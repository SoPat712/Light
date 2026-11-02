//
//  HealthManager.swift
//  Iron
//
//  Created by Karim Abou Zeid on 02.10.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import Foundation
import HealthKit
import WorkoutDataKit
import os.log

class HealthManager {
    static let shared = HealthManager()

    final class MutationCoordinator {
        typealias Mutation = (@escaping () -> Void) -> Void

        private let lock = NSLock()
        private var pending: [Mutation] = []
        private var isRunning = false

        func enqueue(_ mutation: @escaping Mutation) {
            lock.lock()
            pending.append(mutation)
            let next = takeNextIfIdleLocked()
            lock.unlock()
            if let next { run(next) }
        }

        private func takeNextIfIdleLocked() -> Mutation? {
            guard !isRunning, !pending.isEmpty else { return nil }
            isRunning = true
            return pending.removeFirst()
        }

        private func run(_ mutation: @escaping Mutation) {
            let finishLock = NSLock()
            var didFinish = false
            mutation { [weak self] in
                finishLock.lock()
                guard !didFinish else {
                    finishLock.unlock()
                    return
                }
                didFinish = true
                finishLock.unlock()
                self?.mutationFinished()
            }
        }

        private func mutationFinished() {
            lock.lock()
            isRunning = false
            let next = takeNextIfIdleLocked()
            lock.unlock()
            if let next { run(next) }
        }
    }
    
    let healthStore: HKHealthStore
    private let mutationCoordinator = MutationCoordinator()
    private let workoutWriter: WorkoutWriter?
    
    // The injected writer receives values, never managed objects or real HealthKit.
    init(workoutWriter: WorkoutWriter? = nil) {
        self.healthStore = HKHealthStore()
        self.workoutWriter = workoutWriter
    }
}

extension HealthManager {
    enum AccessState: Equatable {
        case unavailable
        case notDetermined
        case needsReview
        case ready
    }

    enum AuthorizationError: LocalizedError {
        case unavailable
        case denied

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Apple Health is not available on this device."
            case .denied:
                return "Light could not access Apple Health. You can review access in the Health app or iPhone Settings."
            }
        }
    }

    // completion is called on a background queue!
    private func requestPermissions(
        toShare typesToShare: Set<HKSampleType>?,
        read typesToRead: Set<HKObjectType>?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        os_log("Requesting HealthKit permissions share=%@ read=%@", log: .health, type: .default, typesToShare ?? [], typesToRead ?? [])
        
        guard HKHealthStore.isHealthDataAvailable() else {
            os_log("HealthKit is not available on this device", log: .health, type: .error)
            completion(.failure(AuthorizationError.unavailable))
            return
        }

        #if DEBUG
        // Simulator screenshot runs can't pre-grant Health; skip the system sheet.
        if ProcessInfo.processInfo.arguments.contains("-ironSkipHealthAuthorization") {
            completion(.failure(AuthorizationError.denied))
            return
        }
        #endif

        healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead) { (success, error) in
            guard success else {
                os_log("Could not request health authorization: %@", log: .health, type: .fault, error?.localizedDescription ?? "nil")
                completion(.failure(error ?? AuthorizationError.denied))
                return
            }
            completion(.success(()))
            if typesToShare?.contains(HKObjectType.workoutType()) == true,
               self.healthStore.authorizationStatus(for: .workoutType()) == .sharingAuthorized {
                DispatchQueue.main.async { self.retryPendingWorkouts() }
            }
        }
    }
    
    // completion is called on a background queue!
    func requestReadBodyWeightPermission(completion: @escaping (Result<Void, Error>) -> Void) {
        let read = Set([
            HKObjectType.quantityType(forIdentifier: .bodyMass)
        ].compactMap { $0 })
        requestPermissions(toShare: nil, read: read, completion: completion)
    }

    /// Requests the body-composition types Iron can exchange with Apple Health.  Limb and
    /// chest circumferences remain local because HealthKit has no matching quantity types.
    func requestBodyMeasurementPermission(completion: @escaping (Result<Void, Error>) -> Void) {
        let identifiers: [HKQuantityTypeIdentifier] = [.bodyMass, .height, .bodyFatPercentage, .waistCircumference]
        let quantityTypes = identifiers.compactMap { HKObjectType.quantityType(forIdentifier: $0) }
        requestPermissions(
            toShare: Set<HKSampleType>(quantityTypes),
            read: Set<HKObjectType>(quantityTypes),
            completion: completion
        )
    }
    
    // completion is called on a background queue!
    func requestShareWorkoutPermission(completion: @escaping (Result<Void, Error>) -> Void) {
        let workoutType = HKObjectType.workoutType()
        if healthStore.authorizationStatus(for: workoutType) == .sharingAuthorized {
            completion(.success(()))
            return
        }
        requestPermissions(toShare: [workoutType], read: [workoutType], completion: completion)
    }

    /// Requests every category Iron currently exchanges with Apple Health in a
    /// single, intentional setup step. HealthKit does not reveal read access,
    /// so the connection state below reflects the categories Iron can write.
    func requestWorkoutAndBodyMeasurementPermission(
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let workoutType = HKObjectType.workoutType()
        let quantityTypes = bodyMeasurementTypes
        let shareTypes: [HKSampleType] = [workoutType] + quantityTypes.map { $0 as HKSampleType }
        let readTypes: [HKObjectType] = [workoutType] + quantityTypes.map { $0 as HKObjectType }
        requestPermissions(
            toShare: Set(shareTypes),
            read: Set(readTypes),
            completion: completion
        )
    }

    var accessState: AccessState {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }

        let shareTypes: [HKSampleType] = [HKObjectType.workoutType()]
            + bodyMeasurementTypes.map { $0 as HKSampleType }
        let statuses = shareTypes.map(healthStore.authorizationStatus(for:))
        if statuses.allSatisfy({ $0 == .notDetermined }) {
            return .notDetermined
        }
        if statuses.allSatisfy({ $0 == .sharingAuthorized }) {
            return .ready
        }
        return .needsReview
    }

    private var bodyMeasurementTypes: [HKQuantityType] {
        let identifiers: [HKQuantityTypeIdentifier] = [
            .bodyMass,
            .height,
            .bodyFatPercentage,
            .waistCircumference
        ]
        return identifiers.compactMap { HKObjectType.quantityType(forIdentifier: $0) }
    }
}

extension HealthManager {
    struct ExistingSampleReconciliation<Sample> {
        let reusable: Sample?
        let surplus: [Sample]
    }

    static func reconcileExistingSamples<Sample>(
        _ samples: [Sample],
        matches: (Sample) -> Bool,
        stableID: (Sample) -> UUID
    ) -> ExistingSampleReconciliation<Sample> {
        let reusable = samples
            .filter(matches)
            .min { stableID($0).uuidString < stableID($1).uuidString }
        guard let reusable else {
            return ExistingSampleReconciliation(reusable: nil, surplus: samples)
        }
        let reusableID = stableID(reusable)
        return ExistingSampleReconciliation(
            reusable: reusable,
            surplus: samples.filter { stableID($0) != reusableID }
        )
    }

    /// Returns false only when the caller still needs to create a replacement.
    /// A reusable matching sample is retained while exact surplus objects are
    /// deleted through the same error-reporting path as other removals.
    @discardableResult
    static func completeUsingReusableSample<Sample>(
        _ reconciliation: ExistingSampleReconciliation<Sample>,
        delete: @escaping ([Sample], @escaping (Result<Void, Error>) -> Void) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) -> Bool {
        guard reconciliation.reusable != nil else { return false }
        coordinateReplacement(
            oldObjects: reconciliation.surplus,
            replacements: [Sample](),
            intent: .delete,
            save: { _, _ in assertionFailure("Delete-only reconciliation must not save") },
            delete: delete,
            completion: completion
        )
        return true
    }

    enum ReplacementIntent {
        case replace
        case delete
    }

    /// Save immutable replacements before deleting the exact old objects
    /// returned by the preceding query. Empty replacements are safe no-ops
    /// unless the caller explicitly requests deletion.
    static func coordinateReplacement<Old, New>(
        oldObjects: [Old],
        replacements: [New],
        intent: ReplacementIntent,
        save: @escaping ([New], @escaping (Result<Void, Error>) -> Void) -> Void,
        delete: @escaping ([Old], @escaping (Result<Void, Error>) -> Void) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        func deleteOldObjects() {
            guard !oldObjects.isEmpty else {
                completion(.success(()))
                return
            }
            delete(oldObjects, completion)
        }

        switch intent {
        case .delete:
            deleteOldObjects()
        case .replace:
            guard !replacements.isEmpty else {
                completion(.success(()))
                return
            }
            save(replacements) { result in
                switch result {
                case .success:
                    deleteOldObjects()
                case .failure:
                    completion(result)
                }
            }
        }
    }

    static func replacementMetadata(
        copying priorMetadata: [String: Any]?,
        externalUUID: String,
        title: String?
    ) -> [String: Any] {
        var metadata = priorMetadata ?? [:]
        // This is a new independent sample, not a HealthKit sync-version update.
        // Reusing the old sync identity/version can cause HealthKit to ignore it.
        metadata.removeValue(forKey: HKMetadataKeySyncIdentifier)
        metadata.removeValue(forKey: HKMetadataKeySyncVersion)
        metadata[HKMetadataKeyExternalUUID] = externalUUID
        if let title {
            metadata[HKMetadataKeyWorkoutBrandName] = title
        } else {
            metadata.removeValue(forKey: HKMetadataKeyWorkoutBrandName)
        }
        return metadata
    }

    static func isValidWorkoutInterval(start: Date, end: Date, duration: TimeInterval) -> Bool {
        Workout.healthExportEligibility(importSource: nil, isCurrent: false,
                                        start: start, end: end, duration: duration) == .eligible
    }

    static func workoutFieldsMatch(
        existingStart: Date,
        existingEnd: Date,
        existingDuration: TimeInterval,
        existingTitle: String?,
        desiredStart: Date,
        desiredEnd: Date,
        desiredDuration: TimeInterval,
        desiredTitle: String?
    ) -> Bool {
        abs(existingStart.timeIntervalSince(desiredStart)) < 1
            && abs(existingEnd.timeIntervalSince(desiredEnd)) < 1
            && abs(existingDuration - desiredDuration) < 1
            && existingTitle == desiredTitle
    }

    enum WorkoutSyncOutcome {
        case saved
        case updated
        case alreadyPresent
    }

    enum WorkoutSyncError: LocalizedError, Equatable {
        case missingWorkoutData
        case importedWorkout

        var errorDescription: String? {
            switch self {
            case .missingWorkoutData:
                return "The workout is missing the information Apple Health needs."
            case .importedWorkout:
                return "Imported workouts are never sent to Apple Health."
            }
        }
    }

    static func workoutExportError(_ eligibility: Workout.HealthExportEligibility) -> WorkoutSyncError? {
        switch eligibility {
        case .eligible: return nil
        case .imported: return .importedWorkout
        case .invalidWorkout: return .missingWorkoutData
        }
    }

    struct WorkoutExportRequest {
        let uuid: UUID
        let start: Date
        let end: Date
        let duration: TimeInterval
        let title: String?
    }

    typealias WorkoutWriter = (WorkoutExportRequest, @escaping (Result<WorkoutSyncOutcome, Error>) -> Void) -> Void

    /// A matching external UUID already saved by Watch (or another source)
    /// belongs to that session. The phone must neither copy nor replace it.
    static func canReconcileWorkoutSamples<Sample>(
        _ samples: [Sample],
        isPhoneOwned: (Sample) -> Bool
    ) -> Bool {
        samples.allSatisfy(isPhoneOwned)
    }

    var workoutConfiguration: HKWorkoutConfiguration {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        return configuration
    }
    
    func saveWorkout(workout: Workout, exerciseStore: ExerciseStore) {
        syncWorkoutIfNeeded(workout: workout, exerciseStore: exerciseStore) { result in
            if case .failure(let error) = result {
                os_log("Could not save Apple Health workout: %@", log: .health, type: .error, error.localizedDescription)
            }
        }
    }

    /// Adds a completed workout to Apple Health only when a sample with Iron's
    /// stable workout identifier is not already present. This makes the detail
    /// screen's Sync action safe to retry.
    func syncWorkoutIfNeeded(
        workout: Workout,
        exerciseStore: ExerciseStore,
        completion: @escaping (Result<WorkoutSyncOutcome, Error>) -> Void
    ) {
        let context = workout.managedObjectContext
        let workoutID = workout.objectID
        mutationCoordinator.enqueue { finish in
            guard let context else {
                finish()
                DispatchQueue.main.async {
                    completion(.failure(WorkoutSyncError.missingWorkoutData))
                }
                return
            }
            self.performSyncWorkoutIfNeeded(
                workoutID: workoutID,
                context: context,
                exerciseStore: exerciseStore
            ) { result in
                finish()
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    private func performSyncWorkoutIfNeeded(
        workoutID: NSManagedObjectID,
        context: NSManagedObjectContext,
        exerciseStore: ExerciseStore,
        pendingOnly: Bool = false,
        completion: @escaping (Result<WorkoutSyncOutcome, Error>) -> Void
    ) {
        context.perform {
            guard let workout = (try? context.existingObject(with: workoutID)) as? Workout,
                  !workout.isDeleted else {
                completion(.failure(WorkoutSyncError.missingWorkoutData))
                return
            }
            if pendingOnly && workout.healthExportState != "pending" {
                completion(.success(.alreadyPresent))
                return
            }
            // Imports must fail before even requesting Health authorization.
            if let error = Self.workoutExportError(workout.healthExportEligibility) {
                completion(.failure(error))
                return
            }
            // A test completion is permanently excluded, even after switching
            // modes/builds. The debug preference also pauses manual/backfill sync.
            guard workout.healthExportState != "test", !SettingsStore.shared.healthTestMode else {
                completion(.success(.alreadyPresent))
                return
            }
            guard !workoutID.isTemporaryID,
                  let uuid = workout.uuid, let start = workout.start,
                  let end = workout.end, let duration = workout.duration else {
                completion(.failure(WorkoutSyncError.missingWorkoutData))
                return
            }
            // A Watch finish owns its Health sample even before it reaches the phone.
            guard workout.healthExportState != "watch" else {
                completion(.success(.alreadyPresent))
                return
            }
            do {
                try self.persistHealthExportState("pending", for: workout, in: context)
            } catch {
                completion(.failure(error))
                return
            }
            let request = WorkoutExportRequest(uuid: uuid, start: start, end: end,
                                               duration: duration,
                                               title: workout.optionalDisplayTitle(in: exerciseStore.exercises))
            let writer = self.workoutWriter ?? self.writeWorkoutToHealth
            writer(request) { result in
                context.perform {
                    do {
                        if case .success = result, !workout.isDeleted,
                           workout.healthExportEligibility == .eligible,
                           workout.healthExportState != "watch", workout.healthExportState != "test",
                           !SettingsStore.shared.healthTestMode {
                            try self.persistHealthExportState("exported", for: workout, in: context)
                        }
                        completion(result)
                    } catch {
                        // Health may have saved: pending reconciliation safely reuses its UUID.
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    /// Save just the state in a sibling context, without committing editor changes.
    /// Merge on the caller's queue so the native List observes the durable result.
    private func persistHealthExportState(_ state: String, for workout: Workout,
                                          in context: NSManagedObjectContext) throws {
        guard workout.healthExportState != state else { return }
        guard let coordinator = context.persistentStoreCoordinator else {
            throw WorkoutSyncError.missingWorkoutData
        }
        let stateContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        stateContext.persistentStoreCoordinator = coordinator
        let workoutID = workout.objectID
        var savedNotification: Notification?
        let observer = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave, object: stateContext, queue: nil
        ) { savedNotification = $0 }
        defer { NotificationCenter.default.removeObserver(observer) }
        try stateContext.performAndWait {
            guard let stored = try stateContext.existingObject(with: workoutID) as? Workout,
                  stored.healthExportEligibility == .eligible,
                  stored.healthExportState != "watch", stored.healthExportState != "test" else {
                throw WorkoutSyncError.missingWorkoutData
            }
            stored.healthExportState = state
            try stateContext.save()
        }
        if let savedNotification { context.mergeChanges(fromContextDidSave: savedNotification) }
    }

    private func writeWorkoutToHealth(_ request: WorkoutExportRequest,
                                      completion: @escaping (Result<WorkoutSyncOutcome, Error>) -> Void) {
        let uuid = request.uuid
        let start = request.start
        let end = request.end
        let duration = request.duration
        let workoutTitle = request.title
        self.requestShareWorkoutPermission { authorization in
            guard case .success = authorization else {
                if case .failure(let error) = authorization {
                    completion(.failure(error))
                }
                return
            }

            var metadata: [String : Any] = [HKMetadataKeyExternalUUID : uuid.uuidString]
            if let workoutTitle {
                metadata[HKMetadataKeyWorkoutBrandName] = workoutTitle
            }
            let uuidPredicate = HKQuery.predicateForObjects(
                withMetadataKey: HKMetadataKeyExternalUUID,
                allowedValues: [uuid.uuidString]
            )
            // Read all sources for this Iron UUID so a Watch-owned sample
            // prevents a second phone export. Only phone samples may mutate.
            let query = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: uuidPredicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                guard !SettingsStore.shared.healthTestMode else {
                    completion(.success(.alreadyPresent))
                    return
                }
                if let error {
                    completion(.failure(error))
                    return
                }

                let existingSamples = (samples as? [HKWorkout]) ?? []
                guard Self.canReconcileWorkoutSamples(existingSamples, isPhoneOwned: {
                    $0.sourceRevision.source == HKSource.default()
                }) else {
                    completion(.success(.alreadyPresent))
                    return
                }
                let reconciliation = Self.reconcileExistingSamples(
                    existingSamples,
                    matches: {
                        self.healthWorkout(
                            $0,
                            matchesStart: start,
                            end: end,
                            duration: duration,
                            title: workoutTitle
                        )
                    },
                    stableID: { $0.uuid }
                )
                let reusedOutcome: WorkoutSyncOutcome = reconciliation.surplus.isEmpty
                    ? .alreadyPresent
                    : .updated
                if Self.completeUsingReusableSample(
                    reconciliation,
                    delete: { surplus, deleted in
                        self.healthStore.delete(surplus) { success, error in
                            deleted(success
                                ? .success(())
                                : .failure(error ?? AuthorizationError.denied))
                        }
                    },
                    completion: { result in
                        completion(result.map { reusedOutcome })
                    }
                ) {
                    return
                }

                let prior = existingSamples.first
                let replacementMetadata = Self.replacementMetadata(
                    copying: prior?.metadata ?? metadata,
                    externalUUID: uuid.uuidString,
                    title: workoutTitle
                )
                let reconciledWorkout = HKWorkout(
                    activityType: self.workoutConfiguration.activityType,
                    start: start,
                    end: end,
                    duration: duration,
                    totalEnergyBurned: prior?.totalEnergyBurned,
                    totalDistance: prior?.totalDistance,
                    device: prior?.device ?? .local(),
                    metadata: replacementMetadata
                )
                let outcome: WorkoutSyncOutcome = existingSamples.isEmpty ? .saved : .updated
                Self.coordinateReplacement(
                    oldObjects: existingSamples,
                    replacements: [reconciledWorkout],
                    intent: .replace,
                    save: { replacements, saved in
                        guard !SettingsStore.shared.healthTestMode else {
                            saved(.failure(GenericError(description: "Apple Health recording is off in test mode.")))
                            return
                        }
                        self.healthStore.save(replacements) { success, error in
                            saved(success
                                ? .success(())
                                : .failure(error ?? AuthorizationError.denied))
                        }
                    },
                    delete: { oldObjects, deleted in
                        self.healthStore.delete(oldObjects) { success, error in
                            deleted(success
                                ? .success(())
                                : .failure(error ?? AuthorizationError.denied))
                        }
                    },
                    completion: { result in
                        completion(result.map { outcome })
                    }
                )
            }
            self.healthStore.execute(query)
        }
    }

    private func healthWorkout(
        _ sample: HKWorkout,
        matchesStart start: Date,
        end: Date,
        duration: TimeInterval,
        title: String?
    ) -> Bool {
        let sampleTitle = sample.metadata?[HKMetadataKeyWorkoutBrandName] as? String
        return sample.workoutActivityType == workoutConfiguration.activityType
            && Self.workoutFieldsMatch(
                existingStart: sample.startDate,
                existingEnd: sample.endDate,
                existingDuration: sample.duration,
                existingTitle: sampleTitle,
                desiredStart: start,
                desiredEnd: end,
                desiredDuration: duration,
                desiredTitle: title
            )
    }
    
    func deleteWorkout(workout: Workout) {
        guard let uuid = workout.uuid else { return }
        deleteWorkout(uuid: uuid, eligibility: workout.healthExportEligibility)
    }

    /// Value-only deletion entry point for callers that have already durably
    /// removed the Core Data workout.
    func deleteWorkout(uuid: UUID, eligibility: Workout.HealthExportEligibility) {
        // The caller captures provenance before deleting the managed object.
        guard eligibility == .eligible else { return }
        mutationCoordinator.enqueue { finish in
            self.performDeleteWorkout(uuid: uuid, completion: finish)
        }
    }

    private func performDeleteWorkout(uuid: UUID, completion: @escaping () -> Void) {
        let uuidPredicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: [uuid.uuidString])
        let sourcePredicate = HKQuery.predicateForObjects(from: .default())
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [uuidPredicate, sourcePredicate])
        
        os_log("Deleting HealthKit workout with uuid=%@", log: .health, uuid as NSUUID)
        let query = HKSampleQuery(
            sampleType: .workoutType(),
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: nil) { (query, samples, error) in
                if let error = error {
                    os_log("Could not query HealthKit workout with uuid=%@: %@", log: .health, type: .fault, uuid as NSUUID, error.localizedDescription)
                    completion()
                    return
                }
                let workoutSamples = (samples as? [HKWorkout]) ?? []
                guard !workoutSamples.isEmpty else {
                    os_log("No HealthKit workout with uuid=%@", log: .health, type: .fault, uuid as NSUUID)
                    completion()
                    return
                }
                
                self.healthStore.delete(workoutSamples) { success, error in
                    guard success else {
                        os_log("Could not delete HealthKit workout with uuid=%@: %@", log: .health, type: .fault, uuid as NSUUID, error?.localizedDescription ?? "nil")
                        completion()
                        return
                    }
                    os_log("Successfully deleted HealthKit workout with uuid=%@", log: .health, type: .info, uuid as NSUUID)
                    completion()
                }
        }
        healthStore.execute(query)
    }

    /// Reconciles the HealthKit samples owned by this local measurement entry.
    /// Each supported field receives its own stable external identifier so edits
    /// replace Iron's prior value instead of appending another Health sample.
    func saveBodyMeasurements(_ entry: BodyMeasurementEntry) {
        reconcileBodyMeasurements(entry, shouldSaveCurrentValues: true)
    }

    /// Removes only HealthKit samples previously exported for this Iron entry.
    /// HealthKit additionally limits deletion to objects saved by this app.
    func deleteBodyMeasurements(_ entry: BodyMeasurementEntry) {
        reconcileBodyMeasurements(entry, shouldSaveCurrentValues: false)
    }

    private struct BodyReplacementPlan {
        let identifier: HKQuantityTypeIdentifier
        let type: HKQuantityType
        let externalIdentifier: String
        let replacement: HKQuantitySample?
        let intent: ReplacementIntent
    }

    private func reconcileBodyMeasurements(
        _ entry: BodyMeasurementEntry,
        shouldSaveCurrentValues: Bool
    ) {
        mutationCoordinator.enqueue { finish in
            self.performReconcileBodyMeasurements(
                entry,
                shouldSaveCurrentValues: shouldSaveCurrentValues,
                completion: finish
            )
        }
    }

    private func performReconcileBodyMeasurements(
        _ entry: BodyMeasurementEntry,
        shouldSaveCurrentValues: Bool,
        completion: @escaping () -> Void
    ) {
        requestBodyMeasurementPermission { authorization in
            guard case .success = authorization else {
                if case .failure(let error) = authorization {
                    os_log("Could not authorize body measurement sync: %@", log: .health, type: .error, error.localizedDescription)
                }
                completion()
                return
            }

            let supportedValues: [(HKQuantityTypeIdentifier, Double?, HKUnit)] = [
                (.bodyMass, entry[.bodyWeight], .gramUnit(with: .kilo)),
                (.height, entry[.height].map { $0 / 100 }, .meter()),
                (.bodyFatPercentage, entry[.bodyFat].map { $0 / 100 }, .percent()),
                (.waistCircumference, entry[.waist].map { $0 / 100 }, .meter())
            ]
            let plans: [BodyReplacementPlan] = supportedValues.compactMap { identifier, value, unit in
                guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
                let externalIdentifier = self.bodyMeasurementExternalIdentifier(
                    entryID: entry.id,
                    quantityIdentifier: identifier
                )
                if !shouldSaveCurrentValues || value == nil {
                    return BodyReplacementPlan(
                        identifier: identifier,
                        type: type,
                        externalIdentifier: externalIdentifier,
                        replacement: nil,
                        intent: .delete
                    )
                }
                guard let replacement = self.bodySample(
                    identifier: identifier,
                    value: value,
                    unit: unit,
                    date: entry.date,
                    externalIdentifier: externalIdentifier
                ) else {
                    // A present but invalid value is a construction failure,
                    // not an instruction to erase the previous Health sample.
                    return nil
                }
                return BodyReplacementPlan(
                    identifier: identifier,
                    type: type,
                    externalIdentifier: externalIdentifier,
                    replacement: replacement,
                    intent: .replace
                )
            }

            let queryGroup = DispatchGroup()
            let resultLock = NSLock()
            var oldSamplesByIdentifier: [String: [HKQuantitySample]] = [:]
            var queryError: Error?

            for plan in plans {
                let identifierPredicate = HKQuery.predicateForObjects(
                    withMetadataKey: HKMetadataKeyExternalUUID,
                    allowedValues: [plan.externalIdentifier]
                )
                let sourcePredicate = HKQuery.predicateForObjects(from: .default())
                let predicate = NSCompoundPredicate(
                    andPredicateWithSubpredicates: [identifierPredicate, sourcePredicate]
                )
                queryGroup.enter()
                let query = HKSampleQuery(
                    sampleType: plan.type,
                    predicate: predicate,
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: nil
                ) { _, samples, error in
                    resultLock.lock()
                    if let error {
                        if queryError == nil { queryError = error }
                    } else {
                        oldSamplesByIdentifier[plan.externalIdentifier] =
                            (samples as? [HKQuantitySample]) ?? []
                    }
                    resultLock.unlock()
                    queryGroup.leave()
                }
                self.healthStore.execute(query)
            }

            queryGroup.notify(queue: .global(qos: .utility)) {
                resultLock.lock()
                let capturedError = queryError
                let capturedOldSamples = oldSamplesByIdentifier
                resultLock.unlock()

                guard capturedError == nil else {
                    os_log(
                        "Could not query prior Light body measurements in HealthKit: %@",
                        log: .health,
                        type: .error,
                        capturedError?.localizedDescription ?? "unknown error"
                    )
                    completion()
                    return
                }

                let replacementGroup = DispatchGroup()
                for plan in plans {
                    replacementGroup.enter()
                    Self.coordinateReplacement(
                        oldObjects: capturedOldSamples[plan.externalIdentifier] ?? [],
                        replacements: plan.replacement.map { [$0] } ?? [],
                        intent: plan.intent,
                        save: { replacements, saved in
                            self.healthStore.save(replacements) { success, error in
                                saved(success
                                    ? .success(())
                                    : .failure(error ?? AuthorizationError.denied))
                            }
                        },
                        delete: { oldObjects, deleted in
                            self.healthStore.delete(oldObjects) { success, error in
                                deleted(success
                                    ? .success(())
                                    : .failure(error ?? AuthorizationError.denied))
                            }
                        },
                        completion: { result in
                            if case .failure(let error) = result {
                                os_log(
                                    "Could not reconcile Light body measurement %@ in HealthKit: %@",
                                    log: .health,
                                    type: .error,
                                    plan.identifier.rawValue,
                                    error.localizedDescription
                                )
                            }
                            replacementGroup.leave()
                        }
                    )
                }
                replacementGroup.notify(queue: .global(qos: .utility)) {
                    if plans.isEmpty {
                        os_log(
                            "No supported body measurement values to reconcile",
                            log: .health,
                            type: .info
                        )
                    }
                    completion()
                }
            }
        }
    }

    private func bodyMeasurementExternalIdentifier(
        entryID: UUID,
        quantityIdentifier: HKQuantityTypeIdentifier
    ) -> String {
        "com.joshpatra.iron.body-measurement.\(entryID.uuidString).\(quantityIdentifier.rawValue)"
    }

    private func bodySample(
        identifier: HKQuantityTypeIdentifier,
        value: Double?,
        unit: HKUnit,
        date: Date,
        externalIdentifier: String
    ) -> HKQuantitySample? {
        guard let value = value,
              value.isFinite,
              value > 0,
              date.timeIntervalSinceReferenceDate.isFinite,
              let type = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
        let metadata: [String: Any] = [
            HKMetadataKeyWasUserEntered: true,
            HKMetadataKeyExternalUUID: externalIdentifier
        ]
        return HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: value), start: date, end: date, metadata: metadata)
    }

    struct BodyMeasurementRead {
        let values: [BodyMeasurementKind: Double]
        let date: Date?
    }

    func fetchLatestBodyMeasurements(completion: @escaping (Result<BodyMeasurementRead, Error>) -> Void) {
        requestBodyMeasurementPermission { authorization in
            guard case .success = authorization else {
                if case .failure(let error) = authorization {
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
                return
            }
            let requested: [(BodyMeasurementKind, HKQuantityTypeIdentifier, HKUnit, Double)] = [
                (.bodyWeight, .bodyMass, .gramUnit(with: .kilo), 1),
                (.height, .height, .meter(), 100),
                (.bodyFat, .bodyFatPercentage, .percent(), 100),
                (.waist, .waistCircumference, .meter(), 100)
            ]
            let group = DispatchGroup()
            let lock = NSLock()
            var values: [BodyMeasurementKind: Double] = [:]
            var newestDate: Date?
            var firstError: Error?

            for (kind, identifier, unit, multiplier) in requested {
                guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { continue }
                group.enter()
                let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
                let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, error in
                    defer { group.leave() }
                    if let error {
                        lock.lock()
                        if firstError == nil { firstError = error }
                        lock.unlock()
                        return
                    }
                    guard let sample = samples?.first as? HKQuantitySample else { return }
                    lock.lock()
                    values[kind] = sample.quantity.doubleValue(for: unit) * multiplier
                    newestDate = max(newestDate ?? sample.endDate, sample.endDate)
                    lock.unlock()
                }
                self.healthStore.execute(query)
            }

            group.notify(queue: .main) {
                if values.isEmpty, let firstError {
                    completion(.failure(firstError))
                } else {
                    completion(.success(BodyMeasurementRead(values: values, date: newestDate)))
                }
            }
        }
    }
}

import CoreData
extension HealthManager {
    enum UpdateError: Error {
        case noSuccess
        case noHKWorkouts
    }
    
    struct WorkoutUpdates {
        let created: Int
        let deleted: Int
        let modified: Int
    }
    
    func updateHealthWorkouts(managedObjectContext: NSManagedObjectContext, exerciseStore: ExerciseStore,
                              completion: @escaping (Result<WorkoutUpdates, Error>) -> Void) {
        enqueueExportPass(in: managedObjectContext, exerciseStore: exerciseStore,
                          pendingOnly: false, completion: completion)
    }

    /// Foreground/unlock/authorization retries only durable, explicitly requested exports.
    func retryPendingWorkouts(
        in context: NSManagedObjectContext = WorkoutDataStorage.shared.persistentContainer.viewContext,
        exerciseStore: ExerciseStore = .shared,
        completion: @escaping (Result<WorkoutUpdates, Error>) -> Void = { _ in }
    ) {
        // Re-fetch when this pass reaches the coordinator. Repeated triggers
        // skip exported rows, while an unlock arriving during a failure is retained.
        enqueueExportPass(in: context, exerciseStore: exerciseStore,
                          pendingOnly: true, completion: completion)
    }

    private func enqueueExportPass(in context: NSManagedObjectContext, exerciseStore: ExerciseStore,
                                   pendingOnly: Bool,
                                   completion: @escaping (Result<WorkoutUpdates, Error>) -> Void) {
        mutationCoordinator.enqueue { finish in
            context.perform {
                do {
                    let request: NSFetchRequest<Workout> = Workout.fetchRequest()
                    if pendingOnly { request.predicate = NSPredicate(format: "healthExportState == %@", "pending") }
                    let ids = try context.fetch(request).filter {
                        $0.healthExportEligibility == .eligible && $0.healthExportState != "watch"
                            && $0.healthExportState != "test" && !SettingsStore.shared.healthTestMode
                    }.map(\.objectID)
                    var created = 0
                    var modified = 0
                    var firstError: Error?
                    func next(_ index: Int) {
                        guard index < ids.count else {
                            // Without a local eligible workout, ownership/provenance cannot
                            // be established. Bulk sync must never delete orphan Health data.
                            let result: Result<WorkoutUpdates, Error> = firstError.map { .failure($0) }
                                ?? .success(WorkoutUpdates(created: created, deleted: 0, modified: modified))
                            finish()
                            DispatchQueue.main.async { completion(result) }
                            return
                        }
                        self.performSyncWorkoutIfNeeded(workoutID: ids[index], context: context,
                                                        exerciseStore: exerciseStore,
                                                        pendingOnly: pendingOnly) { result in
                            switch result {
                            case .success(.saved): created += 1
                            case .success(.updated): modified += 1
                            case .success(.alreadyPresent): break
                            case .failure(let error): if firstError == nil { firstError = error }
                            }
                            next(index + 1)
                        }
                    }
                    next(0)
                } catch {
                    finish()
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        }
    }
}

extension HKWorkout {
    var externalUuid: UUID? {
        guard let externalUuidString = metadata?[HKMetadataKeyExternalUUID] as? String else { return nil }
        return UUID(uuidString: externalUuidString)
    }
}

// MARK: - Workout vitals

extension HealthManager {
    /// Heart rate and active energy recorded in Apple Health during a workout's
    /// time window. Read-only: Light never writes these samples from the iPhone.
    struct WorkoutVitals: Equatable {
        struct HeartRatePoint: Equatable {
            let date: Date
            let bpm: Double
        }

        var heartRate: [HeartRatePoint]
        var activeEnergyKilocalories: Double?

        var isEmpty: Bool { heartRate.isEmpty && activeEnergyKilocalories == nil }
    }

    private var vitalsReadTypes: Set<HKObjectType> {
        Set([
            HKQuantityType.quantityType(forIdentifier: .heartRate),
            HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)
        ].compactMap { $0 })
    }

    /// HealthKit never reveals whether read access was granted; this only says
    /// whether the permission prompt has yet to be shown.
    // completion is called on a background queue!
    func needsVitalsReadRequest(completion: @escaping (Bool) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(false)
            return
        }
        healthStore.getRequestStatusForAuthorization(toShare: [], read: vitalsReadTypes) { status, _ in
            completion(status == .shouldRequest)
        }
    }

    // completion is called on a background queue!
    func requestVitalsReadPermission(completion: @escaping (Result<Void, Error>) -> Void) {
        requestPermissions(toShare: nil, read: vitalsReadTypes, completion: completion)
    }

    // completion is called on a background queue!
    func fetchWorkoutVitals(start: Date, end: Date, completion: @escaping (WorkoutVitals) -> Void) {
        guard HKHealthStore.isHealthDataAvailable(), end > start,
              let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate),
              let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) else {
            completion(WorkoutVitals(heartRate: [], activeEnergyKilocalories: nil))
            return
        }

        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let group = DispatchGroup()
        let lock = NSLock()
        var heartRate: [WorkoutVitals.HeartRatePoint] = []
        var energy: Double?

        group.enter()
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        let heartRateQuery = HKSampleQuery(
            sampleType: heartRateType,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        ) { _, samples, _ in
            let points = (samples as? [HKQuantitySample] ?? []).map {
                WorkoutVitals.HeartRatePoint(date: $0.startDate, bpm: $0.quantity.doubleValue(for: bpmUnit))
            }
            lock.lock(); heartRate = points; lock.unlock()
            group.leave()
        }

        group.enter()
        let energyQuery = HKStatisticsQuery(
            quantityType: energyType,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum
        ) { _, statistics, _ in
            let total = statistics?.sumQuantity()?.doubleValue(for: .kilocalorie())
            lock.lock(); energy = total.flatMap { $0 > 0 ? $0 : nil }; lock.unlock()
            group.leave()
        }

        healthStore.execute(heartRateQuery)
        healthStore.execute(energyQuery)
        group.notify(queue: .global(qos: .userInitiated)) {
            lock.lock()
            let vitals = WorkoutVitals(heartRate: heartRate, activeEnergyKilocalories: energy)
            lock.unlock()
            completion(vitals)
        }
    }
}
