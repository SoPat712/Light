import XCTest
@testable import Iron

final class WarmupPlanTests: XCTestCase {
    func testPoundBarbellRoundingMatchesOriginalCalculator() {
        let plan = WarmupPlan.recommendations(workingWeight: 225, unit: .pound)
        // 70% is 157.5; the original 5 lb rounding rounds that tie UP to 160.
        XCTAssertEqual(plan.map(\.weight), [90, 125, 160, 185, 205])
        XCTAssertEqual(plan.map(\.repetitions), [10, 8, 5, 3, 1])
        XCTAssertEqual(plan.map(\.percentage), [0.40, 0.55, 0.70, 0.82, 0.92])
    }

    func testNoSetupMatchesOriginalAlgorithmInBothUnits() {
        let templates: [(Double, Int)] = [(0.40, 10), (0.55, 8), (0.70, 5), (0.82, 3), (0.92, 1)]
        for unit in WeightUnit.allCases {
            for working in [1.0, 19, 20, 21, 44, 45, 46, 60, 80, 95, 100, 135, 173.5, 225, 315] {
                var seen = Set<Double>()
                let original: [WarmupPlan.Recommendation] = templates.compactMap { percentage, reps in
                    let rounded = max((working * percentage / unit.barbellIncrement).rounded() * unit.barbellIncrement, unit.barbellWeight)
                    guard rounded < working, seen.insert(rounded).inserted else { return nil }
                    return .init(percentage: percentage, weight: rounded, repetitions: reps)
                }
                XCTAssertEqual(WarmupPlan.recommendations(workingWeight: working, unit: unit.plateLoadUnit), original)
            }
        }
    }

    func testMachineStartingWeightFloorsAndDeduplicates() {
        let plan = WarmupPlan.recommendations(workingWeight: 100, unit: .pound,
            loadout: PlateLoadout(mode: .machine(90), unit: .pound), inventory: inventory([10], unit: .pound))
        XCTAssertEqual(plan.map(\.weight), [90])
        XCTAssertEqual(plan.map(\.repetitions), [10])
        XCTAssertEqual(plan.map(\.percentage), [0.40])
    }

    func testNoBarCanRecommendBelowStandardBarWeight() {
        let plan = WarmupPlan.recommendations(workingWeight: 30, unit: .pound,
            loadout: PlateLoadout(mode: .noBar, loadedSides: .one, unit: .pound), inventory: inventory([5], unit: .pound))
        XCTAssertEqual(plan.map(\.weight), [10, 15, 20, 25])
        XCTAssertEqual(plan.map(\.repetitions), [10, 8, 5, 3])
    }

    func testLimitedPlatesDropDuplicatesAndWorkingWeight() {
        let plan = WarmupPlan.recommendations(workingWeight: 225, unit: .pound,
            loadout: PlateLoadout(mode: .barbell(45), unit: .pound), inventory: inventory([45], unit: .pound))
        XCTAssertEqual(plan.map(\.weight), [45, 135])
        XCTAssertTrue(plan.allSatisfy { $0.weight < 225 })
    }

    func testNearestLoadCanBeAbovePercentageButNeverAboveWork() {
        let plan = WarmupPlan.recommendations(workingWeight: 90, unit: .pound,
            loadout: PlateLoadout(mode: .noBar, loadedSides: .one, unit: .pound), inventory: inventory([25], unit: .pound))
        XCTAssertEqual(plan.map(\.weight), [25, 50, 75])
        XCTAssertEqual(plan.map(\.percentage), [0.40, 0.55, 0.70])
    }

    func testFindsLoadableCombinationsThatGreedyPlateSelectionMisses() {
        let plan = WarmupPlan.recommendations(workingWeight: 125, unit: .pound,
            loadout: PlateLoadout(mode: .noBar, loadedSides: .one, unit: .pound), inventory: inventory([35, 25], unit: .pound))
        XCTAssertEqual(plan.map(\.weight), [50, 70, 85, 100, 110])
    }

    func testLoadedSideCountAffectsRecommendations() {
        let plates = inventory([10], unit: .pound)
        let one = WarmupPlan.recommendations(workingWeight: 50, unit: .pound,
            loadout: PlateLoadout(mode: .noBar, loadedSides: .one, unit: .pound), inventory: plates)
        let both = WarmupPlan.recommendations(workingWeight: 50, unit: .pound,
            loadout: PlateLoadout(mode: .noBar, loadedSides: .both, unit: .pound), inventory: plates)
        XCTAssertEqual(one.map(\.weight), [20, 30, 40])
        XCTAssertEqual(both.map(\.weight), [20, 40])
    }

    func testKilogramsWithAndWithoutSetup() {
        XCTAssertEqual(WarmupPlan.recommendations(workingWeight: 100, unit: .kilogram).map(\.weight), [40, 55, 70, 82.5, 92.5])
        let plan = WarmupPlan.recommendations(workingWeight: 100, unit: .kilogram,
            loadout: PlateLoadout(mode: .barbell(20), unit: .kilogram), inventory: inventory([2.5], unit: .kilogram))
        XCTAssertEqual(plan.map(\.weight), [40, 55, 70, 80, 90])
    }

    func testSetupStartingWeightConvertsToDisplayUnit() {
        let plan = WarmupPlan.recommendations(workingWeight: 100, unit: .pound,
            loadout: PlateLoadout(mode: .machine(20), unit: .kilogram), inventory: inventory([], unit: .pound))
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan.first?.weight ?? 0, 20 / 0.45359237, accuracy: 0.000001)
    }

    func testEmptyInventoryOnlyAllowsStartingWeight() {
        let plan = WarmupPlan.recommendations(workingWeight: 225, unit: .pound,
            loadout: PlateLoadout(mode: .barbell(45), unit: .pound), inventory: inventory([], unit: .pound))
        XCTAssertEqual(plan.map(\.weight), [45])
    }

    func testQuarterPoundSingleSidePlateIsLoadable() {
        let plan = WarmupPlan.recommendations(workingWeight: 1, unit: .pound,
            loadout: PlateLoadout(mode: .noBar, loadedSides: .one, unit: .pound), inventory: inventory([0.25], unit: .pound))
        XCTAssertEqual(plan.map(\.weight), [0.5, 0.75])
    }

    func testWorkingWeightAtOrBelowBarIsEmpty() {
        XCTAssertTrue(WarmupPlan.recommendations(workingWeight: 44, unit: .pound).isEmpty)
        XCTAssertTrue(WarmupPlan.recommendations(workingWeight: 45, unit: .pound).isEmpty)
        XCTAssertTrue(WarmupPlan.recommendations(workingWeight: 19, unit: .kilogram).isEmpty)
        XCTAssertTrue(WarmupPlan.recommendations(workingWeight: 225, unit: .pound,
            loadout: PlateLoadout(mode: .barbell(250), unit: .pound)).isEmpty)
    }

    func testInvalidWorkingWeightsAreEmpty() {
        for weight in [0.0, -1, .infinity, .nan] {
            XCTAssertTrue(WarmupPlan.recommendations(workingWeight: weight, unit: .pound).isEmpty)
        }
    }

    func testWarmupsEnterExistingScheduleBeforeWorkingSets() {
        let working = WatchWorkoutSet(order: 1, weight: 225, reps: 5)
        let warmups = WarmupPlan.recommendations(workingWeight: 225, unit: .pound).map {
            WatchWorkoutSet(order: 0, weight: $0.weight, reps: $0.repetitions, completed: false, tag: "warmUp")
        }
        var snapshot = WatchWorkoutSnapshot(workoutID: UUID(), exercises: [
            WatchWorkoutExercise(order: 1, name: "Bench Press", sets: warmups + [working])
        ], selectedSetID: working.id, weightUnit: .pound)
        WatchWorkoutEditing.normalize(&snapshot)
        XCTAssertEqual(WatchWorkoutEditing.nextSet(in: snapshot), warmups.first?.id)
        XCTAssertEqual(WatchWorkoutEditing.schedule(in: snapshot), (warmups + [working]).map(\.id))
        XCTAssertEqual(snapshot.exercises[0].sets.map(\.order), [1, 2, 3, 4, 5, 6])
    }

    func testSupersetScheduleFindsFirstWarmupAndRetainsRoundRotation() {
        let group = UUID()
        let first = WatchWorkoutSet(order: 1, weight: 100, reps: 5, completed: true)
        let second = WatchWorkoutSet(order: 2, weight: 100, reps: 5)
        let working = WatchWorkoutSet(order: 1, weight: 225, reps: 5)
        let warmups = WarmupPlan.recommendations(workingWeight: 225, unit: .pound).map {
            WatchWorkoutSet(order: 0, weight: $0.weight, reps: $0.repetitions, tag: "warmUp")
        }
        var snapshot = WatchWorkoutSnapshot(workoutID: UUID(), exercises: [
            WatchWorkoutExercise(order: 1, name: "Row", sets: [first, second], supersetID: group),
            WatchWorkoutExercise(order: 2, name: "Bench Press", sets: warmups + [working], supersetID: group)
        ], weightUnit: .pound)
        WatchWorkoutEditing.normalize(&snapshot)
        XCTAssertEqual(WatchWorkoutEditing.nextSet(in: snapshot), warmups.first?.id)
        XCTAssertEqual(Array(WatchWorkoutEditing.schedule(in: snapshot).prefix(4)),
                       [first.id, warmups[0].id, second.id, warmups[1].id])
    }

    private func inventory(_ weights: [Double], unit: WatchWorkoutWeightUnit) -> PlateInventory {
        var inventory = PlateInventory()
        for weight in PlateInventory.availablePlates(for: unit) {
            inventory.setEnabled(weights.contains(weight), weight: weight, unit: unit)
        }
        return inventory
    }
}
