//
//  Workout+Logic.swift
//  Iron
//
//  Created by Karim Abou Zeid on 21.12.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import Foundation
import ActivityKit
import UIKit
import WorkoutDataKit
import os.log

extension Workout {
    /// Kept outside Core Data's schema and independent of Health test/export state.
    var wasStartedOnWatch: Bool { WatchConnectionManager.shared.wasStartedOnWatch(self) }

    // TODO: would be better when SettingsStore, WatchConnectionManager, RestTimerStore etc are injected

    enum StartError: LocalizedError {
        case workoutAlreadyActive
        case workoutUnavailable

        var errorDescription: String? {
            switch self {
            case .workoutAlreadyActive:
                return "A workout is already active. Finish or discard it before starting another."
            case .workoutUnavailable:
                return "This workout is no longer available."
            }
        }
    }

    /// Create the log and its sets inside the save boundary so a failed start
    /// cannot leave an orphan history entry or partially copied routine.
    static func startNew(
        in context: NSManagedObjectContext,
        routine: WorkoutRoutine? = nil,
        notesDefaults: UserDefaults = .standard,
        save: (() throws -> Void)? = nil
    ) throws -> Workout {
        if let routine, routine.managedObjectContext !== context || routine.isDeleted {
            throw StartError.workoutUnavailable
        }
        return try startCreatedWorkout(in: context, save: save, afterSave: { workout in
            let sources = routine?.workoutRoutineExercises?.array as? [WorkoutRoutineExercise] ?? []
            let destinations = workout.workoutExercises?.array as? [WorkoutExercise] ?? []
            for (source, destination) in zip(sources, destinations) {
                if let id = destination.uuid {
                    WorkoutRoutineNoteLinks.setRoutineExerciseID(source.uuid, for: id, defaults: notesDefaults)
                }
            }
        }) {
            guard let routine else { return Workout.create(context: context) }
            let workout = routine.createWorkout(context: context)
            let sources = routine.workoutRoutineExercises?.array as? [WorkoutRoutineExercise] ?? []
            let destinations = workout.workoutExercises?.array as? [WorkoutExercise] ?? []
            for (source, destination) in zip(sources, destinations) {
                // Plan cues are displayed through their source; this field belongs only to this session.
                destination.comment = nil
                let type = source.setTrackingType
                let targets = source.workoutRoutineSets?.array as? [WorkoutRoutineSet] ?? []
                let sets = destination.workoutSets?.array as? [WorkoutSet] ?? []
                for (target, set) in zip(targets, sets) {
                    set.distanceValue = type.usesDistance ? SetTrackingPreferences.routineDistance(for: target.uuid) : nil
                    if type.usesReps { set.repetitionsValue = target.maxRepetitionsValue ?? target.minRepetitionsValue ?? 5 }
                    set.prepare(for: type)
                }
            }
            return workout
        }
    }

    static func startRepeating(_ source: Workout, blank: Bool, trackingDefaults: UserDefaults = .standard,
                               save: (() throws -> Void)? = nil) throws -> Workout {
        guard let context = source.managedObjectContext, !source.isDeleted else {
            throw StartError.workoutUnavailable
        }
        let trackingDraft = source.repeatTrackingDraft(defaults: trackingDefaults)
        return try startCreatedWorkout(in: context, save: save, afterSave: { workout in
            trackingDraft.commit()
            let sources = source.workoutExercises?.array as? [WorkoutExercise] ?? []
            let destinations = workout.workoutExercises?.array as? [WorkoutExercise] ?? []
            for (original, destination) in zip(sources, destinations) {
                if let id = destination.uuid {
                    WorkoutRoutineNoteLinks.setRoutineExerciseID(
                        original.routineNoteSource(defaults: trackingDefaults)?.uuid,
                        for: id, defaults: trackingDefaults)
                }
            }
        }) {
            guard let copy = source.copyForRepeat(blank: blank) else { throw StartError.workoutUnavailable }
            return copy
        }
    }

    /// Call only after the workout save succeeds; defaults cannot roll back with Core Data.
    func persistRoutineNoteLinks(defaults: UserDefaults = .standard) {
        for exercise in workoutExercises?.array as? [WorkoutExercise] ?? [] {
            guard let id = exercise.uuid,
                  WorkoutRoutineNoteLinks.routineExerciseID(for: id, defaults: defaults) == nil,
                  let sourceID = exercise.routineNoteSource(defaults: defaults)?.uuid else { continue }
            WorkoutRoutineNoteLinks.setRoutineExerciseID(sourceID, for: id, defaults: defaults)
        }
    }

    private static func startCreatedWorkout(
        in context: NSManagedObjectContext,
        save: (() throws -> Void)?,
        afterSave: (Workout) -> Void = { _ in },
        create: () throws -> Workout
    ) throws -> Workout {
        guard try context.count(for: Workout.currentWorkoutFetchRequest) == 0 else {
            throw StartError.workoutAlreadyActive
        }
        let workout = try context.persistMutation(save: { try save?() ?? context.save() }) {
            let workout = try create()
            workout.start = Date()
            workout.isCurrentWorkout = true
            if !workout.isImported && SettingsStore.shared.healthTestMode {
                workout.healthExportState = "test"
            }
            return workout
        }
        afterSave(workout)
        workout.didStart(startWatchCompanionErrorHandler: nil)
        return workout
    }
    
    func start(startWatchCompanionErrorHandler: WatchConnectionManager.StartWatchCompanionErrorHandler? = nil,
               save: (() throws -> Void)? = nil) throws {
        guard let context = managedObjectContext else {
            os_log("Attempt to start workout without context", log: .workoutData, type: .error)
            assertionFailure("Attempt to start workout without context")
            return
        }

        try context.persistMutation(save: { try save?() ?? context.save() }) {
            start = Date()
            isCurrentWorkout = true
            if !isImported && SettingsStore.shared.healthTestMode {
                healthExportState = "test"
            }
        }

        didStart(startWatchCompanionErrorHandler: startWatchCompanionErrorHandler)
    }

    /// Called synchronously when enabling the debug preference, before a quick
    /// off/finish can lose the fact that the active workout was a test.
    static func markCurrentWorkoutAsHealthTestWorkout(in context: NSManagedObjectContext) throws {
        guard SettingsStore.shared.healthTestMode else { return }
        try context.performAndWait {
            let workouts = try context.fetch(Workout.currentWorkoutFetchRequest).filter {
                !$0.isImported && $0.healthExportState != "test"
            }
            guard !workouts.isEmpty else { return }
            try context.persistMutation(save: { try context.save() }) {
                for workout in workouts { workout.healthExportState = "test" }
            }
        }
    }

    private func didStart(startWatchCompanionErrorHandler: WatchConnectionManager.StartWatchCompanionErrorHandler?) {
        WorkoutLiveActivityManager.shared.startOrUpdate(for: self)
        
        if SettingsStore.shared.watchCompanion {
            WatchConnectionManager.shared.prepareAndStartWatchWorkout(workout: self, startWatchCompanionErrorHandler: startWatchCompanionErrorHandler)
        }
        
        // TODO: move this to the current workout view controller, or maybe even when a notification is scheduled?
        NotificationManager.shared.requestAuthorization()
        
        if (workoutExercises?.count ?? 0) == 0 && workoutRoutine == nil {
            // only donate when we start an empty workout
            // we don't have apropriate intent parameters for other workouts yet
            Shortcuts.donateStartWorkoutInteraction(for: self)
        }
    }
    
    func cancel(save: (() throws -> Void)? = nil) throws {
        guard let context = managedObjectContext else {
            os_log("Attempt to cancel workout without context", log: .workoutData, type: .error)
            assertionFailure("Attempt to cancel workout without context")
            return
        }
        
        let workoutID = uuid
        let activitySnapshot = WorkoutLiveActivityManager.shared.endSnapshot(for: self)
        try context.persistMutation(save: { try save?() ?? context.save() }) {
            context.delete(self)
        }

        RestTimerStore.shared.cancel()
        WorkoutLiveActivityManager.shared.end(using: activitySnapshot, completed: false)
        
        if WatchConnectionManager.shared.currentWatchWorkoutUuid != nil, let uuid = workoutID {
            WatchConnectionManager.shared.discardWatchWorkout(uuid: uuid)
        }
        
        // the user did not go through with the workout, we should remove our previous donation
        if let workoutID { Shortcuts.deleteStartWorkoutInteractionDonation(uuid: workoutID) }
    }
    
    func finish() throws {
        try finish(syncToHealth: UserDefaults.standard.syncFinishedWorkoutsWithHealth)
    }

    /// Finishes the local workout while allowing the completion editor to opt
    /// out of phone-originated HealthKit export. A workout already running on
    /// Apple Watch must still be ended on the watch; watchOS owns that active
    /// HealthKit session.
    func finish(syncToHealth: Bool, save: (() throws -> Void)? = nil,
                healthManager: HealthManager = .shared,
                updatingValues: () -> Void = {}) throws {
        guard let context = managedObjectContext else {
            os_log("Attempt to finish workout without context", log: .workoutData, type: .error)
            assertionFailure("Attempt to finish workout without context")
            return
        }
        
        let watchWorkoutUuid = WatchConnectionManager.shared.currentWatchWorkoutUuid
        try context.persistMutation(save: { try save?() ?? context.save() }) {
            updatingValues()
            deleteExercisesWhereAllSetsAreUncompleted()
            deleteUncompletedSets()
            start = safeStart
            end = safeEnd
            isCurrentWorkout = false
            // Persist the export intent with completion, before any external effect.
            let isTestWorkout = healthExportState == "test" || SettingsStore.shared.healthTestMode
            if isTestWorkout && !isImported {
                // Keep exclusion even if a duration is invalid and repaired later.
                healthExportState = "test"
            } else {
                healthExportState = healthExportEligibility == .eligible
                    ? (watchWorkoutUuid != nil ? "watch" : (syncToHealth ? "pending" : nil))
                    : nil
            }
        }

        RestTimerStore.shared.cancel()
        WorkoutLiveActivityManager.shared.end(for: self, completed: true)
        
        // Imports must not reach either phone export or Watch finalization.
        guard healthExportEligibility == .eligible else { return }

        // save workout in Health or tell Apple Watch to finish the workout
        if let watchWorkoutUuid {
            // watchOS owns the live HealthKit session. Never add a phone copy,
            // including when a delayed Watch message leaves a mismatched ID.
            if watchWorkoutUuid != uuid {
                os_log("currentWatchWorkoutUuid=%@ but workout uuid=%@; leaving Health export to Watch", log: .watch, type: .error, watchWorkoutUuid.uuidString, uuid?.uuidString ?? "nil")
            }
            if let start = start, let end = end, let uuid = uuid {
                WatchConnectionManager.shared.finishWatchWorkout(start: start, end: end, title: optionalDisplayTitle(in: ExerciseStore.shared.exercises), uuid: uuid,
                    healthTestMode: healthExportState == "test")
            }
        } else if healthExportState == "pending" {
            healthManager.saveWorkout(workout: self, exerciseStore: ExerciseStore.shared)
        }
    }
    
    func delete(save: (() throws -> Void)? = nil) throws {
        guard let context = managedObjectContext else {
            os_log("Attempt to delete workout without context", log: .workoutData, type: .error)
            assertionFailure("Attempt to delete workout without context")
            return
        }
        
        let workoutID = uuid
        let healthEligibility = healthExportEligibility
        try context.persistMutation(save: { try save?() ?? context.save() }) {
            context.delete(self)
        }
        if let workoutID {
            HealthManager.shared.deleteWorkout(uuid: workoutID, eligibility: healthEligibility)
            Shortcuts.deleteStartWorkoutInteractionDonation(uuid: workoutID)
        }
    }
    
    /// Resolve before blanking the measurements. Publishing is deferred until
    /// the new session saves, before Watch/Live Activity snapshots are created.
    func repeatTrackingDraft(defaults: UserDefaults = .standard) -> RoutineSetTrackingDraft {
        let draft = RoutineSetTrackingDraft(defaults: defaults)
        for exercise in workoutExercises?.array as? [WorkoutExercise] ?? [] {
            guard let id = exercise.exerciseUuid else { continue }
            let type = exercise.trackingType(catalogExercise: ExerciseStore.shared.exercisesByUUID[id], defaults: defaults)
            draft.setOverride(type, for: id)
        }
        return draft
    }

    func copyForRepeat(blank: Bool) -> Workout? {
        guard let context = managedObjectContext else {
            os_log("Attempt to copy workout without context", log: .workoutData, type: .error)
            assertionFailure("Attempt to copy workout without context")
            return nil
        }
        
        // A repeat is a new native session; never copy importSource.
        let newWorkout = Workout.create(context: context)
        
        if let workoutExercises = workoutExercises?.compactMap({ $0 as? WorkoutExercise }) {
            // copy the exercises
            for workoutExercise in workoutExercises {
                let newWorkoutExercise = WorkoutExercise.create(context: context)
                newWorkoutExercise.workout = newWorkout
                newWorkoutExercise.exerciseUuid = workoutExercise.exerciseUuid
                // Workout-only notes never become the next session’s notes.
                newWorkoutExercise.comment = nil
                
                if let workoutSets = workoutExercise.workoutSets?.compactMap({ $0 as? WorkoutSet }) {
                    // copy the sets
                    for workoutSet in workoutSets {
                        let newWorkoutSet = WorkoutSet.create(context: context)
                        newWorkoutSet.workoutExercise = newWorkoutExercise
                        newWorkoutSet.isCompleted = false
                        if !blank {
                            let repetitions = workoutSet.repetitionsValue
                            newWorkoutSet.minTargetRepetitionsValue = repetitions
                            newWorkoutSet.maxTargetRepetitionsValue = repetitions
                            // Timed/distance sets have no separate target attributes.
                            // Preserve those targets without manufacturing lifting load.
                            newWorkoutSet.durationValue = workoutSet.durationValue
                            newWorkoutSet.distanceValue = workoutSet.distanceValue
                            // don't copy weight, RPE, tag, comment, etc.
                        }
                    }
                }
            }
        }
        
        return newWorkout
    }
}

extension WorkoutExercise {
    /// Resolve a plan cue without putting it in the logged, workout-only comment.
    /// The UUID link distinguishes repeated occurrences of the same catalog exercise.
    func routineNoteSource(defaults: UserDefaults = .standard) -> WorkoutRoutineExercise? {
        guard let context = managedObjectContext, let exerciseID = exerciseUuid else { return nil }
        if let sourceID = WorkoutRoutineNoteLinks.routineExerciseID(for: uuid, defaults: defaults) {
            let request: NSFetchRequest<WorkoutRoutineExercise> = WorkoutRoutineExercise.fetchRequest()
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "uuid == %@ AND exerciseUuid == %@",
                                            sourceID as NSUUID, exerciseID as NSUUID)
            return (try? context.fetch(request))?.first
        }
        // Older sessions and legacy backups have the workout relationship but no UUID map.
        let peers = workout?.workoutExercises?.array as? [WorkoutExercise] ?? []
        let matches = peers.filter { $0.exerciseUuid == exerciseID }
        guard let occurrence = matches.firstIndex(where: { $0.objectID == objectID }) else { return nil }
        let sources = workout?.workoutRoutine?.workoutRoutineExercises?.array as? [WorkoutRoutineExercise] ?? []
        let candidates = sources.filter { $0.exerciseUuid == exerciseID && !$0.isDeleted }
        return candidates.indices.contains(occurrence) ? candidates[occurrence] : nil
    }

    var routineNote: String? {
        let text = routineNoteSource()?.comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
}

/// Owns Iron's single active workout Live Activity and translates Core Data models into a
/// compact, value-only ActivityKit payload. The widget extension never opens the live workout.
final class WorkoutLiveActivityManager {
    static let shared = WorkoutLiveActivityManager()

    private let activityOperationLock = NSLock()
    private var activityOperation: Task<Void, Never>?

    private struct PendingConfirmationTransition {
        let token: UUID
        let confirmationUntil: Date
        var workItem: DispatchWorkItem?
        var backgroundTaskIdentifier: UIBackgroundTaskIdentifier
    }

    private struct ConfirmationTransitionResources {
        let workItem: DispatchWorkItem?
        let backgroundTaskIdentifier: UIBackgroundTaskIdentifier
    }

    struct EndSnapshot {
        let workoutID: String
        let completedSets: Int
        let totalSets: Int
        let fallbackSet: WorkoutActivityAttributes.SetSnapshot?
    }

    private let confirmationTransitionLock = NSLock()
    private var pendingConfirmationTransitions: [String: PendingConfirmationTransition] = [:]

    private init() {}

    func startOrUpdate(for workout: Workout, preservingTransition: Bool = true) {
        let workoutID = identifier(for: workout)
        let existingActivity = activity(for: workoutID)
        let restInterval = RestTimerStore.shared.restTimerInterval
        let state = reconciledState(
            for: workout,
            priorState: preservingTransition ? existingActivity?.content.state : nil,
            now: Date(),
            restTimerStart: restInterval?.lowerBound,
            restTimerEnd: restInterval?.upperBound,
            pausedRestRemaining: pausedRestRemaining
        )
        synchronizeConfirmationTransition(for: workoutID, state: state)
        publish(
            attributes: existingActivity?.attributes ?? attributes(for: workout),
            state: state
        )
    }

    func setCompleted(
        _ set: WorkoutSet,
        in workoutExercise: WorkoutExercise,
        workout: Workout,
        confirmationDuration: TimeInterval = 10
    ) {
        let attributes = attributes(for: workout)
        let completedSnapshot = snapshot(for: set, in: workoutExercise)
        let nextSnapshot = nextIncompleteSnapshot(after: set, in: workout)
        let now = Date()
        let restInterval = RestTimerStore.shared.restTimerInterval
        let restTimerStart = restInterval?.lowerBound
        let restTimerEnd = restInterval?.upperBound
        let pausedRemaining = self.pausedRestRemaining
        let hasRunningRest = nextSnapshot != nil
            && restTimerStart != nil
            && restTimerEnd.map { $0 > now } == true
        let hasPausedRest = nextSnapshot != nil
            && pausedRemaining.map { $0.isFinite && $0 > 0 } == true
        let hasActiveRest = hasRunningRest || hasPausedRest
        let confirmationUntil: Date? = hasActiveRest ? nil : now.addingTimeInterval(confirmationDuration)
        let counts = setCounts(in: workout)
        let completedState = WorkoutActivityAttributes.ContentState(
            phase: hasActiveRest ? .resting : .setCompleted,
            displaySet: completedSnapshot,
            nextSet: nextSnapshot,
            confirmationUntil: confirmationUntil,
            restTimerStart: hasActiveRest ? restTimerStart : nil,
            restTimerEnd: hasActiveRest ? restTimerEnd : nil,
            completedSets: counts.completed,
            totalSets: counts.total,
            pausedRestRemaining: hasPausedRest ? pausedRemaining : nil
        )

        guard !hasActiveRest else {
            cancelPendingConfirmationTransition(for: attributes.workoutID)
            publish(attributes: attributes, state: completedState)
            return
        }
        guard let confirmationUntil else { return }

        let transitionToken = replacePendingConfirmationTransition(
            for: attributes.workoutID,
            confirmationUntil: confirmationUntil
        )
        publish(attributes: attributes, state: completedState)
        scheduleConfirmationTransition(
            for: attributes.workoutID,
            confirmationUntil: confirmationUntil,
            token: transitionToken
        )
    }

    /// Reconcile timer changes immediately, including adjustments and Watch updates.
    func refreshRestTimer(for workout: Workout) {
        startOrUpdate(for: workout, preservingTransition: true)
    }

    func refreshCurrentWorkoutRestTimer() {
        let context = WorkoutDataStorage.shared.persistentContainer.viewContext
        guard let workout = (try? context.fetch(Workout.currentWorkoutFetchRequest))?.first else { return }
        refreshRestTimer(for: workout)
    }

    func end(for workout: Workout, completed: Bool) {
        end(using: endSnapshot(for: workout), completed: completed)
    }

    /// Captures every Core Data value needed to end an activity before a
    /// workout is durably deleted.
    func endSnapshot(for workout: Workout) -> EndSnapshot {
        let counts = setCounts(in: workout)
        return EndSnapshot(
            workoutID: identifier(for: workout),
            completedSets: counts.completed,
            totalSets: counts.total,
            fallbackSet: currentPayload(for: workout)?.state.displaySet
        )
    }

    func end(using snapshot: EndSnapshot, completed: Bool) {
        cancelPendingConfirmationTransition(for: snapshot.workoutID)
        let dismissalPolicy: ActivityUIDismissalPolicy = completed
            ? .after(Date().addingTimeInterval(30))
            : .immediate

        enqueueActivityOperation {
            guard let activity = self.activity(for: snapshot.workoutID) else { return }
            let finalState = WorkoutActivityAttributes.ContentState(
                phase: .finished,
                displaySet: activity.content.state.visibleSet(at: Date()) ?? snapshot.fallbackSet,
                nextSet: nil,
                confirmationUntil: nil,
                restTimerStart: nil,
                restTimerEnd: nil,
                completedSets: snapshot.completedSets,
                totalSets: snapshot.totalSets
            )
            let content = ActivityContent(
                state: finalState,
                staleDate: nil,
                relevanceScore: 100
            )
            await activity.end(content, dismissalPolicy: dismissalPolicy)
        }
    }

    private typealias Payload = (
        attributes: WorkoutActivityAttributes,
        state: WorkoutActivityAttributes.ContentState
    )

    private func currentPayload(for workout: Workout) -> Payload? {
        let restInterval = RestTimerStore.shared.restTimerInterval
        return (
            attributes: attributes(for: workout),
            state: reconciledState(
                for: workout,
                priorState: nil,
                now: Date(),
                restTimerStart: restInterval?.lowerBound,
                restTimerEnd: restInterval?.upperBound,
                pausedRestRemaining: pausedRestRemaining
            )
        )
    }

    /// Rebuilds value snapshots from Core Data so ActivityKit never republishes
    /// stale set results, ordering, identifiers, or counts.
    func reconciledState(
        for workout: Workout,
        priorState: WorkoutActivityAttributes.ContentState?,
        now: Date,
        restTimerStart: Date?,
        restTimerEnd: Date?,
        pausedRestRemaining: TimeInterval? = nil
    ) -> WorkoutActivityAttributes.ContentState {
        let flattened = flattenedSets(in: workout)
        let counts = setCounts(in: workout)
        let anchor = priorState?.displaySet?.setID.flatMap { anchorID in
            flattened.first { setIdentifier($0.set) == anchorID && $0.set.isCompleted }
        }
        let confirmationUntil: Date? = {
            guard priorState?.phase == .setCompleted,
                  anchor != nil,
                  let deadline = priorState?.confirmationUntil,
                  deadline > now else { return nil }
            return deadline
        }()

        let next: (exercise: WorkoutExercise, set: WorkoutSet)?
        if let focused = supersetFocus(in: workout, among: flattened) {
            next = focused
        } else if let anchor,
           let anchorIndex = flattened.firstIndex(where: { $0.set.objectID == anchor.set.objectID }) {
            let after = flattened.dropFirst(anchorIndex + 1).first { !$0.set.isCompleted }
            next = after ?? flattened.first { !$0.set.isCompleted }
        } else {
            next = flattened.first { !$0.set.isCompleted }
        }

        let anchorSnapshot = anchor.map { snapshot(for: $0.set, in: $0.exercise) }
        let nextSnapshot = next.map { snapshot(for: $0.set, in: $0.exercise) }
        let fallbackSnapshot = flattened.last.map { snapshot(for: $0.set, in: $0.exercise) }
        let hasRunningTimer = nextSnapshot != nil
            && restTimerStart != nil
            && restTimerEnd.map { $0 > now } == true
        let pausedRemaining = pausedRestRemaining.flatMap {
            nextSnapshot != nil && $0.isFinite && $0 > 0 ? $0 : nil
        }
        let hasActiveRest = hasRunningTimer || pausedRemaining != nil
        let effectiveConfirmationUntil = hasActiveRest ? nil : confirmationUntil

        let phase: WorkoutActivityAttributes.Phase
        if hasActiveRest {
            phase = .resting
        } else if effectiveConfirmationUntil != nil {
            phase = .setCompleted
        } else if flattened.isEmpty {
            phase = .currentSet
        } else if nextSnapshot == nil {
            phase = .finished
        } else {
            phase = .currentSet
        }

        return WorkoutActivityAttributes.ContentState(
            phase: phase,
            // Keep the completed anchor across repeated reconciliations. The
            // widget uses nextSet while resting/current, while displaySet is
            // the stable basis for finding the next set again after edits.
            displaySet: anchorSnapshot ?? nextSnapshot ?? fallbackSnapshot,
            nextSet: nextSnapshot,
            confirmationUntil: effectiveConfirmationUntil,
            restTimerStart: hasActiveRest ? restTimerStart : nil,
            restTimerEnd: hasActiveRest ? restTimerEnd : nil,
            completedSets: counts.completed,
            totalSets: counts.total,
            pausedRestRemaining: pausedRemaining
        )
    }

    private var pausedRestRemaining: TimeInterval? {
        RestTimerStore.shared.isPaused ? RestTimerStore.shared.restTimerRemainingTime : nil
    }

    private func synchronizeConfirmationTransition(
        for workoutID: String,
        state: WorkoutActivityAttributes.ContentState
    ) {
        guard state.phase == .setCompleted, let confirmationUntil = state.confirmationUntil else {
            cancelPendingConfirmationTransition(for: workoutID)
            return
        }
        ensureConfirmationTransition(for: workoutID, confirmationUntil: confirmationUntil)
    }

    private func publish(
        attributes: WorkoutActivityAttributes,
        state: WorkoutActivityAttributes.ContentState
    ) {
        if state.phase != .setCompleted || state.confirmationUntil == nil {
            cancelPendingConfirmationTransition(for: attributes.workoutID)
        }

        let content = ActivityContent(
            state: state,
            staleDate: staleDate(for: state),
            relevanceScore: 100
        )
        let artworkFileNames = [
            state.displaySet?.artworkFileName,
            state.nextSet?.artworkFileName
        ].compactMap { $0 }

        enqueueActivityOperation {
            if let activity = self.activity(for: attributes.workoutID) {
                await activity.update(content)
                // Artwork must not serialize the next timer tap behind the IO queue.
                Task(priority: .utility) {
                    await ExerciseMediaStore.shared.prepareLiveActivityArtwork(fileNames: artworkFileNames)
                }
                return
            }

            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            let canCreateActivity = await MainActor.run {
                UIApplication.shared.applicationState == .active
            }
            guard canCreateActivity else { return }
            do {
                // Start before the artwork: a request only works in the foreground,
                // so waiting on the IO queue loses it if the app closes meanwhile.
                let activity = try Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
                Task(priority: .utility) {
                    await ExerciseMediaStore.shared.prepareLiveActivityArtwork(fileNames: artworkFileNames)
                    await activity.update(activity.content)
                }
            } catch {
                os_log(
                    "Could not start workout Live Activity: %@",
                    log: .workoutData,
                    type: .error,
                    error.localizedDescription
                )
            }
        }
    }

    private func ensureConfirmationTransition(
        for workoutID: String,
        confirmationUntil: Date
    ) {
        guard !hasPendingConfirmationTransition(for: workoutID) else { return }
        let transitionToken = replacePendingConfirmationTransition(
            for: workoutID,
            confirmationUntil: confirmationUntil
        )
        scheduleConfirmationTransition(
            for: workoutID,
            confirmationUntil: confirmationUntil,
            token: transitionToken
        )
    }

    /// Schedule exactly one app-side transition for the current confirmation phase. The
    /// background task keeps the app alive while the short confirmation window expires,
    /// including when the user locks the phone immediately after completing a set.
    private func scheduleConfirmationTransition(
        for workoutID: String,
        confirmationUntil: Date,
        token: UUID
    ) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.performConfirmationTransition(
                for: workoutID,
                confirmationUntil: confirmationUntil,
                token: token
            )
        }

        confirmationTransitionLock.lock()
        guard var pending = pendingConfirmationTransitions[workoutID],
              pending.token == token,
              pending.confirmationUntil == confirmationUntil else {
            confirmationTransitionLock.unlock()
            workItem.cancel()
            return
        }
        pending.workItem = workItem
        pendingConfirmationTransitions[workoutID] = pending
        confirmationTransitionLock.unlock()

        let backgroundTaskIdentifier = beginBackgroundTask(for: workoutID, token: token)

        confirmationTransitionLock.lock()
        guard var current = pendingConfirmationTransitions[workoutID],
              current.token == token,
              current.confirmationUntil == confirmationUntil else {
            confirmationTransitionLock.unlock()
            workItem.cancel()
            endBackgroundTask(backgroundTaskIdentifier)
            return
        }
        current.backgroundTaskIdentifier = backgroundTaskIdentifier
        pendingConfirmationTransitions[workoutID] = current
        confirmationTransitionLock.unlock()

        let delay = max(0, confirmationUntil.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func performConfirmationTransition(
        for workoutID: String,
        confirmationUntil: Date,
        token: UUID
    ) {
        enqueueActivityOperation {
            defer {
                self.finishConfirmationTransition(for: workoutID, token: token)
            }

            guard self.hasPendingConfirmationTransition(
                for: workoutID,
                confirmationUntil: confirmationUntil,
                token: token
            ), let activity = self.activity(for: workoutID) else { return }

            let existing = activity.content.state
            guard existing.phase == .setCompleted,
                  existing.confirmationUntil == confirmationUntil,
                  Date() >= confirmationUntil else { return }

            let now = Date()
            let phase: WorkoutActivityAttributes.Phase
            if existing.nextSet == nil {
                phase = .finished
            } else if existing.isRestPaused || existing.restTimerEnd.map({ now < $0 }) == true {
                phase = .resting
            } else {
                phase = .currentSet
            }

            let state = WorkoutActivityAttributes.ContentState(
                phase: phase,
                displaySet: existing.displaySet,
                nextSet: existing.nextSet,
                confirmationUntil: nil,
                restTimerStart: phase == .finished ? nil : existing.restTimerStart,
                restTimerEnd: phase == .finished ? nil : existing.restTimerEnd,
                completedSets: existing.completedSets,
                totalSets: existing.totalSets,
                pausedRestRemaining: phase == .finished ? nil : existing.pausedRestRemaining
            )
            await activity.update(
                ActivityContent(
                    state: state,
                    staleDate: self.staleDate(for: state),
                    relevanceScore: 100
                )
            )
        }
    }

    /// Ask ActivityKit to invalidate the presentation at each time-driven phase boundary.
    /// The widget reads `context.isStale`, which gives the system a supported reason to
    /// re-render even while the containing app is suspended.
    private func staleDate(
        for state: WorkoutActivityAttributes.ContentState
    ) -> Date? {
        switch state.phase {
        case .setCompleted:
            return state.confirmationUntil
        case .resting:
            return state.isRestPaused ? nil : state.restTimerEnd
        case .currentSet, .finished:
            return nil
        }
    }

    private func beginBackgroundTask(
        for workoutID: String,
        token: UUID
    ) -> UIBackgroundTaskIdentifier {
        let begin = {
            UIApplication.shared.beginBackgroundTask(withName: "Workout Live Activity confirmation") { [weak self] in
                self?.confirmationTransitionExpired(for: workoutID, token: token)
            }
        }
        if Thread.isMainThread {
            return begin()
        }
        return DispatchQueue.main.sync(execute: begin)
    }

    private func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        guard identifier != .invalid else { return }
        if Thread.isMainThread {
            UIApplication.shared.endBackgroundTask(identifier)
        } else {
            DispatchQueue.main.sync {
                UIApplication.shared.endBackgroundTask(identifier)
            }
        }
    }

    private func confirmationTransitionExpired(for workoutID: String, token: UUID) {
        guard let resources = removePendingConfirmationTransition(
            for: workoutID,
            token: token
        ) else { return }
        resources.workItem?.cancel()
        endBackgroundTask(resources.backgroundTaskIdentifier)
    }

    private func finishConfirmationTransition(for workoutID: String, token: UUID) {
        guard let resources = removePendingConfirmationTransition(
            for: workoutID,
            token: token
        ) else { return }
        resources.workItem?.cancel()
        endBackgroundTask(resources.backgroundTaskIdentifier)
    }

    private func replacePendingConfirmationTransition(
        for workoutID: String,
        confirmationUntil: Date
    ) -> UUID {
        let token = UUID()
        let pending = PendingConfirmationTransition(
            token: token,
            confirmationUntil: confirmationUntil,
            workItem: nil,
            backgroundTaskIdentifier: .invalid
        )

        confirmationTransitionLock.lock()
        let previous = pendingConfirmationTransitions.updateValue(
            pending,
            forKey: workoutID
        )
        confirmationTransitionLock.unlock()

        cancelConfirmationTransitionResources(previous.map {
            ConfirmationTransitionResources(
                workItem: $0.workItem,
                backgroundTaskIdentifier: $0.backgroundTaskIdentifier
            )
        })
        return token
    }

    private func cancelPendingConfirmationTransition(for workoutID: String) {
        let resources = removePendingConfirmationTransition(for: workoutID)
        cancelConfirmationTransitionResources(resources)
    }

    private func cancelConfirmationTransitionResources(
        _ resources: ConfirmationTransitionResources?
    ) {
        resources?.workItem?.cancel()
        if let backgroundTaskIdentifier = resources?.backgroundTaskIdentifier {
            endBackgroundTask(backgroundTaskIdentifier)
        }
    }

    private func hasPendingConfirmationTransition(for workoutID: String) -> Bool {
        confirmationTransitionLock.lock()
        defer { confirmationTransitionLock.unlock() }
        return pendingConfirmationTransitions[workoutID] != nil
    }

    private func hasPendingConfirmationTransition(
        for workoutID: String,
        confirmationUntil: Date,
        token: UUID
    ) -> Bool {
        confirmationTransitionLock.lock()
        defer { confirmationTransitionLock.unlock() }
        guard let pending = pendingConfirmationTransitions[workoutID] else { return false }
        return pending.token == token && pending.confirmationUntil == confirmationUntil
    }

    private func removePendingConfirmationTransition(
        for workoutID: String,
        token: UUID? = nil
    ) -> ConfirmationTransitionResources? {
        confirmationTransitionLock.lock()
        guard let pending = pendingConfirmationTransitions[workoutID],
              token == nil || pending.token == token else {
            confirmationTransitionLock.unlock()
            return nil
        }
        pendingConfirmationTransitions.removeValue(forKey: workoutID)
        confirmationTransitionLock.unlock()
        return ConfirmationTransitionResources(
            workItem: pending.workItem,
            backgroundTaskIdentifier: pending.backgroundTaskIdentifier
        )
    }

    /// ActivityKit requests, updates, and endings must retain call order. In particular,
    /// a workout can be cancelled before the asynchronous initial request has returned.
    /// Interactive intents return only after their timer state has reached ActivityKit.
    func waitForPendingUpdate() async {
        await pendingActivityOperation()?.value
    }

    private func pendingActivityOperation() -> Task<Void, Never>? {
        activityOperationLock.lock()
        defer { activityOperationLock.unlock() }
        return activityOperation
    }

    private func enqueueActivityOperation(
        _ operation: @escaping () async -> Void
    ) {
        activityOperationLock.lock()
        let previousOperation = activityOperation
        let nextOperation = Task {
            await previousOperation?.value
            await operation()
        }
        activityOperation = nextOperation
        activityOperationLock.unlock()
    }

    private func activity(for workoutID: String) -> Activity<WorkoutActivityAttributes>? {
        // A dismissed activity can stay listed. Treating it as running would never start a new one.
        Activity<WorkoutActivityAttributes>.activities.first {
            $0.attributes.workoutID == workoutID && $0.activityState != .ended && $0.activityState != .dismissed
        }
    }

    private func attributes(for workout: Workout) -> WorkoutActivityAttributes {
        WorkoutActivityAttributes(
            workoutID: identifier(for: workout),
            workoutTitle: workout.displayTitle(in: ExerciseStore.shared.exercises),
            workoutStart: workout.start ?? Date()
        )
    }

    private func identifier(for workout: Workout) -> String {
        workout.uuid?.uuidString ?? workout.objectID.uriRepresentation().absoluteString
    }

    private func setIdentifier(_ set: WorkoutSet) -> String {
        set.uuid?.uuidString ?? set.objectID.uriRepresentation().absoluteString
    }

    private func snapshot(
        for set: WorkoutSet,
        in workoutExercise: WorkoutExercise
    ) -> WorkoutActivityAttributes.SetSnapshot {
        let sets = workoutExercise.workoutSets?.array.compactMap { $0 as? WorkoutSet }
            .filter { !$0.isDeleted } ?? []
        let setIndex = sets.firstIndex { $0.objectID == set.objectID } ?? 0
        let exercise = workoutExercise.exercise(in: ExerciseStore.shared.exercises)
        let exerciseName = exercise?.title ?? "Exercise"
        let artworkFileName = [exercise?.imageURL, exercise?.animationURL]
            .compactMap { $0 }
            .compactMap { ExerciseMediaStore.shared.liveActivityArtworkFileName(for: $0) }
            .first
        return WorkoutActivityAttributes.SetSnapshot(
            setID: set.uuid?.uuidString ?? set.objectID.uriRepresentation().absoluteString,
            exerciseName: exerciseName,
            setNumber: setIndex + 1,
            setCount: max(sets.count, 1),
            result: set.resultTitle(weightUnit: SettingsStore.shared.weightUnit),
            artworkFileName: artworkFileName,
            completedSetCount: sets.filter(\.isCompleted).count
        )
    }

    private func nextIncompleteSnapshot(
        after set: WorkoutSet,
        in workout: Workout
    ) -> WorkoutActivityAttributes.SetSnapshot? {
        let flattened = flattenedSets(in: workout)
        if let focused = supersetFocus(in: workout, among: flattened) {
            return snapshot(for: focused.set, in: focused.exercise)
        }
        guard let completedIndex = flattened.firstIndex(where: { $0.set.objectID == set.objectID }) else {
            return flattened.first(where: { !$0.set.isCompleted }).map {
                snapshot(for: $0.set, in: $0.exercise)
            }
        }

        let after = flattened.dropFirst(completedIndex + 1).first(where: { !$0.set.isCompleted })
        let next = after ?? flattened.first(where: { !$0.set.isCompleted })
        return next.map { snapshot(for: $0.set, in: $0.exercise) }
    }

    /// Superset rounds must name the same next set in the logger and activity.
    /// Ordinary workouts retain their existing completed-anchor reconciliation.
    private func supersetFocus(
        in workout: Workout,
        among sets: [(exercise: WorkoutExercise, set: WorkoutSet)]
    ) -> (exercise: WorkoutExercise, set: WorkoutSet)? {
        guard sets.contains(where: { $0.exercise.supersetUuid != nil }),
              let focus = WorkoutSetFocus.next(in: workout) else { return nil }
        return sets.first { $0.set.objectID == focus.setID }
    }

    private func flattenedSets(
        in workout: Workout
    ) -> [(exercise: WorkoutExercise, set: WorkoutSet)] {
        let exercises = workout.workoutExercises?.array.compactMap { $0 as? WorkoutExercise }
            .filter { !$0.isDeleted } ?? []
        return exercises.flatMap { exercise in
            let sets = exercise.workoutSets?.array.compactMap { $0 as? WorkoutSet }
                .filter { !$0.isDeleted } ?? []
            return sets.map { (exercise, $0) }
        }
    }

    private func setCounts(in workout: Workout) -> (completed: Int, total: Int) {
        let sets = flattenedSets(in: workout).map(\.set)
        return (sets.filter(\.isCompleted).count, sets.count)
    }
}

/// Entry point used by Live Activity App Intents. `LiveActivityIntent` runs in the
/// containing app process, so this keeps notifications, Watch sync, the in-app timer,
/// and ActivityKit content on the same source of truth.
@available(iOS 17.0, *)
@MainActor
enum WorkoutLiveActivityIntentHandler {
    static func completeSet(workoutID: String, setID: String) async {
        guard let workout = matchingCurrentWorkout(workoutID: workoutID),
              let (workoutExercise, set) = matchingSet(setID: setID, in: workout),
              !set.isCompleted,
              let context = set.managedObjectContext else { return }

        do {
            try persistCompletion(set: set, workout: workout, at: Date()) {
                try context.save()
            }
        } catch {
            os_log(
                "Could not complete workout set from Live Activity: %@",
                log: .workoutData,
                type: .error,
                error.localizedDescription
            )
            return
        }

        if let exerciseID = workoutExercise.exerciseUuid,
           SetTrackingPreferences.override(for: exerciseID) == nil {
            SetTrackingPreferences.setOverride(workoutExercise.setTrackingType, for: exerciseID)
        }
        if SettingsStore.shared.autoStartRestTimer {
            RestTimerStore.shared.start(duration: restTimerDuration(for: workoutExercise))
        }
        WatchConnectionManager.shared.syncCurrentWorkoutSnapshot()
        WorkoutLiveActivityManager.shared.setCompleted(
            set,
            in: workoutExercise,
            workout: workout
        )
        await WorkoutLiveActivityManager.shared.waitForPendingUpdate()
    }

    /// Mutates and saves only the fields owned by the completion action. A
    /// failed save restores those fields without rolling back unrelated edits
    /// already pending in the managed object context.
    static func persistCompletion(
        set: WorkoutSet,
        workout: Workout,
        at date: Date,
        save: () throws -> Void
    ) throws {
        let previousIsCompleted = set.isCompleted
        let previousCompletedAt = set.completedAt
        let previousWorkoutStart = workout.start

        set.isCompleted = true
        set.completedAt = date
        workout.start = workout.start ?? date

        do {
            try save()
        } catch {
            set.isCompleted = previousIsCompleted
            set.completedAt = previousCompletedAt
            workout.start = previousWorkoutStart
            throw error
        }
    }

    static func adjustRestTimer(workoutID: String, by interval: TimeInterval) async {
        guard let workout = matchingCurrentWorkout(workoutID: workoutID) else { return }
        RestTimerStore.shared.adjust(by: interval)
        WorkoutLiveActivityManager.shared.refreshRestTimer(for: workout)
        await WorkoutLiveActivityManager.shared.waitForPendingUpdate()
    }

    static func skipRestTimer(workoutID: String) async {
        guard let workout = matchingCurrentWorkout(workoutID: workoutID) else { return }
        RestTimerStore.shared.cancel()
        WorkoutLiveActivityManager.shared.refreshRestTimer(for: workout)
        await WorkoutLiveActivityManager.shared.waitForPendingUpdate()
    }

    static func resumeRestTimer(workoutID: String) async {
        guard let workout = matchingCurrentWorkout(workoutID: workoutID),
              RestTimerStore.shared.isPaused else { return }
        RestTimerStore.shared.resume()
        WorkoutLiveActivityManager.shared.refreshRestTimer(for: workout)
        await WorkoutLiveActivityManager.shared.waitForPendingUpdate()
    }

    private static func matchingSet(
        setID: String,
        in workout: Workout
    ) -> (WorkoutExercise, WorkoutSet)? {
        let exercises = workout.workoutExercises?.array.compactMap { $0 as? WorkoutExercise }
            .filter { !$0.isDeleted } ?? []
        for exercise in exercises {
            let sets = exercise.workoutSets?.array.compactMap { $0 as? WorkoutSet }
                .filter { !$0.isDeleted } ?? []
            if let set = sets.first(where: {
                ($0.uuid?.uuidString ?? $0.objectID.uriRepresentation().absoluteString) == setID
            }) {
                return (exercise, set)
            }
        }
        return nil
    }

    private static func restTimerDuration(for workoutExercise: WorkoutExercise) -> TimeInterval {
        if let duration = workoutExercise.restTimerDurationValue { return duration }
        switch workoutExercise.exercise(in: ExerciseStore.shared.exercises)?.type {
        case .barbell:
            return SettingsStore.shared.defaultRestTimeBarbellBased
        case .dumbbell:
            return SettingsStore.shared.defaultRestTimeDumbbellBased
        default:
            return SettingsStore.shared.defaultRestTime
        }
    }

    private static func matchingCurrentWorkout(workoutID: String) -> Workout? {
        let context = WorkoutDataStorage.shared.persistentContainer.viewContext
        guard let workout = try? context.fetch(Workout.currentWorkoutFetchRequest).first else {
            return nil
        }
        let identifier = workout.uuid?.uuidString
            ?? workout.objectID.uriRepresentation().absoluteString
        return identifier == workoutID ? workout : nil
    }
}

import CoreData
extension Workout {
    func startOrCrash(startWatchCompanionErrorHandler: WatchConnectionManager.StartWatchCompanionErrorHandler? = nil) {
        do {
            os_log("Starting workout", log: .workoutData)
            try start(startWatchCompanionErrorHandler: startWatchCompanionErrorHandler)
        } catch {
            let errorDescription = NSManagedObjectContext.descriptionWithDetailedErrors(error: error as NSError)
            os_log("Could not start workout: %@", log: .workoutData, type: .error, errorDescription)
            fatalError("Could not start workout: \(errorDescription)")
        }
    }
    
    func cancelOrCrash() {
        do {
            os_log("Cancelling workout", log: .workoutData)
            try cancel()
        } catch {
            let errorDescription = NSManagedObjectContext.descriptionWithDetailedErrors(error: error as NSError)
            os_log("Could not cancel workout: %@", log: .workoutData, type: .error, errorDescription)
            fatalError("Could not cancel workout: \(errorDescription)")
        }
    }
    
    func finishOrCrash() {
        finishOrCrash(syncToHealth: UserDefaults.standard.syncFinishedWorkoutsWithHealth)
    }

    func finishOrCrash(syncToHealth: Bool) {
        do {
            os_log("Finishing workout", log: .workoutData)
            try finish(syncToHealth: syncToHealth)
        } catch {
            let errorDescription = NSManagedObjectContext.descriptionWithDetailedErrors(error: error as NSError)
            os_log("Could not finish workout: %@", log: .workoutData, type: .error, errorDescription)
            fatalError("Could not finish workout: \(errorDescription)")
        }
    }
    
    func deleteOrCrash() {
        do {
            os_log("Deleting workout", log: .workoutData)
            try delete()
        } catch {
            let errorDescription = NSManagedObjectContext.descriptionWithDetailedErrors(error: error as NSError)
            os_log("Could not delete workout: %@", log: .workoutData, type: .error, errorDescription)
            fatalError("Could not delete workout: \(errorDescription)")
        }
    }
}
