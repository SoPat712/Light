//
//  IronBackup.swift
//  Iron
//
//  Created by Karim Abou Zeid on 26.10.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import Foundation
import CoreData
import WorkoutDataKit
import os.log

enum IronBackup {
    static let bodyMeasurementsStorageKey = "iron.bodyMeasurements.v1"
    private static let currentVersion = 6

    enum RestoreValidationError: LocalizedError {
        case unsupportedVersion(Int)
        case invalidBodyMeasurements
        case invalidTrackingPreferences
        case invalidExerciseNotes
        case invalidRoutineNoteLinks
        case duplicateIdentifier(UUID)
        case missingIdentifier
        case conflictingRetainedCustomExercise(UUID)

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                return "This backup version (\(version)) is not supported."
            case .invalidBodyMeasurements:
                return "The backup contains invalid body measurements."
            case .invalidTrackingPreferences:
                return "The backup contains invalid set tracking preferences."
            case .invalidExerciseNotes:
                return "The backup contains invalid exercise notes."
            case .invalidRoutineNoteLinks:
                return "The backup contains invalid saved-workout note links."
            case .duplicateIdentifier(let identifier):
                return "The backup contains the duplicate identifier \(identifier.uuidString)."
            case .missingIdentifier:
                return "The backup contains an object without an identifier."
            case .conflictingRetainedCustomExercise(let identifier):
                return "The backup defines custom exercise \(identifier.uuidString) differently from the active workout."
            }
        }
    }

    private struct IronBackup: Codable {
        /*
         Version History
         ===============
         
         Version 1: initial
         Version 2: workout UUIDs
         Version 3: workout plans, all entities have mandatory UUIDs
         Version 4: body measurements
         Version 5: set tracking types and saved-workout distance targets
         Version 6: exercise notes and saved-workout note links
         */
        var version: Int = 6 // var not let so it can be overwritten by decodable
        let date: Date
        let customExercises: [Exercise]
        let workoutPlans: [WorkoutPlan]
        let workouts: [Workout]
        /// Opaque JSON from the app-group measurement store. Keeping this as
        /// data lets the shared backup model remain independent of HealthKit.
        let bodyMeasurementsData: Data?
        let trackingPreferences: SetTrackingPreferences?
        let exerciseNotes: ExerciseNotes?
        let routineNoteLinks: WorkoutRoutineNoteLinks?
        
        // MARK: - Codable
        
        private enum CodingKeys: String, CodingKey {
            case version
            case date
            case customExercises
            case workoutPlans
            case workouts
            case bodyMeasurementsData
            case trackingPreferences
            case exerciseNotes
            case routineNoteLinks
        }
        
        init(
            date: Date,
            customExercises: [Exercise],
            workoutPlans: [WorkoutPlan],
            workouts: [Workout],
            bodyMeasurementsData: Data?,
            trackingPreferences: SetTrackingPreferences?,
            exerciseNotes: ExerciseNotes?,
            routineNoteLinks: WorkoutRoutineNoteLinks?
        ) {
            self.date = date
            self.customExercises = customExercises
            self.workoutPlans = workoutPlans
            self.workouts = workouts
            self.bodyMeasurementsData = bodyMeasurementsData
            self.trackingPreferences = trackingPreferences
            self.exerciseNotes = exerciseNotes
            self.routineNoteLinks = routineNoteLinks
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            date = try container.decode(Date.self, forKey: .date)
            customExercises = try container.decode([Exercise].self, forKey: .customExercises)
            workoutPlans = try container.decodeIfPresent([WorkoutPlan].self, forKey: .workoutPlans) ?? []
            // workout plans must be decoded before workouts
            workouts = try container.decode([Workout].self, forKey: .workouts)
            bodyMeasurementsData = try container.decodeIfPresent(Data.self, forKey: .bodyMeasurementsData)
            trackingPreferences = try container.decodeIfPresent(SetTrackingPreferences.self, forKey: .trackingPreferences)
            exerciseNotes = try container.decodeIfPresent(ExerciseNotes.self, forKey: .exerciseNotes)
            routineNoteLinks = try container.decodeIfPresent(WorkoutRoutineNoteLinks.self, forKey: .routineNoteLinks)
        }
        
//        public func encode(to encoder: Encoder) throws {
//            let container = encoder.container(keyedBy: CodingKeys.self)
//            try container.encode(version, forKey: .version)
//            try container.encode(date, forKey: .date)
//            try container.encode(customExercises, forKey: .customExercises)
//            try container.encode(workoutPlans, forKey: .workoutPlans)
//            try container.encode(workouts, forKey: .workouts)
//        }
    }
    
    static func createBackupData(
        managedObjectContext: NSManagedObjectContext,
        exerciseStore: ExerciseStore,
        userDefaults: UserDefaults = .appGroup,
        trackingDefaults: UserDefaults = .standard,
        notesDefaults: UserDefaults = .standard
    ) throws -> Data
    {
        let workoutRequest: NSFetchRequest<Workout> = Workout.fetchRequest()
        workoutRequest.predicate = NSPredicate(format: "\(#keyPath(Workout.isCurrentWorkout)) != %@", NSNumber(booleanLiteral: true))
        workoutRequest.sortDescriptors = [NSSortDescriptor(keyPath: \Workout.start, ascending: false)]
        let workouts = try managedObjectContext.fetch(workoutRequest)
        
        let workoutPlanRequest: NSFetchRequest<WorkoutPlan> = WorkoutPlan.fetchRequest()
        workoutPlanRequest.sortDescriptors = [NSSortDescriptor(keyPath: \WorkoutPlan.title, ascending: false)]
        let workoutPlans = try managedObjectContext.fetch(workoutPlanRequest)
        
        let backup = IronBackup(
            date: Date(),
            customExercises: exerciseStore.customExercises,
            workoutPlans: workoutPlans,
            workouts: workouts,
            bodyMeasurementsData: userDefaults.data(forKey: bodyMeasurementsStorageKey),
            trackingPreferences: SetTrackingPreferences.load(defaults: trackingDefaults),
            exerciseNotes: ExerciseNotes.load(defaults: notesDefaults),
            routineNoteLinks: WorkoutRoutineNoteLinks.load(defaults: notesDefaults)
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let exercisesKey = CodingUserInfoKey.exercisesKey {
            encoder.userInfo[exercisesKey] = exerciseStore.exercises
        }
        
        return try encoder.encode(backup)
    }
    
    static var restoringBackupData = false
    static func restoreBackupData(
        data: Data,
        managedObjectContext: NSManagedObjectContext,
        exerciseStore: ExerciseStore,
        userDefaults: UserDefaults = .appGroup,
        trackingDefaults: UserDefaults = .standard,
        notesDefaults: UserDefaults = .standard,
        saveParent: ((NSManagedObjectContext) throws -> Void)? = nil
    ) throws {
        let previousCustomExercises = exerciseStore.customExercises
        var changedCustomExercises = false
        var success = false
        defer {
            if !success {
                os_log("Restoring backup data was unsuccessful", log: .backup, type: .default)
                if changedCustomExercises {
                    do {
                        try exerciseStore.replaceCustomExercises(with: previousCustomExercises)
                    } catch {
                        os_log("Could not restore custom exercises after failed backup restore", log: .backup, type: .error)
                    }
                }
            }
            restoringBackupData = false
        }
        restoringBackupData = true
        
        // use a child context so we don't lose the current data if anything goes wrong
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.parent = managedObjectContext
        
        // delete all workouts (except for the current workout)
        os_log("Deleting all workouts", log: .backup, type: .default)
        let workoutRequest: NSFetchRequest<Workout> = Workout.fetchRequest()
        workoutRequest.predicate = NSPredicate(format: "\(#keyPath(Workout.isCurrentWorkout)) != %@", NSNumber(booleanLiteral: true))
        let workouts = try context.fetch(workoutRequest)
        for workout in workouts {
            context.delete(workout)
        }
        
        os_log("Deleting all workout plans", log: .backup, type: .default)
        let workoutPlanRequest: NSFetchRequest<WorkoutPlan> = WorkoutPlan.fetchRequest()
        let workoutPlans = try context.fetch(workoutPlanRequest)
        for workoutPlan in workoutPlans {
            context.delete(workoutPlan)
        }
        
        // try to restore the workouts
        os_log("Restoring workouts", log: .backup, type: .default)
        guard let managedObjectContextKey = CodingUserInfoKey.managedObjectContextKey else { throw "Managed object context key is nill" }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.userInfo[managedObjectContextKey] = context
        decoder.userInfo[.preserveWorkoutProvenance] = true
        let workoutDataBackup = try decoder.decode(IronBackup.self, from: data) // this already inserts the workout into the context
        try validate(workoutDataBackup)
        let customExercisesToRestore = try managedObjectContext.performAndWait {
            try validateNoCollisionWithCurrentWorkout(
                workoutDataBackup,
                in: managedObjectContext
            )
            return try reconciledCustomExercises(
                archived: workoutDataBackup.customExercises,
                retaining: previousCustomExercises,
                in: managedObjectContext
            )
        }

        let activeExerciseIDs = try managedObjectContext.performAndWait {
            Set(try managedObjectContext.fetch(Workout.currentWorkoutFetchRequest).flatMap { workout in
                (workout.workoutExercises?.array as? [WorkoutExercise] ?? []).compactMap { $0.exerciseUuid?.uuidString }
            })
        }

        // Persist custom exercises before the Core Data commit so any storage
        // failure leaves the parent untouched. The defer restores these if the
        // subsequent parent save fails.
        os_log("Restoring custom exercises", log: .backup, type: .default)
        try exerciseStore.replaceCustomExercises(with: customExercisesToRestore)
        changedCustomExercises = true

        // The child save is inside the parent's scoped undo transaction so a
        // failed durable save removes only this import from the parent.
        try managedObjectContext.performAndWait {
            try managedObjectContext.persistMutation(
                save: {
                    if let saveParent {
                        try saveParent(managedObjectContext)
                    } else if managedObjectContext.hasChanges {
                        try managedObjectContext.save()
                    }
                },
                mutation: { try context.save() }
            )
        }

        // Older backups intentionally preserve the user's current body data.
        // Version 4+ backups replace it with the data captured in the archive.
        if workoutDataBackup.version >= 4 {
            if let bodyMeasurementsData = workoutDataBackup.bodyMeasurementsData {
                userDefaults.set(bodyMeasurementsData, forKey: bodyMeasurementsStorageKey)
            } else {
                userDefaults.removeObject(forKey: bodyMeasurementsStorageKey)
            }
        }
        // Defaults are outside Core Data's undo transaction. Restore them only
        // after the parent save, and retain the active workout's measurement types.
        // Missing metadata in older archives leaves existing preferences intact.
        // Install plan-row links before notifications can trigger a sync snapshot.
        if let archived = workoutDataBackup.routineNoteLinks {
            WorkoutRoutineNoteLinks.load(defaults: notesDefaults).merging(archived).save(defaults: notesDefaults)
        }
        if let archived = workoutDataBackup.trackingPreferences {
            let stored = SetTrackingPreferences.load(defaults: trackingDefaults)
            var restored = stored
            let now = Date().timeIntervalSince1970
            for (key, value) in archived.overrides where !activeExerciseIDs.contains(key) {
                restored.overrides[key] = .init(type: value.type,
                    updatedAt: max(now, (stored.overrides[key]?.updatedAt ?? 0) + 0.001))
            }
            for (key, value) in archived.routineDistances {
                restored.routineDistances[key] = .init(meters: value.meters,
                    updatedAt: max(now, (stored.routineDistances[key]?.updatedAt ?? 0) + 0.001))
            }
            restored.save(defaults: trackingDefaults)
            if restored != stored {
                NotificationCenter.default.post(name: SetTrackingPreferences.didChangeNotification, object: trackingDefaults)
            }
        }
        if let archived = workoutDataBackup.exerciseNotes {
            let stored = ExerciseNotes.load(defaults: notesDefaults)
            var restored = stored
            let now = Date().timeIntervalSince1970
            for (key, value) in archived.entries {
                // Restoring is a new local edit. It must supersede both a newer
                // on-device note and the archive's old note on the other device.
                let previousTimestamp = max(value.updatedAt, stored.entries[key]?.updatedAt ?? 0)
                let nextTimestamp = previousTimestamp.nextUp
                restored.entries[key] = .init(text: value.text,
                    updatedAt: max(now, nextTimestamp.isFinite ? nextTimestamp : previousTimestamp))
            }
            restored.save(defaults: notesDefaults)
            if restored != stored {
                NotificationCenter.default.post(name: ExerciseNotes.didChangeNotification, object: notesDefaults)
            }
        }
        success = true
        os_log("Successfully restored backup data", log: .backup, type: .info)
    }

    private static func validate(_ backup: IronBackup) throws {
        guard (1...currentVersion).contains(backup.version) else {
            throw RestoreValidationError.unsupportedVersion(backup.version)
        }

        if let tracking = backup.trackingPreferences {
            guard SetTrackingPreferences(payload: tracking.dictionaryRepresentation) != nil,
                  tracking.overrides.keys.allSatisfy({ UUID(uuidString: $0) != nil }),
                  tracking.routineDistances.keys.allSatisfy({ UUID(uuidString: $0) != nil }) else {
                throw RestoreValidationError.invalidTrackingPreferences
            }
        }
        if let notes = backup.exerciseNotes, !notes.isValid {
            throw RestoreValidationError.invalidExerciseNotes
        }
        if let links = backup.routineNoteLinks, !links.isValid {
            throw RestoreValidationError.invalidRoutineNoteLinks
        }

        var identifiers = Set<UUID>()
        func register(_ identifier: UUID?) throws {
            guard let identifier else { throw RestoreValidationError.missingIdentifier }
            guard identifiers.insert(identifier).inserted else {
                throw RestoreValidationError.duplicateIdentifier(identifier)
            }
        }

        for exercise in backup.customExercises {
            try register(exercise.uuid)
        }
        for plan in backup.workoutPlans {
            try register(plan.uuid)
            let routines = plan.workoutRoutines?.array.compactMap { $0 as? WorkoutRoutine } ?? []
            for routine in routines {
                try register(routine.uuid)
                let exercises = routine.workoutRoutineExercises?.array
                    .compactMap { $0 as? WorkoutRoutineExercise } ?? []
                for exercise in exercises {
                    try register(exercise.uuid)
                    let sets = exercise.workoutRoutineSets?.array
                        .compactMap { $0 as? WorkoutRoutineSet } ?? []
                    for set in sets { try register(set.uuid) }
                }
            }
        }
        for workout in backup.workouts {
            try register(workout.uuid)
            let exercises = workout.workoutExercises?.array.compactMap { $0 as? WorkoutExercise } ?? []
            for exercise in exercises {
                try register(exercise.uuid)
                let sets = exercise.workoutSets?.array.compactMap { $0 as? WorkoutSet } ?? []
                for set in sets { try register(set.uuid) }
            }
        }

        if backup.version >= 4, let data = backup.bodyMeasurementsData {
            let measurementIDs = try validatedBodyMeasurementIDs(data)
            for identifier in measurementIDs { try register(identifier) }
        }
    }

    private static func validateNoCollisionWithCurrentWorkout(
        _ backup: IronBackup,
        in context: NSManagedObjectContext
    ) throws {
        let retainedWorkouts = try context.fetch(Workout.currentWorkoutFetchRequest)
        var retainedIdentifiers = Set<UUID>()
        for workout in retainedWorkouts {
            try appendWorkoutIdentifiers(from: workout, to: &retainedIdentifiers)
        }

        for workout in backup.workouts {
            var importedIdentifiers = Set<UUID>()
            try appendWorkoutIdentifiers(from: workout, to: &importedIdentifiers)
            if let collision = importedIdentifiers.first(where: retainedIdentifiers.contains) {
                throw RestoreValidationError.duplicateIdentifier(collision)
            }
        }
    }

    private static func reconciledCustomExercises(
        archived: [Exercise],
        retaining existingCustomExercises: [Exercise],
        in context: NSManagedObjectContext
    ) throws -> [Exercise] {
        let retainedWorkouts = try context.fetch(Workout.currentWorkoutFetchRequest)
        let referencedIdentifiers = Set(retainedWorkouts.flatMap { workout in
            (workout.workoutExercises?.array as? [WorkoutExercise] ?? [])
                .compactMap(\.exerciseUuid)
        })
        let retainedDefinitions = existingCustomExercises.filter {
            referencedIdentifiers.contains($0.uuid)
        }
        guard !retainedDefinitions.isEmpty else { return archived }

        var archivedByIdentifier = Dictionary(uniqueKeysWithValues: archived.map { ($0.uuid, $0) })
        var reconciled = archived
        for retained in retainedDefinitions {
            if let archivedDefinition = archivedByIdentifier[retained.uuid] {
                guard archivedDefinition == retained else {
                    throw RestoreValidationError.conflictingRetainedCustomExercise(retained.uuid)
                }
            } else {
                reconciled.append(retained)
                archivedByIdentifier[retained.uuid] = retained
            }
        }
        return reconciled
    }

    private static func appendWorkoutIdentifiers(
        from workout: Workout,
        to identifiers: inout Set<UUID>
    ) throws {
        guard let workoutID = workout.uuid else { throw RestoreValidationError.missingIdentifier }
        identifiers.insert(workoutID)
        let exercises = workout.workoutExercises?.array.compactMap { $0 as? WorkoutExercise } ?? []
        for exercise in exercises {
            guard let exerciseID = exercise.uuid else { throw RestoreValidationError.missingIdentifier }
            identifiers.insert(exerciseID)
            let sets = exercise.workoutSets?.array.compactMap { $0 as? WorkoutSet } ?? []
            for set in sets {
                guard let setID = set.uuid else { throw RestoreValidationError.missingIdentifier }
                identifiers.insert(setID)
            }
        }
    }

    private struct BodyMeasurementArchiveEntry: Decodable {
        let id: UUID
        let date: Date
        let values: [String: Double]
        let progressPhotoData: Data?
    }

    /// Validate the opaque app payload without introducing app-only model
    /// dependencies into the Shared target.
    private static func validatedBodyMeasurementIDs(_ data: Data) throws -> [UUID] {
        let entries: [BodyMeasurementArchiveEntry]
        do {
            entries = try JSONDecoder().decode([BodyMeasurementArchiveEntry].self, from: data)
        } catch {
            throw RestoreValidationError.invalidBodyMeasurements
        }
        return try entries.map { entry in
            guard entry.date.timeIntervalSinceReferenceDate.isFinite else {
                throw RestoreValidationError.invalidBodyMeasurements
            }
            for value in entry.values.values {
                guard value.isFinite, value > 0 else {
                    throw RestoreValidationError.invalidBodyMeasurements
                }
            }
            return entry.id
        }
    }
}
