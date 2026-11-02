//
//  RestoreBackupView.swift
//  Iron
//
//  Created by Karim Abou Zeid on 28.10.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import SwiftUI
import WorkoutDataKit

struct RestoreBackupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) var managedObjectContext
    @EnvironmentObject var exerciseStore: ExerciseStore

    @ObservedObject var backupStore: BackupFileStore

    private struct BackupModal: Identifiable {
        enum Kind {
            case restoreConfirmation(URL)
            case deleteConfirmation(URL)
            case restoreResult(RestoreActionSheet.RestoreResult)
            case deleteError(Error)
        }

        let id = UUID()
        let kind: Kind
    }

    @State private var activeModal: BackupModal?
    @State private var modalAfterDismiss: BackupModal?
    @State private var isRestoring = false

    var body: some View {
        List {
            Section {
                switch backupStore.loadState {
                case .idle, .loading:
                    HStack {
                        ProgressView()
                        Text("Checking iCloud Drive…")
                            .foregroundStyle(.secondary)
                    }

                case .unavailable(let message):
                    ContentUnavailableView {
                        Label("iCloud Drive Unavailable", systemImage: "icloud.slash.fill")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again", action: backupStore.fetchBackups)
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .controlSize(.large)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)

                case .loaded:
                    if backupStore.backups.isEmpty {
                        ContentUnavailableView {
                            Label("No iCloud Backups", systemImage: "icloud.fill")
                        } description: {
                            Text("Create your first private backup, then return here whenever you need to restore it.")
                        }
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(backupStore.backups.indices, id: \.self) { index in
                            backupRow(backupStore.backups[index])
                        }
                    }
                }
            } header: {
                Text("iCloud Backups")
            } footer: {
                Text("A restore replaces completed workouts, saved workouts, custom exercises, body measurements, and set tracking targets. Other settings and any workout in progress stay unchanged.")
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: IronTheme.floatingWorkoutBottomClearance - 36)
        }
        .navigationTitle("Restore Backup")
        .navigationBarTitleDisplayMode(.inline)
        .ironScreen()
        .onAppear(perform: backupStore.fetchBackups)
        .allowsHitTesting(!isRestoring)
        .overlay {
            if isRestoring {
                restoreProgressOverlay
                    .transition(.opacity)
            }
        }
        .sheet(item: $activeModal, onDismiss: presentQueuedModal) { modal in
            switch modal.kind {
            case .restoreConfirmation(let url):
                IronConfirmationSheet(
                    title: RestoreActionSheet.confirmationTitle,
                    message: RestoreActionSheet.confirmationMessage,
                    confirmTitle: "Restore Backup",
                    systemImage: "arrow.counterclockwise.icloud.fill",
                    secondaryTitle: "Keep Current Data",
                    onCancel: { activeModal = nil },
                    onConfirm: { restoreBackup(at: url) }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)

            case .deleteConfirmation(let url):
                IronConfirmationSheet(
                    title: "Delete this backup?",
                    message: "This removes only the selected iCloud backup. Other backups and your current Light data are not changed.",
                    confirmTitle: "Delete Backup",
                    systemImage: "trash.fill",
                    secondaryTitle: "Keep Backup",
                    onCancel: { activeModal = nil },
                    onConfirm: { deleteBackup(at: url) }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)

            case .restoreResult(let result):
                let details = RestoreActionSheet.restoreResultDetails(result)
                IronStatusSheet(
                    headerTitle: "Restore",
                    title: details.title,
                    message: details.message,
                    systemImage: details.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    tint: details.isSuccess ? IronTheme.success : IronTheme.danger
                )

            case .deleteError(let error):
                IronStatusSheet(
                    headerTitle: "Backups",
                    title: "Could not delete backup",
                    message: error.localizedDescription,
                    systemImage: "trash.slash.fill",
                    tint: IronTheme.danger
                )
            }
        }
    }

    private var restoreProgressOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Restoring Your Data")
                    .font(.headline)
                Text("Keep Light open while workouts and measurements are replaced.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Restoring your Light data")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func backupRow(_ backup: BackupFileStore.BackupFile) -> some View {
        Button {
            activeModal = BackupModal(kind: .restoreConfirmation(backup.url))
        } label: {
            SettingsSubpageLabel(
                BackupFileStore.BackupFile.dateFormatter.string(from: backup.creationDate),
                detail: "\(backup.deviceName) · \(BackupFileStore.BackupFile.byteCountFormatter.string(fromByteCount: Int64(backup.fileSize)))",
                systemImage: "archivebox.fill",
                tint: IronTheme.metricVolume
            )
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                activeModal = BackupModal(kind: .deleteConfirmation(backup.url))
            }
        }
        .contextMenu {
            Button("Restore Backup", systemImage: "arrow.counterclockwise") {
                activeModal = BackupModal(kind: .restoreConfirmation(backup.url))
            }
            Button("Delete Backup", systemImage: "trash", role: .destructive) {
                activeModal = BackupModal(kind: .deleteConfirmation(backup.url))
            }
        }
    }

    private func restoreBackup(at url: URL) {
        guard !isRestoring else { return }
        isRestoring = true
        activeModal = nil

        // Let the confirmation sheet finish dismissing and render the progress
        // surface before the Core Data replacement starts on its required queue.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            RestoreActionSheet.restore(
                context: managedObjectContext,
                exerciseStore: exerciseStore,
                data: { try Data(contentsOf: url) }
            ) { result in
                isRestoring = false
                activeModal = BackupModal(kind: .restoreResult(result))
            }
        }
    }

    private func deleteBackup(at url: URL) {
        guard let index = backupStore.backups.firstIndex(where: { $0.url == url }) else {
            activeModal = nil
            return
        }
        do {
            try backupStore.delete(at: index)
        } catch {
            modalAfterDismiss = BackupModal(kind: .deleteError(error))
        }
        activeModal = nil
    }

    private func presentQueuedModal() {
        guard let nextModal = modalAfterDismiss else { return }
        modalAfterDismiss = nil
        DispatchQueue.main.async {
            activeModal = nextModal
        }
    }
}

import CoreData
enum RestoreActionSheet {
    typealias RestoreResult = Result<Void, Error>

    static let confirmationTitle = "Restore this backup?"
    static let confirmationMessage = "Completed workouts, saved workouts, custom exercises, and saved body measurements will be replaced with the backup. Settings and any workout in progress stay unchanged. This cannot be undone."

    static func restore(
        context: NSManagedObjectContext,
        exerciseStore: ExerciseStore,
        data: @escaping () throws -> Data,
        completion: @escaping (RestoreResult) -> Void
    ) {
        do {
            try IronBackup.restoreBackupData(
                data: data(),
                managedObjectContext: context,
                exerciseStore: exerciseStore
            )
            BodyMetricsStore.shared.reload()
            completion(.success(()))
        } catch {
            completion(.failure(error))
        }
    }

    static func restoreResultDetails(_ restoreResult: RestoreResult) -> (title: String, message: String, isSuccess: Bool) {
        switch restoreResult {
        case .success():
            return (
                "Restore complete",
                "Your completed workouts, saved workouts, custom exercises, and body measurements are ready.",
                true
            )
        case .failure(let error):
            let errorMessage: String
            if let decodingError = error as? DecodingError {
                switch decodingError {
                case let .dataCorrupted(context):
                    errorMessage = "Data corrupted. \(context.debugDescription)"
                case let .keyNotFound(_, context):
                    errorMessage = "Key not found. \(context.debugDescription)"
                case let .typeMismatch(_, context):
                    errorMessage = "Type mismatch. \(context.debugDescription)"
                case let .valueNotFound(_, context):
                    errorMessage = "Value not found. \(context.debugDescription)"
                @unknown default:
                    errorMessage = "Decoding error. \(error.localizedDescription)"
                }
            } else {
                errorMessage = error.localizedDescription
            }
            return ("Restore failed", errorMessage, false)
        }
    }
}
