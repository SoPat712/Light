//
//  WorkoutSet+WeightUnit.swift
//  Iron
//
//  Created by Karim Abou Zeid on 05.12.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import Foundation
import WorkoutDataKit

extension WorkoutSet {
    func displayTitle(weightUnit: WeightUnit) -> String {
        displayTitle(unit: weightUnit.unit, formatter: weightUnit.formatter)
    }

    var trackingData: SetTrackingType.SetData {
        .init(weight: weightValue, reps: Int(repetitionsValue), duration: durationValue, distance: distanceValue)
    }

    /// Actual recorded dimensions take precedence over a later preference change.
    var trackingType: SetTrackingType {
        let preferred = workoutExercise?.setTrackingType ?? .weightReps
        return SetTrackingType.resolved(preferred, from: trackingData)
    }

    var trackedVolume: Double {
        trackingType.volume(weight: weightValue, reps: Int(repetitionsValue))
    }

    func prepare(for type: SetTrackingType) {
        if !type.usesWeight { weightValue = 0 }
        if !type.usesReps {
            repetitionsValue = 0
            minTargetRepetitionsValue = nil
            maxTargetRepetitionsValue = nil
        } else if repetitionsValue == 0 {
            repetitionsValue = 5
        }
        durationValue = type.usesDuration ? (durationValue ?? 60) : nil
        if !type.usesDistance { distanceValue = nil }
    }

    /// The compact result shown anywhere a completed set is summarized.
    func resultTitle(weightUnit: WeightUnit) -> String {
        let type = trackingType
        var parts: [String] = []
        if type.usesWeight {
            parts.append(type.weightPrefix + WeightUnit.format(weight: weightValue, from: .metric, to: weightUnit))
        }
        if type.usesReps {
            if type.usesWeight { return "\(parts[0]) × \(repetitionsValue)" }
            parts.append("\(repetitionsValue) \(repetitionsValue == 1 ? "rep" : "reps")")
        }
        if type.usesDistance, let distance = distanceValue {
            parts.append(Self.distanceTitle(distance, weightUnit: weightUnit))
        }
        if type.usesDuration, let duration = durationValue {
            parts.append(SetTrackingType.durationText(duration))
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    /// Retain extra imported dimensions that don't fit one of the eight editors.
    func additionalTrackingTitle(weightUnit: WeightUnit) -> String {
        var values: [String] = []
        if !trackingType.usesWeight, weightValue > 0 {
            values.append(WeightUnit.format(weight: weightValue, from: .metric, to: weightUnit))
        }
        if !trackingType.usesReps, repetitionsValue > 0 { values.append("\(repetitionsValue) reps") }
        return values.joined(separator: " · ")
    }

    static func distanceTitle(_ meters: Double, weightUnit: WeightUnit) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let value = distanceDisplayValue(meters, weightUnit: weightUnit)
        return "\(formatter.string(from: NSNumber(value: value)) ?? "0") \(distanceUnit(weightUnit))"
    }
    static func distanceUnit(_ weightUnit: WeightUnit) -> String { weightUnit == .metric ? "km" : "mi" }
    static func distanceDisplayValue(_ meters: Double, weightUnit: WeightUnit) -> Double {
        Measurement<UnitLength>(value: meters, unit: .meters).converted(to: weightUnit == .metric ? .kilometers : .miles).value
    }
    static func distanceMeters(_ value: Double, weightUnit: WeightUnit) -> Double {
        Measurement<UnitLength>(value: value, unit: weightUnit == .metric ? .kilometers : .miles).converted(to: .meters).value
    }

    func logTitle(weightUnit: WeightUnit) -> String {
        logTitle(unit: weightUnit.unit, formatter: weightUnit.formatter)
    }

}

extension WorkoutExercise {
    var setTrackingType: SetTrackingType {
        trackingType(catalogExercise: exerciseUuid.flatMap { ExerciseStore.shared.exercisesByUUID[$0] })
    }
    func trackingType(catalogExercise catalog: Exercise?, defaults: UserDefaults = .standard) -> SetTrackingType {
        let fallback = SetTrackingType.defaultType(name: catalog?.title ?? "", equipment: catalog?.equipment ?? [], category: catalog?.muscleGroup ?? "")
        if let override = SetTrackingPreferences.override(for: exerciseUuid, defaults: defaults) { return override }
        let sets = workoutSets?.array as? [WorkoutSet] ?? []
        if let timed = sets.first(where: { $0.durationValue != nil || $0.distanceValue != nil }),
           SetTrackingType.infer(from: timed.trackingData) != nil {
            return SetTrackingType.resolved(fallback, from: timed.trackingData)
        }
        if fallback == .bodyweightReps, sets.contains(where: { $0.weightValue > 0 }) { return .weightedBodyweight }
        // A live lifting editor starts with reps and zero load. Infer reps-only
        // from recorded results, never from those unfinished placeholder rows.
        if let measured = sets.first(where: { $0.isCompleted && SetTrackingType.infer(from: $0.trackingData) != nil }) {
            return SetTrackingType.resolved(fallback, from: measured.trackingData)
        }
        return fallback
    }
    var trackedCompletedVolume: Double {
        (workoutSets?.array as? [WorkoutSet] ?? []).filter(\.isCompleted).reduce(0) { $0 + $1.trackedVolume }
    }
}

extension WorkoutRoutineExercise {
    var setTrackingType: SetTrackingType {
        trackingType(catalogExercise: exerciseUuid.flatMap { ExerciseStore.shared.exercisesByUUID[$0] })
    }
    func trackingType(catalogExercise catalog: Exercise?, defaults: UserDefaults = .standard) -> SetTrackingType {
        if let override = SetTrackingPreferences.override(for: exerciseUuid, defaults: defaults) { return override }
        let fallback = SetTrackingType.defaultType(name: catalog?.title ?? "", equipment: catalog?.equipment ?? [], category: catalog?.muscleGroup ?? "")
        let sets = workoutRoutineSets?.array as? [WorkoutRoutineSet] ?? []
        if let timed = sets.first(where: { $0.durationValue != nil || SetTrackingPreferences.routineDistance(for: $0.uuid, defaults: defaults) != nil }) {
            return SetTrackingType.resolved(fallback, from: .init(weight: timed.weightValue ?? 0,
                duration: timed.durationValue, distance: SetTrackingPreferences.routineDistance(for: timed.uuid, defaults: defaults)))
        }
        if fallback == .bodyweightReps, sets.contains(where: { ($0.weightValue ?? 0) > 0 }) { return .weightedBodyweight }
        return fallback
    }
}

extension Workout {
    var trackedCompletedVolume: Double {
        (workoutExercises?.array as? [WorkoutExercise] ?? []).reduce(0) { $0 + $1.trackedCompletedVolume }
    }
}
