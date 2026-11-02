//
//  ExportImportWorkoutDataTests.swift
//  IronTests
//
//  Created by Karim Abou Zeid on 26.10.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import XCTest
import CoreData
import WorkoutDataKit
@testable import Iron

class ExportImportWorkoutDataTests: XCTestCase {
    var persistenContainer: NSPersistentContainer!
    
    var encoder: JSONEncoder {
        guard let contextKey = CodingUserInfoKey.managedObjectContextKey else { fatalError() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.userInfo[contextKey] = persistenContainer.viewContext
        return encoder
    }
    
    var decoder: JSONDecoder {
        guard let contextKey = CodingUserInfoKey.managedObjectContextKey else { fatalError() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.userInfo[contextKey] = persistenContainer.viewContext
        return decoder
    }

    override func setUp() {
        super.setUp()
        persistenContainer = setUpInMemoryNSPersistentContainer()
    }

    override func tearDown() {
        persistenContainer.viewContext.reset()
        persistenContainer = nil
        super.tearDown()
    }

    func testReadWorkoutData() {
        let workoutDataUrl = Bundle.init(for: Self.self).bundleURL.appendingPathComponent("workout_data.json")
        precondition(FileManager.default.fileExists(atPath: workoutDataUrl.path))
        
        // check that start and end is not nil
        let workouts = try! decoder.decode([Workout].self, from: Data(contentsOf: workoutDataUrl))
        XCTAssertFalse(workouts.isEmpty)
        for workout in workouts {
            XCTAssertNotNil(workout.start)
            XCTAssertNotNil(workout.end)
            XCTAssertFalse(workout.isCurrentWorkout)
            XCTAssertEqual(workout.importSource, "json") // legacy JSON has no provenance key
            XCTAssertNil(workout.healthExportState)
        }
        
        // check that workout is set
        let exercises = workouts.compactMap { $0.workoutExercises?.array.compactMap { $0 as? WorkoutExercise } }.flatMap { $0 }
        XCTAssertFalse(exercises.isEmpty)
        for exercise in exercises {
            XCTAssertNotNil(exercise.workout)
        }
        
        // check that workoutExercise is set
        let sets = exercises.compactMap { $0.workoutSets?.array.compactMap { $0 as? WorkoutSet } }.flatMap { $0 }
        XCTAssertFalse(sets.isEmpty)
        for set in sets {
            XCTAssertNotNil(set.workoutExercise)
            XCTAssert(set.isCompleted)
        }
        
        XCTAssertNoThrow(try persistenContainer.viewContext.save())
    }
    
    func testReadWorkoutDataStartEndMissing() {
        let workoutDataUrl = Bundle.init(for: Self.self).bundleURL.appendingPathComponent("workout_data_start_end_missing.json")
        precondition(FileManager.default.fileExists(atPath: workoutDataUrl.path))
        
        // cannot read if a workout doesn't have a start / end value
        XCTAssertThrowsError(try decoder.decode([Workout].self, from: Data(contentsOf: workoutDataUrl)))
    }
    
    func testExportWorkoutWithoutStartEnd() {
        let workout = Workout.create(context: persistenContainer.viewContext)
        // no start / end is set
        // encoding shouldn't crash but set safeStart and safeEnd
        let data = try! encoder.encode([workout])
        
        XCTAssertThrowsError(try persistenContainer.viewContext.save())
        persistenContainer.viewContext.delete(workout)
        XCTAssertNoThrow(try persistenContainer.viewContext.save())
        
        let workouts = try! decoder.decode([Workout].self, from: data)
        for workout in workouts {
            // decoded workouts must always have start end assigned
            XCTAssertNotNil(workout.start)
            XCTAssertNotNil(workout.end)
        }
        
        XCTAssertNoThrow(try persistenContainer.viewContext.save())
    }

    func testHevyCSVWorkoutImportExportAndDuplicateProtection() throws {
        let exercise = try XCTUnwrap(ExerciseStore.shared.exercises.first)
        let exerciseTitle = exercise.title.replacingOccurrences(of: "\"", with: "\"\"")
        let header = "\"title\",\"start_time\",\"end_time\",\"description\",\"exercise_title\",\"superset_id\",\"exercise_notes\",\"set_index\",\"set_type\",\"weight_lbs\",\"reps\",\"distance_miles\",\"duration_seconds\",\"rpe\""
        let rowOne = "\"Push, Pull\",\"17 Aug 2026, 08:16\",\"17 Aug 2026, 08:35\",\"Good \"\"session\"\"\",\"\(exerciseTitle)\",,\"First line\\nSecond line\",0,\"warmup\",135,5,,,"
        let rowTwo = "\"Push, Pull\",\"17 Aug 2026, 08:16\",\"17 Aug 2026, 08:35\",\"Good \"\"session\"\"\",\"\(exerciseTitle)\",,\"First line\\nSecond line\",1,\"normal\",225,8,,,7.5"
        let data = try XCTUnwrap((header + "\r\n" + rowOne + "\n" + rowTwo + "\r\n").data(using: .utf8))

        let parsed = try HevyCSV.parse(data: data)
        XCTAssertEqual(parsed.records.count, 2)
        XCTAssertEqual(parsed.records.first?.title, "Push, Pull")

        let result = try HevyCSV.importData(
            data,
            into: persistenContainer.viewContext,
            exerciseStore: .shared
        )
        XCTAssertEqual(result.importedWorkouts, 1)
        XCTAssertEqual(result.importedSets, 2)

        let request: NSFetchRequest<Workout> = Workout.fetchRequest()
        let workout = try XCTUnwrap(persistenContainer.viewContext.fetch(request).first)
        XCTAssertEqual(workout.importSource, "hevy")
        XCTAssertTrue(workout.isImported)
        let objectID = workout.objectID
        let freshContext = persistenContainer.newBackgroundContext()
        try freshContext.performAndWait {
            let persisted = try XCTUnwrap(freshContext.existingObject(with: objectID) as? Workout)
            XCTAssertEqual(persisted.importSource, "hevy")
            XCTAssertTrue(persisted.isImported)
        }
        let workoutExercise = try XCTUnwrap(workout.workoutExercises?.firstObject as? WorkoutExercise)
        let sets = try XCTUnwrap(workoutExercise.workoutSets?.array as? [WorkoutSet])
        XCTAssertEqual(sets.count, 2)
        XCTAssertEqual(sets[0].tagValue, .warmUp)
        XCTAssertEqual(sets[1].rpeValue, 7.5)
        XCTAssertEqual(sets[1].weightValue, Measurement(value: 225, unit: UnitMass.pounds).converted(to: .kilograms).value, accuracy: 0.0001)
        XCTAssertEqual(workoutExercise.comment, "First line\nSecond line")

        let duplicateResult = try HevyCSV.importData(
            data,
            into: persistenContainer.viewContext,
            exerciseStore: .shared
        )
        XCTAssertEqual(duplicateResult.importedWorkouts, 0)
        XCTAssertEqual(duplicateResult.skippedDuplicateWorkouts, 1)

        let exported = try HevyCSV.exportData(workouts: [workout], exercises: ExerciseStore.shared.exercises, weightUnit: .imperial)
        let reparsed = try HevyCSV.parse(data: exported)
        XCTAssertEqual(reparsed.records.count, 2)
        XCTAssertEqual(reparsed.records[1].repetitions, 8)
        XCTAssertEqual(reparsed.records[1].rpe, 7.5)
    }

    func testRawWorkoutJSONImportMarksAllWorkoutsImportedAndClearsHealthExportState() throws {
        let context = persistenContainer.viewContext
        let imported = Workout.create(context: context)
        imported.importSource = "hevy"
        imported.healthExportState = "pending"
        imported.start = Date(timeIntervalSince1970: 1_000)
        imported.end = Date(timeIntervalSince1970: 2_000)
        let native = Workout.create(context: context)
        XCTAssertNil(native.importSource)
        XCTAssertFalse(native.isImported)
        native.healthExportState = "watch"
        native.start = imported.start
        native.end = imported.end

        let data = try encoder.encode([imported, native])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(json[0]["importSource"] as? String, "hevy")
        XCTAssertNil(json[1]["importSource"])
        XCTAssertEqual(json[0]["healthExportState"] as? String, "pending")
        XCTAssertEqual(json[1]["healthExportState"] as? String, "watch")
        context.reset()
        let restored = try decoder.decode([Workout].self, from: data)
        XCTAssertEqual(restored.count, 2)
        for workout in restored {
            XCTAssertEqual(workout.importSource, "json")
            XCTAssertTrue(workout.isImported)
            XCTAssertNil(workout.healthExportState)
        }
    }

    func testSeedHistoryMarksCompletedAndOptionalActiveWorkoutsAsSamples() throws {
        for includeActiveWorkout in [false, true] {
            let container = setUpInMemoryNSPersistentContainer()
            let context = container.viewContext
            MockWorkoutData.seedHistory(
                into: context,
                unit: .metric,
                includeActiveWorkout: includeActiveWorkout
            )

            let request: NSFetchRequest<Workout> = Workout.fetchRequest()
            let workouts = try context.fetch(request)
            XCTAssertFalse(workouts.filter { !$0.isCurrentWorkout }.isEmpty)
            XCTAssertEqual(workouts.filter(\.isCurrentWorkout).count, includeActiveWorkout ? 1 : 0)
            for workout in workouts {
                XCTAssertEqual(workout.importSource, "sample")
                XCTAssertTrue(workout.isImported)
            }

            let native = Workout.create(context: context)
            XCTAssertNil(native.importSource)
            XCTAssertFalse(native.isImported)
        }
    }

    func testStaticAndRandomPreviewWorkoutsAreSamples() throws {
        for mock in [MockWorkoutData.metric, .imperial, .metricRandom, .imperialRandom] {
            let request: NSFetchRequest<Workout> = Workout.fetchRequest()
            let workouts = try mock.context.fetch(request)
            XCTAssertFalse(workouts.filter { !$0.isCurrentWorkout }.isEmpty)
            XCTAssertTrue(mock.currentWorkout.isCurrentWorkout)
            XCTAssertEqual(mock.currentWorkout.importSource, "sample")
            for workout in workouts {
                XCTAssertEqual(workout.importSource, "sample")
                XCTAssertTrue(workout.isImported)
            }
        }
    }

    func testHevyCSVSkipsNonfiniteAndOverflowingNumbersWithoutCrashing() throws {
        let header = "title,start_time,end_time,exercise_title,set_index,weight_kg,reps,distance_km,duration_seconds,rpe"
        let prefix = "Push,2026-08-17T08:16:00Z,2026-08-17T08:35:00Z,Bench Press,"
        let invalidFields = [
            "0,100,NaN,,,", "0,100,inf,,,", "0,100,1e100,,,",
            "1e100,100,8,,,", "NaN,100,8,,,", "0,NaN,8,,,",
            "0,100,8,1e308,,", "0,100,8,,inf,", "0,100,8,,,NaN"
        ]
        let rows = invalidFields.map { prefix + $0 }
            + [prefix + "0,100,8,,60,8"]
        let data = Data(([header] + rows).joined(separator: "\n").utf8)

        let document = try HevyCSV.parse(data: data)

        XCTAssertEqual(document.skippedRows, invalidFields.count)
        XCTAssertEqual(document.records.count, 1)
        XCTAssertEqual(document.records.first?.repetitions, 8)
        XCTAssertEqual(document.records.first?.weightKilograms, 100)
    }

    func testMeasurementInputRejectsNonfiniteAndConvertedOverflow() {
        for raw in ["NaN", "inf", "-1", "0", "1e309", "1e308"] {
            XCTAssertNil(BodyMeasurementKind.height.validatedCanonicalValue(from: raw, weightUnit: .imperial))
        }
        XCTAssertEqual(BodyMeasurementKind.bodyWeight.validatedCanonicalValue(from: "82,5", weightUnit: .metric), 82.5)
    }

    func testInvalidMeasurementDoesNotReplacePersistedEntry() throws {
        let suiteName = "InvalidMeasurementSave.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BodyMetricsStore(userDefaults: defaults)
        let original = BodyMeasurementEntry(values: [BodyMeasurementKind.bodyWeight.rawValue: 80])
        XCTAssertTrue(store.save(original, exportToHealth: false))
        for invalid in [Double.nan, Double.infinity, -1, 0] {
            var edited = original
            edited[.bodyWeight] = invalid
            XCTAssertFalse(store.save(edited, exportToHealth: false))
            XCTAssertEqual(store.entries, [original])
            XCTAssertEqual(BodyMetricsStore(userDefaults: defaults).entries, [original])
        }
    }

    func testHevyMeasurementImportSkipsNonfiniteAndOverflowingValues() throws {
        let suiteName = "HevyInvalidMeasurements.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BodyMetricsStore(userDefaults: defaults)
        let data = Data("""
        date,weight_kg,height_in
        2026-08-17T08:00:00Z,NaN,
        2026-08-18T08:00:00Z,inf,
        2026-08-19T08:00:00Z,80,1e308
        2026-08-20T08:00:00Z,80,70
        """.utf8)

        let result = try HevyCSV.importData(
            data,
            into: persistenContainer.viewContext,
            exerciseStore: .shared,
            bodyMetricsStore: store
        )

        XCTAssertEqual(result.skippedRows, 3)
        XCTAssertEqual(result.importedMeasurements, 1)
        XCTAssertEqual(store.entries.first?[.bodyWeight], 80)
        XCTAssertEqual(BodyMetricsStore(userDefaults: defaults).entries, store.entries)
    }

    func testHevyCSVBatchPreflightsEveryFileBeforeWriting() throws {
        let exercise = try XCTUnwrap(ExerciseStore.shared.exercises.first)
        let exerciseTitle = exercise.title.replacingOccurrences(of: "\"", with: "\"\"")
        let header = "\"title\",\"start_time\",\"end_time\",\"description\",\"exercise_title\",\"superset_id\",\"exercise_notes\",\"set_index\",\"set_type\",\"weight_kg\",\"reps\",\"distance_km\",\"duration_seconds\",\"rpe\""
        let row = "\"Push\",\"17 Aug 2026, 08:16\",\"17 Aug 2026, 08:35\",,\"\(exerciseTitle)\",,,0,normal,100,8,,,8"
        let validWorkout = try XCTUnwrap((header + "\n" + row + "\n").data(using: .utf8))
        let malformedSecondFile = try XCTUnwrap("not,a,hevy,export\n".data(using: .utf8))

        XCTAssertThrowsError(
            try HevyCSV.importData(
                [validWorkout, malformedSecondFile],
                into: persistenContainer.viewContext,
                exerciseStore: .shared
            )
        )

        let request: NSFetchRequest<Workout> = Workout.fetchRequest()
        XCTAssertTrue(try persistenContainer.viewContext.fetch(request).isEmpty)
    }

    func testHevyCSVBatchCombinesWorkoutAndMeasurementFiles() throws {
        let exercise = try XCTUnwrap(ExerciseStore.shared.exercises.first)
        let exerciseTitle = exercise.title.replacingOccurrences(of: "\"", with: "\"\"")
        let workoutHeader = "\"title\",\"start_time\",\"end_time\",\"description\",\"exercise_title\",\"superset_id\",\"exercise_notes\",\"set_index\",\"set_type\",\"weight_kg\",\"reps\",\"distance_km\",\"duration_seconds\",\"rpe\""
        let workoutRow = "\"Push\",\"17 Aug 2026, 08:16\",\"17 Aug 2026, 08:35\",,\"\(exerciseTitle)\",,,0,normal,100,8,,,8"
        let workoutData = try XCTUnwrap((workoutHeader + "\n" + workoutRow + "\n").data(using: .utf8))

        let measurementHeader = "\"date\",\"weight_lbs\",\"waist_in\""
        let measurementRow = "\"21 Mar 2022, 00:00\",182,32"
        let measurementData = try XCTUnwrap((measurementHeader + "\n" + measurementRow + "\n").data(using: .utf8))

        let suiteName = "HevyCSVBatchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let measurementStore = BodyMetricsStore(userDefaults: defaults)

        let result = try HevyCSV.importData(
            [workoutData, measurementData],
            into: persistenContainer.viewContext,
            exerciseStore: .shared,
            bodyMetricsStore: measurementStore
        )

        XCTAssertEqual(result.importedWorkouts, 1)
        XCTAssertEqual(result.importedSets, 1)
        XCTAssertEqual(result.importedMeasurements, 1)
        XCTAssertEqual(measurementStore.entries.count, 1)
    }

    func testHevyMeasurementCSVImportExportAndDuplicateProtection() throws {
        let suiteName = "HevyMeasurementCSVTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BodyMetricsStore(userDefaults: defaults)

        let header = "\"date\",\"weight_lbs\",\"fat_percent\",\"height_in\",\"neck_in\",\"shoulder_in\",\"chest_in\",\"left_bicep_in\",\"right_bicep_in\",\"left_forearm_in\",\"right_forearm_in\",\"abdomen_in\",\"waist_in\",\"hips_in\",\"left_thigh_in\",\"right_thigh_in\",\"left_calf_in\",\"right_calf_in\""
        let first = "\"21 Mar 2022, 00:00\",182,18,70,15,,40,,,,,34,32,,,,,"
        let second = "\"31 Mar 2022, 00:00\",180.6,,,,,,,,,,,,,,,,"
        let data = try XCTUnwrap((header + "\r\n" + first + "\n" + second + "\r\n").data(using: .utf8))

        let result = try HevyCSV.importData(
            data,
            into: persistenContainer.viewContext,
            exerciseStore: .shared,
            bodyMetricsStore: store
        )
        XCTAssertEqual(result.importedMeasurements, 2)
        XCTAssertEqual(store.entries.count, 2)
        let oldest = try XCTUnwrap(store.entries.last)
        XCTAssertEqual(oldest[.bodyWeight]!, Measurement(value: 182, unit: UnitMass.pounds).converted(to: .kilograms).value, accuracy: 0.0001)
        XCTAssertEqual(oldest[.height]!, Measurement(value: 70, unit: UnitLength.inches).converted(to: .centimeters).value, accuracy: 0.0001)
        XCTAssertEqual(oldest[.waist]!, Measurement(value: 32, unit: UnitLength.inches).converted(to: .centimeters).value, accuracy: 0.0001)
        XCTAssertEqual(oldest[.bodyFat], 18)

        let duplicateResult = try HevyCSV.importData(
            data,
            into: persistenContainer.viewContext,
            exerciseStore: .shared,
            bodyMetricsStore: store
        )
        XCTAssertEqual(duplicateResult.skippedDuplicateMeasurements, 2)
        XCTAssertEqual(store.entries.count, 2)

        let exported = try HevyCSV.exportMeasurementData(entries: store.entries, weightUnit: .imperial)
        let secondDefaultsName = "HevyMeasurementCSVTests.\(UUID().uuidString)"
        let secondDefaults = try XCTUnwrap(UserDefaults(suiteName: secondDefaultsName))
        defer { secondDefaults.removePersistentDomain(forName: secondDefaultsName) }
        let secondStore = BodyMetricsStore(userDefaults: secondDefaults)
        let roundTripResult = try HevyCSV.importData(
            exported,
            into: persistenContainer.viewContext,
            exerciseStore: .shared,
            bodyMetricsStore: secondStore
        )
        XCTAssertEqual(roundTripResult.importedMeasurements, 2)
        XCTAssertEqual(secondStore.entries.count, 2)
        let roundTrippedOldest = try XCTUnwrap(secondStore.entries.last)
        XCTAssertEqual(roundTrippedOldest[.height]!, oldest[.height]!, accuracy: 0.0001)
    }

    func testHevyHeightOnlyMeasurementCSVIsRecognized() throws {
        let suiteName = "HevyHeightOnlyCSVTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BodyMetricsStore(userDefaults: defaults)
        let data = try XCTUnwrap(
            "\"date\",\"height_cm\"\n\"24 Aug 2026, 09:30\",182.5\n".data(using: .utf8)
        )

        let result = try HevyCSV.importData(
            data,
            into: persistenContainer.viewContext,
            exerciseStore: .shared,
            bodyMetricsStore: store
        )

        XCTAssertEqual(result.importedMeasurements, 1)
        XCTAssertEqual(store.entries.first?[.height], 182.5)
    }

    func testMeasurementImportHandlesStoredDatesOutsideIntegerRange() throws {
        let suiteName = "HevyExtremeStoredDate.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BodyMetricsStore(userDefaults: defaults)
        let existing = BodyMeasurementEntry(
            date: Date(timeIntervalSince1970: 1e100),
            values: [BodyMeasurementKind.bodyWeight.rawValue: 80]
        )
        XCTAssertTrue(store.save(existing, exportToHealth: false))

        let result = try HevyCSV.importData(
            Data("date,weight_kg\n2026-08-17T08:00:00Z,82\n".utf8),
            into: persistenContainer.viewContext,
            exerciseStore: .shared,
            bodyMetricsStore: store
        )

        XCTAssertEqual(result.importedMeasurements, 1)
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertTrue(store.entries.contains { $0.id == existing.id })
    }
}

extension ExportImportWorkoutDataTests {
    private struct ImportSaveFailure: Error {}

    private func workoutCSV(
        title: String = "Imported",
        start: String = "2026-08-17T08:16:00Z",
        end: String = "2026-08-17T08:35:00Z",
        exerciseTitle: String
    ) -> Data {
        Data("""
        title,start_time,end_time,exercise_title,set_index,weight_kg,reps
        \(title),\(start),\(end),\(exerciseTitle),0,100,8
        """.utf8)
    }

    private func temporaryExerciseStore() -> (ExerciseStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HevyImportCustomExercises.\(UUID().uuidString).json")
        return (ExerciseStore(customExercisesURL: url), url)
    }

    func testImportTransactionErrorReportsPrimaryAndRollbackFailures() {
        let primary = NSError(
            domain: "HevyCSVImportTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "unique primary save failure"]
        )
        let rollback = NSError(
            domain: "HevyCSVImportTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "unique custom rollback failure"]
        )
        let error = HevyCSVImportTransactionError(
            primaryError: primary,
            rollbackErrors: [rollback]
        )

        XCTAssertTrue(error.localizedDescription.contains("unique primary save failure"))
        XCTAssertTrue(error.localizedDescription.contains("unique custom rollback failure"))
    }

    func testCustomExerciseReplacementDoesNotPublishBeforeImportCommit() throws {
        let (store, url) = temporaryExerciseStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let replacement = try XCTUnwrap(store.stageCreatingCustomExercises([
            .init(title: "Transaction Press", type: .barbell)
        ]))

        try store.write(replacement)

        XCTAssertTrue(store.customExercises.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode([Exercise].self, from: Data(contentsOf: url)).count, 1)
        store.publish(replacement)
        XCTAssertEqual(store.customExercises.map(\.title), ["Transaction Press"])
    }

    func testCustomExerciseRollbackRestoresExactBytesAndAbsentFile() throws {
        let (store, url) = temporaryExerciseStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let absentReplacement = try XCTUnwrap(store.stageCreatingCustomExercises([
            .init(title: "Temporary Press", type: .other)
        ]))
        try store.write(absentReplacement)
        try store.rollback(absentReplacement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        let original = try JSONEncoder().encode([Exercise]())
        try original.write(to: url)
        let existingReplacement = try XCTUnwrap(store.stageCreatingCustomExercises([
            .init(title: "Another Press", type: .dumbbell)
        ]))
        try store.write(existingReplacement)
        try store.rollback(existingReplacement)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testCorruptCustomExerciseFileFailsClosed() throws {
        let (store, url) = temporaryExerciseStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: url)

        XCTAssertThrowsError(try store.stageCreatingCustomExercises([
            .init(title: "Must Not Replace", type: .other)
        ]))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testBodyMetricsReplacementWritesWithoutPublishingAndRollsBack() throws {
        let suiteName = "HevyStagedMeasurements.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BodyMetricsStore(userDefaults: defaults)
        let original = BodyMeasurementEntry(
            date: Date(timeIntervalSince1970: 1_000),
            values: [BodyMeasurementKind.bodyWeight.rawValue: 80]
        )
        XCTAssertTrue(store.save(original, exportToHealth: false))
        let replacementEntry = BodyMeasurementEntry(
            date: Date(timeIntervalSince1970: 2_000),
            values: [BodyMeasurementKind.bodyWeight.rawValue: 82]
        )
        let replacement = try store.stageReplacement(with: [replacementEntry])

        store.write(replacement)

        XCTAssertEqual(store.entries, [original])
        XCTAssertEqual(BodyMetricsStore(userDefaults: defaults).entries, [replacementEntry])
        store.rollback(replacement)
        XCTAssertEqual(BodyMetricsStore(userDefaults: defaults).entries, [original])
    }

    func testMixedImportSaveFailureRestoresExternalStorageAndImportedGraph() throws {
        let (exerciseStore, exerciseURL) = temporaryExerciseStore()
        defer { try? FileManager.default.removeItem(at: exerciseURL) }
        let suiteName = "HevyMixedFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let measurementStore = BodyMetricsStore(userDefaults: defaults)
        let original = BodyMeasurementEntry(
            date: Date(timeIntervalSince1970: 1_000),
            values: [BodyMeasurementKind.bodyWeight.rawValue: 80]
        )
        XCTAssertTrue(measurementStore.save(original, exportToHealth: false))
        let unrelated = Workout.create(context: persistenContainer.viewContext)
        unrelated.title = "Pending User Edit"
        unrelated.start = Date(timeIntervalSince1970: 100)
        unrelated.end = Date(timeIntervalSince1970: 200)
        unrelated.isCurrentWorkout = true
        var saveInvoked = false

        XCTAssertThrowsError(try HevyCSV.importData(
            [
                workoutCSV(exerciseTitle: "Unstored Transaction Lift"),
                Data("date,weight_kg\n2026-08-18T08:00:00Z,82\n".utf8)
            ],
            into: persistenContainer.viewContext,
            exerciseStore: exerciseStore,
            bodyMetricsStore: measurementStore,
            save: {
                saveInvoked = true
                throw ImportSaveFailure()
            }
        ))

        XCTAssertTrue(saveInvoked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exerciseURL.path))
        XCTAssertTrue(exerciseStore.customExercises.isEmpty)
        XCTAssertEqual(measurementStore.entries, [original])
        XCTAssertEqual(BodyMetricsStore(userDefaults: defaults).entries, [original])
        XCTAssertFalse(unrelated.isDeleted)
        XCTAssertEqual(unrelated.title, "Pending User Edit")
        let request: NSFetchRequest<Workout> = Workout.fetchRequest()
        XCTAssertFalse(try persistenContainer.viewContext.fetch(request).contains { $0.title == "Imported" })
    }

    func testMeasurementOnlySaveFailureRestoresDefaultsAndPublishesNothing() throws {
        let suiteName = "HevyMeasurementFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BodyMetricsStore(userDefaults: defaults)
        let original = BodyMeasurementEntry(
            date: Date(timeIntervalSince1970: 1_000),
            values: [BodyMeasurementKind.bodyWeight.rawValue: 80]
        )
        XCTAssertTrue(store.save(original, exportToHealth: false))
        var saveInvoked = false

        XCTAssertThrowsError(try HevyCSV.importData(
            Data("date,weight_kg\n2026-08-18T08:00:00Z,82\n".utf8),
            into: persistenContainer.viewContext,
            exerciseStore: .shared,
            bodyMetricsStore: store,
            save: {
                saveInvoked = true
                throw ImportSaveFailure()
            }
        ))

        XCTAssertTrue(saveInvoked)
        XCTAssertEqual(store.entries, [original])
        XCTAssertEqual(BodyMetricsStore(userDefaults: defaults).entries, [original])
    }

    func testDuplicateWorkoutDoesNotCreateExerciseFromSkippedRows() throws {
        let (store, url) = temporaryExerciseStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let existingExercise = try XCTUnwrap(store.builtInExercises.first)
        _ = try HevyCSV.importData(
            workoutCSV(title: "Duplicate", exerciseTitle: existingExercise.title),
            into: persistenContainer.viewContext,
            exerciseStore: store
        )

        let result = try HevyCSV.importData(
            workoutCSV(title: "Duplicate", exerciseTitle: "Should Never Be Created"),
            into: persistenContainer.viewContext,
            exerciseStore: store
        )

        XCTAssertEqual(result.skippedDuplicateWorkouts, 1)
        XCTAssertEqual(result.createdExercises, 0)
        XCTAssertTrue(store.customExercises.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testBatchSkipsDuplicateWorkoutAcrossSelectedFiles() throws {
        let exercise = try XCTUnwrap(ExerciseStore.shared.exercises.first)
        let document = workoutCSV(title: "Selected Duplicate", exerciseTitle: exercise.title)

        let result = try HevyCSV.importData(
            [document, document],
            into: persistenContainer.viewContext,
            exerciseStore: .shared
        )

        XCTAssertEqual(result.importedWorkouts, 1)
        XCTAssertEqual(result.skippedDuplicateWorkouts, 1)
        XCTAssertEqual(result.importedSets, 1)
    }

    func testBatchMeasurementMergePreservesIDAndSequentialCounts() throws {
        let suiteName = "HevySequentialMeasurements.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BodyMetricsStore(userDefaults: defaults)
        let id = UUID()
        let original = BodyMeasurementEntry(
            id: id,
            date: ISO8601DateFormatter().date(from: "2026-08-18T08:00:00Z")!,
            values: [BodyMeasurementKind.bodyWeight.rawValue: 80]
        )
        XCTAssertTrue(store.save(original, exportToHealth: false))

        let result = try HevyCSV.importData(
            [
                Data("date,weight_kg\n2026-08-18T08:00:00Z,82\n".utf8),
                Data("date,weight_kg,fat_percent\n2026-08-18T08:00:00Z,82,18\n".utf8)
            ],
            into: persistenContainer.viewContext,
            exerciseStore: .shared,
            bodyMetricsStore: store
        )

        XCTAssertEqual(result.updatedMeasurements, 2)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.id, id)
        XCTAssertEqual(store.entries.first?[.bodyWeight], 82)
        XCTAssertEqual(store.entries.first?[.bodyFat], 18)
    }

    func testSuccessfulMixedBatchPublishesAllStagedStores() throws {
        let (exerciseStore, exerciseURL) = temporaryExerciseStore()
        defer { try? FileManager.default.removeItem(at: exerciseURL) }
        let suiteName = "HevyMixedSuccess.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let measurementStore = BodyMetricsStore(userDefaults: defaults)

        let result = try HevyCSV.importData(
            [
                workoutCSV(exerciseTitle: "Committed Transaction Lift"),
                Data("date,weight_kg\n2026-08-18T08:00:00Z,82\n".utf8)
            ],
            into: persistenContainer.viewContext,
            exerciseStore: exerciseStore,
            bodyMetricsStore: measurementStore
        )

        XCTAssertEqual(result.importedWorkouts, 1)
        XCTAssertEqual(result.importedSets, 1)
        XCTAssertEqual(result.importedMeasurements, 1)
        XCTAssertEqual(result.createdExercises, 1)
        XCTAssertEqual(exerciseStore.customExercises.map(\.title), ["Committed Transaction Lift"])
        XCTAssertEqual(measurementStore.entries.first?[.bodyWeight], 82)
    }
}

extension ExportImportWorkoutDataTests {
    private func makeImportedDataTestWorkout(in context: NSManagedObjectContext) -> Workout {
        let workout = Workout.create(context: context)
        workout.start = Date(timeIntervalSince1970: 1_790_000_000)
        workout.end = workout.start?.addingTimeInterval(60)
        return workout
    }

    func testHevyWorkoutKeyRoundsStartAndNormalizesTitle() {
        let key = HevyCSV.workoutKey(
            start: Date(timeIntervalSince1970: 1_790_000_000.1), title: "  Café — PUSH!  "
        )
        let equivalent = HevyCSV.workoutKey(
            start: Date(timeIntervalSince1970: 1_790_000_000.4), title: "cafe push"
        )
        XCTAssertEqual(key, equivalent)
        XCTAssertEqual(Set([key, equivalent]).count, 1)
        XCTAssertEqual(
            HevyCSV.workoutKey(start: .distantPast, title: ""),
            HevyCSV.workoutKey(start: .distantPast, title: "Workout")
        )
    }

    func testHevyWorkoutKeyDistinguishesStartSecondsAndTitles() {
        let start = Date(timeIntervalSince1970: 1_790_000_000.1)
        let key = HevyCSV.workoutKey(start: start, title: "Push")
        XCTAssertNotEqual(key, HevyCSV.workoutKey(start: start.addingTimeInterval(1), title: "Push"))
        XCTAssertNotEqual(key, HevyCSV.workoutKey(start: start, title: "Pull"))
    }

    func testHevyReimportSkipsRenamedWorkoutByExerciseAndSets() throws {
        let exercise = try XCTUnwrap(ExerciseStore.shared.exercises.first)
        let data = workoutCSV(exerciseTitle: exercise.title)
        _ = try HevyCSV.importData(data, into: persistenContainer.viewContext, exerciseStore: .shared)
        let workout = try XCTUnwrap(persistenContainer.viewContext.fetch(Workout.fetchRequest()).first)
        workout.title = "Renamed in Iron"
        try persistenContainer.viewContext.save()

        let result = try HevyCSV.importData(data, into: persistenContainer.viewContext, exerciseStore: .shared)
        XCTAssertEqual(result.importedWorkouts, 0)
        XCTAssertEqual(result.skippedDuplicateWorkouts, 1)
        XCTAssertEqual(workout.title, "Renamed in Iron")
        XCTAssertEqual(try persistenContainer.viewContext.count(for: Workout.fetchRequest()), 1)
    }

    func testHevyFingerprintUsesNormalizedPersistedSetValues() throws {
        let context = persistenContainer.viewContext
        let exercise = try XCTUnwrap(ExerciseStore.shared.exercises.first)
        let title = exercise.title.replacingOccurrences(of: "\"", with: "\"\"")
        let data = Data("""
        title,start_time,end_time,exercise_title,set_index,set_type,weight_kg,reps,distance_km,duration_seconds,rpe
        Imported,2026-08-17T08:16:00Z,2026-08-17T08:35:00Z,"\(title)",0,warmup,-5,99999,0,0,7.3
        Imported,2026-08-17T08:16:00Z,2026-08-17T08:35:00Z,"\(title)",1,dropset,45.12345678,8,1.234567,90,8.5
        """.utf8)
        _ = try HevyCSV.importData(data, into: context, exerciseStore: .shared)
        let workout = try XCTUnwrap(HevyImportedWorkouts.fetch(in: context).first)
        workout.title = "Renamed locally"
        workout.comment = "A local note does not change session identity"
        try context.save()

        let result = try HevyCSV.importData(data, into: context, exerciseStore: .shared)

        XCTAssertEqual(result.importedWorkouts, 0)
        XCTAssertEqual(result.skippedDuplicateWorkouts, 1)
        XCTAssertEqual(try context.count(for: WorkoutSet.fetchRequest()), 2)
        XCTAssertEqual(workout.title, "Renamed locally")
        XCTAssertEqual(workout.comment, "A local note does not change session identity")
    }

    func testHevyFingerprintDistinguishesExerciseIdentity() throws {
        let context = persistenContainer.viewContext
        let exercises = Array(ExerciseStore.shared.exercises.prefix(2))
        XCTAssertEqual(exercises.count, 2)
        let firstExercise = try XCTUnwrap(exercises.first)
        let secondExercise = try XCTUnwrap(exercises.dropFirst().first)
        let original = workoutCSV(exerciseTitle: firstExercise.title)
        _ = try HevyCSV.importData(original, into: context, exerciseStore: .shared)
        let workout = try XCTUnwrap(HevyImportedWorkouts.fetch(in: context).first)
        workout.title = "Renamed locally"
        try context.save()

        let result = try HevyCSV.importData(
            workoutCSV(exerciseTitle: secondExercise.title), into: context, exerciseStore: .shared
        )

        XCTAssertEqual(result.importedWorkouts, 1)
        XCTAssertEqual(result.skippedDuplicateWorkouts, 0)
        XCTAssertEqual(try HevyImportedWorkouts.fetch(in: context).count, 2)
    }

    func testHevyFingerprintDistinguishesDatesAndSetValues() throws {
        let exercise = try XCTUnwrap(ExerciseStore.shared.exercises.first)
        let original = workoutCSV(exerciseTitle: exercise.title)
        _ = try HevyCSV.importData(original, into: persistenContainer.viewContext, exerciseStore: .shared)
        let workout = try XCTUnwrap(persistenContainer.viewContext.fetch(Workout.fetchRequest()).first)
        workout.title = "Renamed"
        try persistenContainer.viewContext.save()
        let changed = Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: ",100,8", with: ",105,8").utf8)
        let changedResult = try HevyCSV.importData(changed, into: persistenContainer.viewContext, exerciseStore: .shared)
        XCTAssertEqual(changedResult.importedWorkouts, 1)
        let later = workoutCSV(start: "2026-08-18T08:16:00Z", end: "2026-08-18T08:35:00Z", exerciseTitle: exercise.title)
        let laterResult = try HevyCSV.importData(later, into: persistenContainer.viewContext, exerciseStore: .shared)
        XCTAssertEqual(laterResult.importedWorkouts, 1)
        XCTAssertEqual(try persistenContainer.viewContext.count(for: Workout.fetchRequest()), 3)
    }

    func testContentFingerprintDoesNotTreatNativeWorkoutAsHevyImport() throws {
        let exercise = try XCTUnwrap(ExerciseStore.shared.exercises.first)
        let data = workoutCSV(exerciseTitle: exercise.title)
        _ = try HevyCSV.importData(data, into: persistenContainer.viewContext, exerciseStore: .shared)
        let native = try XCTUnwrap(persistenContainer.viewContext.fetch(Workout.fetchRequest()).first)
        native.importSource = nil
        native.title = "Logged in Iron"
        try persistenContainer.viewContext.save()
        let result = try HevyCSV.importData(data, into: persistenContainer.viewContext, exerciseStore: .shared)
        XCTAssertEqual(result.importedWorkouts, 1)
        XCTAssertNil(native.importSource)
        XCTAssertEqual(native.title, "Logged in Iron")
    }

    func testContentFingerprintDoesNotTreatOtherImportSourceAsHevy() throws {
        let context = persistenContainer.viewContext
        let exercise = try XCTUnwrap(ExerciseStore.shared.exercises.first)
        let data = workoutCSV(exerciseTitle: exercise.title)
        _ = try HevyCSV.importData(data, into: context, exerciseStore: .shared)
        let otherImport = try XCTUnwrap(HevyImportedWorkouts.fetch(in: context).first)
        otherImport.importSource = "json"
        otherImport.title = "Imported from JSON"
        try context.save()

        let result = try HevyCSV.importData(data, into: context, exerciseStore: .shared)

        XCTAssertEqual(result.importedWorkouts, 1)
        XCTAssertEqual(result.skippedDuplicateWorkouts, 0)
        XCTAssertEqual(otherImport.importSource, "json")
        XCTAssertEqual(otherImport.title, "Imported from JSON")
    }

    func testRemovalPredicateOnlySelectsExactHevySource() throws {
        let context = persistenContainer.viewContext
        let sources: [String?] = [nil, "hevy", "json", "sample", "Hevy", "hevy ", ""]
        for source in sources {
            let workout = makeImportedDataTestWorkout(in: context)
            workout.importSource = source
        }
        try context.save()
        let selected = try HevyImportedWorkouts.fetch(in: context)
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first?.importSource, "hevy")
        XCTAssertEqual(try HevyImportedWorkouts.remove(in: context), 1)
        let remaining = try context.fetch(Workout.fetchRequest())
        XCTAssertEqual(remaining.count, sources.count - 1)
        XCTAssertTrue(remaining.contains { $0.importSource == nil })
        XCTAssertFalse(remaining.contains { $0.importSource == "hevy" })
    }

    func testRemovalCascadesImportedSetsAndKeepsNativeWorkout() throws {
        let context = persistenContainer.viewContext
        let exercise = try XCTUnwrap(ExerciseStore.shared.exercises.first)
        _ = try HevyCSV.importData(workoutCSV(exerciseTitle: exercise.title), into: context, exerciseStore: .shared)
        let native = makeImportedDataTestWorkout(in: context)
        native.title = "Iron workout"
        let nativeExercise = WorkoutExercise.create(context: context)
        nativeExercise.exerciseUuid = exercise.uuid
        native.addToWorkoutExercises(nativeExercise)
        let nativeSet = WorkoutSet.create(context: context)
        nativeSet.isCompleted = true
        nativeExercise.addToWorkoutSets(nativeSet)
        try context.save()

        XCTAssertEqual(try HevyImportedWorkouts.remove(in: context), 1)
        XCTAssertEqual(try context.fetch(Workout.fetchRequest()), [native])
        XCTAssertEqual(try context.fetch(WorkoutExercise.fetchRequest()), [nativeExercise])
        XCTAssertEqual(try context.count(for: WorkoutSet.fetchRequest()), 1)
        XCTAssertEqual(native.title, "Iron workout")
    }

    func testRemovalSaveFailureRestoresImportedGraphAndPendingNativeEdit() throws {
        let context = persistenContainer.viewContext
        let exercise = try XCTUnwrap(ExerciseStore.shared.exercises.first)
        _ = try HevyCSV.importData(workoutCSV(exerciseTitle: exercise.title), into: context, exerciseStore: .shared)
        let imported = try XCTUnwrap(HevyImportedWorkouts.fetch(in: context).first)
        let native = makeImportedDataTestWorkout(in: context)
        try context.save()
        native.comment = "Unsaved native note"
        XCTAssertThrowsError(try HevyImportedWorkouts.remove(in: context, save: { throw ImportSaveFailure() }))
        XCTAssertFalse(imported.isDeleted)
        XCTAssertEqual(try HevyImportedWorkouts.fetch(in: context).count, 1)
        XCTAssertEqual(try context.count(for: WorkoutSet.fetchRequest()), 1)
        XCTAssertEqual(native.comment, "Unsaved native note")
        XCTAssertTrue(context.hasChanges)
    }

    func testReplacementUpdatesHevySessionAndKeepsNativeAndMeasurements() throws {
        let context = persistenContainer.viewContext
        let exercise = try XCTUnwrap(ExerciseStore.shared.exercises.first)
        let original = workoutCSV(exerciseTitle: exercise.title)
        _ = try HevyCSV.importData(original, into: context, exerciseStore: .shared)
        let oldID = try XCTUnwrap(HevyImportedWorkouts.fetch(in: context).first?.objectID)
        let native = makeImportedDataTestWorkout(in: context)
        native.title = "Keep me"
        try context.save()
        let suite = "HevyReplaceMeasurements.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let measurements = BodyMetricsStore(userDefaults: defaults)
        let entry = BodyMeasurementEntry(values: [BodyMeasurementKind.bodyWeight.rawValue: 82])
        XCTAssertTrue(measurements.save(entry, exportToHealth: false))
        let changed = Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: ",100,8", with: ",105,8").utf8)
        let result = try HevyCSV.importData(HevyCSV.prepareImport([changed]), into: context,
                                          exerciseStore: .shared, bodyMetricsStore: measurements,
                                          replacingImportedWorkouts: true)
        XCTAssertEqual(result.removedWorkouts, 1)
        XCTAssertEqual(result.importedWorkouts, 1)
        XCTAssertEqual(result.skippedDuplicateWorkouts, 0)
        let replacement = try XCTUnwrap(HevyImportedWorkouts.fetch(in: context).first)
        XCTAssertNotEqual(replacement.objectID, oldID)
        let replacementExercise = try XCTUnwrap(replacement.workoutExercises?.firstObject as? WorkoutExercise)
        XCTAssertEqual((replacementExercise.workoutSets?.firstObject as? WorkoutSet)?.weightValue, 105)
        XCTAssertEqual(native.title, "Keep me")
        XCTAssertNil(native.importSource)
        XCTAssertEqual(measurements.entries, [entry])
        XCTAssertEqual(try context.count(for: WorkoutSet.fetchRequest()), 1)
    }

    func testReplacementFailureRestoresOldGraphAndCustomExerciseFile() throws {
        let context = persistenContainer.viewContext
        let (store, url) = temporaryExerciseStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let exercise = try XCTUnwrap(store.exercises.first)
        _ = try HevyCSV.importData(workoutCSV(exerciseTitle: exercise.title), into: context, exerciseStore: store)
        let old = try XCTUnwrap(HevyImportedWorkouts.fetch(in: context).first)
        let oldID = old.objectID
        let native = makeImportedDataTestWorkout(in: context)
        try context.save()
        native.comment = "Keep pending edit"
        let prepared = try HevyCSV.prepareImport([workoutCSV(exerciseTitle: "Unique Replacement Test Press")])
        XCTAssertThrowsError(try HevyCSV.importData(prepared, into: context, exerciseStore: store,
                                                   replacingImportedWorkouts: true, save: { throw ImportSaveFailure() }))
        XCTAssertEqual(try HevyImportedWorkouts.fetch(in: context).map(\.objectID), [oldID])
        XCTAssertFalse(old.isDeleted)
        XCTAssertEqual(try context.count(for: WorkoutSet.fetchRequest()), 1)
        XCTAssertEqual(native.comment, "Keep pending edit")
        XCTAssertTrue(store.customExercises.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testReplacementRejectsMeasurementOnlyCSVWithoutDeletingWorkouts() throws {
        let context = persistenContainer.viewContext
        let exercise = try XCTUnwrap(ExerciseStore.shared.exercises.first)
        _ = try HevyCSV.importData(workoutCSV(exerciseTitle: exercise.title), into: context, exerciseStore: .shared)
        let prepared = try HevyCSV.prepareImport([Data("date,weight_kg\n2026-08-17T08:00:00Z,82\n".utf8)])
        XCTAssertThrowsError(try HevyCSV.importData(prepared, into: context, exerciseStore: .shared,
                                                   replacingImportedWorkouts: true))
        XCTAssertEqual(try HevyImportedWorkouts.fetch(in: context).count, 1)
        XCTAssertEqual(try context.count(for: WorkoutSet.fetchRequest()), 1)
    }

    @MainActor
    func testBackgroundRemovalMergesDeletionAndPreservesPendingNativeEdit() async throws {
        let context = persistenContainer.viewContext
        let exercise = try XCTUnwrap(ExerciseStore.shared.exercises.first)
        _ = try HevyCSV.importData(workoutCSV(exerciseTitle: exercise.title), into: context, exerciseStore: .shared)
        let native = makeImportedDataTestWorkout(in: context)
        try context.save()
        native.comment = "Still editing"
        let controller = HevyImportController()
        let outcome = await controller.remove(count: 1, from: context)
        let result = try outcome.result.get()
        XCTAssertEqual(result.removedWorkouts, 1)
        XCTAssertEqual(try HevyImportedWorkouts.fetch(in: context).count, 0)
        XCTAssertEqual(native.comment, "Still editing")
        XCTAssertTrue(context.hasChanges)
        XCTAssertNil(controller.phase)
    }
}

extension ExportImportWorkoutDataTests {
    func testReplacementRejectsPartiallyMalformedExportBeforeDeletion() throws {
        let context = persistenContainer.viewContext
        let exercise = try XCTUnwrap(ExerciseStore.shared.exercises.first)
        let original = workoutCSV(exerciseTitle: exercise.title)
        _ = try HevyCSV.importData(original, into: context, exerciseStore: .shared)
        let malformed = Data((String(decoding: original, as: UTF8.self) + "\nBroken,not-a-date,,Unknown,0,100,8\n").utf8)
        let prepared = try HevyCSV.prepareImport([malformed])
        XCTAssertThrowsError(try HevyCSV.importData(prepared, into: context, exerciseStore: .shared,
                                                   replacingImportedWorkouts: true))
        XCTAssertEqual(try HevyImportedWorkouts.fetch(in: context).count, 1)
        XCTAssertEqual(try context.count(for: WorkoutSet.fetchRequest()), 1)
    }
}

extension ExportImportWorkoutDataTests {
    @MainActor
    func testBackgroundReplacementPublishesCustomExerciseAndMergesGraphBeforeSuccess() async throws {
        let context = persistenContainer.viewContext
        let (store, url) = temporaryExerciseStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let exercise = try XCTUnwrap(store.exercises.first)
        _ = try HevyCSV.importData(workoutCSV(exerciseTitle: exercise.title), into: context, exerciseStore: store)
        let native = makeImportedDataTestWorkout(in: context)
        native.title = "Keep native workout"
        try context.save()
        native.comment = "Pending native note"
        let controller = HevyImportController()
        let outcome = await controller.replace(workoutCSV(exerciseTitle: "Background Replacement Test Press"),
                                               into: context, exerciseStore: store)
        let result = try outcome.result.get()
        XCTAssertEqual(result.importedWorkouts, 1)
        XCTAssertEqual(result.removedWorkouts, 1)
        let created = try XCTUnwrap(store.customExercises.first { $0.title == "Background Replacement Test Press" })
        let imported = try XCTUnwrap(HevyImportedWorkouts.fetch(in: context).first)
        let importedExercise = try XCTUnwrap(imported.workoutExercises?.firstObject as? WorkoutExercise)
        XCTAssertEqual(importedExercise.exerciseUuid, created.uuid)
        XCTAssertEqual(try context.count(for: WorkoutSet.fetchRequest()), 1)
        XCTAssertEqual(native.comment, "Pending native note")
        XCTAssertTrue(context.hasChanges)
        XCTAssertNil(controller.phase)
    }
}

extension ExportImportWorkoutDataTests {
    func testHevyAliasResolvesToCuratedBuiltInWithoutCreatingCustomExercise() throws {
        let (store, url) = temporaryExerciseStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let curatedUUID = try XCTUnwrap(UUID(uuidString: "7988E742-0363-5443-98DB-86EE3879C512"))
        let curated = try XCTUnwrap(store.builtInExercises.first { $0.uuid == curatedUUID })
        XCTAssertTrue(curated.alias.contains("Leg Raise Parallel Bars"))

        let result = try HevyCSV.importData(
            workoutCSV(exerciseTitle: "Leg Raise Parallel Bars"),
            into: persistenContainer.viewContext,
            exerciseStore: store
        )

        XCTAssertEqual(result.importedWorkouts, 1)
        XCTAssertEqual(result.createdExercises, 0)
        XCTAssertTrue(store.customExercises.isEmpty)
        let workout = try XCTUnwrap(persistenContainer.viewContext.fetch(Workout.fetchRequest()).first)
        let workoutExercise = try XCTUnwrap(workout.workoutExercises?.firstObject as? WorkoutExercise)
        XCTAssertEqual(workoutExercise.exerciseUuid, curatedUUID)
    }

    func testHevyAliasEnrichesEmptyCustomInMemoryAndPreservesCustomIdentityAndHistory() throws {
        let (_, url) = temporaryExerciseStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let customUUID = UUID()
        let custom = Exercise(
            uuid: customUUID,
            everkineticId: 10_000,
            title: "Leg Raise Parallel Bars",
            alias: [],
            description: nil,
            primaryMuscle: [],
            secondaryMuscle: [],
            equipment: [],
            steps: [],
            tips: [],
            references: [],
            pdfPaths: []
        )
        let originalData = try JSONEncoder().encode([custom])
        try originalData.write(to: url, options: .atomic)

        let store = ExerciseStore(customExercisesURL: url)
        let enriched = try XCTUnwrap(store.customExercises.first)
        XCTAssertEqual(enriched.uuid, customUUID)
        XCTAssertEqual(enriched.title, "Leg Raise Parallel Bars")
        XCTAssertFalse(enriched.primaryMuscle.isEmpty)
        XCTAssertFalse(enriched.secondaryMuscle.isEmpty)
        XCTAssertNotNil(enriched.imageFilename)
        XCTAssertNotNil(enriched.animationFilename)
        XCTAssertEqual(try Data(contentsOf: url), originalData)

        let data = workoutCSV(exerciseTitle: "Leg Raise Parallel Bars")
        let firstResult = try HevyCSV.importData(
            data,
            into: persistenContainer.viewContext,
            exerciseStore: store
        )
        XCTAssertEqual(firstResult.importedWorkouts, 1)
        XCTAssertEqual(firstResult.createdExercises, 0)
        let workout = try XCTUnwrap(persistenContainer.viewContext.fetch(Workout.fetchRequest()).first)
        let workoutExercise = try XCTUnwrap(workout.workoutExercises?.firstObject as? WorkoutExercise)
        XCTAssertEqual(workoutExercise.exerciseUuid, customUUID)

        workout.title = "Renamed in Iron"
        try persistenContainer.viewContext.save()
        let duplicateResult = try HevyCSV.importData(
            data,
            into: persistenContainer.viewContext,
            exerciseStore: store
        )
        XCTAssertEqual(duplicateResult.importedWorkouts, 0)
        XCTAssertEqual(duplicateResult.skippedDuplicateWorkouts, 1)
        XCTAssertEqual(workout.title, "Renamed in Iron")
        XCTAssertEqual(try persistenContainer.viewContext.count(for: Workout.fetchRequest()), 1)
        XCTAssertEqual(try Data(contentsOf: url), originalData)
    }

    func testExerciseCatalogEnrichmentPreservesUnknownAndExplicitCustomMetadata() throws {
        let (_, url) = temporaryExerciseStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let unknown = Exercise(
            uuid: UUID(),
            everkineticId: 10_000,
            title: "Uncatalogued Hevy Movement",
            alias: [],
            description: nil,
            primaryMuscle: [],
            secondaryMuscle: [],
            equipment: [],
            steps: [],
            tips: [],
            references: [],
            pdfPaths: []
        )
        let explicitMuscles = Exercise(
            uuid: UUID(),
            everkineticId: 10_000,
            title: "Leg Raise Parallel Bars",
            alias: [],
            description: nil,
            primaryMuscle: ["custom muscle"],
            secondaryMuscle: ["custom stabilizer"],
            equipment: ["body weight"],
            steps: [],
            tips: [],
            references: [],
            pdfPaths: []
        )
        let explicitEquipment = Exercise(
            uuid: UUID(),
            everkineticId: 10_000,
            title: "Bicep Curl (Barbell)",
            alias: [],
            description: nil,
            primaryMuscle: [],
            secondaryMuscle: [],
            equipment: ["custom apparatus"],
            steps: [],
            tips: [],
            references: [],
            pdfPaths: []
        )
        let originalData = try JSONEncoder().encode([unknown, explicitMuscles, explicitEquipment])
        try originalData.write(to: url, options: .atomic)

        let store = ExerciseStore(customExercisesURL: url)
        let loadedUnknown = try XCTUnwrap(store.customExercises.first { $0.title == unknown.title })
        XCTAssertTrue(loadedUnknown.primaryMuscle.isEmpty)
        XCTAssertTrue(loadedUnknown.secondaryMuscle.isEmpty)
        XCTAssertTrue(loadedUnknown.equipment.isEmpty)
        XCTAssertNil(loadedUnknown.imageFilename)
        XCTAssertNil(loadedUnknown.animationFilename)

        let loadedMuscles = try XCTUnwrap(store.customExercises.first { $0.title == explicitMuscles.title })
        XCTAssertEqual(loadedMuscles.primaryMuscle, explicitMuscles.primaryMuscle)
        XCTAssertEqual(loadedMuscles.secondaryMuscle, explicitMuscles.secondaryMuscle)
        XCTAssertEqual(loadedMuscles.equipment, explicitMuscles.equipment)
        XCTAssertNil(loadedMuscles.imageFilename)
        XCTAssertNil(loadedMuscles.animationFilename)

        let loadedEquipment = try XCTUnwrap(store.customExercises.first { $0.title == explicitEquipment.title })
        XCTAssertTrue(loadedEquipment.primaryMuscle.isEmpty)
        XCTAssertTrue(loadedEquipment.secondaryMuscle.isEmpty)
        XCTAssertEqual(loadedEquipment.equipment, explicitEquipment.equipment)
        XCTAssertNil(loadedEquipment.imageFilename)
        XCTAssertNil(loadedEquipment.animationFilename)
        XCTAssertEqual(try Data(contentsOf: url), originalData)
    }

    func testUpdatingCatalogPreservesLegacyUpdatesExistingAndAppendsNewWithoutDuplicateUUIDs() {
        func fixture(uuid: UUID, id: Int, title: String, primary: [String]) -> Exercise {
            Exercise(
                uuid: uuid,
                everkineticId: id,
                title: title,
                alias: [],
                description: "Description \(title)",
                primaryMuscle: primary,
                secondaryMuscle: [],
                equipment: ["body weight"],
                steps: ["Instruction \(title)"],
                tips: [],
                references: [],
                pdfPaths: []
            )
        }

        let legacyUUID = UUID()
        let existingUUID = UUID()
        let newUUID = UUID()
        let legacy = fixture(uuid: legacyUUID, id: 1, title: "Legacy Only", primary: ["legacy muscle"])
        let existing = fixture(uuid: existingUUID, id: 2, title: "Existing Name", primary: ["old muscle"])
        let updated = fixture(uuid: existingUUID, id: 2, title: "Updated Name", primary: ["new muscle"])
        let new = fixture(uuid: newUUID, id: -3, title: "New Name", primary: ["new catalog muscle"])

        let catalog = ExerciseCatalogMetadata.updatingCatalog([legacy, existing], with: [updated, new])

        XCTAssertEqual(catalog.map(\.uuid), [legacyUUID, existingUUID, newUUID])
        XCTAssertEqual(catalog.map(\.everkineticId), [1, 2, -3])
        XCTAssertEqual(catalog.first, legacy)
        XCTAssertEqual(catalog[1].title, "Updated Name")
        XCTAssertEqual(catalog[1].primaryMuscle, ["new muscle"])
        XCTAssertEqual(catalog[2].uuid, newUUID)
        XCTAssertEqual(Set(catalog.map(\.uuid)).count, catalog.count)
    }

    func testLegacyArtAddsPicturesWithoutChangingIdentityOrExistingArt() throws {
        func fixture(uuid: UUID, title: String, image: String? = nil) -> Exercise {
            Exercise(
                uuid: uuid, everkineticId: 1, title: title, alias: ["Old Name"], description: nil,
                primaryMuscle: ["chest"], secondaryMuscle: [], equipment: ["cable"], steps: [], tips: [],
                references: [], pdfPaths: ["pdf/0001-tension.pdf"], imageFilename: image, animationFilename: image
            )
        }
        let plainID = UUID()
        let illustratedID = UUID()
        let art = try JSONDecoder().decode([ExerciseCatalogMetadata.LegacyArt].self, from: Data("""
        [{"uuid": "\(plainID.uuidString)", "image": "0001-abc.jpg", "animation": "0001-abc.gif"},
         {"uuid": "\(illustratedID.uuidString)", "image": "0002-new.jpg", "animation": "0002-new.gif"}]
        """.utf8))

        let catalog = ExerciseCatalogMetadata.addingLegacyArt(art, to: [
            fixture(uuid: plainID, title: "Flyes: Cable"),
            fixture(uuid: illustratedID, title: "Air Bike", image: "0003-kept.gif")
        ])

        XCTAssertEqual(catalog[0].uuid, plainID)
        XCTAssertEqual(catalog[0].title, "Flyes: Cable")
        XCTAssertEqual(catalog[0].alias, ["Old Name"])
        XCTAssertEqual(catalog[0].pdfPaths, ["pdf/0001-tension.pdf"])
        XCTAssertEqual(catalog[0].imageURL?.absoluteString, "https://static.exercisedb.dev/media/abc.gif")
        XCTAssertEqual(catalog[1].animationFilename, "0003-kept.gif")
    }

    func testBundledLegacyExercisesAllHavePicturesExceptTheReviewedGap() {
        let store = ExerciseStore(customExercisesURL: nil)
        let withoutPicture = store.builtInExercises.filter { !$0.pdfPaths.isEmpty && $0.imageURL == nil }
        XCTAssertEqual(withoutPicture.map(\.title), ["Supermans"])
    }

    func testCatalogCleanupHidesOnlyReviewedDuplicatesAndKeepsCommonNames() throws {
        let store = ExerciseStore(customExercisesURL: nil)
        let byID = Dictionary(uniqueKeysWithValues: store.builtInExercises.map { ($0.uuid, $0) })
        let root = ExerciseStore.defaultBuiltInExercisesResourceURL
        let duplicates = try JSONDecoder().decode(
            [ExerciseCatalogMetadata.CatalogDuplicate].self,
            from: Data(contentsOf: root.appendingPathComponent("catalog-duplicates.json"))
        )
        XCTAssertEqual(duplicates.count, 58)
        for duplicate in duplicates {
            let hidden = try XCTUnwrap(byID[duplicate.uuid])
            let kept = try XCTUnwrap(byID[duplicate.keep], hidden.title)
            XCTAssertFalse(store.isBrowsable(hidden), hidden.title)
            XCTAssertTrue(store.isBrowsable(kept), kept.title)
            XCTAssertNotNil(kept.imageURL, kept.title)
            XCTAssertFalse(hidden.title.contains("V. "), hidden.title)
        }

        var importTargets = Set<UUID>()
        for name in ["hevy-aliases.json", "hevy-template-aliases.json"] {
            let aliases = try JSONDecoder().decode(
                [String: UUID].self, from: Data(contentsOf: root.appendingPathComponent(name))
            )
            importTargets.formUnion(aliases.values)
        }
        XCTAssertTrue(importTargets.isDisjoint(with: duplicates.map(\.uuid)))

        for title in ["Crunch", "Plank", "Leg Press", "Leg Extension", "Supermans", "Flyes: Cable", "Squat: Barbell"] {
            let exercise = try XCTUnwrap(store.builtInExercises.first { $0.title == title }, title)
            XCTAssertTrue(store.isBrowsable(exercise), title)
        }

        let custom = Exercise(uuid: UUID(), everkineticId: 10_000, title: "Mine", alias: [],
                              description: nil, primaryMuscle: [], secondaryMuscle: [], equipment: [],
                              steps: [], tips: [], references: [], pdfPaths: [])
        XCTAssertTrue(store.isBrowsable(custom))

        XCTAssertEqual(store.listed(store.builtInExercises, showingAll: false).count, 1_383)
        let everything = store.listed(store.builtInExercises, showingAll: true)
        XCTAssertEqual(everything.count, store.builtInExercises.count, "Nothing may become unreachable")
        XCTAssertEqual(everything.prefix(1_383).filter(store.isBrowsable).count, 1_383, "Listed exercises come first")
    }

    func testAddExerciseSearchFindsUnlistedExercisesEvenAfterBrowsing() {
        let store = ExerciseStore(customExercisesURL: nil)
        let catalog = AddExerciseCatalog(exercises: store.builtInExercises, store: store)

        let browsing = catalog.matches(search: "", muscleGroup: nil, equipment: nil)
        XCTAssertEqual(browsing.count, 1_383)
        XCTAssertEqual(catalog.moreCount, store.builtInExercises.count - 1_383)
        XCTAssertFalse(browsing.contains { $0.title == "1 2 Stick Drill" })

        // The next letter narrows the cached matches, which must still include unlisted ones.
        let noPicture = catalog.matches(search: "1 2 stick", muscleGroup: nil, equipment: nil)
        XCTAssertTrue(noPicture.contains { $0.title == "1 2 Stick Drill" })
        XCTAssertEqual(catalog.moreCount, 0)
        let duplicate = catalog.matches(search: "front raises: barbell", muscleGroup: nil, equipment: nil)
        XCTAssertTrue(duplicate.contains { $0.title == "Front Raises: Barbell" })

        let frontRaises = catalog.matches(search: "front raise", muscleGroup: nil, equipment: nil)
        let firstUnlisted = frontRaises.firstIndex { !store.isBrowsable($0) } ?? frontRaises.endIndex
        XCTAssertTrue(frontRaises[firstUnlisted...].allSatisfy { !store.isBrowsable($0) }, "Listed exercises come first")

        let all = catalog.matches(search: "", muscleGroup: nil, equipment: nil, showingAll: true)
        XCTAssertEqual(all.count, store.builtInExercises.count)
        XCTAssertEqual(catalog.moreCount, 0)

        // A filter with only unlisted exercises shows them instead of nothing.
        let massageBall = catalog.matches(search: "", muscleGroup: nil, equipment: "massage ball")
        XCTAssertFalse(massageBall.isEmpty)
        XCTAssertEqual(catalog.moreCount, 0)
    }

    func testOpenGymCatalogMetadataEnrichesHipThrustAndPreservesCustomIdentityThroughImport() throws {
        let (seedStore, url) = temporaryExerciseStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let customUUID = UUID()
        let custom = Exercise(
            uuid: customUUID,
            everkineticId: 10_000,
            title: "Hip Thrust (Barbell)",
            alias: [],
            description: nil,
            primaryMuscle: [],
            secondaryMuscle: [],
            equipment: [],
            steps: [],
            tips: [],
            references: [],
            pdfPaths: []
        )
        let originalData = try JSONEncoder().encode([custom])
        try originalData.write(to: url, options: .atomic)

        let store = ExerciseStore(customExercisesURL: url)
        let builtInCount = seedStore.builtInExercises.count
        let enriched = try XCTUnwrap(store.customExercises.first)
        XCTAssertEqual(enriched.uuid, customUUID)
        XCTAssertEqual(enriched.everkineticId, 10_000)
        XCTAssertEqual(enriched.title, custom.title)
        XCTAssertEqual(enriched.primaryMuscle, ["glutes"])
        XCTAssertEqual(enriched.secondaryMuscle, ["hamstrings", "quadriceps", "core"])
        XCTAssertEqual(enriched.equipment, ["barbell"])
        XCTAssertFalse(enriched.steps.isEmpty)
        XCTAssertNil(enriched.imageFilename)
        XCTAssertNil(enriched.animationFilename)
        XCTAssertEqual(store.builtInExercises.count, builtInCount)
        XCTAssertFalse(store.builtInExercises.contains { $0.uuid == customUUID })
        XCTAssertEqual(try Data(contentsOf: url), originalData)

        let data = workoutCSV(title: "Hip Thrust Import", exerciseTitle: custom.title)
        let firstResult = try HevyCSV.importData(
            data,
            into: persistenContainer.viewContext,
            exerciseStore: store
        )
        XCTAssertEqual(firstResult.importedWorkouts, 1)
        XCTAssertEqual(firstResult.createdExercises, 0)
        let workout = try XCTUnwrap(persistenContainer.viewContext.fetch(Workout.fetchRequest()).first)
        let workoutExercise = try XCTUnwrap(workout.workoutExercises?.firstObject as? WorkoutExercise)
        XCTAssertEqual(workoutExercise.exerciseUuid, customUUID)

        workout.title = "Renamed Hip Thrust Import"
        try persistenContainer.viewContext.save()
        let duplicateResult = try HevyCSV.importData(
            data,
            into: persistenContainer.viewContext,
            exerciseStore: store
        )
        XCTAssertEqual(duplicateResult.importedWorkouts, 0)
        XCTAssertEqual(duplicateResult.skippedDuplicateWorkouts, 1)
        XCTAssertEqual(workout.title, "Renamed Hip Thrust Import")
        XCTAssertEqual(try persistenContainer.viewContext.count(for: Workout.fetchRequest()), 1)
        XCTAssertEqual(try Data(contentsOf: url), originalData)
    }

    func testReviewedHipThrustAliasResolvesToBuiltInWithoutCreatingCustom() throws {
        let (store, url) = temporaryExerciseStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let curatedUUID = try XCTUnwrap(UUID(uuidString: "8C8CF9C9-DA60-524C-AFCF-716AFBA3FC6E"))
        let curated = try XCTUnwrap(store.builtInExercises.first { $0.uuid == curatedUUID })
        XCTAssertTrue(curated.alias.contains("Hip Thrust (Barbell)"))
        let builtInCount = store.builtInExercises.count

        let result = try HevyCSV.importData(
            workoutCSV(title: "Fresh Hip Thrust", exerciseTitle: "Hip Thrust (Barbell)"),
            into: persistenContainer.viewContext,
            exerciseStore: store
        )

        XCTAssertEqual(result.importedWorkouts, 1)
        XCTAssertEqual(result.createdExercises, 0)
        XCTAssertTrue(store.customExercises.isEmpty)
        XCTAssertEqual(store.builtInExercises.count, builtInCount)
        let workout = try XCTUnwrap(persistenContainer.viewContext.fetch(Workout.fetchRequest()).first)
        let workoutExercise = try XCTUnwrap(workout.workoutExercises?.firstObject as? WorkoutExercise)
        XCTAssertEqual(workoutExercise.exerciseUuid, curatedUUID)
    }

    func testPreferredAliasOverridesAmbiguousCatalogNameWhileUnreviewedNameRemainsUnchanged() {
        func fixture(
            uuid: UUID,
            title: String,
            alias: [String],
            primary: [String],
            secondary: [String],
            equipment: [String]
        ) -> Exercise {
            Exercise(
                uuid: uuid,
                everkineticId: 1,
                title: title,
                alias: alias,
                description: "Template description",
                primaryMuscle: primary,
                secondaryMuscle: secondary,
                equipment: equipment,
                steps: ["Template instruction"],
                tips: [],
                references: [],
                pdfPaths: []
            )
        }

        let firstUUID = UUID()
        let secondUUID = UUID()
        let first = fixture(
            uuid: firstUUID,
            title: "First Template",
            alias: ["Reviewed Movement", "Shared Ambiguous"],
            primary: ["first muscle"],
            secondary: ["first stabilizer"],
            equipment: ["first equipment"]
        )
        let second = fixture(
            uuid: secondUUID,
            title: "Second Template",
            alias: ["Reviewed Movement", "Shared Ambiguous"],
            primary: ["second muscle"],
            secondary: ["second stabilizer"],
            equipment: ["second equipment"]
        )
        let metadata = ExerciseCatalogMetadata(
            exercises: [first, second],
            preferredAliases: ["Reviewed Movement": secondUUID]
        )
        let reviewed = Exercise(
            uuid: UUID(),
            everkineticId: 10_000,
            title: "Reviewed Movement",
            alias: [],
            description: nil,
            primaryMuscle: [],
            secondaryMuscle: [],
            equipment: [],
            steps: [],
            tips: [],
            references: [],
            pdfPaths: []
        )
        let resolved = metadata.enriching(reviewed)
        XCTAssertEqual(resolved.uuid, reviewed.uuid)
        XCTAssertEqual(resolved.title, reviewed.title)
        XCTAssertEqual(resolved.primaryMuscle, second.primaryMuscle)
        XCTAssertEqual(resolved.secondaryMuscle, second.secondaryMuscle)
        XCTAssertEqual(resolved.equipment, second.equipment)
        XCTAssertEqual(resolved.steps, second.steps)

        let ambiguous = Exercise(
            uuid: UUID(),
            everkineticId: 10_000,
            title: "Shared Ambiguous",
            alias: [],
            description: nil,
            primaryMuscle: [],
            secondaryMuscle: [],
            equipment: [],
            steps: [],
            tips: [],
            references: [],
            pdfPaths: []
        )
        let unchanged = metadata.enriching(ambiguous)
        XCTAssertEqual(unchanged.uuid, ambiguous.uuid)
        XCTAssertEqual(unchanged.title, ambiguous.title)
        XCTAssertTrue(unchanged.primaryMuscle.isEmpty)
        XCTAssertTrue(unchanged.secondaryMuscle.isEmpty)
        XCTAssertTrue(unchanged.equipment.isEmpty)
        XCTAssertTrue(unchanged.steps.isEmpty)
    }

    func testExactCustomTitleWinsOverBuiltInTitleDuringHevyImport() throws {
        let (seedStore, url) = temporaryExerciseStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let builtIn = try XCTUnwrap(seedStore.builtInExercises.first)
        let customUUID = UUID()
        let custom = Exercise(
            uuid: customUUID,
            everkineticId: 10_000,
            title: builtIn.title,
            alias: [],
            description: nil,
            primaryMuscle: [],
            secondaryMuscle: [],
            equipment: [],
            steps: [],
            tips: [],
            references: [],
            pdfPaths: []
        )
        try JSONEncoder().encode([custom]).write(to: url, options: .atomic)

        let store = ExerciseStore(customExercisesURL: url)
        XCTAssertEqual(store.exercises.first?.uuid, builtIn.uuid)
        XCTAssertEqual(store.customExercises.first?.uuid, customUUID)
        let result = try HevyCSV.importData(
            workoutCSV(title: "Exact Custom Title", exerciseTitle: builtIn.title),
            into: persistenContainer.viewContext,
            exerciseStore: store
        )
        XCTAssertEqual(result.importedWorkouts, 1)
        XCTAssertEqual(result.createdExercises, 0)
        let workout = try XCTUnwrap(persistenContainer.viewContext.fetch(Workout.fetchRequest()).first)
        let workoutExercise = try XCTUnwrap(workout.workoutExercises?.firstObject as? WorkoutExercise)
        XCTAssertEqual(workoutExercise.exerciseUuid, customUUID)
    }
}
