//
//  BackupAndExportView.swift
//  Iron
//
//  Created by Karim Abou Zeid on 17.09.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import SwiftUI
import CoreData
import WorkoutDataKit
import os.log
import UniformTypeIdentifiers

struct BackupAndExportView: View {
    @Environment(\.managedObjectContext) var managedObjectContext
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var exerciseStore: ExerciseStore

    @ObservedObject var backupStore = BackupFileStore.shared
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Workout.start, ascending: true)],
        predicate: HevyImportedWorkouts.predicate
    ) private var importedWorkouts: FetchedResults<Workout>

    @State private var operationError: DataOperationError?
    private struct DataOperationError: Identifiable {
        let id = UUID()
        let title: String
        let error: Error
    }

    @State private var activityItems: [Any]?
    @State private var isShowingCSVImporter = false
    @State private var isReplacingImport = false
    @State private var replacementCSV: Data?
    @State private var showingRemoveConfirmation = false
    @State private var showingReplaceConfirmation = false
    @State private var hevyImportOutcome: HevyCSVImportOutcome?
    @State private var isCreatingCloudBackup = false
    @State private var cloudBackupSucceeded = false

    private var cloudBackupFooterText: String {
        var strings = [String]()
        if settingsStore.autoBackup {
            strings.append("Light attempts an automatic backup when iOS closes the app.")
        }
        strings.append("Backups are in Light’s iCloud Drive folder and the Files app; only the last backup each day is kept.")

        return strings.joined(separator: " ")
    }

    var body: some View {
        List {
            Section {
                nativeSummaryRow(
                    title: "Bring everything into Light",
                    detail: "Imports one or both Hevy CSV files automatically.",
                    systemImage: "square.and.arrow.down"
                )

                Button(action: {
                    isReplacingImport = false
                    isShowingCSVImporter = true
                }) {
                    SettingsSubpageLabel("Choose CSV from Files", systemImage: "folder.fill", tint: IronTheme.metricVolume)
                }
                .buttonStyle(.plain)
            } header: {
                Text("Import")
            } footer: {
                Text("Choose workout_data.csv, measurement_data.csv, or both. Light detects each file automatically.")
            }

            importedDataSection

            Section {
                nativeSummaryRow(
                    title: "Take your data with you",
                    detail: "Share Hevy-compatible CSV files or a complete Light backup.",
                    systemImage: "square.and.arrow.up"
                )

                Button(action: exportHevyWorkoutCSV) {
                    SettingsSubpageLabel("Workouts (Hevy CSV)", systemImage: "tablecells", tint: IronTheme.accent)
                }
                .buttonStyle(.plain)
                Button(action: exportHevyMeasurementCSV) {
                    SettingsSubpageLabel("Measurements (Hevy CSV)", systemImage: "ruler", tint: IronTheme.metricBody)
                }
                .buttonStyle(.plain)

                Button(action: exportWorkoutDataJSON) {
                    SettingsSubpageLabel("JSON", systemImage: "curlybraces", tint: IronTheme.metricVolume)
                }
                .buttonStyle(.plain)
                Button(action: exportWorkoutDataText) {
                    SettingsSubpageLabel("Plain Text", systemImage: "doc.plaintext", tint: IronTheme.metricVolume)
                }
                .buttonStyle(.plain)

                Button(action: createAndShareBackup) {
                    SettingsSubpageLabel("Share Full Backup", systemImage: "archivebox.fill", tint: IronTheme.metricVolume)
                }
                .buttonStyle(.plain)
            } header: {
                Text("Export")
            }

            Section {
                nativeCloudBackupContent
                if let creationDate = backupStore.lastBackup?.creationDate {
                    LabeledContent("Last Backup") {
                        Text(BackupFileStore.BackupFile.dateFormatter.string(from: creationDate))
                            .font(.ironMetric(.body, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("iCloud Backup")
            } footer: {
                Text(cloudBackupFooterText)
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: IronTheme.floatingWorkoutBottomClearance - 36)
        }
        .onAppear(perform: backupStore.fetchBackups)
        .navigationTitle("Import & Export")
        .navigationBarTitleDisplayMode(.inline)
        .ironScreen()
        .alert(item: $operationError) { operationError in
            Alert(
                title: Text(operationError.title),
                message: Text(operationError.error.localizedDescription),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert("Backup created", isPresented: $cloudBackupSucceeded) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your latest Light data is now stored in iCloud Drive and is available from Restore Backup or the Files app.")
        }
        .ironActivitySheet(activityItems: $activityItems)
        .fileImporter(
            isPresented: $isShowingCSVImporter,
            allowedContentTypes: [.commaSeparatedText],
            allowsMultipleSelection: !isReplacingImport,
            onCompletion: importCSV
        )
        .confirmationDialog(
            "Remove \(importedWorkouts.count.formatted()) Imported Workouts?",
            isPresented: $showingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Imported Workouts", role: .destructive) {
                let count = importedWorkouts.count
                Task {
                    hevyImportOutcome = await HevyImportController.shared.remove(count: count, from: managedObjectContext)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \(importedWorkouts.count.formatted()) Hevy workouts and their sets. Workouts you logged in Light are kept.")
        }
        .confirmationDialog(
            "Replace \(importedWorkouts.count.formatted()) Imported Workouts?",
            isPresented: $showingReplaceConfirmation,
            titleVisibility: .visible
        ) {
            Button("Replace Imported Workouts", role: .destructive, action: replaceImportedWorkouts)
            Button("Cancel", role: .cancel) { replacementCSV = nil }
        } message: {
            Text("The selected export replaces your Hevy workouts. Workouts you logged in Light are kept. If the import fails, your existing imported workouts are restored.")
        }
        .sheet(item: $hevyImportOutcome) { outcome in
            HevyCSVImportResultSheet(outcome: outcome)
        }
    }

    private var importedDataSection: some View {
        Section {
            importedSummary

            Button {
                isReplacingImport = true
                isShowingCSVImporter = true
            } label: {
                SettingsSubpageLabel("Replace with New Export…", systemImage: "arrow.triangle.2.circlepath", tint: IronTheme.metricVolume)
            }
            .buttonStyle(.plain)
            Button(role: .destructive) {
                showingRemoveConfirmation = true
            } label: {
                HStack(spacing: 12) {
                    SettingsSubpageIconTile(systemImage: "trash.fill", tint: IronTheme.danger)
                    Text("Remove Imported Workouts")
                        .font(.body)
                        .foregroundStyle(IronTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tint(IronTheme.danger)
            // ironScreen supplies the legacy accent environment used by
            // native List label icons; override it for this destructive row.
            .accentColor(IronTheme.danger)
            .disabled(importedWorkouts.isEmpty)
        } header: {
            Text("Imported Data")
        } footer: {
            Text("Workouts you logged in Light and body measurements are kept. Imported workouts are never exported to Apple Health.")
        }
    }

    private var importedSummary: some View {
        let count = importedWorkouts.count.formatted()
        let unit = importedWorkouts.count == 1 ? "workout" : "workouts"
        return (
            Text("Hevy · ").foregroundColor(IronTheme.primaryText)
                + Text(count).font(.ironMetric(.body, weight: .semibold))
                    .foregroundColor(IronTheme.primaryText)
                + Text(" \(unit) · \(importedDateRange)").foregroundColor(IronTheme.secondaryText)
        )
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Hevy, \(count) \(unit), \(importedDateRange)")
    }

    private var importedDateRange: String {
        guard let first = importedWorkouts.first?.start, let last = importedWorkouts.last?.start else {
            return "No imported workouts"
        }
        let format = Date.FormatStyle.dateTime.month(.abbreviated).year()
        let firstText = first.formatted(format)
        let lastText = last.formatted(format)
        return firstText == lastText ? firstText : "\(firstText) – \(lastText)"
    }

    private func replaceImportedWorkouts() {
        guard let document = replacementCSV else { return }
        replacementCSV = nil
        Task {
            hevyImportOutcome = await HevyImportController.shared.replace(
                document, into: managedObjectContext, exerciseStore: exerciseStore
            )
        }
    }

    private func nativeSummaryRow(
        title: String,
        detail: String,
        systemImage: String
    ) -> some View {
        SettingsSubpageLabel(title, detail: detail, systemImage: systemImage, tint: IronTheme.metricVolume)
    }

    @ViewBuilder
    private var nativeCloudBackupContent: some View {
        switch backupStore.loadState {
        case .idle, .loading:
            HStack(spacing: 12) {
                SettingsSubpageLabel("Checking iCloud Drive", detail: "Looking for Light backups saved by your devices…",
                                     systemImage: "icloud.fill")
                ProgressView()
            }

        case .unavailable(let message):
            SettingsSubpageLabel("iCloud Drive unavailable", detail: message,
                                 systemImage: "icloud.slash", tint: IronTheme.warning)

            Button(action: backupStore.fetchBackups) {
                SettingsSubpageLabel("Try iCloud Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)

        case .loaded:
            if backupStore.lastBackup != nil {
                NavigationLink(destination: RestoreBackupView(backupStore: backupStore)) {
                    SettingsSubpageLabel("Restore from iCloud", detail: restoreAvailabilityText,
                                         systemImage: "arrow.counterclockwise.icloud")
                }
            } else {
                SettingsSubpageLabel("Restore from iCloud", detail: "No saved backups yet",
                                     systemImage: "icloud.slash", tint: IronTheme.secondaryText)
            }

            Toggle(isOn: $settingsStore.autoBackup) {
                SettingsSubpageLabel("Automatic backups", detail: "Attempt a backup when Light closes",
                                     systemImage: "clock.arrow.circlepath")
            }
            .tint(IronTheme.accent)

            Button(action: createCloudBackup) {
                HStack(spacing: 12) {
                    SettingsSubpageLabel(isCreatingCloudBackup ? "Creating Backup…" : "Back Up Now",
                                         systemImage: "icloud.and.arrow.up")
                    if isCreatingCloudBackup { ProgressView() }
                }
            }
            .buttonStyle(.plain)
            .disabled(isCreatingCloudBackup)
        }
    }

    private var restoreAvailabilityText: String {
        guard let creationDate = backupStore.lastBackup?.creationDate else {
            return "No saved backups yet"
        }
        return "Latest: \(BackupFileStore.BackupFile.dateFormatter.string(from: creationDate))"
    }

    private func createAndShareBackup() {
        do {
            os_log("Creating backup data", log: .backup, type: .default)
            let data = try IronBackup.createBackupData(managedObjectContext: managedObjectContext, exerciseStore: exerciseStore)

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let url = try tempFile(data: data, name: "\(formatter.string(from: Date())).ironbackup")

            shareFile(url: url)
        } catch {
            os_log("Could not create backup: %@", log: .backup, type: .default, error.localizedDescription)
            operationError = DataOperationError(title: "Could Not Create Backup", error: error)
        }
    }

    private func importCSV(_ selection: Result<[URL], Error>) {
        if case .failure(let error) = selection,
           (error as NSError).code == NSUserCancelledError {
            return
        }

        do {
            let urls = try selection.get()
            guard !urls.isEmpty else { return }
            let dataDocuments = try urls.map { url -> Data in
                let isSecurityScoped = url.startAccessingSecurityScopedResource()
                defer {
                    if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
                }
                return try Data(contentsOf: url)
            }

            if isReplacingImport {
                guard dataDocuments.count == 1 else { throw HevyCSVError.replacementRequiresWorkouts }
                replacementCSV = dataDocuments[0]
                showingReplaceConfirmation = true
                return
            }

            Task {
                hevyImportOutcome = await HevyImportController.shared.run(
                    dataDocuments,
                    into: managedObjectContext,
                    exerciseStore: exerciseStore
                )
            }
        } catch {
            hevyImportOutcome = HevyCSVImportOutcome(result: .failure(error))
        }
    }

    private func exportHevyWorkoutCSV() {
        do {
            let workouts = try fetchWorkouts()
            let data = try HevyCSV.exportData(
                workouts: workouts,
                exercises: exerciseStore.exercises,
                weightUnit: settingsStore.weightUnit
            )
            shareFile(url: try tempFile(data: data, name: "workout_data.csv"))
        } catch {
            operationError = DataOperationError(title: "Could Not Export Workout Data", error: error)
        }
    }

    private func exportHevyMeasurementCSV() {
        do {
            let data = try HevyCSV.exportMeasurementData(
                entries: BodyMetricsStore.shared.entries,
                weightUnit: settingsStore.weightUnit
            )
            shareFile(url: try tempFile(data: data, name: "measurement_data.csv"))
        } catch {
            operationError = DataOperationError(title: "Could Not Export Measurements", error: error)
        }
    }

    private func exportWorkoutDataJSON() {
        do {
            let workouts = try fetchWorkouts()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            if let exercisesKey = CodingUserInfoKey.exercisesKey {
                encoder.userInfo[exercisesKey] = ExerciseStore.shared.exercises
            }
            let data = try encoder.encode(workouts)
            shareFile(url: try tempFile(data: data, name: "workout_data.json"))
        } catch {
            operationError = DataOperationError(title: "Could Not Export Workout Data", error: error)
        }
    }

    private func exportWorkoutDataText() {
        do {
            let workouts = try fetchWorkouts()
            let text = workouts
                .compactMap { $0.logText(in: exerciseStore.exercises, weightUnit: settingsStore.weightUnit) }
                .joined(separator: "\n\n\n\n\n")
            let data = Data(text.utf8)
            shareFile(url: try tempFile(data: data, name: "workout_data.txt"))
        } catch {
            operationError = DataOperationError(title: "Could Not Export Workout Data", error: error)
        }
    }

    private func createCloudBackup() {
        guard !isCreatingCloudBackup else { return }
        isCreatingCloudBackup = true
        backupStore.create(data: {
            try self.managedObjectContext.performAndWait { context in
                os_log("Creating backup data", log: .backup, type: .default)
                return try IronBackup.createBackupData(managedObjectContext: context, exerciseStore: self.exerciseStore)
            }
        }, onSuccess: { _ in
            DispatchQueue.main.async {
                self.isCreatingCloudBackup = false
                self.cloudBackupSucceeded = true
            }
        }, onError: { error in
            DispatchQueue.main.async {
                self.isCreatingCloudBackup = false
                self.operationError = DataOperationError(title: "Could Not Create iCloud Backup", error: error)
            }
        })
    }

    private func fetchWorkouts() throws -> [Workout] {
        let request: NSFetchRequest<Workout> = Workout.fetchRequest()
        request.predicate = NSPredicate(format: "\(#keyPath(Workout.isCurrentWorkout)) != %@", NSNumber(booleanLiteral: true))
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Workout.start, ascending: false)]
        return try managedObjectContext.fetch(request)
    }

    private func tempFile(data: Data, name: String) throws -> URL {
        let path = FileManager.default.temporaryDirectory
        let url = path.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func shareFile(url: URL) {
        activityItems = [url]
    }
}

#if DEBUG
struct BackupAndExportView_Previews: PreviewProvider {
    static var previews: some View {
        BackupAndExportView()
            .mockEnvironment(weightUnit: .metric)
    }
}
#endif
