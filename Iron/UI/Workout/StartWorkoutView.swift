//
//  StartWorkoutView.swift
//  Iron
//
//  Created by Karim Abou Zeid on 19.07.19.
//  Rebuilt for Iron's focused workout experience.
//

import SwiftUI
import Charts
import CoreData
import WorkoutDataKit

struct WorkoutPlanEditorRoute: Identifiable {
    enum Kind {
        case create(containerID: NSManagedObjectID?)
        case createFromWorkout(workoutID: NSManagedObjectID, containerID: NSManagedObjectID?)
        case edit(planID: NSManagedObjectID)
        case duplicate(planID: NSManagedObjectID)
    }

    let id = UUID()
    let kind: Kind
}

/// Portable, versioned representation for one saved workout. The wrapper keeps
/// shared files self-describing without coupling the import contract to the
/// Core Data container used by the app.
struct SavedWorkoutDocument: Codable {
    static let currentVersion = 2

    let version: Int
    let workout: WorkoutRoutine
    let trackingPreferences: SetTrackingPreferences?

    init(workout: WorkoutRoutine, defaults: UserDefaults = .standard) {
        version = Self.currentVersion
        self.workout = workout
        let draft = RoutineSetTrackingDraft(defaults: defaults)
        draft.copyTracking(from: workout, to: workout)
        trackingPreferences = draft.changes
    }
}

private struct SavedWorkoutImportResult: Identifiable {
    let id = UUID()
    let importedTitle: String?
    let error: Error?

    var alertTitle: String {
        error == nil ? "Workout imported" : "Could not import workout"
    }

    var message: String {
        if let error {
            return error.localizedDescription
        }
        return "\(importedTitle ?? "Saved workout") is now available in the Workout tab."
    }
}

/// Keeps plan edits isolated until the user explicitly taps Create or Update.
/// A child context gives Cancel real meaning without rolling back unrelated
/// workout changes in the app's shared view context.
final class WorkoutPlanEditorSession: ObservableObject {
    let context: NSManagedObjectContext
    let routine: WorkoutRoutine
    let isNew: Bool
    let trackingDraft: RoutineSetTrackingDraft

    private let parentContext: NSManagedObjectContext
    private let route: WorkoutPlanEditorRoute

    init(parentContext: NSManagedObjectContext, route: WorkoutPlanEditorRoute,
         trackingDefaults: UserDefaults = .standard) throws {
        self.parentContext = parentContext
        self.route = route
        let trackingDraft = RoutineSetTrackingDraft(defaults: trackingDefaults)
        self.trackingDraft = trackingDraft

        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.parent = parentContext
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        self.context = context

        // Resolve against the parent first: a child may still see a snapshot
        // for an object that has been deleted but not yet saved by its parent.
        func load<T: NSManagedObject>(_ id: NSManagedObjectID, as type: T.Type) throws -> T {
            guard let source = try? parentContext.existingObject(with: id) as? T,
                  !source.isDeleted,
                  let draft = try? context.existingObject(with: id) as? T,
                  !draft.isDeleted else {
                throw WorkoutPlanEditorLoadError.unavailable
            }
            return draft
        }

        switch route.kind {
        case .create(let containerID):
            let container: WorkoutPlan
            if let containerID {
                container = try load(containerID, as: WorkoutPlan.self)
            } else {
                container = WorkoutPlan.create(context: context)
            }

            let routine = WorkoutRoutine.create(context: context)
            routine.workoutPlan = container
            self.routine = routine
            self.isNew = true

        case .createFromWorkout(let workoutID, let containerID):
            let source = try load(workoutID, as: Workout.self)
            let container: WorkoutPlan
            if let containerID {
                container = try load(containerID, as: WorkoutPlan.self)
            } else {
                container = WorkoutPlan.create(context: context)
            }

            let routine = WorkoutRoutine.create(context: context)
            routine.workoutPlan = container
            routine.title = source.title ?? "Saved Workout"
            routine.comment = source.comment
            routine.workoutRoutineExercises = NSOrderedSet(
                array: Self.routineExercises(from: source, in: context, trackingDraft: trackingDraft,
                    defaults: trackingDefaults)
            )
            self.routine = routine
            self.isNew = true

        case .edit(let planID):
            self.routine = try load(planID, as: WorkoutRoutine.self)
            self.isNew = false

        case .duplicate(let planID):
            let source = try load(planID, as: WorkoutRoutine.self)
            let routine = source.duplicate(context: context)
            self.routine = routine
            trackingDraft.copyTracking(from: source, to: routine)
            self.isNew = true
        }
    }

    /// Builds a new editable routine in the child context. The completed
    /// session is read only; completion, dates, provenance and Health state
    /// intentionally have no representation in a saved workout.
    private static func routineExercises(
        from workout: Workout,
        in context: NSManagedObjectContext,
        trackingDraft: RoutineSetTrackingDraft,
        defaults: UserDefaults
    ) -> [WorkoutRoutineExercise] {
        let sourceExercises = workout.workoutExercises?.array
            .compactMap { $0 as? WorkoutExercise } ?? []
        var copiedSupersetIDs: [UUID: UUID] = [:]

        return sourceExercises.map { source in
            let copy = WorkoutRoutineExercise.create(context: context)
            copy.exerciseUuid = source.exerciseUuid
            // Keep plan cues; the logged comment belongs only to the source session.
            copy.comment = source.routineNoteSource(defaults: defaults)?.comment
            copy.restTimerDurationValue = source.restTimerDurationValue
            if let id = source.exerciseUuid {
                trackingDraft.setOverride(source.trackingType(catalogExercise: ExerciseStore.shared.exercisesByUUID[id],
                    defaults: defaults), for: id)
            }
            if let sourceSupersetID = source.supersetUuid {
                let copiedSupersetID = copiedSupersetIDs[sourceSupersetID] ?? UUID()
                copiedSupersetIDs[sourceSupersetID] = copiedSupersetID
                copy.supersetUuid = copiedSupersetID
            }

            let copiedSets = (source.workoutSets?.array
                .compactMap { $0 as? WorkoutSet } ?? []).map { sourceSet in
                    let set = WorkoutRoutineSet.create(context: context)
                    let minRepetitions = sourceSet.minTargetRepetitionsValue
                        ?? (sourceSet.repetitionsValue > 0 ? sourceSet.repetitionsValue : nil)
                    let maxRepetitions = sourceSet.maxTargetRepetitionsValue
                        ?? (sourceSet.repetitionsValue > 0 ? sourceSet.repetitionsValue : nil)
                    set.minRepetitionsValue = minRepetitions
                    set.maxRepetitionsValue = maxRepetitions
                    set.weightValue = sourceSet.weightValue
                    set.durationValue = sourceSet.durationValue
                    if let id = set.uuid { trackingDraft.setDistance(sourceSet.distanceValue, for: id) }
                    set.tagValue = sourceSet.tagValue
                    set.comment = sourceSet.comment
                    return set
                }
            copy.workoutRoutineSets = NSOrderedSet(array: copiedSets)
            return copy
        }
    }

    func commit(save: (() throws -> Void)? = nil) throws {
        // Do not save the child into its parent: a failed parent save would
        // leave the child clean and unable to retry its draft. Copy the draft
        // into one reversible parent mutation instead.
        let draft = SavedWorkoutDraft(routine)
        try parentContext.persistMutation(save: { try save?() ?? parentContext.save() }) {
            let target: WorkoutRoutine
            switch route.kind {
            case .edit(let planID):
                guard let existing = try parentContext.existingObject(with: planID) as? WorkoutRoutine,
                      !existing.isDeleted else { throw SavedWorkoutDraftError.missingWorkout }
                target = existing
            case .create(let containerID):
                let container: WorkoutPlan
                if let containerID {
                    guard let existing = try parentContext.existingObject(with: containerID) as? WorkoutPlan,
                          !existing.isDeleted else { throw SavedWorkoutDraftError.missingWorkout }
                    container = existing
                } else {
                    container = WorkoutPlan.create(context: parentContext)
                }
                target = WorkoutRoutine.create(context: parentContext)
                target.workoutPlan = container
            case .createFromWorkout(_, let containerID):
                let container: WorkoutPlan
                if let containerID {
                    guard let existing = try parentContext.existingObject(with: containerID) as? WorkoutPlan,
                          !existing.isDeleted else { throw SavedWorkoutDraftError.missingWorkout }
                    container = existing
                } else {
                    container = WorkoutPlan.create(context: parentContext)
                }
                target = WorkoutRoutine.create(context: parentContext)
                target.workoutPlan = container
            case .duplicate(let planID):
                guard let source = try parentContext.existingObject(with: planID) as? WorkoutRoutine,
                      !source.isDeleted else { throw SavedWorkoutDraftError.missingWorkout }
                target = WorkoutRoutine.create(context: parentContext)
                target.workoutPlan = source.workoutPlan
            }
            draft.apply(to: target, in: parentContext)
        }
        trackingDraft.retainMetadata(for: routine)
        trackingDraft.commit()
    }

    func cancel() {
        context.rollback()
        trackingDraft.discard()
    }
}

enum WorkoutPlanEditorLoadError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "This saved workout or folder is no longer available. Close this editor and select a workout again."
    }
}

private enum SavedWorkoutDraftError: LocalizedError {
    case missingWorkout

    var errorDescription: String? {
        "The saved workout is no longer available. Your draft is still open."
    }
}

/// Copies only the editable plan graph. Existing object identities, the folder,
/// and links from completed workouts are retained when editing a saved workout.
private struct SavedWorkoutDraft {
    private struct Record {
        let objectID: NSManagedObjectID
        let attributes: [String: Any]

        init(_ object: NSManagedObject) {
            objectID = object.objectID
            let keys = object.entity.attributesByName.filter { !$0.value.isTransient }.map(\.key)
            attributes = object.dictionaryWithValues(forKeys: keys)
        }
    }

    private struct ExerciseDraft {
        let record: Record
        let sets: [Record]
    }

    private let record: Record
    private let exercises: [ExerciseDraft]

    init(_ routine: WorkoutRoutine) {
        record = Record(routine)
        exercises = (routine.workoutRoutineExercises?.array as? [WorkoutRoutineExercise] ?? []).map {
            ExerciseDraft(record: Record($0), sets: ($0.workoutRoutineSets?.array as? [WorkoutRoutineSet] ?? []).map(Record.init))
        }
    }

    func apply(to routine: WorkoutRoutine, in context: NSManagedObjectContext) {
        routine.setValuesForKeys(record.attributes)
        let previousExercises = routine.workoutRoutineExercises?.array as? [WorkoutRoutineExercise] ?? []
        let updatedExercises = exercises.map { draft -> WorkoutRoutineExercise in
            let exercise = previousExercises.first { $0.objectID == draft.record.objectID }
                ?? WorkoutRoutineExercise.create(context: context)
            exercise.setValuesForKeys(draft.record.attributes)
            let previousSets = exercise.workoutRoutineSets?.array as? [WorkoutRoutineSet] ?? []
            let updatedSets = draft.sets.map { setDraft -> WorkoutRoutineSet in
                let set = previousSets.first { $0.objectID == setDraft.objectID }
                    ?? WorkoutRoutineSet.create(context: context)
                set.setValuesForKeys(setDraft.attributes)
                return set
            }
            exercise.workoutRoutineSets = NSOrderedSet(array: updatedSets)
            for set in previousSets where !updatedSets.contains(set) { context.delete(set) }
            return exercise
        }
        routine.workoutRoutineExercises = NSOrderedSet(array: updatedExercises)
        for exercise in previousExercises where !updatedExercises.contains(exercise) { context.delete(exercise) }
    }
}

enum SavedWorkoutImporter {
    @discardableResult
    static func importData(
        _ data: Data,
        into parentContext: NSManagedObjectContext,
        trackingDefaults: UserDefaults = .standard,
        save: (() throws -> Void)? = nil
    ) throws -> String {
        let importContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        importContext.parent = parentContext
        importContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        defer { importContext.rollback() }

        let decoder = JSONDecoder()
        if let contextKey = CodingUserInfoKey.managedObjectContextKey {
            decoder.userInfo[contextKey] = importContext
        }
        let document = try decoder.decode(SavedWorkoutDocument.self, from: data)
        guard (1...SavedWorkoutDocument.currentVersion).contains(document.version) else {
            throw SavedWorkoutImportError.unsupportedVersion(document.version)
        }

        let importedTitle = document.workout.displayTitle
        let trackingDraft = RoutineSetTrackingDraft(defaults: trackingDefaults)
        let exercises = document.workout.workoutRoutineExercises?.array as? [WorkoutRoutineExercise] ?? []
        let sets = exercises.flatMap { $0.workoutRoutineSets?.array as? [WorkoutRoutineSet] ?? [] }
        if let metadata = document.trackingPreferences {
            let exerciseIDs = Set(exercises.compactMap { $0.exerciseUuid?.uuidString })
            let setIDs = Set(sets.compactMap { $0.uuid?.uuidString })
            guard SetTrackingPreferences(payload: metadata.dictionaryRepresentation) != nil,
                  metadata.overrides.keys.allSatisfy({ exerciseIDs.contains($0) }),
                  metadata.routineDistances.keys.allSatisfy({ setIDs.contains($0) }) else {
                throw SavedWorkoutImportError.invalidTrackingPreferences
            }
            for exercise in exercises {
                if let id = exercise.exerciseUuid, let type = metadata.overrides[id.uuidString]?.type {
                    trackingDraft.setOverride(type, for: id)
                }
            }
        }
        // Imports are new saved workouts, even when the same file is imported
        // twice. Remap set metadata before replacing the archived identities.
        document.workout.uuid = UUID()
        var supersetIDs: [UUID: UUID] = [:]
        for exercise in exercises {
            exercise.uuid = UUID()
            if let group = exercise.supersetUuid {
                let id = supersetIDs[group] ?? UUID()
                supersetIDs[group] = id
                exercise.supersetUuid = id
            }
            for set in exercise.workoutRoutineSets?.array as? [WorkoutRoutineSet] ?? [] {
                let distance = set.uuid.flatMap { document.trackingPreferences?.routineDistances[$0.uuidString]?.meters }
                let id = UUID()
                set.uuid = id
                if let distance { trackingDraft.setDistance(distance, for: id) }
            }
        }
        let draft = SavedWorkoutDraft(document.workout)
        try parentContext.persistMutation(
            save: {
                if let save { try save() }
                else { try parentContext.save() }
            },
            mutation: {
                let container = WorkoutPlan.create(context: parentContext)
                container.title = "Imported Workouts"
                let routine = WorkoutRoutine.create(context: parentContext)
                routine.workoutPlan = container
                draft.apply(to: routine, in: parentContext)
            }
        )
        trackingDraft.commit()
        return importedTitle
    }
}

private final class WorkoutPlanEditorPresentation: ObservableObject {
    let result: Result<WorkoutPlanEditorSession, Error>

    init(parentContext: NSManagedObjectContext, route: WorkoutPlanEditorRoute) {
        result = Result { try WorkoutPlanEditorSession(parentContext: parentContext, route: route) }
    }
}

private struct WorkoutPlanEditorHost: View {
    @StateObject private var presentation: WorkoutPlanEditorPresentation
    @State private var persistenceError: String?

    let onDismiss: () -> Void

    init(
        parentContext: NSManagedObjectContext,
        route: WorkoutPlanEditorRoute,
        onDismiss: @escaping () -> Void
    ) {
        _presentation = StateObject(
            wrappedValue: WorkoutPlanEditorPresentation(parentContext: parentContext, route: route)
        )
        self.onDismiss = onDismiss
    }

    var body: some View {
        NavigationStack {
            switch presentation.result {
            case .success(let session):
                editor(session)
            case .failure(let error):
                ContentUnavailableView {
                    Label("Workout Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.localizedDescription)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", action: onDismiss)
                    }
                }
            }
        }
    }

    private func editor(_ session: WorkoutPlanEditorSession) -> some View {
        WorkoutRoutineView(
            workoutRoutine: session.routine,
            isNew: session.isNew,
            autosavesChanges: false,
            trackingDraft: session.trackingDraft,
            onCancel: {
                session.cancel()
                onDismiss()
            },
            onCommit: {
                do {
                    try session.commit()
                    onDismiss()
                } catch {
                    persistenceError = "Your workout could not be saved. Try again. \(error.localizedDescription)"
                }
            }
        )
        .environment(\.managedObjectContext, session.context)
        .alert("Workout Not Saved", isPresented: Binding(
            get: { persistenceError != nil },
            set: { if !$0 { persistenceError = nil } }
        )) {
            Button("OK", role: .cancel) { persistenceError = nil }
        } message: {
            Text(persistenceError ?? "Please try again.")
        }
    }
}

struct StartWorkoutView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.managedObjectContext) private var managedObjectContext
    @EnvironmentObject private var exerciseStore: ExerciseStore
    @EnvironmentObject private var sceneState: SceneState
    @ObservedObject private var watchConnection = WatchConnectionManager.shared

    @FetchRequest(fetchRequest: StartWorkoutView.fetchRequest) private var workoutPlans
    @FetchRequest(fetchRequest: Workout.currentWorkoutFetchRequest) private var currentWorkouts
    @FetchRequest(fetchRequest: StartWorkoutView.historyFetchRequest) private var workoutHistory

    var onOpenCurrentWorkout: () -> Void = {}

    @State private var planToDelete: WorkoutRoutine?
    @State private var planEditorRoute: WorkoutPlanEditorRoute?
    @State private var activityItems: [Any]?
    @State private var isShowingWorkoutImporter = false
    @State private var importResult: SavedWorkoutImportResult?
    @State private var persistenceError: String?
    @State private var showingRepeatBlocked = false
    @State private var selectedRecentWorkout: Workout?
    @State private var deletedWorkoutCount = 0

    static var fetchRequest: NSFetchRequest<WorkoutPlan> {
        let request: NSFetchRequest<WorkoutPlan> = WorkoutPlan.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \WorkoutPlan.title, ascending: true)]
        return request
    }

    private static var historyFetchRequest: NSFetchRequest<Workout> {
        let request: NSFetchRequest<Workout> = Workout.fetchRequest()
        request.predicate = NSPredicate(format: "isCurrentWorkout != %@", NSNumber(value: true))
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Workout.start, ascending: false)]
        return request
    }

    private var recentWorkouts: [Workout] {
        Array(workoutHistory.lazy.filter { $0.hasCompletedSets ?? false }.prefix(5))
    }

    /// `WorkoutPlan` is retained as a persistence container for backwards
    /// compatibility. The user-facing plans are its saved workout entries.
    private var plans: [WorkoutRoutine] {
        workoutPlans.flatMap { $0.workoutRoutines?.array as? [WorkoutRoutine] ?? [] }
    }

    private var activeRoutineObjectID: NSManagedObjectID? {
        currentWorkouts.first?.workoutRoutine?.objectID
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    quickStartCard
                        .ironStaggeredEntrance(index: 0)
                }
                .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))

                recentWorkoutsSection

                Section {
                    if plans.isEmpty {
                        ContentUnavailableView {
                            Label("No saved workouts", systemImage: "dumbbell.fill")
                        } description: {
                            Text("Save a workout for push/pull/legs, upper/lower, or any split you train.")
                        } actions: {
                            Button(action: newPlan) {
                                Label("New Workout", systemImage: "plus")
                            }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .controlSize(.large)
                            .labelStyle(.titleAndIcon)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets(top: 24, leading: 16, bottom: 24, trailing: 16))
                    } else {
                        ForEach(Array(plans.enumerated()), id: \.element.objectID) { index, plan in
                            SavedWorkoutRow(
                                workout: plan,
                                onEdit: {
                                    planEditorRoute = WorkoutPlanEditorRoute(
                                        kind: .edit(planID: plan.objectID)
                                    )
                                },
                                onDuplicate: { duplicate(plan) },
                                onDelete: { requestDelete(plan) },
                                onExport: { exportWorkout(plan) },
                                canStartWorkout: currentWorkouts.isEmpty,
                                isActiveWorkout: activeRoutineObjectID == plan.objectID,
                                onWorkoutStarted: onOpenCurrentWorkout,
                                onFailure: { persistenceError = $0.localizedDescription }
                            )
                            .ironStaggeredEntrance(index: index + recentWorkouts.count + 1)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                        }
                    }
                } header: {
                    Text("Saved Workouts")
                }

                if !plans.isEmpty {
                    Section {
                        Button(action: newPlan) {
                            Label("Create Workout", systemImage: "plus")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .animation(IronMotion.preferred(IronMotion.collapse, reduceMotion: reduceMotion), value: plans.map(\.objectID))
            .contentMargins(.bottom, IronTheme.floatingWorkoutBottomClearance, for: .scrollContent)
            .navigationTitle("Workout")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(item: $selectedRecentWorkout) { workout in
                WorkoutDetailView(workout: workout)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("New Workout", systemImage: "plus", action: newPlan)
                        Button("Import Workout", systemImage: "square.and.arrow.down") {
                            isShowingWorkoutImporter = true
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Create or import workout")
                }
            }
            .sheet(item: $planEditorRoute) { route in
                WorkoutPlanEditorHost(
                    parentContext: managedObjectContext,
                    route: route,
                    onDismiss: { planEditorRoute = nil }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .confirmationDialog(
            planToDelete.map { "Delete \($0.displayTitle)?" } ?? "Delete workout?",
            isPresented: Binding(
                get: { planToDelete != nil },
                set: { if !$0 { planToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Workout", role: .destructive) {
                guard let plan = planToDelete else { return }
                planToDelete = nil
                delete(plan)
            }
            Button("Cancel", role: .cancel) {
                planToDelete = nil
            }
        } message: {
            Text("This removes the exercises, targets, and notes saved in this workout. Your completed workout history is not affected.")
        }
        .ironActivitySheet(activityItems: $activityItems)
        .sheet(isPresented: $showingRepeatBlocked) {
            WorkoutRepeatBlockedSheet()
        }
        .sensoryFeedback(.error, trigger: showingRepeatBlocked) { _, blocked in blocked }
        .sensoryFeedback(.error, trigger: persistenceError) { _, error in error != nil }
        .sensoryFeedback(.impact(weight: .medium), trigger: deletedWorkoutCount)
        .fileImporter(
            isPresented: $isShowingWorkoutImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: importWorkout
        )
        .alert(item: $importResult) { result in
            Alert(
                title: Text(result.alertTitle),
                message: Text(result.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert("Workout Not Saved", isPresented: Binding(
            get: { persistenceError != nil },
            set: { if !$0 { persistenceError = nil } }
        )) {
            Button("OK", role: .cancel) { persistenceError = nil }
        } message: {
            Text(persistenceError ?? "Please try again.")
        }
    }

    /// The empty-workout path deserves more than a list row: it is the entry
    /// point for anyone not training a saved routine today.
    @ViewBuilder
    private var quickStartCard: some View {
        if let snapshot = watchConnection.watchWorkoutAwaitingOpen,
           snapshot.workoutID != currentWorkouts.first?.uuid {
            VStack(alignment: .leading, spacing: 14) {
                Label("Workout running on Apple Watch", systemImage: "applewatch")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(IronTheme.secondaryText)
                Text(snapshot.title ?? "Workout")
                    .font(.headline)
                    .foregroundStyle(IronTheme.primaryText)
                HStack(spacing: 4) {
                    Text("Elapsed")
                        .font(.subheadline)
                        .foregroundStyle(IronTheme.secondaryText)
                    Text(snapshot.startDate, style: .timer)
                        .font(.ironMetric(.subheadline, weight: .semibold))
                        .foregroundStyle(IronTheme.metricTime)
                }
                .accessibilityElement(children: .combine)
                if snapshot.exercises.isEmpty {
                    Text("Waiting for Apple Watch…")
                        .font(.subheadline)
                        .foregroundStyle(IronTheme.secondaryText)
                }
                Button {
                    do {
                        try watchConnection.openWatchWorkout(in: managedObjectContext)
                        onOpenCurrentWorkout()
                    } catch { persistenceError = error.localizedDescription }
                } label: {
                    Label("Open on iPhone", systemImage: "iphone")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(!watchConnection.canReplaceEmptyPhoneWorkout(currentWorkouts.first))
                if let current = currentWorkouts.first {
                    Text(watchConnection.canReplaceEmptyPhoneWorkout(current)
                         ? "Replaces the empty workout on this iPhone."
                         : "Finish the workout on this iPhone before opening your Watch workout.")
                        .font(.footnote)
                        .foregroundStyle(IronTheme.secondaryText)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            localQuickStartCard
        }
    }

    private var localQuickStartCard: some View {
        let activeWorkout = currentWorkouts.first
        let isWatchWorkout = activeWorkout.map { watchConnection.wasStartedOnWatch($0) } ?? false
        let isWaitingForWatch = isWatchWorkout && (activeWorkout?.workoutExercises?.count ?? 0) == 0
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return VStack(alignment: .leading, spacing: 14) {
            if isWatchWorkout {
                Label(isWaitingForWatch ? "Workout running on Apple Watch" : "Also on Apple Watch", systemImage: "applewatch")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(IronTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            layout {
                Image(systemName: isWatchWorkout ? "applewatch" : "dumbbell.fill")
                    .font(.headline)
                    .foregroundStyle(IronTheme.accent)
                    .frame(width: 44, height: 44)
                    .background(IronTheme.accentSoft, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(currentWorkouts.first?.displayTitle(in: exerciseStore.exercises) ?? "Empty Workout")
                        .font(.headline)
                        .foregroundStyle(IronTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let workout = currentWorkouts.first {
                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            WorkoutPreviewMetricLine(workout: workout, now: timeline.date)
                        }
                        if isWaitingForWatch {
                            Text("Waiting for Apple Watch…")
                                .font(.subheadline)
                                .foregroundStyle(IronTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("Add exercises as you go")
                            .font(.subheadline)
                            .foregroundStyle(IronTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                if currentWorkouts.isEmpty { startEmptyWorkout() }
                else { onOpenCurrentWorkout() }
            } label: {
                Label(isWatchWorkout ? "Open on iPhone" : (currentWorkouts.isEmpty ? "Start Workout" : "Resume Workout"),
                      systemImage: isWatchWorkout ? "iphone" : "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 50)
            .accessibilityHint(isWatchWorkout ? "Opens the same workout. Edits sync with Apple Watch." : "")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var recentWorkoutsSection: some View {
        if !recentWorkouts.isEmpty {
            Section {
                ForEach(Array(recentWorkouts.enumerated()), id: \.element.objectID) { index, workout in
                    RecentWorkoutRow(
                        workout: workout,
                        onRepeat: { repeatWorkout(workout, blank: $0) },
                        onViewDetails: { selectedRecentWorkout = workout },
                        onSaveAsWorkout: { saveAsWorkout(workout) }
                    )
                    .ironStaggeredEntrance(index: index + 1)
                }
            } header: {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text("Recent Workouts")
                        Spacer()
                        seeAllButton
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recent Workouts")
                        seeAllButton
                    }
                }
                .textCase(nil)
            }
        }
    }

    private var seeAllButton: some View {
        Button("See All") { sceneState.selectedTab = .history }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(IronTheme.accent)
            .frame(minHeight: IronTheme.controlHeight)
            .accessibilityLabel("See all workout history")
    }

    private func repeatWorkout(_ workout: Workout, blank: Bool) {
        do {
            let didStart = try WorkoutRepeater.start(from: workout, blank: blank, sceneState: sceneState)
            showingRepeatBlocked = !didStart
        } catch {
            persistenceError = "The workout was not started. \(error.localizedDescription)"
        }
    }

    private func startEmptyWorkout() {
        do {
            _ = try Workout.startNew(in: managedObjectContext)
            onOpenCurrentWorkout()
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    private func newPlan() {
        planEditorRoute = WorkoutPlanEditorRoute(
            kind: .create(containerID: workoutPlans.first?.objectID)
        )
    }

    private func saveAsWorkout(_ workout: Workout) {
        guard !workout.isDeleted else {
            persistenceError = "This completed workout is no longer available."
            return
        }
        planEditorRoute = WorkoutPlanEditorRoute(
            kind: .createFromWorkout(
                workoutID: workout.objectID,
                containerID: workoutPlans.first?.objectID
            )
        )
    }

    private func duplicate(_ plan: WorkoutRoutine) {
        planEditorRoute = WorkoutPlanEditorRoute(
            kind: .duplicate(planID: plan.objectID)
        )
    }

    private func requestDelete(_ plan: WorkoutRoutine) {
        planToDelete = plan
    }

    private func delete(_ plan: WorkoutRoutine) {
        do {
            try managedObjectContext.persistMutation(save: { try managedObjectContext.save() }) {
                managedObjectContext.delete(plan)
            }
            deletedWorkoutCount += 1
        } catch {
            persistenceError = "The saved workout was not deleted. \(error.localizedDescription)"
        }
    }

    private func exportWorkout(_ workout: WorkoutRoutine) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let exercisesKey = CodingUserInfoKey.exercisesKey {
                encoder.userInfo[exercisesKey] = exerciseStore.exercises
            }
            let data = try encoder.encode(SavedWorkoutDocument(workout: workout))
            let filename = sanitizedFilename(workout.displayTitle) + ".ironworkout.json"
            activityItems = [try temporaryFile(data: data, name: filename)]
        } catch {
            importResult = SavedWorkoutImportResult(importedTitle: nil, error: error)
        }
    }

    private func importWorkout(_ selection: Result<[URL], Error>) {
        if case .failure(let error) = selection,
           (error as NSError).code == NSUserCancelledError {
            return
        }

        do {
            guard let url = try selection.get().first else { return }
            let isSecurityScoped = url.startAccessingSecurityScopedResource()
            defer {
                if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: url)

            let importedTitle = try SavedWorkoutImporter.importData(
                data,
                into: managedObjectContext
            )
            importResult = SavedWorkoutImportResult(
                importedTitle: importedTitle,
                error: nil
            )
        } catch {
            importResult = SavedWorkoutImportResult(importedTitle: nil, error: error)
        }
    }

    private func sanitizedFilename(_ title: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r")
        let sanitized = title.components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Light Workout" : sanitized
    }

    private func temporaryFile(data: Data, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }
}

enum SavedWorkoutImportError: LocalizedError {
    case unsupportedVersion(Int)
    case invalidTrackingPreferences

    var errorDescription: String? {
        switch self {
        case .invalidTrackingPreferences:
            return "This workout file contains invalid set tracking preferences."
        case .unsupportedVersion(let version):
            return "This Light workout file uses version \(version), which this build cannot import yet."
        }
    }
}

private enum WorkoutPlanTrendMetric: String, CaseIterable, Identifiable {
    case volume
    case repetitions
    case duration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .volume: return "Volume"
        case .repetitions: return "Reps"
        case .duration: return "Duration"
        }
    }

    var color: Color {
        switch self {
        case .volume: return IronTheme.metricVolume
        case .repetitions: return IronTheme.metricSets
        case .duration: return IronTheme.metricTime
        }
    }

    var icon: String {
        switch self {
        case .volume: return "scalemass.fill"
        case .repetitions: return "arrow.triangle.2.circlepath"
        case .duration: return "timer"
        }
    }
}

private struct WorkoutPlanTrendPoint: Identifiable {
    let id: NSManagedObjectID
    let date: Date
    let value: Double
    let duration: TimeInterval?
    let totalVolume: Double
    let completedSets: Int
    let repetitions: Int
}

private struct WorkoutPlanTrendChart: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var hasAppeared = false
    let points: [WorkoutPlanTrendPoint]
    let valueFormatter: (Double) -> String
    let valueText: (Double) -> Text
    let metricTitle: String
    let metricColor: Color
    let volumeFormatter: (Double) -> String

    @State private var selectedPointID: WorkoutPlanTrendPoint.ID?

    private var selectedPoint: WorkoutPlanTrendPoint? {
        guard let selectedPointID else { return nil }
        return points.first { $0.id == selectedPointID }
    }

    private func dateLabel(_ date: Date) -> String {
        Workout.dateFormatter.string(from: date)
    }

    private func durationLabel(_ duration: TimeInterval?) -> String {
        guard let duration else { return "—" }
        return Workout.durationFormatter.string(from: duration) ?? "—"
    }

    private var accessibilityValue: String {
        guard let selectedPoint,
              let index = points.firstIndex(where: { $0.id == selectedPoint.id }) else {
            let sessionLabel = points.count == 1 ? "1 session" : String(points.count) + " sessions"
            return sessionLabel + ". Select a session to hear its details."
        }

        return dateLabel(selectedPoint.date) + ", "
            + metricTitle + " " + valueFormatter(selectedPoint.value) + "; "
            + "duration " + durationLabel(selectedPoint.duration) + ", "
            + "volume " + volumeFormatter(selectedPoint.totalVolume) + ", "
            + String(selectedPoint.completedSets) + " sets, "
            + String(selectedPoint.repetitions) + " repetitions; session "
            + String(index + 1) + " of " + String(points.count)
    }

    private func adjustSelection(_ direction: AccessibilityAdjustmentDirection) {
        guard !points.isEmpty else { return }

        let currentIndex = selectedPointID.flatMap { id in
            points.firstIndex { $0.id == id }
        }
        let targetIndex: Int
        switch direction {
        case .increment:
            targetIndex = min((currentIndex ?? -1) + 1, points.count - 1)
        case .decrement:
            targetIndex = max((currentIndex ?? points.count) - 1, 0)
        @unknown default:
            return
        }

        withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) {
            selectedPointID = points[targetIndex].id
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let shown = selectedPoint ?? points.last {
                IronChartHeader(
                    caption: selectedPoint == nil ? "Latest" : "Session",
                    value: valueText(shown.value),
                    detail: "\(dateLabel(shown.date)) · \(shown.completedSets) sets · \(durationLabel(shown.duration))"
                )
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: shown.id)
            }
            chart
        }
    }

    private var chart: some View {
        Chart(points) { point in
            let emphasis = IronChartEmphasis.opacity(isSelected: point.id == selectedPointID, hasSelection: selectedPointID != nil)
            LineMark(
                x: .value("Date", point.date),
                y: .value(metricTitle, hasAppeared || reduceMotion ? point.value : 0)
            )
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .foregroundStyle(metricColor.opacity(selectedPointID == nil ? 1 : IronChartEmphasis.dimmed))

            PointMark(
                x: .value("Date", point.date),
                y: .value(metricTitle, hasAppeared || reduceMotion ? point.value : 0)
            )
            .symbolSize(point.id == selectedPointID ? 64 : 24)
            .foregroundStyle(metricColor.opacity(emphasis))

            if let selectedPoint, selectedPoint.id == point.id {
                IronChartSelectionRule(date: selectedPoint.date)
            }
        }
        .chartYScale(domain: 0...max((points.map(\.value).max() ?? 0) * 1.1, 1))
        .opacity(!reduceMotion || hasAppeared ? 1 : 0)
        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: hasAppeared)
        .onAppear { hasAppeared = true }
        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: metricTitle)
        .ironValueAxis(.automatic(desiredCount: 3), label: valueFormatter)
        .ironDateAxis(.automatic(desiredCount: 3), format: .dateTime.month(.abbreviated).day())
        .chartXSelection(value: Binding(
            get: { selectedPoint?.date },
            set: { newDate in
                guard let newDate else {
                    selectedPointID = nil
                    return
                }
                selectedPointID = points.min {
                    abs($0.date.timeIntervalSince(newDate)) < abs($1.date.timeIntervalSince(newDate))
                }?.id
            }
        ))
        .ironHorizontalChartScrubbing { selectedPointID = nil }
        .frame(height: dynamicTypeSize.isAccessibilitySize ? 260 : 150)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Training trend chart with \(points.count) sessions")
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction(adjustSelection)
    }

}

private struct WorkoutPlanDetailView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.managedObjectContext) private var managedObjectContext
    @EnvironmentObject private var exerciseStore: ExerciseStore
    @EnvironmentObject private var settingsStore: SettingsStore

    @ObservedObject var plan: WorkoutRoutine
    let canStartWorkout: Bool
    let isActiveWorkout: Bool
    let onEdit: () -> Void
    let onWorkoutStarted: () -> Void
    let onFailure: (Error) -> Void

    @State private var selectedMetric: WorkoutPlanTrendMetric = .volume

    private var planExercises: [WorkoutRoutineExercise] {
        plan.workoutRoutineExercises?.array as? [WorkoutRoutineExercise] ?? []
    }

    private var completedWorkouts: [Workout] {
        (plan.workouts?.compactMap { $0 as? Workout } ?? [])
            .filter { !$0.isCurrentWorkout && ($0.hasCompletedSets ?? false) }
            .sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }
    }

    private var chartWorkouts: [Workout] {
        Array(completedWorkouts.prefix(8).reversed())
    }

    private var trendPoints: [WorkoutPlanTrendPoint] {
        chartWorkouts.map { workout in
            WorkoutPlanTrendPoint(
                id: workout.objectID,
                date: workout.start ?? .distantPast,
                value: metricValue(for: workout),
                duration: workout.duration,
                totalVolume: workout.trackedCompletedVolume,
                completedSets: workout.numberOfCompletedSets ?? 0,
                repetitions: totalRepetitions(for: workout)
            )
        }
    }

    private var totalVolume: Double {
        completedWorkouts.reduce(0) { $0 + ($1.trackedCompletedVolume) }
    }

    private var latestWorkout: Workout? { completedWorkouts.first }

    var body: some View {
        List {
            Section {
                Button(action: startWorkout) {
                    Label(
                        isActiveWorkout
                            ? "Resume Workout"
                            : (canStartWorkout ? "Start Workout" : "Finish Current Workout First"),
                        systemImage: isActiveWorkout || canStartWorkout ? "play.fill" : "lock.fill"
                    )
                }
                .fontWeight(.semibold)
                .disabled(!isActiveWorkout && (!canStartWorkout || planExercises.isEmpty))
            } footer: {
                if let comment = plan.comment, !comment.isEmpty {
                    Text(comment)
                }
            }

            Section("Summary") {
                LabeledContent("Sessions") {
                    Text("\(completedWorkouts.count)")
                        .font(.ironMetric(.body))
                        .foregroundStyle(IronTheme.accent)
                }
                LabeledContent("Last Trained", value: latestWorkoutDate)
                LabeledContent("Total Volume") {
                    volumeText(totalVolume).font(.ironMetric(.body))
                }
            }

            trendSection

            exerciseSection

            if !completedWorkouts.isEmpty {
                Section("Recent Sessions") {
                    ForEach(completedWorkouts.prefix(4), id: \.objectID) { workout in
                        NavigationLink {
                            WorkoutDetailView(workout: workout)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Workout.dateFormatter.string(from: workout.start, fallback: "Unknown date"))
                                (Text("^[\(workout.numberOfCompletedSets ?? 0) set](inflect: true)").foregroundColor(IronTheme.metricSets)
                                 + Text(" · ").foregroundColor(IronTheme.secondaryText)
                                 + volumeText(workout.trackedCompletedVolume)
                                 + Text(" · ").foregroundColor(IronTheme.secondaryText)
                                 + Text(workout.duration.flatMap { Workout.durationFormatter.string(from: $0) } ?? "—").foregroundColor(IronTheme.metricTime))
                                    .font(.ironMetric(.caption, weight: .semibold))
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.bottom, isActiveWorkout ? IronTheme.floatingWorkoutBottomClearance : 24, for: .scrollContent)
        .navigationTitle(plan.displayTitle)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit", action: onEdit)
            }
        }
    }

    @ViewBuilder
    private var trendSection: some View {
        Section {
            if trendPoints.isEmpty {
                ContentUnavailableView(
                    "No Trend Yet",
                    systemImage: "chart.xyaxis.line",
                    description: Text("Volume, repetitions, and duration appear here after your first saved session.")
                )
                .listRowBackground(Color.clear)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Metric", selection: $selectedMetric) {
                        ForEach(WorkoutPlanTrendMetric.allCases) { metric in
                            Text(metric.title).tag(metric)
                        }
                    }
                    .pickerStyle(.segmented)
                    .sensoryFeedback(.selection, trigger: selectedMetric) { _, _ in SettingsStore.shared.workoutHaptics }

                    WorkoutPlanTrendChart(
                        points: trendPoints,
                        valueFormatter: chartValueLabel,
                        valueText: metricValueText,
                        metricTitle: selectedMetric.title,
                        metricColor: selectedMetric.color,
                        volumeFormatter: displayWeight
                    )
                }
                .padding(.vertical, 6)

            }
        } header: {
            Text("Training Trend")
        } footer: {
            if !trendPoints.isEmpty {
                Text("Latest \(selectedMetric.title.lowercased()) across your last \(trendPoints.count) session\(trendPoints.count == 1 ? "" : "s").")
            }
        }
    }

    @ViewBuilder
    private var exerciseSection: some View {
        Section("Exercises") {
            if planExercises.isEmpty {
                Button("Add Exercises", systemImage: "plus", action: onEdit)
            } else {
                ForEach(planExercises, id: \.id) { planExercise in
                    planExerciseRow(planExercise)
                }
            }
        }
    }

    @ViewBuilder
    private func planExerciseRow(_ planExercise: WorkoutRoutineExercise) -> some View {
        let exercise = planExercise.exercise(in: exerciseStore.exercises)
        let sets = planExercise.workoutRoutineSets?.array as? [WorkoutRoutineSet] ?? []
        let summary: Text = sets.isEmpty
            ? Text("No target sets").foregroundColor(IronTheme.secondaryText)
            : sets.enumerated().map { targetSetSummary($0.element, index: $0.offset) }
                .reduce(Text("")) { result, next in result + next + Text("  ") }

        if let exercise {
            NavigationLink {
                ExerciseDetailView(exercise: exercise)
            } label: {
                HStack(spacing: 12) {
                    ExerciseDiagramThumbnail(exercise: exercise, size: 40)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(exercise.title)
                            .lineLimit(2)
                        summary
                            .font(.ironMetric(.caption, weight: .semibold))
                            .lineLimit(2)
                        if let rest = planExercise.restTimerDurationValue {
                            Text(restTimerText(rest))
                                .font(.ironMetric(.caption2, weight: .semibold))
                                .foregroundStyle(IronTheme.metricTime)
                        }
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Unknown Exercise")
                summary
                    .font(.ironMetric(.caption, weight: .semibold))
            }
        }
    }

    private func targetSetSummary(_ set: WorkoutRoutineSet, index: Int) -> Text {
        Text(targetSetLabel(set, index: index) + ": ").foregroundColor(IronTheme.metricSets)
            + targetSetText(set)
    }

    private func targetSetLabel(_ set: WorkoutRoutineSet, index: Int) -> String {
        switch set.tagValue {
        case .warmUp: return "W"
        case .dropSet: return "D"
        case .failure: return "F"
        case nil: return "\(index + 1)"
        }
    }

    private func startWorkout() {
        if isActiveWorkout {
            onWorkoutStarted()
            return
        }
        guard canStartWorkout, !planExercises.isEmpty else { return }
        do {
            _ = try Workout.startNew(in: managedObjectContext, routine: plan)
            onWorkoutStarted()
        } catch {
            onFailure(error)
        }
    }

    private func metricValue(for workout: Workout) -> Double {
        switch selectedMetric {
        case .volume:
            return WeightUnit.convert(
                weight: workout.trackedCompletedVolume,
                from: .metric,
                to: settingsStore.weightUnit
            )
        case .repetitions:
            return Double(totalRepetitions(for: workout))
        case .duration:
            return (workout.duration ?? 0) / 60
        }
    }

    private func totalRepetitions(for workout: Workout) -> Int {
        (workout.workoutExercises?.array as? [WorkoutExercise] ?? [])
            .reduce(0) { $0 + ($1.numberOfCompletedRepetitions ?? 0) }
    }

    private func chartValueLabel(_ value: Double) -> String {
        switch selectedMetric {
        case .volume:
            return (settingsStore.weightUnit.displayNumberFormatter.string(from: value as NSNumber) ?? "—")
                + " " + settingsStore.weightUnit.unit.symbol
        case .repetitions:
            return String(format: "%.0f", value)
        case .duration:
            if value >= 60 { return String(format: "%.1fh", value / 60) }
            return String(format: "%.0fm", value)
        }
    }

    private func metricValueText(_ value: Double) -> Text {
        switch selectedMetric {
        case .volume:
            return IronChartText.value(settingsStore.weightUnit.displayNumberFormatter.string(from: value as NSNumber) ?? "—",
                                       unit: settingsStore.weightUnit.unit.symbol, tint: IronTheme.metricVolume)
        case .repetitions:
            return IronChartText.value(String(format: "%.0f", value), unit: "reps", tint: selectedMetric.color)
        case .duration:
            return IronChartText.value(chartValueLabel(value), tint: selectedMetric.color)
        }
    }

    private var latestWorkoutDate: String {
        guard let date = latestWorkout?.start else { return "—" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter.string(from: date)
    }

    private func displayWeight(_ kilograms: Double) -> String {
        WeightUnit.format(weight: kilograms, from: .metric, to: settingsStore.weightUnit)
    }

    private func volumeText(_ kilograms: Double) -> Text {
        let display = WeightUnit.convert(weight: kilograms, from: .metric, to: settingsStore.weightUnit)
        return Text(settingsStore.weightUnit.displayNumberFormatter.string(from: display as NSNumber) ?? "—")
            .foregroundColor(IronTheme.metricVolume)
            + Text(" " + settingsStore.weightUnit.unit.symbol).font(.caption).foregroundColor(IronTheme.secondaryText)
    }

    private func restTimerText(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return "Rest \(formatter.string(from: duration) ?? "Off")"
    }

    private func targetSetText(_ set: WorkoutRoutineSet) -> Text {
        if let duration = set.durationValue {
            let durationTitle = targetDurationText(duration)
            guard let kilograms = set.weightValue else { return Text(durationTitle).foregroundColor(IronTheme.metricTime) }
            let display = WeightUnit.convert(weight: kilograms, from: .metric, to: settingsStore.weightUnit)
            let weight = settingsStore.weightUnit.displayNumberFormatter.string(from: NSNumber(value: display)) ?? "—"
            return Text(weight).foregroundColor(IronTheme.metricVolume)
                + Text(" " + settingsStore.weightUnit.unit.symbol).font(.caption2).foregroundColor(IronTheme.secondaryText)
                + Text(" · ") + Text(durationTitle).foregroundColor(IronTheme.metricTime)
        }

        let repetitions: String
        if let min = set.minRepetitionsValue, let max = set.maxRepetitionsValue {
            repetitions = min == max ? "\(max)" : "\(min)-\(max)"
        } else if let min = set.minRepetitionsValue {
            repetitions = "\(min)+"
        } else if let max = set.maxRepetitionsValue {
            repetitions = "<\(max)"
        } else {
            repetitions = "—"
        }

        guard let kilograms = set.weightValue else { return Text(repetitions).foregroundColor(IronTheme.metricSets) }
        let display = WeightUnit.convert(weight: kilograms, from: .metric, to: settingsStore.weightUnit)
        let weight = settingsStore.weightUnit.displayNumberFormatter.string(from: NSNumber(value: display)) ?? "—"
        return Text(weight).foregroundColor(IronTheme.metricVolume)
            + Text(" " + settingsStore.weightUnit.unit.symbol).font(.caption2).foregroundColor(IronTheme.secondaryText)
            + Text(" × ") + Text(repetitions).foregroundColor(IronTheme.metricSets)
    }

    private func targetDurationText(_ seconds: TimeInterval) -> String {
        let roundedSeconds = Int(max(seconds, 0).rounded())
        let hours = roundedSeconds / 3_600
        let minutes = (roundedSeconds % 3_600) / 60
        let remainingSeconds = roundedSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

private struct SavedWorkoutRow: View {
    @Environment(\.managedObjectContext) private var managedObjectContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var exerciseStore: ExerciseStore

    @ObservedObject var workout: WorkoutRoutine
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    let onExport: () -> Void
    let canStartWorkout: Bool
    let isActiveWorkout: Bool
    let onWorkoutStarted: () -> Void
    let onFailure: (Error) -> Void

    private var workoutExercises: [WorkoutRoutineExercise] {
        workout.workoutRoutineExercises?.array as? [WorkoutRoutineExercise] ?? []
    }

    private var lastPerformed: String {
        let lastDate = (workout.workouts?.compactMap { $0 as? Workout } ?? [])
            .filter { !$0.isCurrentWorkout && ($0.hasCompletedSets ?? false) }
            .compactMap(\.start).max()
        guard let lastDate else { return "Never done" }
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return "Last done \(formatter.localizedString(for: lastDate, relativeTo: Date()))"
    }

    private var muscleGroups: [String] {
        var groups: [String] = []
        for exercise in workoutExercises {
            guard let group = exercise.exercise(in: exerciseStore.exercises)?.muscleGroup,
                  !group.isEmpty, group.lowercased() != "other" else { continue }
            let title = Exercise.displayName(forMuscleGroup: group)
            if !groups.contains(title) { groups.append(title) }
        }
        return Array(groups.prefix(3))
    }

    private var canStart: Bool {
        !workoutExercises.isEmpty && (isActiveWorkout || canStartWorkout)
    }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            NavigationLink {
                WorkoutPlanDetailView(
                    plan: workout,
                    canStartWorkout: canStartWorkout,
                    isActiveWorkout: isActiveWorkout,
                    onEdit: onEdit,
                    onWorkoutStarted: onWorkoutStarted,
                    onFailure: onFailure
                )
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(workout.displayTitle)
                            .font(.headline)
                            .foregroundStyle(IronTheme.primaryText)
                        (Text("\(workoutExercises.count)").font(.ironMetric(.subheadline, weight: .semibold))
                         + Text(" exercise\(workoutExercises.count == 1 ? "" : "s") · \(lastPerformed)"))
                            .font(.subheadline)
                            .foregroundStyle(IronTheme.secondaryText)
                        muscleTags
                    }

                    Spacer(minLength: 0)

                    if isActiveWorkout {
                        Text("Active")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(IronTheme.accent)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            startButton
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            Button("Edit", systemImage: "pencil", action: onEdit)
                .tint(IronTheme.secondaryText)
        }
        .swipeActions(edge: .leading) {
            if workoutExercises.isEmpty {
                Button("Add Exercises", systemImage: "plus", action: onEdit)
                    .tint(IronTheme.accent)
            } else {
                Button(isActiveWorkout ? "Resume" : "Start", systemImage: "play.fill", action: start)
                    .tint(IronTheme.accent)
                    .disabled(!isActiveWorkout && !canStartWorkout)
            }
        }
        .contextMenu {
            if !workoutExercises.isEmpty {
                Button(isActiveWorkout ? "Resume Workout" : "Start Workout", systemImage: "play.fill", action: start)
                    .disabled(!isActiveWorkout && !canStartWorkout)
            }
            Button("Edit Workout", systemImage: "pencil", action: onEdit)
            Button("Duplicate Workout", systemImage: "doc.on.doc", action: onDuplicate)
            Button("Share Workout", systemImage: "square.and.arrow.up", action: onExport)
            Divider()
            Button("Delete Workout", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }

    /// Starting is the primary reason to open this screen, so it gets a visible
    /// control rather than living only in the swipe and context menus.
    private var startButton: some View {
        Button(action: start) {
            Text(isActiveWorkout ? "Resume" : "Start")
                .font(.subheadline.weight(.semibold))
                .fixedSize()
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .frame(minHeight: 30)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .disabled(!canStart)
        .accessibilityLabel(isActiveWorkout ? "Resume \(workout.displayTitle)" : "Start \(workout.displayTitle)")
    }

    private var muscleTags: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 4))
        return ViewThatFits(in: .horizontal) {
            layout {
                ForEach(muscleGroups, id: \.self) { muscleTag($0) }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(muscleGroups, id: \.self) { muscleTag($0) }
            }
        }
    }

    private func muscleTag(_ title: String) -> some View {
        ExerciseLibraryTag(title: title)
    }

    private func start() {
        if isActiveWorkout {
            onWorkoutStarted()
            return
        }
        do {
            _ = try Workout.startNew(in: managedObjectContext, routine: workout)
            onWorkoutStarted()
        } catch {
            onFailure(error)
        }
    }
}

private struct RecentWorkoutRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var exerciseStore: ExerciseStore
    @ObservedObject var workout: Workout
    let onRepeat: (Bool) -> Void
    let onViewDetails: () -> Void
    let onSaveAsWorkout: () -> Void

    private var title: String { workout.displayTitle(in: exerciseStore.exercises) }

    private var metadata: String {
        let date = WorkoutPreviewFormatting.date(workout.start)
        let muscles = workout.muscleGroups(in: exerciseStore.exercises)
            .filter { !$0.isEmpty && $0.lowercased() != "other" }
            .prefix(3).map { Exercise.displayName(forMuscleGroup: $0) }
            .joined(separator: ", ")
        return muscles.isEmpty ? date : "\(date) · \(muscles)"
    }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            Button(action: onViewDetails) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(IronTheme.primaryText)
                    Text(metadata)
                        .font(.subheadline)
                        .foregroundStyle(IronTheme.secondaryText)
                    WorkoutPreviewMetricLine(workout: workout)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("View details for \(title)")

            Button { onRepeat(false) } label: {
                Text("Repeat")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(IronTheme.accent)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: IronTheme.compactCornerRadius))
            .controlSize(.small)
            .frame(minHeight: IronTheme.controlHeight)
            .contentShape(Rectangle())
            .fixedSize()
            .accessibilityLabel("Repeat \(title)")
        }
        .contextMenu {
            Button("Save as Workout…", systemImage: "plus", action: onSaveAsWorkout)
            Button("Repeat", systemImage: "arrow.clockwise") { onRepeat(false) }
            Button("Repeat with Blank Sets", systemImage: "doc") { onRepeat(true) }
            Button("View Details", systemImage: "info.circle", action: onViewDetails)
        }
    }
}

private struct WorkoutPreviewMetricLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var settingsStore: SettingsStore
    @ObservedObject var workout: Workout
    var now: Date = .now

    private var duration: String {
        let seconds = Int(max(workout.isCurrentWorkout
            ? now.timeIntervalSince(workout.start ?? now)
            : workout.duration ?? 0, 0))
        if seconds >= 3_600 {
            return String(format: "%dh %02dm", seconds / 3_600, (seconds % 3_600) / 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        let value = WeightUnit.convert(weight: workout.trackedCompletedVolume, from: .metric, to: settingsStore.weightUnit)
        let volume = WorkoutPreviewFormatting.volume(value)
        IronWorkoutMetricLine(
            duration: duration, sets: workout.numberOfCompletedSets ?? 0,
            volume: volume, unit: settingsStore.weightUnit.unit.symbol
        )
            .contentTransition(reduceMotion ? .opacity : .numericText())
            .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: duration)
            .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: volume)
            .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: workout.numberOfCompletedSets)
            .accessibilityElement(children: .combine)
    }
}

enum WorkoutPreviewFormatting {
    static func date(_ date: Date?) -> String {
        guard let date else { return "Unknown date" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(
            calendar.component(.year, from: date) == calendar.component(.year, from: Date())
                ? "EEE, MMM d" : "MMM d, yyyy"
        )
        return formatter.string(from: date)
    }

    static func volume(_ value: Double) -> String {
        if value >= 10_000 {
            return (value / 1_000).formatted(.number.precision(.fractionLength(1))) + "k"
        }
        return value.formatted(.number.precision(.fractionLength(0)).grouping(.automatic))
    }
}

/// Both history entry points and the Workout tab use the model's transactional
/// start path, including Watch and Live Activity updates after a successful save.
enum WorkoutRepeater {
    @discardableResult
    static func start(from workout: Workout, blank: Bool, sceneState: SceneState) throws -> Bool {
        do {
            _ = try Workout.startRepeating(workout, blank: blank)
        } catch Workout.StartError.workoutAlreadyActive {
            return false
        }
        sceneState.selectedTab = .workout
        sceneState.isCurrentWorkoutExpanded = true
        return true
    }
}

struct WorkoutRepeatBlockedSheet: View {
    var body: some View {
        IronStatusSheet(
            headerTitle: "Workout in progress",
            title: "Finish your current workout first",
            message: "Your active workout is safely stored on this iPhone. Finish or discard it before repeating another session.",
            systemImage: "figure.strengthtraining.traditional",
            tint: IronTheme.warning,
            actionTitle: "Got It"
        )
        .presentationDetents([.height(390), .medium])
        .presentationDragIndicator(.visible)
    }
}

#if DEBUG
struct StartWorkoutView_Previews: PreviewProvider {
    static var previews: some View {
        StartWorkoutView()
            .mockEnvironment(weightUnit: .metric)
    }
}
#endif
