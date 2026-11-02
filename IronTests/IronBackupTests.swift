//
//  IronBackupTests.swift
//  IronTests
//
//  Created by Karim Abou Zeid on 25.03.20.
//  Copyright © 2020 Karim Abou Zeid Software. All rights reserved.
//

import XCTest
import CoreData
import WorkoutDataKit
import UIKit
@testable import Iron

class IronBackupTests: XCTestCase {
    var persistenContainer: NSPersistentContainer!
    var userDefaults: UserDefaults!
    var exerciseStore: ExerciseStore!
    var customExercisesURL: URL!

    override func setUpWithError() throws {
        // reset test folder
        let testFolder = FileManager.default.temporaryDirectory.appendingPathComponent("test", isDirectory: true)
        if FileManager.default.fileExists(atPath: testFolder.path) {
            try! FileManager.default.removeItem(at: testFolder)
        }
        try! FileManager.default.createDirectory(at: testFolder, withIntermediateDirectories: true)
        
        // reset user defaults
        UserDefaults().removePersistentDomain(forName: "test")
        userDefaults = UserDefaults(suiteName: "test")
        
        // in memory persistent container
        persistenContainer = setUpInMemoryNSPersistentContainer()
        
        // exercise store in test folder
        customExercisesURL = testFolder.appendingPathComponent("custom_exercises.json")
        exerciseStore = ExerciseStore(customExercisesURL: customExercisesURL)
    }

    override func tearDownWithError() throws {
        persistenContainer.viewContext.reset()
        persistenContainer = nil
    }
    
    func testImportIronBackupV1() {
        let context = persistenContainer.viewContext
        
        let data = backupData(name: "v1")
        XCTAssertNoThrow(try IronBackup.restoreBackupData(data: data, managedObjectContext: context, exerciseStore: exerciseStore))
        
        let workoutRequest: NSFetchRequest<Workout> = Workout.fetchRequest()
        let workouts = try! context.fetch(workoutRequest)
        XCTAssertEqual(workouts.count, 209) // sanity check
        XCTAssertTrue(workouts.allSatisfy { $0.importSource == nil && $0.healthExportState == nil && !$0.isImported })
        
        XCTAssertEqual(exerciseStore.customExercises.count, 4) // sanity check
    }

    func testImportIronBackupV2() {
        let context = persistenContainer.viewContext
        
        let data = backupData(name: "v2")
        XCTAssertNoThrow(try IronBackup.restoreBackupData(data: data, managedObjectContext: context, exerciseStore: exerciseStore))
        
        let workoutRequest: NSFetchRequest<Workout> = Workout.fetchRequest()
        let workouts = try! context.fetch(workoutRequest)
        XCTAssertEqual(workouts.count, 246) // sanity check
        
        XCTAssertEqual(exerciseStore.customExercises.count, 5) // sanity check
    }
    
    func testImportIronBackupV3() {
        let context = persistenContainer.viewContext

        let data = backupData(name: "v3")
        XCTAssertNoThrow(try IronBackup.restoreBackupData(data: data, managedObjectContext: context, exerciseStore: exerciseStore))

        let workoutRequest: NSFetchRequest<Workout> = Workout.fetchRequest()
        let workouts = try! context.fetch(workoutRequest)
        XCTAssertEqual(workouts.count, 246) // sanity check
        
        let workoutPlanRequest: NSFetchRequest<WorkoutPlan> = WorkoutPlan.fetchRequest()
        let workoutPlans = try! context.fetch(workoutPlanRequest)
        XCTAssertEqual(workoutPlans.count, 1) // sanity check
        
        XCTAssertEqual(exerciseStore.customExercises.count, 5) // sanity check
    }
    
    func testExportIronBackup() {
        let context = persistenContainer.viewContext
        createTestWorkoutData(context: context)
        try! context.save()
        
        XCTAssertNoThrow(try IronBackup.createBackupData(
            managedObjectContext: context,
            exerciseStore: exerciseStore,
            userDefaults: userDefaults
        ))
    }

    func testBackupRoundTripPreservesWorkoutProvenanceAndHealthState() throws {
        let context = persistenContainer.viewContext
        let values: [(String?, String?)] = [("hevy", nil), ("sample", nil), ("json", nil),
                                           (nil, nil), (nil, "pending"), (nil, "exported"), (nil, "watch")]
        var expected: [UUID: (String?, String?)] = [:]
        for (source, state) in values {
            let workout = Workout.create(context: context)
            workout.importSource = source
            workout.healthExportState = state
            workout.start = Date(timeIntervalSince1970: 1_000)
            workout.end = Date(timeIntervalSince1970: 2_000)
            expected[try XCTUnwrap(workout.uuid)] = (source, state)
        }
        try context.save()
        let data = try IronBackup.createBackupData(
            managedObjectContext: context, exerciseStore: exerciseStore, userDefaults: userDefaults
        )
        try IronBackup.restoreBackupData(
            data: data, managedObjectContext: context,
            exerciseStore: exerciseStore, userDefaults: userDefaults
        )
        let freshContext = persistenContainer.newBackgroundContext()
        try freshContext.performAndWait {
            let restored = try freshContext.fetch(Workout.fetchRequest())
            XCTAssertEqual(restored.count, values.count)
            for workout in restored {
                let value = try XCTUnwrap(expected[try XCTUnwrap(workout.uuid)])
                XCTAssertEqual(workout.importSource, value.0)
                XCTAssertEqual(workout.healthExportState, value.1)
            }
        }
    }

    func testExportAndRestoreBodyMeasurements() throws {
        let context = persistenContainer.viewContext
        let original = BodyMeasurementEntry(
            date: Date(timeIntervalSince1970: 1_720_000_000),
            values: [
                BodyMeasurementKind.bodyWeight.rawValue: 82.4,
                BodyMeasurementKind.waist.rawValue: 81.2
            ]
        )
        let measurementData = try JSONEncoder().encode([original])
        userDefaults.set(measurementData, forKey: IronBackup.bodyMeasurementsStorageKey)

        let backupData = try IronBackup.createBackupData(
            managedObjectContext: context,
            exerciseStore: exerciseStore,
            userDefaults: userDefaults
        )
        userDefaults.removeObject(forKey: IronBackup.bodyMeasurementsStorageKey)

        try IronBackup.restoreBackupData(
            data: backupData,
            managedObjectContext: context,
            exerciseStore: exerciseStore,
            userDefaults: userDefaults
        )

        let restoredStore = BodyMetricsStore(userDefaults: userDefaults)
        XCTAssertEqual(restoredStore.entries, [original])
    }

    func testCustomExerciseInstructionsPersistAcrossCreateAndUpdate() throws {
        let created = try exerciseStore.createCustomExercise(
            title: "Test Split Squat",
            description: "A stable unilateral squat.",
            primaryMuscle: ["quadriceps"],
            secondaryMuscle: ["glutes"],
            type: .dumbbell,
            steps: ["Stand in a split stance.", "Lower under control."],
            tips: ["Keep the front foot planted."]
        )

        XCTAssertEqual(created.steps, ["Stand in a split stance.", "Lower under control."])
        XCTAssertEqual(created.tips, ["Keep the front foot planted."])

        let updated = try exerciseStore.updateCustomExercise(
            with: created.uuid,
            title: "Test Rear-Foot-Elevated Split Squat",
            description: "Rear foot elevated.",
            primaryMuscle: ["quadriceps"],
            secondaryMuscle: ["glutes", "hamstrings"],
            type: .dumbbell,
            steps: ["Elevate the rear foot.", "Descend until the front thigh is parallel."],
            tips: ["Brace before each rep.", "Drive through the full front foot."]
        )

        XCTAssertEqual(updated.title, "Test Rear-Foot-Elevated Split Squat")
        XCTAssertEqual(updated.steps.count, 2)
        XCTAssertEqual(updated.tips.count, 2)

        let reloadedStore = ExerciseStore(customExercisesURL: customExercisesURL)
        let reloaded = try XCTUnwrap(reloadedStore.find(with: created.uuid))
        XCTAssertEqual(reloaded, updated)

        let deleted = try reloadedStore.deleteCustomExercise(with: created.uuid)
        XCTAssertEqual(deleted, updated)
        let afterDeletionStore = ExerciseStore(customExercisesURL: customExercisesURL)
        XCTAssertNil(afterDeletionStore.find(with: created.uuid))
    }

    func testCustomExerciseMutationReportsPersistenceFailures() {
        let unavailableStore = ExerciseStore(customExercisesURL: nil)

        XCTAssertThrowsError(
            try unavailableStore.createCustomExercise(
                title: "Unsaved Exercise",
                description: nil,
                primaryMuscle: ["quadriceps"],
                secondaryMuscle: [],
                type: .other
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                ExerciseStore.CustomExerciseMutationError.storageUnavailable.localizedDescription
            )
        }
        XCTAssertTrue(unavailableStore.customExercises.isEmpty)
    }

    func testRejectsFutureBackupVersionBeforeChangingStores() throws {
        let originalMeasurements = Data("original".utf8)
        userDefaults.set(originalMeasurements, forKey: IronBackup.bodyMeasurementsStorageKey)
        let data = try modifiedBackupData { $0["version"] = 999 }

        XCTAssertThrowsError(try IronBackup.restoreBackupData(
            data: data,
            managedObjectContext: persistenContainer.viewContext,
            exerciseStore: exerciseStore,
            userDefaults: userDefaults
        ))

        XCTAssertEqual(userDefaults.data(forKey: IronBackup.bodyMeasurementsStorageKey), originalMeasurements)
        XCTAssertTrue(exerciseStore.customExercises.isEmpty)
        XCTAssertFalse(persistenContainer.viewContext.hasChanges)
    }

    func testRejectsInvalidBodyMeasurementPayload() throws {
        let invalidMeasurements: [[String: Any]] = [[
            "id": UUID().uuidString,
            "date": 1_000.0,
            "values": ["bodyWeight": -1.0]
        ]]
        let measurementData = try JSONSerialization.data(withJSONObject: invalidMeasurements)
        let data = try modifiedBackupData {
            $0["bodyMeasurementsData"] = measurementData.base64EncodedString()
        }

        XCTAssertThrowsError(try IronBackup.restoreBackupData(
            data: data,
            managedObjectContext: persistenContainer.viewContext,
            exerciseStore: exerciseStore,
            userDefaults: userDefaults
        ))
        XCTAssertFalse(persistenContainer.viewContext.hasChanges)
    }

    func testMeasurementValidationAcceptsNumericOneAndReferenceDateZero() throws {
        let measurements: [[String: Any]] = [[
            "id": UUID().uuidString,
            "date": 0.0,
            "values": ["bodyWeight": 1.0]
        ]]
        let measurementData = try JSONSerialization.data(withJSONObject: measurements)
        let data = try modifiedBackupData {
            $0["bodyMeasurementsData"] = measurementData.base64EncodedString()
        }

        XCTAssertNoThrow(try IronBackup.restoreBackupData(
            data: data,
            managedObjectContext: persistenContainer.viewContext,
            exerciseStore: exerciseStore,
            userDefaults: userDefaults
        ))
        XCTAssertEqual(
            userDefaults.data(forKey: IronBackup.bodyMeasurementsStorageKey),
            measurementData
        )
    }

    func testMeasurementValidationRejectsBooleanDateAndValues() throws {
        let invalidMeasurements: [[[String: Any]]] = [
            [[
                "id": UUID().uuidString,
                "date": true,
                "values": ["bodyWeight": 80.0]
            ]],
            [[
                "id": UUID().uuidString,
                "date": 0.0,
                "values": ["bodyWeight": true]
            ]]
        ]

        for measurements in invalidMeasurements {
            let measurementData = try JSONSerialization.data(withJSONObject: measurements)
            let data = try modifiedBackupData {
                $0["bodyMeasurementsData"] = measurementData.base64EncodedString()
            }
            XCTAssertThrowsError(try IronBackup.restoreBackupData(
                data: data,
                managedObjectContext: persistenContainer.viewContext,
                exerciseStore: exerciseStore,
                userDefaults: userDefaults
            ))
            XCTAssertFalse(persistenContainer.viewContext.hasChanges)
        }
    }

    func testRejectsDuplicateCustomExerciseIdentifiers() throws {
        _ = try exerciseStore.createCustomExercise(
            title: "Duplicate Candidate",
            description: nil,
            primaryMuscle: ["quadriceps"],
            secondaryMuscle: [],
            type: .other
        )
        let data = try modifiedBackupData { object in
            var exercises = object["customExercises"] as! [[String: Any]]
            exercises.append(exercises[0])
            object["customExercises"] = exercises
        }

        XCTAssertThrowsError(try IronBackup.restoreBackupData(
            data: data,
            managedObjectContext: persistenContainer.viewContext,
            exerciseStore: exerciseStore,
            userDefaults: userDefaults
        ))
        XCTAssertEqual(exerciseStore.customExercises.count, 1)
        XCTAssertFalse(persistenContainer.viewContext.hasChanges)
    }

    func testTrackingPreferencesRoundTripAndLegacyArchiveCompatibility() throws {
        let exerciseID = UUID(), setID = UUID()
        SetTrackingPreferences.setOverride(.distanceDuration, for: exerciseID, defaults: userDefaults)
        SetTrackingPreferences.setRoutineDistance(1_000, for: setID, defaults: userDefaults)
        let data = try IronBackup.createBackupData(managedObjectContext: persistenContainer.viewContext,
            exerciseStore: exerciseStore, userDefaults: userDefaults, trackingDefaults: userDefaults)
        SetTrackingPreferences.setOverride(.weightReps, for: exerciseID, defaults: userDefaults)
        SetTrackingPreferences.setRoutineDistance(2_000, for: setID, defaults: userDefaults)
        try IronBackup.restoreBackupData(data: data, managedObjectContext: persistenContainer.viewContext,
            exerciseStore: exerciseStore, userDefaults: userDefaults, trackingDefaults: userDefaults)
        XCTAssertEqual(SetTrackingPreferences.override(for: exerciseID, defaults: userDefaults), .distanceDuration)
        XCTAssertEqual(SetTrackingPreferences.routineDistance(for: setID, defaults: userDefaults), 1_000)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy["version"] = 4
        legacy.removeValue(forKey: "trackingPreferences")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let previous = SetTrackingPreferences.load(defaults: userDefaults)
        try IronBackup.restoreBackupData(data: legacyData, managedObjectContext: persistenContainer.viewContext,
            exerciseStore: exerciseStore, userDefaults: userDefaults, trackingDefaults: userDefaults)
        XCTAssertEqual(SetTrackingPreferences.load(defaults: userDefaults), previous)
    }

    func testFailedBackupSaveDoesNotPublishTrackingPreferences() throws {
        let exerciseID = UUID()
        SetTrackingPreferences.setOverride(.distanceDuration, for: exerciseID, defaults: userDefaults)
        let data = try IronBackup.createBackupData(managedObjectContext: persistenContainer.viewContext,
            exerciseStore: exerciseStore, userDefaults: userDefaults, trackingDefaults: userDefaults)
        SetTrackingPreferences.setOverride(.weightReps, for: exerciseID, defaults: userDefaults)
        let previous = SetTrackingPreferences.load(defaults: userDefaults)
        enum SaveFailure: Error { case expected }
        XCTAssertThrowsError(try IronBackup.restoreBackupData(data: data,
            managedObjectContext: persistenContainer.viewContext, exerciseStore: exerciseStore,
            userDefaults: userDefaults, trackingDefaults: userDefaults,
            saveParent: { _ in throw SaveFailure.expected }))
        XCTAssertEqual(SetTrackingPreferences.load(defaults: userDefaults), previous)
    }

    func testRestoreRetainsActiveWorkoutTrackingOverride() throws {
        let exerciseID = UUID()
        SetTrackingPreferences.setOverride(.distanceDuration, for: exerciseID, defaults: userDefaults)
        let data = try IronBackup.createBackupData(managedObjectContext: persistenContainer.viewContext,
            exerciseStore: exerciseStore, userDefaults: userDefaults, trackingDefaults: userDefaults)
        let context = persistenContainer.viewContext
        let active = Workout.create(context: context)
        active.isCurrentWorkout = true
        active.start = Date()
        let exercise = WorkoutExercise.create(context: context)
        exercise.exerciseUuid = exerciseID
        active.workoutExercises = NSOrderedSet(array: [exercise])
        try context.save()
        SetTrackingPreferences.setOverride(.weightReps, for: exerciseID, defaults: userDefaults)
        try IronBackup.restoreBackupData(data: data, managedObjectContext: context,
            exerciseStore: exerciseStore, userDefaults: userDefaults, trackingDefaults: userDefaults)
        XCTAssertEqual(SetTrackingPreferences.override(for: exerciseID, defaults: userDefaults), .weightReps)
        XCTAssertTrue(active.isCurrentWorkout)
        XCTAssertFalse(active.isDeleted)
    }

    func testExerciseNotesAndRoutineLinksRoundTripWithoutRevivingDeletedNotes() throws {
        let exerciseID = UUID(), deletedExerciseID = UUID(), unrelatedExerciseID = UUID()
        let loggedExerciseID = UUID(), routineExerciseID = UUID(), otherLoggedID = UUID(), otherRoutineID = UUID()
        ExerciseNotes.setNote("Archived cue", for: exerciseID,
            updatedAt: Date(timeIntervalSince1970: 100), defaults: userDefaults)
        ExerciseNotes.setNote("Delete this cue", for: deletedExerciseID,
            updatedAt: Date(timeIntervalSince1970: 100), defaults: userDefaults)
        ExerciseNotes.setNote(nil, for: deletedExerciseID,
            updatedAt: Date(timeIntervalSince1970: 200), defaults: userDefaults)
        WorkoutRoutineNoteLinks.setRoutineExerciseID(routineExerciseID, for: loggedExerciseID, defaults: userDefaults)
        let archivedNotes = ExerciseNotes.load(defaults: userDefaults)
        let data = try IronBackup.createBackupData(managedObjectContext: persistenContainer.viewContext,
            exerciseStore: exerciseStore, userDefaults: userDefaults,
            trackingDefaults: userDefaults, notesDefaults: userDefaults)
        let archive = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(archive["version"] as? Int, 6)
        XCTAssertNotNil(archive["exerciseNotes"])
        XCTAssertNotNil(archive["routineNoteLinks"])

        ExerciseNotes.setNote("Newer local cue", for: exerciseID,
            updatedAt: Date(timeIntervalSince1970: 300), defaults: userDefaults)
        ExerciseNotes.setNote("Newer local cue", for: deletedExerciseID,
            updatedAt: Date(timeIntervalSince1970: 300), defaults: userDefaults)
        ExerciseNotes.setNote("Keep this unrelated cue", for: unrelatedExerciseID,
            updatedAt: Date(timeIntervalSince1970: 300), defaults: userDefaults)
        let beforeRestore = ExerciseNotes.load(defaults: userDefaults)
        WorkoutRoutineNoteLinks.setRoutineExerciseID(otherRoutineID, for: loggedExerciseID, defaults: userDefaults)
        WorkoutRoutineNoteLinks.setRoutineExerciseID(otherRoutineID, for: otherLoggedID, defaults: userDefaults)

        try IronBackup.restoreBackupData(data: data, managedObjectContext: persistenContainer.viewContext,
            exerciseStore: exerciseStore, userDefaults: userDefaults,
            trackingDefaults: userDefaults, notesDefaults: userDefaults)
        let restored = ExerciseNotes.load(defaults: userDefaults)
        XCTAssertEqual(ExerciseNotes.note(for: exerciseID, defaults: userDefaults), "Archived cue")
        XCTAssertNil(ExerciseNotes.note(for: deletedExerciseID, defaults: userDefaults))
        XCTAssertEqual(ExerciseNotes.note(for: unrelatedExerciseID, defaults: userDefaults), "Keep this unrelated cue")
        XCTAssertNotNil(restored.entries[deletedExerciseID.uuidString])
        XCTAssertGreaterThan(try XCTUnwrap(restored.entries[exerciseID.uuidString]?.updatedAt), 300)
        XCTAssertEqual(restored.merging(beforeRestore).merging(archivedNotes), restored)
        XCTAssertEqual(WorkoutRoutineNoteLinks.routineExerciseID(for: loggedExerciseID, defaults: userDefaults), routineExerciseID)
        XCTAssertEqual(WorkoutRoutineNoteLinks.routineExerciseID(for: otherLoggedID, defaults: userDefaults), otherRoutineID)
    }

    func testLegacyBackupWithoutExerciseNotesPreservesCurrentMetadata() throws {
        let exerciseID = UUID(), loggedExerciseID = UUID(), routineExerciseID = UUID()
        ExerciseNotes.setNote("Current cue", for: exerciseID, defaults: userDefaults)
        WorkoutRoutineNoteLinks.setRoutineExerciseID(routineExerciseID, for: loggedExerciseID, defaults: userDefaults)
        let notes = ExerciseNotes.load(defaults: userDefaults)
        let links = WorkoutRoutineNoteLinks.load(defaults: userDefaults)
        let currentData = try IronBackup.createBackupData(managedObjectContext: persistenContainer.viewContext,
            exerciseStore: exerciseStore, userDefaults: userDefaults,
            trackingDefaults: userDefaults, notesDefaults: userDefaults)
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: currentData) as? [String: Any])
        archive["version"] = 5
        archive.removeValue(forKey: "exerciseNotes")
        archive.removeValue(forKey: "routineNoteLinks")
        let data = try JSONSerialization.data(withJSONObject: archive)

        try IronBackup.restoreBackupData(data: data, managedObjectContext: persistenContainer.viewContext,
            exerciseStore: exerciseStore, userDefaults: userDefaults,
            trackingDefaults: userDefaults, notesDefaults: userDefaults)
        XCTAssertEqual(ExerciseNotes.load(defaults: userDefaults), notes)
        XCTAssertEqual(WorkoutRoutineNoteLinks.load(defaults: userDefaults), links)
    }

    func testFailedBackupSaveDoesNotPublishExerciseNoteMetadata() throws {
        let exerciseID = UUID(), loggedExerciseID = UUID(), routineExerciseID = UUID()
        ExerciseNotes.setNote("Archived cue", for: exerciseID, defaults: userDefaults)
        WorkoutRoutineNoteLinks.setRoutineExerciseID(routineExerciseID, for: loggedExerciseID, defaults: userDefaults)
        let data = try IronBackup.createBackupData(managedObjectContext: persistenContainer.viewContext,
            exerciseStore: exerciseStore, userDefaults: userDefaults,
            trackingDefaults: userDefaults, notesDefaults: userDefaults)
        ExerciseNotes.setNote("Current cue", for: exerciseID,
            updatedAt: Date().addingTimeInterval(1), defaults: userDefaults)
        WorkoutRoutineNoteLinks.setRoutineExerciseID(nil, for: loggedExerciseID, defaults: userDefaults)
        let notes = ExerciseNotes.load(defaults: userDefaults)
        let links = WorkoutRoutineNoteLinks.load(defaults: userDefaults)
        enum SaveFailure: Error { case expected }

        XCTAssertThrowsError(try IronBackup.restoreBackupData(data: data,
            managedObjectContext: persistenContainer.viewContext, exerciseStore: exerciseStore,
            userDefaults: userDefaults, trackingDefaults: userDefaults, notesDefaults: userDefaults,
            saveParent: { _ in throw SaveFailure.expected }))
        XCTAssertEqual(ExerciseNotes.load(defaults: userDefaults), notes)
        XCTAssertEqual(WorkoutRoutineNoteLinks.load(defaults: userDefaults), links)
    }

    func testInvalidExerciseNoteMetadataIsRejectedBeforeChangingStores() throws {
        let exerciseID = UUID()
        ExerciseNotes.setNote("Current cue", for: exerciseID, defaults: userDefaults)
        let notes = ExerciseNotes.load(defaults: userDefaults)
        let invalidMetadata: [(String, [String: Any])] = [
            ("exerciseNotes", ["entries": ["invalid": ["text": "Cue", "updatedAt": 100]]]),
            ("exerciseNotes", ["entries": [exerciseID.uuidString: ["text": "Cue", "updatedAt": -1]]]),
            ("routineNoteLinks", ["links": [UUID().uuidString: "invalid"]])
        ]
        for (key, value) in invalidMetadata {
            let data = try modifiedBackupData { $0[key] = value }
            XCTAssertThrowsError(try IronBackup.restoreBackupData(data: data,
                managedObjectContext: persistenContainer.viewContext, exerciseStore: exerciseStore,
                userDefaults: userDefaults, trackingDefaults: userDefaults, notesDefaults: userDefaults))
            XCTAssertEqual(ExerciseNotes.load(defaults: userDefaults), notes)
            XCTAssertFalse(persistenContainer.viewContext.hasChanges)
        }
    }

    func testVersionFourWithoutMeasurementsClearsCurrentMeasurements() throws {
        let data = try IronBackup.createBackupData(
            managedObjectContext: persistenContainer.viewContext,
            exerciseStore: exerciseStore,
            userDefaults: userDefaults
        )
        userDefaults.set(Data("current".utf8), forKey: IronBackup.bodyMeasurementsStorageKey)

        try IronBackup.restoreBackupData(
            data: data,
            managedObjectContext: persistenContainer.viewContext,
            exerciseStore: exerciseStore,
            userDefaults: userDefaults
        )

        XCTAssertNil(userDefaults.data(forKey: IronBackup.bodyMeasurementsStorageKey))
    }

    func testLegacyBackupWithoutMeasurementsPreservesCurrentMeasurements() throws {
        let data = try modifiedBackupData {
            $0["version"] = 3
            $0.removeValue(forKey: "bodyMeasurementsData")
        }
        let currentMeasurements = Data("current".utf8)
        userDefaults.set(currentMeasurements, forKey: IronBackup.bodyMeasurementsStorageKey)

        try IronBackup.restoreBackupData(
            data: data,
            managedObjectContext: persistenContainer.viewContext,
            exerciseStore: exerciseStore,
            userDefaults: userDefaults
        )

        XCTAssertEqual(userDefaults.data(forKey: IronBackup.bodyMeasurementsStorageKey), currentMeasurements)
    }

    func testRejectsImportedSetIdentifierCollisionWithRetainedCurrentWorkout() throws {
        let context = persistenContainer.viewContext
        let currentWorkout = createTestCurrentWorkout(context: context)
        try context.save()
        let retainedExercise = try XCTUnwrap(
            currentWorkout.workoutExercises?.firstObject as? WorkoutExercise
        )
        let retainedSet = try XCTUnwrap(retainedExercise.workoutSets?.firstObject as? WorkoutSet)
        let retainedSetID = try XCTUnwrap(retainedSet.uuid)

        let sourceContainer = setUpInMemoryNSPersistentContainer()
        createTestWorkoutData(context: sourceContainer.viewContext)
        let sourceWorkout = try XCTUnwrap(
            try sourceContainer.viewContext.fetch(Workout.fetchRequest()).first
        )
        let sourceExercise = try XCTUnwrap(
            sourceWorkout.workoutExercises?.firstObject as? WorkoutExercise
        )
        let sourceSet = try XCTUnwrap(sourceExercise.workoutSets?.firstObject as? WorkoutSet)
        sourceSet.uuid = retainedSetID
        try sourceContainer.viewContext.save()
        let data = try IronBackup.createBackupData(
            managedObjectContext: sourceContainer.viewContext,
            exerciseStore: exerciseStore,
            userDefaults: userDefaults
        )

        XCTAssertThrowsError(try IronBackup.restoreBackupData(
            data: data,
            managedObjectContext: context,
            exerciseStore: exerciseStore,
            userDefaults: userDefaults
        ))

        let fetchedCurrent = try context.fetch(Workout.currentWorkoutFetchRequest)
        XCTAssertEqual(fetchedCurrent, [currentWorkout])
        XCTAssertEqual(retainedSet.uuid, retainedSetID)
        XCTAssertEqual(retainedSet.workoutExercise, retainedExercise)
        XCTAssertFalse(context.hasChanges)
    }

    func testFailedParentSaveRestoresImportedGraphAndExternalStoresOnly() throws {
        struct ExpectedError: Error {}
        let context = persistenContainer.viewContext
        createTestWorkoutData(context: context)
        let currentWorkout = createTestCurrentWorkout(context: context)
        try context.save()
        let originalWorkoutCount = try context.count(for: Workout.fetchRequest())
        let originalExerciseCount = try context.count(for: WorkoutExercise.fetchRequest())
        currentWorkout.title = "Pending user edit"

        let originalExercise = try exerciseStore.createCustomExercise(
            title: "Original custom exercise",
            description: nil,
            primaryMuscle: ["back"],
            secondaryMuscle: [],
            type: .other
        )
        let originalMeasurements = Data("original measurements".utf8)
        userDefaults.set(originalMeasurements, forKey: IronBackup.bodyMeasurementsStorageKey)

        let sourceContainer = setUpInMemoryNSPersistentContainer()
        createTestWorkoutData(context: sourceContainer.viewContext)
        try sourceContainer.viewContext.save()
        let sourceFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceFolder) }
        let sourceStore = ExerciseStore(
            customExercisesURL: sourceFolder.appendingPathComponent("custom.json")
        )
        _ = try sourceStore.createCustomExercise(
            title: "Imported custom exercise",
            description: nil,
            primaryMuscle: ["chest"],
            secondaryMuscle: [],
            type: .other
        )
        let sourceDefaultsName = "backup-source-\(UUID().uuidString)"
        let sourceDefaults = UserDefaults(suiteName: sourceDefaultsName)!
        defer { sourceDefaults.removePersistentDomain(forName: sourceDefaultsName) }
        let importedMeasurements: [[String: Any]] = [[
            "id": UUID().uuidString,
            "date": 1_000.0,
            "values": ["bodyWeight": 80.0]
        ]]
        sourceDefaults.set(
            try JSONSerialization.data(withJSONObject: importedMeasurements),
            forKey: IronBackup.bodyMeasurementsStorageKey
        )
        let data = try IronBackup.createBackupData(
            managedObjectContext: sourceContainer.viewContext,
            exerciseStore: sourceStore,
            userDefaults: sourceDefaults
        )

        var injectedSaveWasCalled = false
        XCTAssertThrowsError(try IronBackup.restoreBackupData(
            data: data,
            managedObjectContext: context,
            exerciseStore: exerciseStore,
            userDefaults: userDefaults,
            saveParent: { _ in
                injectedSaveWasCalled = true
                throw ExpectedError()
            }
        ))

        XCTAssertTrue(injectedSaveWasCalled)
        XCTAssertEqual(try context.count(for: Workout.fetchRequest()), originalWorkoutCount)
        XCTAssertEqual(try context.count(for: WorkoutExercise.fetchRequest()), originalExerciseCount)
        XCTAssertEqual(currentWorkout.title, "Pending user edit")
        XCTAssertEqual(exerciseStore.customExercises, [originalExercise])
        XCTAssertEqual(userDefaults.data(forKey: IronBackup.bodyMeasurementsStorageKey), originalMeasurements)
        XCTAssertTrue(context.hasChanges)
        XCTAssertTrue(context.insertedObjects.isEmpty)
        XCTAssertTrue(context.deletedObjects.isEmpty)
    }

    func testRestoreRetainsCustomDefinitionReferencedByCurrentWorkout() throws {
        let context = persistenContainer.viewContext
        let unreferenced = try exerciseStore.createCustomExercise(
            title: "Old unreferenced definition",
            description: nil,
            primaryMuscle: [],
            secondaryMuscle: [],
            type: .other
        )
        let retained = try exerciseStore.createCustomExercise(
            title: "Active custom exercise",
            description: "Used by the active workout",
            primaryMuscle: ["back"],
            secondaryMuscle: [],
            type: .other
        )
        let currentWorkout = createTestCurrentWorkout(context: context)
        let currentExercise = try XCTUnwrap(
            currentWorkout.workoutExercises?.firstObject as? WorkoutExercise
        )
        currentExercise.exerciseUuid = retained.uuid
        try context.save()
        let (data, archived) = try backupWithSingleCustomExercise(title: "Archived exercise")

        try IronBackup.restoreBackupData(
            data: data,
            managedObjectContext: context,
            exerciseStore: exerciseStore,
            userDefaults: userDefaults
        )

        XCTAssertEqual(exerciseStore.customExercises.map(\.uuid), [archived.uuid, retained.uuid])
        XCTAssertEqual(currentExercise.exerciseUuid, retained.uuid)
        let reloaded = ExerciseStore(customExercisesURL: customExercisesURL)
        XCTAssertEqual(reloaded.customExercises.map(\.uuid), [archived.uuid, retained.uuid])
        XCTAssertEqual(reloaded.find(with: retained.uuid), retained)
        XCTAssertNil(reloaded.find(with: unreferenced.uuid))
    }

    func testRestoreDeduplicatesIdenticalCurrentCustomDefinition() throws {
        let context = persistenContainer.viewContext
        let retained = try exerciseStore.createCustomExercise(
            title: "Shared active definition",
            description: "Identical in backup",
            primaryMuscle: ["quadriceps"],
            secondaryMuscle: ["glutes"],
            type: .dumbbell
        )
        let currentWorkout = createTestCurrentWorkout(context: context)
        let currentExercise = try XCTUnwrap(
            currentWorkout.workoutExercises?.firstObject as? WorkoutExercise
        )
        currentExercise.exerciseUuid = retained.uuid
        try context.save()
        let data = try IronBackup.createBackupData(
            managedObjectContext: context,
            exerciseStore: exerciseStore,
            userDefaults: userDefaults
        )

        try IronBackup.restoreBackupData(
            data: data,
            managedObjectContext: context,
            exerciseStore: exerciseStore,
            userDefaults: userDefaults
        )

        XCTAssertEqual(exerciseStore.customExercises, [retained])
        XCTAssertEqual(ExerciseStore(customExercisesURL: customExercisesURL).customExercises, [retained])
    }

    func testRestoreRejectsConflictingCurrentCustomDefinitionBeforeAnyWrite() throws {
        let context = persistenContainer.viewContext
        let retained = try exerciseStore.createCustomExercise(
            title: "Original active definition",
            description: "Must not change",
            primaryMuscle: ["chest"],
            secondaryMuscle: [],
            type: .barbell
        )
        let currentWorkout = createTestCurrentWorkout(context: context)
        let currentExercise = try XCTUnwrap(
            currentWorkout.workoutExercises?.firstObject as? WorkoutExercise
        )
        currentExercise.exerciseUuid = retained.uuid
        let oldWorkout = Workout.create(context: context)
        oldWorkout.title = "Existing history"
        oldWorkout.start = Date(timeIntervalSinceReferenceDate: 1_000)
        oldWorkout.end = Date(timeIntervalSinceReferenceDate: 2_000)
        oldWorkout.isCurrentWorkout = false
        try context.save()
        let originalCustomFile = try Data(contentsOf: customExercisesURL)
        let originalMeasurements = try JSONEncoder().encode([
            BodyMeasurementEntry(
                date: Date(timeIntervalSince1970: 1_720_000_000),
                values: [BodyMeasurementKind.bodyWeight.rawValue: 82.4]
            )
        ])
        userDefaults.set(originalMeasurements, forKey: IronBackup.bodyMeasurementsStorageKey)
        var data = try IronBackup.createBackupData(
            managedObjectContext: context,
            exerciseStore: exerciseStore,
            userDefaults: userDefaults
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var customExercises = try XCTUnwrap(object["customExercises"] as? [[String: Any]])
        guard customExercises.count == 1 else {
            return XCTFail("Expected exactly one archived custom definition")
        }
        customExercises[0]["title"] = "Conflicting archived definition"
        object["customExercises"] = customExercises
        data = try JSONSerialization.data(withJSONObject: object)
        currentWorkout.title = "Unrelated pending edit"

        XCTAssertThrowsError(try IronBackup.restoreBackupData(
            data: data,
            managedObjectContext: context,
            exerciseStore: exerciseStore,
            userDefaults: userDefaults
        )) { error in
            guard let validationError = error as? IronBackup.RestoreValidationError,
                  case .conflictingRetainedCustomExercise(let identifier) = validationError else {
                XCTFail("Expected retained custom-exercise conflict, got \(error)")
                return
            }
            XCTAssertEqual(identifier, retained.uuid)
        }

        XCTAssertEqual(try Data(contentsOf: customExercisesURL), originalCustomFile)
        XCTAssertEqual(exerciseStore.customExercises, [retained])
        XCTAssertEqual(userDefaults.data(forKey: IronBackup.bodyMeasurementsStorageKey), originalMeasurements)
        XCTAssertEqual(currentWorkout.title, "Unrelated pending edit")
        XCTAssertFalse(oldWorkout.isDeleted)
        XCTAssertEqual(oldWorkout.title, "Existing history")
        XCTAssertTrue(context.hasChanges)
        XCTAssertTrue(context.insertedObjects.isEmpty)
        XCTAssertTrue(context.deletedObjects.isEmpty)
    }

    func testRestoreWithoutCurrentWorkoutStillReplacesOldCustomDefinitions() throws {
        let old = try exerciseStore.createCustomExercise(
            title: "Old unreferenced exercise",
            description: nil,
            primaryMuscle: ["back"],
            secondaryMuscle: [],
            type: .other
        )
        let (data, archived) = try backupWithSingleCustomExercise(title: "Archived replacement")

        try IronBackup.restoreBackupData(
            data: data,
            managedObjectContext: persistenContainer.viewContext,
            exerciseStore: exerciseStore,
            userDefaults: userDefaults
        )

        XCTAssertEqual(exerciseStore.customExercises, [archived])
        XCTAssertNil(exerciseStore.find(with: old.uuid))
        XCTAssertEqual(ExerciseStore(customExercisesURL: customExercisesURL).customExercises, [archived])
    }

    private func backupWithSingleCustomExercise(title: String) throws -> (Data, Exercise) {
        let sourceContainer = setUpInMemoryNSPersistentContainer()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-custom-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ExerciseStore(customExercisesURL: folder.appendingPathComponent("custom.json"))
        let exercise = try store.createCustomExercise(
            title: title,
            description: "Archived definition",
            primaryMuscle: ["shoulders"],
            secondaryMuscle: [],
            type: .dumbbell
        )
        let data = try IronBackup.createBackupData(
            managedObjectContext: sourceContainer.viewContext,
            exerciseStore: store,
            userDefaults: userDefaults
        )
        return (data, exercise)
    }

    private func modifiedBackupData(
        _ mutation: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        let data = try IronBackup.createBackupData(
            managedObjectContext: persistenContainer.viewContext,
            exerciseStore: exerciseStore,
            userDefaults: userDefaults
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        try mutation(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }
}

final class AutomaticBackupCoordinatorTests: XCTestCase {
    @MainActor
    func testCapturesBeforeAsyncWriteAndCoalescesOverlappingRequests() async {
        let finished = expectation(description: "Background task ended")
        var events: [String] = []
        var complete: ((Result<URL, Error>) -> Void)?
        let coordinator = AutomaticBackupCoordinator(
            write: { data, completion in
                XCTAssertEqual(data, Data([1, 2, 3]))
                events.append("write")
                complete = completion
            },
            begin: { _ in events.append("begin"); return UIBackgroundTaskIdentifier(rawValue: 1) },
            end: { _ in events.append("end"); finished.fulfill() }
        )
        coordinator.start { events.append("capture"); return Data([1, 2, 3]) }
        coordinator.start { XCTFail("Overlapping backup must be coalesced"); return Data() }
        XCTAssertEqual(events, ["begin", "capture", "write"])
        complete?(.success(URL(fileURLWithPath: "/tmp/test.ironbackup")))
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(events.last, "end")
    }

    @MainActor
    func testCaptureFailureEndsTaskWithoutWritingAndAllowsRetry() {
        struct Failure: Error {}
        var endCount = 0
        let coordinator = AutomaticBackupCoordinator(
            write: { _, _ in XCTFail("Failed snapshot cannot be written") },
            begin: { _ in UIBackgroundTaskIdentifier(rawValue: 1) },
            end: { _ in endCount += 1 }
        )
        coordinator.start { throw Failure() }
        coordinator.start { throw Failure() }
        XCTAssertEqual(endCount, 2)
    }

    @MainActor
    func testWriteFailureEndsBackgroundTask() async {
        struct Failure: Error {}
        let finished = expectation(description: "Failed write ended")
        let coordinator = AutomaticBackupCoordinator(
            write: { _, completion in completion(.failure(Failure())) },
            begin: { _ in UIBackgroundTaskIdentifier(rawValue: 1) },
            end: { _ in finished.fulfill() }
        )
        coordinator.start { Data() }
        await fulfillment(of: [finished], timeout: 2)
    }

    @MainActor
    func testExpirationDoesNotAllowAnOlderWriteToRaceANewerBackup() async {
        let expired = expectation(description: "Background time ended")
        var expire: (() -> Void)?
        var complete: ((Result<URL, Error>) -> Void)?
        var writes = 0
        var endCount = 0
        let coordinator = AutomaticBackupCoordinator(
            write: { _, completion in writes += 1; complete = completion },
            begin: { expiration in
                expire = expiration
                return UIBackgroundTaskIdentifier(rawValue: 1)
            },
            end: { _ in endCount += 1; expired.fulfill() }
        )
        coordinator.start { Data([1]) }
        expire?()
        await fulfillment(of: [expired], timeout: 2)
        coordinator.start { XCTFail("The expired write is still in flight"); return Data([2]) }
        XCTAssertEqual(writes, 1)
        complete?(.success(URL(fileURLWithPath: "/tmp/test.ironbackup")))
        // The completion is delivered to the main actor before a subsequent
        // background entry can start another run.
        await Task.yield()
        XCTAssertEqual(endCount, 1)
        coordinator.start { Data([3]) }
        XCTAssertEqual(writes, 2)
    }
}

extension IronBackupTests {
    private func backupData(name: String) -> Data {
        let url = Bundle.init(for: Self.self).bundleURL.appendingPathComponent("iron_backups").appendingPathComponent(name).appendingPathExtension("ironbackup")
        precondition(FileManager.default.fileExists(atPath: url.path), "File \(url.path) does not exist")
        return try! Data(contentsOf: url)
    }
}
