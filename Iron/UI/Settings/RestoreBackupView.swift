//
//  RestoreBackupView.swift
//  Iron
//
//  Created by Karim Abou Zeid on 28.10.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import SwiftUI
import UniformTypeIdentifiers
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
    @ObservedObject private var dataActions = SettingsDataActionCoordinator.shared
    @State private var isRestoring = false
    @State private var restoringURL: URL?
    @State private var pickedBackupURL: URL?
    @State private var isPreparingFile = false
    @State private var preparationFeedback = 0
    @State private var successFeedback = 0
    @State private var errorFeedback = 0
    @State private var isShowingFileImporter = false

    private static let backupFileTypes: [UTType] = [UTType("com.kabouzeid.ironbackup"), .json].compactMap { $0 }

    var body: some View {
        List {
            Section {
                Button { isShowingFileImporter = true } label: {
                    SettingsActionLabel("Choose Backup File", systemImage: "folder.fill", tint: IronTheme.accent,
                                        trailingSymbol: "doc.badge.arrow.up",
                                        isPreparing: isPreparingFile || (isRestoring && restoringURL == pickedBackupURL))
                }
                .accessibilityLabel(isPreparingFile || (isRestoring && restoringURL == pickedBackupURL)
                                    ? "Preparing Choose Backup File"
                                    : "Choose Backup File, A .ironbackup file from Files or AirDrop")
            } header: {
                Text("From Files")
            } footer: {
                Text("Moving to a new Light app: in the old app, Share Full Backup and save it to Files, then choose it here.")
            }

            Section {
                switch backupStore.loadState {
                case .idle, .loading:
                    LabeledContent("Status") {
                        HStack(spacing: 8) {
                            Text("Checking iCloud Drive…")
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityHidden(true)
                        }
                    }

                case .unavailable:
                    LabeledContent("Status") {
                        Text("iCloud Drive Unavailable")
                            .foregroundStyle(IronTheme.danger)
                    }
                    Button("Try Again", action: backupStore.fetchBackups)

                case .loaded:
                    if backupStore.backups.isEmpty {
                        LabeledContent("Status", value: "No iCloud Backups")
                    } else {
                        ForEach(backupStore.backups.indices, id: \.self) { index in
                            backupRow(backupStore.backups[index])
                        }
                    }
                }
            } header: {
                Text("iCloud Backups")
            } footer: {
                if case .unavailable(let message) = backupStore.loadState {
                    Text(message.replacingOccurrences(of: "Iron", with: "Light"))
                } else {
                    Text("Restoring replaces saved data and settings while keeping any workout in progress.")
                }
            }
        }
        .disabled(dataActions.isBusy || isPreparingFile)
        .labeledContentStyle(SettingsValueStyle())
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: IronTheme.floatingWorkoutBottomClearance - 36)
        }
        .navigationTitle("Restore Light Backup")
        .navigationBarTitleDisplayMode(.inline)
        .ironScreen()
        .sensoryFeedback(.impact(weight: .light), trigger: preparationFeedback) { _, _ in SettingsStore.shared.workoutHaptics }
        .sensoryFeedback(.success, trigger: successFeedback) { _, _ in SettingsStore.shared.workoutHaptics }
        .sensoryFeedback(.error, trigger: errorFeedback) { _, _ in SettingsStore.shared.workoutHaptics }
        .onAppear(perform: backupStore.fetchBackups)
        .fileImporter(isPresented: $isShowingFileImporter, allowedContentTypes: Self.backupFileTypes) { result in
            if case .failure(let error) = result, (error as NSError).code == NSUserCancelledError { return }
            isPreparingFile = true
            Task { @MainActor in
                let modal: BackupModal
                do {
                    let url = try result.get()
                    let copy = try await Task.detached(priority: .userInitiated) {
                        try Self.localCopy(of: url)
                    }.value
                    pickedBackupURL = copy
                    modal = BackupModal(kind: .restoreConfirmation(copy))
                } catch {
                    errorFeedback += 1
                    modal = BackupModal(kind: .restoreResult(.failure(error)))
                }
                isPreparingFile = false
                // Let the picker finish dismissing before presenting the confirmation.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { activeModal = modal }
            }
        }
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
            HStack(spacing: 12) {
                SettingsRowIcon(systemImage: "archivebox.fill", tint: IronTheme.metricVolume)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isRestoring && restoringURL == backup.url
                         ? "Preparing…"
                         : BackupFileStore.BackupFile.dateFormatter.string(from: backup.creationDate))
                        .font(.body)
                        .foregroundStyle(isRestoring && restoringURL == backup.url ? IronTheme.secondaryText : IronTheme.primaryText)
                    if !(isRestoring && restoringURL == backup.url) {
                        Text("\(backup.deviceName) · \(BackupFileStore.BackupFile.byteCountFormatter.string(fromByteCount: Int64(backup.fileSize)))")
                            .font(.subheadline)
                            .foregroundStyle(IronTheme.secondaryText)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if isRestoring && restoringURL == backup.url {
                    ProgressView()
                        .controlSize(.small)
                        .tint(IronTheme.secondaryText)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(isRestoring && restoringURL == backup.url
                            ? "Preparing Restore Backup, \(BackupFileStore.BackupFile.dateFormatter.string(from: backup.creationDate))"
                            : "\(BackupFileStore.BackupFile.dateFormatter.string(from: backup.creationDate)), \(backup.deviceName), \(BackupFileStore.BackupFile.byteCountFormatter.string(fromByteCount: Int64(backup.fileSize)))")
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

    /// A picked file is security-scoped, and the restore reads it later, so copy it while access lasts.
    private nonisolated static func localCopy(of url: URL) throws -> URL {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("ironbackup")
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    private func restoreBackup(at url: URL) {
        guard !isRestoring, dataActions.begin(.restore) else { return }
        preparationFeedback += 1
        restoringURL = url
        isRestoring = true
        activeModal = nil

        // Dismiss the confirmation and render progress before starting the replacement.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            Task { @MainActor in
                do {
                    let data = try await Task.detached(priority: .userInitiated) {
                        try Data(contentsOf: url)
                    }.value
                    // IronBackup.restoreBackupData owns a main-queue child context and
                    // publishes shared stores. Its decoding/transaction must stay on main
                    // until that API can support background preparation outside Settings.
                    RestoreActionSheet.restore(
                        context: managedObjectContext,
                        exerciseStore: exerciseStore,
                        data: { data },
                        completion: finishRestoring
                    )
                } catch {
                    finishRestoring(.failure(error))
                }
            }
        }
    }

    private func finishRestoring(_ result: RestoreActionSheet.RestoreResult) {
        dataActions.finish()
        isRestoring = false
        restoringURL = nil
        switch result {
        case .success: successFeedback += 1
        case .failure: errorFeedback += 1
        }
        activeModal = BackupModal(kind: .restoreResult(result))
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
    static let confirmationMessage = "Completed workouts, saved workouts, custom exercises, saved body measurements, and the settings saved with the backup will be replaced. Any workout in progress stays unchanged. This cannot be undone."

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
