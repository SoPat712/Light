import XCTest
import CoreData
import WorkoutDataKit
@testable import Iron

final class ThisWeekWidgetDataTests: XCTestCase {
    private func calendar(firstWeekday: Int = 2, zone: String = "America/New_York") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = firstWeekday
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    func testSummaryUsesHomesCompletedHistoryIncludingImports() throws {
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        let calendar = calendar()
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 12))!
        func workout(current: Bool = false, imported: Bool = false, completed: Bool = true) -> Workout {
            let workout = Workout.create(context: context)
            workout.start = now
            workout.end = now.addingTimeInterval(3600)
            workout.isCurrentWorkout = current
            workout.importSource = imported ? "hevy" : nil
            let exercise = WorkoutExercise.create(context: context)
            let set = WorkoutSet.create(context: context)
            set.weightValue = 20
            set.repetitionsValue = 5
            set.isCompleted = completed
            exercise.workoutSets = NSOrderedSet(array: [set])
            workout.workoutExercises = NSOrderedSet(array: [exercise])
            return workout
        }
        // Unsaved on purpose: a finished workout with an incomplete set fails model
        // validation, but Home's snapshot must still exclude it if one ever loads.
        let workouts = [workout(), workout(imported: true), workout(current: true), workout(completed: false)]
        let home = TrainingHistorySnapshot.build(from: workouts, calendar: calendar)
        let history = ThisWeekWidgetHistory(sessions: home.sessions.map {
            .init(date: $0.date, sets: $0.setCount, volume: $0.volume)
        })
        let summary = history.summary(at: now, calendar: calendar)
        XCTAssertEqual(summary.workouts, 2)
        XCTAssertEqual(summary.sets, 2)
        XCTAssertEqual(summary.volume, 200)
        XCTAssertEqual(summary.days.filter(\.isToday).count, 1)
        XCTAssertEqual(summary.days.first(where: \.isToday)?.volume, 200)
        XCTAssertEqual(summary.streak, home.streak(now: now, calendar: calendar))
    }

    func testWeekUsesLocalFirstWeekdayAndKeepsSevenEmptyTracks() {
        for firstWeekday in [1, 2] {
            let calendar = calendar(firstWeekday: firstWeekday)
            let now = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1, hour: 12))!
            let week = calendar.dateInterval(of: .weekOfYear, for: now)!
            let history = ThisWeekWidgetHistory(sessions: [
                .init(date: week.start.addingTimeInterval(-1), sets: 4, volume: 400),
                .init(date: week.start.addingTimeInterval(1), sets: 3, volume: 300),
                .init(date: week.end.addingTimeInterval(1), sets: 8, volume: 800)
            ])
            let summary = history.summary(at: now, calendar: calendar)
            XCTAssertEqual(summary.workouts, 1)
            XCTAssertEqual(summary.sets, 3)
            XCTAssertEqual(summary.volume, 300)
            XCTAssertEqual(summary.days.count, 7)
            XCTAssertEqual(summary.days.first?.date, week.start)
            XCTAssertEqual(summary.days.filter { $0.volume == 0 }.count, 6)
            XCTAssertEqual(calendar.component(.weekday, from: summary.days[0].date), firstWeekday)
        }
        let empty = ThisWeekWidgetHistory(sessions: []).summary(at: Date())
        XCTAssertEqual(empty.workouts, 0)
        XCTAssertEqual(empty.streak, 0)
        XCTAssertEqual(empty.days.count, 7)
        XCTAssertEqual(empty.workoutTarget, 7)
    }

    func testStreakMatchesHomeAcrossGraceWeeksGapsYearBoundariesAndCap() {
        for firstWeekday in [1, 2] {
            for zone in ["America/New_York", "Asia/Tokyo"] {
                let calendar = calendar(firstWeekday: firstWeekday, zone: zone)
                let now = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1, hour: 12))!
                let start = calendar.dateInterval(of: .weekOfYear, for: now)!.start
                let cases: [[Int]] = [[], [0], [1], [1, 2, 4], [0, 1, 2, 4], Array(0..<530)]
                for offsets in cases {
                    let weeks = Set(offsets.map {
                        calendar.date(byAdding: .weekOfYear, value: -$0, to: start)!
                    })
                    var home = TrainingHistorySnapshot()
                    home.trainedWeeks = weeks
                    XCTAssertEqual(ThisWeekWidgetHistory.streak(trainedWeeks: weeks, now: now, calendar: calendar),
                                   home.streak(now: now, calendar: calendar))
                }
            }
        }
    }

    func testMidnightUsesCalendarDaysAcrossDaylightSavingChanges() {
        let calendar = calendar()
        for (month, day, hours) in [(3, 8, 23), (11, 1, 25)] {
            let start = calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
            let midnight = ThisWeekWidgetHistory.nextMidnight(after: start, calendar: calendar)
            XCTAssertEqual(midnight.timeIntervalSince(start), Double(hours * 3600))
            XCTAssertEqual(calendar.component(.hour, from: midnight), 0)
            XCTAssertEqual(calendar.component(.day, from: midnight), day + 1)
        }
    }
}

final class HomeWeekSummaryTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    func testSummarySplitsThisWeekLastWeekMusclesAndFourWeekAverages() {
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        let calendar = calendar
        let legs = UUID(), chest = UUID(), back = UUID(), arms = UUID()
        let groups = [legs: "legs", chest: "chest", back: "back", arms: "arms"]
        func date(_ month: Int, _ day: Int, _ hour: Int = 10) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
        }
        func workout(on start: Date, exercise: UUID, sets: Int) -> Workout {
            let workout = Workout.create(context: context)
            workout.start = start
            workout.end = start.addingTimeInterval(3600)
            let item = WorkoutExercise.create(context: context)
            item.exerciseUuid = exercise
            item.workoutSets = NSOrderedSet(array: (0..<sets).map { _ in
                let set = WorkoutSet.create(context: context)
                set.weightValue = 20
                set.repetitionsValue = 5
                set.isCompleted = true
                return set
            })
            workout.workoutExercises = NSOrderedSet(array: [item])
            return workout
        }
        // Wednesday, October 28; the week runs Monday the 26th to Sunday, November 1.
        let now = date(10, 28, 12)
        let workouts = [
            workout(on: date(10, 26), exercise: legs, sets: 3),
            workout(on: date(10, 28, 9), exercise: chest, sets: 2),
            workout(on: date(10, 22), exercise: back, sets: 4),
            workout(on: date(10, 5), exercise: legs, sets: 1),
            workout(on: date(9, 1), exercise: arms, sets: 2)
        ]
        let sessions = TrainingHistorySnapshot.build(from: workouts, calendar: calendar).sessions
        let summary = HomeWeekSummary(sessions: sessions, muscleGroup: { groups[$0] }, now: now, calendar: calendar)

        XCTAssertEqual(summary.workouts, 2)
        XCTAssertEqual(summary.sets, 5)
        XCTAssertEqual(summary.lastWorkouts, 1)
        XCTAssertEqual(summary.lastSets, 4)
        XCTAssertEqual(summary.days.count, 7)
        XCTAssertEqual(summary.todayIndex, 2)
        XCTAssertEqual(summary.days.map(\.isFuture), [false, false, false, true, true, true, true])
        XCTAssertGreaterThan(summary.days[0].volume, 0)
        XCTAssertEqual(summary.days[1].volume, 0)
        XCTAssertEqual(summary.lastWeekVolumes.map { $0 > 0 }, [false, false, false, true, false, false, false])
        XCTAssertEqual(summary.muscleSets["legs"], [3, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(summary.muscleSets["chest"], [0, 0, 2, 0, 0, 0, 0])
        XCTAssertEqual(summary.weeklyAverages["legs"], 1)
        XCTAssertEqual(summary.weeklyAverages["chest"], 0.5)
        XCTAssertEqual(summary.weeklyAverages["back"], 1)
        XCTAssertEqual(summary.weeklyAverages["arms"], 0)
        XCTAssertEqual(summary.lastTrained["arms"], date(9, 1))
        XCTAssertEqual(summary.lastTrained["legs"], date(10, 26))
        XCTAssertNil(summary.lastTrained["abdominals"])
    }

    func testRunningTotalsStartAtZero() {
        XCTAssertEqual(HomeWeekSummary.runningTotals([1, 0, 2]), [0, 1, 1, 3])
    }

    func testHomeCardsDecodeSkipUnknownAndRepeatedNames() {
        XCTAssertEqual(HomeSection.decode("pace,bogus,rings,pace"), [.pace, .rings])
        XCTAssertEqual(HomeSection.decode(""), [])
        XCTAssertEqual(HomeSection.encode([.muscles, .bars]), "muscles,bars")
        XCTAssertEqual(HomeSection.decode("records,bodyWeight,nextWorkout,records"), [.records, .body, .nextWorkout])
        XCTAssertEqual(HomeSection.encode([.records, .body, .nextWorkout]), "records,body,nextWorkout")
        XCTAssertEqual(HomeSection.decode("body,bodyWeight"), [.body])
        for card in [HomeSection.records, .body, .nextWorkout] {
            XCTAssertFalse(card.isWeekCard)
            XCTAssertEqual(HomeSection.defaultCards.contains(card), card == .body)
        }
    }

    func testHomeCardsCarryOverBuild71Layout() {
        XCTAssertEqual(HomeSection.migrated(style: nil, order: nil, hidden: nil), HomeSection.defaultCards)
        XCTAssertEqual(HomeSection.migrated(style: "pace", order: "muscles,week", hidden: "body"),
                       [.muscles, .pace, .calendar, .recent, .pinned])
        XCTAssertEqual(HomeSection.migrated(style: "muscles", order: nil, hidden: nil).first, .muscleWeek)
    }
}

final class ExerciseBestsTests: XCTestCase {
    private let exerciseID = UUID()
    private let firstDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func workout(in context: NSManagedObjectContext, date: Date, weight: Double = 100,
                         reps: Int16 = 5, warmUp: Bool = false, completed: Bool = true,
                         current: Bool = false) -> Workout {
        let workout = Workout.create(context: context)
        workout.start = date
        workout.end = date.addingTimeInterval(3600)
        workout.isCurrentWorkout = current
        let exercise = WorkoutExercise.create(context: context)
        exercise.exerciseUuid = exerciseID
        let set = WorkoutSet.create(context: context)
        set.weightValue = weight
        set.repetitionsValue = reps
        set.tagValue = warmUp ? .warmUp : nil
        set.isCompleted = completed
        exercise.workoutSets = NSOrderedSet(array: [set])
        workout.workoutExercises = NSOrderedSet(array: [exercise])
        return workout
    }

    func testTiesKeepEarliestRecordDateForEveryBest() throws {
        let context = setUpInMemoryNSPersistentContainer().viewContext
        let later = workout(in: context, date: firstDate.addingTimeInterval(86_400))
        let earlier = workout(in: context, date: firstDate)
        let snapshot = TrainingHistorySnapshot.build(from: [later, earlier])
        let bests = try XCTUnwrap(snapshot.exerciseBests[exerciseID])
        for kind in ExerciseBests.Kind.allCases {
            XCTAssertEqual(bests[kind]?.date, firstDate)
            XCTAssertEqual(bests[kind]?.workoutID, earlier.objectID)
        }
        XCTAssertTrue(snapshot.recordEvents.isEmpty)
    }

    func testWarmUpsUnfinishedSetsAndCurrentWorkoutAreExcluded() throws {
        let context = setUpInMemoryNSPersistentContainer().viewContext
        let working = workout(in: context, date: firstDate)
        let warmUp = workout(in: context, date: firstDate.addingTimeInterval(1), weight: 200, reps: 10, warmUp: true)
        let unfinished = workout(in: context, date: firstDate.addingTimeInterval(2), weight: 300, reps: 20, completed: false)
        let active = workout(in: context, date: firstDate.addingTimeInterval(3), weight: 400, reps: 30, current: true)
        let snapshot = TrainingHistorySnapshot.build(from: [working, warmUp, unfinished, active])
        let bests = try XCTUnwrap(snapshot.exerciseBests[exerciseID])
        XCTAssertEqual(bests.heaviest?.value, 100)
        XCTAssertEqual(bests.mostReps?.value, 5)
        XCTAssertEqual(bests.sessionVolume?.value, 500)
        XCTAssertEqual(try XCTUnwrap(bests.estimatedOneRepMax).value, 100 * (1 + 5.0 / 30), accuracy: 0.0001)
        XCTAssertTrue(snapshot.recordEvents.isEmpty)
    }

    func testFirstSessionEstablishesBaselineWithoutARecordEvent() {
        let context = setUpInMemoryNSPersistentContainer().viewContext
        let first = workout(in: context, date: firstDate)
        let snapshot = TrainingHistorySnapshot.build(from: [first])
        XCTAssertFalse(snapshot.exerciseBests[exerciseID]?.isEmpty ?? true)
        XCTAssertTrue(snapshot.recordSetIDs.isEmpty)
        XCTAssertTrue(snapshot.recordEvents.isEmpty)
    }

    func testEstimatesUseEpleyAcrossModelChartsAndBestsForEverySetSize() throws {
        let context = setUpInMemoryNSPersistentContainer().viewContext
        let evaluator = WorkoutExerciseChartData.evaluator(for: .oneRM, weightUnit: .metric)
        let cases: [(reps: Int16, expected: Double)] = [
            (1, 100),
            (5, 100 * (1 + 5.0 / 30)),
            (12, 100 * (1 + 12.0 / 30)),
            (20, 100 * (1 + 20.0 / 30)),
            (40, 100 * (1 + 40.0 / 30))
        ]
        for (reps, expected) in cases {
            let session = workout(in: context, date: firstDate, reps: reps)
            let exercise = try XCTUnwrap(session.workoutExercises?.firstObject as? WorkoutExercise)
            let set = try XCTUnwrap(exercise.workoutSets?.firstObject as? WorkoutSet)
            let snapshot = TrainingHistorySnapshot.build(from: [session])
            let estimates = [
                ("Model / Siri", set.estimatedOneRepMax()),
                ("Progress / History", ExerciseProgressData.epleyEstimate(for: set)),
                ("Home / Siri charts", evaluator(exercise)),
                ("Bests", snapshot.exerciseBests[exerciseID]?.estimatedOneRepMax?.value)
            ]
            for (source, estimate) in estimates {
                let value = try XCTUnwrap(estimate, "\(source), \(reps) reps")
                XCTAssertTrue(value.isFinite, "\(source), \(reps) reps")
                if reps == 1 {
                    XCTAssertEqual(value, 100, "\(source): a single rep must equal its weight exactly")
                } else {
                    XCTAssertEqual(value, expected, accuracy: 0.0001, "\(source), \(reps) reps")
                }
            }
        }
    }

    func testProgressAndBestsKeepCompletionTrackingAndMeasurementFilters() throws {
        let context = setUpInMemoryNSPersistentContainer().viewContext
        let cases: [(completed: Bool, weight: Double, reps: Int16, duration: TimeInterval?, distance: Double?)] = [
            (false, 100, 20, nil, nil),
            (true, 100, 20, 60, nil),
            (true, 100, 20, nil, 100),
            (true, 0, 20, nil, nil),
            (true, -100, 20, nil, nil),
            (true, 100, 0, nil, nil),
            (true, 100, -1, nil, nil)
        ]
        for entry in cases {
            let session = workout(in: context, date: firstDate, weight: entry.weight,
                                  reps: entry.reps, completed: entry.completed)
            let exercise = try XCTUnwrap(session.workoutExercises?.firstObject as? WorkoutExercise)
            let set = try XCTUnwrap(exercise.workoutSets?.firstObject as? WorkoutSet)
            set.durationValue = entry.duration
            set.distanceValue = entry.distance
            let result = ExerciseBests.SetResult(
                id: set.objectID, exerciseID: exerciseID, workoutID: session.objectID, date: firstDate,
                weight: set.weightValue, repetitions: Int(set.repetitionsValue), trackingType: set.trackingType,
                isCompleted: set.isCompleted
            )
            XCTAssertNil(ExerciseProgressData.epleyEstimate(for: set), "\(entry)")
            XCTAssertNil(result.estimatedOneRepMax, "\(entry)")
            XCTAssertNil(TrainingHistorySnapshot.build(from: [session]).exerciseBests[exerciseID]?.estimatedOneRepMax,
                         "\(entry)")
        }
    }

    func testLaterHeavierSetIsARecordAndAgreesWithHistory() throws {
        let context = setUpInMemoryNSPersistentContainer().viewContext
        let first = workout(in: context, date: firstDate)
        let later = workout(in: context, date: firstDate.addingTimeInterval(86_400), weight: 110)
        let snapshot = TrainingHistorySnapshot.build(from: [later, first])
        let record = try XCTUnwrap(snapshot.recordEvents.first)
        XCTAssertEqual(snapshot.recordEvents.count, 1)
        XCTAssertEqual(record.workoutID, later.objectID)
        XCTAssertEqual(record.kind, .heaviest)
        XCTAssertTrue(snapshot.recordSetIDs.contains(record.id))
    }

    func testHistoryParetoRecordIsKeptWhenNeitherScalarBestImproves() throws {
        let context = setUpInMemoryNSPersistentContainer().viewContext
        let first = workout(in: context, date: firstDate, weight: 100, reps: 10)
        let heaviest = workout(in: context, date: firstDate.addingTimeInterval(1), weight: 120, reps: 1)
        let combination = workout(in: context, date: firstDate.addingTimeInterval(2), weight: 110, reps: 3)
        let snapshot = TrainingHistorySnapshot.build(from: [combination, first, heaviest])
        let record = try XCTUnwrap(snapshot.recordEvents.first)
        XCTAssertEqual(record.workoutID, combination.objectID)
        XCTAssertEqual(record.kind, .set)
        XCTAssertTrue(snapshot.recordSetIDs.contains(record.id))
    }

    func testSessionVolumeCombinesDuplicateExerciseEntriesInOneWorkout() throws {
        let context = setUpInMemoryNSPersistentContainer().viewContext
        let first = workout(in: context, date: firstDate, weight: 100)
        let later = workout(in: context, date: firstDate.addingTimeInterval(1), weight: 60)
        let duplicate = WorkoutExercise.create(context: context)
        duplicate.exerciseUuid = exerciseID
        let set = WorkoutSet.create(context: context)
        set.weightValue = 60
        set.repetitionsValue = 5
        set.isCompleted = true
        duplicate.workoutSets = NSOrderedSet(array: [set])
        later.addToWorkoutExercises(duplicate)
        let snapshot = TrainingHistorySnapshot.build(from: [first, later])
        let best = try XCTUnwrap(snapshot.exerciseBests[exerciseID]?.sessionVolume)
        XCTAssertEqual(best.value, 600)
        XCTAssertEqual(best.workoutID, later.objectID)
    }
}
