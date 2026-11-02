//
//  WorkoutDataTests.swift
//  IronTests
//
//  Created by Karim Abou Zeid on 15.02.18.
//  Copyright © 2018 Karim Abou Zeid Software. All rights reserved.
//

import XCTest
import CoreData
import Combine
import UIKit
@testable import WorkoutDataKit
@testable import Iron

class WorkoutDataTests: XCTestCase {
    var persistenContainer: NSPersistentContainer!
    
    var testWorkouts: [Workout]!
    var testWorkoutExercises: [WorkoutExercise]!
    var testWorkoutSets: [WorkoutSet]!
    
    var testCurrentWorkout: Workout!
    
    override func setUp() {
        super.setUp()
        // Put setup code here. This method is called before the invocation of each test method in the class.
        persistenContainer = setUpInMemoryNSPersistentContainer()

        createTestWorkoutData(context: persistenContainer.viewContext)
        testCurrentWorkout = createTestCurrentWorkout(context: persistenContainer.viewContext)
        
        testWorkouts = try? persistenContainer.viewContext.fetch(Workout.fetchRequest())
        testWorkoutExercises = try? persistenContainer.viewContext.fetch(WorkoutExercise.fetchRequest())
        testWorkoutSets = try? persistenContainer.viewContext.fetch(WorkoutSet.fetchRequest())

        XCTAssertNotNil(testWorkouts)
        XCTAssertTrue(testWorkouts.count > 0)
        XCTAssertTrue(testWorkouts.count == 2) // might change in future
        XCTAssertNotNil(testWorkoutExercises)
        XCTAssertTrue(testWorkoutExercises.count > 0)
        XCTAssertNotNil(testWorkoutSets)
        XCTAssertTrue(testWorkoutSets.count > 0)
        
        XCTAssertNotNil(testCurrentWorkout)
        
        XCTAssertNoThrow(try persistenContainer.viewContext.save())
    }
    
    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        persistenContainer.viewContext.reset()
        persistenContainer = nil
        
        testWorkouts = nil
        testWorkoutExercises = nil
        testWorkoutSets = nil
        testCurrentWorkout = nil
        
        super.tearDown()
    }
    
    func testWorkoutExerciseNumberOfCompletedSets() {
        for workoutExercise in testWorkoutExercises {
            let count = workoutExercise.workoutSets?.filter({ (set) -> Bool in
                (set as! WorkoutSet).isCompleted == true
            }).count
            XCTAssertTrue(workoutExercise.numberOfCompletedSets == count)
        }
    }
    
    func testRelationshipDeleteRules() {
        for workout in testWorkouts {
            let workoutExercises = workout.workoutExercises!.array.map { $0 as! WorkoutExercise }
            
            let workoutExercise = workoutExercises.first!
            let workoutSets = workoutExercise.workoutSets!.array.map { $0 as! WorkoutSet }
            
            // set deletion doesn't delete exercise
            let workoutSet = workoutSets.first!
            persistenContainer.viewContext.delete(workoutSet)
            XCTAssertNoThrow(try persistenContainer.viewContext.save())
            XCTAssertNil(workoutSet.managedObjectContext)
            XCTAssertNotNil(workoutExercise.managedObjectContext)
            
            // exercise deletion doesn't delete workout, but deletes sets
            persistenContainer.viewContext.delete(workoutExercise)
            XCTAssertNoThrow(try persistenContainer.viewContext.save())
            XCTAssertNil(workoutExercise.managedObjectContext)
            XCTAssertTrue(workoutSets.reduce(true, { $0 && $1.managedObjectContext == nil }))
            XCTAssertNotNil(workout.managedObjectContext)

            // workout deletion deletes exercises
            persistenContainer.viewContext.delete(workout)
            XCTAssertNoThrow(try persistenContainer.viewContext.save())
            XCTAssertNil(workout.managedObjectContext)
            XCTAssertTrue(workoutExercises.reduce(true, { $0 && $1.managedObjectContext == nil }))
        }
    }
    
    func uncompletedSetsSwift(workout: Workout) -> [WorkoutSet]? {
        return workout.workoutExercises?
            .compactMap { $0 as? WorkoutExercise }
            .compactMap { $0.workoutSets?.array as? [WorkoutSet] }
            .flatMap { $0 }
            .filter { !$0.isCompleted }
    }
    
    func uncompletedSetsFetch(workout: Workout) -> [WorkoutSet]? {
        let fetchRequest: NSFetchRequest<WorkoutSet> = WorkoutSet.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "\(#keyPath(WorkoutSet.workoutExercise.workout)) == %@ AND \(#keyPath(WorkoutSet.isCompleted)) == %@", workout, NSNumber(booleanLiteral: false))
        return try? workout.managedObjectContext?.fetch(fetchRequest)
    }
    
    func testUncompletedSets() {
        for workout in testWorkouts {
            XCTAssertEqual(Set(uncompletedSetsSwift(workout: workout) ?? []), Set(uncompletedSetsFetch(workout: workout) ?? []))
        }
    }
    
    func testUncompletedSetsSwift() {
        self.measure {
            for workout in testWorkouts {
                _ = uncompletedSetsSwift(workout: workout)
            }
        }
    }
    
    func testUncompletedSetsFetch() {
        self.measure {
            for workout in testWorkouts {
                _ = uncompletedSetsFetch(workout: workout)
            }
        }
    }
    
    func testDeleteUncompletedSets() {
        testCurrentWorkout.deleteUncompletedSets()
        XCTAssertTrue(
            testCurrentWorkout.workoutExercises?
                .compactMap { $0 as? WorkoutExercise }
                .compactMap { $0.workoutSets?.array as? [WorkoutSet] }
                .flatMap { $0 }
                .filter { !$0.isCompleted }
                .isEmpty ?? true
        )
    }
    
    func testDeleteExercisesWhereAllSetsAreUncompleted() {
        testCurrentWorkout.deleteExercisesWhereAllSetsAreUncompleted()
        XCTAssertTrue(
            testCurrentWorkout.workoutExercises?
                .compactMap { $0 as? WorkoutExercise }
                .compactMap { $0.workoutSets?.array as? [WorkoutSet] }
                .filter { $0.reduce(true, { $0 && !$1.isCompleted }) }
                .isEmpty ?? true
        )
    }
    
    func testStartEndValidation() {
        for workout in testWorkouts {
            if let start = workout.start, let end = workout.end {
                workout.start = end
                workout.end = start
                XCTAssertThrowsError(try persistenContainer.viewContext.save())
                
                workout.start = nil
                workout.end = end
                XCTAssertThrowsError(try persistenContainer.viewContext.save())
                
                workout.start = start
                workout.end = nil
                if workout.isCurrentWorkout {
                    XCTAssertNoThrow(try persistenContainer.viewContext.save())
                } else {
                    XCTAssertThrowsError(try persistenContainer.viewContext.save())
                }
            }
        }
    }
    
    func testUuidRequired() {
        for workout in testWorkouts {
            workout.uuid = nil
            XCTAssertThrowsError(try persistenContainer.viewContext.save())
            workout.uuid = UUID()
            XCTAssertNoThrow(try persistenContainer.viewContext.save())
        }
        
        for workoutExercise in testWorkoutExercises {
            workoutExercise.uuid = nil
            XCTAssertThrowsError(try persistenContainer.viewContext.save())
            workoutExercise.uuid = UUID()
            XCTAssertNoThrow(try persistenContainer.viewContext.save())
        }
        
        for workoutSet in testWorkoutSets{
            workoutSet.uuid = nil
            XCTAssertThrowsError(try persistenContainer.viewContext.save())
            workoutSet.uuid = UUID()
            XCTAssertNoThrow(try persistenContainer.viewContext.save())
        }
        
        // TODO: also for workout plans
    }
    
    func testCurrentWorkoutValidation() {
        XCTAssertEqual(try persistenContainer.viewContext.count(for: Workout.currentWorkoutFetchRequest), 1)
        let workout = createTestCurrentWorkout(context: persistenContainer.viewContext)
        XCTAssertEqual(try persistenContainer.viewContext.count(for: Workout.currentWorkoutFetchRequest), 2)
        XCTAssertThrowsError(try persistenContainer.viewContext.save())
        persistenContainer.viewContext.delete(workout)
        XCTAssertEqual(try persistenContainer.viewContext.count(for: Workout.currentWorkoutFetchRequest), 1)
        XCTAssertNoThrow(try persistenContainer.viewContext.save())
        persistenContainer.viewContext.delete(testCurrentWorkout)
        XCTAssertEqual(try persistenContainer.viewContext.count(for: Workout.currentWorkoutFetchRequest), 0)
        XCTAssertNoThrow(try persistenContainer.viewContext.save())
        _ = createTestCurrentWorkout(context: persistenContainer.viewContext)
        XCTAssertEqual(try persistenContainer.viewContext.count(for: Workout.currentWorkoutFetchRequest), 1)
        XCTAssertNoThrow(try persistenContainer.viewContext.save())
    }
    
    func testWorkoutIsCompletedValidation() {
        testCurrentWorkout.isCurrentWorkout = false
        XCTAssertThrowsError(try persistenContainer.viewContext.save())
        testCurrentWorkout.isCurrentWorkout = true
        XCTAssertNoThrow(try persistenContainer.viewContext.save())
        
        for workoutSet in testWorkoutSets {
            if let workout = workoutSet.workoutExercise?.workout, !workout.isCurrentWorkout {
                workoutSet.isCompleted = false
                XCTAssertThrowsError(try persistenContainer.viewContext.save())
                workoutSet.isCompleted = true
                XCTAssertNoThrow(try persistenContainer.viewContext.save())
            }
        }
    }
    
    func testDetachedWorkoutExercise() {
        let workoutExercise = WorkoutExercise.create(context: persistenContainer.viewContext)
        XCTAssertThrowsError(try persistenContainer.viewContext.save())
        workoutExercise.workout = testWorkouts.first
        XCTAssertNoThrow(try persistenContainer.viewContext.save())
    }
    
    func testDetachedWorkoutSet() {
        let workoutSet = WorkoutSet.create(context: persistenContainer.viewContext)
        workoutSet.isCompleted = true
        XCTAssertThrowsError(try persistenContainer.viewContext.save())
        workoutSet.workoutExercise = testWorkoutExercises.first
        XCTAssertNoThrow(try persistenContainer.viewContext.save())
    }
    
    func testUncompletedSet() {
        let workoutSet = WorkoutSet.create(context: persistenContainer.viewContext)
        workoutSet.isCompleted = false
        workoutSet.workoutExercise = testCurrentWorkout.workoutExercises?.firstObject as? WorkoutExercise
        XCTAssertNotNil(workoutSet.workoutExercise)
        XCTAssertNoThrow(try persistenContainer.viewContext.save())
        workoutSet.workoutExercise = testWorkoutExercises.first { !$0.workout!.isCurrentWorkout }
        XCTAssertThrowsError(try persistenContainer.viewContext.save())
        workoutSet.isCompleted = true
        XCTAssertNoThrow(try persistenContainer.viewContext.save())
    }
    
    func testWorkoutIsCompleted() {
        for workout in testWorkouts {
            if !workout.isCurrentWorkout {
                XCTAssertTrue(workout.isCompleted!)
            }
        }
    }
    
    func testWorkoutHasCompletedSets() {
        let workout = Workout.create(context: persistenContainer.viewContext)
        XCTAssertFalse(workout.hasCompletedSets!)
        
        let exercise = WorkoutExercise.create(context: persistenContainer.viewContext)
        workout.addToWorkoutExercises(exercise)
        XCTAssertFalse(workout.hasCompletedSets!)
        
        let set = WorkoutSet.create(context: persistenContainer.viewContext)
        exercise.addToWorkoutSets(set)
        XCTAssertFalse(workout.hasCompletedSets!)
        
        set.isCompleted = true
        XCTAssertTrue(workout.hasCompletedSets!)
        
        for workout in testWorkouts {
            XCTAssertTrue(workout.hasCompletedSets!)
        }
    }

    func testWorkoutStartedFromPlanUsesPlanNameWithoutPersistenceContainerTitle() {
        let context = persistenContainer.viewContext
        let persistedContainer = WorkoutPlan.create(context: context)
        persistedContainer.title = "Workout Plan"

        let plan = WorkoutRoutine.create(context: context)
        plan.title = "Pull"
        persistedContainer.addToWorkoutRoutines(plan)

        let workout = plan.createWorkout(context: context)

        XCTAssertEqual(workout.title, "Pull")
        XCTAssertEqual(workout.displayTitle(in: []), "Pull")

        plan.title = "Renamed later"
        XCTAssertEqual(workout.displayTitle(in: []), "Pull")
    }

    func testWorkoutStartedFromUnnamedPlanSnapshotsFallbackName() {
        let context = persistenContainer.viewContext
        let persistedContainer = WorkoutPlan.create(context: context)
        let plan = WorkoutRoutine.create(context: context)
        persistedContainer.addToWorkoutRoutines(plan)

        let workout = plan.createWorkout(context: context)

        XCTAssertEqual(workout.title, "Workout A")
        XCTAssertEqual(workout.displayTitle(in: []), "Workout A")
    }

    func testGeneratedTitleUsesTimeOfDayAndSplit() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        func date(hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 30, hour: hour))!
        }

        XCTAssertEqual(
            Workout.generatedTitle(muscleGroups: ["legs"], at: date(hour: 6), calendar: calendar),
            "Early Morning Leg Day"
        )
        XCTAssertEqual(
            Workout.generatedTitle(muscleGroups: ["chest", "arms"], at: date(hour: 22), calendar: calendar),
            "Late Night Chest + Arms"
        )
        XCTAssertEqual(
            Workout.generatedTitle(muscleGroups: ["back", "arms"], at: date(hour: 18), calendar: calendar),
            "Evening Pull Day"
        )
        XCTAssertEqual(
            Workout.generatedTitle(muscleGroups: ["chest", "shoulders"], at: date(hour: 10), calendar: calendar),
            "Morning Push Day"
        )
        XCTAssertEqual(
            Workout.generatedTitle(muscleGroups: ["legs", "chest", "back"], at: date(hour: 14), calendar: calendar),
            "Afternoon Full Body"
        )
        XCTAssertNil(Workout.generatedTitle(muscleGroups: [], at: date(hour: 10), calendar: calendar))
    }
    
    func testSendObjectsWillChange() {
        let workout = Workout.create(context: persistenContainer.viewContext)
        let workoutExercise1 = WorkoutExercise.create(context: persistenContainer.viewContext)
        let workoutExercise2 = WorkoutExercise.create(context: persistenContainer.viewContext)
        let workoutSet1_1 = WorkoutSet.create(context: persistenContainer.viewContext)
        let workoutSet1_2 = WorkoutSet.create(context: persistenContainer.viewContext)
        let workoutSet2_1 = WorkoutSet.create(context: persistenContainer.viewContext)
        let workoutSet2_2 = WorkoutSet.create(context: persistenContainer.viewContext)
        
        workout.start = Date()
        workout.end = Date()
        workoutSet1_1.isCompleted = true
        workoutSet1_2.isCompleted = true
        workoutSet2_1.isCompleted = true
        workoutSet2_2.isCompleted = true
        
        workoutExercise1.addToWorkoutSets([workoutSet1_1, workoutSet1_2])
        workoutExercise2.addToWorkoutSets([workoutSet2_1, workoutSet2_2])
        workout.addToWorkoutExercises([workoutExercise1, workoutExercise2])
        
        try! persistenContainer.viewContext.save()
        
        var cancellables = Set<AnyCancellable>()
        persistenContainer.viewContext.publisher.sink { WorkoutDataStorage.sendObjectsWillChange(changes: $0) }.store(in: &cancellables)
        
        var expectations = changeExpectations(reason: "increment weight", objects: [
            (workoutSet1_1.workoutExercise!.workout!, true),
            (workoutSet1_1.workoutExercise!, true),
            (workoutSet1_1, true),
            (workoutSet1_2, false),
            (workoutSet2_1, false),
            (workoutSet2_2, false)
        ], store: &cancellables)
        workoutSet1_1.weightValue += 1
        wait(for: expectations, timeout: 1)
        
        expectations = changeExpectations(reason: "set exercise uuid", objects: [
            (workoutExercise1.workout!, true),
            (workoutExercise1, true),
            (workoutExercise2, false),
            (workoutSet1_1, true),
            (workoutSet1_2, true),
            (workoutSet2_1, false),
            (workoutSet2_2, false)
        ], store: &cancellables)
        workoutExercise1.exerciseUuid = UUID()
        wait(for: expectations, timeout: 1)
        
        expectations = changeExpectations(reason: "set workout title", objects: [
            (workout, true),
            (workoutExercise1, true),
            (workoutExercise2, true),
            (workoutSet1_1, true),
            (workoutSet1_2, true),
            (workoutSet2_1, true),
            (workoutSet2_2, true)
        ], store: &cancellables)
        workout.title = "Test"
        wait(for: expectations, timeout: 1)
    }

    func testWatchWorkoutSetDisplayTextUsesOnlyRelevantUnits() {
        let weighted = WatchWorkoutSet(order: 1, weight: 65, reps: 8)
        XCTAssertEqual(weighted.displayText(weightUnit: .kilogram), "65 kg × 8")

        let fractional = WatchWorkoutSet(order: 2, weight: 37.5, reps: 9)
        XCTAssertEqual(fractional.displayText(weightUnit: .pound), "37.5 lb × 9")

        let bodyweight = WatchWorkoutSet(order: 3, weight: 0, reps: 5)
        XCTAssertEqual(bodyweight.displayText(weightUnit: .pound), "5 reps")

        let previousBodyweight = WatchWorkoutSet(
            order: 4,
            weight: 0,
            reps: 8,
            previousWeight: 0,
            previousReps: 6
        )
        XCTAssertEqual(previousBodyweight.previousDisplayText(weightUnit: .pound), "6 reps")
    }
    
    private func changeExpectations(reason: String = "", objects: [(NSManagedObject, Bool)], store: inout Set<AnyCancellable>) -> [XCTestExpectation] {
        objects.map {
            let expectation = XCTestExpectation(description: "\($0.0.entity.name ?? "object") for \(reason)")
            expectation.isInverted = !$0.1
            $0.0.objectWillChange.sink { _ in expectation.fulfill() }.store(in: &store)
            return expectation
        }
    }
}

final class WorkoutLiveActivitySetProgressTests: XCTestCase {
    func testLegacySnapshotDoesNotInferCompletedSetsFromOrdinal() throws {
        let data = Data(#"{"setID":"set","exerciseName":"Bench Press","setNumber":4,"setCount":6,"result":"135 lb × 8"}"#.utf8)
        let set = try JSONDecoder().decode(WorkoutActivityAttributes.SetSnapshot.self, from: data)
        XCTAssertNil(set.completedSetCount)
        XCTAssertNil(set.completedSetProgress)
    }

    func testCompletedCountRoundTripsIndependentlyOfCurrentSetNumber() throws {
        let set = WorkoutActivityAttributes.SetSnapshot(
            setID: "set", exerciseName: "Bench Press", setNumber: 4, setCount: 6,
            result: "135 lb × 8", completedSetCount: 2
        )
        let data = try JSONEncoder().encode(set)
        let decoded = try JSONDecoder().decode(WorkoutActivityAttributes.SetSnapshot.self, from: data)
        XCTAssertEqual(decoded, set)
        XCTAssertEqual(try XCTUnwrap(decoded.completedSetProgress), 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertLessThan(data.count, 512)
    }

    func testProgressClampsInvalidCountsAndHandlesEmptyExercise() {
        var set = WorkoutActivityAttributes.SetSnapshot(
            setID: "set", exerciseName: "Bench Press", setNumber: 1, setCount: 4,
            result: "—", completedSetCount: -3
        )
        XCTAssertEqual(set.completedSetProgress, 0)
        set.completedSetCount = 99
        XCTAssertEqual(set.completedSetProgress, 1)
        let empty = WorkoutActivityAttributes.SetSnapshot(
            setID: nil, exerciseName: "Bench Press", setNumber: 0, setCount: 0,
            result: "—", completedSetCount: 0
        )
        XCTAssertNil(empty.completedSetProgress)
    }
}

final class WorkoutLiveActivityArtworkTests: XCTestCase {
    func testLegacySetSnapshotDecodesWithoutArtwork() throws {
        let data = Data(#"{"setID":"set","exerciseName":"Bench Press","setNumber":1,"setCount":4,"result":"135 lb × 8"}"#.utf8)
        let snapshot = try JSONDecoder().decode(WorkoutActivityAttributes.SetSnapshot.self, from: data)
        XCTAssertNil(snapshot.artworkFileName)
        XCTAssertNil(snapshot.completedSetCount)
        XCTAssertEqual(snapshot.setNumber, 1)
    }

    func testArtworkSnapshotRoundTripsWithinActivityPayloadBudget() throws {
        let set = WorkoutActivityAttributes.SetSnapshot(
            setID: UUID().uuidString,
            exerciseName: "Bench Press: Barbell",
            setNumber: 1,
            setCount: 4,
            result: "135 lb × 8",
            artworkFileName: "exercise.gif.png",
            completedSetCount: 2
        )
        let state = WorkoutActivityAttributes.ContentState(
            phase: .currentSet, displaySet: set, nextSet: set,
            confirmationUntil: nil, restTimerStart: nil, restTimerEnd: nil,
            completedSets: 0, totalSets: 20
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(WorkoutActivityAttributes.ContentState.self, from: data)
        XCTAssertEqual(decoded.displaySet?.artworkFileName, "exercise.gif.png")
        XCTAssertEqual(decoded.displaySet?.completedSetCount, 2)
        XCTAssertEqual(decoded, state)
        XCTAssertLessThan(data.count, 2_048, "Leave room for ActivityKit attributes and longer exercise labels")
    }

    func testArtworkRejectsUntrustedFilePaths() {
        for name in ["", "../image.png", "/tmp/image.png", "a\\image.png", "image.gif", "a\u{0}.png", "https://example.com/image.png"] {
            XCTAssertNil(WorkoutLiveActivityArtwork.fileURL(for: name), name)
        }
    }

    @MainActor
    func testCachedArtworkIsReadyBeforeActivityPublication() async throws {
        let remoteURL = try XCTUnwrap(URL(string: "https://static.exercisedb.dev/media/iron-test-\(UUID().uuidString).gif"))
        let store = ExerciseMediaStore.shared
        let sourceURL = store.fileURL(for: remoteURL)
        let fileName = remoteURL.lastPathComponent + ".png"
        guard let artworkURL = WorkoutLiveActivityArtwork.fileURL(for: fileName) else {
            throw XCTSkip("This signing configuration has no shared artwork container")
        }
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: artworkURL)
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 192)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 192))
        }
        try XCTUnwrap(image.pngData()).write(to: sourceURL, options: .atomic)
        XCTAssertEqual(store.liveActivityArtworkFileName(for: remoteURL), fileName)
        await store.prepareLiveActivityArtwork(fileNames: [fileName, fileName])
        let thumbnail = try XCTUnwrap(UIImage(contentsOfFile: artworkURL.path))
        XCTAssertLessThanOrEqual(max(thumbnail.size.width, thumbnail.size.height), 128)
        XCTAssertEqual(thumbnail.size.width / thumbnail.size.height, 256.0 / 192.0, accuracy: 0.02)
    }
}

@available(iOS 16.1, *)
final class WorkoutLiveActivityStateTests: XCTestCase {
    private let completedSet = WorkoutActivityAttributes.SetSnapshot(
        setID: "completed-set",
        exerciseName: "Deadlift (Barbell)",
        setNumber: 1,
        setCount: 4,
        result: "135 lb × 5 reps"
    )
    private let nextSet = WorkoutActivityAttributes.SetSnapshot(
        setID: "next-set",
        exerciseName: "Deadlift (Barbell)",
        setNumber: 2,
        setCount: 4,
        result: "135 lb × 5 reps"
    )

    func testCompletionWithRunningRestPublishesRestImmediately() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let state = WorkoutActivityAttributes.ContentState(
            phase: .setCompleted,
            displaySet: completedSet,
            nextSet: nextSet,
            confirmationUntil: now.addingTimeInterval(10),
            restTimerStart: now,
            restTimerEnd: now.addingTimeInterval(70),
            completedSets: 1,
            totalSets: 4
        )

        XCTAssertEqual(state.resolvedPhase(at: now.addingTimeInterval(9.9)), .resting)
        XCTAssertEqual(state.visibleSet(at: now.addingTimeInterval(9.9)), nextSet)
        XCTAssertEqual(state.resolvedPhase(at: now.addingTimeInterval(10)), .resting)
        XCTAssertEqual(state.visibleSet(at: now.addingTimeInterval(10)), nextSet)
        XCTAssertEqual(state.resolvedPhase(at: now.addingTimeInterval(69.9)), .resting)
        XCTAssertEqual(state.resolvedPhase(at: now.addingTimeInterval(70)), .currentSet)
        XCTAssertEqual(state.visibleSet(at: now.addingTimeInterval(70)), nextSet)
    }

    func testFinalSetFinishesAfterConfirmationWithoutAnUnusedRestPhase() {
        let now = Date(timeIntervalSinceReferenceDate: 20_000)
        let state = WorkoutActivityAttributes.ContentState(
            phase: .setCompleted,
            displaySet: completedSet,
            nextSet: nil,
            confirmationUntil: now.addingTimeInterval(10),
            restTimerStart: now,
            restTimerEnd: now.addingTimeInterval(30),
            completedSets: 4,
            totalSets: 4
        )

        XCTAssertEqual(state.resolvedPhase(at: now.addingTimeInterval(10)), .finished)
        XCTAssertEqual(state.resolvedPhase(at: now.addingTimeInterval(30)), .finished)
    }

    func testPublishedRestPhaseStillAdvancesIfTheAppSuspends() {
        let now = Date(timeIntervalSinceReferenceDate: 30_000)
        let state = WorkoutActivityAttributes.ContentState(
            phase: .resting,
            displaySet: completedSet,
            nextSet: nextSet,
            confirmationUntil: nil,
            restTimerStart: now,
            restTimerEnd: now.addingTimeInterval(20),
            completedSets: 1,
            totalSets: 4
        )

        XCTAssertEqual(state.resolvedPhase(at: now.addingTimeInterval(19.9)), .resting)
        XCTAssertEqual(state.resolvedPhase(at: now.addingTimeInterval(20)), .currentSet)
        XCTAssertEqual(state.visibleSet(at: now.addingTimeInterval(20)), nextSet)
    }

    func testRestProgressClampsAtBothBoundaries() {
        let now = Date(timeIntervalSinceReferenceDate: 40_000)
        let state = WorkoutActivityAttributes.ContentState(
            phase: .resting,
            displaySet: completedSet,
            nextSet: nextSet,
            confirmationUntil: nil,
            restTimerStart: now,
            restTimerEnd: now.addingTimeInterval(60),
            completedSets: 1,
            totalSets: 4
        )

        XCTAssertEqual(state.restProgress(at: now.addingTimeInterval(-1)), 0)
        XCTAssertEqual(state.restProgress(at: now.addingTimeInterval(30)), 0.5)
        XCTAssertEqual(state.restProgress(at: now.addingTimeInterval(61)), 1)
    }
}

@available(iOS 17.0, *)
final class WorkoutLiveActivityReconciliationTests: XCTestCase {
    private var persistentContainer: NSPersistentContainer!
    private var workout: Workout!
    private var exercise: WorkoutExercise!
    private var sets: [WorkoutSet]!

    override func setUp() {
        super.setUp()
        persistentContainer = setUpInMemoryNSPersistentContainer()
        let context = persistentContainer.viewContext
        workout = Workout.create(context: context)
        workout.start = Date(timeIntervalSinceReferenceDate: 1_000)
        workout.isCurrentWorkout = true
        exercise = WorkoutExercise.create(context: context)
        exercise.workout = workout
        sets = (0..<3).map { index in
            let set = WorkoutSet.create(context: context)
            set.weightValue = Double(100 + index * 10)
            set.repetitionsValue = Int16(5 + index)
            set.isCompleted = index == 0
            set.workoutExercise = exercise
            return set
        }
        workout.workoutExercises = NSOrderedSet(array: [exercise])
        exercise.workoutSets = NSOrderedSet(array: sets)
    }

    override func tearDown() {
        persistentContainer.viewContext.reset()
        persistentContainer = nil
        workout = nil
        exercise = nil
        sets = nil
        super.tearDown()
    }

    private func setID(_ set: WorkoutSet) -> String {
        set.uuid?.uuidString ?? set.objectID.uriRepresentation().absoluteString
    }

    private func snapshot(for set: WorkoutSet, number: Int) -> WorkoutActivityAttributes.SetSnapshot {
        WorkoutActivityAttributes.SetSnapshot(
            setID: setID(set),
            exerciseName: "Exercise",
            setNumber: number,
            setCount: sets.count,
            result: "stale result"
        )
    }

    private func priorState(
        phase: WorkoutActivityAttributes.Phase = .setCompleted,
        confirmationUntil: Date? = Date(timeIntervalSinceReferenceDate: 2_000)
    ) -> WorkoutActivityAttributes.ContentState {
        WorkoutActivityAttributes.ContentState(
            phase: phase,
            displaySet: snapshot(for: sets[0], number: 1),
            nextSet: snapshot(for: sets[1], number: 2),
            confirmationUntil: confirmationUntil,
            restTimerStart: nil,
            restTimerEnd: nil,
            completedSets: 1,
            totalSets: 3
        )
    }

    private func reconcile(
        prior: WorkoutActivityAttributes.ContentState?,
        now: Date = Date(timeIntervalSinceReferenceDate: 1_500),
        restTimerStart: Date? = nil,
        restTimerEnd: Date? = nil
    ) -> WorkoutActivityAttributes.ContentState {
        WorkoutLiveActivityManager.shared.reconciledState(
            for: workout,
            priorState: prior,
            now: now,
            restTimerStart: restTimerStart,
            restTimerEnd: restTimerEnd
        )
    }

    func testReconciliationRefreshesEditedWeightAndRepetitions() {
        sets[1].weightValue = 225
        sets[1].repetitionsValue = 8

        let state = reconcile(prior: priorState())

        XCTAssertEqual(state.nextSet?.setID, setID(sets[1]))
        XCTAssertEqual(
            state.nextSet?.result,
            sets[1].resultTitle(weightUnit: SettingsStore.shared.weightUnit)
        )
        XCTAssertNotEqual(state.nextSet?.result, "stale result")
    }

    func testReconciliationSelectsFollowingSetWhenPriorNextSetWasRemoved() {
        let prior = priorState()
        let removed = sets[1]
        exercise.workoutSets = NSOrderedSet(array: [sets[0], sets[2]])
        persistentContainer.viewContext.delete(removed)
        persistentContainer.viewContext.processPendingChanges()

        let state = reconcile(prior: prior)

        XCTAssertEqual(state.nextSet?.setID, setID(sets[2]))
        XCTAssertEqual(state.nextSet?.setNumber, 2)
        XCTAssertEqual(state.totalSets, 2)
    }

    func testReconciliationIgnoresSetPendingDeletionWithoutRelationshipCleanup() {
        let prior = priorState()
        persistentContainer.viewContext.delete(sets[1])

        let state = reconcile(prior: prior)

        XCTAssertEqual(state.nextSet?.setID, setID(sets[2]))
        XCTAssertEqual(state.nextSet?.setNumber, 2)
        XCTAssertEqual(state.nextSet?.setCount, 2)
        XCTAssertEqual(state.totalSets, 2)
    }

    func testReconciliationDropsConfirmationWhenCompletedAnchorWasRemoved() {
        let prior = priorState()
        let removed = sets[0]
        exercise.workoutSets = NSOrderedSet(array: [sets[1], sets[2]])
        persistentContainer.viewContext.delete(removed)
        persistentContainer.viewContext.processPendingChanges()

        let state = reconcile(prior: prior)

        XCTAssertEqual(state.phase, .currentSet)
        XCTAssertNil(state.confirmationUntil)
        XCTAssertEqual(state.nextSet?.setID, setID(sets[1]))
        XCTAssertEqual(state.completedSets, 0)
        XCTAssertEqual(state.totalSets, 2)
    }

    func testReconciliationUsesCurrentOrderAfterCompletedAnchor() {
        exercise.workoutSets = NSOrderedSet(array: [sets[0], sets[2], sets[1]])

        let state = reconcile(prior: priorState())

        XCTAssertEqual(state.nextSet?.setID, setID(sets[2]))
        XCTAssertEqual(state.nextSet?.setNumber, 2)
    }

    func testRepeatedReconciliationRetainsAnchorWithEarlierIncompleteSet() {
        exercise.workoutSets = NSOrderedSet(array: [sets[1], sets[0], sets[2]])
        let first = reconcile(prior: priorState(phase: .resting, confirmationUntil: nil))

        let second = reconcile(prior: first)

        XCTAssertEqual(first.displaySet?.setID, setID(sets[0]))
        XCTAssertEqual(first.nextSet?.setID, setID(sets[2]))
        XCTAssertEqual(second.displaySet?.setID, setID(sets[0]))
        XCTAssertEqual(second.nextSet?.setID, setID(sets[2]))
    }

    func testSupersetActivityUsesTheSameNextSetAsTheFocusedEditor() {
        let context = persistentContainer.viewContext
        let group = UUID()
        exercise.supersetUuid = group
        let partner = WorkoutExercise.create(context: context)
        partner.workout = workout
        partner.supersetUuid = group
        let partnerSets = (0..<2).map { _ -> WorkoutSet in
            let set = WorkoutSet.create(context: context)
            set.workoutExercise = partner
            return set
        }
        partner.workoutSets = NSOrderedSet(array: partnerSets)
        workout.workoutExercises = NSOrderedSet(array: [exercise!, partner])

        let first = reconcile(prior: priorState(phase: .resting, confirmationUntil: nil))
        XCTAssertEqual(first.nextSet?.setID, setID(partnerSets[0]))
        XCTAssertEqual(WorkoutSetFocus.next(in: workout)?.setID, partnerSets[0].objectID)
        partnerSets[0].isCompleted = true
        let second = reconcile(prior: first)
        XCTAssertEqual(second.nextSet?.setID, setID(sets[1]))
        XCTAssertEqual(WorkoutSetFocus.next(in: workout)?.setID, sets[1].objectID)
    }

    func testReconciliationFinishesWithoutReopeningCompletedSets() {
        sets.forEach { $0.isCompleted = true }

        let state = reconcile(prior: priorState(confirmationUntil: nil))

        XCTAssertEqual(state.phase, .finished)
        XCTAssertNil(state.nextSet)
        XCTAssertNil(state.restTimerStart)
        XCTAssertNil(state.restTimerEnd)
        XCTAssertEqual(state.completedSets, 3)
        XCTAssertEqual(state.totalSets, 3)
    }

    func testReconciliationRestoresActiveRestTimerWithoutPriorActivityState() {
        let now = Date(timeIntervalSinceReferenceDate: 3_000)
        let timerStart = now.addingTimeInterval(-15)
        let timerEnd = now.addingTimeInterval(45)

        let state = reconcile(
            prior: nil,
            now: now,
            restTimerStart: timerStart,
            restTimerEnd: timerEnd
        )

        XCTAssertEqual(state.phase, .resting)
        XCTAssertEqual(state.restTimerStart, timerStart)
        XCTAssertEqual(state.restTimerEnd, timerEnd)
        XCTAssertEqual(state.nextSet?.setID, setID(sets[1]))
    }

    func testDeletingEverySetClearsStaleSnapshotsWithoutFinishingEmptyWorkout() {
        let prior = priorState()
        exercise.workoutSets = NSOrderedSet()
        sets.forEach { persistentContainer.viewContext.delete($0) }

        let state = reconcile(prior: prior)

        XCTAssertEqual(state.phase, .currentSet)
        XCTAssertNil(state.displaySet)
        XCTAssertNil(state.nextSet)
        XCTAssertEqual(state.totalSets, 0)
    }

    @MainActor
    func testFailedCompletionSaveRestoresOwnedFieldsOnly() async {
        enum ExpectedError: Error { case saveFailed }
        let set = sets[1]
        set.repetitionsValue = 12
        let previousCompletedAt = Date(timeIntervalSinceReferenceDate: 500)
        set.completedAt = previousCompletedAt
        workout.start = nil

        do {
            try WorkoutLiveActivityIntentHandler.persistCompletion(
                set: set,
                workout: workout,
                at: Date(timeIntervalSinceReferenceDate: 4_000),
                save: { throw ExpectedError.saveFailed }
            )
            XCTFail("Expected the save to fail")
        } catch ExpectedError.saveFailed {
            // Expected. Assertions below verify the targeted restoration.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(set.isCompleted)
        XCTAssertEqual(set.completedAt, previousCompletedAt)
        XCTAssertNil(workout.start)
        XCTAssertEqual(set.repetitionsValue, 12)
        XCTAssertTrue(persistentContainer.viewContext.hasChanges)
    }
}

final class WatchEventPersistenceTests: XCTestCase {
    private enum ExpectedError: Error { case saveFailed }

    private var persistentContainer: NSPersistentContainer!
    private var context: NSManagedObjectContext!
    private var workout: Workout!
    private var exercise: WorkoutExercise!
    private var sets: [WorkoutSet]!

    override func setUp() {
        super.setUp()
        persistentContainer = setUpInMemoryNSPersistentContainer()
        context = persistentContainer.viewContext
        workout = Workout.create(context: context)
        workout.isCurrentWorkout = true
        workout.start = Date(timeIntervalSinceReferenceDate: 1_000)
        exercise = WorkoutExercise.create(context: context)
        exercise.workout = workout
        sets = (0..<2).map { index in
            let set = WorkoutSet.create(context: context)
            set.weightValue = Double(100 + index * 10)
            set.repetitionsValue = Int16(5 + index)
            set.workoutExercise = exercise
            return set
        }
        workout.workoutExercises = NSOrderedSet(array: [exercise])
        exercise.workoutSets = NSOrderedSet(array: sets)
        try! context.save()
    }

    override func tearDown() {
        context.reset()
        context = nil
        persistentContainer = nil
        workout = nil
        exercise = nil
        sets = nil
        super.tearDown()
    }

    private func event(
        kind: WatchWorkoutEventKind,
        setID: UUID? = nil,
        weight: Double? = nil,
        reps: Int? = nil,
        id: UUID = UUID()
    ) -> WatchWorkoutEvent {
        WatchWorkoutEvent(
            workoutID: workout.uuid!,
            sequence: 1,
            kind: kind,
            exerciseID: exercise.uuid,
            setID: setID,
            weight: weight,
            reps: reps,
            id: id
        )
    }

    func testFailedScalarUpdateRestoresEventFieldsAndPreservesPendingUserEdit() {
        let originalWeight = sets[0].weight
        let originalRepetitions = sets[0].repetitions
        workout.title = "Pending user title"
        var effects = 0
        var acknowledgements = 0
        let update = event(
            kind: .setUpdated,
            setID: sets[0].uuid,
            weight: 225,
            reps: 12
        )

        XCTAssertThrowsError(try WatchConnectionManager.commitWatchEventMutation(
            in: context,
            save: { throw ExpectedError.saveFailed },
            mutation: {
                _ = try WatchConnectionManager.shared.applyWatchEventModelMutation(
                    update,
                    to: self.workout,
                    in: self.context
                )
                return .init(perform: { effects += 1 })
            },
            didPersist: { acknowledgements += 1 }
        ))

        XCTAssertEqual(sets[0].weight, originalWeight)
        XCTAssertEqual(sets[0].repetitions, originalRepetitions)
        XCTAssertEqual(workout.title, "Pending user title")
        XCTAssertEqual(effects, 0)
        XCTAssertEqual(acknowledgements, 0)
        XCTAssertTrue(context.hasChanges)
    }

    func testFailedSetInsertionRemovesInsertedObject() {
        let insertedID = UUID()
        let add = event(kind: .setAdded, setID: insertedID, weight: 140, reps: 8)

        XCTAssertThrowsError(try WatchConnectionManager.persistWatchEventMutation(
            in: context,
            save: { throw ExpectedError.saveFailed },
            mutation: {
                try WatchConnectionManager.shared.applyWatchEventModelMutation(
                    add,
                    to: self.workout,
                    in: self.context
                )
            }
        ))

        let currentSets = exercise.workoutSets?.array.compactMap { $0 as? WorkoutSet } ?? []
        XCTAssertEqual(currentSets.count, 2)
        XCTAssertFalse(currentSets.contains { $0.uuid == insertedID })
        XCTAssertFalse(context.insertedObjects.contains { ($0 as? WorkoutSet)?.uuid == insertedID })
    }

    func testFailedSetDeletionRestoresDeletedObjectAndRelationship() {
        let deletedID = sets[0].uuid!
        let delete = event(kind: .setDeleted, setID: deletedID)

        XCTAssertThrowsError(try WatchConnectionManager.persistWatchEventMutation(
            in: context,
            save: { throw ExpectedError.saveFailed },
            mutation: {
                try WatchConnectionManager.shared.applyWatchEventModelMutation(
                    delete,
                    to: self.workout,
                    in: self.context
                )
            }
        ))

        let currentSets = exercise.workoutSets?.array.compactMap { $0 as? WorkoutSet } ?? []
        XCTAssertEqual(currentSets.count, 2)
        XCTAssertTrue(currentSets.contains { $0.uuid == deletedID })
        XCTAssertFalse(sets[0].isDeleted)
    }

    func testFailedEventCanRetryAndOnlyThenPerformEffectsAndAcknowledge() throws {
        let update = event(kind: .setUpdated, setID: sets[0].uuid, weight: 180, reps: 9)
        var effects = 0
        var acknowledgements = 0

        XCTAssertThrowsError(try WatchConnectionManager.commitWatchEventMutation(
            in: context,
            save: { throw ExpectedError.saveFailed },
            mutation: {
                _ = try WatchConnectionManager.shared.applyWatchEventModelMutation(
                    update,
                    to: self.workout,
                    in: self.context
                )
                return .init(perform: { effects += 1 })
            },
            didPersist: { acknowledgements += 1 }
        ))

        try WatchConnectionManager.commitWatchEventMutation(
            in: context,
            save: { try self.context.save() },
            mutation: {
                _ = try WatchConnectionManager.shared.applyWatchEventModelMutation(
                    update,
                    to: self.workout,
                    in: self.context
                )
                return .init(perform: { effects += 1 })
            },
            didPersist: { acknowledgements += 1 }
        )

        XCTAssertEqual(sets[0].weightValue, 180, accuracy: 0.001)
        XCTAssertEqual(sets[0].repetitionsValue, 9)
        XCTAssertEqual(effects, 1)
        XCTAssertEqual(acknowledgements, 1)
        XCTAssertFalse(context.hasChanges)
    }

    func testDuplicateSetAddedEventRemainsIdempotent() throws {
        let insertedID = UUID()
        let eventID = UUID()
        let add = event(kind: .setAdded, setID: insertedID, id: eventID)

        for _ in 0..<2 {
            _ = try WatchConnectionManager.persistWatchEventMutation(
                in: context,
                save: { try self.context.save() },
                mutation: {
                    try WatchConnectionManager.shared.applyWatchEventModelMutation(
                        add,
                        to: self.workout,
                        in: self.context
                    )
                }
            )
        }

        let matchingSets = exercise.workoutSets?.array.compactMap { $0 as? WorkoutSet }
            .filter { $0.uuid == insertedID } ?? []
        XCTAssertEqual(matchingSets.count, 1)
    }

    func testThrowDuringMutationRestoresPendingChangesBeforeUndo() {
        let originalWeight = sets[0].weightValue
        workout.title = "Keep this pending title"
        XCTAssertThrowsError(try WatchConnectionManager.persistWatchEventMutation(
            in: context,
            save: { XCTFail("A throwing mutation cannot be saved") },
            mutation: {
                self.sets[0].weightValue = 999
                throw ExpectedError.saveFailed
            }
        ))
        XCTAssertEqual(sets[0].weightValue, originalWeight)
        XCTAssertEqual(workout.title, "Keep this pending title")
    }

    func testFailedWorkoutDiscardRestoresCascadingRelationships() {
        let originalID = workout.uuid
        let discard = event(kind: .workoutDiscarded)
        workout.title = "Pending title"
        XCTAssertThrowsError(try WatchConnectionManager.persistWatchEventMutation(
            in: context,
            save: { throw ExpectedError.saveFailed },
            mutation: {
                try WatchConnectionManager.shared.applyWatchEventModelMutation(
                    discard, to: self.workout, in: self.context
                )
            }
        ))
        XCTAssertFalse(workout.isDeleted)
        XCTAssertEqual(workout.uuid, originalID)
        XCTAssertEqual(workout.title, "Pending title")
        XCTAssertEqual(workout.workoutExercises?.count, 1)
        XCTAssertEqual(exercise.workoutSets?.count, 2)
        XCTAssertTrue(sets.allSatisfy { !$0.isDeleted })
    }
}

@available(iOS 17.0, *)
final class WorkoutPausedLiveActivityTests: XCTestCase {
    private var next: WorkoutActivityAttributes.SetSnapshot {
        .init(setID: "next", exerciseName: "Bench Press", setNumber: 2, setCount: 3, result: "100 lb × 8")
    }

    private func state(phase: WorkoutActivityAttributes.Phase = .resting) -> WorkoutActivityAttributes.ContentState {
        .init(phase: phase, displaySet: next, nextSet: next,
              confirmationUntil: Date(timeIntervalSince1970: 1_010),
              restTimerStart: nil, restTimerEnd: nil, completedSets: 1, totalSets: 3,
              pausedRestRemaining: 45)
    }

    func testPausedRestDoesNotAdvanceWithWallClockTime() {
        let paused = state()
        XCTAssertEqual(paused.resolvedPhase(at: Date(timeIntervalSince1970: 9_000)), .resting)
        XCTAssertEqual(paused.visibleSet(at: Date()), next)
        XCTAssertNil(paused.restProgress(at: Date()))
        XCTAssertEqual(paused.pausedRestRemaining, 45)
    }

    func testCompletionWithPausedRestPublishesRestImmediately() {
        let paused = state(phase: .setCompleted)
        XCTAssertEqual(paused.resolvedPhase(at: Date(timeIntervalSince1970: 1_005)), .resting)
        XCTAssertEqual(paused.resolvedPhase(at: Date(timeIntervalSince1970: 1_020)), .resting)
    }

    func testOlderActivityPayloadStillDecodesWithoutPauseField() throws {
        let encoded = try JSONEncoder().encode(state())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "pausedRestRemaining")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(WorkoutActivityAttributes.ContentState.self, from: legacyData)
        XCTAssertNil(decoded.pausedRestRemaining)
        XCTAssertFalse(decoded.isRestPaused)
        XCTAssertEqual(decoded.resolvedPhase(at: Date()), .currentSet)
    }

    func testReconciliationRetainsPausedRestAndClearsItAfterLastSet() {
        let container = setUpInMemoryNSPersistentContainer()
        let workout = Workout.create(context: container.viewContext)
        let exercise = WorkoutExercise.create(context: container.viewContext)
        exercise.workout = workout
        let set = WorkoutSet.create(context: container.viewContext)
        set.workoutExercise = exercise
        let now = Date()
        // Even old dates must remain in a paused payload; only the total and
        // captured remaining time determine its frozen progress.
        let start = now.addingTimeInterval(-300)
        let end = start.addingTimeInterval(120)
        let reconcile = {
            WorkoutLiveActivityManager.shared.reconciledState(
                for: workout, priorState: nil, now: now, restTimerStart: start,
                restTimerEnd: end, pausedRestRemaining: 45
            )
        }
        let paused = reconcile()
        XCTAssertEqual(paused.phase, .resting)
        XCTAssertEqual(paused.pausedRestRemaining, 45)
        XCTAssertEqual(paused.restTimerStart, start)
        XCTAssertEqual(paused.restTimerEnd, end)
        XCTAssertEqual(paused.restDuration, 120)
        XCTAssertEqual(paused.restProgress(at: now), 0.625)
        XCTAssertEqual(paused.restProgress(at: now.addingTimeInterval(300)), 0.625)
        set.isCompleted = true
        XCTAssertEqual(reconcile().phase, .finished)
        XCTAssertNil(reconcile().pausedRestRemaining)
        XCTAssertNil(reconcile().restTimerInterval)
    }
}

final class WorkoutLifecyclePersistenceTests: XCTestCase {
    private enum Failure: Error { case save }
    private var container: NSPersistentContainer!
    private var workout: Workout!
    private var exercise: WorkoutExercise!

    override func setUpWithError() throws {
        container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        workout = Workout.create(context: context)
        workout.isCurrentWorkout = true
        workout.start = Date(timeIntervalSince1970: 1_000)
        exercise = WorkoutExercise.create(context: context)
        exercise.workout = workout
        for completed in [true, false] {
            let set = WorkoutSet.create(context: context)
            set.workoutExercise = exercise
            set.weightValue = 50
            set.repetitionsValue = 8
            set.isCompleted = completed
        }
        try context.save()
    }

    override func tearDown() {
        container.viewContext.reset()
        container = nil
        workout = nil
        exercise = nil
    }

    func testFailedFinishRestoresUncompletedSetsAndEditorValues() {
        workout.title = "Pending title"
        XCTAssertThrowsError(try workout.finish(syncToHealth: false, save: { throw Failure.save }) {
            self.workout.title = "Changed by finish editor"
            self.workout.end = Date(timeIntervalSince1970: 2_000)
            self.workout.sessionEffortValue = 8
        })
        XCTAssertTrue(workout.isCurrentWorkout)
        XCTAssertNil(workout.end)
        XCTAssertEqual(workout.title, "Pending title")
        XCTAssertEqual(exercise.workoutSets?.count, 2)
        XCTAssertEqual(workout.workoutExercises?.count, 1)
        XCTAssertTrue(container.viewContext.hasChanges)
    }

    func testFailedCancelLeavesWorkoutAndRelationshipsIntact() {
        XCTAssertThrowsError(try workout.cancel(save: { throw Failure.save }))
        XCTAssertFalse(workout.isDeleted)
        XCTAssertTrue(workout.isCurrentWorkout)
        XCTAssertEqual(workout.workoutExercises?.count, 1)
        XCTAssertEqual(exercise.workoutSets?.count, 2)
    }

    func testFailedHistoryDeletionLeavesSavedWorkoutIntact() {
        XCTAssertThrowsError(try workout.delete(save: { throw Failure.save }))
        XCTAssertFalse(workout.isDeleted)
        XCTAssertEqual(exercise.workoutSets?.count, 2)
    }

    func testFailedStartRestoresPriorStartAndStatus() {
        let originalStart = workout.start
        workout.isCurrentWorkout = false
        XCTAssertThrowsError(try workout.start(save: { throw Failure.save }))
        XCTAssertFalse(workout.isCurrentWorkout)
        XCTAssertEqual(workout.start, originalStart)
    }
}

final class CurrentWorkoutMutationPersistenceTests: XCTestCase {
    private enum Failure: Error { case save }
    private var container: NSPersistentContainer!
    private var workout: Workout!
    private var exercises: [WorkoutExercise]!

    override func setUpWithError() throws {
        container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        workout = Workout.create(context: context)
        workout.isCurrentWorkout = true
        workout.start = Date(timeIntervalSince1970: 1_000)
        exercises = (0..<2).map { index in
            let exercise = WorkoutExercise.create(context: context)
            exercise.uuid = UUID()
            exercise.exerciseUuid = UUID()
            exercise.comment = "Exercise \(index)"
            workout.addToWorkoutExercises(exercise)

            let set = WorkoutSet.create(context: context)
            set.uuid = UUID()
            set.weightValue = Double(40 + index)
            set.repetitionsValue = 5
            exercise.addToWorkoutSets(set)
            return exercise
        }
        try context.save()
    }

    override func tearDown() {
        container.viewContext.reset()
        container = nil
        workout = nil
        exercises = nil
    }

    func testFailedExerciseInsertionRemovesInsertedGraphAndPreservesPendingEdit() {
        let context = container.viewContext
        workout.title = "Pending title"

        XCTAssertThrowsError(try CurrentWorkoutPersistence.perform(
            in: context,
            save: { throw Failure.save }
        ) {
            let exercise = WorkoutExercise.create(context: context)
            workout.addToWorkoutExercises(exercise)
            let set = WorkoutSet.create(context: context)
            exercise.addToWorkoutSets(set)
        })

        XCTAssertEqual(workout.workoutExercises?.count, 2)
        XCTAssertTrue(context.insertedObjects.isEmpty)
        XCTAssertEqual(workout.title, "Pending title")
        XCTAssertTrue(context.hasChanges)
    }

    func testFailedSetDeletionRestoresObjectAndRelationship() throws {
        let context = container.viewContext
        let exercise = try XCTUnwrap(exercises.first)
        let set = try XCTUnwrap(exercise.workoutSets?.firstObject as? WorkoutSet)

        XCTAssertThrowsError(try CurrentWorkoutPersistence.perform(
            in: context,
            save: { throw Failure.save }
        ) {
            exercise.removeFromWorkoutSets(set)
            context.delete(set)
        })

        XCTAssertFalse(set.isDeleted)
        XCTAssertEqual(set.workoutExercise, exercise)
        XCTAssertEqual(exercise.workoutSets?.count, 1)
        XCTAssertTrue(context.deletedObjects.isEmpty)
    }

    func testFailedExerciseReorderRestoresOriginalOrder() {
        let context = container.viewContext
        let originalIDs = exercises.map(\.objectID)

        XCTAssertThrowsError(try CurrentWorkoutPersistence.perform(
            in: context,
            save: { throw Failure.save }
        ) {
            workout.workoutExercises = NSOrderedSet(array: Array(exercises.reversed()))
        })

        let restoredIDs = workout.workoutExercises?.array
            .compactMap { ($0 as? WorkoutExercise)?.objectID }
        XCTAssertEqual(restoredIDs, originalIDs)
    }

    func testFailedConfigurationMutationRestoresAllSetFields() throws {
        let context = container.viewContext
        let exercise = try XCTUnwrap(exercises.first)
        let set = try XCTUnwrap(exercise.workoutSets?.firstObject as? WorkoutSet)
        let originalWeight = set.weightValue
        let originalRepetitions = set.repetitionsValue

        XCTAssertThrowsError(try CurrentWorkoutPersistence.perform(
            in: context,
            save: { throw Failure.save }
        ) {
            exercise.restTimerDurationValue = 90
            set.durationValue = 60
            set.weightValue = 0
            set.repetitionsValue = 0
        })

        XCTAssertNil(exercise.restTimerDurationValue)
        XCTAssertNil(set.durationValue)
        XCTAssertEqual(set.weightValue, originalWeight)
        XCTAssertEqual(set.repetitionsValue, originalRepetitions)
    }
}

final class SavedWorkoutEditorPersistenceTests: XCTestCase {
    private struct SaveFailure: Error {}
    private var container: NSPersistentContainer!
    private var context: NSManagedObjectContext { container.viewContext }

    override func setUp() {
        super.setUp()
        container = setUpInMemoryNSPersistentContainer()
    }

    override func tearDown() {
        context.reset()
        container = nil
        super.tearDown()
    }

    private func savedRoutine() throws -> WorkoutRoutine {
        let plan = WorkoutPlan.create(context: context)
        let routine = WorkoutRoutine.create(context: context)
        routine.workoutPlan = plan
        routine.title = "Push"
        let exercise = WorkoutRoutineExercise.create(context: context)
        exercise.workoutRoutine = routine
        exercise.exerciseUuid = UUID()
        exercise.restTimerDurationValue = 90
        let set = WorkoutRoutineSet.create(context: context)
        set.workoutRoutineExercise = exercise
        set.weightValue = 50
        set.minRepetitionsValue = 8
        set.maxRepetitionsValue = 10
        try context.save()
        return routine
    }

    func testFailedEditKeepsDraftAndCanRetryWithoutReplacingHistoryLinks() throws {
        let routine = try savedRoutine()
        let originalExercise = try XCTUnwrap(routine.workoutRoutineExercises?.firstObject as? WorkoutRoutineExercise)
        let originalSet = try XCTUnwrap(originalExercise.workoutRoutineSets?.firstObject as? WorkoutRoutineSet)
        let history = Workout.create(context: context)
        history.workoutRoutine = routine
        history.start = Date(timeIntervalSince1970: 1_000)
        history.end = Date(timeIntervalSince1970: 2_000)
        try context.save()
        let session = try WorkoutPlanEditorSession(parentContext: context, route: .init(kind: .edit(planID: routine.objectID)))
        let draftExercise = try XCTUnwrap(session.routine.workoutRoutineExercises?.firstObject as? WorkoutRoutineExercise)
        let draftSet = try XCTUnwrap(draftExercise.workoutRoutineSets?.firstObject as? WorkoutRoutineSet)
        session.routine.title = "Push Updated"
        draftExercise.restTimerDurationValue = 120
        draftSet.weightValue = 65
        history.comment = "Unrelated pending edit"

        XCTAssertThrowsError(try session.commit(save: { throw SaveFailure() }))
        XCTAssertEqual(routine.title, "Push")
        XCTAssertEqual(originalSet.weightValue, 50)
        XCTAssertEqual(history.comment, "Unrelated pending edit")
        XCTAssertEqual(session.routine.title, "Push Updated")
        XCTAssertEqual(draftSet.weightValue, 65)

        try session.commit()
        XCTAssertEqual(routine.title, "Push Updated")
        XCTAssertEqual(originalSet.weightValue, 65)
        XCTAssertEqual(originalExercise.restTimerDurationValue, 120)
        XCTAssertEqual(history.workoutRoutine, routine)
        XCTAssertEqual((routine.workoutRoutineExercises?.firstObject as? WorkoutRoutineExercise)?.objectID, originalExercise.objectID)
    }

    func testFailedCreationRemovesParentOrphansButRetainsRetryableDraft() throws {
        let session = try WorkoutPlanEditorSession(parentContext: context, route: .init(kind: .create(containerID: nil)))
        session.routine.title = "New Workout"
        let draftExercise = WorkoutRoutineExercise.create(context: session.context)
        draftExercise.workoutRoutine = session.routine
        let draftSet = WorkoutRoutineSet.create(context: session.context)
        draftSet.workoutRoutineExercise = draftExercise
        draftSet.durationValue = 45

        XCTAssertThrowsError(try session.commit(save: { throw SaveFailure() }))
        XCTAssertEqual(try context.count(for: WorkoutPlan.fetchRequest()), 0)
        XCTAssertEqual(try context.count(for: WorkoutRoutine.fetchRequest()), 0)
        XCTAssertEqual(try context.count(for: WorkoutRoutineExercise.fetchRequest()), 0)
        XCTAssertEqual(try context.count(for: WorkoutRoutineSet.fetchRequest()), 0)
        XCTAssertEqual(draftSet.durationValue, 45)

        try session.commit()
        XCTAssertEqual(try context.count(for: WorkoutRoutine.fetchRequest()), 1)
        let result = try XCTUnwrap(context.fetch(WorkoutRoutine.fetchRequest()).first)
        XCTAssertEqual(result.title, "New Workout")
        XCTAssertEqual(result.uuid, session.routine.uuid)
        XCTAssertEqual(try context.count(for: WorkoutRoutineSet.fetchRequest()), 1)
    }

    func testFailedDuplicateLeavesOriginalUntouchedAndRetriesOnce() throws {
        let source = try savedRoutine()
        let session = try WorkoutPlanEditorSession(parentContext: context, route: .init(kind: .duplicate(planID: source.objectID)))
        session.routine.title = "Push Copy Edited"

        XCTAssertThrowsError(try session.commit(save: { throw SaveFailure() }))
        XCTAssertEqual(try context.count(for: WorkoutRoutine.fetchRequest()), 1)
        XCTAssertEqual(source.title, "Push")
        XCTAssertEqual(session.routine.title, "Push Copy Edited")

        try session.commit()
        XCTAssertEqual(try context.count(for: WorkoutRoutine.fetchRequest()), 2)
        let copy = try XCTUnwrap(context.fetch(WorkoutRoutine.fetchRequest()).first { $0.uuid == session.routine.uuid })
        XCTAssertNotEqual(copy.uuid, source.uuid)
        XCTAssertEqual(copy.workoutPlan, source.workoutPlan)
        XCTAssertEqual(copy.title, "Push Copy Edited")
    }

    func testFailedRemovalAndInsertionRestoreOriginalTargets() throws {
        let routine = try savedRoutine()
        let original = try XCTUnwrap(routine.workoutRoutineExercises?.firstObject as? WorkoutRoutineExercise)
        let session = try WorkoutPlanEditorSession(parentContext: context, route: .init(kind: .edit(planID: routine.objectID)))
        let removed = try XCTUnwrap(session.routine.workoutRoutineExercises?.firstObject as? WorkoutRoutineExercise)
        session.routine.removeFromWorkoutRoutineExercises(removed)
        session.context.delete(removed)
        let inserted = WorkoutRoutineExercise.create(context: session.context)
        inserted.workoutRoutine = session.routine
        inserted.comment = "Replacement"
        let target = WorkoutRoutineSet.create(context: session.context)
        target.workoutRoutineExercise = inserted
        target.tagValue = .warmUp
        target.weightValue = 20

        XCTAssertThrowsError(try session.commit(save: { throw SaveFailure() }))
        XCTAssertFalse(original.isDeleted)
        XCTAssertEqual(routine.workoutRoutineExercises?.firstObject as? WorkoutRoutineExercise, original)
        XCTAssertEqual(session.routine.workoutRoutineExercises?.firstObject as? WorkoutRoutineExercise, inserted)
        XCTAssertEqual(try context.count(for: WorkoutRoutineSet.fetchRequest()), 1)

        try session.commit()
        let replacement = try XCTUnwrap(routine.workoutRoutineExercises?.firstObject as? WorkoutRoutineExercise)
        XCTAssertEqual(replacement.uuid, inserted.uuid)
        XCTAssertEqual(replacement.comment, "Replacement")
        XCTAssertEqual((replacement.workoutRoutineSets?.firstObject as? WorkoutRoutineSet)?.tagValue, .warmUp)
        XCTAssertEqual(try context.count(for: WorkoutRoutineExercise.fetchRequest()), 1)
        XCTAssertEqual(try context.count(for: WorkoutRoutineSet.fetchRequest()), 1)
    }

    func testCancellingDraftDoesNotChangeSavedTargets() throws {
        let routine = try savedRoutine()
        let session = try WorkoutPlanEditorSession(parentContext: context, route: .init(kind: .edit(planID: routine.objectID)))
        session.routine.title = "Cancelled"
        session.routine.comment = "Do not save"
        session.cancel()

        XCTAssertEqual(routine.title, "Push")
        XCTAssertNil(routine.comment)
        XCTAssertFalse(context.hasChanges)
    }

    func testCreateFromCompletedWorkoutCopiesEditableGraphAndCancelIsIsolated() throws {
        let source = Workout.create(context: context)
        source.title = "Completed Push"
        source.comment = "Keep this note"
        source.importSource = "hevy"
        source.start = Date(timeIntervalSince1970: 1_000)
        source.end = Date(timeIntervalSince1970: 2_000)

        let exercise = WorkoutExercise.create(context: context)
        exercise.exerciseUuid = UUID()
        exercise.comment = "Bench setup"
        exercise.restTimerDurationValue = 90
        let sourceSupersetID = UUID()
        exercise.supersetUuid = sourceSupersetID
        source.addToWorkoutExercises(exercise)

        let set = WorkoutSet.create(context: context)
        set.isCompleted = true
        set.weightValue = 100
        set.repetitionsValue = 8
        set.minTargetRepetitionsValue = 5
        set.maxTargetRepetitionsValue = 8
        set.tagValue = .dropSet
        set.comment = "Controlled"
        exercise.addToWorkoutSets(set)
        try context.save()

        let route = WorkoutPlanEditorRoute(
            kind: .createFromWorkout(workoutID: source.objectID, containerID: nil)
        )
        let session = try WorkoutPlanEditorSession(parentContext: context, route: route)
        let draftExercise = try XCTUnwrap(
            session.routine.workoutRoutineExercises?.firstObject as? WorkoutRoutineExercise
        )
        let draftSet = try XCTUnwrap(
            draftExercise.workoutRoutineSets?.firstObject as? WorkoutRoutineSet
        )

        XCTAssertEqual(session.routine.title, source.title)
        XCTAssertEqual(session.routine.comment, source.comment)
        XCTAssertEqual(draftExercise.exerciseUuid, exercise.exerciseUuid)
        XCTAssertNil(draftExercise.comment)
        XCTAssertEqual(draftExercise.restTimerDurationValue, 90)
        XCTAssertNotEqual(draftExercise.supersetUuid, sourceSupersetID)
        XCTAssertEqual(draftSet.minRepetitionsValue, 5)
        XCTAssertEqual(draftSet.maxRepetitionsValue, 8)
        XCTAssertEqual(draftSet.weightValue, 100)
        XCTAssertEqual(draftSet.tagValue, .dropSet)
        XCTAssertEqual(draftSet.comment, "Controlled")
        XCTAssertTrue(set.isCompleted)

        session.cancel()
        XCTAssertEqual(try context.count(for: WorkoutPlan.fetchRequest()), 0)
        XCTAssertEqual(try context.count(for: WorkoutRoutine.fetchRequest()), 0)
        XCTAssertEqual(source.title, "Completed Push")
        XCTAssertEqual(source.importSource, "hevy")
        XCTAssertTrue(set.isCompleted)
        XCTAssertFalse(context.hasChanges)

        let committedSession = try WorkoutPlanEditorSession(parentContext: context, route: route)
        try committedSession.commit()
        let saved = try XCTUnwrap(context.fetch(WorkoutRoutine.fetchRequest()).first)
        let savedExercise = try XCTUnwrap(
            saved.workoutRoutineExercises?.firstObject as? WorkoutRoutineExercise
        )
        let savedSet = try XCTUnwrap(
            savedExercise.workoutRoutineSets?.firstObject as? WorkoutRoutineSet
        )
        XCTAssertEqual(saved.title, "Completed Push")
        XCTAssertEqual(saved.comment, "Keep this note")
        XCTAssertNil(savedExercise.comment)
        XCTAssertEqual(exercise.comment, "Bench setup")
        XCTAssertEqual(savedExercise.restTimerDurationValue, 90)
        XCTAssertEqual(savedSet.minRepetitionsValue, 5)
        XCTAssertEqual(savedSet.maxRepetitionsValue, 8)
        XCTAssertEqual(savedSet.weightValue, 100)
        XCTAssertEqual(savedSet.tagValue, .dropSet)
        XCTAssertTrue(set.isCompleted)
        XCTAssertEqual(source.importSource, "hevy")
    }
}

final class SavedWorkoutEditorAvailabilityTests: XCTestCase {
    func testEditAndDuplicateRejectDeletedWorkoutsWithoutChangingPendingEdits() throws {
        for saveDeletion in [false, true] {
            let container = setUpInMemoryNSPersistentContainer()
            let context = container.viewContext
            let folder = WorkoutPlan.create(context: context)
            let routine = WorkoutRoutine.create(context: context)
            routine.workoutPlan = folder
            try context.save()
            let id = routine.objectID
            context.delete(routine)
            if saveDeletion { try context.save() }
            folder.title = "Unrelated pending edit"
            let deletedBefore = context.deletedObjects

            for kind in [WorkoutPlanEditorRoute.Kind.edit(planID: id), .duplicate(planID: id)] {
                XCTAssertThrowsError(try WorkoutPlanEditorSession(
                    parentContext: context, route: .init(kind: kind)
                )) { XCTAssertTrue($0 is WorkoutPlanEditorLoadError) }
            }

            XCTAssertEqual(folder.title, "Unrelated pending edit")
            XCTAssertEqual(context.deletedObjects, deletedBefore)
            XCTAssertTrue(context.insertedObjects.isEmpty)
            XCTAssertTrue(context.hasChanges)
            XCTAssertEqual(try context.count(for: WorkoutRoutine.fetchRequest()), 0)
        }
    }

    func testCreateRejectsDeletedFolderInsteadOfSilentlyCreatingAnother() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        let folder = WorkoutPlan.create(context: context)
        try context.save()
        let id = folder.objectID
        context.delete(folder)
        try context.save()

        XCTAssertThrowsError(try WorkoutPlanEditorSession(
            parentContext: context, route: .init(kind: .create(containerID: id))
        )) { XCTAssertTrue($0 is WorkoutPlanEditorLoadError) }
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try context.count(for: WorkoutPlan.fetchRequest()), 0)
        XCTAssertEqual(try context.count(for: WorkoutRoutine.fetchRequest()), 0)
    }

    func testWrongEntityRoutesFailWithoutCreatingDrafts() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        let folder = WorkoutPlan.create(context: context)
        let routine = WorkoutRoutine.create(context: context)
        routine.workoutPlan = folder
        try context.save()

        let kinds: [WorkoutPlanEditorRoute.Kind] = [
            .edit(planID: folder.objectID),
            .duplicate(planID: folder.objectID),
            .create(containerID: routine.objectID)
        ]
        for kind in kinds {
            XCTAssertThrowsError(try WorkoutPlanEditorSession(
                parentContext: context, route: .init(kind: kind)
            )) { XCTAssertTrue($0 is WorkoutPlanEditorLoadError) }
        }
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try context.count(for: WorkoutRoutine.fetchRequest()), 1)
    }
}

final class NewWorkoutStartPersistenceTests: XCTestCase {
    private struct SaveFailure: Error {}

    func testUnavailableRoutineCannotCreateAWorkout() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        let otherContainer = setUpInMemoryNSPersistentContainer()
        let foreignRoutine = WorkoutRoutine.create(context: otherContainer.viewContext)
        var saveCalled = false

        XCTAssertThrowsError(try Workout.startNew(in: context, routine: foreignRoutine, save: { saveCalled = true }))
        XCTAssertFalse(saveCalled)
        XCTAssertEqual(try context.count(for: Workout.fetchRequest()), 0)

        let deletedRoutine = WorkoutRoutine.create(context: context)
        context.delete(deletedRoutine)
        XCTAssertThrowsError(try Workout.startNew(in: context, routine: deletedRoutine, save: { saveCalled = true }))
        XCTAssertFalse(saveCalled)
        XCTAssertEqual(try context.count(for: Workout.fetchRequest()), 0)
    }

    func testFailedEmptyStartDoesNotLeaveAnOrphanLog() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        let unrelated = Workout.create(context: context)
        unrelated.title = "Pending History Edit"

        XCTAssertThrowsError(try Workout.startNew(in: context, save: { throw SaveFailure() }))

        XCTAssertEqual(try context.count(for: Workout.fetchRequest()), 1)
        XCTAssertEqual(try context.count(for: Workout.currentWorkoutFetchRequest), 0)
        XCTAssertFalse(unrelated.isDeleted)
        XCTAssertEqual(unrelated.title, "Pending History Edit")
    }

    func testFailedRoutineStartRemovesCopiedSetsAndPreservesRoutine() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        let plan = WorkoutPlan.create(context: context)
        let routine = WorkoutRoutine.create(context: context)
        routine.workoutPlan = plan
        routine.title = "Push"
        let exercise = WorkoutRoutineExercise.create(context: context)
        exercise.workoutRoutine = routine
        let set = WorkoutRoutineSet.create(context: context)
        set.workoutRoutineExercise = exercise
        set.weightValue = 50
        try context.save()

        XCTAssertThrowsError(try Workout.startNew(in: context, routine: routine, save: { throw SaveFailure() }))

        XCTAssertEqual(try context.count(for: Workout.fetchRequest()), 0)
        XCTAssertEqual(try context.count(for: WorkoutExercise.fetchRequest()), 0)
        XCTAssertEqual(try context.count(for: WorkoutSet.fetchRequest()), 0)
        XCTAssertEqual(try context.count(for: WorkoutRoutineSet.fetchRequest()), 1)
        XCTAssertEqual(routine.title, "Push")
        XCTAssertEqual(routine.workouts?.count ?? 0, 0)
    }

    func testExistingActiveWorkoutPreventsAnotherStart() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        let active = Workout.create(context: context)
        active.start = Date(timeIntervalSince1970: 1_000)
        active.isCurrentWorkout = true
        var saveCalled = false

        XCTAssertThrowsError(try Workout.startNew(in: context, save: { saveCalled = true })) { error in
            XCTAssertTrue(error is Workout.StartError)
        }
        XCTAssertFalse(saveCalled)
        XCTAssertEqual(try context.count(for: Workout.fetchRequest()), 1)
        XCTAssertEqual(active.start, Date(timeIntervalSince1970: 1_000))
    }

    func testFailedRepeatRemovesOnlyTheNewGraph() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        let original = Workout.create(context: context)
        original.title = "Finished Workout"
        original.start = Date(timeIntervalSince1970: 1_000)
        original.end = Date(timeIntervalSince1970: 2_000)
        let exercise = WorkoutExercise.create(context: context)
        exercise.workout = original
        let set = WorkoutSet.create(context: context)
        set.workoutExercise = exercise
        set.isCompleted = true
        set.repetitionsValue = 8
        try context.save()

        for blank in [false, true] {
            XCTAssertThrowsError(try Workout.startRepeating(original, blank: blank, save: { throw SaveFailure() }))
            XCTAssertEqual(try context.count(for: Workout.fetchRequest()), 1)
            XCTAssertEqual(try context.count(for: WorkoutExercise.fetchRequest()), 1)
            XCTAssertEqual(try context.count(for: WorkoutSet.fetchRequest()), 1)
            XCTAssertFalse(original.isCurrentWorkout)
            XCTAssertTrue(set.isCompleted)
            XCTAssertEqual(set.repetitionsValue, 8)
        }
    }
}

final class SupersetDuplicationTests: XCTestCase {
    private struct RoutineFixture {
        let routine: WorkoutRoutine
        let exercises: [WorkoutRoutineExercise]
        let firstGroupID: UUID
        let secondGroupID: UUID
    }

    private func makeRoutine(
        in context: NSManagedObjectContext,
        plan: WorkoutPlan? = nil,
        firstGroupID sharedFirstGroupID: UUID? = nil
    ) -> RoutineFixture {
        let routine = WorkoutRoutine.create(context: context)
        routine.title = "Grouped Routine"
        routine.workoutPlan = plan
        let firstGroupID = sharedFirstGroupID ?? UUID()
        let secondGroupID = UUID()
        let groupIDs: [UUID?] = [firstGroupID, firstGroupID, secondGroupID, secondGroupID, nil]
        let exercises = groupIDs.map { groupID -> WorkoutRoutineExercise in
            let exercise = WorkoutRoutineExercise.create(context: context)
            exercise.exerciseUuid = UUID()
            exercise.supersetUuid = groupID
            return exercise
        }
        routine.workoutRoutineExercises = NSOrderedSet(array: exercises)
        return RoutineFixture(
            routine: routine,
            exercises: exercises,
            firstGroupID: firstGroupID,
            secondGroupID: secondGroupID
        )
    }

    private func assertPreservedGroups(
        source: RoutineFixture,
        copiedRoutine: WorkoutRoutine,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let copies = try XCTUnwrap(
            copiedRoutine.workoutRoutineExercises?.array as? [WorkoutRoutineExercise],
            file: file,
            line: line
        )
        XCTAssertEqual(copies.count, source.exercises.count, file: file, line: line)
        guard copies.count == 5, source.exercises.count == 5 else {
            XCTFail("Expected five source and copied exercises", file: file, line: line)
            return
        }
        let sourceExerciseIDs = Set(source.exercises.compactMap(\.uuid))
        for (original, copy) in zip(source.exercises, copies) {
            let copiedID = try XCTUnwrap(copy.uuid, file: file, line: line)
            XCTAssertNotEqual(copiedID, original.uuid, file: file, line: line)
            XCTAssertFalse(sourceExerciseIDs.contains(copiedID), file: file, line: line)
            XCTAssertEqual(copy.exerciseUuid, original.exerciseUuid, file: file, line: line)
        }

        let copiedFirstGroupID = try XCTUnwrap(copies[0].supersetUuid, file: file, line: line)
        let copiedSecondGroupID = try XCTUnwrap(copies[2].supersetUuid, file: file, line: line)
        XCTAssertEqual(copies[1].supersetUuid, copiedFirstGroupID, file: file, line: line)
        XCTAssertEqual(copies[3].supersetUuid, copiedSecondGroupID, file: file, line: line)
        XCTAssertNotEqual(copiedFirstGroupID, copiedSecondGroupID, file: file, line: line)
        let sourceGroupIDs: Set<UUID> = [source.firstGroupID, source.secondGroupID]
        XCTAssertFalse(sourceGroupIDs.contains(copiedFirstGroupID), file: file, line: line)
        XCTAssertFalse(sourceGroupIDs.contains(copiedSecondGroupID), file: file, line: line)
        XCTAssertNil(copies[4].supersetUuid, file: file, line: line)

        XCTAssertEqual(source.exercises[0].supersetUuid, source.firstGroupID, file: file, line: line)
        XCTAssertEqual(source.exercises[1].supersetUuid, source.firstGroupID, file: file, line: line)
        XCTAssertEqual(source.exercises[2].supersetUuid, source.secondGroupID, file: file, line: line)
        XCTAssertEqual(source.exercises[3].supersetUuid, source.secondGroupID, file: file, line: line)
        XCTAssertNil(source.exercises[4].supersetUuid, file: file, line: line)
    }

    func testRoutineDuplicatePreservesSupersetMembershipWithFreshGroupIDs() throws {
        let context = setUpInMemoryNSPersistentContainer().viewContext
        let source = makeRoutine(in: context)

        let copy = source.routine.duplicate(context: context)

        try assertPreservedGroups(source: source, copiedRoutine: copy)
    }

    func testPlanDuplicatePreservesSupersetMembershipWithFreshGroupIDs() throws {
        let context = setUpInMemoryNSPersistentContainer().viewContext
        let plan = WorkoutPlan.create(context: context)
        plan.title = "Original Plan"
        let sharedSourceGroupID = UUID()
        let firstSource = makeRoutine(
            in: context,
            plan: plan,
            firstGroupID: sharedSourceGroupID
        )
        let secondSource = makeRoutine(
            in: context,
            plan: plan,
            firstGroupID: sharedSourceGroupID
        )
        plan.workoutRoutines = NSOrderedSet(array: [firstSource.routine, secondSource.routine])

        let copiedPlan = plan.duplicate(context: context)
        let copiedRoutines = try XCTUnwrap(copiedPlan.workoutRoutines?.array as? [WorkoutRoutine])
        guard copiedRoutines.count == 2 else {
            XCTFail("Expected two copied routines")
            return
        }

        XCTAssertNotEqual(copiedPlan.uuid, plan.uuid)
        XCTAssertNotEqual(copiedRoutines[0].uuid, firstSource.routine.uuid)
        XCTAssertNotEqual(copiedRoutines[1].uuid, secondSource.routine.uuid)
        try assertPreservedGroups(source: firstSource, copiedRoutine: copiedRoutines[0])
        try assertPreservedGroups(source: secondSource, copiedRoutine: copiedRoutines[1])
        XCTAssertNotEqual(
            (copiedRoutines[0].workoutRoutineExercises?.firstObject as? WorkoutRoutineExercise)?.supersetUuid,
            (copiedRoutines[1].workoutRoutineExercises?.firstObject as? WorkoutRoutineExercise)?.supersetUuid
        )
    }
}

final class SavedWorkoutImportPersistenceTests: XCTestCase {
    private struct SaveFailure: Error {}

    private let firstExerciseID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let secondExerciseID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let supersetID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private func savedWorkoutData() throws -> Data {
        let context = setUpInMemoryNSPersistentContainer().viewContext
        let routine = WorkoutRoutine.create(context: context)
        routine.title = "Imported Push"
        routine.comment = "Keep exercise order"

        let firstExercise = WorkoutRoutineExercise.create(context: context)
        firstExercise.exerciseUuid = firstExerciseID
        firstExercise.comment = "First"
        firstExercise.restTimerDurationValue = 90
        firstExercise.supersetUuid = supersetID
        let firstSet = WorkoutRoutineSet.create(context: context)
        firstSet.minRepetitionsValue = 5
        firstSet.maxRepetitionsValue = 8
        firstSet.weightValue = 100
        firstExercise.workoutRoutineSets = NSOrderedSet(array: [firstSet])

        let secondExercise = WorkoutRoutineExercise.create(context: context)
        secondExercise.exerciseUuid = secondExerciseID
        secondExercise.comment = "Second"
        secondExercise.restTimerDurationValue = 120
        secondExercise.supersetUuid = supersetID
        let secondSet = WorkoutRoutineSet.create(context: context)
        secondSet.durationValue = 45
        secondExercise.workoutRoutineSets = NSOrderedSet(array: [secondSet])
        routine.workoutRoutineExercises = NSOrderedSet(array: [firstExercise, secondExercise])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(SavedWorkoutDocument(workout: routine))
    }

    func testFailedParentSaveRemovesImportedGraphAndRetryImportsExactlyOnce() throws {
        let data = try savedWorkoutData()
        let context = setUpInMemoryNSPersistentContainer().viewContext
        let existingPlan = WorkoutPlan.create(context: context)
        existingPlan.title = "Existing"
        try context.save()
        existingPlan.title = "Unrelated pending edit"
        var saveInvoked = false

        XCTAssertThrowsError(try SavedWorkoutImporter.importData(
            data,
            into: context,
            save: {
                saveInvoked = true
                throw SaveFailure()
            }
        ))

        XCTAssertTrue(saveInvoked)
        XCTAssertEqual(try context.count(for: WorkoutPlan.fetchRequest()), 1)
        XCTAssertEqual(try context.count(for: WorkoutRoutine.fetchRequest()), 0)
        XCTAssertEqual(try context.count(for: WorkoutRoutineExercise.fetchRequest()), 0)
        XCTAssertEqual(try context.count(for: WorkoutRoutineSet.fetchRequest()), 0)
        XCTAssertEqual(existingPlan.title, "Unrelated pending edit")
        XCTAssertTrue(context.hasChanges)

        // An unrelated later save must not resurrect the failed import.
        try context.save()
        let reader = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        reader.persistentStoreCoordinator = context.persistentStoreCoordinator
        XCTAssertEqual(try reader.count(for: WorkoutPlan.fetchRequest()), 1)
        XCTAssertEqual(try reader.count(for: WorkoutRoutine.fetchRequest()), 0)
        XCTAssertEqual(try reader.count(for: WorkoutRoutineExercise.fetchRequest()), 0)
        XCTAssertEqual(try reader.count(for: WorkoutRoutineSet.fetchRequest()), 0)

        let importedTitle = try SavedWorkoutImporter.importData(data, into: context)

        XCTAssertEqual(importedTitle, "Imported Push")
        XCTAssertEqual(try context.count(for: WorkoutPlan.fetchRequest()), 2)
        XCTAssertEqual(try context.count(for: WorkoutRoutine.fetchRequest()), 1)
        XCTAssertEqual(try context.count(for: WorkoutRoutineExercise.fetchRequest()), 2)
        XCTAssertEqual(try context.count(for: WorkoutRoutineSet.fetchRequest()), 2)
        let routine = try XCTUnwrap(context.fetch(WorkoutRoutine.fetchRequest()).first)
        let exercises = try XCTUnwrap(routine.workoutRoutineExercises?.array as? [WorkoutRoutineExercise])
        guard exercises.count == 2 else {
            return XCTFail("Expected both imported exercises")
        }
        XCTAssertEqual(exercises.map(\.exerciseUuid), [firstExerciseID, secondExerciseID])
        XCTAssertNotNil(exercises[0].supersetUuid)
        XCTAssertNotEqual(exercises[0].supersetUuid, supersetID)
        XCTAssertEqual(exercises[0].supersetUuid, exercises[1].supersetUuid)
        XCTAssertEqual(exercises.map(\.restTimerDurationValue), [90, 120])
        XCTAssertEqual((exercises[0].workoutRoutineSets?.firstObject as? WorkoutRoutineSet)?.weightValue, 100)
        XCTAssertEqual((exercises[1].workoutRoutineSets?.firstObject as? WorkoutRoutineSet)?.durationValue, 45)
        XCTAssertEqual(existingPlan.title, "Unrelated pending edit")
    }

    func testMalformedAndUnsupportedDocumentsDoNotMutateParent() throws {
        let context = setUpInMemoryNSPersistentContainer().viewContext
        var saveInvoked = false

        XCTAssertThrowsError(try SavedWorkoutImporter.importData(
            Data("not-json".utf8),
            into: context,
            save: { saveInvoked = true }
        ))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: savedWorkoutData()) as? [String: Any]
        )
        object["version"] = SavedWorkoutDocument.currentVersion + 1
        let unsupportedData = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try SavedWorkoutImporter.importData(
            unsupportedData,
            into: context,
            save: { saveInvoked = true }
        )) { error in
            guard let importError = error as? SavedWorkoutImportError,
                  case .unsupportedVersion = importError else {
                XCTFail("Expected unsupported-version error, got \(error)")
                return
            }
        }

        XCTAssertFalse(saveInvoked)
        XCTAssertEqual(try context.count(for: WorkoutPlan.fetchRequest()), 0)
        XCTAssertEqual(try context.count(for: WorkoutRoutine.fetchRequest()), 0)
        XCTAssertEqual(try context.count(for: WorkoutRoutineExercise.fetchRequest()), 0)
        XCTAssertEqual(try context.count(for: WorkoutRoutineSet.fetchRequest()), 0)
        XCTAssertFalse(context.hasChanges)
    }
}

/// Data-safety gates intentionally exercise no HealthKit APIs.
final class ImportedWorkoutHealthSafetyTests: XCTestCase {
    func testExportGateRejectsAllImportedSources() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let workout = Workout.create(context: container.viewContext)
        workout.start = Date(timeIntervalSince1970: 1_000)
        workout.end = Date(timeIntervalSince1970: 2_000)
        XCTAssertFalse(workout.isImported)
        XCTAssertEqual(workout.healthExportEligibility, .eligible)
        XCTAssertNil(HealthManager.workoutExportError(workout.healthExportEligibility))
        for source in ["hevy", "sample", "json", "future-importer", ""] {
            workout.importSource = source
            XCTAssertTrue(workout.isImported)
            XCTAssertEqual(HealthManager.workoutExportError(workout.healthExportEligibility), .importedWorkout)
        }
        XCTAssertEqual(HealthManager.WorkoutSyncError.importedWorkout.errorDescription,
                       "Imported workouts are never sent to Apple Health.")
    }

    func testSingleSyncRejectsAnImportBeforeAuthorizationAndDataValidation() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let workout = Workout.create(context: container.viewContext)
        workout.importSource = "hevy"
        // Even an unsaved import with no interval must hit the import guard first.
        let rejected = expectation(description: "Import rejected before HealthKit")
        HealthManager.shared.syncWorkoutIfNeeded(workout: workout, exerciseStore: .shared) { result in
            if case .failure(let error) = result {
                XCTAssertEqual(error as? HealthManager.WorkoutSyncError, .importedWorkout)
            } else {
                XCTFail("An imported workout must never sync")
            }
            rejected.fulfill()
        }
        wait(for: [rejected], timeout: 2)
    }

    func testWatchOrOtherSourceSamplePreventsPhoneSaveReplacementAndCleanup() {
        let isPhoneOwned: (String) -> Bool = { $0 == "phone" }
        XCTAssertTrue(HealthManager.canReconcileWorkoutSamples([String](), isPhoneOwned: isPhoneOwned))
        XCTAssertTrue(HealthManager.canReconcileWorkoutSamples(["phone", "phone"], isPhoneOwned: isPhoneOwned))
        XCTAssertFalse(HealthManager.canReconcileWorkoutSamples(["watch"], isPhoneOwned: isPhoneOwned))
        XCTAssertFalse(HealthManager.canReconcileWorkoutSamples(["phone", "watch"], isPhoneOwned: isPhoneOwned))
        XCTAssertFalse(HealthManager.canReconcileWorkoutSamples(["hevy"], isPhoneOwned: isPhoneOwned))
    }

    func testRepeatingImportedWorkoutsCreatesNativeSessions() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        let source = Workout.create(context: context)
        source.importSource = "hevy"
        source.start = Date(timeIntervalSince1970: 1_000)
        source.end = Date(timeIntervalSince1970: 2_000)
        let exercise = WorkoutExercise.create(context: context)
        source.addToWorkoutExercises(exercise)
        let set = WorkoutSet.create(context: context)
        exercise.addToWorkoutSets(set)
        set.isCompleted = true
        set.repetitionsValue = 8
        try context.save()

        for blank in [false, true] {
            let copy = try XCTUnwrap(source.copyForRepeat(blank: blank))
            XCTAssertNil(copy.importSource)
            XCTAssertNil(copy.healthExportState)
            XCTAssertFalse(copy.isImported)
            XCTAssertNotEqual(copy.uuid, source.uuid)
            XCTAssertEqual(copy.workoutExercises?.count, 1)
            let copiedExercise = try XCTUnwrap(copy.workoutExercises?.firstObject as? WorkoutExercise)
            let copiedSet = try XCTUnwrap(copiedExercise.workoutSets?.firstObject as? WorkoutSet)
            XCTAssertFalse(copiedSet.isCompleted)
            XCTAssertEqual(source.importSource, "hevy")
        }
    }

    func testWorkoutExportPreferenceDefaultsOnAndHonorsStoredPreference() throws {
        let suite = "IronP11ExportPreference.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(defaults.object(forKey: "Iron.finishWorkout.syncWithHealth"))
        XCTAssertTrue(defaults.syncFinishedWorkoutsWithHealth)
        defaults.syncFinishedWorkoutsWithHealth = true
        XCTAssertTrue(defaults.syncFinishedWorkoutsWithHealth)
        defaults.syncFinishedWorkoutsWithHealth = false
        XCTAssertFalse(defaults.syncFinishedWorkoutsWithHealth)
    }
}

/// Exercises the real coordinator/persistence path with a value-only Health writer.
final class DurableWorkoutHealthExportTests: XCTestCase {
    private enum Failure: Error { case write, save }
    private var container: NSPersistentContainer!
    private var previousWatchID: UUID?
    private var previousHealthTestMode: Any?

    override func setUp() {
        container = setUpInMemoryNSPersistentContainer()
        previousHealthTestMode = UserDefaults.appGroup.object(forKey: UserDefaults.SettingsKeys.healthTestMode.rawValue)
        SettingsStore.shared.healthTestMode = false
        previousWatchID = WatchConnectionManager.shared.currentWatchWorkoutUuid
        WatchConnectionManager.shared.currentWatchWorkoutUuid = nil
    }

    override func tearDown() {
        UserDefaults.appGroup.set(previousHealthTestMode, forKey: UserDefaults.SettingsKeys.healthTestMode.rawValue)
        WatchConnectionManager.shared.currentWatchWorkoutUuid = previousWatchID
        container.viewContext.reset()
        container = nil
    }

    private func workout(source: String? = nil, state: String? = nil, current: Bool = false) -> Workout {
        let workout = Workout.create(context: container.viewContext)
        workout.start = Date(timeIntervalSince1970: 1_000)
        workout.end = current ? nil : Date(timeIntervalSince1970: 2_000)
        workout.isCurrentWorkout = current
        workout.importSource = source
        workout.healthExportState = state
        return workout
    }

    private func storedState(_ workout: Workout) throws -> String? {
        let context = container.newBackgroundContext()
        let id = workout.objectID
        return try context.performAndWait {
            try (context.existingObject(with: id) as? Workout)?.healthExportState
        }
    }

    func testEligibilityRejectsCurrentMissingZeroNegativeAndNonfiniteIntervals() {
        let native = workout()
        XCTAssertEqual(native.healthExportEligibility, .eligible)
        native.isCurrentWorkout = true
        XCTAssertEqual(native.healthExportEligibility, .invalidWorkout)
        native.isCurrentWorkout = false
        native.end = nil
        XCTAssertEqual(native.healthExportEligibility, .invalidWorkout)
        native.end = native.start
        XCTAssertEqual(native.healthExportEligibility, .invalidWorkout)
        native.end = Date(timeIntervalSince1970: 999)
        XCTAssertEqual(native.healthExportEligibility, .invalidWorkout)
        let valid = Date(timeIntervalSince1970: 1_000)
        for duration in [Double.nan, .infinity, -.infinity, -1, 0] {
            XCTAssertEqual(Workout.healthExportEligibility(importSource: nil, isCurrent: false,
                start: valid, end: valid.addingTimeInterval(10), duration: duration), .invalidWorkout)
        }
        XCTAssertEqual(Workout.healthExportEligibility(importSource: nil, isCurrent: false,
            start: nil, end: valid, duration: 10), .invalidWorkout)
        XCTAssertEqual(Workout.healthExportEligibility(importSource: nil, isCurrent: false,
            start: Date(timeIntervalSinceReferenceDate: .infinity), end: valid, duration: 10), .invalidWorkout)
    }

    func testFinishPersistsPendingWithCompletionBeforeWriterAndScopesSuccessSave() throws {
        let workout = workout(current: true)
        try container.viewContext.save()
        let wrote = expectation(description: "Writer received durable completion")
        var finishSaved = false
        var writerCompletion: ((Result<HealthManager.WorkoutSyncOutcome, Error>) -> Void)?
        let manager = HealthManager(workoutWriter: { request, completion in
            XCTAssertTrue(finishSaved)
            XCTAssertEqual(request.uuid, workout.uuid)
            XCTAssertEqual(try? self.storedState(workout), "pending")
            writerCompletion = completion
            wrote.fulfill()
        })
        try workout.finish(syncToHealth: true, save: {
            XCTAssertEqual(workout.healthExportState, "pending")
            XCTAssertFalse(workout.isCurrentWorkout)
            XCTAssertNil(writerCompletion)
            try self.container.viewContext.save()
            finishSaved = true
        }, healthManager: manager) {
            workout.end = Date(timeIntervalSince1970: 2_000)
        }
        wait(for: [wrote], timeout: 2)
        let unrelated = self.workout()
        unrelated.title = "Unsaved editor change"
        let saved = expectation(for: NSPredicate(format: "healthExportState == %@", "exported"), evaluatedWith: workout)
        writerCompletion?(.success(.saved))
        wait(for: [saved], timeout: 2)
        XCTAssertEqual(try storedState(workout), "exported")
        XCTAssertTrue(unrelated.isInserted)
        XCTAssertTrue(container.viewContext.hasChanges)
        let fresh = container.newBackgroundContext()
        try fresh.performAndWait {
            XCTAssertEqual(try fresh.count(for: Workout.fetchRequest()), 1)
        }
    }

    func testFailedFinishRollsBackPendingAndNeverCallsWriter() throws {
        let workout = workout(current: true)
        try container.viewContext.save()
        var writes = 0
        let manager = HealthManager(workoutWriter: { _, _ in writes += 1 })
        XCTAssertThrowsError(try workout.finish(syncToHealth: true, save: {
            XCTAssertEqual(workout.healthExportState, "pending")
            throw Failure.save
        }, healthManager: manager))
        XCTAssertTrue(workout.isCurrentWorkout)
        XCTAssertNil(workout.end)
        XCTAssertNil(workout.healthExportState)
        XCTAssertNil(try storedState(workout))
        XCTAssertEqual(writes, 0)
    }

    func testSyncOffLeavesNoPendingExport() throws {
        let workout = workout(current: true)
        try container.viewContext.save()
        var writes = 0
        let manager = HealthManager(workoutWriter: { _, _ in writes += 1 })
        try workout.finish(syncToHealth: false, healthManager: manager)
        XCTAssertNil(workout.healthExportState)
        XCTAssertNil(try storedState(workout))
        XCTAssertEqual(writes, 0)
    }

    func testFinishingSampleOrImportedDataNeverRequestsHealthExport() throws {
        var writes = 0
        let manager = HealthManager(workoutWriter: { _, _ in writes += 1 })
        for source in ["hevy", "sample", "json"] {
            let workout = workout(source: source, current: true)
            try container.viewContext.save()
            try workout.finish(syncToHealth: true, healthManager: manager)
            XCTAssertNil(try storedState(workout))
        }
        XCTAssertEqual(writes, 0)
    }

    func testWriteFailureLeavesPendingAndRetryEventuallyExports() throws {
        let workout = workout()
        try container.viewContext.save()
        var writes = 0
        let manager = HealthManager(workoutWriter: { _, completion in
            writes += 1
            completion(writes == 1 ? .failure(Failure.write) : .success(.alreadyPresent))
        })
        let failed = expectation(description: "Write failed")
        manager.syncWorkoutIfNeeded(workout: workout, exerciseStore: .shared) { result in
            if case .success = result { XCTFail("Expected write failure") }
            failed.fulfill()
        }
        wait(for: [failed], timeout: 2)
        XCTAssertEqual(try storedState(workout), "pending")
        let retried = expectation(description: "Retried")
        manager.retryPendingWorkouts(in: container.viewContext) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            retried.fulfill()
        }
        wait(for: [retried], timeout: 2)
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(try storedState(workout), "exported")
    }

    func testRetrySerializesEligiblePendingAndSkipsEverythingElse() throws {
        let first = workout(state: "pending")
        let second = workout(state: "pending")
        let imports = ["hevy", "sample", "json", ""].map { workout(source: $0, state: "pending") }
        let current = workout(state: "pending", current: true)
        let invalid = workout(state: "pending")
        invalid.end = invalid.start
        let legacy = workout()
        let watch = workout(state: "watch")
        try container.viewContext.save()
        var requested: [UUID] = []
        var inFlight = 0
        let manager = HealthManager(workoutWriter: { request, completion in
            requested.append(request.uuid)
            inFlight += 1
            XCTAssertEqual(inFlight, 1)
            DispatchQueue.main.async {
                inFlight -= 1
                completion(.success(.saved))
            }
        })
        let retried = expectation(description: "Pending pass")
        manager.retryPendingWorkouts(in: container.viewContext) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            retried.fulfill()
        }
        wait(for: [retried], timeout: 2)
        XCTAssertEqual(Set(requested), Set([first.uuid!, second.uuid!]))
        XCTAssertEqual(try storedState(first), "exported")
        XCTAssertEqual(try storedState(second), "exported")
        for excluded in imports + [current, invalid] { XCTAssertEqual(try storedState(excluded), "pending") }
        XCTAssertNil(try storedState(legacy))
        XCTAssertEqual(try storedState(watch), "watch")
        let again = expectation(description: "Idempotent pass")
        manager.retryPendingWorkouts(in: container.viewContext) { _ in again.fulfill() }
        wait(for: [again], timeout: 2)
        XCTAssertEqual(requested.count, 2)
    }

    func testRetryTriggerDuringFailedPassIsRetained() throws {
        let workout = workout(state: "pending")
        try container.viewContext.save()
        let firstWrite = expectation(description: "First pass in progress")
        var writes = 0
        var firstCompletion: ((Result<HealthManager.WorkoutSyncOutcome, Error>) -> Void)?
        let manager = HealthManager(workoutWriter: { _, completion in
            writes += 1
            if writes == 1 {
                firstCompletion = completion
                firstWrite.fulfill()
            } else {
                completion(.success(.saved))
            }
        })
        manager.retryPendingWorkouts(in: container.viewContext)
        wait(for: [firstWrite], timeout: 2)
        // An unlock/authorization notification during a failing write must
        // schedule another serialized pass rather than being dropped.
        manager.retryPendingWorkouts(in: container.viewContext)
        firstCompletion?(.failure(Failure.write))
        let saved = expectation(for: NSPredicate(format: "healthExportState == %@", "exported"), evaluatedWith: workout)
        wait(for: [saved], timeout: 2)
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(try storedState(workout), "exported")
    }

    func testManualAndBulkSyncUseTheSameAllowlistAndSkipWatch() throws {
        let native = workout()
        let imports = ["hevy", "sample", "json"].map { workout(source: $0) }
        let invalid = workout(current: true)
        let watch = workout(state: "watch")
        let test = workout(state: "test")
        try container.viewContext.save()
        var requested: [UUID] = []
        let manager = HealthManager(workoutWriter: { request, completion in
            requested.append(request.uuid)
            completion(.success(.saved))
        })
        for excluded in imports + [invalid, watch, test] {
            let checked = expectation(description: "Manual guard")
            manager.syncWorkoutIfNeeded(workout: excluded, exerciseStore: .shared) { _ in checked.fulfill() }
            wait(for: [checked], timeout: 2)
        }
        XCTAssertTrue(requested.isEmpty)
        let bulk = expectation(description: "Bulk allowlist")
        manager.updateHealthWorkouts(managedObjectContext: container.viewContext, exerciseStore: .shared) { result in
            if case .success(let counts) = result { XCTAssertEqual(counts.deleted, 0) }
            else { XCTFail("Bulk failed") }
            bulk.fulfill()
        }
        wait(for: [bulk], timeout: 2)
        XCTAssertEqual(requested, [native.uuid!])
    }

    #if DEBUG
    func testBothPhoneStartTransactionsPersistTestProvenanceBeforeSideEffects() throws {
        SettingsStore.shared.healthTestMode = true
        let context = container.viewContext
        // Inspect the save boundary and then fail it to avoid launching any
        // companion, notification, or Live Activity from this unit test.
        XCTAssertThrowsError(try Workout.startNew(in: context, save: {
            let active = try XCTUnwrap(context.fetch(Workout.currentWorkoutFetchRequest).first)
            XCTAssertEqual(active.healthExportState, "test")
            throw Failure.save
        }))
        XCTAssertEqual(try context.count(for: Workout.fetchRequest()), 0)

        let existing = workout()
        try context.save()
        XCTAssertThrowsError(try existing.start(save: {
            XCTAssertEqual(existing.healthExportState, "test")
            throw Failure.save
        }))
        XCTAssertNil(existing.healthExportState, "A failed start must roll back provenance too")
        XCTAssertNil(try storedState(existing))
    }

    func testEnablingTestModePersistsActiveProvenanceBeforeSwitchingOffAndFinishing() throws {
        let active = workout(current: true)
        let imported = workout(source: "hevy")
        let history = workout()
        try container.viewContext.save()
        SettingsStore.shared.healthTestMode = true
        try Workout.markCurrentWorkoutAsHealthTestWorkout(in: container.viewContext)
        SettingsStore.shared.healthTestMode = false

        XCTAssertEqual(try storedState(active), "test")
        XCTAssertNil(try storedState(imported))
        XCTAssertNil(try storedState(history))
        var writes = 0
        let manager = HealthManager(workoutWriter: { _, _ in writes += 1 })
        try active.finish(syncToHealth: true, healthManager: manager) {
            active.end = Date(timeIntervalSince1970: 2_000)
        }
        XCTAssertEqual(try storedState(active), "test")
        XCTAssertEqual(writes, 0)

        imported.isCurrentWorkout = true
        imported.end = nil
        try container.viewContext.save()
        SettingsStore.shared.healthTestMode = true
        try Workout.markCurrentWorkoutAsHealthTestWorkout(in: container.viewContext)
        XCTAssertNil(try storedState(imported), "Imported records never acquire native test provenance")
    }

    func testTestModeFinishRemainsExcludedAfterTurningOffAndBackfilling() throws {
        let workout = workout(current: true)
        try container.viewContext.save()
        var writes = 0
        let manager = HealthManager(workoutWriter: { _, completion in
            writes += 1
            completion(.success(.saved))
        })
        SettingsStore.shared.healthTestMode = true
        try workout.finish(syncToHealth: true, healthManager: manager) {
            workout.end = Date(timeIntervalSince1970: 2_000)
        }
        XCTAssertEqual(try storedState(workout), "test")
        XCTAssertEqual(writes, 0)
        SettingsStore.shared.healthTestMode = false
        let manual = expectation(description: "Test workout manual sync skipped")
        manager.syncWorkoutIfNeeded(workout: workout, exerciseStore: .shared) { _ in manual.fulfill() }
        let bulk = expectation(description: "Test workout backfill skipped")
        manager.updateHealthWorkouts(managedObjectContext: container.viewContext, exerciseStore: .shared) { _ in bulk.fulfill() }
        let retry = expectation(description: "Test workout retry skipped")
        manager.retryPendingWorkouts(in: container.viewContext) { _ in retry.fulfill() }
        wait(for: [manual, bulk, retry], timeout: 2)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(try storedState(workout), "test")
    }
    #endif

    func testOfflineWatchTestFinishAndFailureNeverBecomePending() throws {
        let workout = workout(current: true)
        try container.viewContext.save()
        var writes = 0
        let manager = HealthManager(workoutWriter: { _, completion in
            writes += 1
            completion(.success(.saved))
        })
        var snapshot = WatchWorkoutSnapshot(workoutID: workout.uuid!, startDate: workout.start!,
            endDate: Date(timeIntervalSince1970: 2_000), isFinished: true)
        snapshot.healthTestMode = true
        for (index, kind) in [WatchWorkoutEventKind.workoutFinished, .workoutFailed].enumerated() {
            let event = WatchWorkoutEvent(workoutID: workout.uuid!, sequence: Int64(index + 1),
                kind: kind, endDate: snapshot.endDate, snapshot: snapshot,
                fieldChanges: WatchWorkoutFieldChanges())
            try WatchConnectionManager.commitWatchEventMutation(in: container.viewContext,
                save: { try self.container.viewContext.save() }, mutation: {
                    try WatchConnectionManager.shared.applyWatchEventModelMutation(event, to: workout,
                        in: self.container.viewContext, healthManager: manager)
                }, didPersist: {})
            XCTAssertEqual(try storedState(workout), "test")
        }
        let bulk = expectation(description: "Offline test workout backfill skipped")
        manager.updateHealthWorkouts(managedObjectContext: container.viewContext, exerciseStore: .shared) { _ in bulk.fulfill() }
        wait(for: [bulk], timeout: 2)
        XCTAssertEqual(writes, 0)
    }

    func testWatchFinishSavesWatchStateAndNeverSchedulesPhoneWriter() throws {
        let workout = workout(current: true)
        try container.viewContext.save()
        var writes = 0
        let manager = HealthManager(workoutWriter: { _, _ in writes += 1 })
        let event = WatchWorkoutEvent(workoutID: workout.uuid!, sequence: 1, kind: .workoutFinished,
            startDate: workout.start, endDate: Date(timeIntervalSince1970: 2_000))
        try WatchConnectionManager.commitWatchEventMutation(in: container.viewContext,
            save: {
                XCTAssertEqual(workout.healthExportState, "watch")
                XCTAssertEqual(writes, 0)
                try self.container.viewContext.save()
            }, mutation: {
                try WatchConnectionManager.shared.applyWatchEventModelMutation(event, to: workout,
                    in: self.container.viewContext, healthManager: manager)
            }, didPersist: {})
        XCTAssertEqual(try storedState(workout), "watch")
        let retry = expectation(description: "No Watch retry")
        manager.retryPendingWorkouts(in: container.viewContext) { _ in retry.fulfill() }
        wait(for: [retry], timeout: 2)
        XCTAssertEqual(writes, 0)
    }

    func testWatchHealthFailureCanArriveBeforeFinishAndExportsAfterSave() throws {
        let workout = workout(current: true)
        try container.viewContext.save()
        let exported = expectation(description: "Watch failure fallback")
        let manager = HealthManager(workoutWriter: { _, completion in
            XCTAssertFalse(workout.isCurrentWorkout)
            XCTAssertEqual(try? self.storedState(workout), "pending")
            completion(.success(.saved))
            exported.fulfill()
        })
        let event = WatchWorkoutEvent(workoutID: workout.uuid!, sequence: 2, kind: .workoutFailed,
            startDate: workout.start, endDate: Date(timeIntervalSince1970: 2_000), title: "Health save failed")
        try WatchConnectionManager.commitWatchEventMutation(in: container.viewContext,
            save: { try self.container.viewContext.save() }, mutation: {
                try WatchConnectionManager.shared.applyWatchEventModelMutation(event, to: workout,
                    in: self.container.viewContext, healthManager: manager)
            }, didPersist: {})
        wait(for: [exported], timeout: 2)
        XCTAssertNotEqual(workout.title, "Health save failed")
        let done = expectation(for: NSPredicate(format: "healthExportState == %@", "exported"), evaluatedWith: workout)
        wait(for: [done], timeout: 2)
    }

    func testFailedWatchFallbackSaveRollsBackAndNeverSchedulesPhoneWriter() throws {
        let workout = workout(state: "watch")
        try container.viewContext.save()
        var writes = 0
        let manager = HealthManager(workoutWriter: { _, _ in writes += 1 })
        let event = WatchWorkoutEvent(workoutID: workout.uuid!, sequence: 2, kind: .workoutFailed,
            startDate: workout.start, endDate: workout.end)
        XCTAssertThrowsError(try WatchConnectionManager.commitWatchEventMutation(in: container.viewContext,
            save: {
                XCTAssertEqual(workout.healthExportState, "pending")
                throw Failure.save
            }, mutation: {
                try WatchConnectionManager.shared.applyWatchEventModelMutation(event, to: workout,
                    in: self.container.viewContext, healthManager: manager)
            }, didPersist: {}))
        XCTAssertEqual(try storedState(workout), "watch")
        XCTAssertEqual(workout.healthExportState, "watch")
        XCTAssertEqual(writes, 0)
    }
}

final class ExerciseRecencyTests: XCTestCase {
    private func exercise(_ title: String, alias: [String] = []) -> Exercise {
        Exercise(uuid: UUID(), everkineticId: Exercise.customEverkineticId,
                 title: title, alias: alias, description: nil, primaryMuscle: [],
                 secondaryMuscle: [], equipment: [], steps: [], tips: [], references: [], pdfPaths: [])
    }

    @discardableResult
    private func workout(in context: NSManagedObjectContext, exercises: [Exercise],
                         at date: Date, imported: Bool = false, current: Bool = false,
                         completed: Bool = true) -> Workout {
        let workout = Workout.create(context: context)
        workout.start = date
        workout.end = date.addingTimeInterval(3600)
        workout.isCurrentWorkout = current
        workout.importSource = imported ? "hevy" : nil
        for exercise in exercises {
            let entry = WorkoutExercise.create(context: context)
            entry.exerciseUuid = exercise.uuid
            entry.workout = workout
            if completed {
                let set = WorkoutSet.create(context: context)
                set.isCompleted = true
                set.workoutExercise = entry
            }
        }
        return workout
    }

    func testHistoryIncludesImportsAndAllEntriesInQualifyingWorkouts() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        let exercises = (0..<12).map { exercise("Exercise \($0)") }
        let older = Date(timeIntervalSince1970: 1000)
        let newer = Date(timeIntervalSince1970: 2000)
        workout(in: context, exercises: Array(exercises.prefix(9)), at: older, imported: true)
        let latest = workout(in: context, exercises: [exercises[0]], at: newer)
        let noSets = WorkoutExercise.create(context: context)
        noSets.exerciseUuid = exercises[9].uuid
        noSets.workout = latest
        workout(in: context, exercises: [exercises[10]], at: newer, completed: false)
        workout(in: context, exercises: [exercises[11]], at: newer, current: true)
        try context.save()

        let dates = try ExerciseRecency.latestDates(in: context)
        XCTAssertEqual(dates.count, 10, "Recents must not be capped at seven")
        XCTAssertEqual(dates[exercises[0].uuid], newer)
        XCTAssertEqual(dates[exercises[1].uuid], older)
        XCTAssertEqual(dates[exercises[9].uuid], newer, "Qualification is at the workout level")
        XCTAssertNil(dates[exercises[10].uuid])
        XCTAssertNil(dates[exercises[11].uuid])
    }

    func testWorkoutReferencesIncludeUnloggedAndSavedWorkoutExercises() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        let logged = exercise("Logged")
        let unlogged = exercise("Unlogged")
        let saved = exercise("Saved")
        let unused = exercise("Unused")
        workout(in: context, exercises: [logged], at: Date(timeIntervalSince1970: 1000))
        workout(in: context, exercises: [unlogged], at: Date(timeIntervalSince1970: 2000), current: true, completed: false)
        let routine = WorkoutRoutine.create(context: context)
        routine.workoutPlan = WorkoutPlan.create(context: context)
        let entry = WorkoutRoutineExercise.create(context: context)
        entry.exerciseUuid = saved.uuid
        entry.workoutRoutine = routine
        try context.save()

        let referenced = try ExerciseRecency.workoutReferencedIDs(in: context)
        XCTAssertEqual(referenced, [logged.uuid, unlogged.uuid, saved.uuid])
        XCTAssertFalse(referenced.contains(unused.uuid))
    }

    @MainActor
    func testCleanedUpExerciseStaysListedOnceAnyWorkoutUsesIt() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        let store = ExerciseStore(customExercisesURL: nil)
        let hidden = try XCTUnwrap(store.builtInExercises.first { $0.title == "Front Raises: Barbell" })
        let noPicture = try XCTUnwrap(store.builtInExercises.first { $0.title == "1 2 Stick Drill" })
        XCTAssertFalse(store.isBrowsable(hidden))
        XCTAssertFalse(store.isBrowsable(noPicture))

        workout(in: context, exercises: [hidden], at: Date(timeIntervalSince1970: 1000))
        let routine = WorkoutRoutine.create(context: context)
        routine.workoutPlan = WorkoutPlan.create(context: context)
        let entry = WorkoutRoutineExercise.create(context: context)
        entry.exerciseUuid = noPicture.uuid
        entry.workoutRoutine = routine
        try context.save()

        let updated = expectation(description: "Referenced exercises refreshed")
        let subscription = store.$workoutReferencedExerciseIDs
            .first { $0.contains(hidden.uuid) && $0.contains(noPicture.uuid) }
            .sink { _ in updated.fulfill() }
        store.observeWorkoutHistory(in: context)
        wait(for: [updated], timeout: 3)
        withExtendedLifetime(subscription) {}

        XCTAssertTrue(store.isBrowsable(hidden))
        XCTAssertTrue(store.isBrowsable(noPicture))
    }

    func testSearchAndBrowseShareRecencyWithTitleTiesAndStableUnseenOrder() {
        let barbell = exercise("Barbell Bench Press")
        let dumbbell = exercise("Dumbbell Bench Press")
        let alias = exercise("Chest Press", alias: ["bench"])
        let unseenZ = exercise("Z Bench Press")
        let unseenA = exercise("A Bench Press")
        let unrelated = exercise("Squat")
        let today = Date(timeIntervalSince1970: 1_000_000)
        let dates = [barbell.uuid: today, dumbbell.uuid: today.addingTimeInterval(-7 * 86400), alias.uuid: today]
        let input = [unseenZ, dumbbell, unrelated, unseenA, alias, barbell]
        XCTAssertEqual(ExerciseRecency.ordered(input, dates: dates),
                       [barbell, alias, dumbbell, unseenZ, unrelated, unseenA])
        let matches = ExerciseStore.filter(exercises: input, using: "bench")
        XCTAssertEqual(ExerciseRecency.ordered(matches, dates: dates),
                       [barbell, alias, dumbbell, unseenZ, unseenA])
    }

    @MainActor
    func testCacheRefreshesOnCompletionEditingAndDeletionWithoutAnotherSearch() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        let exercise = exercise("Bench Press")
        let older = Date(timeIntervalSince1970: 1000)
        let newer = Date(timeIntervalSince1970: 2000)
        let imported = workout(in: context, exercises: [exercise], at: older, imported: true)
        let active = workout(in: context, exercises: [exercise], at: newer, current: true)
        try context.save()
        let store = ExerciseStore(customExercisesURL: nil)

        func expectSnapshot(_ expected: [UUID: Date], mutation: () throws -> Void) throws {
            let updated = expectation(description: "Recency snapshot")
            let subscription = store.$lastPerformedDates
                .first { $0 == expected }
                .sink { _ in
                    XCTAssertTrue(Thread.isMainThread)
                    updated.fulfill()
                }
            try mutation()
            wait(for: [updated], timeout: 3)
            withExtendedLifetime(subscription) {}
        }

        try expectSnapshot([exercise.uuid: older]) { store.observeWorkoutHistory(in: context) }
        try expectSnapshot([exercise.uuid: newer]) {
            active.isCurrentWorkout = false
            try context.save()
        }
        let revised = newer.addingTimeInterval(100)
        try expectSnapshot([exercise.uuid: revised]) {
            active.start = revised
            try context.save()
        }
        try expectSnapshot([exercise.uuid: older]) {
            context.delete(active)
            try context.save()
        }
        try expectSnapshot([:]) {
            context.delete(imported)
            try context.save()
        }
    }
}

@available(iOS 17.0, *)
final class WorkoutLiveActivityTimingRegressionTests: XCTestCase {
    private let completedSet = WorkoutActivityAttributes.SetSnapshot(
        setID: "completed-set",
        exerciseName: "Deadlift (Barbell)",
        setNumber: 1,
        setCount: 2,
        result: "135 lb × 5 reps"
    )
    private let nextSet = WorkoutActivityAttributes.SetSnapshot(
        setID: "next-set",
        exerciseName: "Deadlift (Barbell)",
        setNumber: 2,
        setCount: 2,
        result: "135 lb × 5 reps"
    )

    private let now = Date(timeIntervalSinceReferenceDate: 50_000)

    private func state(
        confirmationUntil: Date? = nil,
        restTimerStart: Date? = nil,
        restTimerEnd: Date? = nil,
        pausedRestRemaining: TimeInterval? = nil,
        hasNextSet: Bool = true
    ) -> WorkoutActivityAttributes.ContentState {
        WorkoutActivityAttributes.ContentState(
            phase: .setCompleted,
            displaySet: completedSet,
            nextSet: hasNextSet ? nextSet : nil,
            confirmationUntil: confirmationUntil,
            restTimerStart: restTimerStart,
            restTimerEnd: restTimerEnd,
            completedSets: hasNextSet ? 1 : 2,
            totalSets: 2,
            pausedRestRemaining: pausedRestRemaining
        )
    }

    func testRunningRestImmediatelyWinsOverCompletionConfirmation() {
        let state = state(
            confirmationUntil: now.addingTimeInterval(10),
            restTimerStart: now,
            restTimerEnd: now.addingTimeInterval(60)
        )

        XCTAssertEqual(state.resolvedPhase(at: now.addingTimeInterval(1)), .resting)
        XCTAssertEqual(state.visibleSet(at: now.addingTimeInterval(1)), nextSet)
    }

    func testPausedRestImmediatelyWinsOverCompletionConfirmation() {
        let state = state(
            confirmationUntil: now.addingTimeInterval(10),
            pausedRestRemaining: 45
        )

        XCTAssertEqual(state.resolvedPhase(at: now.addingTimeInterval(1)), .resting)
        XCTAssertEqual(state.visibleSet(at: now.addingTimeInterval(1)), nextSet)
    }

    func testNoRestKeepsCompletionConfirmationUntilItsDeadline() {
        let state = state(confirmationUntil: now.addingTimeInterval(10))

        XCTAssertEqual(state.resolvedPhase(at: now.addingTimeInterval(9)), .setCompleted)
        XCTAssertEqual(state.resolvedPhase(at: now.addingTimeInterval(10)), .currentSet)
    }

    func testExpiredRestDoesNotSuppressCompletionConfirmationOrReopenRest() {
        let state = state(
            confirmationUntil: now.addingTimeInterval(10),
            restTimerStart: now.addingTimeInterval(-60),
            restTimerEnd: now.addingTimeInterval(-1)
        )

        XCTAssertEqual(state.resolvedPhase(at: now), .setCompleted)
        XCTAssertEqual(state.resolvedPhase(at: now.addingTimeInterval(10)), .currentSet)
    }

    func testFinalSetKeepsConfirmationAndThenFinishesWithoutRest() {
        let state = state(
            confirmationUntil: now.addingTimeInterval(10),
            restTimerStart: now,
            restTimerEnd: now.addingTimeInterval(60),
            hasNextSet: false
        )

        XCTAssertEqual(state.resolvedPhase(at: now.addingTimeInterval(1)), .setCompleted)
        XCTAssertEqual(state.resolvedPhase(at: now.addingTimeInterval(10)), .finished)
    }

    private var persistentContainer: NSPersistentContainer!
    private var workout: Workout!
    private var exercise: WorkoutExercise!
    private var completed: WorkoutSet!
    private var next: WorkoutSet!

    override func setUp() {
        super.setUp()
        persistentContainer = setUpInMemoryNSPersistentContainer()
        let context = persistentContainer.viewContext
        workout = Workout.create(context: context)
        workout.isCurrentWorkout = true
        exercise = WorkoutExercise.create(context: context)
        exercise.workout = workout
        completed = WorkoutSet.create(context: context)
        completed.isCompleted = true
        completed.workoutExercise = exercise
        next = WorkoutSet.create(context: context)
        next.isCompleted = false
        next.workoutExercise = exercise
        workout.workoutExercises = NSOrderedSet(array: [exercise])
        exercise.workoutSets = NSOrderedSet(array: [completed, next])
    }

    override func tearDown() {
        persistentContainer.viewContext.reset()
        persistentContainer = nil
        workout = nil
        exercise = nil
        completed = nil
        next = nil
        super.tearDown()
    }

    private func setID(_ set: WorkoutSet) -> String {
        set.uuid?.uuidString ?? set.objectID.uriRepresentation().absoluteString
    }

    private func snapshot(for set: WorkoutSet, number: Int) -> WorkoutActivityAttributes.SetSnapshot {
        WorkoutActivityAttributes.SetSnapshot(
            setID: setID(set),
            exerciseName: "Deadlift (Barbell)",
            setNumber: number,
            setCount: 2,
            result: "135 lb × 5 reps"
        )
    }

    private func priorState() -> WorkoutActivityAttributes.ContentState {
        WorkoutActivityAttributes.ContentState(
            phase: .setCompleted,
            displaySet: snapshot(for: completed, number: 1),
            nextSet: snapshot(for: next, number: 2),
            confirmationUntil: now.addingTimeInterval(10),
            restTimerStart: nil,
            restTimerEnd: nil,
            completedSets: 1,
            totalSets: 2
        )
    }

    func testReconciliationPromotesRunningRestAndClearsStaleConfirmation() {
        let state = WorkoutLiveActivityManager.shared.reconciledState(
            for: workout,
            priorState: priorState(),
            now: now,
            restTimerStart: now.addingTimeInterval(-5),
            restTimerEnd: now.addingTimeInterval(55)
        )

        XCTAssertEqual(state.phase, .resting)
        XCTAssertNil(state.confirmationUntil)
        XCTAssertEqual(state.displaySet?.setID, setID(completed))
        XCTAssertEqual(state.nextSet?.setID, setID(next))
    }

    func testReconciliationPromotesPausedRestAndClearsStaleConfirmation() {
        let state = WorkoutLiveActivityManager.shared.reconciledState(
            for: workout,
            priorState: priorState(),
            now: now,
            restTimerStart: nil,
            restTimerEnd: nil,
            pausedRestRemaining: 30
        )

        XCTAssertEqual(state.phase, .resting)
        XCTAssertNil(state.confirmationUntil)
        XCTAssertEqual(state.pausedRestRemaining, 30)
    }

    func testPhoneAndWatchRestUpdatesPublishMatchingIntervalsThroughSkip() throws {
        var currentTime = now
        let suite = "WorkoutLiveActivityRestTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RestTimerStore(
            userDefaults: defaults,
            now: { currentTime },
            keepRunning: { false },
            notificationUpdater: { _, _ in },
            watchUpdater: { _ in },
            expiryScheduler: { _, _ in {} }
        )
        func reconcile() -> WorkoutActivityAttributes.ContentState {
            let interval = store.restTimerInterval
            return WorkoutLiveActivityManager.shared.reconciledState(
                for: workout,
                priorState: priorState(),
                now: currentTime,
                restTimerStart: interval?.lowerBound,
                restTimerEnd: interval?.upperBound,
                pausedRestRemaining: store.isPaused ? store.restTimerRemainingTime : nil
            )
        }

        store.start(duration: 120)
        currentTime.addTimeInterval(45)
        // The phone App Intent calls this same adjust method before refreshing.
        store.adjust(by: 15)
        let phone = reconcile()
        XCTAssertEqual(phone.restTimerStart, now)
        XCTAssertEqual(phone.restDuration, 135)
        XCTAssertEqual(try XCTUnwrap(phone.restProgress(at: currentTime)), 45.0 / 135.0, accuracy: 0.001)

        store.applyWatchUpdate(end: try XCTUnwrap(store.restTimerEnd).addingTimeInterval(-15))
        let watch = reconcile()
        XCTAssertEqual(watch.restTimerStart, now)
        XCTAssertEqual(watch.restDuration, 120)
        XCTAssertEqual(watch.restProgress(at: currentTime), 0.375)

        store.applyWatchUpdate(end: nil, pausedRemaining: 75)
        currentTime.addTimeInterval(300)
        store.adjust(by: 15)
        let paused = reconcile()
        XCTAssertEqual(paused.phase, .resting)
        XCTAssertEqual(paused.pausedRestRemaining, 90)
        XCTAssertEqual(paused.restDuration, 135)
        XCTAssertEqual(try XCTUnwrap(paused.restProgress(at: currentTime)), 45.0 / 135.0, accuracy: 0.001)
        XCTAssertEqual(paused.restProgress(at: currentTime.addingTimeInterval(300)), paused.restProgress(at: currentTime))

        store.applyWatchUpdate(end: nil, pausedRemaining: 75)
        XCTAssertEqual(reconcile().restDuration, 120)
        XCTAssertEqual(reconcile().restProgress(at: currentTime), 0.375)
        store.applyWatchUpdate(end: currentTime.addingTimeInterval(75))
        let resumed = reconcile()
        XCTAssertFalse(resumed.isRestPaused)
        XCTAssertEqual(resumed.restDuration, 120)
        XCTAssertEqual(resumed.restProgress(at: currentTime), 0.375)

        // SkipWorkoutRestTimerIntent cancels this store before refreshing.
        store.cancel()
        let skipped = reconcile()
        XCTAssertEqual(skipped.phase, .currentSet)
        XCTAssertNil(skipped.restTimerInterval)
        XCTAssertNil(skipped.pausedRestRemaining)
    }

    func testReconciliationRetainsConfirmationWhenNoRestIsActive() {
        let state = WorkoutLiveActivityManager.shared.reconciledState(
            for: workout,
            priorState: priorState(),
            now: now,
            restTimerStart: nil,
            restTimerEnd: nil
        )

        XCTAssertEqual(state.phase, .setCompleted)
        XCTAssertEqual(state.confirmationUntil, now.addingTimeInterval(10))
    }
}

final class WorkoutSetFocusTests: XCTestCase {
    private struct ExerciseSpec {
        let supersetID: UUID?
        let completed: [Bool]

        init(completed: [Bool], supersetID: UUID? = nil) {
            self.supersetID = supersetID
            self.completed = completed
        }
    }

    private var container: NSPersistentContainer!
    private var context: NSManagedObjectContext { container.viewContext }

    override func setUp() {
        super.setUp()
        container = setUpInMemoryNSPersistentContainer()
    }

    override func tearDown() {
        container.viewContext.reset()
        container = nil
        super.tearDown()
    }

    private func makeWorkout(
        current: Bool = true,
        specs: [ExerciseSpec]
    ) -> (workout: Workout, exercises: [WorkoutExercise], sets: [[WorkoutSet]]) {
        let workout = Workout.create(context: context)
        workout.start = Date(timeIntervalSince1970: 1_000)
        workout.isCurrentWorkout = current
        if !current { workout.end = Date(timeIntervalSince1970: 2_000) }

        var exercises: [WorkoutExercise] = []
        var setsByExercise: [[WorkoutSet]] = []

        for spec in specs {
            let exercise = WorkoutExercise.create(context: context)
            exercise.supersetUuid = spec.supersetID
            exercise.workout = workout

            let sets = spec.completed.map { completed -> WorkoutSet in
                let set = WorkoutSet.create(context: context)
                set.isCompleted = completed
                set.workoutExercise = exercise
                return set
            }
            exercise.workoutSets = NSOrderedSet(array: sets)
            exercises.append(exercise)
            setsByExercise.append(sets)
        }

        workout.workoutExercises = NSOrderedSet(array: exercises)
        return (workout, exercises, setsByExercise)
    }

    private func assertFocus(
        _ focus: WorkoutSetFocus?,
        exercise: WorkoutExercise,
        set: WorkoutSet,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            focus,
            WorkoutSetFocus(exerciseID: exercise.objectID, setID: set.objectID),
            file: file,
            line: line
        )
    }

    func testNormalSupersetProgressionAlternatesRounds() {
        let group = UUID()
        let graph = makeWorkout(specs: [
            ExerciseSpec(completed: [false, false], supersetID: group),
            ExerciseSpec(completed: [false, false], supersetID: group)
        ])
        let expected = [(0, 0), (1, 0), (0, 1), (1, 1)]

        for (exerciseIndex, setIndex) in expected {
            assertFocus(
                WorkoutSetFocus.next(in: graph.workout),
                exercise: graph.exercises[exerciseIndex],
                set: graph.sets[exerciseIndex][setIndex]
            )
            graph.sets[exerciseIndex][setIndex].isCompleted = true
        }

        XCTAssertNil(WorkoutSetFocus.next(in: graph.workout))
    }

    func testThreeWaySupersetFinishesUnevenMembersBeforeNextUnit() {
        let group = UUID()
        let graph = makeWorkout(specs: [
            ExerciseSpec(completed: [false, false, false], supersetID: group),
            ExerciseSpec(completed: [false], supersetID: group),
            ExerciseSpec(completed: [false, false], supersetID: group),
            ExerciseSpec(completed: [false])
        ])
        let expected = [(0, 0), (1, 0), (2, 0), (0, 1), (2, 1), (0, 2), (3, 0)]

        for (exerciseIndex, setIndex) in expected {
            assertFocus(
                WorkoutSetFocus.next(in: graph.workout),
                exercise: graph.exercises[exerciseIndex],
                set: graph.sets[exerciseIndex][setIndex]
            )
            graph.sets[exerciseIndex][setIndex].isCompleted = true
        }

        XCTAssertNil(WorkoutSetFocus.next(in: graph.workout))
    }

    func testEmptyAndCompletedSupersetMembersAreSkipped() {
        let group = UUID()
        let graph = makeWorkout(specs: [
            ExerciseSpec(completed: [], supersetID: group),
            ExerciseSpec(completed: [true], supersetID: group),
            ExerciseSpec(completed: [false], supersetID: group),
            ExerciseSpec(completed: [false])
        ])

        assertFocus(
            WorkoutSetFocus.next(in: graph.workout),
            exercise: graph.exercises[2],
            set: graph.sets[2][0]
        )
        graph.sets[2][0].isCompleted = true
        assertFocus(
            WorkoutSetFocus.next(in: graph.workout),
            exercise: graph.exercises[3],
            set: graph.sets[3][0]
        )
    }

    func testNonAdjacentSupersetMembersRemainOneUnit() {
        let group = UUID()
        let graph = makeWorkout(specs: [
            ExerciseSpec(completed: [false, false], supersetID: group),
            ExerciseSpec(completed: [false]),
            ExerciseSpec(completed: [false, false], supersetID: group),
            ExerciseSpec(completed: [false])
        ])
        let expected = [(0, 0), (2, 0), (0, 1), (2, 1), (1, 0), (3, 0)]

        for (exerciseIndex, setIndex) in expected {
            assertFocus(
                WorkoutSetFocus.next(in: graph.workout),
                exercise: graph.exercises[exerciseIndex],
                set: graph.sets[exerciseIndex][setIndex]
            )
            graph.sets[exerciseIndex][setIndex].isCompleted = true
        }
    }

    func testOutOfOrderHolesUseFirstIncompleteSetAndStableTieBreak() {
        let group = UUID()
        let graph = makeWorkout(specs: [
            ExerciseSpec(completed: [true, false, false], supersetID: group),
            ExerciseSpec(completed: [false, true, false], supersetID: group)
        ])
        let expected = [(1, 0), (0, 1), (0, 2), (1, 2)]

        for (exerciseIndex, setIndex) in expected {
            assertFocus(
                WorkoutSetFocus.next(in: graph.workout),
                exercise: graph.exercises[exerciseIndex],
                set: graph.sets[exerciseIndex][setIndex]
            )
            graph.sets[exerciseIndex][setIndex].isCompleted = true
        }
        XCTAssertNil(WorkoutSetFocus.next(in: graph.workout))
    }

    func testNonCurrentAndAllCompletedWorkoutsHaveNoFocus() {
        let nonCurrent = makeWorkout(
            current: false,
            specs: [ExerciseSpec(completed: [false])]
        )
        XCTAssertNil(WorkoutSetFocus.next(in: nonCurrent.workout))

        let allCompleted = makeWorkout(
            specs: [ExerciseSpec(completed: [true]), ExerciseSpec(completed: [])]
        )
        XCTAssertNil(WorkoutSetFocus.next(in: allCompleted.workout))
    }

    func testOrdinaryExercisesFinishInWorkoutOrderWithOnlyOneFocus() {
        let graph = makeWorkout(specs: [
            ExerciseSpec(completed: [false, false]),
            ExerciseSpec(completed: [false, false])
        ])
        for (exerciseIndex, setIndex) in [(0, 0), (0, 1), (1, 0), (1, 1)] {
            let focus = WorkoutSetFocus.next(in: graph.workout)
            assertFocus(focus, exercise: graph.exercises[exerciseIndex], set: graph.sets[exerciseIndex][setIndex])
            XCTAssertEqual(graph.sets.flatMap { $0 }.filter { $0.objectID == focus?.setID }.count, 1)
            graph.sets[exerciseIndex][setIndex].isCompleted = true
        }
    }

    func testUndoReorderAndDeletionRecomputeFromCurrentModel() {
        let graph = makeWorkout(specs: [
            ExerciseSpec(completed: [false, false]),
            ExerciseSpec(completed: [false])
        ])
        graph.sets[0][0].isCompleted = true
        assertFocus(WorkoutSetFocus.next(in: graph.workout), exercise: graph.exercises[0], set: graph.sets[0][1])
        graph.sets[0][0].isCompleted = false
        assertFocus(WorkoutSetFocus.next(in: graph.workout), exercise: graph.exercises[0], set: graph.sets[0][0])
        graph.workout.workoutExercises = NSOrderedSet(array: graph.exercises.reversed())
        assertFocus(WorkoutSetFocus.next(in: graph.workout), exercise: graph.exercises[1], set: graph.sets[1][0])
        graph.exercises[1].removeFromWorkoutSets(graph.sets[1][0])
        context.delete(graph.sets[1][0])
        context.processPendingChanges()
        assertFocus(WorkoutSetFocus.next(in: graph.workout), exercise: graph.exercises[0], set: graph.sets[0][0])
    }

    func testPendingSetDeletionIsSkippedBeforeRelationshipCleanup() {
        let graph = makeWorkout(specs: [ExerciseSpec(completed: [false, false])])
        try! context.save()
        context.delete(graph.sets[0][0])
        assertFocus(WorkoutSetFocus.next(in: graph.workout), exercise: graph.exercises[0], set: graph.sets[0][1])
    }

    func testPendingExerciseDeletionIsSkippedBeforeRelationshipCleanup() {
        let graph = makeWorkout(specs: [
            ExerciseSpec(completed: [false]),
            ExerciseSpec(completed: [false])
        ])
        try! context.save()
        context.delete(graph.exercises[0])
        assertFocus(WorkoutSetFocus.next(in: graph.workout), exercise: graph.exercises[1], set: graph.sets[1][0])
    }

    func testFindingFocusDoesNotMutateOrderedGraph() {
        let group = UUID()
        let graph = makeWorkout(specs: [
            ExerciseSpec(completed: [true, false], supersetID: group),
            ExerciseSpec(completed: [false], supersetID: group),
            ExerciseSpec(completed: [false])
        ])
        let exerciseIDs = graph.workout.workoutExercises?.array.compactMap { ($0 as? WorkoutExercise)?.objectID }
        let setIDs = graph.sets.map { $0.map(\.objectID) }
        let completion = graph.sets.map { $0.map(\.isCompleted) }
        let supersetIDs = graph.exercises.map(\.supersetUuid)
        let insertedCount = context.insertedObjects.count

        _ = WorkoutSetFocus.next(in: graph.workout)

        XCTAssertEqual(
            graph.workout.workoutExercises?.array.compactMap { ($0 as? WorkoutExercise)?.objectID },
            exerciseIDs
        )
        XCTAssertEqual(graph.sets.map { $0.map(\.objectID) }, setIDs)
        XCTAssertEqual(graph.sets.map { $0.map(\.isCompleted) }, completion)
        XCTAssertEqual(graph.exercises.map(\.supersetUuid), supersetIDs)
        XCTAssertEqual(context.insertedObjects.count, insertedCount)
    }
}

final class WorkoutOrganizationTests: XCTestCase {
    private var container: NSPersistentContainer!
    private var context: NSManagedObjectContext { container.viewContext }
    private var workout: Workout!
    private var exercises: [WorkoutExercise]!
    private var sets: [WorkoutSet]!

    override func setUp() {
        super.setUp()
        container = setUpInMemoryNSPersistentContainer()
        workout = Workout.create(context: context)
        workout.isCurrentWorkout = true
        workout.start = Date()
        exercises = (0..<6).map { index in
            let exercise = WorkoutExercise.create(context: context)
            exercise.workout = workout
            exercise.comment = "Notes \(index)"
            return exercise
        }
        sets = exercises.enumerated().map { index, exercise in
            let set = WorkoutSet.create(context: context)
            set.workoutExercise = exercise
            set.weightValue = Double(20 + index)
            set.repetitionsValue = 5
            set.isCompleted = index % 2 == 0
            exercise.workoutSets = NSOrderedSet(array: [set])
            return set
        }
        workout.workoutExercises = NSOrderedSet(array: exercises)
    }

    override func tearDown() {
        context.reset()
        container = nil
        workout = nil
        exercises = nil
        sets = nil
        super.tearDown()
    }

    private var order: [NSManagedObjectID] {
        (workout.workoutExercises?.array as? [WorkoutExercise] ?? []).map(\.objectID)
    }
    private var groups: [UUID?] { exercises.map(\.supersetUuid) }

    func testCreatesOnlySelectedPairWithoutChangingSetsOrOrder() throws {
        let originalOrder = order
        let originalSetIDs = sets.map(\.objectID)
        let originalWeights = sets.map(\.weightValue)
        try WorkoutOrganization.setSuperset(in: workout, source: exercises[0], partnerIDs: [exercises[1].objectID])
        XCTAssertNotNil(exercises[0].supersetUuid)
        XCTAssertEqual(exercises[0].supersetUuid, exercises[1].supersetUuid)
        XCTAssertTrue(exercises.dropFirst(2).allSatisfy { $0.supersetUuid == nil })
        XCTAssertEqual(order, originalOrder)
        XCTAssertEqual(sets.map(\.objectID), originalSetIDs)
        XCTAssertEqual(sets.map(\.weightValue), originalWeights)
    }

    func testChoosingExistingGroupIncludesEveryMember() throws {
        let first = UUID(), second = UUID(), untouched = UUID()
        for index in [0, 1] { exercises[index].supersetUuid = first }
        for index in [2, 3] { exercises[index].supersetUuid = second }
        for index in [4, 5] { exercises[index].supersetUuid = untouched }
        try WorkoutOrganization.setSuperset(in: workout, source: exercises[0], partnerIDs: [exercises[1].objectID, exercises[2].objectID])
        XCTAssertEqual(Set(exercises.prefix(4).compactMap(\.supersetUuid)).count, 1)
        XCTAssertEqual(exercises[4].supersetUuid, untouched)
        XCTAssertEqual(exercises[5].supersetUuid, untouched)
    }

    func testEditingLeavesTwoUnselectedFormerPartnersLinked() throws {
        let former = UUID(), chosen = UUID()
        for index in [0, 1, 2] { exercises[index].supersetUuid = former }
        for index in [3, 4] { exercises[index].supersetUuid = chosen }
        try WorkoutOrganization.setSuperset(in: workout, source: exercises[0], partnerIDs: [exercises[3].objectID])
        XCTAssertEqual(exercises[0].supersetUuid, chosen)
        XCTAssertEqual(exercises[4].supersetUuid, chosen)
        XCTAssertEqual(exercises[1].supersetUuid, former)
        XCTAssertEqual(exercises[2].supersetUuid, former)
    }

    func testEditingClearsOrphanedFormerPartner() throws {
        let former = UUID()
        exercises[0].supersetUuid = former
        exercises[1].supersetUuid = former
        try WorkoutOrganization.setSuperset(in: workout, source: exercises[0], partnerIDs: [exercises[2].objectID])
        XCTAssertNil(exercises[1].supersetUuid)
        XCTAssertEqual(exercises[0].supersetUuid, exercises[2].supersetUuid)
    }

    func testInvalidPartnerSelectionDoesNotMutateTheGroup() throws {
        try context.save()
        let originalGroups = groups
        let outsider = WorkoutExercise.create(context: context)
        XCTAssertThrowsError(try WorkoutOrganization.setSuperset(in: workout, source: exercises[0], partnerIDs: [outsider.objectID]))
        XCTAssertThrowsError(try WorkoutOrganization.setSuperset(in: workout, source: exercises[0], partnerIDs: []))
        XCTAssertThrowsError(try WorkoutOrganization.setSuperset(in: workout, source: exercises[0], partnerIDs: [exercises[0].objectID]))
        XCTAssertEqual(groups, originalGroups)
    }

    func testReorderPreservesSupersetAndSetIdentities() throws {
        let group = UUID()
        exercises[0].supersetUuid = group
        exercises[1].supersetUuid = group
        let originalSetIDs = sets.map(\.objectID)
        let originalGroups = groups
        let reversed = Array(order.reversed())
        try WorkoutOrganization.reorder(reversed, in: workout)
        XCTAssertEqual(order, reversed)
        XCTAssertEqual(groups, originalGroups)
        XCTAssertEqual(sets.map(\.objectID), originalSetIDs)
        XCTAssertEqual(exercises.map(\.comment), (0..<6).map { "Notes \($0)" })
    }

    func testStaleOrDuplicateReorderIsRejectedBeforeMutation() throws {
        let original = order
        XCTAssertThrowsError(try WorkoutOrganization.reorder(Array(original.dropLast()), in: workout))
        var duplicate = original
        duplicate[0] = duplicate[1]
        XCTAssertThrowsError(try WorkoutOrganization.reorder(duplicate, in: workout))
        let outsider = WorkoutExercise.create(context: context)
        var foreign = original
        foreign[0] = outsider.objectID
        XCTAssertThrowsError(try WorkoutOrganization.reorder(foreign, in: workout))
        XCTAssertEqual(order, original)
    }

    func testFailedSaveRestoresOrderAndGroupsButKeepsPendingTitle() throws {
        enum SaveFailure: Error { case expected }
        try context.save()
        let original = order
        workout.title = "Pending title"
        let originalGroups = groups
        var saveAttempts = 0
        XCTAssertThrowsError(try context.persistMutation(save: { saveAttempts += 1; throw SaveFailure.expected }) {
            try WorkoutOrganization.setSuperset(in: self.workout, source: self.exercises[0], partnerIDs: [self.exercises[1].objectID])
            try WorkoutOrganization.reorder(Array(original.reversed()), in: self.workout)
        })
        XCTAssertEqual(saveAttempts, 1)
        XCTAssertEqual(order, original)
        XCTAssertEqual(groups, originalGroups)
        XCTAssertEqual(workout.title, "Pending title")
        XCTAssertTrue(context.hasChanges)
    }

    func testInactiveWorkoutIsNeverEdited() throws {
        workout.isCurrentWorkout = false
        let original = order
        XCTAssertThrowsError(try WorkoutOrganization.reorder(Array(original.reversed()), in: workout))
        XCTAssertThrowsError(try WorkoutOrganization.setSuperset(in: workout, source: exercises[0], partnerIDs: [exercises[1].objectID]))
        XCTAssertEqual(order, original)
        XCTAssertTrue(groups.allSatisfy { $0 == nil })
    }
}


final class SavedWorkoutTrackingTransferTests: XCTestCase {
    // These cover app-side transfer helpers, so use the app module's copy of the shared types.
    private typealias SetTrackingType = Iron.SetTrackingType
    private typealias SetTrackingPreferences = Iron.SetTrackingPreferences
    private enum SaveFailure: Error { case failed }
    private var container: NSPersistentContainer!
    private var defaults: UserDefaults!
    private var suite: String!
    private var context: NSManagedObjectContext { container.viewContext }

    override func setUpWithError() throws {
        container = setUpInMemoryNSPersistentContainer()
        suite = "SavedWorkoutTrackingTransferTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        container = nil
        super.tearDown()
    }

    private func routine() throws -> (WorkoutRoutine, WorkoutRoutineExercise, WorkoutRoutineSet) {
        let plan = WorkoutPlan.create(context: context)
        let routine = WorkoutRoutine.create(context: context)
        routine.workoutPlan = plan
        let exercise = WorkoutRoutineExercise.create(context: context)
        exercise.exerciseUuid = UUID()
        exercise.workoutRoutine = routine
        let set = WorkoutRoutineSet.create(context: context)
        set.workoutRoutineExercise = exercise
        set.weightValue = 40
        SetTrackingPreferences.setOverride(.weightDistance, for: try XCTUnwrap(exercise.exerciseUuid), defaults: defaults)
        SetTrackingPreferences.setRoutineDistance(25, for: try XCTUnwrap(set.uuid), defaults: defaults)
        try context.save()
        return (routine, exercise, set)
    }

    func testDuplicateStagesFreshDistanceTargetsAndSupportsCancelFailureAndRetry() throws {
        let (source, exercise, sourceSet) = try routine()
        let original = SetTrackingPreferences.load(defaults: defaults)
        let route = WorkoutPlanEditorRoute(kind: .duplicate(planID: source.objectID))
        let cancelled = try WorkoutPlanEditorSession(parentContext: context, route: route, trackingDefaults: defaults)
        let cancelledExercise = try XCTUnwrap(cancelled.routine.workoutRoutineExercises?.firstObject as? WorkoutRoutineExercise)
        let cancelledSet = try XCTUnwrap(cancelledExercise.workoutRoutineSets?.firstObject as? WorkoutRoutineSet)
        XCTAssertNotEqual(cancelledSet.uuid, sourceSet.uuid)
        XCTAssertEqual(cancelled.trackingDraft.distance(for: cancelledSet.uuid), 25)
        XCTAssertEqual(cancelled.trackingDraft.override(for: exercise.exerciseUuid), .weightDistance)
        XCTAssertEqual(SetTrackingPreferences.load(defaults: defaults), original)
        cancelled.cancel()
        XCTAssertEqual(SetTrackingPreferences.load(defaults: defaults), original)

        let session = try WorkoutPlanEditorSession(parentContext: context, route: route, trackingDefaults: defaults)
        let copiedExercise = try XCTUnwrap(session.routine.workoutRoutineExercises?.firstObject as? WorkoutRoutineExercise)
        let copiedSet = try XCTUnwrap(copiedExercise.workoutRoutineSets?.firstObject as? WorkoutRoutineSet)
        let copiedID = try XCTUnwrap(copiedSet.uuid)
        session.trackingDraft.setDistance(50, for: copiedID)
        XCTAssertThrowsError(try session.commit(save: { throw SaveFailure.failed }))
        XCTAssertEqual(SetTrackingPreferences.load(defaults: defaults), original)
        XCTAssertEqual(session.trackingDraft.distance(for: copiedID), 50)
        XCTAssertEqual(try context.count(for: WorkoutRoutine.fetchRequest()), 1)
        try session.commit()
        XCTAssertEqual(SetTrackingPreferences.routineDistance(for: copiedID, defaults: defaults), 50)
        XCTAssertEqual(SetTrackingPreferences.routineDistance(for: sourceSet.uuid, defaults: defaults), 25)
        XCTAssertEqual(try context.count(for: WorkoutRoutine.fetchRequest()), 2)
    }

    func testSaveAsWorkoutStagesInferredTypesAndDistanceForCurrentAndFinishedSessions() throws {
        for current in [true, false] {
            let source = Workout.create(context: context)
            source.isCurrentWorkout = current
            source.start = Date(timeIntervalSince1970: 1_000)
            source.end = current ? nil : Date(timeIntervalSince1970: 2_000)
            let exercise = WorkoutExercise.create(context: context)
            exercise.exerciseUuid = UUID()
            exercise.workout = source
            let set = WorkoutSet.create(context: context)
            set.workoutExercise = exercise
            set.weightValue = 40
            set.distanceValue = 25
            set.isCompleted = !current
            try context.save()
            let original = SetTrackingPreferences.load(defaults: defaults)
            let route = WorkoutPlanEditorRoute(kind: .createFromWorkout(workoutID: source.objectID, containerID: nil))
            let session = try WorkoutPlanEditorSession(parentContext: context, route: route, trackingDefaults: defaults)
            let targetExercise = try XCTUnwrap(session.routine.workoutRoutineExercises?.firstObject as? WorkoutRoutineExercise)
            let targetSet = try XCTUnwrap(targetExercise.workoutRoutineSets?.firstObject as? WorkoutRoutineSet)
            XCTAssertEqual(session.trackingDraft.override(for: exercise.exerciseUuid), .weightDistance)
            XCTAssertEqual(session.trackingDraft.distance(for: targetSet.uuid), 25)
            XCTAssertEqual(SetTrackingPreferences.load(defaults: defaults), original)
            XCTAssertThrowsError(try session.commit(save: { throw SaveFailure.failed }))
            XCTAssertEqual(SetTrackingPreferences.load(defaults: defaults), original)
            try session.commit()
            XCTAssertEqual(SetTrackingPreferences.override(for: exercise.exerciseUuid, defaults: defaults), .weightDistance)
            XCTAssertEqual(SetTrackingPreferences.routineDistance(for: targetSet.uuid, defaults: defaults), 25)
            XCTAssertEqual(source.isCurrentWorkout, current)
            XCTAssertEqual(set.isCompleted, !current)
            XCTAssertEqual(set.distanceValue, 25)
        }
    }

    func testEditorUsesStagedTypeChangesAndDropsDeletedDraftSetMetadata() throws {
        let (source, exercise, _) = try routine()
        let session = try WorkoutPlanEditorSession(parentContext: context,
            route: .init(kind: .duplicate(planID: source.objectID)), trackingDefaults: defaults)
        let copiedExercise = try XCTUnwrap(session.routine.workoutRoutineExercises?.firstObject as? WorkoutRoutineExercise)
        let copiedSet = try XCTUnwrap(copiedExercise.workoutRoutineSets?.firstObject as? WorkoutRoutineSet)
        let removedID = try XCTUnwrap(copiedSet.uuid)
        session.trackingDraft.setOverride(.duration, for: try XCTUnwrap(exercise.exerciseUuid))
        session.context.delete(copiedSet)
        session.context.processPendingChanges()
        try session.commit()
        XCTAssertEqual(SetTrackingPreferences.override(for: exercise.exerciseUuid, defaults: defaults), .duration)
        XCTAssertNil(SetTrackingPreferences.load(defaults: defaults).routineDistances[removedID.uuidString])
    }

    func testSingleWorkoutExportScopesMetadataAndImportRemapsItAfterDurableSave() throws {
        let (source, exercise, sourceSet) = try routine()
        let unrelatedID = UUID()
        SetTrackingPreferences.setOverride(.duration, for: unrelatedID, defaults: defaults)
        SetTrackingPreferences.setRoutineDistance(999, for: UUID(), defaults: defaults)
        let document = SavedWorkoutDocument(workout: source, defaults: defaults)
        XCTAssertEqual(document.trackingPreferences?.overrides.count, 1)
        XCTAssertEqual(document.trackingPreferences?.routineDistances.count, 1)
        let data = try JSONEncoder().encode(document)
        defaults.removeObject(forKey: SetTrackingPreferences.storageKey)
        XCTAssertThrowsError(try SavedWorkoutImporter.importData(data, into: context, trackingDefaults: defaults,
            save: { throw SaveFailure.failed }))
        XCTAssertTrue(SetTrackingPreferences.load(defaults: defaults).isEmpty)
        XCTAssertEqual(try context.count(for: WorkoutRoutine.fetchRequest()), 1)

        for _ in 0..<2 {
            try SavedWorkoutImporter.importData(data, into: context, trackingDefaults: defaults)
        }
        let imported = try context.fetch(WorkoutRoutine.fetchRequest()).filter { $0 != source }
        let importedSets = imported.compactMap {
            ($0.workoutRoutineExercises?.firstObject as? WorkoutRoutineExercise)?.workoutRoutineSets?.firstObject as? WorkoutRoutineSet
        }
        XCTAssertEqual(importedSets.count, 2)
        XCTAssertEqual(Set(imported.compactMap(\.uuid)).count, 2)
        XCTAssertEqual(Set(importedSets.compactMap(\.uuid)).count, 2)
        for set in importedSets {
            XCTAssertNotEqual(set.uuid, sourceSet.uuid)
            XCTAssertEqual(SetTrackingPreferences.routineDistance(for: set.uuid, defaults: defaults), 25)
        }
        XCTAssertEqual(SetTrackingPreferences.override(for: exercise.exerciseUuid, defaults: defaults), .weightDistance)
        XCTAssertNil(SetTrackingPreferences.override(for: unrelatedID, defaults: defaults))
        XCTAssertEqual(SetTrackingPreferences.load(defaults: defaults).routineDistances.count, 2)
    }

    func testLegacyDocumentImportsWithoutMetadataAndUnrelatedMetadataIsRejected() throws {
        let (source, _, _) = try routine()
        let data = try JSONEncoder().encode(SavedWorkoutDocument(workout: source, defaults: defaults))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var metadata = try XCTUnwrap(object["trackingPreferences"] as? [String: Any])
        metadata["routineDistances"] = [UUID().uuidString: ["meters": 500, "updatedAt": 1]]
        object["trackingPreferences"] = metadata
        let original = SetTrackingPreferences.load(defaults: defaults)
        XCTAssertThrowsError(try SavedWorkoutImporter.importData(JSONSerialization.data(withJSONObject: object),
            into: context, trackingDefaults: defaults))
        XCTAssertEqual(SetTrackingPreferences.load(defaults: defaults), original)
        XCTAssertEqual(try context.count(for: WorkoutRoutine.fetchRequest()), 1)
        object["version"] = 1
        object.removeValue(forKey: "trackingPreferences")
        try SavedWorkoutImporter.importData(JSONSerialization.data(withJSONObject: object),
            into: context, trackingDefaults: defaults)
        XCTAssertEqual(SetTrackingPreferences.load(defaults: defaults), original)
        XCTAssertEqual(try context.count(for: WorkoutRoutine.fetchRequest()), 2)
    }

    func testBlankRepeatStagesEveryTrackingTypeBeforeClearingValues() throws {
        let source = Workout.create(context: context)
        source.start = Date(timeIntervalSince1970: 1_000)
        source.end = Date(timeIntervalSince1970: 2_000)
        var ids: [UUID: SetTrackingType] = [:]
        for type in SetTrackingType.allCases {
            let exercise = WorkoutExercise.create(context: context)
            let id = UUID()
            ids[id] = type
            exercise.exerciseUuid = id
            exercise.workout = source
            let set = WorkoutSet.create(context: context)
            set.workoutExercise = exercise
            set.isCompleted = true
            set.weightValue = type.usesWeight ? 20 : 0
            set.repetitionsValue = type.usesReps ? 12 : 0
            set.durationValue = type.usesDuration ? 60 : nil
            set.distanceValue = type.usesDistance ? 500 : nil
            if type == .weightedBodyweight || type == .assistedBodyweight {
                SetTrackingPreferences.setOverride(type, for: id, defaults: defaults)
            }
        }
        try context.save()
        let original = SetTrackingPreferences.load(defaults: defaults)
        let draft = source.repeatTrackingDraft(defaults: defaults)
        let blank = try XCTUnwrap(source.copyForRepeat(blank: true))
        for exercise in blank.workoutExercises?.array as? [WorkoutExercise] ?? [] {
            let id = try XCTUnwrap(exercise.exerciseUuid)
            XCTAssertEqual(draft.override(for: id), ids[id])
            for set in exercise.workoutSets?.array as? [WorkoutSet] ?? [] {
                XCTAssertNil(SetTrackingType.infer(from: set.trackingData))
            }
        }
        XCTAssertEqual(SetTrackingPreferences.load(defaults: defaults), original)
        // copyForRepeat creates a draft; the production start boundary assigns
        // these fields before persisting its unfinished sets.
        blank.start = Date(timeIntervalSince1970: 3_000)
        blank.isCurrentWorkout = true
        try context.save()
        draft.commit()
        for exercise in blank.workoutExercises?.array as? [WorkoutExercise] ?? [] {
            let id = try XCTUnwrap(exercise.exerciseUuid)
            XCTAssertEqual(exercise.trackingType(catalogExercise: nil, defaults: defaults), ids[id])
        }
    }

    func testFailedRepeatStartDoesNotPublishInferredTypes() throws {
        let source = Workout.create(context: context)
        source.start = Date(timeIntervalSince1970: 1_000)
        source.end = Date(timeIntervalSince1970: 2_000)
        let exercise = WorkoutExercise.create(context: context)
        exercise.workout = source
        exercise.exerciseUuid = UUID()
        let set = WorkoutSet.create(context: context)
        set.workoutExercise = exercise
        set.durationValue = 90
        set.isCompleted = true
        try context.save()
        var saveCalled = false
        XCTAssertThrowsError(
            try Workout.startRepeating(source, blank: true, trackingDefaults: defaults, save: {
                saveCalled = true
                throw SaveFailure.failed
            })
        ) { error in
            XCTAssertTrue(error is SaveFailure)
        }
        XCTAssertTrue(saveCalled)
        XCTAssertTrue(SetTrackingPreferences.load(defaults: defaults).isEmpty)
        XCTAssertEqual(try context.count(for: Workout.fetchRequest()), 1)
        XCTAssertFalse(source.isCurrentWorkout)
    }

    func testUnfinishedZeroLoadLiftingRowsDoNotInferRepsOnly() {
        let exercise = WorkoutExercise.create(context: context)
        exercise.exerciseUuid = UUID()
        let set = WorkoutSet.create(context: context)
        set.workoutExercise = exercise
        set.repetitionsValue = 5
        set.weightValue = 0
        XCTAssertEqual(exercise.trackingType(catalogExercise: nil, defaults: defaults), .weightReps)
        set.isCompleted = true
        XCTAssertEqual(exercise.trackingType(catalogExercise: nil, defaults: defaults), .bodyweightReps)
    }
}

final class WorkoutSetPersonalRecordTests: XCTestCase {
    private typealias Tracking = WorkoutDataKit.SetTrackingType
    private typealias Values = WorkoutDataKit.SetTrackingType.SetData
    private var container: NSPersistentContainer!
    private var originalPreferences: Data?
    private var context: NSManagedObjectContext { container.viewContext }
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        container = setUpInMemoryNSPersistentContainer()
        originalPreferences = UserDefaults.standard.data(forKey: WorkoutDataKit.SetTrackingPreferences.storageKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(originalPreferences, forKey: WorkoutDataKit.SetTrackingPreferences.storageKey)
        context.reset()
        container = nil
        super.tearDown()
    }

    private func exercise(_ id: UUID, at offset: TimeInterval, current: Bool = false) -> WorkoutExercise {
        let workout = Workout.create(context: context)
        workout.start = date.addingTimeInterval(offset)
        workout.end = date.addingTimeInterval(offset + 600)
        workout.isCurrentWorkout = current
        let exercise = WorkoutExercise.create(context: context)
        exercise.exerciseUuid = id
        exercise.workout = workout
        return exercise
    }

    @discardableResult
    private func set(_ values: Values, in exercise: WorkoutExercise, completed: Bool = true) -> WorkoutSet {
        let set = WorkoutSet.create(context: context)
        // Timed/distance records must work with absent legacy weight/reps fields.
        set.weight = values.weight > 0 ? NSNumber(value: values.weight) : nil
        set.repetitions = values.reps > 0 ? NSNumber(value: values.reps) : nil
        set.durationValue = values.duration
        set.distanceValue = values.distance
        set.isCompleted = completed
        let sets = exercise.workoutSets?.mutableCopy() as? NSMutableOrderedSet ?? NSMutableOrderedSet()
        sets.add(set)
        exercise.workoutSets = sets
        return set
    }

    private func prefer(_ type: Tracking, for id: UUID) {
        WorkoutDataKit.SetTrackingPreferences.setOverride(type, for: id)
    }

    private func assertHistoryAgrees(catalog: [UUID: Exercise] = [:],
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let workouts = try context.fetch(Workout.fetchRequest()).filter { !$0.isCurrentWorkout }
        let completedSets = workouts.flatMap { $0.workoutExercises?.array as? [WorkoutExercise] ?? [] }
            .flatMap { $0.workoutSets?.array as? [WorkoutSet] ?? [] }.filter(\.isCompleted)
        let expected = Set(completedSets.filter { $0.isPersonalRecord == true }.map(\.objectID))
        let snapshot = TrainingHistorySnapshot.build(from: Array(workouts.reversed()), catalog: catalog)
        XCTAssertEqual(snapshot.recordSetIDs, expected, file: file, line: line)
    }

    private var progressions: [(Tracking, Values, Values, Values)] {
        [
            (.weightReps, .init(weight: 40, reps: 8), .init(weight: 35, reps: 7), .init(weight: 45, reps: 8)),
            (.bodyweightReps, .init(reps: 8), .init(reps: 7), .init(reps: 9)),
            (.weightedBodyweight, .init(weight: 20, reps: 8), .init(weight: 15, reps: 7), .init(weight: 25, reps: 8)),
            (.assistedBodyweight, .init(weight: 30, reps: 8), .init(weight: 35, reps: 7), .init(weight: 25, reps: 8)),
            (.duration, .init(duration: 60), .init(duration: 50), .init(duration: 70)),
            (.weightDuration, .init(weight: 20, duration: 60), .init(weight: 15, duration: 50), .init(weight: 25, duration: 60)),
            (.distanceDuration, .init(duration: 300, distance: 1_000), .init(duration: 250, distance: 900), .init(duration: 350, distance: 1_100)),
            (.weightDistance, .init(weight: 20, distance: 30), .init(weight: 15, distance: 25), .init(weight: 25, distance: 30))
        ]
    }

    private func checkProgressions(useOverrides: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        for (type, baseline, worse, improved) in progressions {
            if !useOverrides, type == .weightedBodyweight || type == .assistedBodyweight { continue }
            let id = UUID()
            if useOverrides { prefer(type, for: id) }
            set(baseline, in: exercise(id, at: 0))
            try context.save()
            let current = exercise(id, at: 3_600, current: true)
            let tie = set(baseline, in: current)
            let regression = set(worse, in: current)
            let record = set(improved, in: current)
            let duplicate = set(improved, in: current)
            XCTAssertEqual(tie.isPersonalRecord, false, type.rawValue, file: file, line: line)
            XCTAssertEqual(regression.isPersonalRecord, false, type.rawValue, file: file, line: line)
            XCTAssertEqual(record.isPersonalRecord, true, type.rawValue, file: file, line: line)
            XCTAssertEqual(duplicate.isPersonalRecord, false, type.rawValue, file: file, line: line)
            current.workout?.isCurrentWorkout = false
            try assertHistoryAgrees(file: file, line: line)
            try context.save()
            // Exercise the persisted-store path as well as pending inserts.
            XCTAssertEqual(record.isPersonalRecord, true, type.rawValue, file: file, line: line)
            XCTAssertEqual(duplicate.isPersonalRecord, false, type.rawValue, file: file, line: line)
            try assertHistoryAgrees(file: file, line: line)
        }
    }

    func testAllTrackingTypesCompareTheirOwnMeasurements() throws {
        try checkProgressions(useOverrides: true)
    }

    func testRecordedDimensionsAreInferredWithoutAnOverride() throws {
        try checkProgressions(useOverrides: false)
    }

    func testPredicatesAlsoWorkInSQLite() throws {
        context.reset()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("PersonalRecords.sqlite")
        container = NSPersistentContainer(name: "PersonalRecords", managedObjectModel: WorkoutDataStorage.model)
        defer {
            context.reset()
            try? container.persistentStoreCoordinator.destroyPersistentStore(at: url, ofType: NSSQLiteStoreType, options: nil)
            try? FileManager.default.removeItem(at: directory)
        }
        _ = try container.persistentStoreCoordinator.addPersistentStore(ofType: NSSQLiteStoreType,
            configurationName: nil, at: url, options: nil)
        try checkProgressions(useOverrides: true)
        try checkProgressions(useOverrides: false)
        try checkOnlyCompletedPriorSetsOfTheSameExerciseCountAsHistory()
    }

    func testFirstWorkoutInEachDimensionOnlyEstablishesABaseline() throws {
        for (type, baseline, _, improved) in progressions {
            let id = UUID()
            prefer(type, for: id)
            let first = exercise(id, at: 0, current: true)
            XCTAssertEqual(set(baseline, in: first).isPersonalRecord, false, type.rawValue)
            XCTAssertEqual(set(improved, in: first).isPersonalRecord, false, type.rawValue)
            first.workout?.isCurrentWorkout = false
            try assertHistoryAgrees()
        }
    }

    func testLoadPairsPreserveTheLegacyParetoComparison() throws {
        let cases: [(Tracking, Values, Values, Values)] = [
            (.weightReps, .init(weight: 40, reps: 8), .init(weight: 45, reps: 6), .init(weight: 35, reps: 10)),
            (.weightedBodyweight, .init(weight: 40, reps: 8), .init(weight: 45, reps: 6), .init(weight: 35, reps: 10)),
            (.weightDuration, .init(weight: 40, duration: 60), .init(weight: 45, duration: 50), .init(weight: 35, duration: 70)),
            (.weightDistance, .init(weight: 40, distance: 30), .init(weight: 45, distance: 25), .init(weight: 35, distance: 35))
        ]
        for (type, baseline, heavier, more) in cases {
            let id = UUID()
            prefer(type, for: id)
            set(baseline, in: exercise(id, at: 0))
            try context.save()
            let current = exercise(id, at: 3_600, current: true)
            XCTAssertEqual(set(heavier, in: current).isPersonalRecord, true, type.rawValue)
            XCTAssertEqual(set(more, in: current).isPersonalRecord, true, type.rawValue)
            XCTAssertEqual(set(heavier, in: current).isPersonalRecord, false, type.rawValue)
            current.workout?.isCurrentWorkout = false
            try assertHistoryAgrees()
            let later = exercise(id, at: 7_200)
            XCTAssertEqual(set(heavier, in: later).isPersonalRecord, false, type.rawValue)
            XCTAssertEqual(set(more, in: later).isPersonalRecord, false, type.rawValue)
            XCTAssertEqual(set(baseline, in: later).isPersonalRecord, false, type.rawValue)
            try assertHistoryAgrees()
        }
    }

    func testAssistanceReversesLoadAndAllowsZeroAssistance() throws {
        let id = UUID()
        prefer(.assistedBodyweight, for: id)
        set(.init(weight: 30, reps: 8), in: exercise(id, at: 0))
        try context.save()
        let current = exercise(id, at: 3_600, current: true)
        XCTAssertEqual(set(.init(weight: 40, reps: 8), in: current).isPersonalRecord, false)
        XCTAssertEqual(set(.init(weight: 20, reps: 8), in: current).isPersonalRecord, true)
        XCTAssertEqual(set(.init(weight: 30, reps: 9), in: current).isPersonalRecord, true)
        XCTAssertEqual(set(.init(weight: 30, reps: 7), in: current).isPersonalRecord, false)
        let unassisted = set(.init(reps: 8), in: current)
        unassisted.weightValue = 0
        XCTAssertEqual(unassisted.isPersonalRecord, true)
        let duplicate = set(.init(reps: 8), in: current)
        duplicate.weightValue = 0
        XCTAssertEqual(duplicate.isPersonalRecord, false)
        current.workout?.isCurrentWorkout = false
        try assertHistoryAgrees()
    }

    func testOverrideChangesAreReadWithoutStaleCachedResults() throws {
        let id = UUID()
        set(.init(weight: 30, reps: 8), in: exercise(id, at: 0))
        try context.save()
        let candidate = set(.init(weight: 20, reps: 8), in: exercise(id, at: 3_600, current: true))
        prefer(.weightedBodyweight, for: id)
        XCTAssertEqual(candidate.isPersonalRecord, false)
        prefer(.assistedBodyweight, for: id)
        XCTAssertEqual(candidate.isPersonalRecord, true)
        prefer(.weightedBodyweight, for: id)
        XCTAssertEqual(candidate.isPersonalRecord, false)
    }

    func testDifferentDimensionsNeverEstablishOrSuppressARecord() throws {
        let id = UUID()
        set(.init(weight: 100, reps: 100), in: exercise(id, at: 0))
        try context.save()
        let current = exercise(id, at: 7_200, current: true)
        set(.init(weight: 200, reps: 200), in: current)
        let timed = set(.init(duration: 90), in: current)
        XCTAssertEqual(timed.isPersonalRecord, false) // No prior duration baseline.
        set(.init(duration: 60), in: exercise(id, at: 3_600))
        try context.save()
        XCTAssertEqual(timed.isPersonalRecord, true)
        // A later preference must still resolve recorded reps and seconds separately.
        prefer(.assistedBodyweight, for: id)
        XCTAssertEqual(timed.isPersonalRecord, true)
    }

    func testDistanceTiesDoNotWinThroughFasterPace() throws {
        let id = UUID()
        set(.init(duration: 300, distance: 1_000), in: exercise(id, at: 0))
        try context.save()
        let current = exercise(id, at: 3_600, current: true)
        XCTAssertEqual(set(.init(duration: 240, distance: 1_000), in: current).isPersonalRecord, false)
        XCTAssertEqual(set(.init(distance: 1_100), in: current).isPersonalRecord, true)
        current.workout?.isCurrentWorkout = false
        try assertHistoryAgrees()
    }

    func testCompatibleOverridesStillSeparateRecordedDimensions() throws {
        let id = UUID()
        prefer(.bodyweightReps, for: id)
        set(.init(reps: 8), in: exercise(id, at: 0))
        try context.save()
        let loaded = set(.init(weight: 20, reps: 8), in: exercise(id, at: 7_200, current: true))
        XCTAssertEqual(loaded.isPersonalRecord, false) // Added load resolves to weighted bodyweight.
        set(.init(weight: 10, reps: 8), in: exercise(id, at: 3_600))
        try context.save()
        XCTAssertEqual(loaded.isPersonalRecord, true)
        loaded.workoutExercise?.workout?.isCurrentWorkout = false

        let distanceID = UUID()
        prefer(.distanceDuration, for: distanceID)
        set(.init(duration: 3_600), in: exercise(distanceID, at: 0))
        try context.save()
        let current = exercise(distanceID, at: 7_200, current: true)
        set(.init(duration: 7_200), in: current)
        let distance = set(.init(distance: 1_000), in: current)
        XCTAssertEqual(distance.isPersonalRecord, false) // Time alone is not a distance baseline.
        set(.init(distance: 500), in: exercise(distanceID, at: 3_600))
        try context.save()
        XCTAssertEqual(distance.isPersonalRecord, true)
    }

    func testExplicitZeroLoadRemainsValidForWeightedOverrides() throws {
        let types: [Tracking] = [.weightedBodyweight, .assistedBodyweight, .weightDuration]
        for type in types {
            let id = UUID()
            prefer(type, for: id)
            let values: Values = type == .weightDuration ? .init(duration: 60) : .init(reps: 8)
            let baseline = set(values, in: exercise(id, at: 0))
            baseline.weightValue = 0
            try context.save()
            let current = exercise(id, at: 3_600, current: true)
            let tie = set(values, in: current)
            tie.weightValue = 0
            XCTAssertEqual(tie.isPersonalRecord, false, type.rawValue)
            let more: Values = type == .weightDuration ? .init(duration: 70) : .init(reps: 9)
            let record = set(more, in: current)
            record.weightValue = 0
            XCTAssertEqual(record.isPersonalRecord, true, type.rawValue)
            current.workout?.isCurrentWorkout = false
            try assertHistoryAgrees()
        }
    }

    func testOnlyCompletedPriorSetsOfTheSameExerciseCountAsHistory() throws {
        try checkOnlyCompletedPriorSetsOfTheSameExerciseCountAsHistory()
    }

    private func checkOnlyCompletedPriorSetsOfTheSameExerciseCountAsHistory() throws {
        let id = UUID()
        set(.init(reps: 100), in: exercise(UUID(), at: 0))
        let earlier = set(.init(reps: 100), in: exercise(id, at: 0))
        let peer = set(.init(reps: 100), in: exercise(id, at: 3_600))
        set(.init(reps: 100), in: exercise(id, at: 7_200))
        try context.save()
        earlier.isCompleted = false
        let candidate = set(.init(reps: 10), in: exercise(id, at: 3_600, current: true))
        XCTAssertEqual(candidate.isPersonalRecord, false) // No completed prior baseline.
        earlier.isCompleted = true
        earlier.repetitionsValue = 8
        XCTAssertEqual(candidate.isPersonalRecord, true) // Peer/future/other UUID are ignored.
        let peerWorkout = try XCTUnwrap(peer.workoutExercise?.workout)
        peerWorkout.start = date.addingTimeInterval(1_800)
        XCTAssertEqual(candidate.isPersonalRecord, false)
        peerWorkout.start = date.addingTimeInterval(3_600)
        XCTAssertEqual(candidate.isPersonalRecord, true) // Moving it back removes the suppressor.
        let earlierWorkout = try XCTUnwrap(earlier.workoutExercise?.workout)
        earlierWorkout.end = date.addingTimeInterval(4_200)
        earlierWorkout.start = date.addingTimeInterval(3_600)
        XCTAssertEqual(candidate.isPersonalRecord, false) // The edited date also removes the baseline.
        earlierWorkout.start = date
        earlierWorkout.end = date.addingTimeInterval(600)
        XCTAssertEqual(candidate.isPersonalRecord, true)
        peerWorkout.start = date.addingTimeInterval(1_800)
        XCTAssertEqual(candidate.isPersonalRecord, false)
        try context.save()
        XCTAssertEqual(candidate.isPersonalRecord, false)
    }

    func testEarlierUnfinishedRowsStillSuppressAndLaterRowsDoNot() throws {
        let id = UUID()
        set(.init(duration: 60), in: exercise(id, at: 0))
        try context.save()
        let current = exercise(id, at: 3_600, current: true)
        let earlier = set(.init(duration: 120), in: current, completed: false)
        let candidate = set(.init(duration: 90), in: current)
        XCTAssertEqual(candidate.isPersonalRecord, false)
        current.workoutSets = NSOrderedSet(array: [candidate, earlier])
        XCTAssertEqual(candidate.isPersonalRecord, true)
        earlier.durationValue = 80
        current.workoutSets = NSOrderedSet(array: [earlier, candidate])
        XCTAssertEqual(candidate.isPersonalRecord, true)
    }

    func testHistoryPreservesEarlierRowSuppressionForEveryDimension() throws {
        for (type, baseline, _, improved) in progressions {
            let id = UUID()
            prefer(type, for: id)
            set(baseline, in: exercise(id, at: 0))
            try context.save()
            let current = exercise(id, at: 3_600)
            let earlier = set(improved, in: current, completed: false)
            let candidate = set(improved, in: current)
            XCTAssertEqual(candidate.isPersonalRecord, false, type.rawValue)
            try assertHistoryAgrees()
            current.workoutSets = NSOrderedSet(array: [candidate, earlier])
            XCTAssertEqual(candidate.isPersonalRecord, true, type.rawValue)
            try assertHistoryAgrees()
            // Completed rows, rather than unfinished suppressors, enter history.
            set(baseline, in: exercise(id, at: 7_200))
            try assertHistoryAgrees()
            // The snapshot above tolerates an unfinished row in memory, but
            // finishing must remove it before the historical graph can save.
            current.workout?.deleteUncompletedSets()
            try context.save()
            try assertHistoryAgrees()
        }
    }

    func testHistoryIgnoresInvalidBaselinesAndRequiresStoredLoad() throws {
        for type in [Tracking.assistedBodyweight, .weightDuration, .weightDistance] {
            let id = UUID()
            prefer(type, for: id)
            let baseline: Values
            let improved: Values
            switch type {
            case .assistedBodyweight:
                baseline = .init(weight: 30, reps: 8)
                improved = .init(weight: 20, reps: 8)
            case .weightDuration:
                baseline = .init(weight: 20, duration: 60)
                improved = .init(weight: 25, duration: 60)
            default:
                baseline = .init(weight: 20, distance: 30)
                improved = .init(weight: 25, distance: 30)
            }
            let prior = set(baseline, in: exercise(id, at: 0))
            prior.weight = nil
            let current = exercise(id, at: 3_600)
            let candidate = set(improved, in: current)
            XCTAssertEqual(candidate.isPersonalRecord, false, type.rawValue)
            try assertHistoryAgrees()
            prior.weightValue = baseline.weight
            XCTAssertEqual(candidate.isPersonalRecord, true, type.rawValue)
            try assertHistoryAgrees()
            candidate.weight = nil
            XCTAssertNotEqual(candidate.isPersonalRecord, true, type.rawValue)
            try assertHistoryAgrees()
            candidate.weightValue = -1
            XCTAssertNotEqual(candidate.isPersonalRecord, true, type.rawValue)
            try assertHistoryAgrees()
            candidate.weightValue = .infinity
            XCTAssertNotEqual(candidate.isPersonalRecord, true, type.rawValue)
            try assertHistoryAgrees()
            candidate.weightValue = improved.weight
            try context.save()
            try assertHistoryAgrees()
        }
    }

    func testHistoryUsesTheSamePreferenceAsBadgesRatherThanCatalogMetadata() throws {
        let id = UUID()
        let catalogExercise = Exercise(uuid: id, everkineticId: 10_000, title: "Assisted Pull-up",
            alias: [], description: nil, primaryMuscle: [], secondaryMuscle: [], equipment: ["machine"],
            steps: [], tips: [], references: [], pdfPaths: [])
        set(.init(weight: 30, reps: 8), in: exercise(id, at: 0))
        let candidate = set(.init(weight: 20, reps: 8), in: exercise(id, at: 3_600))
        try context.save()
        XCTAssertEqual(candidate.isPersonalRecord, false)
        try assertHistoryAgrees(catalog: [id: catalogExercise])
        prefer(.assistedBodyweight, for: id)
        XCTAssertEqual(candidate.isPersonalRecord, true)
        try assertHistoryAgrees(catalog: [id: catalogExercise])
        prefer(.weightedBodyweight, for: id)
        XCTAssertEqual(candidate.isPersonalRecord, false)
        try assertHistoryAgrees(catalog: [id: catalogExercise])
    }

    func testHistoryKeepsPeerWorkoutsAndDimensionsSeparate() throws {
        let id = UUID()
        let baseline = exercise(id, at: 0)
        set(.init(duration: 60), in: baseline)
        let peer = exercise(id, at: 3_600)
        set(.init(duration: 120), in: peer)
        let current = exercise(id, at: 3_600)
        set(.init(weight: 100, reps: 100), in: current)
        let candidate = set(.init(duration: 90), in: current)
        let distance = set(.init(distance: 1_000), in: current)
        try context.save()
        XCTAssertEqual(candidate.isPersonalRecord, true)
        XCTAssertEqual(distance.isPersonalRecord, false)
        try assertHistoryAgrees()
        set(.init(distance: 500), in: baseline)
        try context.save()
        XCTAssertEqual(distance.isPersonalRecord, true)
        try assertHistoryAgrees()
    }

    func testInvalidOrMissingMeasurementsAndMetadataDoNotEarnBadges() throws {
        let id = UUID()
        prefer(.weightDuration, for: id)
        set(.init(weight: 20, duration: 60), in: exercise(id, at: 0))
        try context.save()
        let current = exercise(id, at: 3_600, current: true)
        let candidate = set(.init(weight: 25, duration: 70), in: current)
        XCTAssertEqual(candidate.isPersonalRecord, true)
        candidate.weight = nil
        XCTAssertNil(candidate.isPersonalRecord)
        candidate.weightValue = 25
        candidate.duration = .infinity
        XCTAssertNotEqual(candidate.isPersonalRecord, true)
        candidate.duration = 70
        candidate.weightValue = -1
        XCTAssertEqual(candidate.isPersonalRecord, false)
        candidate.weightValue = 25
        current.workout?.start = nil
        XCTAssertNil(candidate.isPersonalRecord)
        current.workout?.start = date.addingTimeInterval(3_600)
        current.exerciseUuid = nil
        XCTAssertNil(candidate.isPersonalRecord)
    }
}

final class WorkoutNoteSeparationTests: XCTestCase {
    private enum SaveFailure: Error { case expected }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "WorkoutNoteSeparationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testSaveAsWorkoutKeepsOnlyRoutineExerciseNotesAndDuplicatePreservesThem() throws {
        for useExplicitLinks in [false, true] {
            let container = setUpInMemoryNSPersistentContainer()
            let context = container.viewContext
            let defaults = try makeDefaults()
            let routine = WorkoutRoutine.create(context: context)
            routine.workoutPlan = WorkoutPlan.create(context: context)
            let exerciseID = UUID()
            let cues: [String?] = ["First plan cue", "Second plan cue", nil]
            let sources = cues.map { cue -> WorkoutRoutineExercise in
                let exercise = WorkoutRoutineExercise.create(context: context)
                exercise.exerciseUuid = exerciseID
                exercise.comment = cue
                return exercise
            }
            routine.workoutRoutineExercises = NSOrderedSet(array: sources)
            let workout = routine.createWorkout(context: context)
            workout.start = Date(timeIntervalSince1970: 1_700_000_000)
            workout.isCurrentWorkout = true
            let logged = try XCTUnwrap(workout.workoutExercises?.array as? [WorkoutExercise])
            for exercise in logged { exercise.comment = "Only relevant to this session" }
            try context.save()
            if useExplicitLinks {
                workout.persistRoutineNoteLinks(defaults: defaults)
                workout.workoutExercises = NSOrderedSet(array: Array(logged.reversed()))
            }
            // Exercises added during the session have no routine cue to carry forward.
            let added = WorkoutExercise.create(context: context)
            added.exerciseUuid = UUID()
            added.comment = "Another session-only note"
            workout.addToWorkoutExercises(added)
            ExerciseNotes.setNote("Persistent exercise cue", for: exerciseID, defaults: defaults, notify: false)
            try context.save()
            let linksBefore = WorkoutRoutineNoteLinks.load(defaults: defaults)
            let notesBefore = ExerciseNotes.load(defaults: defaults)
            let expected: [String?] = (useExplicitLinks ? Array(cues.reversed()) : cues) + [nil]

            let session = try WorkoutPlanEditorSession(
                parentContext: context,
                route: .init(kind: .createFromWorkout(workoutID: workout.objectID, containerID: nil)),
                trackingDefaults: defaults)
            let draftExercises = try XCTUnwrap(
                session.routine.workoutRoutineExercises?.array as? [WorkoutRoutineExercise])
            XCTAssertEqual(draftExercises.map(\.comment), expected)
            try session.commit()
            let saved = try XCTUnwrap(context.fetch(WorkoutRoutine.fetchRequest()).first {
                $0.uuid == session.routine.uuid
            })
            let savedExercises = try XCTUnwrap(saved.workoutRoutineExercises?.array as? [WorkoutRoutineExercise])
            XCTAssertEqual(savedExercises.map(\.comment), expected)

            let duplicate = try WorkoutPlanEditorSession(
                parentContext: context, route: .init(kind: .duplicate(planID: saved.objectID)),
                trackingDefaults: defaults)
            let duplicatedExercises = try XCTUnwrap(
                duplicate.routine.workoutRoutineExercises?.array as? [WorkoutRoutineExercise])
            XCTAssertEqual(duplicatedExercises.map(\.comment), expected)
            duplicate.cancel()
            XCTAssertEqual(sources.map(\.comment), cues)
            XCTAssertTrue(logged.allSatisfy { $0.comment == "Only relevant to this session" })
            XCTAssertEqual(added.comment, "Another session-only note")
            XCTAssertEqual(WorkoutRoutineNoteLinks.load(defaults: defaults), linksBefore)
            XCTAssertEqual(ExerciseNotes.load(defaults: defaults), notesBefore)
        }
    }

    func testRepeatingNeverCopiesTransientExerciseOrSetNotes() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        let defaults = try makeDefaults()
        let source = Workout.create(context: context)
        source.comment = "Session-only summary"
        let exercise = WorkoutExercise.create(context: context)
        exercise.workout = source
        exercise.exerciseUuid = UUID()
        exercise.comment = "Left shoulder felt tired today"
        let set = WorkoutSet.create(context: context)
        set.workoutExercise = exercise
        set.comment = "Lost balance on the last rep"
        set.repetitionsValue = 8
        set.isCompleted = true
        let exerciseID = try XCTUnwrap(exercise.exerciseUuid)
        ExerciseNotes.setNote("Seat height 4", for: exerciseID, defaults: defaults)

        for blank in [false, true] {
            let repeated = try XCTUnwrap(source.copyForRepeat(blank: blank))
            let copied = try XCTUnwrap(repeated.workoutExercises?.firstObject as? WorkoutExercise)
            let copiedSet = try XCTUnwrap(copied.workoutSets?.firstObject as? WorkoutSet)
            XCTAssertNil(repeated.comment)
            XCTAssertNil(copied.comment)
            XCTAssertNil(copiedSet.comment)
            XCTAssertEqual(copied.exerciseUuid, exerciseID)
            XCTAssertEqual(ExerciseNotes.note(for: copied.exerciseUuid, defaults: defaults), "Seat height 4")
        }
        XCTAssertEqual(exercise.comment, "Left shoulder felt tired today")
        XCTAssertEqual(set.comment, "Lost balance on the last rep")
    }

    func testRoutineStartKeepsPlanNotesOutOfTransientFieldAndFailedSavePublishesNoLinks() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        let defaults = try makeDefaults()
        let routine = WorkoutRoutine.create(context: context)
        routine.workoutPlan = WorkoutPlan.create(context: context)
        let planExercise = WorkoutRoutineExercise.create(context: context)
        planExercise.workoutRoutine = routine
        planExercise.exerciseUuid = UUID()
        planExercise.comment = "Perform lateral flexion"
        try context.save()
        var inspected = false

        XCTAssertThrowsError(try Workout.startNew(in: context, routine: routine, notesDefaults: defaults, save: {
            let workout = try XCTUnwrap(context.fetch(Workout.currentWorkoutFetchRequest).first)
            let logged = try XCTUnwrap(workout.workoutExercises?.firstObject as? WorkoutExercise)
            XCTAssertNil(logged.comment)
            XCTAssertEqual(logged.routineNoteSource(defaults: defaults)?.comment, "Perform lateral flexion")
            XCTAssertTrue(WorkoutRoutineNoteLinks.load(defaults: defaults).links.isEmpty)
            inspected = true
            throw SaveFailure.expected
        }))
        XCTAssertTrue(inspected)
        XCTAssertTrue(WorkoutRoutineNoteLinks.load(defaults: defaults).links.isEmpty)
        XCTAssertEqual(planExercise.comment, "Perform lateral flexion")
        XCTAssertEqual(try context.count(for: Workout.fetchRequest()), 0)
    }

    func testRoutineLinkSurvivesDuplicateExerciseReorderingAndRejectsReplacement() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        let defaults = try makeDefaults()
        let routine = WorkoutRoutine.create(context: context)
        routine.workoutPlan = WorkoutPlan.create(context: context)
        let exerciseID = UUID()
        var sources: [WorkoutRoutineExercise] = []
        for text in ["First plan cue", "Second plan cue"] {
            let source = WorkoutRoutineExercise.create(context: context)
            source.exerciseUuid = exerciseID
            source.comment = text
            sources.append(source)
        }
        routine.workoutRoutineExercises = NSOrderedSet(array: sources)
        let workout = routine.createWorkout(context: context)
        workout.start = Date(timeIntervalSince1970: 1_700_000_000)
        workout.isCurrentWorkout = true
        let logged = try XCTUnwrap(workout.workoutExercises?.array as? [WorkoutExercise])
        try context.save()
        workout.persistRoutineNoteLinks(defaults: defaults)
        workout.workoutExercises = NSOrderedSet(array: Array(logged.reversed()))
        XCTAssertEqual(logged[0].routineNoteSource(defaults: defaults)?.comment, "First plan cue")
        XCTAssertEqual(logged[1].routineNoteSource(defaults: defaults)?.comment, "Second plan cue")
        sources[0].comment = "Updated plan cue"
        XCTAssertEqual(logged[0].routineNoteSource(defaults: defaults)?.comment, "Updated plan cue")
        logged[0].exerciseUuid = UUID()
        XCTAssertNil(logged[0].routineNoteSource(defaults: defaults))
    }
}
