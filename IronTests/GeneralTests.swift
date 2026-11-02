//
//  GeneralTests.swift
//  IronTests
//
//  Created by Karim Abou Zeid on 14.01.18.
//  Copyright © 2018 Karim Abou Zeid Software. All rights reserved.
//

import XCTest
import CoreData
import WorkoutDataKit
import UserNotifications
import HealthKit
import Combine
@testable import Iron

class GeneralTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }
    
    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        super.tearDown()
    }
    
    private func loadExercises() -> [Exercise] {
        let data = try! Data(contentsOf: ExerciseStore.defaultBuiltInExercisesURL)
        return try! JSONDecoder().decode([Exercise].self, from: data)
    }
    
    func testEverkineticGroupingSpeed() {
        let exercises = loadExercises()
        self.measure {
            _ = ExerciseStore.splitIntoMuscleGroups(exercises: exercises)
        }
    }
    
    func testEverkineticGrouping() {
        let exercises = loadExercises()
        let groups = ExerciseStore.splitIntoMuscleGroups(exercises: exercises)
        var totalCount = 0
        for group in groups {
            totalCount += group.exercises.count

            for exercise in group.exercises {
                XCTAssert(exercise.muscleGroup == group.title)
            }
        }
        XCTAssert(totalCount == exercises.count)
    }

    func testEverkineticPDFsExist() {
        let exercises = loadExercises()
        for exercise in exercises {
            for pdf in exercise.pdfPaths {
                let url = ExerciseStore.defaultBuiltInExercisesResourceURL.appendingPathComponent(pdf)
                XCTAssertNoThrow(try Data(contentsOf: url))
            }
        }
    }

    func testUniq() {
        var array = ["Hello","Me","That","Me","Hello","Me","as","the"]
        
        let arrayUniqed = array.uniqed()
        XCTAssertEqual(arrayUniqed, ["Hello","Me","That","as","the"])
        
        array.uniq()
        XCTAssertEqual(array, arrayUniqed)
    }
    
    func testSortByFrequency() {
        var array = ["Hello","Me","That","Me","Hello","Me"]
        
        let arraySorted = array.sortedByFrequency()
        XCTAssertEqual(arraySorted, ["That", "Hello", "Hello", "Me", "Me", "Me"])
        
        array.sortByFrequency()
        XCTAssertEqual(array, arraySorted)
    }

    func testWeightUnitConversion() {
        // correct conversion
        XCTAssertEqual(WeightUnit.convert(weight: 20, from: .metric, to: .imperial).rounded(), 44)
        XCTAssertEqual(WeightUnit.convert(weight: 45, from: .imperial, to: .metric).rounded(), 20)
        
        // no precision loss when converting back and forth
        XCTAssertEqual(WeightUnit.convert(weight: WeightUnit.convert(weight: 20, from: .metric, to: .imperial), from: .imperial, to: .metric), 20)
        XCTAssertEqual(WeightUnit.convert(weight: WeightUnit.convert(weight: 127.5, from: .metric, to: .imperial), from: .imperial, to: .metric), 127.5)
        XCTAssertEqual(WeightUnit.convert(weight: WeightUnit.convert(weight: 123980323.59392, from: .metric, to: .imperial), from: .imperial, to: .metric), 123980323.59392)
        
        XCTAssertEqual(WeightUnit.convert(weight: WeightUnit.convert(weight: 45, from: .imperial, to: .metric), from: .metric, to: .imperial), 45)
        XCTAssertEqual(WeightUnit.convert(weight: WeightUnit.convert(weight: 900, from: .imperial, to: .metric), from: .metric, to: .imperial), 900)
        XCTAssertEqual(WeightUnit.convert(weight: WeightUnit.convert(weight: 123980323.59392, from: .imperial, to: .metric), from: .metric, to: .imperial), 123980323.59392)
    }
}

final class RestTimerStoreTests: XCTestCase {
    private final class Effects {
        var notificationUpdates: [(Date?, TimeInterval?)] = []
        var watchUpdates: [Date?] = []
        var scheduledDeadlines: [Date] = []
        var scheduledHandlers: [() -> Void] = []
        var cancellations = 0
        var announcements = 0
        var adjustmentTicks = 0
    }

    private var suiteNames: [String] = []

    override func tearDown() {
        for suiteName in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    private func makeStore(
        now: @escaping () -> Date,
        configureDefaults: ((UserDefaults) -> Void)? = nil,
        isAppActive: @escaping () -> Bool = { true }
    ) -> (RestTimerStore, Effects) {
        let suiteName = "RestTimerStoreTests.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        configureDefaults?(defaults)
        let effects = Effects()
        let store = RestTimerStore(
            userDefaults: defaults,
            now: now,
            keepRunning: { false },
            notificationUpdater: { deadline, total in
                effects.notificationUpdates.append((deadline, total))
            },
            watchUpdater: { end in effects.watchUpdates.append(end) },
            expiryScheduler: { deadline, handler in
                effects.scheduledDeadlines.append(deadline)
                effects.scheduledHandlers.append(handler)
                return { effects.cancellations += 1 }
            },
            expiryAnnouncement: { effects.announcements += 1 },
            adjustmentTick: { effects.adjustmentTicks += 1 },
            isAppActive: isAppActive
        )
        return (store, effects)
    }

    func testPauseClearsDeadlineAndDoesNotScheduleExpiry() {
        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, effects) = makeStore(now: { currentTime })
        store.start(duration: 90)
        currentTime.addTimeInterval(20)

        store.pause()

        XCTAssertTrue(store.isPaused)
        XCTAssertNil(store.restTimerStart)
        XCTAssertEqual(store.restTimerRemainingTime ?? -1, 70, accuracy: 0.001)
        XCTAssertNil(effects.notificationUpdates.last?.0)
        XCTAssertEqual(effects.scheduledHandlers.count, 1)
        XCTAssertEqual(effects.cancellations, 1)
    }

    func testResumeUsesCapturedRemainingInsteadOfRestartingTotalDuration() {
        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, effects) = makeStore(now: { currentTime })
        store.start(duration: 120)
        currentTime.addTimeInterval(45)
        store.pause()
        currentTime.addTimeInterval(30)

        store.resume()

        XCTAssertFalse(store.isPaused)
        XCTAssertEqual(store.restTimerDuration, 120)
        XCTAssertEqual(store.restTimerRemainingTime ?? -1, 75, accuracy: 0.001)
        XCTAssertEqual(store.restTimerEnd, currentTime.addingTimeInterval(75))
        XCTAssertEqual(effects.scheduledDeadlines.last, currentTime.addingTimeInterval(75))
    }

    func testAdjustToZeroCancelsAllTimerState() {
        let currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, effects) = makeStore(now: { currentTime })
        store.start(duration: 30)

        store.adjust(by: -30)

        XCTAssertNil(store.restTimerStart)
        XCTAssertNil(store.restTimerDuration)
        XCTAssertNil(store.restTimerRemainingTime)
        XCTAssertNil(effects.notificationUpdates.last?.0)
        XCTAssertEqual(effects.announcements, 0)
        XCTAssertEqual(effects.adjustmentTicks, 0)
        effects.scheduledHandlers[0]()
        XCTAssertEqual(effects.announcements, 0)
    }

    func testSharedAdjustmentsAndWatchUpdatesDoNotTick() throws {
        let currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, effects) = makeStore(now: { currentTime })
        store.start(duration: 90)

        store.adjust(by: 15)
        store.applyWatchUpdate(end: try XCTUnwrap(store.restTimerEnd).addingTimeInterval(-15))
        store.pause()
        store.adjust(by: 15)
        store.applyWatchUpdate(end: nil, pausedRemaining: 90)

        XCTAssertEqual(effects.adjustmentTicks, 0)
        XCTAssertEqual(effects.announcements, 0)
    }

    func testLocalAdjustmentOptInTicksOnceWithoutAnnouncingCompletion() {
        let currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, effects) = makeStore(now: { currentTime })
        store.start(duration: 15)

        store.adjust(by: -15, feedback: true)

        XCTAssertNil(store.restTimerRemainingTime)
        XCTAssertEqual(effects.adjustmentTicks, 1)
        XCTAssertEqual(effects.announcements, 0)
    }

    func testLocalRunningAndPausedAdjustmentsTickOncePerAction() {
        let currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, effects) = makeStore(now: { currentTime })
        store.start(duration: 90)

        store.adjust(by: 15, feedback: true)
        XCTAssertEqual(store.restTimerRemainingTime, 105)
        XCTAssertEqual(effects.adjustmentTicks, 1)
        XCTAssertEqual(effects.notificationUpdates.last?.0, currentTime.addingTimeInterval(105))
        XCTAssertEqual(effects.watchUpdates.last ?? nil, currentTime.addingTimeInterval(105))

        store.pause()
        store.adjust(by: -15, feedback: true)
        XCTAssertTrue(store.isPaused)
        XCTAssertEqual(store.restTimerRemainingTime, 90)
        XCTAssertEqual(effects.adjustmentTicks, 2)
        XCTAssertNil(effects.notificationUpdates.last?.0)
        XCTAssertEqual(effects.announcements, 0)
    }

    func testPausedAdjustmentToZeroDoesNotAnnounceCompletion() {
        let currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, effects) = makeStore(now: { currentTime })
        store.start(duration: 15)
        store.pause()

        store.adjust(by: -15)
        effects.scheduledHandlers[0]()

        XCTAssertFalse(store.isPaused)
        XCTAssertNil(store.restTimerRemainingTime)
        XCTAssertEqual(effects.announcements, 0)
        XCTAssertEqual(effects.adjustmentTicks, 0)
    }

    func testAdjustingAlreadyExpiredTimerDoesNotRepeatCompletion() {
        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, effects) = makeStore(now: { currentTime })
        store.start(duration: 15)
        currentTime.addTimeInterval(15)
        effects.scheduledHandlers[0]()
        XCTAssertEqual(effects.announcements, 1)

        store.adjust(by: -15)

        XCTAssertNil(store.restTimerRemainingTime)
        XCTAssertEqual(effects.announcements, 1)
        XCTAssertEqual(effects.adjustmentTicks, 0)
    }

    func testBackgroundFeedbackUsesScheduledNotificationOnly() {
        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, effects) = makeStore(now: { currentTime }, isAppActive: { false })
        store.start(duration: 30)
        store.adjust(by: 15, feedback: true)

        XCTAssertEqual(effects.adjustmentTicks, 0)
        XCTAssertEqual(effects.notificationUpdates.last?.0, currentTime.addingTimeInterval(45))
        currentTime.addTimeInterval(45)
        effects.scheduledHandlers.last?()

        XCTAssertEqual(effects.announcements, 0)
    }

    func testInvalidOrMissingTimerDoesNotTickEvenWithOptIn() {
        let currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, effects) = makeStore(now: { currentTime })
        store.adjust(by: 15, feedback: true)
        store.start(duration: 90)
        store.adjust(by: .infinity, feedback: true)
        store.adjust(by: .nan, feedback: true)

        XCTAssertEqual(store.restTimerRemainingTime, 90)
        XCTAssertEqual(effects.adjustmentTicks, 0)
    }

    func testPositiveAdjustmentRestartsAnExpiredTimerFromNow() {
        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, _) = makeStore(now: { currentTime })
        store.start(duration: 10)
        currentTime.addTimeInterval(15)

        store.adjust(by: 30)

        XCTAssertEqual(store.restTimerStart, currentTime)
        XCTAssertEqual(store.restTimerDuration, 30)
        XCTAssertEqual(store.restTimerRemainingTime ?? -1, 30, accuracy: 0.001)
    }

    func testWatchUpdatePublishesOneEffectBatchWithoutEchoingToWatch() {
        let currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, effects) = makeStore(now: { currentTime })
        let end = currentTime.addingTimeInterval(45)

        store.applyWatchUpdate(end: end)

        XCTAssertEqual(store.restTimerEnd, end)
        XCTAssertEqual(effects.notificationUpdates.count, 1)
        XCTAssertEqual(effects.scheduledDeadlines, [end])
        XCTAssertTrue(effects.watchUpdates.isEmpty)
    }

    func testPausedIntervalRetainsTotalAndElapsedWithoutRunningDeadline() throws {
        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, effects) = makeStore(now: { currentTime })
        store.start(duration: 120)
        currentTime.addTimeInterval(45)
        store.pause()
        currentTime.addTimeInterval(300)

        let interval = try XCTUnwrap(store.restTimerInterval)
        XCTAssertEqual(interval.upperBound.timeIntervalSince(interval.lowerBound), 120, accuracy: 0.001)
        XCTAssertEqual(currentTime.timeIntervalSince(interval.lowerBound), 45, accuracy: 0.001)
        XCTAssertEqual(store.restTimerRemainingTime, 75)
        XCTAssertNil(store.restTimerStart)
        XCTAssertNil(store.restTimerEnd)
        XCTAssertNil(effects.notificationUpdates.last?.0)
        XCTAssertEqual(effects.watchUpdates.count, 2)
        XCTAssertNil(effects.watchUpdates.last ?? nil)
        XCTAssertEqual(effects.scheduledDeadlines.count, 1)
    }

    func testWatchAndPhoneAdjustmentsPreserveTheSameElapsedTime() throws {
        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let start = currentTime
        let (phone, _) = makeStore(now: { currentTime })
        let (watch, effects) = makeStore(now: { currentTime })
        phone.start(duration: 120)
        watch.applyWatchUpdate(end: currentTime.addingTimeInterval(120))
        currentTime.addTimeInterval(45)

        for delta in [TimeInterval(15), -15] {
            phone.adjust(by: delta)
            watch.applyWatchUpdate(end: try XCTUnwrap(watch.restTimerEnd).addingTimeInterval(delta))

            XCTAssertEqual(watch.restTimerStart, start)
            XCTAssertEqual(watch.restTimerInterval, phone.restTimerInterval)
            XCTAssertEqual(watch.restTimerDuration, phone.restTimerDuration)
            XCTAssertEqual(watch.restTimerRemainingTime, phone.restTimerRemainingTime)
        }

        phone.pause()
        watch.applyWatchUpdate(end: nil, pausedRemaining: phone.restTimerRemainingTime)
        currentTime.addTimeInterval(300)
        for delta in [TimeInterval(15), -15] {
            phone.adjust(by: delta)
            watch.applyWatchUpdate(end: nil, pausedRemaining: phone.restTimerRemainingTime)

            XCTAssertTrue(watch.isPaused)
            XCTAssertNil(watch.restTimerEnd)
            XCTAssertEqual(watch.restTimerInterval, phone.restTimerInterval)
            XCTAssertEqual(watch.restTimerDuration, phone.restTimerDuration)
            XCTAssertNil(effects.notificationUpdates.last?.0)
        }

        phone.resume()
        watch.applyWatchUpdate(end: phone.restTimerEnd)
        XCTAssertFalse(watch.isPaused)
        XCTAssertEqual(watch.restTimerInterval, phone.restTimerInterval)
        XCTAssertEqual(watch.restTimerDuration, 120)
        XCTAssertEqual(watch.restTimerRemainingTime, 75)
        XCTAssertEqual(effects.scheduledDeadlines.last, phone.restTimerEnd)
        XCTAssertTrue(effects.watchUpdates.isEmpty)
    }

    func testWatchPositiveAdjustmentRestartsExpiredIntervalLikePhone() {
        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, _) = makeStore(now: { currentTime })
        store.start(duration: 10)
        currentTime.addTimeInterval(15)

        store.applyWatchUpdate(end: currentTime.addingTimeInterval(15))

        XCTAssertEqual(store.restTimerStart, currentTime)
        XCTAssertEqual(store.restTimerDuration, 15)
        XCTAssertEqual(store.restTimerRemainingTime, 15)
    }

    func testWatchResumeKeepsTotalAcrossDeliveryDelay() {
        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, _) = makeStore(now: { currentTime })
        store.start(duration: 120)
        currentTime.addTimeInterval(45)
        store.applyWatchUpdate(end: nil, pausedRemaining: 75)
        currentTime.addTimeInterval(300)
        let resumedAt = currentTime
        let end = resumedAt.addingTimeInterval(75)
        currentTime.addTimeInterval(2)

        store.applyWatchUpdate(end: end)

        XCTAssertEqual(store.restTimerDuration, 120)
        XCTAssertEqual(store.restTimerStart, resumedAt.addingTimeInterval(-45))
        XCTAssertEqual(store.restTimerEnd, end)
        XCTAssertEqual(store.restTimerRemainingTime, 73)
    }

    func testExplicitWatchStartReplacesPreviousRestInterval() {
        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, _) = makeStore(now: { currentTime })
        store.start(duration: 120)
        currentTime.addTimeInterval(45)
        let newStart = currentTime.addingTimeInterval(-2)

        store.applyWatchUpdate(end: newStart.addingTimeInterval(90), startedAt: newStart)

        XCTAssertEqual(store.restTimerStart, newStart)
        XCTAssertEqual(store.restTimerDuration, 90)
        XCTAssertEqual(store.restTimerRemainingTime, 88)
    }

    func testWatchSkipClearsPausedIntervalAndRemaining() {
        let currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, effects) = makeStore(now: { currentTime })
        store.applyWatchUpdate(end: nil, pausedRemaining: 45)
        XCTAssertNotNil(store.restTimerInterval)

        store.applyWatchUpdate(end: nil)

        XCTAssertFalse(store.isPaused)
        XCTAssertNil(store.restTimerInterval)
        XCTAssertNil(store.restTimerDuration)
        XCTAssertNil(store.restTimerRemainingTime)
        XCTAssertNil(effects.notificationUpdates.last?.0)
        XCTAssertTrue(effects.watchUpdates.isEmpty)
    }

    func testCancelledExpiryCallbackCannotAnnounceAfterReplacement() {
        let currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, effects) = makeStore(now: { currentTime })
        store.start(duration: 30)
        let staleHandler = effects.scheduledHandlers[0]
        store.setRemaining(60)

        staleHandler()

        XCTAssertEqual(effects.announcements, 0)
        XCTAssertEqual(store.restTimerRemainingTime ?? -1, 60, accuracy: 0.001)
    }

    func testInitializationRestoresExpiryForPersistedRunningTimer() {
        let currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let start = currentTime.addingTimeInterval(-15)
        let (store, effects) = makeStore(
            now: { currentTime },
            configureDefaults: { defaults in
                defaults.restTimerStart = start
                defaults.restTimerDuration = 60
            }
        )

        XCTAssertEqual(store.restTimerRemainingTime ?? -1, 45, accuracy: 0.001)
        XCTAssertEqual(effects.scheduledDeadlines, [currentTime.addingTimeInterval(45)])
    }

    func testInitializationDoesNotSchedulePersistedPausedTimer() throws {
        let currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, effects) = makeStore(
            now: { currentTime },
            configureDefaults: { defaults in
                defaults.restTimerDuration = 60
                defaults.restTimerPausedRemaining = 20
            }
        )

        XCTAssertTrue(store.isPaused)
        let interval = try XCTUnwrap(store.restTimerInterval)
        XCTAssertEqual(interval.upperBound.timeIntervalSince(interval.lowerBound), 60)
        XCTAssertNil(store.restTimerEnd)
        XCTAssertTrue(effects.scheduledDeadlines.isEmpty)
    }

    func testRestTimerSoundRequiresBothAppAndSystemSoundSettings() {
        XCTAssertTrue(NotificationManager.shouldPlayRestTimerSound(
            appSoundsEnabled: true,
            systemSoundSetting: .enabled
        ))
        XCTAssertFalse(NotificationManager.shouldPlayRestTimerSound(
            appSoundsEnabled: false,
            systemSoundSetting: .enabled
        ))
        XCTAssertFalse(NotificationManager.shouldPlayRestTimerSound(
            appSoundsEnabled: true,
            systemSoundSetting: .disabled
        ))
    }
}

final class HealthReplacementCoordinatorTests: XCTestCase {
    private enum ExpectedError: Error, Equatable {
        case save
        case cleanup
    }

    func testReplacementSavesNewObjectsBeforeDeletingExactOldObjects() {
        var operations: [String] = []
        var savedObjects: [Int] = []
        var deletedObjects: [Int] = []
        var result: Result<Void, Error>?

        HealthManager.coordinateReplacement(
            oldObjects: [11, 12],
            replacements: [21],
            intent: .replace,
            save: { objects, completion in
                operations.append("save")
                savedObjects = objects
                completion(.success(()))
            },
            delete: { objects, completion in
                operations.append("delete")
                deletedObjects = objects
                completion(.success(()))
            },
            completion: { result = $0 }
        )

        XCTAssertEqual(operations, ["save", "delete"])
        XCTAssertEqual(savedObjects, [21])
        XCTAssertEqual(deletedObjects, [11, 12])
        XCTAssertNoThrow(try result?.get())
    }

    func testFailedReplacementSaveKeepsOldObjects() {
        var deleted = false
        var capturedError: ExpectedError?

        HealthManager.coordinateReplacement(
            oldObjects: [11],
            replacements: [21],
            intent: .replace,
            save: { _, completion in completion(.failure(ExpectedError.save)) },
            delete: { _, _ in deleted = true },
            completion: { result in
                if case .failure(let error) = result {
                    capturedError = error as? ExpectedError
                }
            }
        )

        XCTAssertFalse(deleted)
        XCTAssertEqual(capturedError, .save)
    }

    func testCleanupFailureIsReportedAfterSuccessfulSave() {
        var operations: [String] = []
        var capturedError: ExpectedError?

        HealthManager.coordinateReplacement(
            oldObjects: [11],
            replacements: [21],
            intent: .replace,
            save: { _, completion in
                operations.append("save")
                completion(.success(()))
            },
            delete: { _, completion in
                operations.append("delete")
                completion(.failure(ExpectedError.cleanup))
            },
            completion: { result in
                if case .failure(let error) = result {
                    capturedError = error as? ExpectedError
                }
            }
        )

        XCTAssertEqual(operations, ["save", "delete"])
        XCTAssertEqual(capturedError, .cleanup)
    }

    func testEmptyReplacementIsNoOpWithoutExplicitDeleteIntent() {
        var operations: [String] = []
        var succeeded = false

        HealthManager.coordinateReplacement(
            oldObjects: [11],
            replacements: [Int](),
            intent: .replace,
            save: { _, _ in operations.append("save") },
            delete: { _, _ in operations.append("delete") },
            completion: { result in
                if case .success = result { succeeded = true }
            }
        )

        XCTAssertTrue(succeeded)
        XCTAssertTrue(operations.isEmpty)
    }

    func testExplicitDeleteRemovesCapturedOldObjectsWithoutSaving() {
        var saved = false
        var deletedObjects: [Int] = []
        var succeeded = false

        HealthManager.coordinateReplacement(
            oldObjects: [11, 12],
            replacements: [Int](),
            intent: .delete,
            save: { _, _ in saved = true },
            delete: { objects, completion in
                deletedObjects = objects
                completion(.success(()))
            },
            completion: { result in
                if case .success = result { succeeded = true }
            }
        )

        XCTAssertFalse(saved)
        XCTAssertEqual(deletedObjects, [11, 12])
        XCTAssertTrue(succeeded)
    }

    func testReplacementMetadataStripsHealthSyncIdentityAndPreservesOtherMetadata() {
        let metadata: [String: Any] = [
            HKMetadataKeySyncIdentifier: "old-sync-id",
            HKMetadataKeySyncVersion: 7,
            HKMetadataKeyExternalUUID: "old-external-id",
            HKMetadataKeyIndoorWorkout: true,
            HKMetadataKeyWorkoutBrandName: "Old title"
        ]

        let replacement = HealthManager.replacementMetadata(
            copying: metadata,
            externalUUID: "new-external-id",
            title: "New title"
        )

        XCTAssertNil(replacement[HKMetadataKeySyncIdentifier])
        XCTAssertNil(replacement[HKMetadataKeySyncVersion])
        XCTAssertEqual(replacement[HKMetadataKeyExternalUUID] as? String, "new-external-id")
        XCTAssertEqual(replacement[HKMetadataKeyIndoorWorkout] as? Bool, true)
        XCTAssertEqual(replacement[HKMetadataKeyWorkoutBrandName] as? String, "New title")
    }

    func testWorkoutFieldMatchingIncludesDuration() {
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let end = start.addingTimeInterval(60)

        XCTAssertTrue(HealthManager.workoutFieldsMatch(
            existingStart: start,
            existingEnd: end,
            existingDuration: 60,
            existingTitle: "Workout",
            desiredStart: start,
            desiredEnd: end,
            desiredDuration: 60,
            desiredTitle: "Workout"
        ))
        XCTAssertFalse(HealthManager.workoutFieldsMatch(
            existingStart: start,
            existingEnd: end,
            existingDuration: 30,
            existingTitle: "Workout",
            desiredStart: start,
            desiredEnd: end,
            desiredDuration: 60,
            desiredTitle: "Workout"
        ))
    }

    func testWorkoutIntervalValidationRejectsInvalidDatesAndDurations() {
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let end = start.addingTimeInterval(60)

        XCTAssertTrue(HealthManager.isValidWorkoutInterval(
            start: start,
            end: end,
            duration: 60
        ))
        XCTAssertFalse(HealthManager.isValidWorkoutInterval(
            start: end,
            end: start,
            duration: 60
        ))
        XCTAssertFalse(HealthManager.isValidWorkoutInterval(
            start: start,
            end: end,
            duration: .nan
        ))
        XCTAssertFalse(HealthManager.isValidWorkoutInterval(
            start: Date(timeIntervalSinceReferenceDate: .infinity),
            end: end,
            duration: 60
        ))
    }
}

final class HealthMutationCoordinatorTests: XCTestCase {
    func testSecondQueryWaitsForFirstCleanup() throws {
        let coordinator = HealthManager.MutationCoordinator()
        var operations: [String] = []
        var finishFirst: (() -> Void)?

        coordinator.enqueue { finish in
            operations.append("first query")
            operations.append("first save")
            finishFirst = {
                operations.append("first cleanup")
                finish()
            }
        }
        coordinator.enqueue { finish in
            operations.append("second query")
            finish()
        }

        XCTAssertEqual(operations, ["first query", "first save"])
        try XCTUnwrap(finishFirst)()
        XCTAssertEqual(
            operations,
            ["first query", "first save", "first cleanup", "second query"]
        )
    }

    func testQueuedSaveThenDeleteEndsDeleted() throws {
        let coordinator = HealthManager.MutationCoordinator()
        var sampleExists = false
        var finishSave: (() -> Void)?

        coordinator.enqueue { finish in
            sampleExists = true
            finishSave = finish
        }
        coordinator.enqueue { finish in
            XCTAssertTrue(sampleExists)
            sampleExists = false
            finish()
        }

        XCTAssertTrue(sampleExists)
        try XCTUnwrap(finishSave)()
        XCTAssertFalse(sampleExists)
    }

    func testFailedJobReleasesNextMutation() throws {
        let coordinator = HealthManager.MutationCoordinator()
        var operations: [String] = []
        var failFirst: (() -> Void)?

        coordinator.enqueue { finish in
            operations.append("first failed")
            failFirst = finish
        }
        coordinator.enqueue { finish in
            operations.append("second started")
            finish()
        }

        XCTAssertEqual(operations, ["first failed"])
        try XCTUnwrap(failFirst)()
        XCTAssertEqual(operations, ["first failed", "second started"])
    }

    func testDuplicateFinishCannotAdvanceQueueTwice() throws {
        let coordinator = HealthManager.MutationCoordinator()
        var operations: [String] = []
        var finishFirst: (() -> Void)?
        var finishSecond: (() -> Void)?

        coordinator.enqueue { finish in
            operations.append("first")
            finishFirst = finish
        }
        coordinator.enqueue { finish in
            operations.append("second")
            finishSecond = finish
        }
        coordinator.enqueue { finish in
            operations.append("third")
            finish()
        }

        let firstCompletion = try XCTUnwrap(finishFirst)
        firstCompletion()
        firstCompletion()
        XCTAssertEqual(operations, ["first", "second"])

        try XCTUnwrap(finishSecond)()
        XCTAssertEqual(operations, ["first", "second", "third"])
    }
}

final class WatchWorkoutPersistenceTests: XCTestCase {
    private func snapshot(weight: Double? = 40) -> WatchWorkoutSnapshot {
        let set = WatchWorkoutSet(order: 1, weight: weight, reps: 5)
        let exercise = WatchWorkoutExercise(order: 1, name: "Squat", sets: [set])
        return WatchWorkoutSnapshot(
            workoutID: UUID(),
            startDate: Date(timeIntervalSinceReferenceDate: 0),
            exercises: [exercise],
            selectedSetID: set.id,
            revision: 1,
            updatedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
    }

    private func event(
        workoutID: UUID,
        sequence: Int64,
        kind: WatchWorkoutEventKind = .setUpdated
    ) -> WatchWorkoutEvent {
        WatchWorkoutEvent(
            workoutID: workoutID, sequence: sequence, kind: kind,
            createdAt: Date(timeIntervalSinceReferenceDate: 100)
        )
    }

    func testLegacyPersistedStateKeysRemainDecodable() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "snapshot": NSNull(),
            "outbox": [],
            "nextSequence": 7
        ])

        let decoded = try XCTUnwrap(
            WatchWorkoutWire.decode(WatchWorkoutPersistedState.self, from: data)
        )
        XCTAssertNil(decoded.snapshot)
        XCTAssertTrue(decoded.outbox.isEmpty)
        XCTAssertEqual(decoded.nextSequence, 7)

        let reencoded = try XCTUnwrap(WatchWorkoutWire.encode(decoded))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["outbox", "nextSequence"])

        let populated = WatchWorkoutPersistedState(snapshot: snapshot())
        let populatedData = try XCTUnwrap(WatchWorkoutWire.encode(populated))
        let populatedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: populatedData) as? [String: Any]
        )
        XCTAssertEqual(
            Set(populatedObject.keys),
            ["snapshot", "outbox", "nextSequence"]
        )
    }

    func testSnapshotEventAndSequenceArePreparedTogether() throws {
        let oldSnapshot = snapshot()
        var newSnapshot = oldSnapshot
        newSnapshot.revision += 1
        let current = WatchWorkoutPersistedState(snapshot: oldSnapshot)

        let prepared = try WatchWorkoutPersistence.prepareEvent(
            current: current,
            snapshotChange: .replace(newSnapshot)
        ) { sequence, persistedSnapshot in
            self.event(
                workoutID: persistedSnapshot?.workoutID ?? oldSnapshot.workoutID,
                sequence: sequence
            )
        }

        XCTAssertEqual(prepared.state.snapshot, newSnapshot)
        XCTAssertEqual(prepared.state.nextSequence, 1)
        XCTAssertEqual(prepared.state.outbox, [prepared.result])
        XCTAssertEqual(prepared.result.sequence, 1)
        XCTAssertEqual(
            WatchWorkoutWire.decode(WatchWorkoutPersistedState.self, from: prepared.data),
            prepared.state
        )
    }

    func testInjectedEncodeFailureLeavesCandidateUnpublished() {
        let original = WatchWorkoutPersistedState(snapshot: snapshot(), nextSequence: 4)

        XCTAssertThrowsError(try WatchWorkoutPersistence.prepare(
            current: original,
            encode: { _ in nil }
        ) { candidate in
            candidate.snapshot = nil
            candidate.nextSequence = 9
        }) { error in
            XCTAssertEqual(error as? WatchWorkoutPersistenceError, .encodingFailed)
        }
        XCTAssertNotNil(original.snapshot)
        XCTAssertEqual(original.nextSequence, 4)
        XCTAssertTrue(original.outbox.isEmpty)
    }

    func testNonFinitePayloadFailsRealJSONEncoding() {
        let original = WatchWorkoutPersistedState(snapshot: snapshot())
        let invalid = snapshot(weight: .nan)

        XCTAssertThrowsError(try WatchWorkoutPersistence.prepare(
            current: original
        ) { candidate in
            candidate.snapshot = invalid
        }) { error in
            XCTAssertEqual(error as? WatchWorkoutPersistenceError, .encodingFailed)
        }
        XCTAssertEqual(original.snapshot?.exercises.first?.sets.first?.weight, 40)
    }

    func testDiscardClearsSnapshotAndQueuesEventAtomically() throws {
        let currentSnapshot = snapshot()
        let current = WatchWorkoutPersistedState(snapshot: currentSnapshot, nextSequence: 2)

        let prepared = try WatchWorkoutPersistence.prepareEvent(
            current: current,
            snapshotChange: .replace(nil)
        ) { sequence, _ in
            self.event(
                workoutID: currentSnapshot.workoutID,
                sequence: sequence,
                kind: .workoutDiscarded
            )
        }

        XCTAssertNil(prepared.state.snapshot)
        XCTAssertEqual(prepared.state.nextSequence, 3)
        XCTAssertEqual(prepared.state.outbox.map(\.kind), [.workoutDiscarded])
    }

    func testEventOnlyEncodeFailureDoesNotConsumeSequence() {
        let currentSnapshot = snapshot()
        let original = WatchWorkoutPersistedState(snapshot: currentSnapshot, nextSequence: 12)

        XCTAssertThrowsError(try WatchWorkoutPersistence.prepareEvent(
            current: original,
            snapshotChange: .keep,
            encode: { _ in nil }
        ) { sequence, _ in
            self.event(workoutID: currentSnapshot.workoutID, sequence: sequence)
        })
        XCTAssertEqual(original.nextSequence, 12)
        XCTAssertTrue(original.outbox.isEmpty)
    }

    func testAcknowledgementFailureRetainsEventsAndSuccessRemovesOnlyRequestedIDs() throws {
        let workoutID = UUID()
        let first = event(workoutID: workoutID, sequence: 1)
        let second = event(workoutID: workoutID, sequence: 2)
        let original = WatchWorkoutPersistedState(outbox: [first, second], nextSequence: 2)

        XCTAssertThrowsError(try WatchWorkoutPersistence.prepare(
            current: original,
            encode: { _ in nil }
        ) { candidate in
            candidate.outbox.removeAll { $0.id == first.id }
        })
        XCTAssertEqual(original.outbox, [first, second])

        let acknowledged = try WatchWorkoutPersistence.prepare(current: original) { candidate in
            candidate.outbox.removeAll { $0.id == first.id }
        }
        XCTAssertEqual(acknowledged.state.outbox, [second])
        XCTAssertEqual(acknowledged.state.nextSequence, 2)
    }

    func testSequenceOverflowThrowsWithoutMutation() {
        let currentSnapshot = snapshot()
        let original = WatchWorkoutPersistedState(
            snapshot: currentSnapshot,
            nextSequence: .max
        )

        XCTAssertThrowsError(try WatchWorkoutPersistence.prepareEvent(
            current: original,
            snapshotChange: .keep
        ) { sequence, _ in
            self.event(workoutID: currentSnapshot.workoutID, sequence: sequence)
        }) { error in
            XCTAssertEqual(error as? WatchWorkoutPersistenceError, .sequenceOverflow)
        }
        XCTAssertEqual(original.nextSequence, .max)
        XCTAssertTrue(original.outbox.isEmpty)
    }

    func testRevisionOverflowThrowsWithoutWrapping() {
        var currentSnapshot = snapshot()
        currentSnapshot.revision = .max

        XCTAssertThrowsError(
            try WatchWorkoutPersistence.incrementRevision(&currentSnapshot)
        ) { error in
            XCTAssertEqual(error as? WatchWorkoutPersistenceError, .revisionOverflow)
        }
        XCTAssertEqual(currentSnapshot.revision, .max)
    }
}

final class BodyWeightSampleSelectionTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSinceReferenceDate: 10_000)

    private func sample(offset: TimeInterval) -> HKQuantitySample {
        let date = referenceDate.addingTimeInterval(offset)
        return HKQuantitySample(
            type: HKQuantityType.quantityType(forIdentifier: .bodyMass)!,
            quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: 80),
            start: date,
            end: date
        )
    }

    func testNearbyPastSampleWinsOverMoreDistantFutureSample() {
        let past = sample(offset: -600)
        let future = sample(offset: 3_600)
        XCTAssertEqual(BodyWeightFetcher.closestSample(to: referenceDate, in: [future, past]), past)
    }

    func testNearbyFutureSampleWinsOverMoreDistantPastSample() {
        let past = sample(offset: -3_600)
        let future = sample(offset: 600)
        XCTAssertEqual(BodyWeightFetcher.closestSample(to: referenceDate, in: [past, future]), future)
    }

    func testEmptyQueryHasNoClosestSample() {
        XCTAssertNil(BodyWeightFetcher.closestSample(to: referenceDate, in: []))
    }
}

final class HistoryMutationPersistenceTests: XCTestCase {
    private struct SaveFailure: Error {}

    private func makeHistoryGraph(
        in context: NSManagedObjectContext
    ) throws -> (Workout, WorkoutExercise, WorkoutSet) {
        let workout = Workout.create(context: context)
        workout.title = "Original"
        workout.start = Date(timeIntervalSinceReferenceDate: 1_000)
        workout.end = Date(timeIntervalSinceReferenceDate: 2_000)
        workout.isCurrentWorkout = false
        let workoutExercise = WorkoutExercise.create(context: context)
        workout.addToWorkoutExercises(workoutExercise)
        let set = WorkoutSet.create(context: context)
        workoutExercise.addToWorkoutSets(set)
        set.isCompleted = true
        try context.save()
        return (workout, workoutExercise, set)
    }

    func testFailedMutationRollsBackOnlyItsChangesAndSkipsEffects() throws {
        let context = setUpInMemoryNSPersistentContainer().viewContext
        let (workout, workoutExercise, set) = try makeHistoryGraph(in: context)
        workout.comment = "Unrelated pending edit"
        var effectCount = 0

        XCTAssertThrowsError(try HistoryMutationPersistence.perform(
            context: context,
            save: { throw SaveFailure() },
            mutation: {
                set.isCompleted = false
                let inserted = WorkoutSet.create(context: context)
                workoutExercise.addToWorkoutSets(inserted)
            },
            onSuccess: { effectCount += 1 }
        ))

        XCTAssertTrue(set.isCompleted)
        XCTAssertEqual(workoutExercise.workoutSets?.count, 1)
        XCTAssertEqual(workout.comment, "Unrelated pending edit")
        XCTAssertTrue(context.hasChanges)
        XCTAssertEqual(effectCount, 0)
    }

    func testRetryPersistsMutationAndRunsEffectOnce() throws {
        let context = setUpInMemoryNSPersistentContainer().viewContext
        let (_, _, set) = try makeHistoryGraph(in: context)
        var effectCount = 0

        XCTAssertThrowsError(try HistoryMutationPersistence.perform(
            context: context,
            save: { throw SaveFailure() },
            mutation: { set.repetitionsValue = 8 },
            onSuccess: { effectCount += 1 }
        ))
        XCTAssertEqual(set.repetitionsValue, 0)

        try HistoryMutationPersistence.perform(
            context: context,
            mutation: { set.repetitionsValue = 8 },
            onSuccess: { effectCount += 1 }
        )

        XCTAssertEqual(set.repetitionsValue, 8)
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(effectCount, 1)
    }

    func testFailedDeletionRestoresObjectAndRelationship() throws {
        let context = setUpInMemoryNSPersistentContainer().viewContext
        let (_, workoutExercise, set) = try makeHistoryGraph(in: context)

        XCTAssertThrowsError(try HistoryMutationPersistence.perform(
            context: context,
            save: { throw SaveFailure() }
        ) {
            workoutExercise.removeFromWorkoutSets(set)
            context.delete(set)
        })

        XCTAssertFalse(set.isDeleted)
        XCTAssertEqual(workoutExercise.workoutSets?.count, 1)
        XCTAssertTrue(workoutExercise.workoutSets?.contains(set) == true)
    }

    func testTrackingCopyPreservesDurationAndDistanceTogether() {
        let context = setUpInMemoryNSPersistentContainer().viewContext
        let source = WorkoutSet.create(context: context)
        source.durationValue = 75
        source.distanceValue = 400
        source.weightValue = 20
        source.repetitionsValue = 6
        source.rpeValue = 8.5
        source.tagValue = .dropSet
        let destination = WorkoutSet.create(context: context)

        HistorySetTrackingValues.copy(from: source, to: destination)

        XCTAssertEqual(destination.durationValue, 75)
        XCTAssertEqual(destination.distanceValue, 400)
        XCTAssertEqual(destination.weightValue, 20)
        XCTAssertEqual(destination.repetitionsValue, 6)
        XCTAssertEqual(destination.rpeValue, 8.5)
        XCTAssertEqual(destination.tagValue, .dropSet)
    }
}

final class HealthSampleReconciliationTests: XCTestCase {
    private struct Sample: Equatable {
        let id: UUID
        let matches: Bool
    }

    private enum CleanupError: Error, Equatable {
        case failed
    }

    private let lowID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let middleID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let highID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    private func reconcile(_ samples: [Sample]) -> HealthManager.ExistingSampleReconciliation<Sample> {
        HealthManager.reconcileExistingSamples(
            samples,
            matches: { $0.matches },
            stableID: { $0.id }
        )
    }

    func testSingleMatchingSampleCompletesWithoutDeletingAnything() throws {
        let canonical = Sample(id: lowID, matches: true)
        let decision = reconcile([canonical])
        var deleteCalled = false
        var result: Result<Void, Error>?

        XCTAssertTrue(HealthManager.completeUsingReusableSample(
            decision,
            delete: { _, _ in deleteCalled = true },
            completion: { result = $0 }
        ))

        XCTAssertEqual(decision.reusable, canonical)
        XCTAssertTrue(decision.surplus.isEmpty)
        XCTAssertFalse(deleteCalled)
        try XCTUnwrap(result).get()
    }

    func testCanonicalMatchingSampleIsIndependentOfQueryOrder() {
        let low = Sample(id: lowID, matches: true)
        let middle = Sample(id: middleID, matches: false)
        let high = Sample(id: highID, matches: true)

        let forward = reconcile([high, middle, low])
        let reversed = reconcile([low, middle, high])

        XCTAssertEqual(forward.reusable, low)
        XCTAssertEqual(reversed.reusable, low)
        XCTAssertEqual(Set(forward.surplus.map(\.id)), Set([middleID, highID]))
        XCTAssertEqual(Set(reversed.surplus.map(\.id)), Set([middleID, highID]))
    }

    func testPartialCleanupRetryKeepsCanonicalAndOnlyReturnsRemainingSurplus() {
        let canonical = Sample(id: lowID, matches: true)
        let firstSurplus = Sample(id: middleID, matches: false)
        let remainingSurplus = Sample(id: highID, matches: false)
        let initial = reconcile([firstSurplus, canonical, remainingSurplus])

        XCTAssertEqual(initial.reusable, canonical)
        XCTAssertEqual(Set(initial.surplus.map(\.id)), Set([middleID, highID]))

        let retry = reconcile([remainingSurplus, canonical])
        XCTAssertEqual(retry.reusable, canonical)
        XCTAssertEqual(retry.surplus, [remainingSurplus])
    }

    func testEmptyAndNoMatchRequireReplacementWithoutInventingCleanup() {
        let empty = reconcile([])
        XCTAssertNil(empty.reusable)
        XCTAssertTrue(empty.surplus.isEmpty)

        let samples = [
            Sample(id: lowID, matches: false),
            Sample(id: middleID, matches: false)
        ]
        let noMatch = reconcile(samples)
        XCTAssertNil(noMatch.reusable)
        XCTAssertEqual(noMatch.surplus, samples)
    }

    func testCleanupFailureDeletesOnlySurplusAndCannotSave() {
        let canonical = Sample(id: lowID, matches: true)
        let surplus = Sample(id: middleID, matches: false)
        let decision = reconcile([surplus, canonical])
        var deleted: [Sample] = []
        var result: Result<Void, Error>?

        let handled = HealthManager.completeUsingReusableSample(
            decision,
            delete: { samples, completion in
                deleted = samples
                completion(.failure(CleanupError.failed))
            },
            completion: { result = $0 }
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(deleted, [surplus])
        XCTAssertFalse(deleted.contains(canonical))
        XCTAssertThrowsError(try result?.get()) { error in
            XCTAssertEqual(error as? CleanupError, .failed)
        }
    }

    func testNoMatchIsNotHandledAsCleanup() {
        let decision = reconcile([Sample(id: lowID, matches: false)])
        var deleted = false
        var completed = false

        let handled = HealthManager.completeUsingReusableSample(
            decision,
            delete: { _, _ in deleted = true },
            completion: { _ in completed = true }
        )

        XCTAssertFalse(handled)
        XCTAssertFalse(deleted)
        XCTAssertFalse(completed)
    }
}

final class TrainingHistorySnapshotTests: XCTestCase {
    func testSnapshotCountsCompletedSetsGroupsDaysAndDeduplicatesExerciseSessions() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 9))!
        let id = UUID()
        func session(_ start: Date, current: Bool = false) -> Workout {
            let workout = Workout.create(context: context)
            workout.start = start; workout.end = start.addingTimeInterval(3600)
            workout.isCurrentWorkout = current
            let exercises = (0..<2).map { _ -> WorkoutExercise in
                let exercise = WorkoutExercise.create(context: context)
                exercise.exerciseUuid = id
                // Finished history contains completed sets only. Keep the
                // unfinished rows in the active workout, as the save rules require.
                let sets = (0..<(current ? 2 : 1)).map { index -> WorkoutSet in
                    let set = WorkoutSet.create(context: context)
                    set.weightValue = 20; set.repetitionsValue = 5
                    set.isCompleted = index == 0
                    return set
                }
                exercise.workoutSets = NSOrderedSet(array: sets)
                return exercise
            }
            workout.workoutExercises = NSOrderedSet(array: exercises)
            return workout
        }
        let morning = session(date)
        let evening = session(date.addingTimeInterval(8 * 3600))
        let active = session(date, current: true)
        try context.save()
        let snapshot = TrainingHistorySnapshot.build(from: [morning, evening, active], calendar: calendar)
        XCTAssertEqual(snapshot.sessions.count, 2)
        XCTAssertEqual(snapshot.byDay[calendar.startOfDay(for: date)]?.count, 2)
        XCTAssertEqual(snapshot.sessions.reduce(0) { $0 + $1.setCount }, 4)
        XCTAssertEqual(snapshot.sessions.reduce(0) { $0 + $1.volume }, 400)
        XCTAssertEqual(snapshot.sessions.reduce(0) { $0 + $1.duration }, 7200)
        XCTAssertEqual(snapshot.exerciseTotals[id]?.sessions, 2)
        XCTAssertEqual(snapshot.exerciseTotals[id]?.sets, 4)
        XCTAssertFalse(context.hasChanges)
    }

    func testSnapshotExcludesAssistanceAndNonLiftingDimensions() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        let workout = Workout.create(context: context)
        workout.start = Date(timeIntervalSince1970: 1_000)
        workout.end = Date(timeIntervalSince1970: 2_000)
        let assistance = Exercise(uuid: UUID(), everkineticId: 10_000, title: "Assisted Pull-up",
            alias: [], description: nil, primaryMuscle: [], secondaryMuscle: [], equipment: ["machine"],
            steps: [], tips: [], references: [], pdfPaths: [])
        var exercises: [WorkoutExercise] = []
        for index in 0..<4 {
            let exercise = WorkoutExercise.create(context: context)
            exercise.exerciseUuid = index == 0 ? assistance.uuid : UUID()
            let set = WorkoutSet.create(context: context)
            set.isCompleted = true
            set.weightValue = 20
            set.repetitionsValue = 5
            if index == 2 { set.durationValue = 60 }
            if index == 3 { set.distanceValue = 100 }
            exercise.workoutSets = NSOrderedSet(array: [set])
            exercises.append(exercise)
        }
        workout.workoutExercises = NSOrderedSet(array: exercises)
        try context.save()
        let snapshot = TrainingHistorySnapshot.build(from: [workout], catalog: [assistance.uuid: assistance])
        XCTAssertEqual(snapshot.sessions.first?.setCount, 4)
        XCTAssertEqual(snapshot.sessions.first?.volume, 100)
        XCTAssertEqual(snapshot.sessions.first?.exercises.map(\.volume), [0, 100, 0, 0])
    }

    func testRepsAndDistanceRecordsCompareTheirOwnMeasurements() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        let repsID = UUID(), distanceID = UUID()
        var workouts: [Workout] = []
        var sets: [[WorkoutSet]] = []
        for (index, values) in [(10, 1_000.0), (12, 1_200.0), (11, 1_100.0)].enumerated() {
            let workout = Workout.create(context: context)
            workout.start = Date(timeIntervalSince1970: Double(index + 1) * 1_000)
            workout.end = workout.start!.addingTimeInterval(60)
            var entries: [WorkoutExercise] = []
            var sessionSets: [WorkoutSet] = []
            for id in [repsID, distanceID] {
                let exercise = WorkoutExercise.create(context: context)
                exercise.exerciseUuid = id
                let set = WorkoutSet.create(context: context)
                set.isCompleted = true
                if id == repsID { set.repetitionsValue = Int16(values.0) }
                else { set.distanceValue = values.1; set.durationValue = 300 }
                exercise.workoutSets = NSOrderedSet(array: [set])
                entries.append(exercise)
                sessionSets.append(set)
            }
            workout.workoutExercises = NSOrderedSet(array: entries)
            workouts.append(workout)
            sets.append(sessionSets)
        }
        try context.save()
        let snapshot = TrainingHistorySnapshot.build(from: Array(workouts.reversed()))
        XCTAssertEqual(snapshot.recordSetIDs, Set(sets[1].map(\.objectID)))
        XCTAssertEqual(snapshot.sessions.reduce(0) { $0 + $1.volume }, 0)
    }

    func testStreakAllowsCurrentRestWeekAndStopsAtFirstMissingPastWeek() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 9))!
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek)!
        let twoWeeks = calendar.date(byAdding: .weekOfYear, value: -2, to: thisWeek)!
        let fourWeeks = calendar.date(byAdding: .weekOfYear, value: -4, to: thisWeek)!
        var snapshot = TrainingHistorySnapshot()
        snapshot.trainedWeeks = [lastWeek, twoWeeks, fourWeeks]
        XCTAssertEqual(snapshot.streak(now: now, calendar: calendar), 2)
        snapshot.trainedWeeks.insert(thisWeek)
        XCTAssertEqual(snapshot.streak(now: now, calendar: calendar), 3)
    }
}

final class RestLengthRulerScaleTests: XCTestCase {
    private let scale = RestLengthRulerScale(range: 30...300, step: 15)

    func testPointerTracksContinuouslyWhileDurationSnaps() {
        let first = scale.duration(at: 114, width: 328)
        let second = scale.duration(at: 115, width: 328)
        XCTAssertGreaterThan(second, first)
        XCTAssertEqual(scale.snapped(first), scale.snapped(second))
        XCTAssertEqual(scale.position(for: first, width: 328), 114, accuracy: 0.001)
        XCTAssertEqual(scale.position(for: second, width: 328), 115, accuracy: 0.001)
    }

    func testScrubbingAndSnappingClampAtBothEnds() {
        XCTAssertEqual(scale.duration(at: -100, width: 328), 30)
        XCTAssertEqual(scale.duration(at: 600, width: 328), 300)
        XCTAssertEqual(scale.snapped(-10), 30)
        XCTAssertEqual(scale.snapped(500), 300)
        XCTAssertEqual(scale.snapped(97), 90)
        XCTAssertEqual(scale.snapped(98), 105)
    }

    func testGeometryRoundTripsAcrossWidths() {
        for width: CGFloat in [240, 328, 600] {
            for duration in stride(from: 30.0, through: 300.0, by: 1.0) {
                XCTAssertEqual(scale.duration(at: scale.position(for: duration, width: width), width: width), duration, accuracy: 0.001)
            }
        }
    }

    func testCustomRangeSnapsRelativeToItsLowerBound() {
        let custom = RestLengthRulerScale(range: 20...80, step: 15)
        XCTAssertEqual(custom.snapped(27), 20)
        XCTAssertEqual(custom.snapped(28), 35)
        XCTAssertEqual(custom.snapped(100), 80)
    }
}

final class HealthTestModeTests: XCTestCase {
    func testPreferenceDefaultsByBuildAndHonorsStoredChoice() throws {
        let suite = "IronHealthTestMode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = SettingsStore(userDefaults: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }
        #if DEBUG
        XCTAssertTrue(settings.healthTestMode)
        settings.healthTestMode = false
        XCTAssertFalse(defaults.healthTestMode)
        defaults.healthTestMode = true
        XCTAssertTrue(settings.healthTestMode)
        #else
        defaults.set(true, forKey: UserDefaults.SettingsKeys.healthTestMode.rawValue)
        XCTAssertFalse(settings.healthTestMode)
        #endif
    }

    func testLegacySnapshotDefaultsFalseAndTestMarkerSurvivesQueuedFinish() throws {
        var snapshot = WatchWorkoutSnapshot(workoutID: UUID())
        let legacyData = try XCTUnwrap(WatchWorkoutWire.encode(snapshot))
        let legacy = try XCTUnwrap(WatchWorkoutWire.decode(WatchWorkoutSnapshot.self, from: legacyData))
        XCTAssertFalse(legacy.isHealthTestWorkout)
        XCTAssertNil(legacy.healthTestWorkoutPaused)
        snapshot.healthTestMode = true
        snapshot.healthTestWorkoutPaused = true
        let event = WatchWorkoutEvent(workoutID: snapshot.workoutID, sequence: 1,
            kind: .workoutFinished, snapshot: snapshot)
        let persisted = WatchWorkoutPersistedState(snapshot: snapshot, outbox: [event])
        let data = try XCTUnwrap(WatchWorkoutWire.encode(persisted))
        let decoded = try XCTUnwrap(WatchWorkoutWire.decode(WatchWorkoutPersistedState.self, from: data))
        XCTAssertTrue(decoded.snapshot?.isHealthTestWorkout == true)
        XCTAssertTrue(decoded.outbox.first?.snapshot?.isHealthTestWorkout == true)
        XCTAssertEqual(decoded.snapshot?.healthTestWorkoutPaused, true)
        XCTAssertEqual(decoded.outbox.first?.snapshot?.healthTestWorkoutPaused, true)
    }

    #if DEBUG
    func testEnablingPreferencePublishesSynchronouslyBeforeItCanBeSwitchedOff() throws {
        let suite = "IronHealthTestNotification.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(userDefaults: defaults)
        var enabledNotifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: SettingsStore.healthTestModeEnabledNotification, object: nil, queue: nil
        ) { notification in
            guard (notification.object as? SettingsStore) === settings else { return }
            XCTAssertTrue(settings.healthTestMode)
            enabledNotifications += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        settings.healthTestMode = true
        settings.healthTestMode = false
        XCTAssertEqual(enabledNotifications, 1)
    }
    #endif
}

final class WatchWorkoutMetricsTests: XCTestCase {
    private let workoutID = UUID()
    private let now = Date(timeIntervalSince1970: 10_000)

    private func packet(date: Date? = nil, state: WatchWorkoutMetrics.SessionState = .running,
                        heartRate: Double? = 112, heartDate: Date? = nil,
                        energy: Double? = 84) -> WatchWorkoutMetrics {
        WatchWorkoutMetrics(workoutID: workoutID, date: date ?? now, state: state,
                            heartRate: heartRate, heartRateDate: heartDate ?? now,
                            activeEnergyKilocalories: energy)
    }

    func testWireRoundTripRetainsSubsecondOrderingAndUnits() throws {
        let value = packet(date: now.addingTimeInterval(0.125))
        let data = try XCTUnwrap(WatchWorkoutWire.encode(value))
        let decoded = try XCTUnwrap(WatchWorkoutWire.decode(WatchWorkoutMetrics.self, from: data))
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.currentHeartRate(at: now), 112)
        XCTAssertEqual(decoded.currentActiveEnergy(at: now), 84)
        XCTAssertLessThan(data.count, 512)
    }

    func testMissingAndInvalidReadingsAreNeverReplacedWithZero() {
        let missing = packet(heartRate: nil, energy: nil)
        XCTAssertNil(missing.currentHeartRate(at: now))
        XCTAssertNil(missing.currentActiveEnergy(at: now))
        for invalid in [-1.0, .nan, .infinity] {
            let value = packet(heartRate: invalid, energy: invalid)
            XCTAssertNil(value.currentHeartRate(at: now))
            XCTAssertNil(value.currentActiveEnergy(at: now))
        }
        XCTAssertNil(packet(heartRate: 0).currentHeartRate(at: now))
        XCTAssertEqual(packet(energy: 0).currentActiveEnergy(at: now), 0)
    }

    func testStaleSampleIsHiddenEvenWhenPacketIsFresh() {
        let value = packet(heartDate: now.addingTimeInterval(-31))
        XCTAssertNil(value.currentHeartRate(at: now))
        XCTAssertEqual(value.currentActiveEnergy(at: now), 84)
        XCTAssertNil(packet(heartDate: now.addingTimeInterval(6)).currentHeartRate(at: now))
    }

    func testLostConnectionExpiresBothReadings() {
        let value = packet()
        XCTAssertNotNil(value.currentHeartRate(at: now.addingTimeInterval(30)))
        XCTAssertNil(value.currentHeartRate(at: now.addingTimeInterval(31)))
        XCTAssertNil(value.currentActiveEnergy(at: now.addingTimeInterval(31)))
    }

    func testOnlyCurrentWorkoutAndNewerPacketsAreAccepted() {
        let first = packet()
        let newer = packet(date: now.addingTimeInterval(0.125))
        XCTAssertTrue(newer.accepts(after: first, for: workoutID, at: now))
        XCTAssertFalse(first.accepts(after: newer, for: workoutID, at: now))
        XCTAssertFalse(first.accepts(after: first, for: workoutID, at: now))
        XCTAssertFalse(first.accepts(after: nil, for: UUID(), at: now))
        XCTAssertFalse(packet(date: now.addingTimeInterval(-31)).accepts(after: nil, for: workoutID, at: now))
        XCTAssertFalse(packet(date: now.addingTimeInterval(6)).accepts(after: nil, for: workoutID, at: now))
    }

    func testPausedAndEndedSessionsNeverShowLiveHeartRate() {
        let paused = packet(state: .paused)
        XCTAssertNil(paused.currentHeartRate(at: now))
        XCTAssertEqual(paused.currentActiveEnergy(at: now), 84)
        let ended = packet(state: .ended)
        XCTAssertNil(ended.currentHeartRate(at: now))
        XCTAssertNil(ended.currentActiveEnergy(at: now))
    }

    func testDecodedNegativeReadingsCannotBypassValidation() throws {
        let source = #"{"workoutID":"WORKOUT","sentAt":10000,"state":"running","heartRate":-5,"heartRateDate":"1970-01-01T02:46:40Z","activeEnergyKilocalories":-20}"#
            .replacingOccurrences(of: "WORKOUT", with: workoutID.uuidString)
        let decoded = try XCTUnwrap(WatchWorkoutWire.decode(WatchWorkoutMetrics.self, from: Data(source.utf8)))
        XCTAssertNil(decoded.currentHeartRate(at: now))
        XCTAssertNil(decoded.currentActiveEnergy(at: now))
    }
}

final class WatchSupersetEditingTests: XCTestCase {
    private func exercise(order: Int, group: UUID?) -> WatchWorkoutExercise {
        WatchWorkoutExercise(order: order, name: "Exercise \(order)",
                             sets: [WatchWorkoutSet(order: 1)], supersetID: group)
    }

    func testEditingSupersetExcludesDeselectedPartner() throws {
        let group = UUID()
        var snapshot = WatchWorkoutSnapshot(workoutID: UUID(), exercises: (1...3).map {
            exercise(order: $0, group: group)
        })
        let ids = snapshot.exercises.map(\.id)
        WatchWorkoutEditing.replaceSuperset(exerciseIDs: [ids[0], ids[2]], anchorID: ids[0], in: &snapshot)
        let replacement = try XCTUnwrap(snapshot.exercises[0].supersetID)
        XCTAssertEqual(snapshot.exercises[2].supersetID, replacement)
        XCTAssertNil(snapshot.exercises[1].supersetID)
        XCTAssertEqual(snapshot.exercises.map(\.id), ids)
    }

    func testMovingPartnerKeepsUnselectedGroupMembersTogether() throws {
        let first = UUID(), second = UUID()
        var snapshot = WatchWorkoutSnapshot(workoutID: UUID(), exercises: (1...5).map {
            exercise(order: $0, group: $0 <= 2 ? first : second)
        })
        let ids = snapshot.exercises.map(\.id)
        let selectedSet = snapshot.exercises[2].sets[0].id
        snapshot.selectedSetID = selectedSet
        WatchWorkoutEditing.replaceSuperset(exerciseIDs: [ids[0], ids[2]], anchorID: ids[0], in: &snapshot)
        XCTAssertEqual(snapshot.exercises[0].supersetID, snapshot.exercises[2].supersetID)
        XCTAssertNotNil(snapshot.exercises[0].supersetID)
        XCTAssertNil(snapshot.exercises[1].supersetID)
        XCTAssertEqual(snapshot.exercises[3].supersetID, second)
        XCTAssertEqual(snapshot.exercises[4].supersetID, second)
        XCTAssertEqual(snapshot.selectedSetID, selectedSet)
    }

    func testRemovingGroupDoesNotAffectAnotherSuperset() {
        let first = UUID(), second = UUID()
        var snapshot = WatchWorkoutSnapshot(workoutID: UUID(), exercises: (1...4).map {
            exercise(order: $0, group: $0 <= 2 ? first : second)
        })
        WatchWorkoutEditing.replaceSuperset(exerciseIDs: [], anchorID: snapshot.exercises[0].id, in: &snapshot)
        XCTAssertNil(snapshot.exercises[0].supersetID)
        XCTAssertNil(snapshot.exercises[1].supersetID)
        XCTAssertEqual(snapshot.exercises[2].supersetID, second)
        XCTAssertEqual(snapshot.exercises[3].supersetID, second)
    }
}

final class WatchAutomaticSetScheduleTests: XCTestCase {
    private func exercise(_ order: Int, sets: Int, group: UUID? = nil) -> WatchWorkoutExercise {
        WatchWorkoutExercise(order: order, name: "Exercise \(order)",
            sets: (0..<sets).map { WatchWorkoutSet(order: $0 + 1, weight: 40, reps: 8) }, supersetID: group)
    }

    private func complete(_ id: UUID, in snapshot: inout WatchWorkoutSnapshot) {
        for exercise in snapshot.exercises.indices {
            guard let set = snapshot.exercises[exercise].sets.firstIndex(where: { $0.id == id }) else { continue }
            snapshot.exercises[exercise].sets[set].completed = true
            snapshot.selectedSetID = WatchWorkoutEditing.nextSet(in: snapshot, after: id)
            return
        }
        XCTFail("Scheduled set is missing")
    }

    func testAutomaticFlowAdvancesAcrossExerciseBoundariesAndFinishes() {
        let first = exercise(1, sets: 2), second = exercise(2, sets: 2)
        var snapshot = WatchWorkoutSnapshot(workoutID: UUID(), exercises: [first, second])
        let expected = first.sets.map(\.id) + second.sets.map(\.id)
        XCTAssertEqual(WatchWorkoutEditing.schedule(in: snapshot), expected)
        for (index, id) in expected.enumerated() {
            XCTAssertEqual(WatchWorkoutEditing.nextSet(in: snapshot), id)
            complete(id, in: &snapshot)
            let following = expected.dropFirst(index + 1).first
            XCTAssertEqual(snapshot.selectedSetID, following)
            XCTAssertEqual(WatchWorkoutEditing.nextSet(in: snapshot), following)
        }
        XCTAssertNil(WatchWorkoutEditing.nextSet(in: snapshot, after: expected.last))
        XCTAssertTrue(snapshot.exercises.flatMap(\.sets).allSatisfy(\.completed))
    }

    func testAutomaticFlowAlternatesUnequalSupersetRoundsAndSkipsEmptyMembers() {
        let group = UUID()
        let first = exercise(1, sets: 2, group: group)
        let empty = exercise(2, sets: 0, group: group)
        let second = exercise(3, sets: 3, group: group)
        let following = exercise(4, sets: 1)
        var snapshot = WatchWorkoutSnapshot(workoutID: UUID(), exercises: [first, empty, second, following])
        let expected = [first.sets[0].id, second.sets[0].id, first.sets[1].id,
                        second.sets[1].id, second.sets[2].id, following.sets[0].id]
        XCTAssertEqual(WatchWorkoutEditing.schedule(in: snapshot), expected)
        for id in expected {
            XCTAssertEqual(WatchWorkoutEditing.nextSet(in: snapshot), id)
            complete(id, in: &snapshot)
            XCTAssertEqual(snapshot.selectedSetID, WatchWorkoutEditing.nextSet(in: snapshot))
        }
        XCTAssertNil(snapshot.selectedSetID)
    }

    func testCompletedSupersetPartnersAreSkippedBeforeNextExercise() {
        let group = UUID()
        let first = exercise(1, sets: 2, group: group)
        let second = exercise(2, sets: 2, group: group)
        let following = exercise(3, sets: 1)
        var snapshot = WatchWorkoutSnapshot(workoutID: UUID(), exercises: [first, second, following])
        for id in second.sets.map(\.id) { complete(id, in: &snapshot) }
        XCTAssertEqual(WatchWorkoutEditing.nextSet(in: snapshot), first.sets[0].id)
        complete(first.sets[0].id, in: &snapshot)
        XCTAssertEqual(snapshot.selectedSetID, first.sets[1].id)
        complete(first.sets[1].id, in: &snapshot)
        XCTAssertEqual(snapshot.selectedSetID, following.sets[0].id)
    }

    func testUndoReturnsToUnfinishedScheduleAndEmptyWorkoutHasNoTarget() {
        let first = exercise(1, sets: 1), second = exercise(2, sets: 1)
        var snapshot = WatchWorkoutSnapshot(workoutID: UUID(), exercises: [first, second])
        complete(first.sets[0].id, in: &snapshot)
        complete(second.sets[0].id, in: &snapshot)
        XCTAssertNil(WatchWorkoutEditing.nextSet(in: snapshot))
        snapshot.exercises[0].sets[0].completed = false
        XCTAssertEqual(WatchWorkoutEditing.nextSet(in: snapshot, after: second.sets[0].id), first.sets[0].id)
        snapshot.exercises = [exercise(1, sets: 0)]
        XCTAssertEqual(WatchWorkoutEditing.schedule(in: snapshot), [])
        XCTAssertNil(WatchWorkoutEditing.nextSet(in: snapshot))
    }
}

final class SetTrackingTypeTests: XCTestCase {
    func testCatalogDefaultsCoverNonWeightExercisesWithoutTreatingEveryMachineAsCardio() {
        let cases: [(String, [String], SetTrackingType)] = [
            ("Stair Machine", ["Stepmill Machine"], .distanceDuration),
            ("Run", ["treadmill"], .distanceDuration),
            ("Ride", ["stationary-bike"], .distanceDuration),
            ("Row", ["rowing machine"], .distanceDuration),
            ("Ski Erg", [], .distanceDuration),
            ("Elliptical", [], .distanceDuration),
            ("Leg Raise", ["Parallel Bars"], .bodyweightReps),
            ("Push-up", ["body weight"], .bodyweightReps),
            ("Weighted Pull-up", ["bodyweight"], .weightedBodyweight),
            ("Assisted Pull-up", ["machine"], .assistedBodyweight),
            ("Plank", ["body weight"], .duration),
            ("Dead Hang", ["body weight"], .duration),
            ("Isometric Hold", [], .duration),
            ("Weighted Plank", ["body weight"], .weightDuration),
            ("Hanging Leg Raise", ["body weight"], .bodyweightReps),
            ("Seated Row", ["machine"], .weightReps),
            ("Bench Press", ["barbell"], .weightReps)
        ]
        for (name, equipment, expected) in cases {
            XCTAssertEqual(SetTrackingType.defaultType(name: name, equipment: equipment), expected, name)
        }
    }

    func testRecordedDimensionsDetermineLegacyTrackingType() {
        XCTAssertNil(SetTrackingType.infer(from: .init()))
        XCTAssertEqual(SetTrackingType.infer(from: .init(reps: 12)), .bodyweightReps)
        XCTAssertEqual(SetTrackingType.infer(from: .init(weight: 20, reps: 8)), .weightReps)
        XCTAssertEqual(SetTrackingType.infer(from: .init(duration: 60)), .duration)
        XCTAssertEqual(SetTrackingType.infer(from: .init(weight: 20, duration: 60)), .weightDuration)
        XCTAssertEqual(SetTrackingType.infer(from: .init(duration: 332, distance: 482.8032)), .distanceDuration)
        XCTAssertEqual(SetTrackingType.infer(from: .init(distance: 1_000)), .distanceDuration)
        XCTAssertEqual(SetTrackingType.infer(from: .init(weight: 40, distance: 20)), .weightDistance)
        XCTAssertNil(SetTrackingType.infer(from: .init(weight: .nan, duration: .infinity, distance: -1)))
    }

    func testCompatibleDefaultsRetainColumnsForUnenteredMeasurements() {
        XCTAssertEqual(SetTrackingType.resolved(.distanceDuration, from: .init(duration: 60)), .distanceDuration)
        XCTAssertEqual(SetTrackingType.resolved(.weightDuration, from: .init(duration: 60)), .weightDuration)
        XCTAssertEqual(SetTrackingType.resolved(.assistedBodyweight, from: .init(reps: 12)), .assistedBodyweight)
        XCTAssertEqual(SetTrackingType.resolved(.weightedBodyweight, from: .init(reps: 12)), .weightedBodyweight)
        XCTAssertEqual(SetTrackingType.resolved(.weightReps, from: .init(duration: 60)), .duration)
        XCTAssertEqual(SetTrackingType.resolved(.bodyweightReps, from: .init(weight: 20, reps: 12)), .weightedBodyweight)
    }

    func testVolumeCountsOnlyExternalLoadTimesReps() {
        for type in SetTrackingType.allCases {
            let expected: Double = type == .weightReps || type == .weightedBodyweight ? 200 : 0
            XCTAssertEqual(type.volume(weight: 20, reps: 10), expected, type.rawValue)
        }
        XCTAssertEqual(SetTrackingType.assistedBodyweight.volume(weight: 40, reps: 10), 0)
        XCTAssertEqual(SetTrackingType.weightReps.volume(weight: .infinity, reps: 10), 0)
        XCTAssertEqual(SetTrackingType.weightReps.volume(weight: 40, reps: -1), 0)
        XCTAssertEqual(SetTrackingType.weightReps.volume(weight: -40, reps: 10), 0)
    }

    func testColumnsAndSignedHeaders() {
        XCTAssertEqual(SetTrackingType.distanceDuration.columns, [.distance, .duration])
        XCTAssertEqual(SetTrackingType.bodyweightReps.columns, [.reps])
        XCTAssertEqual(SetTrackingType.weightedBodyweight.header(for: .weight, weightUnit: "lb", distanceUnit: "mi"), "+LB")
        XCTAssertEqual(SetTrackingType.assistedBodyweight.header(for: .weight, weightUnit: "kg", distanceUnit: "km"), "−KG")
        XCTAssertEqual(SetTrackingType.distanceDuration.unit(for: .distance, weightUnit: "kg", distanceUnit: "km"), "km")
    }

    func testDurationFormattingDoesNotIntroduceHoursOrLeadingMinuteZeros() {
        XCTAssertEqual(SetTrackingType.durationText(0), "0:00")
        XCTAssertEqual(SetTrackingType.durationText(60), "1:00")
        XCTAssertEqual(SetTrackingType.durationText(332), "5:32")
        XCTAssertEqual(SetTrackingType.durationText(3_661), "1:01:01")
        XCTAssertEqual(SetTrackingType.durationText(.nan), "0:00")
    }

    func testDistanceEditorsRoundTripMetersInBothUnitSystems() {
        for unit in WeightUnit.allCases {
            let display = WorkoutSet.distanceDisplayValue(482.8032, weightUnit: unit)
            XCTAssertEqual(WorkoutSet.distanceMeters(display, weightUnit: unit), 482.8032, accuracy: 0.000_001)
        }
        XCTAssertEqual(WorkoutSet.distanceDisplayValue(482.8032, weightUnit: .imperial), 0.3, accuracy: 0.000_001)
    }

    func testPreparingTypesPreservesCompanionMeasurementsAndClearsUnrelatedValues() {
        let container = setUpInMemoryNSPersistentContainer()
        let set = WorkoutSet.create(context: container.viewContext)
        set.weightValue = 20
        set.repetitionsValue = 8
        set.durationValue = 90
        set.distanceValue = 400
        set.prepare(for: .distanceDuration)
        XCTAssertEqual(set.durationValue, 90)
        XCTAssertEqual(set.distanceValue, 400)
        XCTAssertEqual(set.weightValue, 0)
        XCTAssertEqual(set.repetitionsValue, 0)
        set.weightValue = 25
        set.prepare(for: .weightDuration)
        XCTAssertEqual(set.weightValue, 25)
        XCTAssertEqual(set.durationValue, 90)
        XCTAssertNil(set.distanceValue)
        set.prepare(for: .bodyweightReps)
        XCTAssertNil(set.durationValue)
        XCTAssertEqual(set.weightValue, 0)
        XCTAssertEqual(set.repetitionsValue, 5)
    }

    func testModelAggregateExcludesTimedAndDistanceSetsEvenWithLegacyRepetitions() {
        let container = setUpInMemoryNSPersistentContainer()
        let exercise = WorkoutExercise.create(context: container.viewContext)
        for index in 0..<3 {
            let set = WorkoutSet.create(context: container.viewContext)
            set.workoutExercise = exercise
            set.isCompleted = true
            set.weightValue = 20
            set.repetitionsValue = 10
            if index == 1 { set.durationValue = 60 }
            if index == 2 { set.distanceValue = 20 }
        }
        XCTAssertEqual(exercise.totalCompletedWeight, 200)
        XCTAssertEqual(exercise.trackedCompletedVolume, 200)
    }

    func testPreferencePayloadMergesNewerValuesWithoutErasingUnrelatedExercises() throws {
        let suite = "SetTrackingTypeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let exerciseID = UUID()
        let otherID = UUID()
        let setID = UUID()
        SetTrackingPreferences.setOverride(.distanceDuration, for: exerciseID, defaults: defaults)
        SetTrackingPreferences.setRoutineDistance(482.8032, for: setID, defaults: defaults)
        let local = SetTrackingPreferences.load(defaults: defaults)
        XCTAssertEqual(SetTrackingPreferences.override(for: exerciseID, defaults: defaults), .distanceDuration)
        XCTAssertEqual(SetTrackingPreferences.routineDistance(for: setID, defaults: defaults), 482.8032)
        let decoded = try XCTUnwrap(SetTrackingPreferences(payload: local.dictionaryRepresentation))
        XCTAssertEqual(decoded, local)
        var remote = SetTrackingPreferences()
        remote.overrides[exerciseID.uuidString] = .init(type: .duration, updatedAt: 0)
        remote.overrides[otherID.uuidString] = .init(type: .bodyweightReps, updatedAt: 1)
        let merged = local.merging(remote)
        XCTAssertEqual(merged.overrides[exerciseID.uuidString]?.type, .distanceDuration)
        XCTAssertEqual(merged.overrides[otherID.uuidString]?.type, .bodyweightReps)
        XCTAssertEqual(merged, remote.merging(local))
        XCTAssertEqual(merged.merging(merged), merged)
        SetTrackingPreferences.setRoutineDistance(nil, for: setID, defaults: defaults)
        XCTAssertNil(SetTrackingPreferences.routineDistance(for: setID, defaults: defaults))
    }

    func testSavedWorkoutPreferenceDraftWritesOnlyOnCommit() throws {
        let suite = "RoutineTrackingDraftTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let exerciseID = UUID()
        let setID = UUID()
        do {
            let cancelled = RoutineSetTrackingDraft(defaults: defaults)
            cancelled.setOverride(.distanceDuration, for: exerciseID)
            cancelled.setDistance(1_000, for: setID)
            XCTAssertEqual(cancelled.override(for: exerciseID), .distanceDuration)
            XCTAssertEqual(cancelled.distance(for: setID), 1_000)
            XCTAssertTrue(SetTrackingPreferences.load(defaults: defaults).isEmpty)
        }
        XCTAssertTrue(SetTrackingPreferences.load(defaults: defaults).isEmpty)
        let saved = RoutineSetTrackingDraft(defaults: defaults)
        saved.setOverride(.weightDistance, for: exerciseID)
        saved.setDistance(20, for: setID)
        saved.commit()
        XCTAssertEqual(SetTrackingPreferences.override(for: exerciseID, defaults: defaults), .weightDistance)
        XCTAssertEqual(SetTrackingPreferences.routineDistance(for: setID, defaults: defaults), 20)
        XCTAssertTrue(saved.changes.isEmpty)
    }

    func testTrackingTypeOnWatchExerciseIsOptionalForOlderSnapshots() throws {
        let original = WatchWorkoutExercise(order: 1, name: "Run", sets: [], trackingType: SetTrackingType.distanceDuration.rawValue)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(WatchWorkoutExercise.self, from: data), original)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "trackingType")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertNil(try JSONDecoder().decode(WatchWorkoutExercise.self, from: legacyData).trackingType)
    }
}

final class TrackingTemplateConversionTests: XCTestCase {
    func testFreshWatchWorkoutPreservesTrackingAndDistanceWithNewIdentities() {
        let set = WatchWorkoutSet(order: 1, duration: 300, distance: 1_000)
        let exercise = WatchWorkoutExercise(order: 1, name: "Run", sets: [set],
            exerciseUuid: UUID(), trackingType: SetTrackingType.distanceDuration.rawValue)
        let result = WatchWorkoutEditing.newWorkout(exercises: [exercise], title: "Run", unit: .kilogram)
        XCTAssertNotEqual(result.exercises.first?.id, exercise.id)
        XCTAssertNotEqual(result.exercises.first?.sets.first?.id, set.id)
        XCTAssertEqual(result.exercises.first?.trackingType, exercise.trackingType)
        XCTAssertEqual(result.exercises.first?.sets.first?.distance, 1_000)
        XCTAssertEqual(result.exercises.first?.sets.first?.duration, 300)
    }
}

final class ExerciseNotesTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "ExerciseNotesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testNotesUseInjectedStorageAndKeepDeletionTombstones() throws {
        let defaults = try makeDefaults()
        let otherDefaults = try makeDefaults()
        let exerciseID = UUID()
        XCTAssertNil(ExerciseNotes.note(for: nil, defaults: defaults))
        XCTAssertTrue(ExerciseNotes.load(defaults: defaults).isEmpty)

        ExerciseNotes.setNote("  Brace before each rep.\nKeep the full foot planted.  ", for: exerciseID,
            updatedAt: Date(timeIntervalSince1970: 100), defaults: defaults)
        XCTAssertEqual(ExerciseNotes.note(for: exerciseID, defaults: defaults),
            "Brace before each rep.\nKeep the full foot planted.")
        XCTAssertNil(ExerciseNotes.note(for: exerciseID, defaults: otherDefaults))

        ExerciseNotes.setNote(" \n ", for: exerciseID,
            updatedAt: Date(timeIntervalSince1970: 200), defaults: defaults)
        XCTAssertNil(ExerciseNotes.note(for: exerciseID, defaults: defaults))
        let tombstone = try XCTUnwrap(ExerciseNotes.load(defaults: defaults).entries[exerciseID.uuidString])
        XCTAssertNil(tombstone.text)
        XCTAssertEqual(tombstone.updatedAt, 200)
    }

    func testPayloadRoundTripAndMergeNeverReviveAnOlderDeletedNote() throws {
        let exerciseID = UUID(), otherID = UUID()
        var older = ExerciseNotes()
        older.entries[exerciseID.uuidString] = .init(text: "Old cue", updatedAt: 100)
        var newer = ExerciseNotes()
        newer.entries[exerciseID.uuidString] = .init(text: nil, updatedAt: 200)
        newer.entries[otherID.uuidString] = .init(text: "Other cue", updatedAt: 150)
        let merged = older.merging(newer)
        XCTAssertEqual(merged, newer.merging(older))
        XCTAssertEqual(merged.merging(older), merged)
        XCTAssertEqual(merged.merging(merged), merged)
        XCTAssertNil(merged.entries[exerciseID.uuidString]?.text)
        XCTAssertEqual(merged.entries[otherID.uuidString]?.text, "Other cue")
        XCTAssertEqual(try XCTUnwrap(ExerciseNotes(payload: merged.dictionaryRepresentation)), merged)
        XCTAssertNoThrow(try PropertyListSerialization.data(
            fromPropertyList: merged.dictionaryRepresentation, format: .binary, options: 0))
    }

    func testSimultaneousEditsConvergeAndDeletionWinsTheTie() {
        let exerciseID = UUID()
        var first = ExerciseNotes(), second = ExerciseNotes(), deleted = ExerciseNotes()
        first.entries[exerciseID.uuidString] = .init(text: "A cue", updatedAt: 100)
        second.entries[exerciseID.uuidString] = .init(text: "Z cue", updatedAt: 100)
        deleted.entries[exerciseID.uuidString] = .init(text: nil, updatedAt: 100)
        XCTAssertEqual(first.merging(second), second.merging(first))
        XCTAssertEqual(first.merging(second).entries[exerciseID.uuidString]?.text, "Z cue")
        XCTAssertEqual(first.merging(deleted), deleted.merging(first))
        XCTAssertNil(first.merging(deleted).entries[exerciseID.uuidString]?.text)
    }

    func testNotificationsExcludeNoOpsStaleUpdatesAndPeerSaves() throws {
        let defaults = try makeDefaults()
        let exerciseID = UUID()
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: ExerciseNotes.didChangeNotification, object: nil, queue: nil
        ) { notification in
            guard (notification.object as? UserDefaults) === defaults else { return }
            notifications += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        ExerciseNotes.setNote("Local", for: exerciseID,
            updatedAt: Date(timeIntervalSince1970: 100), defaults: defaults)
        ExerciseNotes.setNote("Local", for: exerciseID,
            updatedAt: Date(timeIntervalSince1970: 200), defaults: defaults)
        ExerciseNotes.setNote("Stale", for: exerciseID,
            updatedAt: Date(timeIntervalSince1970: 50), defaults: defaults)
        ExerciseNotes.setNote("Peer", for: exerciseID,
            updatedAt: Date(timeIntervalSince1970: 200), defaults: defaults, notify: false)
        var peer = ExerciseNotes()
        peer.entries[exerciseID.uuidString] = .init(text: "Merged peer", updatedAt: 300)
        ExerciseNotes.load(defaults: defaults).merging(peer).save(defaults: defaults)

        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(ExerciseNotes.note(for: exerciseID, defaults: defaults), "Merged peer")
    }

    func testMalformedPayloadAndStoredDataAreRejected() throws {
        let defaults = try makeDefaults()
        let invalidPayloads: [[String: Any]] = [
            [ExerciseNotes.payloadKey: ["entries": ["not-a-uuid": ["text": "Cue", "updatedAt": 100]]]],
            [ExerciseNotes.payloadKey: ["entries": [UUID().uuidString: ["text": "Cue", "updatedAt": -1]]]],
            [ExerciseNotes.payloadKey: ["entries": [UUID().uuidString: ["text": " \n ", "updatedAt": 100]]]]
        ]
        for payload in invalidPayloads {
            XCTAssertNil(ExerciseNotes(payload: payload))
            let data = try JSONSerialization.data(withJSONObject: payload[ExerciseNotes.payloadKey]!)
            defaults.set(data, forKey: ExerciseNotes.storageKey)
            XCTAssertTrue(ExerciseNotes.load(defaults: defaults).isEmpty)
        }
    }

    func testRoutineLinksDistinguishRepeatedPlanRowsAndCanBeCleared() throws {
        let defaults = try makeDefaults()
        let loggedFirst = UUID(), loggedSecond = UUID(), routineFirst = UUID(), routineSecond = UUID()
        WorkoutRoutineNoteLinks.setRoutineExerciseID(routineFirst, for: loggedFirst, defaults: defaults)
        WorkoutRoutineNoteLinks.setRoutineExerciseID(routineSecond, for: loggedSecond, defaults: defaults)
        XCTAssertEqual(WorkoutRoutineNoteLinks.routineExerciseID(for: loggedFirst, defaults: defaults), routineFirst)
        XCTAssertEqual(WorkoutRoutineNoteLinks.routineExerciseID(for: loggedSecond, defaults: defaults), routineSecond)
        XCTAssertNil(WorkoutRoutineNoteLinks.routineExerciseID(for: nil, defaults: defaults))
        WorkoutRoutineNoteLinks.setRoutineExerciseID(nil, for: loggedFirst, defaults: defaults)
        XCTAssertNil(WorkoutRoutineNoteLinks.routineExerciseID(for: loggedFirst, defaults: defaults))
        XCTAssertEqual(WorkoutRoutineNoteLinks.routineExerciseID(for: loggedSecond, defaults: defaults), routineSecond)
    }
}

final class PreferenceCacheRegressionTests: XCTestCase {
    private struct Value: Codable, Equatable { var number: Int }

    private final class CountingDefaults: UserDefaults {
        var dataReads: [String: Int] = [:]
        var hiddenListReads = 0
        var writtenKeys: [String] = []
        var usesExternalHiddenList = false
        var externalHiddenList: [String]?

        override func set(_ value: Any?, forKey defaultName: String) {
            writtenKeys.append(defaultName)
            super.set(value, forKey: defaultName)
        }

        override func data(forKey defaultName: String) -> Data? {
            dataReads[defaultName, default: 0] += 1
            return super.data(forKey: defaultName)
        }

        override func array(forKey defaultName: String) -> [Any]? {
            if defaultName == "hiddenExerciseUuids" {
                hiddenListReads += 1
                if usesExternalHiddenList { return externalHiddenList }
            }
            return super.array(forKey: defaultName)
        }
    }

    private var suites: [String] = []

    private func defaults() throws -> CountingDefaults {
        let suite = "PreferenceCacheRegressionTests." + UUID().uuidString
        suites.append(suite)
        return try XCTUnwrap(CountingDefaults(suiteName: suite))
    }

    override func tearDown() {
        suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        suites.removeAll()
        super.tearDown()
    }

    func testRepeatedReadsDecodeOnceAndUnrelatedChangesDoNotDecode() throws {
        let storage = try defaults()
        let center = NotificationCenter()
        let key = "cache.test.v1"
        storage.set(try JSONEncoder().encode(Value(number: 1)), forKey: key)
        var decodes = 0
        let cache = Iron.DefaultsValueCache<Value>(key: key, notificationCenter: center) { data in
            decodes += 1
            return data.flatMap { try? JSONDecoder().decode(Value.self, from: $0) } ?? Value(number: 0)
        }
        for _ in 0..<1_000 { XCTAssertEqual(cache.load(defaults: storage).number, 1) }
        XCTAssertEqual(decodes, 1)
        XCTAssertEqual(storage.dataReads[key], 1)

        storage.set(true, forKey: "unrelated")
        center.post(name: UserDefaults.didChangeNotification, object: storage)
        XCTAssertEqual(cache.load(defaults: storage).number, 1)
        XCTAssertEqual(decodes, 1, "Defaults changes for other keys must keep the decoded value")

        storage.set(try JSONEncoder().encode(Value(number: 2)), forKey: key)
        center.post(name: UserDefaults.didChangeNotification, object: storage)
        for _ in 0..<100 { XCTAssertEqual(cache.load(defaults: storage).number, 2) }
        XCTAssertEqual(decodes, 2)
    }

    func testWriteThroughAvoidsDecodeAndCachesStayIsolatedByDefaults() throws {
        let first = try defaults(), second = try defaults()
        let center = NotificationCenter()
        let key = "cache.test.v1"
        var decodes = 0
        let cache = Iron.DefaultsValueCache<Value>(key: key, notificationCenter: center) { data in
            decodes += 1
            return data.flatMap { try? JSONDecoder().decode(Value.self, from: $0) } ?? Value(number: 0)
        }
        XCTAssertEqual(cache.load(defaults: first).number, 0)
        XCTAssertEqual(cache.load(defaults: second).number, 0)
        let value = Value(number: 8)
        cache.store(value, data: try JSONEncoder().encode(value), defaults: first)
        XCTAssertEqual(cache.load(defaults: first), value)
        XCTAssertEqual(cache.load(defaults: second).number, 0)
        XCTAssertEqual(decodes, 2, "A local write uses the already decoded value")

        first.removeObject(forKey: key)
        center.post(name: UserDefaults.didChangeNotification, object: first)
        XCTAssertEqual(cache.load(defaults: first).number, 0)
        XCTAssertEqual(decodes, 3, "Removing the watched key invalidates it once")
    }

    func testMalformedValueIsCachedAndOwnChangeNotificationRefreshesIt() throws {
        let storage = try defaults()
        let center = NotificationCenter()
        let key = "cache.test.v1"
        let localEdit = Notification.Name("cacheLocalEdit")
        storage.set(Data([0xFF]), forKey: key)
        var decodes = 0
        let cache = Iron.DefaultsValueCache<Value>(key: key, notification: localEdit, notificationCenter: center) { data in
            decodes += 1
            return data.flatMap { try? JSONDecoder().decode(Value.self, from: $0) } ?? Value(number: 0)
        }
        for _ in 0..<100 { XCTAssertEqual(cache.load(defaults: storage).number, 0) }
        XCTAssertEqual(decodes, 1)
        storage.set(try JSONEncoder().encode(Value(number: 7)), forKey: key)
        center.post(name: localEdit, object: storage)
        XCTAssertEqual(cache.load(defaults: storage).number, 7)
        XCTAssertEqual(decodes, 2)
    }

    func testSilentPeerSavesUpdateEveryPreferenceCacheImmediately() throws {
        let storage = try defaults()
        let exerciseID = UUID(), setID = UUID(), loggedID = UUID(), routineID = UUID()
        XCTAssertTrue(Iron.SetTrackingPreferences.load(defaults: storage).isEmpty)
        XCTAssertTrue(Iron.ExerciseNotes.load(defaults: storage).isEmpty)
        XCTAssertTrue(Iron.PlateCalculatorPreferences.load(defaults: storage).isEmpty)
        var tracking = Iron.SetTrackingPreferences()
        tracking.overrides[exerciseID.uuidString] = .init(type: .distanceDuration, updatedAt: 10)
        tracking.routineDistances[setID.uuidString] = .init(meters: 400, updatedAt: 10)
        tracking.save(defaults: storage)
        var notes = Iron.ExerciseNotes()
        notes.entries[exerciseID.uuidString] = .init(text: "Brace", updatedAt: 10)
        notes.save(defaults: storage)
        let loadout = Iron.PlateLoadout(mode: .machine(25), unit: .kilogram)
        Iron.PlateLoadout.saveAll([exerciseID.uuidString: loadout], defaults: storage)
        Iron.PlateInventory().save(defaults: storage)
        Iron.WorkoutRoutineNoteLinks.setRoutineExerciseID(routineID, for: loggedID, defaults: storage)

        XCTAssertEqual(Iron.SetTrackingPreferences.override(for: exerciseID, defaults: storage), .distanceDuration)
        XCTAssertEqual(Iron.SetTrackingPreferences.routineDistance(for: setID, defaults: storage), 400)
        XCTAssertEqual(Iron.ExerciseNotes.note(for: exerciseID, defaults: storage), "Brace")
        XCTAssertEqual(Iron.PlateLoadout.loadAll(defaults: storage)[exerciseID.uuidString], loadout)
        XCTAssertNotNil(Iron.PlateCalculatorPreferences.load(defaults: storage).inventory)
        XCTAssertEqual(Iron.WorkoutRoutineNoteLinks.routineExerciseID(for: loggedID, defaults: storage), routineID)
    }

    func testWriteThroughRefreshesAnotherCacheInstanceWithoutLocalEditNotification() throws {
        let storage = try defaults()
        let center = NotificationCenter()
        let key = "cache.test.v1"
        let localEdit = Notification.Name("cacheLocalEdit")
        func cache() -> Iron.DefaultsValueCache<Value> {
            Iron.DefaultsValueCache<Value>(key: key, notification: localEdit, notificationCenter: center) { data in
                data.flatMap { try? JSONDecoder().decode(Value.self, from: $0) } ?? Value(number: 0)
            }
        }
        let first = cache(), second = cache()
        XCTAssertEqual(first.load(defaults: storage).number, 0)
        XCTAssertEqual(second.load(defaults: storage).number, 0)
        var localEdits = 0
        let observer = center.addObserver(forName: localEdit, object: nil, queue: nil) { _ in localEdits += 1 }
        defer { center.removeObserver(observer) }
        let value = Value(number: 9)
        first.store(value, data: try JSONEncoder().encode(value), defaults: storage)
        XCTAssertEqual(second.load(defaults: storage), value)
        XCTAssertEqual(localEdits, 0, "Cache invalidation must not schedule a peer echo")
    }

    func testHiddenExerciseChecksCacheMissingValuesAndFollowExternalEdits() throws {
        let storage = try defaults()
        let store = ExerciseStore(customExercisesURL: nil, userDefaults: storage)
        let exercise = try XCTUnwrap(store.builtInExercises.first)
        XCTAssertFalse(store.isHidden(exercise: exercise))
        let reads = storage.hiddenListReads
        for _ in 0..<1_000 { XCTAssertFalse(store.isHidden(exercise: exercise)) }
        XCTAssertEqual(storage.hiddenListReads, reads)
        store.hide(exercise: exercise)
        XCTAssertTrue(store.isHidden(exercise: exercise))
        store.show(exercise: exercise)
        XCTAssertFalse(store.isHidden(exercise: exercise))

        storage.set([exercise.uuid.uuidString], forKey: "hiddenExerciseUuids")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: storage)
        XCTAssertTrue(store.isHidden(exercise: exercise))
        storage.removeObject(forKey: "hiddenExerciseUuids")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: storage)
        XCTAssertFalse(store.isHidden(exercise: exercise))
    }

    func testCatalogRequestsRefreshCrossProcessHiddenChangesWithoutPerRowReads() throws {
        let storage = try defaults()
        storage.usesExternalHiddenList = true
        let store = ExerciseStore(customExercisesURL: nil, userDefaults: storage)
        let exercise = try XCTUnwrap(store.builtInExercises.first)
        XCTAssertTrue(store.shownExercises.contains { $0.uuid == exercise.uuid })
        let initialReads = storage.hiddenListReads

        // Model an app-group change visible to reads in a surviving extension,
        // without didChangeNotification (which is only posted in the writer).
        storage.externalHiddenList = [exercise.uuid.uuidString]
        XCTAssertFalse(store.shownExercises.contains { $0.uuid == exercise.uuid })
        XCTAssertEqual(storage.hiddenListReads, initialReads + 1)
        for _ in 0..<1_000 { XCTAssertTrue(store.isHidden(exercise: exercise)) }
        XCTAssertEqual(storage.hiddenListReads, initialReads + 1)

        storage.externalHiddenList = nil
        XCTAssertFalse(store.hiddenExercises.contains { $0.uuid == exercise.uuid })
        XCTAssertEqual(storage.hiddenListReads, initialReads + 2)
        for _ in 0..<1_000 { XCTAssertFalse(store.isHidden(exercise: exercise)) }
        XCTAssertEqual(storage.hiddenListReads, initialReads + 2)
    }

    func testReceiptCacheSharesWritesWithoutPublishingViewChanges() throws {
        let storage = try defaults()
        let center = NotificationCenter()
        func cache() -> Iron.DefaultsValueCache<Value> {
            Iron.DefaultsValueCache<Value>(key: "receipt.test", notificationCenter: center,
                                          publishesChanges: false) { data in
                data.flatMap { try? JSONDecoder().decode(Value.self, from: $0) } ?? Value(number: 0)
            }
        }
        let first = cache(), second = cache()
        XCTAssertEqual(second.load(defaults: storage).number, 0)
        var publications = 0
        let firstObserver = first.objectWillChange.sink { publications += 1 }
        let secondObserver = second.objectWillChange.sink { publications += 1 }
        defer { firstObserver.cancel(); secondObserver.cancel() }
        let value = Value(number: 30)
        first.store(value, data: try JSONEncoder().encode(value), defaults: storage)
        XCTAssertEqual(second.load(defaults: storage), value)
        let drained = expectation(description: "Queued cache publications drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertEqual(publications, 0)
    }

    func testEqualContentSilentNoteSetterRetainsItsReceiptClock() throws {
        let storage = try defaults()
        let exerciseID = UUID()
        for timestamp in [10.0, 30.0] {
            Iron.ExerciseNotes.setNote("Brace", for: exerciseID, updatedAt: Date(timeIntervalSince1970: timestamp),
                                       defaults: storage, notify: false)
        }
        let fresh = try XCTUnwrap(UserDefaults(suiteName: try XCTUnwrap(suites.last)))
        Iron.ExerciseNotes.setNote("Stale", for: exerciseID, updatedAt: Date(timeIntervalSince1970: 20),
                                   defaults: fresh, notify: false)
        XCTAssertEqual(Iron.ExerciseNotes.load(defaults: fresh).entries[exerciseID.uuidString]?.updatedAt, 30)
        XCTAssertEqual(Iron.ExerciseNotes.note(for: exerciseID, defaults: fresh), "Brace")
    }

    func testSilentReceiptWatermarksSurviveFreshManagerAndRejectDelayedConflicts() throws {
        let storage = try defaults()
        let suite = try XCTUnwrap(suites.last)
        let exerciseID = UUID(), deletedID = UUID(), setID = UUID(), clearedSetID = UUID()
        let queue = DispatchQueue(label: "PreferenceCacheRegressionTests.watermarks")
        func payload(at timestamp: TimeInterval, conflicting: Bool = false) -> [String: Any] {
            var inventory = Iron.PlateInventory().dictionaryRepresentation
            inventory["updatedAt"] = timestamp
            if conflicting { inventory["kilogramPlates"] = [20.0] }
            let loadout = Iron.PlateLoadout(mode: .barbell(conflicting ? 45 : 20),
                                           unit: .kilogram, updatedAt: timestamp)
            var tracking = Iron.SetTrackingPreferences()
            tracking.overrides[exerciseID.uuidString] = .init(type: conflicting ? .weightReps : .duration,
                                                            updatedAt: timestamp)
            tracking.routineDistances[setID.uuidString] = .init(meters: conflicting ? 200 : 400, updatedAt: timestamp)
            tracking.routineDistances[clearedSetID.uuidString] = .init(meters: conflicting ? 500 : 0, updatedAt: timestamp)
            var notes = Iron.ExerciseNotes()
            notes.entries[exerciseID.uuidString] = .init(text: conflicting ? "Stale" : "Brace", updatedAt: timestamp)
            notes.entries[deletedID.uuidString] = .init(text: conflicting ? "Revived" : nil, updatedAt: timestamp)
            var result: [String: Any] = [
                Iron.PayloadKey.plateInventory: inventory,
                Iron.PayloadKey.plateLoadouts: [exerciseID.uuidString: loadout.dictionaryRepresentation]
            ]
            result.merge(tracking.dictionaryRepresentation) { _, new in new }
            result.merge(notes.dictionaryRepresentation) { _, new in new }
            return result
        }

        var sends = 0, localEdits = 0
        let names = [Iron.PlateCalculatorStorageKeys.didChangeNotification,
                     Iron.SetTrackingPreferences.didChangeNotification, Iron.ExerciseNotes.didChangeNotification]
        let observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in localEdits += 1 }
        }
        defer { observers.forEach { NotificationCenter.default.removeObserver($0) } }
        let manager = Iron.WatchPreferenceSyncManager(defaults: storage, queue: queue,
            transmit: { _ in sends += 1; return true })
        queue.sync { manager.applyReceived(payload(at: 10)) }
        let contentKeys = [Iron.PlateCalculatorStorageKeys.inventory, Iron.PlateCalculatorStorageKeys.loadouts,
                           Iron.SetTrackingPreferences.storageKey, Iron.ExerciseNotes.storageKey]
        let originalContent = contentKeys.map { storage.data(forKey: $0) }
        storage.writtenKeys.removeAll()
        queue.sync { manager.applyReceived(payload(at: 30)) }
        XCTAssertEqual(Set(storage.writtenKeys), Set([
            "plateCalculator.mergeWatermarks.v1",
            Iron.SetTrackingPreferences.storageKey + ".mergeWatermarks.v1",
            Iron.ExerciseNotes.storageKey + ".mergeWatermarks.v1"
        ]))
        XCTAssertEqual(contentKeys.map { storage.data(forKey: $0) }, originalContent)
        storage.writtenKeys.removeAll()
        queue.sync {
            manager.applyReceived(payload(at: 30))
            manager.flush()
        }
        XCTAssertTrue(storage.writtenKeys.isEmpty, "Duplicate message/context delivery must never rewrite a receipt")

        // A new defaults instance forces fresh decoding; a new manager has no
        // observed* snapshots. Only the durable receipt can reject timestamp 20.
        let restartedStorage = try XCTUnwrap(CountingDefaults(suiteName: suite))
        let restarted = Iron.WatchPreferenceSyncManager(defaults: restartedStorage, queue: queue,
            transmit: { _ in sends += 1; return true })
        queue.sync {
            restarted.applyReceived(payload(at: 20, conflicting: true))
            restarted.flush()
        }
        let plates = Iron.PlateCalculatorPreferences.load(defaults: restartedStorage)
        let tracking = Iron.SetTrackingPreferences.load(defaults: restartedStorage)
        let notes = Iron.ExerciseNotes.load(defaults: restartedStorage)
        XCTAssertEqual(plates.inventory?.updatedAt, 30)
        XCTAssertEqual(plates.inventory?.enabledPlates(for: .kilogram), Iron.PlateInventory().enabledPlates(for: .kilogram))
        XCTAssertEqual(plates.loadouts[exerciseID.uuidString]?.baseWeight, 20)
        XCTAssertEqual(plates.loadouts[exerciseID.uuidString]?.updatedAt, 30)
        XCTAssertEqual(tracking.overrides[exerciseID.uuidString]?.type, .duration)
        XCTAssertEqual(tracking.overrides[exerciseID.uuidString]?.updatedAt, 30)
        XCTAssertEqual(tracking.routineDistances[setID.uuidString]?.meters, 400)
        XCTAssertEqual(tracking.routineDistances[setID.uuidString]?.updatedAt, 30)
        XCTAssertEqual(tracking.routineDistances[clearedSetID.uuidString]?.meters, 0)
        XCTAssertEqual(tracking.routineDistances[clearedSetID.uuidString]?.updatedAt, 30)
        XCTAssertEqual(notes.entries[exerciseID.uuidString]?.text, "Brace")
        XCTAssertEqual(notes.entries[exerciseID.uuidString]?.updatedAt, 30)
        XCTAssertNil(notes.entries[deletedID.uuidString]?.text)
        XCTAssertEqual(notes.entries[deletedID.uuidString]?.updatedAt, 30)
        XCTAssertTrue(restartedStorage.writtenKeys.isEmpty)
        XCTAssertEqual(localEdits, 0)
        XCTAssertEqual(sends, 0)
    }
}
