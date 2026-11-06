//
//  WorkoutSetFocus.swift
//  Iron
//
//  The one set that should receive the focused editor in the active workout.
//

import Foundation
import CoreData
import WorkoutDataKit

/// Identifies the single set that is currently promoted for focused entry.
///
/// A superset is treated as one ordered unit. Within that unit, the next round
/// is the lowest incomplete set index among its members; the original exercise
/// order breaks ties. This keeps alternating groups in round-robin order while
/// never jumping over an unfinished set in an individual exercise.
struct WorkoutSetFocus: Equatable {
    let exerciseID: NSManagedObjectID
    let setID: NSManagedObjectID

    private struct Unit {
        var members: [WorkoutExercise]
    }

    private struct Candidate {
        let setIndex: Int
        let memberIndex: Int
        let exercise: WorkoutExercise
        let set: WorkoutSet

        func precedes(_ other: Candidate) -> Bool {
            if setIndex != other.setIndex { return setIndex < other.setIndex }
            return memberIndex < other.memberIndex
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.exerciseID == rhs.exerciseID && lhs.setID == rhs.setID
    }

    /// Returns the next set to focus without changing the Core Data graph.
    ///
    /// Exercises with the same non-nil superset UUID share a unit even when
    /// they are separated in the workout's ordered relationship. Exercises
    /// without a superset remain independent units in their first-appearance
    /// order.
    static func next(in workout: Workout) -> Self? {
        guard workout.isCurrentWorkout else { return nil }

        let exercises = (workout.workoutExercises?.array as? [WorkoutExercise] ?? []).filter { !$0.isDeleted }
        guard !exercises.isEmpty else { return nil }

        var units: [Unit] = []
        var supersetUnitIndex: [UUID: Int] = [:]

        for exercise in exercises {
            if let supersetID = exercise.supersetUuid {
                if let unitIndex = supersetUnitIndex[supersetID] {
                    units[unitIndex].members.append(exercise)
                } else {
                    supersetUnitIndex[supersetID] = units.count
                    units.append(Unit(members: [exercise]))
                }
            } else {
                units.append(Unit(members: [exercise]))
            }
        }

        for unit in units {
            var candidate: Candidate?

            for (memberIndex, exercise) in unit.members.enumerated() {
                let sets = (exercise.workoutSets?.array as? [WorkoutSet] ?? []).filter { !$0.isDeleted }
                guard let setIndex = sets.firstIndex(where: { !$0.isCompleted }) else { continue }
                let set = sets[setIndex]

                let memberCandidate = Candidate(
                    setIndex: setIndex,
                    memberIndex: memberIndex,
                    exercise: exercise,
                    set: set
                )
                if let current = candidate {
                    if memberCandidate.precedes(current) { candidate = memberCandidate }
                } else {
                    candidate = memberCandidate
                }
            }

            if let candidate {
                return Self(exerciseID: candidate.exercise.objectID, setID: candidate.set.objectID)
            }
        }

        return nil
    }
}

/// Pure logger assistance. Each calculation's weights use the same unit.
enum LoggerAssist {
    enum PlateHintPresentation: Equatable {
        case hint, setUpChip, none
    }

    static func plateHintPresentation(
        isBarbell: Bool, equipment: [String], hasSavedSetup: Bool, showPlateCalculator: Bool
    ) -> PlateHintPresentation {
        guard showPlateCalculator else { return .none }
        if isBarbell || hasSavedSetup { return .hint }

        let equipment = equipment.map {
            $0.lowercased().replacingOccurrences(of: "-", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if equipment.contains(where: { $0.contains("plate loaded") }) { return .setUpChip }
        // A generic machine label must not override explicit stack/cable equipment.
        guard !equipment.contains(where: {
            $0.contains("cable") || $0.contains("pin stack") || $0.contains("pin loaded")
                || $0.contains("weight stack") || $0.contains("selectorized")
        }) else { return .none }
        // Match strength equipment, rather than cardio names such as "elliptical machine".
        let machines: Set<String> = [
            "machine", "chest machine", "machine: bench press", "machine: chest", "machine: butterfly",
            "smith machine", "lever", "lever machine", "leverage", "leverage machine",
            "sled", "sled machine", "t bar machine"
        ]
        return equipment.contains(where: { machines.contains($0) }) ? .setUpChip : .none
    }

    struct PreviousSet: Equatable {
        let weight: Double
        let repetitions: Int
        var minTarget: Int? = nil
        var maxTarget: Int? = nil

        var target: Int? { maxTarget ?? minTarget }
    }

    struct Suggestion: Equatable {
        let weight: Double
        let repetitions: Int
    }

    // The Workout tab's saved-plan preview still uses this older, lifting-only
    // input shape. Keep its API while routing all inheritance through the same
    // resolver as the two live loggers.
    struct SetValues: Equatable {
        var weight: Double = 0
        var repetitions: Int = 0
        var isCompleted = false
        var isWarmup = false
        var hasUserEnteredWeight = false
    }

    static func suggestedValues(
        at index: Int, currentSets: [SetValues], previousSets: [SetValues],
        trackingType: SetTrackingType, fallback _: Suggestion
    ) -> Suggestion? {
        guard trackingType.usesReps, currentSets.indices.contains(index), !currentSets[index].isCompleted else { return nil }
        let inputs = currentSets.map { set -> SetValuePrefill.SetInput in
            var fields = Set<SetTrackingType.Column>()
            if set.weight != 0 || set.hasUserEnteredWeight { fields.insert(.weight) }
            if set.repetitions != 0 { fields.insert(.reps) }
            return .init(values: .init(weight: set.weight, repetitions: set.repetitions),
                         userEnteredFields: fields, isCompleted: set.isCompleted, isWarmup: set.isWarmup)
        }
        let values = SetValuePrefill.resolve(currentSets: inputs, previousSets: previousSets.map {
            .init(values: .init(weight: $0.weight, repetitions: $0.repetitions), isWarmup: $0.isWarmup)
        }, trackingType: trackingType)[index]
        guard values.weight != nil || values.repetitions != nil else { return nil }
        return .init(weight: values.weight ?? 0, repetitions: values.repetitions ?? 0)
    }

    static func suggestion(
        previousWorkingSets: [PreviousSet], workingSetIndex: Int, increment: Double
    ) -> Suggestion? {
        guard previousWorkingSets.indices.contains(workingSetIndex),
              let first = previousWorkingSets.first, first.repetitions > 0,
              previousWorkingSets.allSatisfy({
                  $0.weight.isFinite && $0.weight >= 0
                      && $0.repetitions >= ($0.target ?? first.repetitions)
              }) else { return nil }

        let previous = previousWorkingSets[workingSetIndex]
        if previous.weight == 0 {
            guard previous.repetitions < Int.max else { return nil }
            return Suggestion(weight: 0, repetitions: previous.repetitions + 1)
        }
        guard increment.isFinite, increment > 0,
              (previous.weight + increment).isFinite else { return nil }
        let repetitions: Int
        if let minimum = previous.minTarget, let maximum = previous.maxTarget, minimum < maximum {
            repetitions = minimum
        } else {
            repetitions = previous.repetitions
        }
        return Suggestion(weight: previous.weight + increment, repetitions: repetitions)
    }

    struct WarmupSet: Equatable {
        let weight: Double
        let repetitions: Int
    }

    /// The quick menu sequence is separate from the existing calculator's plan.
    static func warmupSets(
        workingWeight: Double, increment: Double, barbell: PlateLoadout? = nil,
        inventory: PlateInventory = PlateInventory()
    ) -> [WarmupSet] {
        guard workingWeight.isFinite, workingWeight > 0,
              increment.isFinite, increment > 0 else { return [] }

        let templates: [(Double, Int)] = barbell == nil
            ? [(0.50, 8), (0.70, 4), (0.85, 2)]
            : [(0, 10), (0.50, 5), (0.70, 3), (0.85, 2)]
        let epsilon = max(1e-9, workingWeight.ulp * 4)
        var previousWeight: Double?
        return templates.compactMap { percentage, repetitions in
            let weight: Double
            if let barbell {
                guard workingWeight > barbell.baseWeight else { return nil }
                let raw = percentage == 0 ? barbell.baseWeight : workingWeight * percentage
                // The plate calculator already floors to enabled, loadable plates.
                weight = PlateLoadSolver.solve(target: raw, loadout: barbell, inventory: inventory).loadedTotal
                let smallestPair = (inventory.enabledPlates(for: barbell.unit).last ?? 0) * 2
                if weight == barbell.baseWeight,
                   workingWeight <= barbell.baseWeight + smallestPair + epsilon { return nil }
            } else {
                // Unit conversion can put an exact detent a few ulps below it.
                weight = floor((workingWeight * percentage + epsilon) / increment) * increment
            }
            guard weight > 0, weight < workingWeight, weight != previousWeight else { return nil }
            previousWeight = weight
            return WarmupSet(weight: weight, repetitions: repetitions)
        }
    }
}
