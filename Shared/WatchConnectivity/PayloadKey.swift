//
//  PayloadKey.swift
//  Iron
//
//  Created by Karim Abou Zeid on 04.11.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import Foundation

enum PayloadKey {
    // phone --> watch
    // calls healthStore.startWatchApp()
    
    // phone <-- watch
    // Args: true
    static let preparedWorkoutSession = "preparedWorkoutSession" // sent to confirm that healthStore.startWatchApp() resulted in a prepare
    
    // phone --> watch
    // Args: true
    static let ignoredPreparedWorkoutSession = "ignoredPreparedWorkoutSession" // send if the prepared message came to late, i.e. after the workout was already canceled / finished
    
    // phone --> watch
    // Args: [start: Date, uuid: UUID]
    static let startWorkoutSession = "startWorkoutSession"
    
    // phone --> watch
    // Args: [start: Date, uuid: UUID]
    static let updateWorkoutSessionStart = "updateWorkoutSessionStart"
    
    // phone --> watch
    // Args: [end: Date?, uuid: UUID]
    static let updateWorkoutSessionEnd = "updateWorkoutSessionEnd"
    
    // phone --> watch
    // Args: [end: Date?, keepRestTimerRunning: Bool?, uuid: UUID]
    static let updateWorkoutSessionRestTimer = "updateWorkoutSessionRestTimer"
    
    // phone --> watch
    // Args: [text: String, uuid: UUID] // TODO: replace with [reps: Int, weight: Double, uuid: UUID]
    static let updateWorkoutSessionSelectedSet = "updateWorkoutSessionSelectedSet"
    
    // phone --> watch
    // Args: [start: Date, end: Date, title: String?, uuid: UUID]
    static let endWorkoutSession = "endWorkoutSession"
    
    // phone --> watch
    // Args: [uuid: UUID]
    static let discardWorkoutSession = "discardWorkoutSession"

    // phone <--> watch
    // Args: Data containing a WatchWorkoutSnapshot / WatchWorkoutEventAck
    static let workoutSnapshot = "workoutSnapshot"
    static let workoutEventAck = "workoutEventAck"

    // watch --> phone
    // Args: Data containing a WatchWorkoutEvent
    static let workoutEvent = "workoutEvent"

    // watch --> phone, best-effort live sensor values; never queued or persisted.
    static let workoutMetrics = "workoutMetrics"
    static let workoutLibrary = "workoutLibrary"
    static let requestWorkoutLibrary = "requestWorkoutLibrary"
    static let requestWorkoutSnapshot = "requestWorkoutSnapshot"

    // phone --> watch: debug preference, also included in start/end arguments.
    static let healthTestMode = "healthTestMode"

    // phone <--> watch: timestamped inventory and exercise-UUID-keyed setups.
    static let plateInventory = "plateInventory"
    static let plateLoadouts = "plateLoadouts"
    
    enum Arg {
        static let start = "start" // Date
        static let end = "end" // Date
        static let keepRestTimerRunning = "keepRestTimerRunning" // Bool
        static let text = "text" // String
        static let title = "title" // String
        static let uuid = "uuid" // UUID
        static let data = "data" // Data
        static let isHealthTestWorkout = "isHealthTestWorkout" // Bool, sticky start provenance
    }
}

/// The wire format is deliberately kept in the shared target.  WatchConnectivity
/// only transports property-list values, so snapshots/events are carried as JSON
/// Data and can be sent through either application context, message, or user info.
enum WatchWorkoutWire {
    static let schemaVersion = 1

    static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}

/// Display-only HealthKit telemetry. The Watch remains the sole owner of its
/// HealthKit workout and samples; this value never enters the durable edit log.
struct WatchWorkoutMetrics: Codable, Equatable {
    enum SessionState: String, Codable {
        case running, paused, ended
    }

    let workoutID: UUID
    /// Unix seconds retain subsecond ordering with the existing wire encoder.
    let sentAt: TimeInterval
    let state: SessionState
    let heartRate: Double?
    let heartRateDate: Date?
    let activeEnergyKilocalories: Double?

    init(workoutID: UUID, date: Date = Date(), state: SessionState,
         heartRate: Double?, heartRateDate: Date?, activeEnergyKilocalories: Double?) {
        self.workoutID = workoutID
        sentAt = date.timeIntervalSince1970
        self.state = state
        self.heartRate = heartRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.heartRateDate = heartRateDate
        self.activeEnergyKilocalories = activeEnergyKilocalories.flatMap {
            $0.isFinite && $0 >= 0 ? $0 : nil
        }
    }

    func isFresh(at date: Date) -> Bool {
        let age = date.timeIntervalSince1970 - sentAt
        return sentAt.isFinite && age >= -5 && age <= 30
    }

    func accepts(after previous: Self?, for currentWorkoutID: UUID, at date: Date) -> Bool {
        guard workoutID == currentWorkoutID, isFresh(at: date) else { return false }
        return previous?.workoutID != workoutID || sentAt > (previous?.sentAt ?? -.infinity)
    }

    func currentHeartRate(at date: Date) -> Double? {
        guard state == .running, isFresh(at: date),
              let heartRate, heartRate.isFinite, heartRate > 0,
              let heartRateDate else { return nil }
        let age = date.timeIntervalSince(heartRateDate)
        return age >= -5 && age <= 30 ? heartRate : nil
    }

    func currentActiveEnergy(at date: Date) -> Double? {
        guard state != .ended, isFresh(at: date),
              let activeEnergyKilocalories,
              activeEnergyKilocalories.isFinite, activeEnergyKilocalories >= 0 else { return nil }
        return activeEnergyKilocalories
    }
}

/// The value stored under `watchWorkoutStore.v1`. Keep these property names
/// stable so watch data written by earlier builds remains decodable.
struct WatchWorkoutPersistedState: Codable, Equatable {
    var snapshot: WatchWorkoutSnapshot?
    var outbox: [WatchWorkoutEvent]
    var nextSequence: Int64
    /// Optional for stores written before acknowledgement watermarks existed.
    var acknowledgedSequences: [String: Int64]? = nil
    /// Bounded terminal identities survive projection/outbox cleanup and relaunch.
    var terminalWorkoutIDs: [UUID]? = nil

    init(
        snapshot: WatchWorkoutSnapshot? = nil,
        outbox: [WatchWorkoutEvent] = [],
        nextSequence: Int64 = 0
    ) {
        self.snapshot = snapshot
        self.outbox = outbox
        self.nextSequence = nextSequence
    }
}

enum WatchWorkoutPersistenceError: LocalizedError, Equatable {
    case encodingFailed
    case sequenceOverflow
    case revisionOverflow
    case missingProjection

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "The workout change could not be encoded for durable storage."
        case .sequenceOverflow:
            return "The workout event sequence is exhausted."
        case .revisionOverflow:
            return "The workout snapshot revision is exhausted."
        case .missingProjection:
            return "The workout action could not be saved because its local projection is missing."
        }
    }
}

enum WatchWorkoutSnapshotChange {
    case keep
    case replace(WatchWorkoutSnapshot?)
}

/// Session-independent decisions shared by recovery and terminal receipts.
enum WatchWorkoutFinalization {
    enum RecoveryAction: Equatable { case none, waitForSave, resume, verifySavedWorkout }

    static func isDuplicateFinish(workoutID: UUID, recordingWorkoutID: UUID?, isFinalizing: Bool) -> Bool {
        recordingWorkoutID == workoutID && isFinalizing
    }

    static func recoveryAction(snapshot: WatchWorkoutSnapshot?, recordingWorkoutID: UUID?,
                               isFinalizing: Bool, canResume: Bool) -> RecoveryAction {
        // A legacy display end date is not evidence of a Finish action.
        guard let snapshot, snapshot.isFinished == true else { return .none }
        if isDuplicateFinish(workoutID: snapshot.workoutID, recordingWorkoutID: recordingWorkoutID,
                             isFinalizing: isFinalizing) { return .waitForSave }
        return recordingWorkoutID == snapshot.workoutID && canResume ? .resume : .verifySavedWorkout
    }
}

/// Prepares a complete replacement value before callers publish it in memory
/// or write it to UserDefaults. This provides application-level atomicity for
/// the snapshot, outbox, and event sequence.
enum WatchWorkoutPersistence {
    struct Prepared<Result> {
        let state: WatchWorkoutPersistedState
        let data: Data
        let result: Result
    }

    static func prepare<Result>(
        current: WatchWorkoutPersistedState,
        encode: (WatchWorkoutPersistedState) -> Data? = { WatchWorkoutWire.encode($0) },
        mutation: (inout WatchWorkoutPersistedState) throws -> Result
    ) throws -> Prepared<Result> {
        var candidate = current
        let result = try mutation(&candidate)
        guard let data = encode(candidate) else {
            throw WatchWorkoutPersistenceError.encodingFailed
        }
        return Prepared(state: candidate, data: data, result: result)
    }

    static func prepareEvent(
        current: WatchWorkoutPersistedState,
        snapshotChange: WatchWorkoutSnapshotChange,
        encode: (WatchWorkoutPersistedState) -> Data? = { WatchWorkoutWire.encode($0) },
        makeEvent: (Int64, WatchWorkoutSnapshot?) -> WatchWorkoutEvent
    ) throws -> Prepared<WatchWorkoutEvent> {
        try prepare(current: current, encode: encode) { candidate in
            guard candidate.nextSequence < Int64.max else {
                throw WatchWorkoutPersistenceError.sequenceOverflow
            }
            candidate.nextSequence += 1
            switch snapshotChange {
            case .keep:
                break
            case .replace(let snapshot):
                candidate.snapshot = snapshot
            }
            let event = makeEvent(candidate.nextSequence, candidate.snapshot)
            candidate.outbox.append(event)
            if event.kind == .workoutFinished || event.kind == .workoutDiscarded {
                markTerminal(event.workoutID, in: &candidate)
            }
            return event
        }
    }

    static func incrementRevision(_ snapshot: inout WatchWorkoutSnapshot) throws {
        guard snapshot.revision < Int64.max else {
            throw WatchWorkoutPersistenceError.revisionOverflow
        }
        snapshot.revision += 1
    }

    static func acknowledge(eventIDs: [UUID], in state: inout WatchWorkoutPersistedState) {
        let ids = Set(eventIDs)
        for event in state.outbox where ids.contains(event.id) {
            // Queued terminal events may have been written by an older build.
            if event.kind == .workoutFinished || event.kind == .workoutDiscarded {
                markTerminal(event.workoutID, in: &state)
            }
            let key = event.workoutID.uuidString
            var sequences = state.acknowledgedSequences ?? [:]
            sequences[key] = max(sequences[key] ?? 0, event.sequence)
            state.acknowledgedSequences = sequences
        }
        state.outbox.removeAll { ids.contains($0.id) }
    }

    static func retainingTerminalID(_ id: UUID, in ids: [UUID]) -> [UUID] {
        Array((ids.filter { $0 != id } + [id]).suffix(50))
    }

    static func markTerminal(_ id: UUID, in state: inout WatchWorkoutPersistedState) {
        state.terminalWorkoutIDs = retainingTerminalID(id, in: state.terminalWorkoutIDs ?? [])
    }
}

struct WatchWorkoutSet: Codable, Identifiable, Equatable {
    let id: UUID
    var order: Int
    var weight: Double?
    var reps: Int?
    var rpe: Double?
    var previousWeight: Double?
    var previousReps: Int?
    var completed: Bool

    /// `warmUp`, `dropSet`, `failure`, or `nil` for a working set.
    var tag: String?
    var duration: TimeInterval? = nil
    /// Canonical meters, independent of the weight display unit.
    var distance: Double? = nil
    var comment: String? = nil
    var minTargetReps: Int? = nil
    var maxTargetReps: Int? = nil

    init(id: UUID = UUID(), order: Int, weight: Double? = nil, reps: Int? = nil,
         rpe: Double? = nil, previousWeight: Double? = nil,
         previousReps: Int? = nil, completed: Bool = false,
         tag: String? = nil, duration: TimeInterval? = nil,
         distance: Double? = nil, comment: String? = nil,
         minTargetReps: Int? = nil, maxTargetReps: Int? = nil) {
        self.id = id
        self.order = order
        self.weight = weight
        self.reps = reps
        self.rpe = rpe
        self.previousWeight = previousWeight
        self.previousReps = previousReps
        self.completed = completed
        self.tag = tag
        self.duration = duration
        self.distance = distance
        self.comment = comment
        self.minTargetReps = minTargetReps
        self.maxTargetReps = maxTargetReps
    }

    var displayText: String {
        if let duration, duration > 0 {
            let seconds = Int(duration.rounded())
            let time = String(format: "%d:%02d", seconds / 60, seconds % 60)
            if let distance, distance > 0 { return "\(time) · \(Self.numberText(distance)) m" }
            return time
        }
        let weightText = positiveWeight.map(Self.numberText)
        let repsText = positiveReps.map(String.init)

        switch (weightText, repsText) {
        case let (.some(weight), .some(reps)):
            return "\(weight) × \(reps)"
        case let (.some(weight), .none):
            return weight
        case let (.none, .some(reps)):
            return "\(reps) reps"
        case (.none, .none):
            return "—"
        }
    }

    func displayText(weightUnit: WatchWorkoutWeightUnit) -> String {
        if duration != nil || distance != nil { return displayText }
        guard let weight = positiveWeight else { return displayText }
        let weightText = Self.numberText(weight)
        if let reps = positiveReps {
            return "\(weightText) \(weightUnit.symbol) × \(reps)"
        }
        return "\(weightText) \(weightUnit.symbol)"
    }

    func previousDisplayText(weightUnit: WatchWorkoutWeightUnit) -> String? {
        let previousWeight = self.previousWeight.flatMap { $0 > 0 ? $0 : nil }
        let previousReps = self.previousReps.flatMap { $0 > 0 ? $0 : nil }

        switch (previousWeight, previousReps) {
        case let (.some(weight), .some(reps)):
            return "\(Self.numberText(weight)) \(weightUnit.symbol) × \(reps)"
        case let (.some(weight), .none):
            return "\(Self.numberText(weight)) \(weightUnit.symbol)"
        case let (.none, .some(reps)):
            return "\(reps) reps"
        case (.none, .none):
            return nil
        }
    }

    private var positiveWeight: Double? {
        weight.flatMap { $0 > 0 ? $0 : nil }
    }

    private var positiveReps: Int? {
        reps.flatMap { $0 > 0 ? $0 : nil }
    }

    private static func numberText(_ value: Double) -> String {
        if value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%g", value)
    }
}

enum WatchWorkoutWeightUnit: String, Codable {
    case kilogram
    case pound

    var symbol: String {
        switch self {
        case .kilogram: return "kg"
        case .pound: return "lb"
        }
    }
}

struct WatchExercisePick: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var muscle: String?
    var imageURL: String?
    /// False leaves it out of the plain list; search still finds it. Older payloads omit it.
    var listed: Bool? = nil
}

struct WatchWorkoutExercise: Codable, Identifiable, Equatable {
    let id: UUID
    var order: Int
    var name: String
    var sets: [WatchWorkoutSet]
    /// Optional so snapshots written by older phone builds remain decodable.
    /// Keeping the configured recovery duration with the exercise lets the
    /// watch start its timer even while the phone is unreachable.
    var restTimerDuration: TimeInterval?
    var muscleGroup: String?
    var exerciseUuid: UUID?
    var imageURL: String?
    /// JPEG still of the bundled diagram when there is no Gym Visual GIF.
    var imageData: Data?
    var supersetID: UUID? = nil
    /// Transient note for this logged workout only.
    var comment: String? = nil
    /// Pinned catalog cue; edits travel through timestamped ExerciseNotes preferences.
    var exerciseNote: String? = nil
    /// Display-only cue from this exercise's saved workout plan.
    var routineNote: String? = nil
    /// Stable source for the plan cue when new logged exercise IDs are created.
    var routineExerciseID: UUID? = nil
    /// Raw value of SetTrackingType; missing/unknown values use the receiver's inference.
    var trackingType: String? = nil

    init(
        id: UUID = UUID(),
        order: Int,
        name: String,
        sets: [WatchWorkoutSet],
        restTimerDuration: TimeInterval? = nil,
        muscleGroup: String? = nil,
        exerciseUuid: UUID? = nil,
        imageURL: String? = nil,
        imageData: Data? = nil,
        supersetID: UUID? = nil,
        comment: String? = nil,
        trackingType: String? = nil,
        exerciseNote: String? = nil,
        routineNote: String? = nil,
        routineExerciseID: UUID? = nil
    ) {
        self.id = id
        self.order = order
        self.name = name
        self.sets = sets
        self.restTimerDuration = restTimerDuration
        self.muscleGroup = muscleGroup
        self.exerciseUuid = exerciseUuid
        self.imageURL = imageURL
        self.imageData = imageData
        self.supersetID = supersetID
        self.comment = comment
        self.exerciseNote = exerciseNote
        self.routineNote = routineNote
        self.routineExerciseID = routineExerciseID
        self.trackingType = trackingType
    }
}

struct WatchWorkoutSnapshot: Codable, Equatable {
    var schemaVersion: Int
    var workoutID: UUID
    var title: String?
    var startDate: Date
    var endDate: Date?
    var exercises: [WatchWorkoutExercise]
    var selectedSetID: UUID?
    var selectedSetText: String?
    var restTimerEnd: Date?
    var keepRestTimerRunning: Bool
    /// Optional so snapshots persisted by an older build remain decodable.
    var weightUnit: WatchWorkoutWeightUnit?
    /// Overall workout effort (1...10). Optional to keep persisted v1
    /// snapshots and snapshots from older phone/watch builds decodable.
    var sessionEffort: Double?
    /// Compact catalog so the watch can add or replace exercises offline.
    var library: [WatchExercisePick]?
    var revision: Int64
    var updatedAt: Date
    var comment: String? = nil
    var sourceSavedWorkoutID: UUID? = nil
    var pausedRestRemaining: TimeInterval? = nil
    var activeEnergyKilocalories: Double? = nil
    /// Fixed display end times can exist on a still-active phone workout.
    var isFinished: Bool? = nil
    /// Durable provenance, including in queued finishes. Older peers omit this
    /// field (false); release builds retain it only to exclude past test exports.
    var healthTestMode: Bool? = nil
    /// Watch-local pause state survives suspension/relaunch without a session.
    var healthTestWorkoutPaused: Bool? = nil
    /// Independent of Health export/test state; older peers omit provenance.
    var startedOnWatch: Bool? = nil
    /// Highest durable Watch event included in this phone projection.
    var acknowledgedWatchSequence: Int64? = nil

    var isHealthTestWorkout: Bool { healthTestMode == true }

    init(workoutID: UUID, title: String? = nil, startDate: Date = Date(),
         endDate: Date? = nil, exercises: [WatchWorkoutExercise] = [],
         selectedSetID: UUID? = nil, selectedSetText: String? = nil,
         restTimerEnd: Date? = nil, keepRestTimerRunning: Bool = false,
         weightUnit: WatchWorkoutWeightUnit? = .kilogram,
         sessionEffort: Double? = nil,
         library: [WatchExercisePick]? = nil,
         revision: Int64 = 0, updatedAt: Date = Date(),
         comment: String? = nil, sourceSavedWorkoutID: UUID? = nil,
         pausedRestRemaining: TimeInterval? = nil,
         isFinished: Bool? = nil) {
        self.schemaVersion = WatchWorkoutWire.schemaVersion
        self.workoutID = workoutID
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.exercises = exercises
        self.selectedSetID = selectedSetID
        self.selectedSetText = selectedSetText
        self.restTimerEnd = restTimerEnd
        self.keepRestTimerRunning = keepRestTimerRunning
        self.weightUnit = weightUnit
        self.sessionEffort = sessionEffort
        self.library = library
        self.revision = revision
        self.updatedAt = updatedAt
        self.comment = comment
        self.sourceSavedWorkoutID = sourceSavedWorkoutID
        self.pausedRestRemaining = pausedRestRemaining
        self.isFinished = isFinished
    }

    var selectedSet: (exercise: WatchWorkoutExercise, set: WatchWorkoutSet)? {
        guard let selectedSetID = selectedSetID else { return nil }
        for exercise in exercises {
            if let set = exercise.sets.first(where: { $0.id == selectedSetID }) {
                return (exercise, set)
            }
        }
        return nil
    }

    var isFinishedRecord: Bool { isFinished ?? (endDate != nil) }

    func canReplace(_ current: WatchWorkoutSnapshot?, acknowledgedSequence: Int64 = 0) -> Bool {
        // A pre-edit snapshot can arrive after the ACK removes the last pending
        // event. Revision alone does not prove that it contains that edit.
        if let acknowledgedWatchSequence, acknowledgedWatchSequence < acknowledgedSequence { return false }
        guard let current, current.workoutID == workoutID else { return true }
        return revision > current.revision || (revision == current.revision && updatedAt >= current.updatedAt)
    }

    static func nextRevision(after revision: Int64, at date: Date) -> Int64 {
        max(revision < .max ? revision + 1 : revision,
            Int64(date.timeIntervalSince1970 * 1_000))
    }

    static func placeholder(workoutID: UUID, startDate: Date) -> WatchWorkoutSnapshot {
        let set = WatchWorkoutSet(order: 1)
        let exercise = WatchWorkoutExercise(order: 1, name: "Workout", sets: [set])
        return WatchWorkoutSnapshot(workoutID: workoutID, startDate: startDate,
                                    exercises: [exercise], selectedSetID: set.id, isFinished: false)
    }
}

enum WatchWorkoutEventKind: String, Codable {
    case setUpdated
    case setCompletionChanged
    case restTimerUpdated
    case workoutFinished
    case workoutDiscarded
    case workoutFailed
    case setAdded
    case setDeleted
    case setTagChanged
    case exerciseAdded
    case exerciseReplaced
    case exerciseDeleted
    case workoutCreated
    case workoutStructureUpdated
    case savedWorkoutUpserted
    case savedWorkoutDeleted
}

/// Field-level changes carried by modern full-snapshot events. A nil mask means
/// the sender predates masked merging and retains the legacy replacement rules.
struct WatchWorkoutFieldChanges: Codable, Equatable {
    var workout: [String]
    var exercises: [String: [String]]
    var sets: [String: [String]]
    var exerciseOrder: Bool
    /// Exercise IDs whose set ordering changed.
    var setOrder: [UUID]
    /// Explicit additions prevent a stale full snapshot from resurrecting IDs
    /// concurrently deleted on the phone. Nil decodes legacy masks.
    var addedExerciseIDs: [UUID]? = nil
    var addedSetIDs: [UUID]? = nil

    init(workout: [String] = [], exercises: [String: [String]] = [:],
         sets: [String: [String]] = [:], exerciseOrder: Bool = false,
         setOrder: [UUID] = [], addedExerciseIDs: [UUID]? = nil,
         addedSetIDs: [UUID]? = nil) {
        self.workout = workout
        self.exercises = exercises
        self.sets = sets
        self.exerciseOrder = exerciseOrder
        self.setOrder = setOrder
        self.addedExerciseIDs = addedExerciseIDs
        self.addedSetIDs = addedSetIDs
    }

    static func between(previous: WatchWorkoutSnapshot,
                        next: WatchWorkoutSnapshot) -> WatchWorkoutFieldChanges {
        let baseline = next.weightUnit.map { WatchWorkoutEditing.converting(previous, to: $0) }
            ?? previous
        var changes = WatchWorkoutFieldChanges(addedExerciseIDs: [], addedSetIDs: [])

        func append(_ field: String, when changed: Bool, to fields: inout [String]) {
            if changed { fields.append(field) }
        }

        append("title", when: baseline.title != next.title, to: &changes.workout)
        append("startDate", when: baseline.startDate != next.startDate, to: &changes.workout)
        append("endDate", when: baseline.endDate != next.endDate, to: &changes.workout)
        append("comment", when: baseline.comment != next.comment, to: &changes.workout)
        append("sourceSavedWorkoutID", when: baseline.sourceSavedWorkoutID != next.sourceSavedWorkoutID,
               to: &changes.workout)

        let previousExercises = Dictionary(uniqueKeysWithValues: baseline.exercises.map { ($0.id, $0) })
        changes.exerciseOrder = baseline.exercises.sorted(by: { $0.order < $1.order }).map(\.id)
            != next.exercises.sorted(by: { $0.order < $1.order }).map(\.id)
        let allExerciseFields = ["exerciseUuid", "restTimerDuration", "supersetID", "comment"]
        let allSetFields = ["weight", "reps", "rpe", "completed", "tag", "duration",
                            "distance", "comment", "minTargetReps", "maxTargetReps"]

        for exercise in next.exercises {
            let exerciseKey = exercise.id.uuidString
            guard let oldExercise = previousExercises[exercise.id] else {
                changes.addedExerciseIDs?.append(exercise.id)
                changes.exercises[exerciseKey] = allExerciseFields
                for set in exercise.sets {
                    changes.addedSetIDs?.append(set.id)
                    changes.sets[set.id.uuidString] = allSetFields
                }
                changes.setOrder.append(exercise.id)
                continue
            }

            var exerciseFields: [String] = []
            append("exerciseUuid", when: oldExercise.exerciseUuid != exercise.exerciseUuid,
                   to: &exerciseFields)
            append("restTimerDuration", when: oldExercise.restTimerDuration != exercise.restTimerDuration,
                   to: &exerciseFields)
            append("supersetID", when: oldExercise.supersetID != exercise.supersetID,
                   to: &exerciseFields)
            append("comment", when: oldExercise.comment != exercise.comment, to: &exerciseFields)
            if !exerciseFields.isEmpty { changes.exercises[exerciseKey] = exerciseFields }

            let previousSets = Dictionary(uniqueKeysWithValues: oldExercise.sets.map { ($0.id, $0) })
            if oldExercise.sets.sorted(by: { $0.order < $1.order }).map(\.id)
                != exercise.sets.sorted(by: { $0.order < $1.order }).map(\.id) {
                changes.setOrder.append(exercise.id)
            }
            for set in exercise.sets {
                guard let oldSet = previousSets[set.id] else {
                    changes.addedSetIDs?.append(set.id)
                    changes.sets[set.id.uuidString] = allSetFields
                    continue
                }
                var setFields: [String] = []
                append("weight", when: oldSet.weight != set.weight, to: &setFields)
                append("reps", when: oldSet.reps != set.reps, to: &setFields)
                append("rpe", when: oldSet.rpe != set.rpe, to: &setFields)
                append("completed", when: oldSet.completed != set.completed, to: &setFields)
                append("tag", when: oldSet.tag != set.tag, to: &setFields)
                append("duration", when: oldSet.duration != set.duration, to: &setFields)
                append("distance", when: oldSet.distance != set.distance, to: &setFields)
                append("comment", when: oldSet.comment != set.comment, to: &setFields)
                append("minTargetReps", when: oldSet.minTargetReps != set.minTargetReps, to: &setFields)
                append("maxTargetReps", when: oldSet.maxTargetReps != set.maxTargetReps, to: &setFields)
                if !setFields.isEmpty { changes.sets[set.id.uuidString] = setFields }
            }
        }
        return changes
    }
}

struct WatchWorkoutEvent: Codable, Identifiable, Equatable {
    let schemaVersion: Int
    let id: UUID
    let workoutID: UUID
    let sequence: Int64
    let createdAt: Date
    let kind: WatchWorkoutEventKind
    var exerciseID: UUID?
    var setID: UUID?
    var weight: Double?
    var reps: Int?
    var rpe: Double?
    var completed: Bool?
    var restTimerEnd: Date?
    var keepRestTimerRunning: Bool?
    var startDate: Date?
    var endDate: Date?
    var title: String?
    /// The unit used for `weight`. Optional for compatibility with queued v1 events.
    var weightUnit: WatchWorkoutWeightUnit?
    /// Overall workout effort (1...10) captured when finishing on Apple Watch.
    /// Optional for compatibility with queued events from older builds.
    var sessionEffort: Double?
    /// Finish events include the watch's complete durable projection so a final
    /// set edit cannot be lost if WatchConnectivity delivers packets out of order.
    var snapshot: WatchWorkoutSnapshot?
    var tag: String?
    var catalogExerciseUuid: UUID?
    var afterExerciseID: UUID?
    var savedWorkout: WatchSavedWorkout? = nil
    /// Explicit deletions preserve concurrent phone additions that were never on this Watch.
    var removedExerciseIDs: [UUID]? = nil
    var removedSetIDs: [UUID]? = nil
    var fieldChanges: WatchWorkoutFieldChanges? = nil

    init(workoutID: UUID, sequence: Int64, kind: WatchWorkoutEventKind,
         exerciseID: UUID? = nil, setID: UUID? = nil, weight: Double? = nil,
         reps: Int? = nil, rpe: Double? = nil, completed: Bool? = nil,
         restTimerEnd: Date? = nil, keepRestTimerRunning: Bool? = nil,
         startDate: Date? = nil, endDate: Date? = nil, title: String? = nil,
         weightUnit: WatchWorkoutWeightUnit? = nil,
         sessionEffort: Double? = nil,
         snapshot: WatchWorkoutSnapshot? = nil,
         tag: String? = nil,
         catalogExerciseUuid: UUID? = nil,
         afterExerciseID: UUID? = nil,
         savedWorkout: WatchSavedWorkout? = nil,
         removedExerciseIDs: [UUID]? = nil, removedSetIDs: [UUID]? = nil,
         fieldChanges: WatchWorkoutFieldChanges? = nil,
         id: UUID = UUID(), createdAt: Date = Date()) {
        self.schemaVersion = WatchWorkoutWire.schemaVersion
        self.id = id
        self.workoutID = workoutID
        self.sequence = sequence
        self.createdAt = createdAt
        self.kind = kind
        self.exerciseID = exerciseID
        self.setID = setID
        self.weight = weight
        self.reps = reps
        self.rpe = rpe
        self.completed = completed
        self.restTimerEnd = restTimerEnd
        self.keepRestTimerRunning = keepRestTimerRunning
        self.startDate = startDate
        self.endDate = endDate
        self.title = title
        self.weightUnit = weightUnit
        self.sessionEffort = sessionEffort
        self.snapshot = snapshot
        self.tag = tag
        self.catalogExerciseUuid = catalogExerciseUuid
        self.afterExerciseID = afterExerciseID
        self.savedWorkout = savedWorkout
        self.removedExerciseIDs = removedExerciseIDs
        self.removedSetIDs = removedSetIDs
        self.fieldChanges = fieldChanges
    }
}

struct WatchSavedWorkout: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var exercises: [WatchWorkoutExercise]
    var weightUnit: WatchWorkoutWeightUnit
    var comment: String?
    var updatedAt: Date
}

/// Transferred as an immutable file, rather than exceeding WCSession's message
/// limit with the full catalog/history. No sensor samples or Health writes.
struct WatchWorkoutLibrary: Codable, Equatable {
    var schemaVersion: Int = WatchWorkoutWire.schemaVersion
    var generatedAt: Date
    var exercises: [WatchExercisePick]
    var savedWorkouts: [WatchSavedWorkout]
    var history: [WatchWorkoutSnapshot]
    var weightUnit: WatchWorkoutWeightUnit
    var revision: Int64? = nil

    /// History needs set results and catalog identifiers, not repeated JPEGs or
    /// an entire embedded exercise picker. Keep the v1 wire keys compatible;
    /// older libraries still decode and are compacted when cached on Watch.
    func removingHistoryMedia() -> Self {
        var result = self
        for workout in result.history.indices {
            result.history[workout].library = nil
            for exercise in result.history[workout].exercises.indices {
                let source = result.history[workout].exercises[exercise]
                if source.imageData != nil {
                    result.history[workout].exercises[exercise].imageURL = Self.historyMediaURL(for: source).absoluteString
                }
                result.history[workout].exercises[exercise].imageData = nil
            }
        }
        return result
    }

    /// Use the existing ExerciseMedia cache's URL keys, including a stable
    /// local key for bundled JPEGs which never had a downloadable image URL.
    var historyMediaForCaching: [(url: URL, data: Data)] {
        history.flatMap(\.exercises).compactMap { exercise in
            exercise.imageData.map { (Self.historyMediaURL(for: exercise), $0) }
        }
    }

    static func historyMediaURL(for exercise: WatchWorkoutExercise) -> URL {
        exercise.imageURL.flatMap(URL.init(string:))
            ?? URL(fileURLWithPath: "/LightExerciseMedia/" + (exercise.exerciseUuid ?? exercise.id).uuidString)
    }

    /// Transport clocks alone must not rewrite the large library file or
    /// invalidate every library view. The receiver retains the clocks separately.
    func hasSameContent(as other: Self) -> Bool {
        schemaVersion == other.schemaVersion && exercises == other.exercises &&
            savedWorkouts == other.savedWorkouts && history == other.history &&
            weightUnit == other.weightUnit
    }
}

enum WatchWorkoutEditing {
    static func nextSet(in snapshot: WatchWorkoutSnapshot, after setID: UUID? = nil) -> UUID? {
        let ordered = schedule(in: snapshot)
        let incomplete = Set(snapshot.exercises.flatMap(\.sets).filter { !$0.completed }.map(\.id))
        if let setID, let index = ordered.firstIndex(of: setID),
           let next = ordered.dropFirst(index + 1).first(where: { incomplete.contains($0) }) {
            return next
        }
        return ordered.first { incomplete.contains($0) }
    }

    static func schedule(in snapshot: WatchWorkoutSnapshot) -> [UUID] {
        var visited = Set<UUID>()
        var result: [UUID] = []
        for exercise in snapshot.exercises {
            if let group = exercise.supersetID {
                guard visited.insert(group).inserted else { continue }
                let members = snapshot.exercises.filter { $0.supersetID == group }
                for round in 0..<(members.map { $0.sets.count }.max() ?? 0) {
                    for member in members where member.sets.indices.contains(round) {
                        result.append(member.sets[round].id)
                    }
                }
            } else {
                result.append(contentsOf: exercise.sets.map(\.id))
            }
        }
        return result
    }

    /// Starting/repeating always creates fresh workout, exercise, set and group
    /// identities. Historical/imported workouts remain read-only source data.
    static func newWorkout(exercises: [WatchWorkoutExercise], title: String,
                           unit: WatchWorkoutWeightUnit, date: Date = Date(),
                           sourceSavedWorkoutID: UUID? = nil) -> WatchWorkoutSnapshot {
        var groups: [UUID: UUID] = [:]
        let copies = exercises.enumerated().map { index, source -> WatchWorkoutExercise in
            var copy = source
            copy = WatchWorkoutExercise(
                order: index + 1, name: source.name,
                sets: source.sets.enumerated().map { order, set in
                    WatchWorkoutSet(order: order + 1, weight: set.weight,
                                    reps: set.reps ?? set.maxTargetReps ?? set.minTargetReps,
                                    previousWeight: set.weight, previousReps: set.reps,
                                    tag: set.tag, duration: set.duration, distance: set.distance,
                                    comment: set.comment, minTargetReps: set.minTargetReps,
                                    maxTargetReps: set.maxTargetReps)
                },
                restTimerDuration: source.restTimerDuration,
                muscleGroup: source.muscleGroup, exerciseUuid: source.exerciseUuid,
                imageURL: source.imageURL, imageData: source.imageData,
                comment: source.comment, trackingType: source.trackingType)
            if let oldGroup = source.supersetID {
                let group = groups[oldGroup] ?? UUID()
                groups[oldGroup] = group
                copy.supersetID = group
            }
            return copy
        }
        var snapshot = WatchWorkoutSnapshot(workoutID: UUID(), title: title, startDate: date, exercises: copies,
                                            weightUnit: unit, updatedAt: date,
                                            sourceSavedWorkoutID: sourceSavedWorkoutID)
        snapshot.selectedSetID = nextSet(in: snapshot)
        return snapshot
    }

    static func normalize(_ snapshot: inout WatchWorkoutSnapshot) {
        for index in snapshot.exercises.indices {
            snapshot.exercises[index].order = index + 1
            for set in snapshot.exercises[index].sets.indices {
                snapshot.exercises[index].sets[set].order = set + 1
            }
        }
        let counts = Dictionary(grouping: snapshot.exercises.compactMap(\.supersetID), by: { $0 })
        for index in snapshot.exercises.indices {
            if let group = snapshot.exercises[index].supersetID, (counts[group]?.count ?? 0) < 2 {
                snapshot.exercises[index].supersetID = nil
            }
        }
        if !snapshot.exercises.flatMap(\.sets).contains(where: { $0.id == snapshot.selectedSetID }) {
            snapshot.selectedSetID = nextSet(in: snapshot)
        }
    }

    static func link(exerciseIDs: Set<UUID>, in snapshot: inout WatchWorkoutSnapshot) {
        if exerciseIDs.count <= 1 {
            for index in snapshot.exercises.indices where exerciseIDs.contains(snapshot.exercises[index].id) {
                snapshot.exercises[index].supersetID = nil
            }
        } else {
            let selectedGroups = Set(snapshot.exercises.filter { exerciseIDs.contains($0.id) }.compactMap(\.supersetID))
            let members = snapshot.exercises.filter { exerciseIDs.contains($0.id) || $0.supersetID.map(selectedGroups.contains) == true }
            let group = UUID()
            let ids = Set(members.map(\.id))
            for index in snapshot.exercises.indices where ids.contains(snapshot.exercises[index].id) {
                snapshot.exercises[index].supersetID = group
            }
        }
        normalize(&snapshot)
    }

    /// A checkbox editor describes exact membership. Detach selected exercises
    /// before linking so deselected members of their old groups stay excluded.
    static func replaceSuperset(exerciseIDs: Set<UUID>, anchorID: UUID?,
                                in snapshot: inout WatchWorkoutSnapshot) {
        let oldGroup = snapshot.exercises.first { $0.id == anchorID }?.supersetID
        for index in snapshot.exercises.indices {
            if exerciseIDs.contains(snapshot.exercises[index].id) ||
                (oldGroup != nil && snapshot.exercises[index].supersetID == oldGroup) {
                snapshot.exercises[index].supersetID = nil
            }
        }
        link(exerciseIDs: exerciseIDs, in: &snapshot)
    }

    static func reorder(exerciseIDs: [UUID], in snapshot: inout WatchWorkoutSnapshot) {
        guard exerciseIDs.count == snapshot.exercises.count,
              Set(exerciseIDs).count == exerciseIDs.count,
              Set(exerciseIDs) == Set(snapshot.exercises.map(\.id)) else { return }
        let byID = Dictionary(uniqueKeysWithValues: snapshot.exercises.map { ($0.id, $0) })
        snapshot.exercises = exerciseIDs.compactMap { byID[$0] }
        normalize(&snapshot)
    }

    static func converting(_ snapshot: WatchWorkoutSnapshot, to unit: WatchWorkoutWeightUnit) -> WatchWorkoutSnapshot {
        guard let oldUnit = snapshot.weightUnit, oldUnit != unit else {
            var copy = snapshot
            copy.weightUnit = unit
            return copy
        }
        var copy = snapshot
        let factor = unit == .pound ? 2.2046226218487757 : 1 / 2.2046226218487757
        for exercise in copy.exercises.indices {
            for set in copy.exercises[exercise].sets.indices {
                copy.exercises[exercise].sets[set].weight = copy.exercises[exercise].sets[set].weight.map { $0 * factor }
                copy.exercises[exercise].sets[set].previousWeight = copy.exercises[exercise].sets[set].previousWeight.map { $0 * factor }
            }
        }
        copy.weightUnit = unit
        return copy
    }
}

struct WatchWorkoutEventAck: Codable {
    let schemaVersion: Int
    let eventIDs: [UUID]

    init(eventIDs: [UUID]) {
        self.schemaVersion = WatchWorkoutWire.schemaVersion
        self.eventIDs = eventIDs
    }
}
