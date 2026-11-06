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
    private let showsHevyImport: Bool
    private enum Destination: Hashable {
        case hevyImport
    }

    init(showsHevyImport: Bool = false) {
        self.showsHevyImport = showsHevyImport
    }

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
    @ObservedObject private var dataActions = SettingsDataActionCoordinator.shared
    @State private var preparationFeedback = 0
    @State private var successFeedback = 0
    @State private var errorFeedback = 0

    private var cloudBackupFooterText: String {
        if case .unavailable(let message) = backupStore.loadState {
            return message.replacingOccurrences(of: "Iron", with: "Light")
        }
        return "Automatic backups are attempted when Light closes, keeping the latest backup each day in iCloud Drive."
    }

    var body: some View {
        if showsHevyImport {
            settingsContent
        } else {
            settingsContent.navigationDestination(for: Destination.self) { _ in
                HevyImportView()
            }
        }
    }

    private var settingsContent: some View {
        List {
            if showsHevyImport {
                hevyImportContent
            } else {
                Section {
                    Button {
                        isReplacingImport = false
                        isShowingCSVImporter = true
                    } label: {
                        SettingsActionLabel("Import from Hevy", systemImage: "square.and.arrow.down",
                                            tint: IronTheme.metricVolume, trailingSymbol: "folder")
                    }
                    if !importedWorkouts.isEmpty {
                        // Keep the destination alive when removing the final imported workout.
                        NavigationLink(value: Destination.hevyImport) {
                            LabeledContent {
                                Text("^[\(importedWorkouts.count) workout](inflect: true)")
                                    .font(.ironMetric(.body, weight: .semibold))
                            } label: {
                                SettingsRowLabel("Hevy Import", systemImage: "tray.full.fill", tint: IronTheme.metricSets)
                            }
                        }
                    }
                } header: {
                    Text("Hevy")
                } footer: {
                    Text("Choose workout_data.csv, measurement_data.csv, or both from your Hevy export.")
                }

                Section {
                    Button(action: createAndShareBackup) {
                        SettingsActionLabel("Share Full Backup", systemImage: "archivebox.fill", tint: IronTheme.accent,
                                            trailingSymbol: "square.and.arrow.up",
                                            isPreparing: dataActions.activeAction == .fullBackup)
                    }
                    .accessibilityLabel(dataActions.activeAction == .fullBackup ? "Preparing Share Full Backup" : "Share Full Backup")

                    NavigationLink {
                        RestoreBackupView(backupStore: backupStore)
                    } label: {
                        SettingsRowLabel("Restore Light Backup", systemImage: "arrow.counterclockwise", tint: IronTheme.metricVolume)
                    }
                    nativeCloudBackupContent
                    LabeledContent {
                        Text(backupStore.lastBackup.map {
                            BackupFileStore.BackupFile.dateFormatter.string(from: $0.creationDate)
                        } ?? "None")
                        .font(.ironMetric(.body, weight: .semibold))
                    } label: {
                        SettingsRowLabel("Last Backup", systemImage: "clock.fill", tint: IronTheme.secondaryText)
                    }
                } header: {
                    Text("Backup")
                } footer: {
                    Text(cloudBackupFooterText)
                }

                Section("Export") {
                    Button(action: exportHevyWorkoutCSV) {
                        SettingsActionLabel("Workouts (Hevy CSV)", systemImage: "tablecells", tint: IronTheme.accent,
                                            trailingSymbol: "square.and.arrow.up",
                                            isPreparing: dataActions.activeAction == .workouts)
                    }
                    .accessibilityLabel(dataActions.activeAction == .workouts ? "Preparing Workouts (Hevy CSV)" : "Workouts (Hevy CSV)")
                    Button(action: exportHevyMeasurementCSV) {
                        SettingsActionLabel("Measurements (Hevy CSV)", systemImage: "ruler", tint: IronTheme.metricBody,
                                            trailingSymbol: "square.and.arrow.up",
                                            isPreparing: dataActions.activeAction == .measurements)
                    }
                    .accessibilityLabel(dataActions.activeAction == .measurements ? "Preparing Measurements (Hevy CSV)" : "Measurements (Hevy CSV)")
                    Button(action: exportWorkoutDataJSON) {
                        SettingsActionLabel("JSON", systemImage: "curlybraces", tint: IronTheme.metricVolume,
                                            trailingSymbol: "square.and.arrow.up",
                                            isPreparing: dataActions.activeAction == .json)
                    }
                    .accessibilityLabel(dataActions.activeAction == .json ? "Preparing JSON" : "JSON")
                    Button(action: exportWorkoutDataText) {
                        SettingsActionLabel("Plain Text", systemImage: "doc.plaintext", tint: IronTheme.secondaryText,
                                            trailingSymbol: "square.and.arrow.up",
                                            isPreparing: dataActions.activeAction == .text)
                    }
                    .accessibilityLabel(dataActions.activeAction == .text ? "Preparing Plain Text" : "Plain Text")
                }
            }
        }
        .labeledContentStyle(SettingsValueStyle())
        .disabled(dataActions.isBusy)
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: IronTheme.floatingWorkoutBottomClearance - 36)
        }
        .onAppear {
            if !showsHevyImport { backupStore.fetchBackups() }
        }
        .navigationTitle(showsHevyImport ? "Hevy Import" : "Import & Export")
        .navigationBarTitleDisplayMode(.inline)
        .ironScreen()
        .sensoryFeedback(.impact(weight: .light), trigger: preparationFeedback) { _, _ in SettingsStore.shared.workoutHaptics }
        .sensoryFeedback(.success, trigger: successFeedback) { _, _ in SettingsStore.shared.workoutHaptics }
        .sensoryFeedback(.error, trigger: errorFeedback) { _, _ in SettingsStore.shared.workoutHaptics }
        .alert(item: $operationError) { operationError in
            Alert(
                title: Text(operationError.title),
                message: Text(operationError.error.localizedDescription),
                dismissButton: .default(Text("OK"))
            )
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

    private var hevyImportContent: some View {
        Section {
            LabeledContent {
                Text(importedWorkouts.count.formatted())
                    .font(.ironMetric(.body, weight: .semibold))
            } label: {
                SettingsRowLabel("Workouts", systemImage: "dumbbell.fill", tint: IronTheme.metricSets)
            }
            LabeledContent {
                Text(importedDateRange)
            } label: {
                SettingsRowLabel("Dates", systemImage: "calendar", tint: IronTheme.accent)
            }

            Button(action: exportHevyImportCSV) {
                SettingsActionLabel("Download Hevy Import", systemImage: "arrow.down.doc.fill", tint: IronTheme.metricVolume,
                                    trailingSymbol: "square.and.arrow.up",
                                    isPreparing: dataActions.activeAction == .hevyImport)
            }
            .accessibilityLabel(dataActions.activeAction == .hevyImport ? "Preparing Download Hevy Import" : "Download Hevy Import")
            .accessibilityHint("Regenerates a Hevy CSV from your imported workouts")
            .disabled(importedWorkouts.isEmpty)

            Button {
                isReplacingImport = true
                isShowingCSVImporter = true
            } label: {
                SettingsActionLabel("Replace with New Export", systemImage: "arrow.triangle.2.circlepath",
                                    tint: IronTheme.accent, trailingSymbol: "folder")
            }
            Button(role: .destructive) {
                showingRemoveConfirmation = true
            } label: {
                HStack(spacing: 12) {
                    SettingsRowIcon(systemImage: "trash.fill", tint: IronTheme.danger)
                    Text("Remove Imported Workouts")
                        .foregroundStyle(IronTheme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(importedWorkouts.isEmpty)
        } footer: {
            Text("Imported workouts are never sent to Apple Health.")
        }
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

    @ViewBuilder
    private var nativeCloudBackupContent: some View {
        switch backupStore.loadState {
        case .idle, .loading:
            LabeledContent {
                HStack(spacing: 8) {
                    Text("Checking…")
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
            } label: {
                SettingsRowLabel("iCloud Drive", systemImage: "icloud.fill", tint: IronTheme.metricTime)
            }

        case .unavailable:
            LabeledContent {
                SettingsStatusBadge(text: "Unavailable", isGood: false)
            } label: {
                SettingsRowLabel("iCloud Drive", systemImage: "icloud.slash.fill", tint: IronTheme.metricTime)
            }
            Button(action: backupStore.fetchBackups) {
                SettingsActionLabel("Try iCloud Again", systemImage: "arrow.clockwise", tint: IronTheme.accent,
                                    trailingSymbol: "arrow.clockwise.circle")
            }

        case .loaded:
            LabeledContent {
                SettingsStatusBadge(text: "On", isGood: true)
            } label: {
                SettingsRowLabel("iCloud Drive", systemImage: "icloud.fill", tint: IronTheme.metricTime)
            }
            SettingsToggle("Back Up Automatically", systemImage: "clock.arrow.2.circlepath", tint: IronTheme.accent,
                           isOn: $settingsStore.autoBackup)
                .tint(IronTheme.accent)
            Button(action: createCloudBackup) {
                SettingsActionLabel("Back Up Now", systemImage: "icloud.and.arrow.up.fill", tint: IronTheme.metricTime,
                                    trailingSymbol: "arrow.up.circle",
                                    isPreparing: dataActions.activeAction == .cloudBackup)
            }
            .accessibilityLabel(dataActions.activeAction == .cloudBackup ? "Preparing Back Up Now" : "Back Up Now")
        }
    }

    private func createAndShareBackup() {
        let store = exerciseStore
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        prepareExport(.fullBackup, filename: "\(formatter.string(from: Date())).ironbackup",
                      errorTitle: "Could Not Create Backup") { context in
            os_log("Creating backup data", log: .backup, type: .default)
            return try IronBackup.createBackupData(managedObjectContext: context, exerciseStore: store)
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
        let exercises = exerciseStore.exercises
        let unit = settingsStore.weightUnit
        prepareExport(.workouts, filename: "workout_data.csv", errorTitle: "Could Not Export Workout Data") { context in
            try HevyCSV.exportData(workouts: SettingsExportFiles.fetchWorkouts(in: context),
                                   exercises: exercises, weightUnit: unit)
        }
    }

    private func exportHevyImportCSV() {
        let exercises = exerciseStore.exercises
        let unit = settingsStore.weightUnit
        // Original files were never retained; regenerate only the Hevy-imported sessions.
        prepareExport(.hevyImport, filename: "hevy_import_workout_data.csv", errorTitle: "Could Not Download Hevy Import") { context in
            try HevyCSV.exportData(
                workouts: SettingsExportFiles.fetchWorkouts(in: context, predicate: HevyImportedWorkouts.predicate),
                exercises: exercises,
                weightUnit: unit
            )
        }
    }

    private func exportHevyMeasurementCSV() {
        let entries = BodyMetricsStore.shared.entries
        let unit = settingsStore.weightUnit
        prepareExport(.measurements, filename: "measurement_data.csv", errorTitle: "Could Not Export Measurements") { _ in
            try HevyCSV.exportMeasurementData(entries: entries, weightUnit: unit)
        }
    }

    private func exportWorkoutDataJSON() {
        let exercises = ExerciseStore.shared.exercises
        prepareExport(.json, filename: "workout_data.json", errorTitle: "Could Not Export Workout Data") { context in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            if let exercisesKey = CodingUserInfoKey.exercisesKey {
                encoder.userInfo[exercisesKey] = exercises
            }
            return try encoder.encode(SettingsExportFiles.fetchWorkouts(in: context))
        }
    }

    private func exportWorkoutDataText() {
        let exercises = exerciseStore.exercises
        let unit = settingsStore.weightUnit
        prepareExport(.text, filename: "workout_data.txt", errorTitle: "Could Not Export Workout Data") { context in
            let text = try SettingsExportFiles.fetchWorkouts(in: context)
                .compactMap { $0.logText(in: exercises, weightUnit: unit) }
                .joined(separator: "\n\n\n\n\n")
            return Data(text.utf8)
        }
    }

    private func prepareExport(
        _ action: SettingsDataActionCoordinator.Action,
        filename: String,
        errorTitle: String,
        makeData: @escaping (NSManagedObjectContext) throws -> Data
    ) {
        guard dataActions.begin(action) else { return }
        preparationFeedback += 1
        let reader = SettingsDataActionCoordinator.reader(parent: managedObjectContext)
        Task { @MainActor in
            do {
                let url = try await reader.perform {
                    try SettingsExportFiles.write(data: makeData(reader), name: filename)
                }
                dataActions.finish()
                successFeedback += 1
                activityItems = [url]
            } catch {
                dataActions.finish()
                errorFeedback += 1
                operationError = DataOperationError(title: errorTitle, error: error)
            }
        }
    }

    private func createCloudBackup() {
        guard dataActions.begin(.cloudBackup) else { return }
        preparationFeedback += 1
        let reader = SettingsDataActionCoordinator.reader(parent: managedObjectContext)
        let store = exerciseStore
        Task { @MainActor in
            do {
                let data = try await reader.perform {
                    try IronBackup.createBackupData(managedObjectContext: reader, exerciseStore: store)
                }
                // The store writes the prepared bytes on its existing iCloud queue.
                backupStore.create(data: { data }, onSuccess: { _ in
                    DispatchQueue.main.async {
                        dataActions.finish()
                        // The drop-down plays the success haptic.
                        LightToastCenter.shared.show(LightToast(
                            title: "Backup Created", subtitle: "Saved to iCloud Drive",
                            systemImage: "checkmark.icloud.fill"))
                    }
                }, onError: { error in
                    DispatchQueue.main.async {
                        dataActions.finish()
                        errorFeedback += 1
                        operationError = DataOperationError(title: "Could Not Create iCloud Backup", error: error)
                    }
                })
            } catch {
                dataActions.finish()
                errorFeedback += 1
                operationError = DataOperationError(title: "Could Not Create iCloud Backup", error: error)
            }
        }
    }
}

/// A separate destination sharing the existing import confirmations and export preparation path.
struct HevyImportView: View {
    var body: some View {
        BackupAndExportView(showsHevyImport: true)
    }
}

/// One gate for exports, manual backups and restores, including across subpage navigation.
@MainActor
final class SettingsDataActionCoordinator: ObservableObject {
    enum Action: Equatable {
        case workouts, hevyImport, measurements, json, text, fullBackup, cloudBackup, restore
    }

    static let shared = SettingsDataActionCoordinator()
    @Published private(set) var activeAction: Action?
    var isBusy: Bool { activeAction != nil }

    func begin(_ action: Action) -> Bool {
        guard !isBusy else { return false }
        activeAction = action
        return true
    }

    func finish() {
        activeAction = nil
    }

    static func reader(parent: NSManagedObjectContext) -> NSManagedObjectContext {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        // Read the store directly: a child of the UI context would fire every fault through the
        // main queue, stalling the spinner for a large history. Edits are saved as they're made,
        // so the store already holds them. Fetched objects and encoding stay on this queue.
        if let coordinator = parent.persistentStoreCoordinator {
            context.persistentStoreCoordinator = coordinator
        } else {
            context.parent = parent
        }
        context.undoManager = nil
        return context
    }
}

private enum SettingsExportFiles {
    static func fetchWorkouts(in context: NSManagedObjectContext, predicate: NSPredicate? = nil) throws -> [Workout] {
        let request: NSFetchRequest<Workout> = Workout.fetchRequest()
        let completed = NSPredicate(format: "\(#keyPath(Workout.isCurrentWorkout)) != %@", NSNumber(booleanLiteral: true))
        if let predicate {
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [completed, predicate])
        } else {
            request.predicate = completed
        }
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Workout.start, ascending: false)]
        // Every export walks each workout's exercises and sets; load them in the same pass.
        request.relationshipKeyPathsForPrefetching = ["workoutExercises", "workoutExercises.workoutSets"]
        return try context.fetch(request)
    }

    static func write(data: Data, name: String) throws -> URL {
        // Separate share sessions so a later export cannot overwrite a file still being shared.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
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
