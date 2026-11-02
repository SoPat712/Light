import XCTest
import CoreData
import WorkoutDataKit
@testable import Iron

final class WatchCompanionSyncTests: XCTestCase {
    private var container: NSPersistentContainer!
    private var context: NSManagedObjectContext { container.viewContext }
    private let manager = WatchConnectionManager.shared
    private var previousHealthTestMode: Any?

    override func setUp() {
        super.setUp()
        previousHealthTestMode = UserDefaults.appGroup.object(forKey: UserDefaults.SettingsKeys.healthTestMode.rawValue)
        SettingsStore.shared.healthTestMode = false
        container = setUpInMemoryNSPersistentContainer()
    }

    override func tearDown() {
        UserDefaults.appGroup.set(previousHealthTestMode, forKey: UserDefaults.SettingsKeys.healthTestMode.rawValue)
        container = nil
        super.tearDown()
    }

    private func snapshot(
        workoutID: UUID = UUID(),
        exerciseID: UUID = UUID(),
        setID: UUID = UUID(),
        completed: Bool = false,
        endDate: Date? = nil,
        supersetID: UUID? = nil
    ) -> WatchWorkoutSnapshot {
        let set = WatchWorkoutSet(
            id: setID, order: 1, weight: 100, reps: 8, rpe: 8.5,
            completed: completed, tag: WorkoutSetTag.warmUp.rawValue,
            duration: 75, distance: 400, comment: "Controlled tempo",
            minTargetReps: 6, maxTargetReps: 10)
        let exercise = WatchWorkoutExercise(
            id: exerciseID, order: 1, name: "Watch exercise", sets: [set],
            restTimerDuration: 90, exerciseUuid: UUID(), supersetID: supersetID,
            comment: "Keep shoulders down")
        return WatchWorkoutSnapshot(
            workoutID: workoutID, title: "Watch session",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: endDate, exercises: [exercise], weightUnit: .kilogram,
            revision: 4, updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            comment: "Watch note")
    }

    func testWatchCreatedHydrationIsIdempotentAndComplete() throws {
        let workout = Workout.create(context: context)
        workout.isCurrentWorkout = true
        workout.healthExportState = "watch"
        let groupID = UUID()
        let source = snapshot(workoutID: workout.uuid!, supersetID: groupID)

        manager.applyComplete(source, to: workout, in: context)
        manager.applyComplete(source, to: workout, in: context)

        let exercises = workout.workoutExercises?.array as? [WorkoutExercise]
        let sets = exercises?.first?.workoutSets?.array as? [WorkoutSet]
        XCTAssertEqual(exercises?.count, 1)
        XCTAssertEqual(sets?.count, 1)
        XCTAssertEqual(exercises?.first?.supersetUuid, groupID)
        XCTAssertEqual(exercises?.first?.comment, "Keep shoulders down")
        XCTAssertEqual(sets?.first?.durationValue, 75)
        XCTAssertEqual(sets?.first?.distanceValue, 400)
        XCTAssertEqual(sets?.first?.minTargetRepetitionsValue, 6)
        XCTAssertEqual(sets?.first?.maxTargetRepetitionsValue, 10)
        XCTAssertEqual(sets?.first?.comment, "Controlled tempo")
        XCTAssertEqual(workout.comment, "Watch note")
        try context.save()
    }

    func testMatchingTestPlaceholderReceivesWatchTitleAndGraph() throws {
        let placeholder = Workout.create(context: context)
        placeholder.isCurrentWorkout = true
        placeholder.healthExportState = "test"
        var source = snapshot(workoutID: placeholder.uuid!)
        source.healthTestMode = true
        source.startedOnWatch = true
        let event = WatchWorkoutEvent(workoutID: source.workoutID, sequence: 1,
                                      kind: .workoutCreated, snapshot: source,
                                      fieldChanges: WatchWorkoutFieldChanges())

        _ = try manager.applyWatchEventModelMutation(event, to: placeholder, in: context)
        try context.save()

        XCTAssertEqual(placeholder.displayTitle(in: []), "Watch session")
        XCTAssertEqual(placeholder.start, source.startDate)
        XCTAssertEqual(placeholder.healthExportState, "test")
        let exercise = try XCTUnwrap(placeholder.workoutExercises?.firstObject as? WorkoutExercise)
        XCTAssertEqual(exercise.uuid, source.exercises[0].id)
        XCTAssertEqual((exercise.workoutSets?.firstObject as? WorkoutSet)?.uuid, source.exercises[0].sets[0].id)
    }

    func testBlankWatchStartThenLiveAdditionCompletionAndPhoneEditKeepOneIdentity() throws {
        var source = snapshot()
        source.exercises = []
        source.startedOnWatch = true
        let created = WatchWorkoutEvent(workoutID: source.workoutID, sequence: 1,
                                        kind: .workoutCreated, snapshot: source,
                                        fieldChanges: WatchWorkoutFieldChanges())
        let workout = try XCTUnwrap(manager.resolveWorkout(for: created, in: context))
        _ = try manager.applyWatchEventModelMutation(created, to: workout, in: context)
        try context.save()

        var added = source
        added.exercises = snapshot().exercises
        let addition = WatchWorkoutEvent(workoutID: source.workoutID, sequence: 2,
                                         kind: .workoutStructureUpdated, snapshot: added,
                                         fieldChanges: .between(previous: source, next: added))
        _ = try manager.applyWatchEventModelMutation(addition, to: workout, in: context)
        let exercise = try XCTUnwrap(workout.workoutExercises?.firstObject as? WorkoutExercise)
        let set = try XCTUnwrap(exercise.workoutSets?.firstObject as? WorkoutSet)
        var edited = added
        edited.exercises[0].sets[0].weight = 110
        edited.exercises[0].sets[0].reps = 9
        let update = WatchWorkoutEvent(workoutID: source.workoutID, sequence: 3,
                                      kind: .workoutStructureUpdated, snapshot: edited,
                                      fieldChanges: .between(previous: added, next: edited))
        _ = try manager.applyWatchEventModelMutation(update, to: workout, in: context)
        XCTAssertEqual(set.weight?.doubleValue, 110)
        XCTAssertEqual(set.repetitions?.intValue, 9)
        let completion = WatchWorkoutEvent(workoutID: source.workoutID, sequence: 4,
                                           kind: .setCompletionChanged, exerciseID: exercise.uuid,
                                           setID: set.uuid, completed: true, snapshot: edited,
                                           fieldChanges: WatchWorkoutFieldChanges())
        _ = try manager.applyWatchEventModelMutation(completion, to: workout, in: context)
        try context.save()

        workout.title = "Renamed on iPhone"
        set.repetitions = 12
        set.comment = "Phone edit"
        try context.save()
        let phone = manager.makeSnapshot(for: workout, after: added.revision)

        XCTAssertEqual(try context.fetch(Workout.currentWorkoutFetchRequest).map(\.uuid), [source.workoutID])
        XCTAssertEqual(phone.workoutID, source.workoutID)
        XCTAssertEqual(phone.title, "Renamed on iPhone")
        XCTAssertEqual(phone.exercises[0].id, added.exercises[0].id)
        XCTAssertEqual(phone.exercises[0].sets[0].id, added.exercises[0].sets[0].id)
        XCTAssertTrue(phone.exercises[0].sets[0].completed)
        XCTAssertEqual(phone.exercises[0].sets[0].reps, 12)
        XCTAssertEqual(phone.exercises[0].sets[0].comment, "Phone edit")
        XCTAssertGreaterThan(phone.revision, added.revision)
    }

    func testOpeningDeferredWatchWorkoutReplacesOnlyEmptyPhonePlaceholder() throws {
        let phone = Workout.create(context: context)
        phone.isCurrentWorkout = true
        phone.start = Date(timeIntervalSince1970: 1_700_000_000)
        let oldID = phone.uuid
        try context.save()
        var source = snapshot(completed: true)
        source.healthTestMode = true
        source.startedOnWatch = true

        let opened = try manager.persistWatchWorkoutForOpening(source, in: context)
        let reopened = try manager.persistWatchWorkoutForOpening(source, in: context)

        XCTAssertEqual(opened.objectID, reopened.objectID)
        XCTAssertEqual(opened.uuid, source.workoutID)
        XCTAssertEqual(opened.title, source.title)
        XCTAssertEqual(opened.healthExportState, "test")
        XCTAssertEqual(opened.numberOfCompletedSets, 1)
        XCTAssertEqual(try context.fetch(Workout.currentWorkoutFetchRequest).map(\.uuid), [source.workoutID])
        let workouts = try context.fetch(Workout.fetchRequest())
        XCTAssertEqual(workouts.count, 1)
        XCTAssertFalse(workouts.contains { $0.uuid == oldID })
    }

    func testOpeningDeferredWatchWorkoutPreservesPhoneExercisesTitleAndNotes() throws {
        let phone = Workout.create(context: context)
        phone.isCurrentWorkout = true
        phone.start = Date(timeIntervalSince1970: 1_700_000_000)
        let exercise = WorkoutExercise.create(context: context)
        exercise.workout = phone
        let source = snapshot()
        try context.save()

        XCTAssertThrowsError(try manager.persistWatchWorkoutForOpening(source, in: context))
        XCTAssertFalse(exercise.isDeleted)
        context.delete(exercise)
        context.processPendingChanges()
        phone.title = "My phone workout"
        XCTAssertThrowsError(try manager.persistWatchWorkoutForOpening(source, in: context))
        phone.title = nil
        phone.comment = "Keep this note"
        XCTAssertThrowsError(try manager.persistWatchWorkoutForOpening(source, in: context))
        XCTAssertEqual(phone.comment, "Keep this note")
        XCTAssertTrue(phone.isCurrentWorkout)
        XCTAssertEqual(try context.fetch(Workout.fetchRequest()).count, 1)
    }

    func testFailedWatchHandoffRestoresPhonePlaceholderAndUnrelatedEdit() throws {
        enum SaveFailure: Error { case expected }
        let phone = Workout.create(context: context)
        phone.isCurrentWorkout = true
        phone.start = Date(timeIntervalSince1970: 1_700_000_000)
        let phoneID = phone.uuid
        let history = Workout.create(context: context)
        history.title = "History"
        history.start = Date(timeIntervalSince1970: 1_000)
        history.end = Date(timeIntervalSince1970: 2_000)
        try context.save()
        history.comment = "Unsaved phone note"

        var saveCalled = false
        XCTAssertThrowsError(try manager.persistWatchWorkoutForOpening(snapshot(), in: context, save: {
            saveCalled = true
            throw SaveFailure.expected
        })) { error in
            XCTAssertTrue(error is SaveFailure)
        }

        XCTAssertTrue(saveCalled)
        XCTAssertFalse(phone.isDeleted)
        XCTAssertTrue(phone.isCurrentWorkout)
        XCTAssertEqual(phone.start, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(try context.fetch(Workout.currentWorkoutFetchRequest).map(\.uuid), [phoneID])
        XCTAssertEqual(try context.fetch(Workout.fetchRequest()).count, 2)
        XCTAssertEqual(history.comment, "Unsaved phone note")
    }

    func testPhoneSnapshotAdvancesPastOfflineWatchRevisionAndKeepsTestProvenance() throws {
        let workout = Workout.create(context: context)
        workout.isCurrentWorkout = true
        workout.healthExportState = "test"
        workout.title = "Watch title"
        let offlineRevision = Int64(Date().timeIntervalSince1970 * 1_000) + 100_000
        let result = manager.makeSnapshot(for: workout, after: offlineRevision)

        XCTAssertGreaterThan(result.revision, offlineRevision)
        XCTAssertTrue(result.isHealthTestWorkout)
        XCTAssertEqual(result.title, "Watch title")
    }

    func testModernFinishPreservesNewerPhoneTitleAndExplicitWatchRenameStillApplies() throws {
        let workout = Workout.create(context: context)
        workout.isCurrentWorkout = true
        workout.healthExportState = "test"
        let source = snapshot(workoutID: workout.uuid!, completed: true)
        manager.applyComplete(source, to: workout, in: context)
        let set = try XCTUnwrap((workout.workoutExercises?.firstObject as? WorkoutExercise)?.workoutSets?.firstObject as? WorkoutSet)
        set.comment = "Concurrent phone note"
        var renamed = source
        renamed.title = "Explicit Watch rename"
        let rename = WatchWorkoutEvent(workoutID: source.workoutID, sequence: 3,
                                       kind: .workoutStructureUpdated, snapshot: renamed,
                                       fieldChanges: .between(previous: source, next: renamed))
        _ = try manager.applyWatchEventModelMutation(rename, to: workout, in: context)
        XCTAssertEqual(workout.title, "Explicit Watch rename")
        workout.title = "Newer phone title"
        let event = WatchWorkoutEvent(workoutID: source.workoutID, sequence: 4,
                                      kind: .workoutFinished, endDate: source.startDate.addingTimeInterval(600),
                                      title: "Final Watch title", snapshot: source,
                                      fieldChanges: WatchWorkoutFieldChanges())

        _ = try manager.applyWatchEventModelMutation(event, to: workout, in: context)

        try context.save()
        XCTAssertEqual(workout.title, "Newer phone title")
        XCTAssertEqual(set.comment, "Concurrent phone note")
        XCTAssertEqual(workout.healthExportState, "test")
        XCTAssertFalse(workout.isCurrentWorkout)
    }

    func testEarlyModernFinishPrunesOnlyUnfinishedRowsAndAcknowledgesAfterSave() throws {
        let workout = Workout.create(context: context)
        workout.isCurrentWorkout = true
        let source = snapshot(workoutID: workout.uuid!, completed: true)
        manager.applyComplete(source, to: workout, in: context)
        let exercise = try XCTUnwrap(workout.workoutExercises?.firstObject as? WorkoutExercise)
        let completed = try XCTUnwrap(exercise.workoutSets?.firstObject as? WorkoutSet)
        completed.weight = 110
        completed.comment = "Completed phone edit"
        let unfinished = WorkoutSet.create(context: context)
        unfinished.workoutExercise = exercise
        let phoneExercise = WorkoutExercise.create(context: context)
        phoneExercise.workout = workout
        let phoneCompleted = WorkoutSet.create(context: context)
        phoneCompleted.isCompleted = true
        phoneCompleted.workoutExercise = phoneExercise
        let unusedExercise = WorkoutExercise.create(context: context)
        unusedExercise.workout = workout
        let unusedSet = WorkoutSet.create(context: context)
        unusedSet.workoutExercise = unusedExercise
        try context.save()

        let finish = WatchWorkoutEvent(workoutID: source.workoutID, sequence: 4,
                                       kind: .workoutFinished, endDate: source.startDate.addingTimeInterval(600),
                                       snapshot: source, fieldChanges: WatchWorkoutFieldChanges())
        let next = WatchWorkoutEvent(workoutID: UUID(), sequence: 5, kind: .workoutCreated)
        var outbox = WatchWorkoutPersistedState(snapshot: source, outbox: [finish, next], nextSequence: 5)
        var acknowledged = false
        try WatchConnectionManager.commitWatchEventMutation(in: context, save: { try self.context.save() }, mutation: {
            try self.manager.applyWatchEventModelMutation(finish, to: workout, in: self.context)
        }, didPersist: {
            acknowledged = true
            WatchWorkoutPersistence.acknowledge(eventIDs: [finish.id], in: &outbox)
        })

        XCTAssertTrue(acknowledged)
        XCTAssertEqual(outbox.outbox.map(\.id), [next.id])
        XCTAssertFalse(workout.isCurrentWorkout)
        XCTAssertEqual(workout.numberOfCompletedSets, 2)
        XCTAssertEqual(completed.weight?.doubleValue, 110)
        XCTAssertEqual(completed.comment, "Completed phone edit")
        XCTAssertEqual((exercise.workoutSets?.array as? [WorkoutSet])?.map(\.uuid), [completed.uuid])
        XCTAssertEqual((workout.workoutExercises?.array as? [WorkoutExercise])?.count, 2)
        XCTAssertFalse(phoneCompleted.isDeleted)
        XCTAssertFalse(phoneExercise.isDeleted)
    }

    func testModernHealthFailurePreservesConcurrentPhoneValuesAndNotes() throws {
        let workout = Workout.create(context: context)
        workout.isCurrentWorkout = true
        let source = snapshot(workoutID: workout.uuid!, completed: true)
        manager.applyComplete(source, to: workout, in: context)
        let exercise = try XCTUnwrap(workout.workoutExercises?.firstObject as? WorkoutExercise)
        let set = try XCTUnwrap(exercise.workoutSets?.firstObject as? WorkoutSet)
        workout.title = "Phone title"
        workout.comment = "Phone workout note"
        exercise.comment = "Phone exercise note"
        set.weight = 110
        set.repetitions = 12
        set.comment = "Phone set note"
        let end = source.startDate.addingTimeInterval(600)
        let finish = WatchWorkoutEvent(workoutID: source.workoutID, sequence: 4,
                                       kind: .workoutFinished, endDate: end, snapshot: source,
                                       fieldChanges: WatchWorkoutFieldChanges())
        _ = try manager.applyWatchEventModelMutation(finish, to: workout, in: context)
        workout.sessionEffortValue = 9
        workout.end = end.addingTimeInterval(30)
        let failure = WatchWorkoutEvent(workoutID: source.workoutID, sequence: 5,
                                        kind: .workoutFailed, endDate: end, title: "Health failure",
                                        snapshot: source, fieldChanges: WatchWorkoutFieldChanges())
        _ = try manager.applyWatchEventModelMutation(failure, to: workout, in: context)
        try context.save()

        XCTAssertEqual(workout.healthExportState, "pending")
        XCTAssertEqual(workout.sessionEffortValue, 9)
        XCTAssertEqual(workout.end, end.addingTimeInterval(30))
        XCTAssertEqual(workout.title, "Phone title")
        XCTAssertEqual(workout.comment, "Phone workout note")
        XCTAssertEqual(exercise.comment, "Phone exercise note")
        XCTAssertEqual(set.weight?.doubleValue, 110)
        XCTAssertEqual(set.repetitions?.intValue, 12)
        XCTAssertEqual(set.comment, "Phone set note")
    }

    func testPhoneFinishAcceptsPriorWatchValuePatchesOnlyOnRetainedCompletedSets() throws {
        let workout = Workout.create(context: context)
        workout.isCurrentWorkout = true
        let source = snapshot(workoutID: workout.uuid!, completed: true)
        manager.applyComplete(source, to: workout, in: context)
        let exercise = try XCTUnwrap(workout.workoutExercises?.firstObject as? WorkoutExercise)
        let set = try XCTUnwrap(exercise.workoutSets?.firstObject as? WorkoutSet)
        let end = source.startDate.addingTimeInterval(600)
        let finalizationKey = "watchWorkoutFinalizationDates.v1"
        let valuesKey = finalizationKey + ".setValues"
        let previousFinalizations = UserDefaults.appGroup.object(forKey: finalizationKey)
        let previousValues = UserDefaults.appGroup.object(forKey: valuesKey)
        defer {
            UserDefaults.appGroup.set(previousFinalizations, forKey: finalizationKey)
            UserDefaults.appGroup.set(previousValues, forKey: valuesKey)
        }
        UserDefaults.appGroup.removeObject(forKey: finalizationKey)
        workout.end = end.addingTimeInterval(-300) // The display end can be edited independently of finalization.
        workout.isCurrentWorkout = false
        workout.healthExportState = "watch"
        try context.save()
        WatchConnectionManager.recordPhoneFinalization(workout, at: end)
        let editDate = end.addingTimeInterval(-10)
        let values = WatchWorkoutEvent(workoutID: source.workoutID, sequence: 3,
                                       kind: .setUpdated, setID: set.uuid, weight: 115, reps: 10, rpe: 9,
                                       weightUnit: .kilogram, snapshot: source, createdAt: editDate)
        _ = try manager.applyWatchEventModelMutation(values, to: workout, in: context)
        XCTAssertEqual(set.weight?.doubleValue, 115)
        XCTAssertEqual(set.repetitions?.intValue, 10)

        var edited = source
        edited.exercises[0].sets[0].comment = "Offline correction"
        edited.exercises[0].sets[0].duration = 85
        edited.exercises[0].sets[0].completed = false
        let missing = WatchWorkoutSet(order: 2, weight: 90, reps: 8, completed: true)
        edited.exercises[0].sets.append(missing)
        let patch = WatchWorkoutEvent(workoutID: source.workoutID, sequence: 4,
                                      kind: .workoutStructureUpdated, snapshot: edited,
                                      removedExerciseIDs: [exercise.uuid!], removedSetIDs: [set.uuid!],
                                      fieldChanges: .between(previous: source, next: edited), createdAt: editDate)
        _ = try manager.applyWatchEventModelMutation(patch, to: workout, in: context)
        try context.save()
        XCTAssertEqual(set.comment, "Offline correction")
        XCTAssertEqual(set.durationValue, 85)
        XCTAssertTrue(set.isCompleted)
        XCTAssertFalse(workout.isCurrentWorkout)
        XCTAssertEqual((exercise.workoutSets?.array as? [WorkoutSet])?.count, 1)

        let late = WatchWorkoutEvent(workoutID: source.workoutID, sequence: 5,
                                     kind: .setUpdated, setID: set.uuid, weight: 50, reps: 1,
                                     snapshot: source, createdAt: end.addingTimeInterval(10))
        _ = try manager.applyWatchEventModelMutation(late, to: workout, in: context)
        XCTAssertEqual(set.weight?.doubleValue, 115)
        XCTAssertEqual(set.repetitions?.intValue, 10)
        XCTAssertEqual(set.rpeValue, 9)
        workout.importSource = "hevy"
        _ = try manager.applyWatchEventModelMutation(values, to: workout, in: context)
        XCTAssertEqual(set.weight?.doubleValue, 115)
        XCTAssertEqual(set.repetitions?.intValue, 10)
        XCTAssertEqual(set.rpeValue, 9)
    }

    func testDelayedWatchPatchesPreservePostFinishPhoneFieldsAndAdvanceOnlySavedValues() throws {
        let suite = "WatchCompanionSyncTests.finalizedValues." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        var preferenceNotifications = 0
        let observers = [PlateCalculatorStorageKeys.didChangeNotification, SetTrackingPreferences.didChangeNotification,
                         ExerciseNotes.didChangeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                preferenceNotifications += 1
            }
        }
        defer { observers.forEach { NotificationCenter.default.removeObserver($0) } }
        let workout = Workout.create(context: context)
        workout.isCurrentWorkout = true
        let source = snapshot(workoutID: workout.uuid!, completed: true)
        manager.applyComplete(source, to: workout, in: context)
        let exercise = try XCTUnwrap(workout.workoutExercises?.firstObject as? WorkoutExercise)
        let set = try XCTUnwrap(exercise.workoutSets?.firstObject as? WorkoutSet)
        let end = source.startDate.addingTimeInterval(600)
        workout.end = end
        workout.isCurrentWorkout = false
        workout.healthExportState = "watch"
        try context.save()
        WatchConnectionManager.recordPhoneFinalization(workout, at: end, defaults: defaults)

        set.weight = 120
        set.comment = "Corrected in phone history"
        set.tagValue = .failure
        try context.save()
        let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
        WatchConnectionManager.recordPhoneFinalization(workout, at: end.addingTimeInterval(30), defaults: reloaded)
        let editDate = end.addingTimeInterval(-10)
        let values = WatchWorkoutEvent(workoutID: source.workoutID, sequence: 3,
            kind: .setUpdated, setID: set.uuid, weight: 110, reps: 10, rpe: 9,
            weightUnit: .kilogram, snapshot: source, createdAt: editDate)
        try WatchConnectionManager.commitWatchEventMutation(in: context, save: { try self.context.save() },
            mutation: { try self.manager.applyWatchEventModelMutation(values, to: workout, in: self.context,
                finalizationDefaults: reloaded) }, didPersist: {})
        XCTAssertEqual(set.weight?.doubleValue, 120)
        XCTAssertEqual(set.repetitions?.intValue, 10)

        let tag = WatchWorkoutEvent(workoutID: source.workoutID, sequence: 4,
            kind: .setTagChanged, setID: set.uuid, tag: "warmUp", createdAt: editDate)
        _ = try manager.applyWatchEventModelMutation(tag, to: workout, in: context, finalizationDefaults: reloaded)
        XCTAssertEqual(set.tagValue, .failure)

        var edited = source
        edited.exercises[0].sets[0].weight = 115
        edited.exercises[0].sets[0].reps = 12
        edited.exercises[0].sets[0].comment = "Older offline note"
        edited.exercises[0].sets[0].duration = 85
        let patch = WatchWorkoutEvent(workoutID: source.workoutID, sequence: 5,
            kind: .workoutStructureUpdated, snapshot: edited,
            fieldChanges: .between(previous: source, next: edited), createdAt: editDate)
        enum SaveFailure: Error { case expected }
        XCTAssertThrowsError(try WatchConnectionManager.commitWatchEventMutation(in: context,
            save: { throw SaveFailure.expected },
            mutation: { try self.manager.applyWatchEventModelMutation(patch, to: workout, in: self.context,
                finalizationDefaults: reloaded) }, didPersist: { XCTFail("A failed save cannot acknowledge the patch") }))
        XCTAssertEqual(set.repetitions?.intValue, 10)
        try WatchConnectionManager.commitWatchEventMutation(in: context, save: { try self.context.save() },
            mutation: { try self.manager.applyWatchEventModelMutation(patch, to: workout, in: self.context,
                finalizationDefaults: reloaded) }, didPersist: {})
        XCTAssertEqual(set.weight?.doubleValue, 120)
        XCTAssertEqual(set.comment, "Corrected in phone history")
        XCTAssertEqual(set.tagValue, .failure)
        XCTAssertEqual(set.repetitions?.intValue, 12, "The previous accepted Watch value must advance its own baseline")
        XCTAssertEqual(set.durationValue, 85)
        XCTAssertFalse(workout.isCurrentWorkout)
        XCTAssertTrue(set.isCompleted)
        XCTAssertEqual(preferenceNotifications, 0, "Durable merge metadata cannot emit local preference-edit notifications")
    }

    func testDelayedWatchValueMasksPreserveRejectedFieldsAndAcceptClearsInEitherUnit() throws {
        for unit in [WatchWorkoutWeightUnit.kilogram, .pound] {
            let suite = "WatchCompanionSyncTests.valueMasks." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let workout = Workout.create(context: context)
            workout.isCurrentWorkout = true
            let source = WatchWorkoutEditing.converting(snapshot(workoutID: workout.uuid!, completed: true), to: unit)
            manager.applyComplete(source, to: workout, in: context)
            let exercise = try XCTUnwrap(workout.workoutExercises?.firstObject as? WorkoutExercise)
            let set = try XCTUnwrap(exercise.workoutSets?.firstObject as? WorkoutSet)
            let end = source.startDate.addingTimeInterval(600)
            workout.end = end
            workout.isCurrentWorkout = false
            try context.save()
            WatchConnectionManager.recordPhoneFinalization(workout, at: end, defaults: defaults)
            set.repetitions = 11 // A later phone correction protects only this field.
            try context.save()

            func commit(_ event: WatchWorkoutEvent) throws {
                try WatchConnectionManager.commitWatchEventMutation(in: context, save: { try self.context.save() },
                    mutation: { try self.manager.applyWatchEventModelMutation(event, to: workout, in: self.context,
                        finalizationDefaults: defaults) }, didPersist: {})
            }
            let editDate = end.addingTimeInterval(-10)
            let values = WatchWorkoutEvent(workoutID: source.workoutID, sequence: 3,
                kind: .setUpdated, setID: set.uuid, weight: 115, reps: nil, rpe: nil,
                weightUnit: unit, snapshot: source, createdAt: editDate)
            try commit(values)
            let canonicalWeight = WeightUnit.convert(weight: 115, from: unit == .pound ? .imperial : .metric, to: .metric)
            XCTAssertEqual(try XCTUnwrap(set.weight).doubleValue, canonicalWeight, accuracy: 0.000_001)
            XCTAssertEqual(set.repetitions?.intValue, 11, "A rejected nil value must not clear the phone correction")
            XCTAssertNil(set.rpeValue, "An accepted nil value must still clear the Watch field")

            let clear = WatchWorkoutEvent(workoutID: source.workoutID, sequence: 4,
                kind: .setUpdated, setID: set.uuid, weight: nil, reps: 12, rpe: 9,
                weightUnit: unit, snapshot: source, createdAt: editDate)
            try commit(clear)
            XCTAssertNil(set.weight, "The saved canonical weight must advance its baseline so a later clear is accepted")
            XCTAssertEqual(set.repetitions?.intValue, 11)
            XCTAssertEqual(set.rpeValue, 9, "A saved nil value must advance its baseline too")

            defaults.removeObject(forKey: "watchWorkoutFinalizationDates.v1.setValues")
            let unprovable = WatchWorkoutEvent(workoutID: source.workoutID, sequence: 5,
                kind: .setUpdated, setID: set.uuid, weight: 130, reps: 13, rpe: 10,
                weightUnit: unit, snapshot: source, createdAt: editDate)
            try commit(unprovable)
            XCTAssertNil(set.weight)
            XCTAssertEqual(set.repetitions?.intValue, 11)
            XCTAssertEqual(set.rpeValue, 9, "A missing baseline must reject the patch without clearing existing values")
        }
    }

    func testConcurrentPhoneWorkoutRemainsCurrentWhenWatchWorkoutIsHydrated() throws {
        let phone = Workout.create(context: context)
        phone.isCurrentWorkout = true
        phone.start = Date(timeIntervalSince1970: 1_700_000_000)
        let watchID = UUID()
        let source = snapshot(workoutID: watchID)
        let event = WatchWorkoutEvent(
            workoutID: watchID, sequence: 1, kind: .workoutCreated,
            snapshot: source)

        let hydrated = try manager.resolveWorkout(for: event, in: context)

        XCTAssertTrue(phone.isCurrentWorkout)
        XCTAssertNil(hydrated, "Conflicting unfinished Watch data must be deferred, not inserted")
        let workoutsRequest: NSFetchRequest<Workout> = Workout.fetchRequest()
        XCTAssertEqual(try context.fetch(workoutsRequest).map(\.uuid), [phone.uuid])
        try context.save()
    }

    func testPhoneDeletionTombstoneRejectsQueuedWatchFinishAfterReload() throws {
        let suite = "WatchCompanionSyncTests.deleted." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let source = snapshot(completed: true, endDate: Date(timeIntervalSince1970: 1_700_000_600))
        let created = WatchWorkoutEvent(workoutID: source.workoutID, sequence: 1,
                                        kind: .workoutFinished, snapshot: source,
                                        fieldChanges: WatchWorkoutFieldChanges())
        let workout = try XCTUnwrap(manager.resolveWorkout(for: created, in: context, tombstoneDefaults: defaults))
        try context.save()
        let observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextDidSave,
            object: context, queue: nil) { notification in
                WatchConnectionManager.recordDeletedWorkouts(from: notification, defaults: defaults)
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        context.delete(workout)
        try context.save()

        let reloadedDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertTrue(WatchConnectionManager.wasDeletedOnPhone(source.workoutID, defaults: reloadedDefaults))
        XCTAssertNil(try manager.resolveWorkout(for: created, in: context, tombstoneDefaults: reloadedDefaults))
        XCTAssertTrue(try context.fetch(Workout.fetchRequest()).isEmpty)
        var unknown = source
        unknown.workoutID = UUID()
        let offlineHistory = WatchWorkoutEvent(workoutID: unknown.workoutID, sequence: 2,
                                               kind: .workoutFinished, snapshot: unknown)
        XCTAssertNotNil(try manager.resolveWorkout(for: offlineHistory, in: context, tombstoneDefaults: reloadedDefaults),
                        "Previously unseen offline history still hydrates normally")
    }

    func testPhoneTerminalStorageIsBoundedAndSnapshotCleanupKeepsPreferences() throws {
        let suite = "WatchCompanionSyncTests.terminals." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let ids = (0..<51).map { _ in UUID() }
        WatchConnectionManager.recordDeletedWorkoutIDs(ids, defaults: defaults)
        XCTAssertFalse(WatchConnectionManager.wasDeletedOnPhone(ids[0], defaults: defaults))
        XCTAssertTrue(WatchConnectionManager.wasDeletedOnPhone(ids[50], defaults: defaults))
        for (index, id) in ids.enumerated() {
            WatchConnectionManager.recordPhoneFinalization(id, at: Date(timeIntervalSince1970: Double(index)),
                defaults: defaults, setValues: [id.uuidString: ["weight": "1100.0"]])
        }
        let baselines = defaults.dictionary(forKey: "watchWorkoutFinalizationDates.v1.setValues")
        XCTAssertEqual(baselines?.count, 50)
        XCTAssertNil(baselines?[ids[0].uuidString])
        XCTAssertNil(WatchConnectionManager.phoneFinalizationDate(ids[0], defaults: defaults))
        XCTAssertEqual(WatchConnectionManager.phoneFinalizationDate(ids[50], defaults: defaults), Date(timeIntervalSince1970: 50))
        WatchConnectionManager.recordPhoneFinalization(ids[50], at: Date(timeIntervalSince1970: 100), defaults: defaults)
        XCTAssertEqual(WatchConnectionManager.phoneFinalizationDate(ids[50], defaults: defaults), Date(timeIntervalSince1970: 50))

        let active = snapshot(workoutID: ids[50])
        let context: [String: Any] = [PayloadKey.workoutSnapshot: try XCTUnwrap(WatchWorkoutWire.encode(active)), "logRPE": true]
        let cleaned = WatchConnectionManager.removingWorkoutSnapshot(ids[50], from: context)
        XCTAssertNil(cleaned[PayloadKey.workoutSnapshot])
        XCTAssertEqual(cleaned["logRPE"] as? Bool, true)
        XCTAssertNotNil(WatchConnectionManager.removingWorkoutSnapshot(ids[49], from: context)[PayloadKey.workoutSnapshot])
    }

    func testFinishedSnapshotRecoversUnknownWorkoutAndAllSets() throws {
        let workoutID = UUID()
        let exerciseID = UUID()
        let first = WatchWorkoutSet(id: UUID(), order: 1, weight: 70, reps: 5, completed: true)
        let second = WatchWorkoutSet(id: UUID(), order: 2, weight: 72.5, reps: 4,
                                     completed: true, duration: 45)
        let end = Date(timeIntervalSince1970: 1_700_000_600)
        var source = snapshot(workoutID: workoutID, exerciseID: exerciseID,
                              completed: true, endDate: end)
        source.exercises[0].sets = [first, second]
        let event = WatchWorkoutEvent(
            workoutID: workoutID, sequence: 9, kind: .workoutFinished,
            endDate: end, snapshot: source)

        let hydrated = try XCTUnwrap(manager.resolveWorkout(for: event, in: context))
        _ = try manager.applyWatchEventModelMutation(event, to: hydrated, in: context)

        XCTAssertEqual(hydrated.end, end)
        XCTAssertFalse(hydrated.isCurrentWorkout)
        XCTAssertEqual(hydrated.healthExportState, "watch")
        let sets = (hydrated.workoutExercises?.firstObject as? WorkoutExercise)?
            .workoutSets?.array as? [WorkoutSet]
        XCTAssertEqual(sets?.compactMap(\.uuid), [first.id, second.id])
        XCTAssertEqual(sets?.last?.durationValue, 45)
        try context.save()
    }

    #if DEBUG
    func testWatchStartReceivedDuringTestModeKeepsProvenanceAfterFlagIsOff() throws {
        let previousWatchID = manager.currentWatchWorkoutUuid
        defer { manager.currentWatchWorkoutUuid = previousWatchID }
        SettingsStore.shared.healthTestMode = true
        let source = snapshot()
        let created = WatchWorkoutEvent(workoutID: source.workoutID, sequence: 1,
                                        kind: .workoutCreated, snapshot: source)
        let workout = try XCTUnwrap(manager.resolveWorkout(for: created, in: context))
        _ = try manager.applyWatchEventModelMutation(created, to: workout, in: context)
        try context.save()
        let fresh = container.newBackgroundContext()
        let id = workout.objectID
        try fresh.performAndWait {
            XCTAssertEqual((try fresh.existingObject(with: id) as? Workout)?.healthExportState, "test")
        }

        SettingsStore.shared.healthTestMode = false
        var finished = source
        finished.endDate = source.startDate.addingTimeInterval(600)
        finished.isFinished = true
        let event = WatchWorkoutEvent(workoutID: source.workoutID, sequence: 2,
                                     kind: .workoutFinished, snapshot: finished)
        _ = try manager.applyWatchEventModelMutation(event, to: workout, in: context)
        XCTAssertEqual(workout.healthExportState, "test")
    }

    func testNormalWatchHistoryUsesProvenanceWhilePhoneTestPreferenceIsOn() throws {
        SettingsStore.shared.healthTestMode = true
        for modern in [false, true] {
            let source = snapshot(completed: true, endDate: Date(timeIntervalSince1970: 1_700_000_600))
            let event = WatchWorkoutEvent(workoutID: source.workoutID, sequence: 1,
                kind: .workoutFinished, snapshot: source,
                fieldChanges: modern ? WatchWorkoutFieldChanges() : nil)
            let workout = try XCTUnwrap(manager.resolveWorkout(for: event, in: context))
            _ = try manager.applyWatchEventModelMutation(event, to: workout, in: context)
            XCTAssertEqual(workout.healthExportState, "watch")
            let failure = WatchWorkoutEvent(workoutID: source.workoutID, sequence: 2,
                kind: .workoutFailed, endDate: source.endDate, snapshot: source)
            _ = try manager.applyWatchEventModelMutation(failure, to: workout, in: context)
            XCTAssertEqual(workout.healthExportState, "pending", "Normal history remains retryable after test mode is disabled")
        }
    }

    func testTestProvenanceDoesNotAuthorizeReplacingActivePhoneGraph() throws {
        let phone = Workout.create(context: context)
        phone.isCurrentWorkout = true
        phone.start = Date(timeIntervalSince1970: 1_700_000_000)
        phone.healthExportState = "test"
        let phoneExercise = WorkoutExercise.create(context: context)
        phoneExercise.workout = phone
        let set = WorkoutSet.create(context: context)
        set.workoutExercise = phoneExercise
        let source = snapshot(workoutID: phone.uuid!)
        let event = WatchWorkoutEvent(workoutID: source.workoutID, sequence: 1,
                                     kind: .workoutCreated, snapshot: source)

        _ = try manager.applyWatchEventModelMutation(event, to: phone, in: context)

        XCTAssertFalse(phoneExercise.isDeleted)
        XCTAssertFalse(set.isDeleted)
        XCTAssertTrue((phone.workoutExercises?.array as? [WorkoutExercise] ?? []).contains(phoneExercise))
    }
    #endif

    func testSavedWorkoutUpsertAndDeletePreserveSupportedTemplateFields() throws {
        let routineID = UUID()
        let groupID = UUID()
        let set = WatchWorkoutSet(
            id: UUID(), order: 1, weight: 225, reps: nil, completed: false,
            tag: WorkoutSetTag.warmUp.rawValue, duration: 60, distance: 1_000,
            comment: "Pause at bottom", minTargetReps: 3, maxTargetReps: 5)
        let exercise = WatchWorkoutExercise(
            id: UUID(), order: 1, name: "Template exercise", sets: [set],
            restTimerDuration: 120, exerciseUuid: UUID(), supersetID: groupID,
            comment: "Brace")
        let saved = WatchSavedWorkout(
            id: routineID, title: "Heavy day", exercises: [exercise],
            weightUnit: .pound, comment: "Template note", updatedAt: Date())
        let upsert = WatchWorkoutEvent(
            workoutID: routineID, sequence: 1, kind: .savedWorkoutUpserted,
            savedWorkout: saved)

        _ = try manager.applySavedWorkoutEvent(upsert, in: context)
        try context.save()

        let request: NSFetchRequest<WorkoutRoutine> = WorkoutRoutine.fetchRequest()
        request.predicate = NSPredicate(format: "uuid == %@", routineID as NSUUID)
        let routine = try XCTUnwrap(context.fetch(request).first)
        let storedExercise = try XCTUnwrap(routine.workoutRoutineExercises?.firstObject as? WorkoutRoutineExercise)
        let storedSet = try XCTUnwrap(storedExercise.workoutRoutineSets?.firstObject as? WorkoutRoutineSet)
        XCTAssertNotNil(routine.workoutPlan)
        XCTAssertEqual(routine.comment, "Template note")
        XCTAssertEqual(storedExercise.supersetUuid, groupID)
        XCTAssertEqual(storedExercise.restTimerDurationValue, 120)
        XCTAssertEqual(storedExercise.comment, "Brace")
        XCTAssertEqual(storedSet.durationValue, 60)
        XCTAssertEqual(storedSet.minRepetitionsValue, 3)
        XCTAssertEqual(storedSet.maxRepetitionsValue, 5)
        XCTAssertEqual(storedSet.comment, "Pause at bottom")
        XCTAssertEqual(storedSet.weightValue ?? 0, 102.058, accuracy: 0.01)

        let deleted = WatchWorkoutEvent(
            workoutID: routineID, sequence: 2, kind: .savedWorkoutDeleted)
        _ = try manager.applySavedWorkoutEvent(deleted, in: context)
        try context.save()
        XCTAssertTrue(try context.fetch(request).isEmpty)
    }

    func testSavedWorkoutTrackingPreferencesPublishOnlyAfterSuccessfulSave() throws {
        let previous = UserDefaults.standard.data(forKey: SetTrackingPreferences.storageKey)
        defer { UserDefaults.standard.set(previous, forKey: SetTrackingPreferences.storageKey) }
        var localEditNotifications = 0
        let observer = NotificationCenter.default.addObserver(forName: SetTrackingPreferences.didChangeNotification,
            object: UserDefaults.standard, queue: nil) { _ in localEditNotifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let exerciseID = UUID(), setID = UUID(), routineID = UUID()
        let set = WatchWorkoutSet(id: setID, order: 1, duration: 300, distance: 1_000)
        let exercise = WatchWorkoutExercise(order: 1, name: "Run", sets: [set], exerciseUuid: exerciseID,
            trackingType: SetTrackingType.distanceDuration.rawValue)
        let saved = WatchSavedWorkout(id: routineID, title: "Run", exercises: [exercise], weightUnit: .kilogram, comment: nil, updatedAt: Date())
        let event = WatchWorkoutEvent(workoutID: routineID, sequence: 1, kind: .savedWorkoutUpserted, savedWorkout: saved)
        enum SaveFailure: Error { case expected }
        XCTAssertThrowsError(try WatchConnectionManager.commitWatchEventMutation(in: context,
            save: { throw SaveFailure.expected },
            mutation: { try self.manager.applySavedWorkoutEvent(event, in: self.context) }, didPersist: {}))
        XCTAssertNil(SetTrackingPreferences.override(for: exerciseID))
        XCTAssertNil(SetTrackingPreferences.routineDistance(for: setID))

        try WatchConnectionManager.commitWatchEventMutation(in: context, save: { try self.context.save() },
            mutation: { try self.manager.applySavedWorkoutEvent(event, in: self.context) }, didPersist: {})
        XCTAssertEqual(SetTrackingPreferences.override(for: exerciseID), .distanceDuration)
        XCTAssertEqual(SetTrackingPreferences.routineDistance(for: setID), 1_000)
        XCTAssertEqual(localEditNotifications, 0, "Applying a Watch event must not publish a local edit")
    }

    func testImportedWorkoutNeverBecomesWatchHealthOwned() throws {
        let workout = Workout.create(context: context)
        workout.importSource = "hevy"
        workout.isCurrentWorkout = false
        workout.start = Date(timeIntervalSince1970: 1_700_000_000)
        workout.end = Date(timeIntervalSince1970: 1_700_000_300)
        let source = snapshot(workoutID: workout.uuid!, completed: true,
                              endDate: workout.end)
        manager.applyComplete(source, to: workout, in: context)
        let event = WatchWorkoutEvent(
            workoutID: workout.uuid!, sequence: 3, kind: .workoutFailed,
            endDate: workout.end, snapshot: source)

        _ = try manager.applyWatchEventModelMutation(event, to: workout, in: context)

        XCTAssertEqual(workout.importSource, "hevy")
        XCTAssertNil(workout.healthExportState)
        XCTAssertEqual(workout.healthExportEligibility, .imported)
    }
}

/// The exact preference manager used by both WCSession adapters, wired to an
/// in-memory transport. No pairing, session activation or live app defaults.
final class WatchPreferenceSyncRegressionTests: XCTestCase {
    private final class RecordingDefaults: UserDefaults {
        var writtenKeys: [String] = []

        override func set(_ value: Any?, forKey defaultName: String) {
            writtenKeys.append(defaultName)
            super.set(value, forKey: defaultName)
        }
    }

    private let exerciseID = UUID()
    private let setID = UUID()
    private var suites: [String] = []

    override func tearDown() {
        suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        suites.removeAll()
        super.tearDown()
    }

    private func defaults() throws -> RecordingDefaults {
        let suite = "WatchPreferenceSyncTests." + UUID().uuidString
        suites.append(suite)
        return try XCTUnwrap(RecordingDefaults(suiteName: suite))
    }

    private func payload(timestamp: TimeInterval, type: SetTrackingType = .duration,
                         note: String = "Brace", baseWeight: Double = 20) -> [String: Any] {
        var inventory = PlateInventory().dictionaryRepresentation
        inventory["updatedAt"] = timestamp
        let loadout = PlateLoadout(mode: .barbell(baseWeight), unit: .kilogram, updatedAt: timestamp)
        var tracking = SetTrackingPreferences()
        tracking.overrides[exerciseID.uuidString] = .init(type: type, updatedAt: timestamp)
        tracking.routineDistances[setID.uuidString] = .init(meters: 1_000, updatedAt: timestamp)
        var notes = ExerciseNotes()
        notes.entries[exerciseID.uuidString] = .init(text: note, updatedAt: timestamp)
        var result: [String: Any] = [
            PayloadKey.plateInventory: inventory,
            PayloadKey.plateLoadouts: [exerciseID.uuidString: loadout.dictionaryRepresentation]
        ]
        result.merge(tracking.dictionaryRepresentation) { _, new in new }
        result.merge(notes.dictionaryRepresentation) { _, new in new }
        return result
    }

    func testEqualReceivedContentPersistsOnlyMergeWatermarksWithoutNotifyOrSend() throws {
        let storage = try defaults()
        let queue = DispatchQueue(label: "WatchPreferenceSyncTests.equal")
        var sends = 0
        let manager = WatchPreferenceSyncManager(defaults: storage, queue: queue,
            transmit: { _ in sends += 1; return true })
        var notifications = 0
        let observers = [PlateCalculatorStorageKeys.didChangeNotification,
                         SetTrackingPreferences.didChangeNotification, ExerciseNotes.didChangeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: storage, queue: nil) { _ in notifications += 1 }
        }
        defer { observers.forEach { NotificationCenter.default.removeObserver($0) } }

        queue.sync { manager.applyReceived(payload(timestamp: 10)) }
        XCTAssertEqual(storage.writtenKeys.count, 4)
        storage.writtenKeys.removeAll()
        let original = storage.dictionaryRepresentation()
        queue.sync {
            manager.applyReceived(payload(timestamp: 30))
            manager.applyReceived(payload(timestamp: 30)) // message + context
            manager.flush() // No local send was scheduled by either receipt.
        }

        let watermarkKeys = ["plateCalculator.mergeWatermarks.v1",
                             SetTrackingPreferences.storageKey + ".mergeWatermarks.v1",
                             ExerciseNotes.storageKey + ".mergeWatermarks.v1"]
        XCTAssertEqual(Set(storage.writtenKeys), Set(watermarkKeys))
        XCTAssertEqual(storage.writtenKeys.count, watermarkKeys.count, "Duplicate receipt must not rewrite the same clocks")
        var contentOnly = storage.dictionaryRepresentation()
        watermarkKeys.forEach { contentOnly.removeValue(forKey: $0) }
        XCTAssertTrue(NSDictionary(dictionary: original).isEqual(to: contentOnly), "Content storage remains byte-for-byte unchanged")
        XCTAssertEqual(PlateCalculatorPreferences.load(defaults: storage).inventory?.updatedAt, 30)
        XCTAssertEqual(PlateLoadout.loadAll(defaults: storage)[exerciseID.uuidString]?.updatedAt, 30)
        XCTAssertEqual(SetTrackingPreferences.load(defaults: storage).overrides[exerciseID.uuidString]?.updatedAt, 30)
        XCTAssertEqual(ExerciseNotes.load(defaults: storage).entries[exerciseID.uuidString]?.updatedAt, 30)
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(sends, 0)

        let afterWatermarks = storage.dictionaryRepresentation()
        storage.writtenKeys.removeAll()
        let reloaded = WatchPreferenceSyncManager(defaults: storage, queue: queue,
            transmit: { _ in sends += 1; return true })
        queue.sync { reloaded.applyReceived(payload(timestamp: 20, type: .weightReps, note: "Stale", baseWeight: 45)) }
        XCTAssertTrue(storage.writtenKeys.isEmpty)
        XCTAssertTrue(NSDictionary(dictionary: afterWatermarks).isEqual(to: storage.dictionaryRepresentation()))
        XCTAssertEqual(SetTrackingPreferences.override(for: exerciseID, defaults: storage), .duration)
        XCTAssertEqual(ExerciseNotes.note(for: exerciseID, defaults: storage), "Brace")
    }

    func testChangedRemotePreferencesKeepOriginalMergeTimestampsAndStaySilent() throws {
        let storage = try defaults()
        let queue = DispatchQueue(label: "WatchPreferenceSyncTests.timestamps")
        var sends = 0
        let manager = WatchPreferenceSyncManager(defaults: storage, queue: queue,
            transmit: { _ in sends += 1; return true })
        queue.sync {
            manager.applyReceived(payload(timestamp: 10))
            manager.applyReceived(payload(timestamp: 40, type: .weightReps, note: "New cue", baseWeight: 45))
        }

        XCTAssertEqual(PlateCalculatorPreferences.load(defaults: storage).inventory?.updatedAt, 40,
                       "Equal inventory content advances its effective durable merge clock")
        let storedInventory = try JSONDecoder().decode(PlateInventory.self,
            from: XCTUnwrap(storage.data(forKey: PlateCalculatorStorageKeys.inventory)))
        XCTAssertEqual(storedInventory.updatedAt, 10, "The separate watermark must leave content storage unchanged")
        XCTAssertEqual(PlateLoadout.loadAll(defaults: storage)[exerciseID.uuidString]?.updatedAt, 40)
        XCTAssertEqual(SetTrackingPreferences.load(defaults: storage).overrides[exerciseID.uuidString]?.updatedAt, 40)
        XCTAssertEqual(ExerciseNotes.load(defaults: storage).entries[exerciseID.uuidString]?.updatedAt, 40)
        XCTAssertEqual(sends, 0)
    }

    func testTwoPreferenceManagersConvergeWithBoundedMessagesDespiteDuplicateDelivery() throws {
        let phoneDefaults = try defaults(), watchDefaults = try defaults()
        let queue = DispatchQueue(label: "WatchPreferenceSyncTests.peers")
        var phone: WatchPreferenceSyncManager!
        var watch: WatchPreferenceSyncManager!
        var messages: [[String: Any]] = []
        phone = WatchPreferenceSyncManager(defaults: phoneDefaults, queue: queue, debounceInterval: 60,
            transmit: { payload in
                messages.append(payload)
                watch.applyReceived(payload)
                watch.applyReceived(payload) // Fast message and durable context.
                return true
            })
        watch = WatchPreferenceSyncManager(defaults: watchDefaults, queue: queue, debounceInterval: 60,
            transmit: { payload in
                messages.append(payload)
                phone.applyReceived(payload)
                phone.applyReceived(payload)
                return true
            })
        defer { queue.sync { phone = nil; watch = nil } }
        var phonePayload = payload(timestamp: 10, note: "Phone cue")
        var phoneNotes = try XCTUnwrap(ExerciseNotes(payload: phonePayload))
        phoneNotes.entries[UUID().uuidString] = .init(text: "Phone-only cue", updatedAt: 10)
        phonePayload.merge(phoneNotes.dictionaryRepresentation) { _, new in new }
        var watchPayload = payload(timestamp: 20, type: .weightReps, note: "Watch cue", baseWeight: 45)
        var watchNotes = try XCTUnwrap(ExerciseNotes(payload: watchPayload))
        watchNotes.entries[UUID().uuidString] = .init(text: "Watch-only cue", updatedAt: 20)
        watchPayload.merge(watchNotes.dictionaryRepresentation) { _, new in new }
        queue.sync {
            phone.applyReceived(phonePayload)
            watch.applyReceived(watchPayload)
        }
        phone.requestSync()
        watch.requestSync()
        queue.sync { phone.flush(); watch.flush() }

        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(PlateCalculatorPreferences.load(defaults: phoneDefaults)
            .hasSameContent(as: PlateCalculatorPreferences.load(defaults: watchDefaults)))
        XCTAssertTrue(SetTrackingPreferences.load(defaults: phoneDefaults)
            .hasSameContent(as: SetTrackingPreferences.load(defaults: watchDefaults)))
        XCTAssertTrue(ExerciseNotes.load(defaults: phoneDefaults).hasSameContent(as: ExerciseNotes.load(defaults: watchDefaults)))

        // Later reconnects can publish the union once; receipts never answer.
        for _ in 0..<3 {
            phone.requestSync()
            watch.requestSync()
            queue.sync { phone.flush(); watch.flush() }
        }
        XCTAssertLessThanOrEqual(messages.count, 3)
        phoneDefaults.writtenKeys.removeAll()
        watchDefaults.writtenKeys.removeAll()
        let sent = messages
        queue.sync {
            for payload in sent {
                phone.applyReceived(payload)
                watch.applyReceived(payload)
            }
            phone.flush()
            watch.flush()
        }
        XCTAssertEqual(messages.count, sent.count)
        XCTAssertTrue(phoneDefaults.writtenKeys.isEmpty)
        XCTAssertTrue(watchDefaults.writtenKeys.isEmpty)
    }

    func testLocalPreferenceBurstCoalescesAndUnchangedEncodedContentIsNotResent() throws {
        let storage = try defaults()
        let queue = DispatchQueue(label: "WatchPreferenceSyncTests.local")
        var messages: [[String: Any]] = []
        let manager = WatchPreferenceSyncManager(defaults: storage, queue: queue, debounceInterval: 60,
            transmit: { messages.append($0); return true })
        SetTrackingPreferences.setOverride(.duration, for: exerciseID, defaults: storage)
        SetTrackingPreferences.setOverride(.weightDuration, for: exerciseID, defaults: storage)
        ExerciseNotes.setNote("Brace", for: exerciseID, defaults: storage)
        PlateLoadout(mode: .noBar, unit: .kilogram).save(exerciseKey: exerciseID.uuidString, defaults: storage)
        queue.sync { manager.flush() }
        XCTAssertEqual(messages.count, 1)
        let sent = try XCTUnwrap(messages.first)
        XCTAssertEqual(SetTrackingPreferences(payload: sent)?.overrides[exerciseID.uuidString]?.type, .weightDuration)
        manager.requestSync()
        queue.sync { manager.flush() }
        XCTAssertEqual(messages.count, 1)
    }

    func testFailedPreferenceTransmissionRetriesWithoutAReceiveEcho() throws {
        let storage = try defaults()
        let queue = DispatchQueue(label: "WatchPreferenceSyncTests.retry")
        var attempts = 0
        let manager = WatchPreferenceSyncManager(defaults: storage, queue: queue, debounceInterval: 60,
            transmit: { _ in attempts += 1; return attempts > 1 })
        queue.sync { manager.applyReceived(payload(timestamp: 10)) }
        manager.requestSync()
        queue.sync {
            manager.flush()
            XCTAssertEqual(attempts, 1)
            manager.applyReceived(payload(timestamp: 20))
            manager.flush() // Drain the explicitly pending retry, without waiting.
            XCTAssertEqual(attempts, 2)
            manager.flush()
            XCTAssertEqual(attempts, 2)
        }
    }

    func testContextEqualityIgnoresTransportClocksButKeepsDatesAcknowledgementsAndArtwork() throws {
        var snapshot = WatchWorkoutSnapshot(workoutID: UUID(), startDate: Date(timeIntervalSince1970: 1_000),
            exercises: [WatchWorkoutExercise(order: 1, name: "Squat", sets: [])], revision: 1,
            updatedAt: Date(timeIntervalSince1970: 1_010))
        snapshot.acknowledgedWatchSequence = 2
        var newer = snapshot
        newer.revision = 100
        newer.updatedAt = Date(timeIntervalSince1970: 2_000)
        var context = payload(timestamp: 10)
        context[PayloadKey.workoutSnapshot] = try XCTUnwrap(WatchWorkoutWire.encode(snapshot))
        var newerContext = payload(timestamp: 20)
        newerContext[PayloadKey.workoutSnapshot] = try XCTUnwrap(WatchWorkoutWire.encode(newer))
        XCTAssertTrue(WatchSyncContent.contextsEqual(context, newerContext))

        newer.startDate.addTimeInterval(60)
        XCTAssertNotEqual(WatchSyncContent.workoutContent(snapshot), WatchSyncContent.workoutContent(newer))
        newer = snapshot
        newer.acknowledgedWatchSequence = 3
        XCTAssertNotEqual(WatchSyncContent.workoutContent(snapshot), WatchSyncContent.workoutContent(newer))
        newer = snapshot
        newer.exercises[0].imageData = Data([1, 2, 3])
        XCTAssertNotEqual(WatchSyncContent.workoutContent(snapshot), WatchSyncContent.workoutContent(newer),
                          "A full artwork file must still upgrade its compact snapshot at the same revision")
    }
}

final class WatchLiveProjectionOrderingTests: XCTestCase {
    func testAcknowledgedEditRejectsDelayedPreEditPhoneSnapshot() throws {
        let workoutID = UUID()
        let local = WatchWorkoutSnapshot(workoutID: workoutID, title: "Watch edit", revision: 10)
        let first = WatchWorkoutEvent(workoutID: workoutID, sequence: 4, kind: .workoutCreated, snapshot: local)
        let edit = WatchWorkoutEvent(workoutID: workoutID, sequence: 5, kind: .workoutStructureUpdated, snapshot: local)
        var state = WatchWorkoutPersistedState(snapshot: local, outbox: [first, edit], nextSequence: 5)

        WatchWorkoutPersistence.acknowledge(eventIDs: [first.id], in: &state)
        XCTAssertEqual(state.outbox.map(\.id), [edit.id], "An ACK must never remove the next queued edit")
        WatchWorkoutPersistence.acknowledge(eventIDs: [edit.id], in: &state)
        XCTAssertTrue(state.outbox.isEmpty)
        let encoded = try XCTUnwrap(WatchWorkoutWire.encode(state))
        let restored = try XCTUnwrap(WatchWorkoutWire.decode(WatchWorkoutPersistedState.self, from: encoded))
        let acknowledged = try XCTUnwrap(restored.acknowledgedSequences?[workoutID.uuidString])
        XCTAssertEqual(acknowledged, 5)

        var delayed = local
        delayed.title = "Stale phone title"
        delayed.revision = 100
        delayed.acknowledgedWatchSequence = 4
        XCTAssertFalse(delayed.canReplace(restored.snapshot, acknowledgedSequence: acknowledged),
                       "A larger revision alone must not erase the last acknowledged Watch edit")
        XCTAssertFalse(delayed.canReplace(nil, acknowledgedSequence: acknowledged),
                       "Clearing the projection must not bypass its durable acknowledgement watermark")
        delayed.acknowledgedWatchSequence = 5
        XCTAssertTrue(delayed.canReplace(restored.snapshot, acknowledgedSequence: acknowledged))
    }

    func testDuplicateAckCannotAdvanceAnotherWorkoutOrDropItsEvents() {
        let firstWorkoutID = UUID()
        let secondWorkoutID = UUID()
        let first = WatchWorkoutEvent(workoutID: firstWorkoutID, sequence: 8, kind: .workoutFinished)
        let second = WatchWorkoutEvent(workoutID: secondWorkoutID, sequence: 9, kind: .workoutCreated)
        var state = WatchWorkoutPersistedState(outbox: [first, second], nextSequence: 9)

        WatchWorkoutPersistence.acknowledge(eventIDs: [first.id], in: &state)
        WatchWorkoutPersistence.acknowledge(eventIDs: [first.id, UUID()], in: &state)

        XCTAssertEqual(state.outbox.map(\.id), [second.id])
        XCTAssertEqual(state.acknowledgedSequences?[firstWorkoutID.uuidString], 8)
        XCTAssertNil(state.acknowledgedSequences?[secondWorkoutID.uuidString])
        XCTAssertEqual(state.terminalWorkoutIDs, [firstWorkoutID], "ACKing a legacy terminal event must retain its identity")
    }

    func testLegacyStateStillDecodesAndQueuedFinishKeepsWatchAndTestProvenance() throws {
        let legacy = WatchWorkoutPersistedState(snapshot: WatchWorkoutSnapshot(workoutID: UUID()))
        let legacyData = try XCTUnwrap(WatchWorkoutWire.encode(legacy))
        let decoded = try XCTUnwrap(WatchWorkoutWire.decode(WatchWorkoutPersistedState.self, from: legacyData))
        XCTAssertNil(decoded.acknowledgedSequences)
        XCTAssertNil(decoded.terminalWorkoutIDs)
        XCTAssertNil(decoded.snapshot?.startedOnWatch)
        XCTAssertNil(decoded.snapshot?.acknowledgedWatchSequence)

        var snapshot = try XCTUnwrap(decoded.snapshot)
        snapshot.startedOnWatch = true
        snapshot.healthTestMode = true
        snapshot.acknowledgedWatchSequence = 12
        snapshot.endDate = snapshot.startDate.addingTimeInterval(600)
        snapshot.isFinished = true
        let finish = WatchWorkoutEvent(workoutID: snapshot.workoutID, sequence: 13,
                                       kind: .workoutFinished, snapshot: snapshot)
        let data = try XCTUnwrap(WatchWorkoutWire.encode(finish))
        let restored = try XCTUnwrap(WatchWorkoutWire.decode(WatchWorkoutEvent.self, from: data))

        XCTAssertEqual(restored.snapshot?.startedOnWatch, true)
        XCTAssertEqual(restored.snapshot?.acknowledgedWatchSequence, 12)
        XCTAssertTrue(restored.snapshot?.isHealthTestWorkout == true)
        XCTAssertTrue(restored.snapshot?.isFinishedRecord == true)
    }
}

final class WatchCompanionSyncRegressionTests: XCTestCase {
    private let manager = WatchConnectionManager.shared
    private var previousHealthTestMode: Any?

    override func setUp() {
        super.setUp()
        previousHealthTestMode = UserDefaults.appGroup.object(forKey: UserDefaults.SettingsKeys.healthTestMode.rawValue)
        SettingsStore.shared.healthTestMode = false
    }

    override func tearDown() {
        UserDefaults.appGroup.set(previousHealthTestMode, forKey: UserDefaults.SettingsKeys.healthTestMode.rawValue)
        super.tearDown()
    }

    func testPhoneOwnedStructureDeletionSurvivesWhileUnrelatedPhoneExerciseRemains() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        let workout = Workout.create(context: context)
        workout.isCurrentWorkout = true
        workout.healthExportState = nil
        let original = WorkoutExercise.create(context: context)
        let removed = WorkoutSet.create(context: context)
        removed.uuid = UUID()
        let removedID = removed.uuid!
        let kept = WorkoutSet.create(context: context)
        kept.uuid = UUID()
        removed.workoutExercise = original
        kept.workoutExercise = original
        original.workoutSets = NSOrderedSet(array: [removed, kept])
        original.workout = workout

        let phoneAdded = WorkoutExercise.create(context: context)
        let phoneAddedSet = WorkoutSet.create(context: context)
        phoneAddedSet.uuid = UUID()
        phoneAddedSet.workoutExercise = phoneAdded
        phoneAdded.workoutSets = NSOrderedSet(array: [phoneAddedSet])
        phoneAdded.workout = workout
        workout.workoutExercises = NSOrderedSet(array: [original, phoneAdded])

        let snapshotExercise = WatchWorkoutExercise(
            id: original.uuid!, order: 1, name: "Original", sets: [
                WatchWorkoutSet(id: kept.uuid!, order: 1, weight: 50, reps: 5)
            ])
        let snapshot = WatchWorkoutSnapshot(
            workoutID: workout.uuid!, startDate: Date(timeIntervalSince1970: 1_700_000_000),
            exercises: [snapshotExercise], updatedAt: Date(timeIntervalSince1970: 1_700_000_010))
        let event = WatchWorkoutEvent(
            workoutID: workout.uuid!, sequence: 1, kind: .workoutStructureUpdated,
            snapshot: snapshot, removedSetIDs: [removedID])

        _ = try manager.applyWatchEventModelMutation(event, to: workout, in: context)
        context.processPendingChanges()

        let originalSetIDs = (original.workoutSets?.array as? [WorkoutSet] ?? []).compactMap(\.uuid)
        XCTAssertFalse(originalSetIDs.contains(removedID))
        let remainingRemoved = try context.fetch(WorkoutSet.fetchRequest()).filter { $0.uuid == removedID }
        XCTAssertTrue(remainingRemoved.isEmpty)
        XCTAssertEqual(originalSetIDs, [kept.uuid!])
        let workoutExerciseIDs = (workout.workoutExercises?.array as? [WorkoutExercise] ?? []).compactMap(\.uuid)
        XCTAssertEqual(Set(workoutExerciseIDs), Set([original.uuid!, phoneAdded.uuid!]))
        XCTAssertFalse(phoneAdded.isDeleted)
        XCTAssertEqual((phoneAdded.workoutSets?.firstObject as? WorkoutSet)?.uuid, phoneAddedSet.uuid)
    }

    func testMaskedStructuralDeletionStillRemovesExplicitSet() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        let workout = Workout.create(context: context)
        workout.isCurrentWorkout = true
        let exercise = WorkoutExercise.create(context: context)
        let removed = WorkoutSet.create(context: context)
        let kept = WorkoutSet.create(context: context)
        let removedID = removed.uuid!
        removed.workoutExercise = exercise
        kept.workoutExercise = exercise
        exercise.workoutSets = NSOrderedSet(array: [removed, kept])
        exercise.workout = workout
        workout.workoutExercises = NSOrderedSet(array: [exercise])
        let snapshot = WatchWorkoutSnapshot(
            workoutID: workout.uuid!, startDate: workout.safeStart,
            exercises: [WatchWorkoutExercise(
                id: exercise.uuid!, order: 1, name: "Exercise",
                sets: [WatchWorkoutSet(id: kept.uuid!, order: 1, weight: 50, reps: 5)])])
        let event = WatchWorkoutEvent(
            workoutID: workout.uuid!, sequence: 2, kind: .workoutStructureUpdated,
            snapshot: snapshot, removedSetIDs: [removedID],
            fieldChanges: WatchWorkoutFieldChanges())

        _ = try manager.applyWatchEventModelMutation(event, to: workout, in: context)
        context.processPendingChanges()

        let remainingRemoved = try context.fetch(WorkoutSet.fetchRequest()).filter { $0.uuid == removedID }
        XCTAssertTrue(remainingRemoved.isEmpty)
        XCTAssertEqual((exercise.workoutSets?.array as? [WorkoutSet])?.compactMap(\.uuid), [kept.uuid!])
    }

    func testMaskedUnrelatedEditDoesNotResurrectPhoneDeletedExerciseOrSet() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        let workout = Workout.create(context: context)
        workout.isCurrentWorkout = true
        let exercise = WorkoutExercise.create(context: context)
        let set = WorkoutSet.create(context: context)
        set.comment = "Before"
        set.workoutExercise = exercise
        exercise.workoutSets = NSOrderedSet(array: [set])
        exercise.workout = workout
        workout.workoutExercises = NSOrderedSet(array: [exercise])

        let phoneDeletedSetID = UUID()
        let phoneDeletedExerciseID = UUID()
        let staleSet = WatchWorkoutSet(id: phoneDeletedSetID, order: 2, weight: 40, reps: 8)
        let staleExercise = WatchWorkoutExercise(
            id: phoneDeletedExerciseID, order: 2, name: "Deleted on phone",
            sets: [WatchWorkoutSet(order: 1, weight: 20, reps: 10)])
        let originalSet = WatchWorkoutSet(id: set.uuid!, order: 1, weight: 60, reps: 5,
                                          comment: "Before")
        let originalExercise = WatchWorkoutExercise(
            id: exercise.uuid!, order: 1, name: "Kept", sets: [originalSet, staleSet])
        let previous = WatchWorkoutSnapshot(
            workoutID: workout.uuid!, exercises: [originalExercise, staleExercise])
        var next = previous
        next.exercises[0].sets[0].comment = "Watch edit"
        let changes = WatchWorkoutFieldChanges.between(previous: previous, next: next)
        XCTAssertEqual(changes.addedExerciseIDs, [])
        XCTAssertEqual(changes.addedSetIDs, [])
        let event = WatchWorkoutEvent(
            workoutID: workout.uuid!, sequence: 3, kind: .workoutStructureUpdated,
            snapshot: next, fieldChanges: changes)

        _ = try manager.applyWatchEventModelMutation(event, to: workout, in: context)
        context.processPendingChanges()

        XCTAssertEqual((workout.workoutExercises?.array as? [WorkoutExercise])?.compactMap(\.uuid),
                       [exercise.uuid!])
        XCTAssertEqual((exercise.workoutSets?.array as? [WorkoutSet])?.compactMap(\.uuid),
                       [set.uuid!])
        XCTAssertEqual(set.comment, "Watch edit")
    }

    func testMaskedExplicitWatchExerciseAndSetAdditionsAreCreated() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        let workout = Workout.create(context: context)
        workout.isCurrentWorkout = true
        let exercise = WorkoutExercise.create(context: context)
        let set = WorkoutSet.create(context: context)
        set.workoutExercise = exercise
        exercise.workoutSets = NSOrderedSet(array: [set])
        exercise.workout = workout
        workout.workoutExercises = NSOrderedSet(array: [exercise])

        let originalExercise = WatchWorkoutExercise(
            id: exercise.uuid!, order: 1, name: "Existing",
            sets: [WatchWorkoutSet(id: set.uuid!, order: 1, weight: 50, reps: 5)])
        let previous = WatchWorkoutSnapshot(workoutID: workout.uuid!, exercises: [originalExercise])
        let addedSet = WatchWorkoutSet(order: 2, weight: 55, reps: 4, comment: "Added set")
        let addedExercise = WatchWorkoutExercise(
            order: 2, name: "Added exercise",
            sets: [WatchWorkoutSet(order: 1, weight: 25, reps: 12)],
            exerciseUuid: UUID(), comment: "Added exercise note")
        var next = previous
        next.exercises[0].sets.append(addedSet)
        next.exercises.append(addedExercise)
        WatchWorkoutEditing.normalize(&next)
        let changes = WatchWorkoutFieldChanges.between(previous: previous, next: next)
        XCTAssertEqual(Set(changes.addedExerciseIDs ?? []), [addedExercise.id])
        XCTAssertEqual(Set(changes.addedSetIDs ?? []),
                       Set([addedSet.id, addedExercise.sets[0].id]))
        let event = WatchWorkoutEvent(
            workoutID: workout.uuid!, sequence: 4, kind: .workoutStructureUpdated,
            snapshot: next, fieldChanges: changes)

        _ = try manager.applyWatchEventModelMutation(event, to: workout, in: context)
        context.processPendingChanges()

        let exercises = workout.workoutExercises?.array as? [WorkoutExercise] ?? []
        XCTAssertEqual(exercises.compactMap(\.uuid), [exercise.uuid!, addedExercise.id])
        let existingSets = exercise.workoutSets?.array as? [WorkoutSet] ?? []
        XCTAssertEqual(existingSets.compactMap(\.uuid), [set.uuid!, addedSet.id])
        XCTAssertEqual(existingSets.last?.comment, "Added set")
        let createdExercise = try XCTUnwrap(exercises.last)
        XCTAssertEqual(createdExercise.comment, "Added exercise note")
        XCTAssertEqual((createdExercise.workoutSets?.firstObject as? WorkoutSet)?.uuid,
                       addedExercise.sets[0].id)
    }

    func testMaskedUnrelatedEditPreservesConcurrentPhoneSetValuesAndNotes() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        let workout = Workout.create(context: context)
        workout.isCurrentWorkout = true
        workout.title = "Phone title"
        workout.comment = "Phone workout note"
        let exercise = WorkoutExercise.create(context: context)
        exercise.comment = "Phone exercise note"
        exercise.restTimerDurationValue = 60
        let set = WorkoutSet.create(context: context)
        set.weight = 140
        set.repetitions = 11
        set.comment = "Phone set note"
        set.workoutExercise = exercise
        exercise.workoutSets = NSOrderedSet(array: [set])
        exercise.workout = workout
        workout.workoutExercises = NSOrderedSet(array: [exercise])

        let watchSet = WatchWorkoutSet(id: set.uuid!, order: 1, weight: 80, reps: 5,
                                       comment: "Stale Watch note")
        let watchExercise = WatchWorkoutExercise(
            id: exercise.uuid!, order: 1, name: "Exercise", sets: [watchSet],
            restTimerDuration: 120, comment: "Stale exercise note")
        let snapshot = WatchWorkoutSnapshot(
            workoutID: workout.uuid!, title: "Stale title", startDate: workout.safeStart,
            exercises: [watchExercise], comment: "Stale workout note")
        let changes = WatchWorkoutFieldChanges(
            exercises: [exercise.uuid!.uuidString: ["restTimerDuration"]])
        let event = WatchWorkoutEvent(
            workoutID: workout.uuid!, sequence: 2, kind: .workoutStructureUpdated,
            snapshot: snapshot, fieldChanges: changes)

        _ = try manager.applyWatchEventModelMutation(event, to: workout, in: context)

        XCTAssertEqual(workout.title, "Phone title")
        XCTAssertEqual(workout.comment, "Phone workout note")
        XCTAssertEqual(exercise.comment, "Phone exercise note")
        XCTAssertEqual(exercise.restTimerDurationValue, 120)
        XCTAssertEqual(set.weight?.doubleValue, 140)
        XCTAssertEqual(set.repetitions?.intValue, 11)
        XCTAssertEqual(set.comment, "Phone set note")
    }

    func testUnitOnlyConversionMaskDoesNotOverwriteConcurrentPhoneWeight() throws {
        let exerciseID = UUID()
        let setID = UUID()
        let kilograms = WatchWorkoutSnapshot(
            workoutID: UUID(), exercises: [WatchWorkoutExercise(
                id: exerciseID, order: 1, name: "Exercise",
                sets: [WatchWorkoutSet(id: setID, order: 1, weight: 100, reps: 5)])],
            weightUnit: .kilogram)
        let pounds = WatchWorkoutEditing.converting(kilograms, to: .pound)
        let changes = WatchWorkoutFieldChanges.between(previous: kilograms, next: pounds)
        XCTAssertFalse(changes.sets[setID.uuidString]?.contains("weight") == true)

        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        let workout = Workout.create(context: context)
        workout.isCurrentWorkout = true
        let exercise = WorkoutExercise.create(context: context)
        exercise.uuid = exerciseID
        let set = WorkoutSet.create(context: context)
        set.uuid = setID
        set.weight = 130
        set.workoutExercise = exercise
        exercise.workoutSets = NSOrderedSet(array: [set])
        exercise.workout = workout
        workout.workoutExercises = NSOrderedSet(array: [exercise])
        var incoming = pounds
        incoming.workoutID = workout.uuid!
        let event = WatchWorkoutEvent(
            workoutID: workout.uuid!, sequence: 3, kind: .workoutStructureUpdated,
            snapshot: incoming, fieldChanges: changes)

        _ = try manager.applyWatchEventModelMutation(event, to: workout, in: context)

        XCTAssertEqual(set.weight?.doubleValue, 130)
    }

    func testModernFinishPreservesKnownConcurrentPhoneGraphAndMetadata() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        let workout = Workout.create(context: context)
        let originalStart = Date(timeIntervalSince1970: 1_700_000_000)
        workout.isCurrentWorkout = true
        workout.start = originalStart
        workout.title = "Phone title"
        workout.comment = "Phone note"
        let exercise = WorkoutExercise.create(context: context)
        exercise.comment = "Phone exercise"
        let set = WorkoutSet.create(context: context)
        set.weight = 150
        set.repetitions = 9
        set.isCompleted = true
        set.comment = "Phone set"
        set.workoutExercise = exercise
        exercise.workoutSets = NSOrderedSet(array: [set])
        exercise.workout = workout
        workout.workoutExercises = NSOrderedSet(array: [exercise])

        let end = originalStart.addingTimeInterval(600)
        let staleSnapshot = WatchWorkoutSnapshot(
            workoutID: workout.uuid!, title: "Stale Watch title",
            startDate: originalStart.addingTimeInterval(30), endDate: end,
            exercises: [], sessionEffort: 8, comment: "Stale Watch note", isFinished: true)
        let event = WatchWorkoutEvent(
            workoutID: workout.uuid!, sequence: 4, kind: .workoutFinished,
            endDate: end, sessionEffort: 8, snapshot: staleSnapshot,
            fieldChanges: WatchWorkoutFieldChanges())

        _ = try manager.applyWatchEventModelMutation(event, to: workout, in: context)

        XCTAssertEqual(workout.start, originalStart)
        XCTAssertEqual(workout.end, end)
        XCTAssertEqual(workout.title, "Phone title")
        XCTAssertEqual(workout.comment, "Phone note")
        XCTAssertEqual(workout.sessionEffortValue, 8)
        XCTAssertFalse(workout.isCurrentWorkout)
        XCTAssertEqual(workout.healthExportState, "watch")
        XCTAssertFalse(exercise.isDeleted)
        XCTAssertFalse(set.isDeleted)
        XCTAssertEqual(set.weight?.doubleValue, 150)
        XCTAssertEqual(set.repetitions?.intValue, 9)
        XCTAssertEqual(set.comment, "Phone set")
    }

    func testFixedDisplayEndDateMarkedActiveDoesNotDisplacePhoneCurrent() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        let phone = Workout.create(context: context)
        phone.isCurrentWorkout = true
        phone.start = Date(timeIntervalSince1970: 1_700_000_000)
        let phoneID = phone.uuid!
        let watchID = UUID()
        let fixedEnd = Date(timeIntervalSince1970: 1_700_000_300)
        var snapshot = WatchWorkoutSnapshot(
            workoutID: watchID, title: "Fixed display", startDate: phone.start!,
            endDate: fixedEnd, updatedAt: fixedEnd, isFinished: false)
        snapshot.isFinished = false
        let event = WatchWorkoutEvent(
            workoutID: watchID, sequence: 1, kind: .workoutCreated, snapshot: snapshot)

        manager.currentWatchWorkoutUuid = nil
        XCTAssertFalse(snapshot.isFinishedRecord)
        XCTAssertNil(try manager.resolveWorkout(for: event, in: context))
        XCTAssertTrue(phone.isCurrentWorkout)
        XCTAssertEqual(try context.fetch(Workout.currentWorkoutFetchRequest).map(\.uuid), [phoneID])

        context.delete(phone)
        context.processPendingChanges()
        let hydrated = try XCTUnwrap(manager.resolveWorkout(for: event, in: context))
        XCTAssertTrue(hydrated.isCurrentWorkout)
        XCTAssertEqual(hydrated.end, fixedEnd)
        XCTAssertEqual(hydrated.healthExportState, "watch")
    }

    func testFinishedWatchEventLeavesImportedWorkoutUntouched() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        let imported = Workout.create(context: context)
        imported.importSource = "hevy"
        imported.isCurrentWorkout = false
        imported.start = Date(timeIntervalSince1970: 1_700_000_000)
        let originalEnd = Date(timeIntervalSince1970: 1_700_000_120)
        imported.end = originalEnd
        imported.title = "Imported title"
        let exercise = WorkoutExercise.create(context: context)
        let set = WorkoutSet.create(context: context)
        set.uuid = UUID()
        set.workoutExercise = exercise
        exercise.workoutSets = NSOrderedSet(array: [set])
        exercise.workout = imported
        imported.workoutExercises = NSOrderedSet(array: [exercise])

        let snapshot = WatchWorkoutSnapshot(
            workoutID: imported.uuid!, title: "Watch replacement", startDate: imported.start!,
            endDate: originalEnd.addingTimeInterval(600),
            exercises: [], updatedAt: originalEnd, isFinished: true)
        let event = WatchWorkoutEvent(
            workoutID: imported.uuid!, sequence: 2, kind: .workoutFinished,
            endDate: snapshot.endDate, snapshot: snapshot)

        _ = try manager.applyWatchEventModelMutation(event, to: imported, in: context)

        XCTAssertEqual(imported.importSource, "hevy")
        XCTAssertEqual(imported.title, "Imported title")
        XCTAssertEqual(imported.end, originalEnd)
        XCTAssertNil(imported.healthExportState)
        XCTAssertEqual(imported.healthExportEligibility, .imported)
        XCTAssertEqual((imported.workoutExercises?.firstObject as? WorkoutExercise)?.uuid, exercise.uuid)
    }
}

final class ExerciseNoteWireTests: XCTestCase {
    func testPinnedNotesRoundTripWithoutChangingTransientComment() throws {
        let exercise = WatchWorkoutExercise(order: 1, name: "Lateral Flexion", sets: [],
            exerciseUuid: UUID(), comment: "Tired today", exerciseNote: "Seat height 4",
            routineNote: "Keep the movement slow", routineExerciseID: UUID())
        let data = try XCTUnwrap(WatchWorkoutWire.encode(exercise))
        XCTAssertEqual(try XCTUnwrap(WatchWorkoutWire.decode(WatchWorkoutExercise.self, from: data)), exercise)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "exerciseNote")
        legacy.removeValue(forKey: "routineNote")
        legacy.removeValue(forKey: "routineExerciseID")
        let decoded = try XCTUnwrap(WatchWorkoutWire.decode(WatchWorkoutExercise.self,
            from: JSONSerialization.data(withJSONObject: legacy)))
        XCTAssertNil(decoded.exerciseNote)
        XCTAssertNil(decoded.routineNote)
        XCTAssertNil(decoded.routineExerciseID)
        XCTAssertEqual(decoded.comment, "Tired today")
    }

    func testDisplayOnlyPinnedNotesDoNotBecomeWorkoutEditFields() {
        let exercise = WatchWorkoutExercise(order: 1, name: "Row", sets: [])
        let previous = WatchWorkoutSnapshot(workoutID: UUID(), startDate: Date(), exercises: [exercise])
        var next = previous
        next.exercises[0].exerciseNote = "New catalog cue"
        next.exercises[0].routineNote = "New plan cue"
        let changes = WatchWorkoutFieldChanges.between(previous: previous, next: next)
        XCTAssertTrue(changes.exercises.isEmpty)
        XCTAssertTrue(changes.workout.isEmpty)
        XCTAssertNil(next.exercises[0].comment)
    }
}

final class WatchWorkoutLibraryCompactionTests: XCTestCase {
    func testHistoryMediaMovesToStableCacheKeysWithoutChangingWorkoutResults() throws {
        let catalogID = UUID()
        let image = Data(repeating: 42, count: 64 * 1_024)
        let exercise = WatchWorkoutExercise(order: 1, name: "Squat",
            sets: [WatchWorkoutSet(order: 1, weight: 80, reps: 5, rpe: 8, completed: true)],
            exerciseUuid: catalogID, imageData: image)
        var history = WatchWorkoutSnapshot(workoutID: UUID(), startDate: Date(timeIntervalSince1970: 1_000),
            endDate: Date(timeIntervalSince1970: 2_000), exercises: [exercise],
            weightUnit: .pound, library: [WatchExercisePick(id: catalogID, name: "Squat", muscle: nil, imageURL: nil)],
            updatedAt: Date(timeIntervalSince1970: 2_000), isFinished: true)
        history.startedOnWatch = true
        history.healthTestMode = true
        let original = WatchWorkoutLibrary(generatedAt: Date(timeIntervalSince1970: 3_000), exercises: [],
            savedWorkouts: [], history: [history], weightUnit: .pound)

        let compact = original.removingHistoryMedia()
        let entries = original.historyMediaForCaching
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.data, image)
        XCTAssertEqual(compact.history.first?.exercises.first?.imageURL, entries.first?.url.absoluteString)
        XCTAssertNil(compact.history.first?.exercises.first?.imageData)
        XCTAssertNil(compact.history.first?.library)
        XCTAssertEqual(compact.history.first?.exercises.first?.sets, exercise.sets)
        XCTAssertEqual(compact.history.first?.workoutID, history.workoutID)
        XCTAssertEqual(compact.history.first?.weightUnit, .pound)
        XCTAssertEqual(compact.history.first?.startedOnWatch, true)
        XCTAssertEqual(compact.history.first?.healthTestMode, true)
        XCTAssertEqual(compact.history.first?.isFinishedRecord, true)
        XCTAssertEqual(compact, compact.removingHistoryMedia(), "Compaction must be idempotent")
        XCTAssertEqual(original.history.first?.exercises.first?.imageData, image, "The received/active value is immutable")

        let legacyData = try XCTUnwrap(WatchWorkoutWire.encode(original))
        let decoded = try XCTUnwrap(WatchWorkoutWire.decode(WatchWorkoutLibrary.self, from: legacyData))
        XCTAssertEqual(decoded.removingHistoryMedia(), compact)
        let compactData = try XCTUnwrap(WatchWorkoutWire.encode(compact))
        XCTAssertLessThan(compactData.count, legacyData.count / 10)
    }

    func testHistoryCompactionPreservesRemoteImagesAndSavedWorkoutArtwork() {
        let remote = "https://example.com/exercise.gif"
        let exercise = WatchWorkoutExercise(order: 1, name: "Press", sets: [],
            imageURL: remote, imageData: Data([1, 2, 3]))
        let saved = WatchSavedWorkout(id: UUID(), title: "Saved", exercises: [exercise],
            weightUnit: .kilogram, updatedAt: Date(timeIntervalSince1970: 1_000))
        let library = WatchWorkoutLibrary(generatedAt: saved.updatedAt, exercises: [], savedWorkouts: [saved],
            history: [WatchWorkoutSnapshot(workoutID: UUID(), exercises: [exercise])], weightUnit: .kilogram)

        let compact = library.removingHistoryMedia()
        XCTAssertEqual(compact.history.first?.exercises.first?.imageURL, remote)
        XCTAssertEqual(compact.savedWorkouts, [saved])
        XCTAssertEqual(library.historyMediaForCaching.first?.url.absoluteString, remote)
        XCTAssertTrue(compact.historyMediaForCaching.isEmpty)
    }

    func testLibraryContentEqualityIgnoresOnlyTransportClocks() {
        let library = WatchWorkoutLibrary(generatedAt: Date(timeIntervalSince1970: 1_000), exercises: [],
            savedWorkouts: [], history: [], weightUnit: .kilogram, revision: 1)
        var newer = library
        newer.generatedAt.addTimeInterval(1_000)
        newer.revision = 20
        XCTAssertTrue(library.hasSameContent(as: newer))
        newer.weightUnit = .pound
        XCTAssertFalse(library.hasSameContent(as: newer))
    }
}

#if WATCH_WORKOUT_STORE_TESTS
final class WatchWorkoutStoreConcurrencyTests: XCTestCase {
    private var suites: [String] = []
    private var directories: [URL] = []
    private let key = "WatchWorkoutStoreConcurrencyTests.state"

    override func tearDown() {
        suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    private func emptyLibrary() -> WatchWorkoutLibrary {
        WatchWorkoutLibrary(generatedAt: Date(timeIntervalSince1970: 1_000), exercises: [],
            savedWorkouts: [], history: [], weightUnit: .kilogram)
    }

    private func makeStore(
        bundledLibrary: (() -> WatchWorkoutLibrary)? = nil,
        encode: @escaping (WatchWorkoutPersistedState) -> Data? = { WatchWorkoutWire.encode($0) }
    ) throws -> (store: WatchWorkoutStore, defaults: UserDefaults, url: URL) {
        let suite = "WatchWorkoutStoreConcurrencyTests." + UUID().uuidString
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        directories.append(directory)
        let url = directory.appendingPathComponent("Library.json")
        let fallback = emptyLibrary()
        return (WatchWorkoutStore(defaults: defaults, defaultsKey: key, libraryURL: url,
            debounceInterval: 60, loadLibrarySynchronously: true, bundledLibrary: bundledLibrary ?? { fallback }, encode: encode), defaults, url)
    }

    @discardableResult
    private func flush(_ store: WatchWorkoutStore) throws -> [WatchWorkoutEvent] {
        let completed = expectation(description: "persistence barrier")
        var result: Result<[WatchWorkoutEvent], Error>?
        store.flushPersistence { result = $0; completed.fulfill() }
        wait(for: [completed], timeout: 3)
        return try XCTUnwrap(result).get()
    }

    func testSleepingEncoderDoesNotBlockLibrarySnapshotOrOutboxReaders() throws {
        let started = expectation(description: "encoder started")
        let completed = expectation(description: "checkpoint completed")
        let readers = expectation(description: "readers completed while encoding")
        let readersFinished = DispatchSemaphore(value: 0)
        let fixture = try makeStore(encode: { state in
            started.fulfill()
            Thread.sleep(forTimeInterval: 0.05)
            XCTAssertEqual(readersFinished.wait(timeout: .now() + 1), .success,
                           "Readers must not wait for the encoder's lock")
            return WatchWorkoutWire.encode(state)
        })
        let snapshot = WatchWorkoutSnapshot(workoutID: UUID(), revision: 1)
        try fixture.store.replaceSnapshot(snapshot)
        fixture.store.flushPersistence { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            completed.fulfill()
        }
        wait(for: [started], timeout: 2)
        DispatchQueue.global().async {
            XCTAssertTrue(fixture.store.library().history.isEmpty)
            XCTAssertEqual(fixture.store.snapshot()?.workoutID, snapshot.workoutID)
            XCTAssertTrue(fixture.store.pendingEvents().isEmpty)
            readersFinished.signal()
            readers.fulfill()
        }
        wait(for: [readers, completed], timeout: 3)
    }

    func testLibraryReadsAndNonLibraryEditsUseTheCachedProjection() throws {
        var loads = 0
        let library = emptyLibrary()
        let fixture = try makeStore(bundledLibrary: { loads += 1; return library })
        var publications = 0
        let observer = NotificationCenter.default.addObserver(forName: WatchWorkoutStore.libraryDidChange,
            object: fixture.store, queue: nil) { _ in publications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        for _ in 0..<100 { XCTAssertEqual(fixture.store.library(), library) }
        _ = try fixture.store.commitEvent(snapshotChange: .keep) { sequence, _ in
            WatchWorkoutEvent(workoutID: UUID(), sequence: sequence, kind: .setUpdated)
        }
        for _ in 0..<100 { XCTAssertEqual(fixture.store.library(), library) }
        XCTAssertEqual(loads, 1, "The bundled catalog is loaded only at initialization")
        XCTAssertEqual(publications, 0, "Live set edits cannot rebuild or republish history")
        try flush(fixture.store)
    }

    func testRapidEditsEncodeOneLatestCheckpoint() throws {
        var encodedRevisions: [Int64] = []
        let fixture = try makeStore(encode: { state in
            encodedRevisions.append(state.snapshot?.revision ?? 0)
            return WatchWorkoutWire.encode(state)
        })
        var snapshot = WatchWorkoutSnapshot(workoutID: UUID(), revision: 0)
        for revision in 1...100 {
            snapshot.revision = Int64(revision)
            try fixture.store.replaceSnapshot(snapshot)
        }
        try flush(fixture.store)
        XCTAssertEqual(encodedRevisions, [100])
        let persisted = try XCTUnwrap(fixture.defaults.data(forKey: key))
        XCTAssertEqual(WatchWorkoutWire.decode(WatchWorkoutPersistedState.self, from: persisted)?.snapshot?.revision, 100)
    }

    func testSlowOlderCheckpointCannotOverwriteANewerEditOrSequence() throws {
        let started = expectation(description: "first checkpoint encoding")
        let firstDone = expectation(description: "first checkpoint saved")
        let secondDone = expectation(description: "second checkpoint saved")
        let release = DispatchSemaphore(value: 0)
        var encodedSequences: [Int64] = []
        let fixture = try makeStore(encode: { state in
            encodedSequences.append(state.nextSequence)
            if state.nextSequence == 1 {
                started.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
            }
            return WatchWorkoutWire.encode(state)
        })
        let workoutID = UUID()
        let first = try fixture.store.commitEvent(snapshotChange: .keep) { sequence, _ in
            WatchWorkoutEvent(workoutID: workoutID, sequence: sequence, kind: .setUpdated)
        }
        fixture.store.flushPersistence { result in
            switch result {
            case .success(let events): XCTAssertEqual(events.map(\.id), [first.id])
            case .failure(let error): XCTFail(error.localizedDescription)
            }
            firstDone.fulfill()
        }
        wait(for: [started], timeout: 2)
        let second = try fixture.store.commitEvent(snapshotChange: .keep) { sequence, _ in
            WatchWorkoutEvent(workoutID: workoutID, sequence: sequence, kind: .setUpdated)
        }
        fixture.store.flushPersistence { result in
            switch result {
            case .success(let events): XCTAssertEqual(events.map(\.id), [first.id, second.id])
            case .failure(let error): XCTFail(error.localizedDescription)
            }
            secondDone.fulfill()
        }
        release.signal()
        wait(for: [firstDone, secondDone], timeout: 3)
        XCTAssertEqual(encodedSequences, [1, 2])
        let data = try XCTUnwrap(fixture.defaults.data(forKey: key))
        let restored = try XCTUnwrap(WatchWorkoutWire.decode(WatchWorkoutPersistedState.self, from: data))
        XCTAssertEqual(restored.nextSequence, 2)
        XCTAssertEqual(restored.outbox.map(\.id), [first.id, second.id])
    }

    func testFailedEncodingCannotProduceADurableOutboxReceipt() throws {
        var fail = true
        let fixture = try makeStore(encode: { fail ? nil : WatchWorkoutWire.encode($0) })
        let event = try fixture.store.commitEvent(snapshotChange: .keep) { sequence, _ in
            WatchWorkoutEvent(workoutID: UUID(), sequence: sequence, kind: .setUpdated)
        }
        XCTAssertThrowsError(try flush(fixture.store))
        XCTAssertNil(fixture.defaults.data(forKey: key))
        XCTAssertEqual(fixture.store.pendingEvents().map(\.id), [event.id])
        fail = false
        XCTAssertEqual(try flush(fixture.store).map(\.id), [event.id])
    }

    func testFailedSavedWorkoutEncodingDoesNotPublishOrConsumeSequence() throws {
        var fail = true
        let fixture = try makeStore(encode: { fail ? nil : WatchWorkoutWire.encode($0) })
        let saved = WatchSavedWorkout(id: UUID(), title: "Saved", exercises: [],
            weightUnit: .kilogram, updatedAt: Date(timeIntervalSince1970: 1_000))
        XCTAssertThrowsError(try fixture.store.commitEvent(snapshotChange: .keep) { sequence, _ in
            WatchWorkoutEvent(workoutID: saved.id, sequence: sequence, kind: .savedWorkoutUpserted, savedWorkout: saved)
        })
        XCTAssertTrue(fixture.store.pendingEvents().isEmpty)
        XCTAssertTrue(fixture.store.library().savedWorkouts.isEmpty)
        XCTAssertNil(fixture.defaults.data(forKey: key))
        fail = false
        let event = try fixture.store.commitEvent(snapshotChange: .keep) { sequence, _ in
            WatchWorkoutEvent(workoutID: saved.id, sequence: sequence, kind: .savedWorkoutUpserted, savedWorkout: saved)
        }
        XCTAssertEqual(event.sequence, 1)
        XCTAssertEqual(fixture.store.library().savedWorkouts.map(\.id), [saved.id])
        let data = try XCTUnwrap(fixture.defaults.data(forKey: key))
        XCTAssertEqual(WatchWorkoutWire.decode(WatchWorkoutPersistedState.self, from: data)?.outbox.map(\.id), [event.id])
        try flush(fixture.store)
    }

    func testAcknowledgedHistorySurvivesReloadWithoutReplayingTheEvent() throws {
        let fixture = try makeStore()
        let snapshot = WatchWorkoutSnapshot(workoutID: UUID(), endDate: Date(), isFinished: true)
        let event = try fixture.store.commitEvent(snapshotChange: .keep) { sequence, _ in
            WatchWorkoutEvent(workoutID: snapshot.workoutID, sequence: sequence, kind: .workoutFinished, snapshot: snapshot)
        }
        try flush(fixture.store)
        try fixture.store.acknowledge(eventIDs: [event.id])
        try flush(fixture.store)
        let restored = WatchWorkoutStore(defaults: fixture.defaults, defaultsKey: key, libraryURL: fixture.url,
            loadLibrarySynchronously: true, bundledLibrary: { self.emptyLibrary() })
        XCTAssertTrue(restored.pendingEvents().isEmpty)
        XCTAssertEqual(restored.library().history.map(\.workoutID), [snapshot.workoutID])
    }

    func testTerminalTombstonesRejectStaleAndLegacyPhoneSnapshotsAfterAckAndRelaunch() throws {
        for kind in [WatchWorkoutEventKind.workoutFinished, .workoutDiscarded] {
            let fixture = try makeStore()
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            var active = WatchWorkoutSnapshot(workoutID: UUID(), startDate: start, revision: 4, updatedAt: start, isFinished: false)
            try fixture.store.replaceSnapshot(active)
            var terminal = active
            terminal.endDate = start.addingTimeInterval(600)
            terminal.isFinished = true
            let event = try fixture.store.commitEvent(snapshotChange: .replace(kind == .workoutFinished ? terminal : nil)) { sequence, _ in
                WatchWorkoutEvent(workoutID: active.workoutID, sequence: sequence, kind: kind,
                                  snapshot: terminal, fieldChanges: WatchWorkoutFieldChanges())
            }
            try fixture.store.clearSnapshot()
            try fixture.store.acknowledge(eventIDs: [event.id])
            try flush(fixture.store)
            let restored = WatchWorkoutStore(defaults: fixture.defaults, defaultsKey: key, libraryURL: fixture.url,
                loadLibrarySynchronously: true, bundledLibrary: { self.emptyLibrary() })
            XCTAssertNil(restored.snapshot())
            XCTAssertTrue(restored.pendingEvents().isEmpty)
            active.revision = 1_000
            active.acknowledgedWatchSequence = event.sequence
            XCTAssertEqual(try restored.replaceSnapshot(active, fromPhone: true), .rejected)
            active.acknowledgedWatchSequence = nil
            XCTAssertEqual(try restored.replaceSnapshot(active, fromPhone: true), .rejected,
                           "Legacy peers without a watermark must also respect terminal identities")
            active.workoutID = UUID()
            XCTAssertEqual(try restored.replaceSnapshot(active, fromPhone: true), .changed)
            try flush(restored)
        }
    }

    func testRecoveryRejectsDiscardedProjectionAndRetainsFinishedFinalizationAcrossReload() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for kind in [WatchWorkoutEventKind.workoutDiscarded, .workoutFinished] {
            let fixture = try makeStore()
            let active = WatchWorkoutSnapshot.placeholder(workoutID: UUID(), startDate: start)
            try fixture.store.replaceSnapshot(active)
            var finished = active
            finished.endDate = start.addingTimeInterval(600)
            finished.isFinished = true
            let event = try fixture.store.commitEvent(snapshotChange: .replace(kind == .workoutFinished ? finished : nil)) { sequence, _ in
                WatchWorkoutEvent(workoutID: active.workoutID, sequence: sequence, kind: kind,
                    snapshot: kind == .workoutFinished ? finished : nil, createdAt: start.addingTimeInterval(600))
            }
            let recovered = WatchWorkoutStore(defaults: fixture.defaults, defaultsKey: key, libraryURL: fixture.url,
                loadLibrarySynchronously: true, bundledLibrary: { self.emptyLibrary() })
            XCTAssertEqual(recovered.shouldDiscardRecoveredWorkout(active.workoutID), kind == .workoutDiscarded)
            XCTAssertEqual(try recovered.replaceSnapshot(active), .rejected,
                           "A local recovery placeholder must respect the terminal tombstone")
            if kind == .workoutFinished {
                // The v1 ISO-8601 wire format drops Date()'s fractional seconds.
                // Compare the entire projection at its durable date precision.
                let finishedData = try XCTUnwrap(WatchWorkoutWire.encode(finished))
                let durableFinished = try XCTUnwrap(WatchWorkoutWire.decode(WatchWorkoutSnapshot.self, from: finishedData))
                XCTAssertEqual(recovered.snapshot(), durableFinished)
                XCTAssertEqual(WatchWorkoutFinalization.recoveryAction(snapshot: recovered.snapshot(),
                    recordingWorkoutID: active.workoutID, isFinalizing: false, canResume: true), .resume)
                XCTAssertTrue(try recovered.reconcileFinishedSnapshot(workoutID: active.workoutID, healthWorkoutSaved: true))
            } else {
                XCTAssertNil(recovered.snapshot())
            }
            try recovered.acknowledge(eventIDs: [event.id])
            try flush(recovered)
            let relaunched = WatchWorkoutStore(defaults: fixture.defaults, defaultsKey: key, libraryURL: fixture.url,
                loadLibrarySynchronously: true, bundledLibrary: { self.emptyLibrary() })
            XCTAssertTrue(relaunched.shouldDiscardRecoveredWorkout(active.workoutID))
            XCTAssertNil(relaunched.snapshot())
            XCTAssertTrue(relaunched.pendingEvents().isEmpty)
            XCTAssertFalse(relaunched.shouldDiscardRecoveredWorkout(UUID()))
        }
    }

    func testLegacyEditableEndDateRecoveryRequiresDurableFinishIntent() throws {
        let fixture = try makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var legacy = WatchWorkoutSnapshot.placeholder(workoutID: UUID(), startDate: start)
        XCTAssertEqual(legacy.isFinished, false)
        legacy.endDate = start.addingTimeInterval(600)
        legacy.isFinished = nil
        try fixture.store.replaceSnapshot(legacy)
        try flush(fixture.store)
        let restored = WatchWorkoutStore(defaults: fixture.defaults, defaultsKey: key, libraryURL: fixture.url,
            loadLibrarySynchronously: true, bundledLibrary: { self.emptyLibrary() })
        XCTAssertEqual(restored.snapshot()?.endDate, legacy.endDate)
        XCTAssertEqual(restored.snapshot()?.isFinished, false)
        XCTAssertEqual(WatchWorkoutFinalization.recoveryAction(snapshot: restored.snapshot(),
            recordingWorkoutID: legacy.workoutID, isFinalizing: false, canResume: true), .none)
        XCTAssertEqual(WatchWorkoutFinalization.recoveryAction(snapshot: legacy,
            recordingWorkoutID: legacy.workoutID, isFinalizing: false, canResume: true), .none)
        XCTAssertFalse(try restored.reconcileFinishedSnapshot(workoutID: legacy.workoutID, healthWorkoutSaved: false))
        XCTAssertTrue(restored.pendingEvents().isEmpty)
        _ = try restored.commitEvent(snapshotChange: .replace(legacy)) { sequence, _ in
            WatchWorkoutEvent(workoutID: legacy.workoutID, sequence: sequence, kind: .workoutFinished,
                snapshot: legacy, createdAt: start.addingTimeInterval(610))
        }
        let finished = WatchWorkoutStore(defaults: fixture.defaults, defaultsKey: key, libraryURL: fixture.url,
            loadLibrarySynchronously: true, bundledLibrary: { self.emptyLibrary() })
        XCTAssertEqual(finished.snapshot()?.isFinished, true)
        XCTAssertEqual(WatchWorkoutFinalization.recoveryAction(snapshot: finished.snapshot(),
            recordingWorkoutID: legacy.workoutID, isFinalizing: false, canResume: true), .resume)
        try flush(restored)
        try flush(finished)
    }

    func testDiscreteWarmupInsertionIsDurableBeforeSuccessAndRollsBackEncodingFailure() throws {
        var failEncoding = false
        let fixture = try makeStore(encode: { failEncoding ? nil : WatchWorkoutWire.encode($0) })
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let active = WatchWorkoutSnapshot.placeholder(workoutID: UUID(), startDate: start)
        try fixture.store.replaceSnapshot(active)
        try flush(fixture.store)
        let originalData = fixture.defaults.data(forKey: key)
        var inserted = active
        inserted.exercises[0].sets.insert(WatchWorkoutSet(order: 0, weight: 40, reps: 5, tag: "warmUp"), at: 0)
        inserted.revision = 1
        inserted.updatedAt = start.addingTimeInterval(10)
        WatchWorkoutEditing.normalize(&inserted)
        let makeEvent: (Int64, WatchWorkoutSnapshot?) -> WatchWorkoutEvent = { sequence, snapshot in
            WatchWorkoutEvent(workoutID: active.workoutID, sequence: sequence, kind: .workoutStructureUpdated,
                snapshot: snapshot, fieldChanges: .between(previous: active, next: inserted),
                createdAt: start.addingTimeInterval(10))
        }
        failEncoding = true
        XCTAssertThrowsError(try fixture.store.commitEvent(snapshotChange: .replace(inserted),
            requiresImmediatePersistence: true, makeEvent: makeEvent))
        XCTAssertEqual(fixture.store.snapshot(), active)
        XCTAssertTrue(fixture.store.pendingEvents().isEmpty)
        XCTAssertEqual(fixture.defaults.data(forKey: key), originalData)
        failEncoding = false
        let event = try fixture.store.commitEvent(snapshotChange: .replace(inserted),
            requiresImmediatePersistence: true, makeEvent: makeEvent)
        // Read durable storage at the exact return boundary used by the page's
        // completion, without a flush, timer, run-loop delay or transport send.
        let data = try XCTUnwrap(fixture.defaults.data(forKey: key))
        let durable = try XCTUnwrap(WatchWorkoutWire.decode(WatchWorkoutPersistedState.self, from: data))
        XCTAssertEqual(durable.snapshot, inserted)
        XCTAssertEqual(durable.outbox.map(\.id), [event.id])
        XCTAssertEqual(event.sequence, 1, "A failed insertion cannot consume the event sequence")
        var crownEdit = inserted
        crownEdit.revision = 2
        crownEdit.exercises[0].sets[0].weight = 45
        _ = try fixture.store.commitEvent(snapshotChange: .replace(crownEdit), makeEvent: makeEvent)
        XCTAssertEqual(fixture.defaults.data(forKey: key), data, "Continuous Crown edits must stay debounced")
        try flush(fixture.store)
    }

    func testConcurrentPhoneFinishIsAnIdempotentReceiptDuringWatchFinalization() throws {
        let fixture = try makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = WatchWorkoutSnapshot(workoutID: UUID(), startDate: start,
            endDate: start.addingTimeInterval(600), revision: 2, updatedAt: start.addingTimeInterval(600), isFinished: true)
        let finish = try fixture.store.commitEvent(snapshotChange: .replace(snapshot)) { sequence, _ in
            WatchWorkoutEvent(workoutID: snapshot.workoutID, sequence: sequence, kind: .workoutFinished,
                              snapshot: snapshot, fieldChanges: WatchWorkoutFieldChanges())
        }
        // Both Watch and phone receipts use this guard before provenance,
        // projection writes, or another call to the in-flight HealthKit end().
        XCTAssertTrue(WatchWorkoutFinalization.isDuplicateFinish(workoutID: snapshot.workoutID,
            recordingWorkoutID: snapshot.workoutID, isFinalizing: true))
        XCTAssertEqual(WatchWorkoutFinalization.recoveryAction(snapshot: snapshot,
            recordingWorkoutID: snapshot.workoutID, isFinalizing: true, canResume: true), .waitForSave)
        XCTAssertFalse(WatchWorkoutFinalization.isDuplicateFinish(workoutID: UUID(),
            recordingWorkoutID: snapshot.workoutID, isFinalizing: true))
        XCTAssertFalse(WatchWorkoutFinalization.isDuplicateFinish(workoutID: snapshot.workoutID,
            recordingWorkoutID: snapshot.workoutID, isFinalizing: false))
        XCTAssertEqual(fixture.store.pendingEvents().map(\.id), [finish.id])
        XCTAssertEqual(fixture.store.snapshot(), snapshot)
        try flush(fixture.store)
    }

    func testFinishedProjectionRecoveryResumesOrArchivesWithDurableHealthOutcome() throws {
        for saved in [true, false] {
            let fixture = try makeStore()
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            let snapshot = WatchWorkoutSnapshot(workoutID: UUID(), startDate: start,
                endDate: start.addingTimeInterval(600), revision: 2, updatedAt: start.addingTimeInterval(600), isFinished: true)
            let finish = try fixture.store.commitEvent(snapshotChange: .replace(snapshot)) { sequence, _ in
                WatchWorkoutEvent(workoutID: snapshot.workoutID, sequence: sequence, kind: .workoutFinished,
                                  snapshot: snapshot, fieldChanges: WatchWorkoutFieldChanges())
            }
            let restored = WatchWorkoutStore(defaults: fixture.defaults, defaultsKey: key, libraryURL: fixture.url,
                loadLibrarySynchronously: true, bundledLibrary: { self.emptyLibrary() })
            XCTAssertEqual(WatchWorkoutFinalization.recoveryAction(snapshot: restored.snapshot(),
                recordingWorkoutID: snapshot.workoutID, isFinalizing: false, canResume: true), .resume)
            XCTAssertEqual(WatchWorkoutFinalization.recoveryAction(snapshot: restored.snapshot(),
                recordingWorkoutID: nil, isFinalizing: false, canResume: false), .verifySavedWorkout)
            XCTAssertTrue(try restored.reconcileFinishedSnapshot(workoutID: snapshot.workoutID,
                healthWorkoutSaved: saved, at: start.addingTimeInterval(610)))
            XCTAssertNil(restored.snapshot())
            let pending = restored.pendingEvents()
            XCTAssertEqual(pending.first?.id, finish.id)
            XCTAssertEqual(pending.map(\.kind), saved ? [.workoutFinished] : [.workoutFinished, .workoutFailed])
            if !saved {
                XCTAssertTrue(pending.last?.snapshot?.isFinishedRecord == true)
                XCTAssertNotNil(pending.last?.fieldChanges, "Recovery failures must use the modern lifecycle-only merge")
                XCTAssertGreaterThan(pending.last!.sequence, finish.sequence)
            }
            XCTAssertFalse(try restored.reconcileFinishedSnapshot(workoutID: snapshot.workoutID, healthWorkoutSaved: saved))
            try flush(restored)
            let relaunched = WatchWorkoutStore(defaults: fixture.defaults, defaultsKey: key, libraryURL: fixture.url,
                loadLibrarySynchronously: true, bundledLibrary: { self.emptyLibrary() })
            XCTAssertNil(relaunched.snapshot())
            XCTAssertEqual(relaunched.pendingEvents().map(\.id), pending.map(\.id))
            XCTAssertTrue(relaunched.isTerminalWorkout(snapshot.workoutID))
            let next = WatchWorkoutSnapshot(workoutID: UUID())
            XCTAssertEqual(try relaunched.replaceSnapshot(next, fromPhone: true), .changed)
            XCTAssertFalse(try relaunched.reconcileFinishedSnapshot(workoutID: snapshot.workoutID, healthWorkoutSaved: saved),
                           "A delayed Health lookup must not archive the next workout")
            XCTAssertEqual(relaunched.snapshot(), next)
            try flush(relaunched)
        }
    }

    func testFinishedRecoveryEncodingFailureRetainsProjectionAndFinishForRetry() throws {
        var failEncoding = false
        let fixture = try makeStore(encode: { failEncoding ? nil : WatchWorkoutWire.encode($0) })
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = WatchWorkoutSnapshot(workoutID: UUID(), startDate: start,
            endDate: start.addingTimeInterval(600), isFinished: true)
        let finish = try fixture.store.commitEvent(snapshotChange: .replace(snapshot)) { sequence, _ in
            WatchWorkoutEvent(workoutID: snapshot.workoutID, sequence: sequence, kind: .workoutFinished, snapshot: snapshot)
        }
        failEncoding = true
        XCTAssertThrowsError(try fixture.store.reconcileFinishedSnapshot(workoutID: snapshot.workoutID, healthWorkoutSaved: false))
        XCTAssertEqual(fixture.store.snapshot(), snapshot)
        XCTAssertEqual(fixture.store.pendingEvents().map(\.id), [finish.id])
        failEncoding = false
        XCTAssertTrue(try fixture.store.reconcileFinishedSnapshot(workoutID: snapshot.workoutID, healthWorkoutSaved: false))
        try flush(fixture.store)
    }

    func testPhoneTerminalArchivePersistsBoundedTombstonesWithoutAnOutboxEvent() throws {
        let fixture = try makeStore()
        let active = WatchWorkoutSnapshot(workoutID: UUID(), revision: 1)
        try fixture.store.replaceSnapshot(active)
        try fixture.store.clearSnapshot()
        try flush(fixture.store)
        let restored = WatchWorkoutStore(defaults: fixture.defaults, defaultsKey: key, libraryURL: fixture.url,
            loadLibrarySynchronously: true, bundledLibrary: { self.emptyLibrary() })
        XCTAssertTrue(restored.isTerminalWorkout(active.workoutID))
        XCTAssertEqual(try restored.replaceSnapshot(active, fromPhone: true), .rejected)
        var state = WatchWorkoutPersistedState()
        let ids = (0..<51).map { _ in UUID() }
        ids.forEach { WatchWorkoutPersistence.markTerminal($0, in: &state) }
        XCTAssertEqual(state.terminalWorkoutIDs, Array(ids.suffix(50)))
        try flush(restored)
    }

    func testFailedLibraryWritePreservesDurableEventForCrashRecovery() throws {
        let fixture = try makeStore()
        // A directory at the file URL deterministically makes atomic writes fail.
        try FileManager.default.createDirectory(at: fixture.url, withIntermediateDirectories: true)
        let snapshot = WatchWorkoutSnapshot(workoutID: UUID(), endDate: Date(), isFinished: true)
        let event = try fixture.store.commitEvent(snapshotChange: .keep) { sequence, _ in
            WatchWorkoutEvent(workoutID: snapshot.workoutID, sequence: sequence, kind: .workoutFinished, snapshot: snapshot)
        }
        try flush(fixture.store)
        try fixture.store.acknowledge(eventIDs: [event.id])
        XCTAssertThrowsError(try flush(fixture.store))
        let data = try XCTUnwrap(fixture.defaults.data(forKey: key))
        let durable = try XCTUnwrap(WatchWorkoutWire.decode(WatchWorkoutPersistedState.self, from: data))
        XCTAssertEqual(durable.outbox.map(\.id), [event.id], "The library must save before its ACK removes the durable event")
    }

    func testUnchangedReplacementAndOrdinaryAckDoNotRewriteLibrary() throws {
        let fixture = try makeStore()
        var library = emptyLibrary()
        library.weightUnit = .pound
        library.revision = 1
        try fixture.store.replaceLibrary(library)
        try flush(fixture.store)
        let before = try FileManager.default.attributesOfItem(atPath: fixture.url.path)[.systemFileNumber] as? NSNumber
        XCTAssertNotNil(before)
        library.generatedAt.addTimeInterval(10)
        library.revision = 3
        try fixture.store.replaceLibrary(library)
        let edit = try fixture.store.commitEvent(snapshotChange: .keep) { sequence, _ in
            WatchWorkoutEvent(workoutID: UUID(), sequence: sequence, kind: .setUpdated)
        }
        try flush(fixture.store)
        try fixture.store.acknowledge(eventIDs: [edit.id])
        try flush(fixture.store)
        let after = try FileManager.default.attributesOfItem(atPath: fixture.url.path)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(before, after)
        let restored = WatchWorkoutStore(defaults: fixture.defaults, defaultsKey: key, libraryURL: fixture.url,
            loadLibrarySynchronously: true, bundledLibrary: { self.emptyLibrary() })
        library.revision = 2
        library.weightUnit = .kilogram
        try restored.replaceLibrary(library)
        XCTAssertEqual(restored.library().weightUnit, .pound, "Persisted transport clocks must reject an old library after relaunch")
        try flush(restored)
    }

    func testHistoryIndexExcludesCurrentAndFutureAndFindsNewlyAddedExercises() {
        let catalogID = UUID()
        let set = WatchWorkoutSet(order: 2, weight: 100, reps: 3, completed: true)
        let exercise = WatchWorkoutExercise(order: 1, name: "Squat", sets: [set], exerciseUuid: catalogID)
        let prior = WatchWorkoutSnapshot(workoutID: UUID(), startDate: Date(timeIntervalSince1970: 100), exercises: [exercise])
        var current = WatchWorkoutSnapshot(workoutID: UUID(), startDate: Date(timeIntervalSince1970: 200))
        let future = WatchWorkoutSnapshot(workoutID: UUID(), startDate: Date(timeIntervalSince1970: 300), exercises: [exercise])
        let index = WatchWorkoutHistoryIndex(history: [future, current, prior])
        let lookup = index.previousExercises(for: current)
        current.exercises = [exercise]
        XCTAssertEqual(lookup[catalogID]?.workoutID, prior.workoutID)
        XCTAssertEqual(lookup[catalogID]?.completedSets[2]?.weight, 100)
        XCTAssertNil(lookup[catalogID]?.completedSets[1])
        XCTAssertEqual(index.previousExercises(for: current)[catalogID]?.workoutID, prior.workoutID)
    }
}
#endif // WATCH_WORKOUT_STORE_TESTS

final class PendingWatchUserInfoTests: XCTestCase {
    func testActivationDrainKeepsLifecycleOrderAndLatestFieldPerWorkout() throws {
        var pending = Iron.PendingWatchUserInfo()
        let firstID = UUID().uuidString, secondID = UUID().uuidString
        func selection(_ value: String, workoutID: String) -> [String: Any] {
            [PayloadKey.updateWorkoutSessionSelectedSet: [PayloadKey.Arg.uuid: workoutID, PayloadKey.Arg.text: value]]
        }
        pending.enqueue([PayloadKey.startWorkoutSession: [PayloadKey.Arg.uuid: firstID]])
        pending.enqueue(selection("Old", workoutID: firstID))
        pending.enqueue(selection("Other workout", workoutID: secondID))
        pending.enqueue(selection("Latest", workoutID: firstID))
        pending.enqueue([PayloadKey.endWorkoutSession: [PayloadKey.Arg.uuid: firstID]])
        let drained = pending.takeAll()
        XCTAssertEqual(drained.count, 4)
        XCTAssertNotNil(drained[0][PayloadKey.startWorkoutSession])
        XCTAssertEqual((drained[1][PayloadKey.updateWorkoutSessionSelectedSet] as? [String: Any])?[PayloadKey.Arg.text] as? String, "Other workout")
        XCTAssertEqual((drained[2][PayloadKey.updateWorkoutSessionSelectedSet] as? [String: Any])?[PayloadKey.Arg.text] as? String, "Latest")
        XCTAssertNotNil(drained[3][PayloadKey.endWorkoutSession])
        XCTAssertTrue(pending.takeAll().isEmpty, "A second activation callback cannot replay the drained commands")
    }
}
