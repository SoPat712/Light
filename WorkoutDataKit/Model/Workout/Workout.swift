//
//  Workout.swift
//  Rhino Fit
//
//  Created by Karim Abou Zeid on 14.02.18.
//  Copyright © 2018 Karim Abou Zeid Software. All rights reserved.
//

import CoreData
import Combine
import os.log

extension Workout {
    public var id: NSManagedObjectID { self.objectID }
}

public class Workout: NSManagedObject, Codable {
    public static var currentWorkoutFetchRequest: NSFetchRequest<Workout> {
        let request: NSFetchRequest<Workout> = Workout.fetchRequest()
        request.predicate = NSPredicate(format: "\(#keyPath(Workout.isCurrentWorkout)) == %@", NSNumber(booleanLiteral: true))
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Workout.start, ascending: false)]
        return request
    }

    public static let dateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        dateFormatter.doesRelativeDateFormatting = true
        return dateFormatter
    }()

    public static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute]
        return formatter
    }()
    
    public class func create(context: NSManagedObjectContext) -> Workout {
        let workout = Workout(context: context)
        workout.uuid = UUID()
        return workout
    }
    
    // v6 generates `@NSManaged public var importSource: String?` alongside
    // the other managed properties. Any source marks a historical import.
    public var isImported: Bool { importSource != nil }

    // v6 also generates healthExportState: nil (legacy/not requested),
    // "pending", "exported", "watch" (Watch owns the Health recording), or
    // "test" (permanently excluded debug test workout; survives release installs).

    public enum HealthExportEligibility: Equatable {
        case eligible
        case imported
        case invalidWorkout
    }

    /// The only allowlist for phone Health mutations, including legacy sessions.
    public var healthExportEligibility: HealthExportEligibility {
        Self.healthExportEligibility(importSource: importSource, isCurrent: isCurrentWorkout,
                                     start: start, end: end, duration: duration)
    }

    public static func healthExportEligibility(
        importSource: String?, isCurrent: Bool, start: Date?, end: Date?, duration: TimeInterval?
    ) -> HealthExportEligibility {
        guard importSource == nil else { return .imported }
        guard !isCurrent, let start, let end, let duration,
              start.timeIntervalSinceReferenceDate.isFinite,
              end.timeIntervalSinceReferenceDate.isFinite,
              duration.isFinite, duration > 0, end > start else { return .invalidWorkout }
        return .eligible
    }

    // MARK: Derived properties
    
    public var isCompleted: Bool? {
        guard let workoutExercises = workoutExercises else { return nil }
        return !workoutExercises
            .compactMap { $0 as? WorkoutExercise }
            .contains { !($0.isCompleted ?? false) }
    }
    
    public var hasCompletedSets: Bool? {
        guard let workoutExercises = workoutExercises else { return nil }
        return workoutExercises
            .compactMap { $0 as? WorkoutExercise }
            .contains {
                guard let sets = $0.workoutSets?.compactMap({ $0 as? WorkoutSet }) else { return false }
                return sets.contains { $0.isCompleted }
            }
    }

    public func workoutPlanAndRoutineTitle() -> String? {
        // `WorkoutPlan` is now only the backwards-compatible persistence
        // container. The saved item users create and name is the Plan itself,
        // so exposing both levels produced titles such as
        // "Workouts - Workout A" throughout the active workout UI.
        workoutRoutine?.displayTitle
    }
    
    public func generatedTitle(in exercises: [Exercise]) -> String? {
        Self.generatedTitle(muscleGroups: muscleGroups(in: exercises), at: start ?? Date())
    }

    /// Names a session the way a person would: time of day plus the split that
    /// actually got trained, e.g. "Early Morning Leg Day".
    public static func generatedTitle(
        muscleGroups: [String],
        at date: Date,
        calendar: Calendar = .current
    ) -> String? {
        guard let focus = trainingFocusTitle(from: muscleGroups) else { return nil }
        return "\(timeOfDayPrefix(at: date, calendar: calendar)) \(focus)"
    }

    public static func timeOfDayPrefix(at date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 4..<9: return "Early Morning"
        case 9..<12: return "Morning"
        case 12..<17: return "Afternoon"
        case 17..<21: return "Evening"
        default: return "Late Night"
        }
    }

    public static func trainingFocusTitle(from muscleGroups: [String]) -> String? {
        let groups = muscleGroups.map { $0.lowercased() }
        guard let primary = groups.first else { return nil }

        var unique: [String] = []
        for group in groups where !unique.contains(group) {
            unique.append(group)
        }
        let set = Set(unique)
        let upper: Set<String> = ["chest", "back", "shoulders", "arms"]
        let hasLegs = set.contains("legs")
        let upperCount = set.intersection(upper).count

        if hasLegs && upperCount >= 2 { return "Full Body" }
        if unique.count >= 4 { return "Full Body" }

        if unique.count >= 2 {
            let pair = Set(unique.prefix(2))
            if pair == ["chest", "arms"] { return "Chest + Arms" }
            if pair == ["chest", "shoulders"] { return "Push Day" }
            if pair == ["shoulders", "arms"] { return "Push Day" }
            if pair == ["back", "arms"] { return "Pull Day" }
            if pair == ["back", "chest"] { return "Upper Body" }
            if pair == ["legs", "abdominals"] { return "Leg Day" }
            if unique.count == 2 {
                return "\(friendlyMuscleName(unique[0])) + \(friendlyMuscleName(unique[1]))"
            }
        }

        switch primary {
        case "legs": return "Leg Day"
        case "arms": return "Arm Day"
        case "chest": return "Chest Day"
        case "back": return "Back Day"
        case "shoulders": return "Shoulder Day"
        case "abdominals": return "Core Day"
        case "cardio": return "Cardio"
        default: return primary.capitalized
        }
    }

    private static func friendlyMuscleName(_ group: String) -> String {
        switch group {
        case "abdominals": return "Core"
        case "arms": return "Arms"
        case "shoulders": return "Shoulders"
        case "back": return "Back"
        case "legs": return "Legs"
        case "chest": return "Chest"
        case "cardio": return "Cardio"
        default: return group.capitalized
        }
    }

    public func optionalDisplayTitle(in exercises: [Exercise]) -> String? {
        title ?? workoutPlanAndRoutineTitle() ?? generatedTitle(in: exercises)
    }

    public func displayTitle(in exercises: [Exercise]) -> String {
        optionalDisplayTitle(in: exercises) ?? "Workout"
    }

    // no duplicate entries, sorted descending by frequency
    public func muscleGroups(in exercises: [Exercise]) -> [String] {
        var muscleGroups = [String]()
        
        let workoutExercises = self.workoutExercises?.array as? [WorkoutExercise] ?? []
        for workoutExercise in workoutExercises {
            if let exercise = workoutExercise.exercise(in: exercises) {
                // even if there are no sets, add the muscle group at least once
                let factor = max(workoutExercise.workoutSets?.count ?? 1, 1)
                muscleGroups.append(contentsOf: Array(repeating: exercise.muscleGroup, count: factor))
            }
        }
        return muscleGroups.sortedByFrequency().uniqed().reversed()
    }
    
    public var duration: TimeInterval? {
        guard let start = start, let end = end else { return nil }
        return end.timeIntervalSince(start)
    }

    public var sessionEffortValue: Double? {
        get { (1.0...10.0).contains(sessionEffort) ? sessionEffort : nil }
        set { sessionEffort = newValue.map { min(max($0, 1), 10) } ?? 0 }
    }

    public var numberOfCompletedSets: Int? {
        workoutExercises?
            .map { $0 as! WorkoutExercise }
            .reduce(0, { (count, workoutExercise) -> Int in
                count + (workoutExercise.numberOfCompletedSets ?? 0)
            })
    }
    
    public var totalCompletedWeight: Double? {
        workoutExercises?
            .map { $0 as! WorkoutExercise }
            .reduce(0, { (weight, workoutExercise) -> Double in
                weight + (workoutExercise.totalCompletedWeight ?? 0)
            })
    }
    
    // MARK: - Codable
    private enum CodingKeys: String, CodingKey {
        case uuid
        case title
        case comment
        case start
        case end
        case exercises
        case routineUuid
        case sessionEffort
        case importSource
        case healthExportState
    }
    
    required convenience public init(from decoder: Decoder) throws {
        guard let contextKey = CodingUserInfoKey.managedObjectContextKey,
            let context = decoder.userInfo[contextKey] as? NSManagedObjectContext,
            let entity = NSEntityDescription.entity(forEntityName: "Workout", in: context)
            else {
            throw CodingUserInfoKey.DecodingError.managedObjectContextMissing
        }
        self.init(entity: entity, insertInto: context)
        
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try container.decodeIfPresent(UUID.self, forKey: .uuid) ?? UUID() // make sure we always have an UUID
        title = try container.decodeIfPresent(String.self, forKey: .title)
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
        let storedSource = try container.decodeIfPresent(String.self, forKey: .importSource)
        let storedState = try container.decodeIfPresent(String.self, forKey: .healthExportState)
        // Only a backup restores provenance. A history JSON import cannot claim
        // to have been completed/exported by this installation of Iron.
        let preservingProvenance = decoder.userInfo[.preserveWorkoutProvenance] as? Bool == true
        importSource = preservingProvenance ? storedSource : "json"
        healthExportState = preservingProvenance ? storedState : nil
        start = try container.decode(Date.self, forKey: .start)
        end = try container.decode(Date.self, forKey: .end)
        sessionEffortValue = try container.decodeIfPresent(Double.self, forKey: .sessionEffort)
        workoutExercises = NSOrderedSet(array: try container.decodeIfPresent([WorkoutExercise].self, forKey: .exercises) ?? [])
        
        if let routineUuid = try container.decodeIfPresent(UUID.self, forKey: .routineUuid) {
            let request: NSFetchRequest<WorkoutRoutine> = WorkoutRoutine.fetchRequest()
            request.predicate = NSPredicate(format: "\(#keyPath(WorkoutRoutine.uuid)) == %@", routineUuid as NSUUID)
            workoutRoutine = try managedObjectContext?.fetch(request).first
            if workoutRoutine == nil {
                os_log("Could not find workout routine with uuid=%@", log: .modelCoding, type: .fault, routineUuid as NSUUID)
                throw DecodingError.dataCorruptedError(forKey: .routineUuid, in: container, debugDescription: "Could not find workout routine with uuid=\(routineUuid)")
            }
        }
        
        isCurrentWorkout = false // just to be sure
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uuid ?? UUID(), forKey: .uuid)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(comment, forKey: .comment)
        try container.encodeIfPresent(importSource, forKey: .importSource)
        try container.encodeIfPresent(healthExportState, forKey: .healthExportState)
        try container.encode(safeStart, forKey: .start)
        try container.encode(safeEnd, forKey: .end)
        try container.encodeIfPresent(workoutExercises?.array.compactMap { $0 as? WorkoutExercise }, forKey: .exercises)
        try container.encodeIfPresent(workoutRoutine?.uuid, forKey: .routineUuid)
        try container.encodeIfPresent(sessionEffortValue, forKey: .sessionEffort)
    }
}

// MARK: - Safe accessors
extension Workout {
    public var safeStart: Date {
        get {
            start ?? min(end ?? Date(), Date())
        }
        set {
            precondition(end == nil || newValue <= end!)
            start = newValue
        }
    }
    
    public var safeEnd: Date {
        get {
            end ?? max(start ?? Date(), Date())
        }
        set {
            precondition(start == nil || newValue >= start!)
            end = newValue
        }
    }
    
    public var safeDuration: TimeInterval {
        safeEnd.timeIntervalSince(safeStart)
    }
}

// MARK: - Prepare for finish
extension Workout {
    // exercises with no sets won't be deleted
    public func deleteExercisesWhereAllSetsAreUncompleted() {
        workoutExercises?
            .compactMap { $0 as? WorkoutExercise }
            .filter {
                guard let sets = $0.workoutSets?.compactMap({ $0 as? WorkoutSet }) else { return false }
                return !sets.isEmpty && !sets.contains { $0.isCompleted }
        }
        .forEach { workoutExercise in
            managedObjectContext?.delete(workoutExercise)
            workoutExercise.workout?.removeFromWorkoutExercises(workoutExercise)
        }
    }
    
    public func deleteUncompletedSets() {
        workoutExercises?
            .compactMap { $0 as? WorkoutExercise }
            .compactMap { $0.workoutSets?.compactMap { $0 as? WorkoutSet } }
            .flatMap { $0 }
            .filter { !$0.isCompleted }
            .forEach { workoutSet in
                managedObjectContext?.delete(workoutSet)
                workoutSet.workoutExercise?.removeFromWorkoutSets(workoutSet)
        }
    }
}

// MARK: - Workout Log
extension Workout {
    public func logText(in exercises: [Exercise], unit: UnitMass, formatter: MeasurementFormatter) -> String? {
        guard let start = start else { return nil }
        guard let weight = totalCompletedWeight else { return nil }
        let dateFormatter = DateFormatter() // we don't want relative formatting here
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short
        let dateString = "\(dateFormatter.string(from: start))"
        let durationString = duration.map { "Duration: \(Self.durationFormatter.string(from: $0)!)" }
        let weightString = "Total weight: \(formatter.string(from: Measurement(value: weight, unit: UnitMass.kilograms).converted(to: unit)))"
        
        guard let workoutExercises = workoutExercisesWhereNotAllSetsAreUncompleted else { return nil }
        let exercisesDescription = workoutExercises
            .map { workoutExercise -> String in
                let exerciseTitle = (workoutExercise.exercise(in: exercises)?.title ?? "Unknown Exercise")
                guard let workoutSets = workoutExercise.workoutSets else { return exerciseTitle }
                let setsDescription = workoutSets
                    .compactMap { $0 as? WorkoutSet }
                    .filter { $0.isCompleted }
                    .map { $0.logTitle(unit: unit, formatter: formatter) }
                    .joined(separator: "\n")
                guard !setsDescription.isEmpty else { return exerciseTitle }
                return exerciseTitle + "\n" + setsDescription
        }
        .joined(separator: "\n\n")
        return [dateString, durationString, weightString + "\n", exercisesDescription].compactMap { $0 }.joined(separator: "\n")
    }
    
    public var workoutExercisesWhereNotAllSetsAreUncompleted: [WorkoutExercise]? {
        workoutExercises?
            .compactMap { $0 as? WorkoutExercise }
            .filter {
                guard let sets = $0.workoutSets?.compactMap({ $0 as? WorkoutSet }) else { return false }
                return sets.isEmpty || sets.contains { $0.isCompleted }
        }
    }
}

// MARK: - Validation
extension Workout {
    override public func validateForUpdate() throws {
        try super.validateForUpdate()
        try validateConsistency()
    }
    
    override public func validateForInsert() throws {
        try super.validateForInsert()
        try validateConsistency()
    }
    
    /// TODO Subclasses should combine any error returned by super’s implementation with their own (see Managed Object Validation).
    /// https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreData/ObjectValidation.html
    func validateConsistency() throws {
        if start == nil {
            throw error(code: 1, message: "The start date is not set.")
        }
        
        if !isCurrentWorkout, end == nil {
            throw error(code: 2, message: "The end date is not set eventhough the workout is not the current workout.")
        }
        
        if let start = start, let end = end, start > end {
            throw error(code: 3, message: "The start date is greater than the end date.")
        }
        
        if isCurrentWorkout, let count = try? managedObjectContext?.count(for: Self.currentWorkoutFetchRequest), count > 1 {
            throw error(code: 4, message: "There is more than one current workout.")
        }

        if !isCurrentWorkout, let isCompleted = isCompleted, !isCompleted {
            throw error(code: 5, message: "The workout is not completed eventhough the workout is not the current workout.")
        }
    }
    
    private func error(code: Int, message: String) -> NSError {
        NSError(domain: "WORKOUT_ERROR_DOMAIN", code: code, userInfo: [NSLocalizedFailureReasonErrorKey: message, NSValidationObjectErrorKey: self])
    }
}
