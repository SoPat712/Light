//
//  WorkoutRoutineView.swift
//  Iron
//
//  Created by Karim Abou Zeid on 21.03.20.
//  Copyright © 2020 Karim Abou Zeid Software. All rights reserved.
//

import SwiftUI
import CoreData
import WorkoutDataKit

/// Preferences follow the saved-workout draft's save boundary. Cancelling or a
/// failed Core Data save must not publish a different global type/distance target.
final class RoutineSetTrackingDraft: ObservableObject {
    @Published private(set) var changes = SetTrackingPreferences()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func override(for exerciseID: UUID?) -> SetTrackingType? {
        guard let exerciseID else { return nil }
        return changes.overrides[exerciseID.uuidString]?.type
            ?? SetTrackingPreferences.override(for: exerciseID, defaults: defaults)
    }
    func distance(for setID: UUID?) -> Double? {
        guard let setID else { return nil }
        if let changed = changes.routineDistances[setID.uuidString] { return changed.meters > 0 ? changed.meters : nil }
        return SetTrackingPreferences.routineDistance(for: setID, defaults: defaults)
    }
    func setOverride(_ type: SetTrackingType, for exerciseID: UUID) {
        changes.overrides[exerciseID.uuidString] = .init(type: type, updatedAt: Date().timeIntervalSince1970)
    }
    func setDistance(_ meters: Double?, for setID: UUID) {
        let value = meters.map { $0.isFinite ? max($0, 0) : 0 } ?? 0
        changes.routineDistances[setID.uuidString] = .init(meters: value, updatedAt: Date().timeIntervalSince1970)
    }
    /// Capture effective types as well as explicit overrides: after copying empty
    /// targets there may be no measurements left from which to infer the type.
    func copyTracking(from source: WorkoutRoutine, to destination: WorkoutRoutine) {
        let sources = source.workoutRoutineExercises?.array as? [WorkoutRoutineExercise] ?? []
        let destinations = destination.workoutRoutineExercises?.array as? [WorkoutRoutineExercise] ?? []
        for (source, destination) in zip(sources, destinations) {
            if let id = destination.exerciseUuid {
                setOverride(source.trackingType(catalogExercise: source.exerciseUuid.flatMap {
                    ExerciseStore.shared.exercisesByUUID[$0]
                }, defaults: defaults), for: id)
            }
            let sourceSets = source.workoutRoutineSets?.array as? [WorkoutRoutineSet] ?? []
            let destinationSets = destination.workoutRoutineSets?.array as? [WorkoutRoutineSet] ?? []
            for (sourceSet, destinationSet) in zip(sourceSets, destinationSets) {
                if let id = destinationSet.uuid { setDistance(distance(for: sourceSet.uuid), for: id) }
            }
        }
    }
    func discard() { changes = SetTrackingPreferences() }

    /// Deleted draft rows must not leave new, unreachable distance preferences.
    func retainMetadata(for routine: WorkoutRoutine) {
        let exercises = routine.workoutRoutineExercises?.array as? [WorkoutRoutineExercise] ?? []
        let exerciseIDs = Set(exercises.compactMap { $0.exerciseUuid?.uuidString })
        let setIDs = Set(exercises.flatMap {
            ($0.workoutRoutineSets?.array as? [WorkoutRoutineSet] ?? []).compactMap { $0.uuid?.uuidString }
        })
        changes.overrides = changes.overrides.filter { exerciseIDs.contains($0.key) }
        changes.routineDistances = changes.routineDistances.filter { setIDs.contains($0.key) }
    }
    func commit() {
        guard !changes.isEmpty else { return }
        let stored = SetTrackingPreferences.load(defaults: defaults)
        let merged = stored.merging(changes)
        merged.save(defaults: defaults)
        changes = SetTrackingPreferences()
        if merged != stored {
            NotificationCenter.default.post(name: SetTrackingPreferences.didChangeNotification, object: defaults)
        }
    }
}

/// A focused editor for one saved workout plan.
///
/// Editable values stay close to the exercise they describe, using a dense
/// separator-led canvas with Cupertino controls for direct input.
struct WorkoutRoutineView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject var exerciseStore: ExerciseStore
    @EnvironmentObject var settingsStore: SettingsStore
    @Environment(\.managedObjectContext) var managedObjectContext
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var workoutRoutine: WorkoutRoutine

    let isNew: Bool
    let autosavesChanges: Bool
    let onCancel: (() -> Void)?
    let onCommit: (() -> Void)?

    @StateObject private var trackingDraft: RoutineSetTrackingDraft
    @State private var showExerciseSelector = false
    @State private var workoutRoutineTitleInput: String?
    @State private var workoutRoutineCommentInput: String?
    @State private var routineExerciseToDelete: WorkoutRoutineExercise?
    @State private var selectionFeedback = 0
    @State private var deleteFeedback = 0

    init(
        workoutRoutine: WorkoutRoutine,
        isNew: Bool = false,
        autosavesChanges: Bool = true,
        trackingDraft: RoutineSetTrackingDraft = RoutineSetTrackingDraft(),
        onCancel: (() -> Void)? = nil,
        onCommit: (() -> Void)? = nil
    ) {
        self.workoutRoutine = workoutRoutine
        self.isNew = isNew
        self.autosavesChanges = autosavesChanges
        _trackingDraft = StateObject(wrappedValue: trackingDraft)
        self.onCancel = onCancel
        self.onCommit = onCommit
    }

    private var workoutRoutineTitle: Binding<String> {
        Binding(
            // A plan without a custom title still has a real fallback title
            // (Workout A, Workout B, …). Present that value as editable text instead
            // of making the field look accidentally empty.
            get: { workoutRoutineTitleInput ?? workoutRoutine.displayTitle },
            set: { workoutRoutineTitleInput = $0 }
        )
    }

    private var workoutRoutineComment: Binding<String> {
        Binding(
            get: { workoutRoutineCommentInput ?? workoutRoutine.comment ?? "" },
            set: { workoutRoutineCommentInput = $0 }
        )
    }

    private var workoutRoutineExercises: [WorkoutRoutineExercise] {
        workoutRoutine.workoutRoutineExercises?.array as? [WorkoutRoutineExercise] ?? []
    }

    private var exerciseSelectorSheet: some View {
        AddExercisesSheet(
            exercises: exerciseStore.shownExercises,
            recentExercises: AddExercisesSheet.loadRecentExercises(
                context: managedObjectContext,
                exercises: exerciseStore.shownExercises
            ),
            onAdd: { selection in
                for exercise in selection {
                    let routineExercise = WorkoutRoutineExercise.create(context: managedObjectContext)
                    routineExercise.workoutRoutine = workoutRoutine
                    routineExercise.exerciseUuid = exercise.uuid
                }
                recordDraftChange()
            }
        )
    }

    private func recordDraftChange() {
        managedObjectContext.processPendingChanges()
        if autosavesChanges {
            managedObjectContext.saveOrCrash()
            trackingDraft.commit()
        }
    }

    private func saveRoutineExerciseNote(_ text: String, for exercise: WorkoutRoutineExercise) -> Bool {
        guard !exercise.isDeleted else { return false }
        do {
            try managedObjectContext.persistMutation(save: {
                if autosavesChanges { try managedObjectContext.save() }
            }) {
                exercise.comment = text.isEmpty ? nil : text
            }
            if autosavesChanges { trackingDraft.commit() }
            return true
        } catch {
            return false // The note sheet keeps its draft visible for retry.
        }
    }

    private func saveRoutineFields() {
        if let input = workoutRoutineTitleInput {
            let title = input.trimmingCharacters(in: .whitespacesAndNewlines)
            workoutRoutineTitleInput = title
            workoutRoutine.title = title.isEmpty ? nil : title
        }
        if let input = workoutRoutineCommentInput {
            let comment = input.trimmingCharacters(in: .whitespacesAndNewlines)
            workoutRoutineCommentInput = comment
            workoutRoutine.comment = comment.isEmpty ? nil : comment
        }
        recordDraftChange()
    }

    private func sets(for routineExercise: WorkoutRoutineExercise) -> [WorkoutRoutineSet] {
        routineExercise.workoutRoutineSets?.array as? [WorkoutRoutineSet] ?? []
    }

    private func addSet(to routineExercise: WorkoutRoutineExercise) {
        let previousSet = sets(for: routineExercise).last
        let routineSet = WorkoutRoutineSet.create(context: managedObjectContext)
        routineSet.workoutRoutineExercise = routineExercise
        let type = trackingDraft.override(for: routineExercise.exerciseUuid) ?? routineExercise.setTrackingType
        routineSet.durationValue = type.usesDuration ? (previousSet?.durationValue ?? 60) : nil
        routineSet.weightValue = type.usesWeight ? previousSet?.weightValue : nil
        routineSet.minRepetitionsValue = type.usesReps ? (previousSet?.minRepetitionsValue ?? 5) : nil
        routineSet.maxRepetitionsValue = type.usesReps ? (previousSet?.maxRepetitionsValue ?? 5) : nil
        if type.usesDistance, let setID = routineSet.uuid {
            trackingDraft.setDistance(trackingDraft.distance(for: previousSet?.uuid), for: setID)
        }
        recordDraftChange()
    }

    private func deleteSet(_ routineSet: WorkoutRoutineSet) {
        routineSet.workoutRoutineExercise?.removeFromWorkoutRoutineSets(routineSet)
        managedObjectContext.delete(routineSet)
        recordDraftChange()
        deleteFeedback += 1
    }

    private func moveSet(in routineExercise: WorkoutRoutineExercise, from source: Int, to destination: Int) {
        let currentSets = sets(for: routineExercise)
        guard source != destination,
              currentSets.indices.contains(source),
              currentSets.indices.contains(destination) else { return }

        var reordered = currentSets
        let routineSet = reordered.remove(at: source)
        reordered.insert(routineSet, at: destination)
        routineExercise.workoutRoutineSets = NSOrderedSet(array: reordered)
        recordDraftChange()
        selectionFeedback += 1
    }

    private func deleteExercise(_ routineExercise: WorkoutRoutineExercise) {
        routineExercise.workoutRoutine?.removeFromWorkoutRoutineExercises(routineExercise)
        managedObjectContext.delete(routineExercise)
        recordDraftChange()
        deleteFeedback += 1
    }

    private func moveExercise(from source: Int, to destination: Int) {
        guard source != destination,
              workoutRoutineExercises.indices.contains(source),
              workoutRoutineExercises.indices.contains(destination) else { return }

        var reordered = workoutRoutineExercises
        let routineExercise = reordered.remove(at: source)
        reordered.insert(routineExercise, at: destination)
        workoutRoutine.workoutRoutineExercises = NSOrderedSet(array: reordered)
        recordDraftChange()
        selectionFeedback += 1
    }

    var body: some View {
        List {
            Section("Workout Details") {
                TextField("Title", text: workoutRoutineTitle)
                    .textInputAutocapitalization(.words)
                    .onSubmit(saveRoutineFields)

                TextField("Notes", text: workoutRoutineComment, axis: .vertical)
                    .lineLimit(1...5)
            }

            if workoutRoutineExercises.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No Exercises", systemImage: "dumbbell")
                    } description: {
                        Text("Add an exercise to start setting targets and rest times.")
                    } actions: {
                        Button("Add Exercise") { showExerciseSelector = true }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .controlSize(.large)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(Array(workoutRoutineExercises.enumerated()), id: \.element.id) { index, routineExercise in
                    WorkoutRoutineExerciseSection(
                        routineExercise: routineExercise,
                        exercise: routineExercise.exercise(in: exerciseStore.exercises),
                        sets: sets(for: routineExercise),
                        index: index,
                        exerciseCount: workoutRoutineExercises.count,
                        onSave: recordDraftChange,
                        onSaveNote: { saveRoutineExerciseNote($0, for: routineExercise) },
                        onMoveUp: { moveExercise(from: index, to: index - 1) },
                        onMoveDown: { moveExercise(from: index, to: index + 1) },
                        onDelete: { routineExerciseToDelete = routineExercise },
                        onAddSet: { addSet(to: routineExercise) },
                        onDeleteSet: { deleteSet($0) },
                        onMoveSet: { source, destination in
                            moveSet(in: routineExercise, from: source, to: destination)
                        }
                    )
                }
            }

            Section {
                Button("Add Exercise", systemImage: "plus") {
                    showExerciseSelector = true
                }
            }
        }
        .listStyle(.insetGrouped)
        .environmentObject(trackingDraft)
        .sensoryFeedback(.selection, trigger: selectionFeedback) { _, _ in settingsStore.workoutHaptics }
        .sensoryFeedback(.impact(weight: .medium), trigger: deleteFeedback) { _, _ in settingsStore.workoutHaptics }
        .animation(IronMotion.preferred(IronMotion.collapse, reduceMotion: reduceMotion), value: workoutRoutineExercises.map(\.objectID))
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(isNew ? "New Workout" : "Edit Workout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: cancelEditor)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Create" : "Update", action: commitEditor)
                    .fontWeight(.semibold)
            }
        }
        .sheet(isPresented: $showExerciseSelector) {
            exerciseSelectorSheet
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "Remove exercise from workout?",
            isPresented: Binding(
                get: { routineExerciseToDelete != nil },
                set: { if !$0 { routineExerciseToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Exercise", role: .destructive) {
                guard let routineExercise = routineExerciseToDelete else { return }
                routineExerciseToDelete = nil
                deleteExercise(routineExercise)
            }
            Button("Cancel", role: .cancel) {
                routineExerciseToDelete = nil
            }
        } message: {
            Text("Its target sets, rest timer, and workout notes will be removed. Completed workout history is not affected.")
        }
    }

    private func cancelEditor() {
        if let onCancel {
            onCancel()
        } else {
            dismiss()
        }
    }

    private func commitEditor() {
        saveRoutineFields()
        if let onCommit {
            onCommit()
        } else {
            managedObjectContext.saveOrCrash()
            trackingDraft.retainMetadata(for: workoutRoutine)
            trackingDraft.commit()
            dismiss()
        }

    }

}

private struct WorkoutRoutineExerciseSection: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var settingsStore: SettingsStore

    @EnvironmentObject private var trackingDraft: RoutineSetTrackingDraft
    @ObservedObject var routineExercise: WorkoutRoutineExercise
    @State private var showingRestTimerEditor = false
    @State private var showingNoteEditor = false
    @State private var selectionFeedback = 0
    let exercise: Exercise?
    let sets: [WorkoutRoutineSet]
    let index: Int
    let exerciseCount: Int
    let onSave: () -> Void
    let onSaveNote: (String) -> Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void
    let onAddSet: () -> Void
    let onDeleteSet: (WorkoutRoutineSet) -> Void
    let onMoveSet: (Int, Int) -> Void

    private var restTimerTitle: String {
        guard let duration = routineExercise.restTimerDurationValue,
              let formatted = restTimerDurationFormatter.string(from: duration) else {
            return "Workout default"
        }
        return "Rest \(formatted)"
    }

    @AppStorage(SetTrackingPreferences.storageKey) private var trackingPreferencesData: Data?
    private var trackingType: SetTrackingType { trackingDraft.override(for: routineExercise.exerciseUuid) ?? routineExercise.setTrackingType }

    private var workoutDefaultRestTimerDuration: TimeInterval {
        switch exercise?.type {
        case .barbell: return settingsStore.defaultRestTimeBarbellBased
        case .dumbbell: return settingsStore.defaultRestTimeDumbbellBased
        default: return settingsStore.defaultRestTime
        }
    }

    private func setTrackingType(_ type: SetTrackingType) {
        guard type != trackingType, let exerciseID = routineExercise.exerciseUuid else { return }
        for set in sets {
            set.durationValue = type.usesDuration ? (set.durationValue ?? 60) : nil
            if !type.usesWeight { set.weightValue = nil }
            if type.usesReps {
                set.minRepetitionsValue = set.minRepetitionsValue ?? 5
                set.maxRepetitionsValue = set.maxRepetitionsValue ?? 5
            } else {
                set.minRepetitionsValue = nil
                set.maxRepetitionsValue = nil
            }
            if !type.usesDistance, let setID = set.uuid {
                trackingDraft.setDistance(nil, for: setID)
            }
        }
        trackingDraft.setOverride(type, for: exerciseID)
        onSave()
        selectionFeedback += 1
    }

    var body: some View {
        Section {
            if let exercise {
                NavigationLink {
                    ExerciseDetailView(exercise: exercise)
                } label: {
                    HStack(spacing: 12) {
                        ExerciseDiagramThumbnail(exercise: exercise, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(exercise.title)
                                .font(.headline)
                                .foregroundStyle(IronTheme.primaryText)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                            Text(exercise.primaryMuscleCommonName.first?.capitalized ?? exercise.muscleGroup.capitalized)
                                .font(.subheadline)
                                .foregroundStyle(IronTheme.secondaryText)
                        }
                    }
                }
            }

            Button { showingNoteEditor = true } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Workout Plan Note", systemImage: "list.bullet")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(IronTheme.primaryText)
                    Text(routineExercise.comment.flatMap { $0.isEmpty ? nil : $0 }
                         ?? "Add a cue for this workout plan…")
                        .font(.subheadline)
                        .foregroundStyle(IronTheme.secondaryText)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shown whenever you start this saved workout")

            Button {
                showingRestTimerEditor = true
            } label: {
                LabeledContent("Rest Timer") {
                    Text(restTimerTitle)
                        .font(.ironMetric(.subheadline, weight: .semibold))
                        .foregroundStyle(IronTheme.metricTime)
                        .contentTransition(reduceMotion ? .opacity : .numericText())
                }
            }
            .accessibilityHint("Opens the rest duration picker")

            Picker("Set Type", selection: Binding(get: { trackingType }, set: setTrackingType)) {
                ForEach(SetTrackingType.allCases) { type in Text(type.title).tag(type) }
            }

            ForEach(Array(sets.enumerated()), id: \.element.id) { setIndex, routineSet in
                WorkoutRoutineSetRow(
                    routineSet: routineSet,
                    index: setIndex,
                    trackingType: trackingType,
                    onSave: onSave,
                    onDelete: { onDeleteSet(routineSet) }
                )
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            }
            .onMove { source, destination in
                guard let from = source.first else { return }
                onMoveSet(from, destination > from ? destination - 1 : destination)
            }
            .onDelete { offsets in
                for offset in offsets where sets.indices.contains(offset) {
                    onDeleteSet(sets[offset])
                }
            }

            Button("Add Set", systemImage: "plus", action: onAddSet)
        } header: {
            HStack {
                Text(exercise?.title ?? "Unknown Exercise")
                Spacer()
                Menu {
                    if index > 0 {
                        Button("Move Up", systemImage: "arrow.up", action: onMoveUp)
                    }
                    if index < exerciseCount - 1 {
                        Button("Move Down", systemImage: "arrow.down", action: onMoveDown)
                    }
                    Divider()
                    Button("Delete Exercise", systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                }
                .accessibilityLabel("Actions for \(exercise?.title ?? "exercise")")
            }
        } footer: {
            if sets.isEmpty {
                Text("No target sets yet.")
            }
        }
        .animation(IronMotion.preferred(IronMotion.collapse, reduceMotion: reduceMotion), value: sets.map(\.objectID))
        .sensoryFeedback(.selection, trigger: selectionFeedback) { _, _ in settingsStore.workoutHaptics }
        .onDisappear(perform: onSave)
        .sheet(isPresented: $showingNoteEditor) {
            ExerciseNoteEditorSheet(
                title: "Workout Plan Note",
                subtitle: "Shown whenever you start from this saved workout.",
                text: routineExercise.comment ?? ""
            ) { text in
                onSaveNote(text)
            }
        }
        .sheet(isPresented: $showingRestTimerEditor) {
            RestTimerConfigurationSheet(
                title: "Rest Timer",
                subtitle: "Recovery after each completed set",
                initialDuration: routineExercise.restTimerDurationValue ?? workoutDefaultRestTimerDuration,
                secondaryActionTitle: "Use Workout Default · \(restTimerDurationFormatter.string(from: workoutDefaultRestTimerDuration) ?? "0:00")",
                onSecondaryAction: {
                    routineExercise.restTimerDurationValue = nil
                    onSave()
                },
                onApply: { duration in
                    routineExercise.restTimerDurationValue = duration
                    onSave()
                }
            )
        }
    }
}

private struct WorkoutRoutineSetRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var settingsStore: SettingsStore

    @EnvironmentObject private var trackingDraft: RoutineSetTrackingDraft
    @ObservedObject var routineSet: WorkoutRoutineSet
    @State private var distanceInput: String?
    @AppStorage(SetTrackingPreferences.storageKey) private var trackingPreferencesData: Data?
    @State private var weightInput: String?
    @State private var repetitionsInput: String?
    @State private var showingDurationPicker = false
    @State private var showingPlateCalculator = false
    @State private var selectionFeedback = 0
    @FocusState private var focusedField: EntryField?
    let index: Int
    let trackingType: SetTrackingType
    let onSave: () -> Void
    let onDelete: () -> Void

    private enum EntryField: Hashable {
        case weight
        case repetitions
        case distance
    }

    private var displayedWeightTitle: String {
        guard let weight = routineSet.weightValue else { return "" }
        let displayWeight = WeightUnit.convert(
            weight: weight,
            from: .metric,
            to: settingsStore.weightUnit
        )
        let formatter = focusedField == .weight ? settingsStore.weightUnit.numberFormatter : settingsStore.weightUnit.displayNumberFormatter
        return formatter.string(from: NSNumber(value: displayWeight)) ?? ""
    }

    private var weightText: Binding<String> {
        Binding(
            get: { weightInput ?? displayedWeightTitle },
            set: { input in
                let sanitized = sanitizedDecimalInput(input)
                guard input.isEmpty || !sanitized.isEmpty else { return }
                weightInput = sanitized
                updateWeight(from: sanitized)
            }
        )
    }

    private var repetitionsText: Binding<String> {
        Binding(
            get: { repetitionsInput ?? repetitionsTitle },
            set: { input in
                let sanitized = sanitizedIntegerInput(input)
                guard input.isEmpty || !sanitized.isEmpty else { return }
                repetitionsInput = sanitized
                updateRepetitions(from: sanitized)
            }
        )
    }

    private var plateCalculatorTarget: Double {
        max(
            routineSet.weightValue.map {
                WeightUnit.convert(weight: $0, from: .metric, to: settingsStore.weightUnit)
            } ?? 0,
            settingsStore.weightUnit.barbellWeight
        )
    }

    private func updateWeight(from input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            routineSet.weightValue = nil
            return
        }
        let parsed = settingsStore.weightUnit.numberFormatter.number(from: trimmed)?.doubleValue
            ?? Double(trimmed.replacingOccurrences(of: ",", with: "."))
        guard let parsed = parsed else { return }
        routineSet.weightValue = WeightUnit.convert(
            weight: min(max(parsed, 0), maximumDisplayWeight),
            from: settingsStore.weightUnit,
            to: .metric
        )
    }

    private var maximumDisplayWeight: Double {
        WeightUnit.convert(
            weight: WorkoutSet.MAX_WEIGHT,
            from: .metric,
            to: settingsStore.weightUnit
        )
    }

    private func sanitizedDecimalInput(_ proposedValue: String) -> String {
        let formatter = settingsStore.weightUnit.numberFormatter
        let decimalSeparator = formatter.decimalSeparator
            ?? Locale.current.decimalSeparator
            ?? "."
        let maximumFractionDigits = settingsStore.weightUnit.maximumFractionDigits
        var result = ""
        var hasDecimalSeparator = false
        var fractionDigitCount = 0

        for character in proposedValue {
            if let digit = character.wholeNumberValue {
                if hasDecimalSeparator {
                    guard fractionDigitCount < maximumFractionDigits else { continue }
                    fractionDigitCount += 1
                }
                result.append(contentsOf: String(digit))
            } else if (character == "." || character == "," || String(character) == decimalSeparator),
                      maximumFractionDigits > 0,
                      !hasDecimalSeparator {
                if result.isEmpty {
                    result = "0"
                }
                result.append(contentsOf: decimalSeparator)
                hasDecimalSeparator = true
            }
        }

        if let value = formatter.number(from: result)?.doubleValue,
           value > maximumDisplayWeight {
            return formatter.string(from: NSNumber(value: maximumDisplayWeight)) ?? result
        }
        return result
    }

    private func sanitizedIntegerInput(_ proposedValue: String) -> String {
        let digits = proposedValue.compactMap(\.wholeNumberValue).map(String.init).joined()
        guard let value = Int(digits) else { return "" }
        return String(min(value, Int(WorkoutSet.MAX_REPETITIONS)))
    }

    private var repetitionsTitle: String {
        if let min = routineSet.minRepetitionsValue, let max = routineSet.maxRepetitionsValue {
            return min == max ? "\(max)" : "\(min)-\(max)"
        }
        if let min = routineSet.minRepetitionsValue { return "\(min)+" }
        if let max = routineSet.maxRepetitionsValue { return "<\(max)" }
        return ""
    }

    private func updateRepetitions(from input: String) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            routineSet.minRepetitionsValue = nil
            routineSet.maxRepetitionsValue = nil
            return
        }

        guard let parsed = Int(value) else { return }
        let repetitions = Int16(min(max(parsed, 0), Int(WorkoutSet.MAX_REPETITIONS)))
        routineSet.minRepetitionsValue = repetitions
        routineSet.maxRepetitionsValue = repetitions
    }

    private var setLabel: String {
        switch routineSet.tagValue {
        case .warmUp: return "Warm-Up"
        case .dropSet: return "Drop Set"
        case .failure: return "Failure"
        case nil: return "Set \(index + 1)"
        }
    }

    private var usesAccessibilityLayout: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var setLabelView: some View {
        Text(setLabel)
            .font(.ironMetric(.subheadline, weight: .semibold))
            .foregroundStyle(IronTheme.metricSets)
            .lineLimit(1)
    }

    private var weightField: some View {
        TextField("—", text: weightText, onEditingChanged: { isEditing in
            if isEditing {
                weightInput = displayedWeightTitle
            } else {
                weightInput = nil
                onSave()
            }
        })
        .font(.ironMetric(.body, weight: .semibold))
        .foregroundStyle(IronTheme.metricVolume)
        .keyboardType(.decimalPad)
        .focused($focusedField, equals: .weight)
        .multilineTextAlignment(.trailing)
        .frame(width: usesAccessibilityLayout ? nil : 62)
        .frame(maxWidth: usesAccessibilityLayout ? .infinity : nil)
        .frame(minHeight: IronTheme.controlHeight)
        .accessibilityLabel("Weight")
    }

    private var repetitionsField: some View {
        TextField("—", text: repetitionsText, onEditingChanged: { isEditing in
            if isEditing {
                repetitionsInput = repetitionsTitle
            } else {
                repetitionsInput = nil
                onSave()
            }
        })
        .font(.ironMetric(.body, weight: .semibold))
        .foregroundStyle(IronTheme.metricSets)
        .keyboardType(.numberPad)
        .focused($focusedField, equals: .repetitions)
        .multilineTextAlignment(.trailing)
        .frame(width: usesAccessibilityLayout ? nil : 46)
        .frame(maxWidth: usesAccessibilityLayout ? .infinity : nil)
        .frame(minHeight: IronTheme.controlHeight)
        .accessibilityLabel("Repetitions")
    }

    private var weightUnitLabel: some View {
        Text(trackingType.weightPrefix + settingsStore.weightUnit.unit.symbol)
            .font(.caption)
            .foregroundStyle(IronTheme.secondaryText)
    }

    private var repetitionsUnitLabel: some View {
        Text("reps")
            .font(.caption)
            .foregroundStyle(IronTheme.secondaryText)
    }

    private var durationControl: some View {
        Button {
            showingDurationPicker = true
        } label: {
            Text(SetTrackingType.durationText(routineSet.durationValue ?? 60))
                .font(.ironMetric(.body, weight: .semibold))
                .foregroundStyle(IronTheme.metricTime)
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: routineSet.durationValue)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .frame(minHeight: IronTheme.controlHeight)
        .accessibilityLabel("Set duration")
        .accessibilityValue(SetTrackingType.durationText(routineSet.durationValue ?? 60))
    }

    private var distanceText: Binding<String> {
        Binding(get: {
            if let distanceInput { return distanceInput }
            guard let meters = trackingDraft.distance(for: routineSet.uuid) else { return "" }
            return settingsStore.weightUnit.numberFormatter.string(from: NSNumber(value: WorkoutSet.distanceDisplayValue(meters, weightUnit: settingsStore.weightUnit))) ?? ""
        }, set: { input in
            let sanitized = sanitizedDecimalInput(input)
            guard input.isEmpty || !sanitized.isEmpty else { return }
            distanceInput = sanitized
            let value = settingsStore.weightUnit.numberFormatter.number(from: sanitized)?.doubleValue ?? 0
            guard let setID = routineSet.uuid else { return }
            trackingDraft.setDistance(WorkoutSet.distanceMeters(value, weightUnit: settingsStore.weightUnit), for: setID)
            onSave()
        })
    }
    private var distanceField: some View {
        TextField("—", text: distanceText)
            .font(.ironMetric(.body, weight: .semibold))
            .keyboardType(.decimalPad)
            .focused($focusedField, equals: .distance)
            .multilineTextAlignment(.trailing)
            .frame(minWidth: 44, minHeight: IronTheme.controlHeight)
            .accessibilityLabel("Distance in \(WorkoutSet.distanceUnit(settingsStore.weightUnit))")
    }
    private var weightTitle: String {
        trackingType == .assistedBodyweight ? "Assistance" : (trackingType == .weightedBodyweight ? "Added Weight" : "Weight")
    }
    private var valueControlsLayout: AnyLayout {
        usesAccessibilityLayout ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 6))
    }
    private var setValueControls: some View {
        valueControlsLayout {
            if trackingType.usesWeight {
                HStack(spacing: 4) {
                    if usesAccessibilityLayout { Text(weightTitle).font(.caption) }
                    weightField.accessibilityLabel("\(weightTitle) in \(settingsStore.weightUnit.unit.symbol)")
                    weightUnitLabel
                }
            }
            if trackingType.usesReps {
                HStack(spacing: 4) {
                    repetitionsField
                    repetitionsUnitLabel
                }
            }
            if trackingType.usesDistance {
                HStack(spacing: 4) {
                    distanceField
                    Text(WorkoutSet.distanceUnit(settingsStore.weightUnit)).font(.caption).foregroundStyle(IronTheme.secondaryText)
                }
            }
            if trackingType.usesDuration { durationControl }
        }
    }

    var body: some View {
        Group {
            if usesAccessibilityLayout {
                VStack(alignment: .leading, spacing: 8) {
                    setLabelView
                    setValueControls
                }
            } else {
                HStack(spacing: 12) {
                    setLabelView
                    Spacer(minLength: 8)
                    setValueControls
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: trackingType) { _, _ in
            focusedField = nil
            weightInput = nil
            repetitionsInput = nil
            distanceInput = nil
        }
        .onChange(of: settingsStore.weightUnit) { _, _ in
            focusedField = nil
            weightInput = nil
            distanceInput = nil
        }
        .sensoryFeedback(.selection, trigger: selectionFeedback) { _, _ in settingsStore.workoutHaptics }
        .contextMenu {
            Picker("Set Type", selection: Binding(
                get: { routineSet.tagValue },
                set: { newValue in
                    guard routineSet.tagValue != newValue else { return }
                    routineSet.tagValue = newValue
                    onSave()
                    selectionFeedback += 1
                }
            )) {
                Text("Normal").tag(WorkoutSetTag?.none)
                ForEach(WorkoutRoutineSet.supportedTags, id: \.self) { tag in
                    Text(tag.title.capitalized).tag(WorkoutSetTag?.some(tag))
                }
            }
            Divider()
            Button("Delete Set", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .sheet(isPresented: $showingDurationPicker) {
            IronDurationPickerSheet(
                initialDuration: routineSet.durationValue ?? 60
            ) { duration in
                routineSet.durationValue = duration
                onSave()
            }
        }
        .sheet(isPresented: $showingPlateCalculator) {
            IronUtilitySheet(
                title: "Plate Calculator",
                subtitle: "",
                systemImage: "plusminus",
                showsDone: false,
                onClose: { showingPlateCalculator = false }
            ) {
                PlateCalculatorView(
                    unit: settingsStore.weightUnit,
                    initialTarget: plateCalculatorTarget,
                    exerciseKey: routineSet.workoutRoutineExercise?.exerciseUuid?.uuidString,
                    onClose: { showingPlateCalculator = false },
                    onApply: { value in
                        routineSet.weightValue = WeightUnit.convert(
                            weight: value,
                            from: settingsStore.weightUnit,
                            to: .metric
                        )
                        weightInput = nil
                        onSave()
                        showingPlateCalculator = false
                    }
                )
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .toolbar {
            if focusedField != nil {
                ToolbarItemGroup(placement: .keyboard) {
                    if trackingType.usesWeight, focusedField == .weight {
                        Button("Plate Calculator", systemImage: "plusminus", action: openPlateCalculator)
                            .labelStyle(.iconOnly)
                            .accessibilityHint("Calculates the plates to load for this set")
                    }

                    Spacer()

                    Button("Done") { focusedField = nil }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func openPlateCalculator() {
        focusedField = nil
        DispatchQueue.main.async {
            showingPlateCalculator = true
        }
    }
}

#if DEBUG
struct WorkoutRoutineView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            WorkoutRoutineView(workoutRoutine: MockWorkoutData.metric.workoutRoutine)
                .mockEnvironment(weightUnit: .metric)
        }
    }
}
#endif
