//
//  WorkoutSet.swift
//  Rhino Fit
//
//  Created by Karim Abou Zeid on 14.02.18.
//  Copyright © 2018 Karim Abou Zeid Software. All rights reserved.
//

import CoreData
import Combine

extension WorkoutSet {
    public var id: NSManagedObjectID { self.objectID }
}

public class WorkoutSet: NSManagedObject, Codable {
    public static var MAX_REPETITIONS: Int16 = 9999
    public static var MAX_WEIGHT: Double = 99999
    
    public class func create(context: NSManagedObjectContext) -> WorkoutSet {
        let workoutSet = WorkoutSet(context: context)
        workoutSet.uuid = UUID()
        return workoutSet
    }
    
    // MARK: Normalized properties
    
    public var weightValue: Double {
        get {
            weight?.doubleValue ?? 0
        }
        set {
            weight = newValue as NSNumber
        }
    }
    
    public var repetitionsValue: Int16 {
        get {
            repetitions?.int16Value ?? 0
        }
        set {
            repetitions = newValue as NSNumber
        }
    }
    
    public var minTargetRepetitionsValue: Int16? {
        get {
            minTargetRepetitions?.int16Value
        }
        set {
            minTargetRepetitions = newValue as NSNumber?
        }
    }
    
    public var maxTargetRepetitionsValue: Int16? {
        get {
            maxTargetRepetitions?.int16Value
        }
        set {
            maxTargetRepetitions = newValue as NSNumber?
        }
    }
    
    public var tagValue: WorkoutSetTag? {
        get {
            WorkoutSetTag(rawValue: tag ?? "")
        }
        set {
            tag = newValue?.rawValue
        }
    }
    
    public var rpeValue: Double? {
        get {
            RPE.allowedValues.contains(rpe) ? rpe : nil
        }
        set {
            let newValue = newValue ?? 0
            rpe = RPE.allowedValues.contains(newValue) ? newValue : 0
        }
    }

    public var durationValue: TimeInterval? {
        get { duration > 0 ? duration : nil }
        set { duration = max(newValue ?? 0, 0) }
    }

    public var distanceValue: Double? {
        get { distance > 0 ? distance : nil }
        set { distance = max(newValue ?? 0, 0) }
    }
    
    // MARK: Derived properties
    
    public func estimatedOneRepMax() -> Double? {
        guard repetitionsValue > 0 else { return nil }
        return repetitionsValue == 1 ? weightValue : weightValue * (1 + Double(repetitionsValue) / 30) // Epley
    }

    public var isPersonalRecord: Bool? {
        let preferred = SetTrackingPreferences.override(for: workoutExercise?.exerciseUuid) ?? .weightReps
        let data = SetTrackingType.SetData(weight: weightValue, reps: Int(repetitionsValue),
                                          duration: durationValue, distance: distanceValue)
        let type = SetTrackingType.resolved(preferred, from: data)
        if type.usesWeight, weight == nil { return nil }
        if type.usesReps, repetitions == nil { return nil }
        let validMeasurement = Self.personalRecordValidityPredicate(for: type)
        guard validMeasurement.evaluate(with: self) else { return false }
        guard let start = workoutExercise?.workout?.start else { return nil }
        guard let exerciseUuid = workoutExercise?.exerciseUuid else { return nil }
        guard let context = managedObjectContext else { return nil }

        let sameDimension = Self.personalRecordTypePredicate(type, preferred: preferred)
        let comparable = NSCompoundPredicate(andPredicateWithSubpredicates: [sameDimension, validMeasurement])

        let previousSetsPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format:
                "\(#keyPath(WorkoutSet.workoutExercise.exerciseUuid)) == %@ AND \(#keyPath(WorkoutSet.isCompleted)) == %@ AND \(#keyPath(WorkoutSet.workoutExercise.workout.start)) < %@",
                exerciseUuid as CVarArg, true as NSNumber, start as NSDate),
            comparable
        ])

        // A date edit dirties the Workout, not its sets. Reconcile those graphs
        // explicitly so a store-level relationship predicate cannot use the old
        // start date. Unchanged history still uses bounded existence queries.
        let editedWorkouts = context.updatedObjects.compactMap { $0 as? Workout }.filter {
            $0.changedValues()[#keyPath(Workout.start)] != nil
        }
        let editedWorkoutSets = editedWorkouts.flatMap { $0.workoutExercises?.array as? [WorkoutExercise] ?? [] }
            .filter { $0.exerciseUuid == exerciseUuid }
            .flatMap { $0.workoutSets?.array as? [WorkoutSet] ?? [] }
        func hasPreviousSet(matching predicate: NSPredicate) throws -> Bool {
            if editedWorkoutSets.contains(where: { !$0.isDeleted && predicate.evaluate(with: $0) }) { return true }
            let request: NSFetchRequest<WorkoutSet> = WorkoutSet.fetchRequest()
            var predicates = [predicate]
            if !editedWorkouts.isEmpty {
                predicates.append(NSPredicate(format: "NOT (%K IN %@)",
                    #keyPath(WorkoutSet.workoutExercise.workout), editedWorkouts))
            }
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            request.fetchLimit = 1
            return try context.count(for: request) > 0
        }
        guard let hasHistory = try? hasPreviousSet(matching: previousSetsPredicate) else { return nil }
        if !hasHistory { return false } // The first workout in each dimension establishes a baseline.

        let betterOrEqual = personalRecordDominancePredicate(for: type, data: data)
        let betterOrEqualPreviousSetsPredicate = NSCompoundPredicate(andPredicateWithSubpredicates:
            [previousSetsPredicate, betterOrEqual]
        )
        guard let hasBetterOrEqualHistory = try? hasPreviousSet(matching: betterOrEqualPreviousSetsPredicate) else { return nil }
        if hasBetterOrEqualHistory { return false } // there are better sets

        guard let sets = workoutExercise?.workoutSets else { return nil }
        let index = sets.index(of: self)
        guard index != NSNotFound else { return nil }
        // Preserve ordered-set suppression (including unfinished earlier rows),
        // without copying/filtering the prefix or fetching historical objects.
        for earlierIndex in 0..<index {
            guard let earlier = sets.object(at: earlierIndex) as? WorkoutSet else { continue }
            if comparable.evaluate(with: earlier), betterOrEqual.evaluate(with: earlier) { return false }
        }
        return true
    }

    private static func personalRecordValidityPredicate(for type: SetTrackingType) -> NSPredicate {
        let maximum = Double.greatestFiniteMagnitude as NSNumber
        return NSCompoundPredicate(andPredicateWithSubpredicates: type.personalRecordMetrics.map { metric in
            let key = personalRecordKeyPath(for: metric.column)
            if metric.column == .reps { return NSPredicate(format: "%K > 0", key) }
            let comparison = metric.column == .weight ? ">=" : ">"
            return NSPredicate(format: "%K \(comparison) 0 AND %K <= %@", key, key, maximum)
        })
    }

    private func personalRecordDominancePredicate(for type: SetTrackingType, data: SetTrackingType.SetData) -> NSPredicate {
        NSCompoundPredicate(andPredicateWithSubpredicates: type.personalRecordMetrics.map { metric in
            let comparison = metric.lowerIsBetter ? "<=" : ">="
            return NSPredicate(format: "%K \(comparison) %@", Self.personalRecordKeyPath(for: metric.column),
                               metric.value(in: data) as NSNumber)
        })
    }

    private static func personalRecordKeyPath(for column: SetTrackingType.Column) -> String {
        switch column {
        case .weight: return #keyPath(WorkoutSet.weight)
        case .reps: return #keyPath(WorkoutSet.repetitions)
        case .duration: return #keyPath(WorkoutSet.duration)
        case .distance: return #keyPath(WorkoutSet.distance)
        }
    }

    private static func personalRecordTypePredicate(_ type: SetTrackingType, preferred: SetTrackingType) -> NSPredicate {
        // Mirror inference with store-translatable predicates. Resolve only six
        // representative measurements, rather than loading/scanning history for
        // every list row. Missing optional values must also match in SQLite.
        func present(_ key: String) -> NSPredicate {
            NSPredicate(format: "%K > 0 AND %K <= %@", key, key, Double.greatestFiniteMagnitude as NSNumber)
        }
        func absent(_ key: String) -> NSPredicate {
            NSPredicate(format: "%K == nil OR %K <= 0 OR %K > %@", key, key, key, Double.greatestFiniteMagnitude as NSNumber)
        }
        let load = present(#keyPath(WorkoutSet.weight))
        let noLoad = absent(#keyPath(WorkoutSet.weight))
        let time = present(#keyPath(WorkoutSet.duration))
        let noTime = absent(#keyPath(WorkoutSet.duration))
        let distance = present(#keyPath(WorkoutSet.distance))
        let noDistance = absent(#keyPath(WorkoutSet.distance))
        let possibilities: [(SetTrackingType.SetData, [NSPredicate])] = [
            (.init(weight: 1, reps: 1), [noDistance, noTime, load]),
            (.init(reps: 1), [noDistance, noTime, noLoad, NSPredicate(format: "%K > 0", #keyPath(WorkoutSet.repetitions))]),
            (.init(duration: 1), [noDistance, time, noLoad]),
            (.init(weight: 1, duration: 1), [noDistance, time, load]),
            (.init(distance: 1), [distance, NSCompoundPredicate(orPredicateWithSubpredicates: [noLoad, time])]),
            (.init(weight: 1, distance: 1), [distance, load, noTime])
        ]
        return NSCompoundPredicate(orPredicateWithSubpredicates: possibilities.compactMap { data, predicates in
            guard SetTrackingType.resolved(preferred, from: data) == type else { return nil }
            return NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        })
    }
    
    // MARK: - Codable
    
    private enum CodingKeys: String, CodingKey {
        case uuid
        case repetitions
        case minTargetRepetitions
        case maxTargetRepetitions
        case weight
        case rpe
        case tag
        case comment
        case duration
        case distance
        case completedAt
    }
    
    required convenience public init(from decoder: Decoder) throws {
        guard let contextKey = CodingUserInfoKey.managedObjectContextKey,
            let context = decoder.userInfo[contextKey] as? NSManagedObjectContext,
            let entity = NSEntityDescription.entity(forEntityName: "WorkoutSet", in: context)
            else {
            throw CodingUserInfoKey.DecodingError.managedObjectContextMissing
        }
        self.init(entity: entity, insertInto: context)
        
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try container.decodeIfPresent(UUID.self, forKey: .uuid) ?? UUID() // make sure we always have an UUID
        repetitionsValue = try container.decode(Int16.self, forKey: .repetitions)
        weightValue = try container.decode(Double.self, forKey: .weight)
        rpeValue = try container.decodeIfPresent(Double.self, forKey: .rpe)
        tagValue = WorkoutSetTag(rawValue: try container.decodeIfPresent(String.self, forKey: .tag) ?? "")
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
        minTargetRepetitionsValue = try container.decodeIfPresent(Int16.self, forKey: .minTargetRepetitions)
        maxTargetRepetitionsValue = try container.decodeIfPresent(Int16.self, forKey: .maxTargetRepetitions)
        durationValue = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        distanceValue = try container.decodeIfPresent(Double.self, forKey: .distance)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        isCompleted = true
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uuid ?? UUID(), forKey: .uuid)
        try container.encode(repetitionsValue, forKey: .repetitions)
        try container.encode(weightValue, forKey: .weight)
        try container.encodeIfPresent(rpeValue, forKey: .rpe)
        try container.encodeIfPresent(tagValue?.rawValue, forKey: .tag)
        try container.encodeIfPresent(comment, forKey: .comment)
        try container.encodeIfPresent(minTargetRepetitionsValue, forKey: .minTargetRepetitions)
        try container.encodeIfPresent(maxTargetRepetitionsValue, forKey: .maxTargetRepetitions)
        try container.encodeIfPresent(durationValue, forKey: .duration)
        try container.encodeIfPresent(distanceValue, forKey: .distance)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
    }
}

// MARK: Display

extension WorkoutSet {
    public func displayTitle(unit: UnitMass, formatter: MeasurementFormatter) -> String {
//        let numberFormatter = unit.numberFormatter
//        numberFormatter.minimumFractionDigits = unit.defaultFractionDigits
//        let weightInUnit = WeightUnit.convert(weight: weight, from: .metric, to: unit)
//        return "\(numberFormatter.string(from: weightInUnit as NSNumber) ?? String(format: "%\(unit.maximumFractionDigits).f")) \(unit.abbrev) × \(repetitions)"
        return formatter.string(from: Measurement(value: weightValue, unit: UnitMass.kilograms).converted(to: unit)) + " × \(repetitionsValue)"
    }
    
    public func logTitle(unit: UnitMass, formatter: MeasurementFormatter) -> String {
        let title = displayTitle(unit: unit, formatter: formatter)
        guard let tag = tagValue?.title.capitalized, !tag.isEmpty else { return title }
        return title + " (\(tag))"
    }
}

// MARK: Validation

extension WorkoutSet {
    override public func validateForUpdate() throws {
        try super.validateForUpdate()
        try validateConsistency()
    }
    
    override public func validateForInsert() throws {
        try super.validateForInsert()
        try validateConsistency()
    }
    
    func validateConsistency() throws {
        if !isCompleted, let workout = workoutExercise?.workout, !workout.isCurrentWorkout {
            throw error(code: 1, message: "The set is not completed eventhough its workout is not the current workout.")
        }
    }
    
    private func error(code: Int, message: String) -> NSError {
        NSError(domain: "WORKOUT_SET_ERROR_DOMAIN", code: code, userInfo: [NSLocalizedFailureReasonErrorKey: message, NSValidationObjectErrorKey: self])
    }
}
