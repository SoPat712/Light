import Foundation
import Combine

/// Measurement columns are independent of warm-up/drop/failure tags.
/// Stored weights are always positive kilograms, including assistance.
enum SetTrackingType: String, Codable, CaseIterable, Identifiable {
    case weightReps, bodyweightReps, weightedBodyweight, assistedBodyweight
    case duration, weightDuration, distanceDuration, weightDistance

    var id: String { rawValue }
    var title: String {
        switch self {
        case .weightReps: return "Weight & Reps"
        case .bodyweightReps: return "Reps Only"
        case .weightedBodyweight: return "Weighted Bodyweight"
        case .assistedBodyweight: return "Assisted Bodyweight"
        case .duration: return "Duration"
        case .weightDuration: return "Weight & Duration"
        case .distanceDuration: return "Distance & Duration"
        case .weightDistance: return "Weight & Distance"
        }
    }

    enum Column: String, Codable, Identifiable, Hashable {
        case weight, reps, distance, duration
        var id: String { rawValue }
    }

    var columns: [Column] {
        switch self {
        case .weightReps, .weightedBodyweight, .assistedBodyweight: return [.weight, .reps]
        case .bodyweightReps: return [.reps]
        case .duration: return [.duration]
        case .weightDuration: return [.weight, .duration]
        case .distanceDuration: return [.distance, .duration]
        case .weightDistance: return [.weight, .distance]
        }
    }
    var usesWeight: Bool { columns.contains(.weight) }
    var usesReps: Bool { columns.contains(.reps) }
    var usesDuration: Bool { columns.contains(.duration) }
    var usesDistance: Bool { columns.contains(.distance) }
    var weightPrefix: String {
        self == .weightedBodyweight ? "+" : (self == .assistedBodyweight ? "−" : "")
    }
    func header(for column: Column, weightUnit: String, distanceUnit: String) -> String {
        switch column {
        case .weight: return weightPrefix + weightUnit.uppercased()
        case .reps: return "REPS"
        case .duration: return "TIME"
        case .distance: return distanceUnit.uppercased()
        }
    }
    func unit(for column: Column, weightUnit: String, distanceUnit: String) -> String {
        switch column {
        case .weight: return weightUnit
        case .reps: return "reps"
        case .duration: return "min:sec"
        case .distance: return distanceUnit
        }
    }

    enum VolumeRule: Equatable { case externalLoadTimesReps, excluded }
    /// Weighted bodyweight counts added load only. Assistance is excluded:
    /// a historical, per-set body mass is unavailable. Never count assistance as load lifted.
    /// Load × time and load × distance are different dimensions, not lifting volume.
    var volumeRule: VolumeRule {
        self == .weightReps || self == .weightedBodyweight ? .externalLoadTimesReps : .excluded
    }
    func volume(weight: Double, reps: Int) -> Double {
        guard volumeRule == .externalLoadTimesReps, weight.isFinite, weight > 0, reps > 0 else { return 0 }
        let value = weight * Double(reps)
        return value.isFinite ? value : 0
    }

    static func defaultType(name: String, equipment: [String], category: String = "") -> Self {
        let name = normalized(name)
        let equipment = equipment.map(normalized).joined(separator: " ")
        let context = name + " " + equipment + " " + normalized(category)
        if ["treadmill", "elliptical", "stepmill", "stair", "bike", "bicycle", "rower", "rowing machine", "ski erg", "skierg"].contains(where: { context.contains($0) }) {
            return .distanceDuration
        }
        let words = context.split(separator: " ")
        if words.contains("assisted") || words.contains("assistance") { return .assistedBodyweight }
        let isHold = name.split(separator: " ").contains { ["plank", "planks", "hold", "holds", "hang", "hangs"].contains(String($0)) }
        if isHold { return name.contains("weighted") ? .weightDuration : .duration }
        if equipment.contains("body weight") || equipment.contains("bodyweight") || equipment.contains("parallel bars") {
            return name.contains("weighted") ? .weightedBodyweight : .bodyweightReps
        }
        return .weightReps
    }

    struct SetData {
        var weight: Double = 0
        var reps: Int = 0
        var duration: TimeInterval? = nil
        var distance: Double? = nil
    }

    /// Shared by the history frontier and the model's store-translatable predicates.
    /// Every metric must be matched or exceeded to suppress a record; assistance
    /// reverses load, and pace never breaks a distance tie.
    struct PersonalRecordMetric {
        let column: Column
        var lowerIsBetter = false

        func value(in data: SetData) -> Double {
            switch column {
            case .weight: return data.weight
            case .reps: return Double(data.reps)
            case .duration: return data.duration ?? 0
            case .distance: return data.distance ?? 0
            }
        }

        func isValid(_ value: Double) -> Bool {
            value.isFinite && (column == .weight ? value >= 0 : value > 0)
        }
    }

    var personalRecordMetrics: [PersonalRecordMetric] {
        switch self {
        case .weightReps, .weightedBodyweight: return [.init(column: .weight), .init(column: .reps)]
        case .assistedBodyweight: return [.init(column: .weight, lowerIsBetter: true), .init(column: .reps)]
        case .bodyweightReps: return [.init(column: .reps)]
        case .duration: return [.init(column: .duration)]
        case .weightDuration: return [.init(column: .weight), .init(column: .duration)]
        case .distanceDuration: return [.init(column: .distance)]
        case .weightDistance: return [.init(column: .weight), .init(column: .distance)]
        }
    }

    /// Coordinates are normalized so higher is always better, including assistance.
    struct PersonalRecordMeasurement {
        let primary: Double
        let secondary: Double

        func dominates(_ other: Self) -> Bool {
            primary >= other.primary && secondary >= other.secondary
        }
    }

    /// Callers must check presence of optional load/reps fields before supplying
    /// their zero-defaulted SetData. Explicit zero load is valid; missing load isn't.
    func personalRecordMeasurement(from data: SetData) -> PersonalRecordMeasurement? {
        let metrics = personalRecordMetrics
        var values = (0.0, 0.0)
        for (index, metric) in metrics.enumerated() {
            let value = metric.value(in: data)
            guard metric.isValid(value) else { return nil }
            let normalized = metric.lowerIsBetter ? -value : value
            if index == 0 { values.0 = normalized }
            else { values.1 = normalized }
        }
        return PersonalRecordMeasurement(primary: values.0, secondary: values.1)
    }

    /// Nil distinguishes an empty set from an explicit reps-only result.
    static func infer(from data: SetData) -> Self? {
        let hasDistance = data.distance.map { $0.isFinite && $0 > 0 } ?? false
        let hasDuration = data.duration.map { $0.isFinite && $0 > 0 } ?? false
        let hasWeight = data.weight.isFinite && data.weight > 0
        if hasDistance { return hasWeight && !hasDuration ? .weightDistance : .distanceDuration }
        if hasDuration { return hasWeight ? .weightDuration : .duration }
        if hasWeight { return .weightReps }
        return data.reps > 0 ? .bodyweightReps : nil
    }

    /// Zero-valued optional measurements aren't stored by Core Data. Keep a
    /// compatible catalog/selected type (e.g. a treadmill with time but no distance
    /// entered yet), while allowing old workouts with other dimensions to render.
    static func resolved(_ preferred: Self, from data: SetData) -> Self {
        guard let inferred = infer(from: data) else { return preferred }
        switch (preferred, inferred) {
        case (.distanceDuration, .duration), (.distanceDuration, .distanceDuration),
             (.weightDuration, .duration), (.weightDuration, .weightDuration),
             (.weightedBodyweight, .weightReps), (.weightedBodyweight, .bodyweightReps),
             (.assistedBodyweight, .weightReps), (.assistedBodyweight, .bodyweightReps):
            return preferred
        case (.weightDistance, .weightReps) where data.reps == 0: return preferred
        case (.bodyweightReps, .weightReps): return .weightedBodyweight
        default: return inferred
        }
    }

    private static func normalized(_ value: String) -> String {
        // A display suffix must not hide a final movement token such as "Hold:"
        // or "Plank:". Preserve the existing handling of source-name parentheses.
        value.lowercased().replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ":", with: " ")
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let value = Int(min(max(seconds.isFinite ? seconds.rounded() : 0, 0), 359_999))
        if value >= 3_600 { return String(format: "%d:%02d:%02d", value / 3_600, value / 60 % 60, value % 60) }
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

/// The logger's only prefill rule. Values use the caller's weight unit and
/// canonical seconds/meters. Nil is empty; an explicitly entered zero is a value.
enum SetValuePrefill {
    struct Values: Codable, Equatable {
        var weight: Double? = nil
        var repetitions: Int? = nil
        var duration: TimeInterval? = nil
        var distance: Double? = nil

        subscript(_ column: SetTrackingType.Column) -> Double? {
            get {
                switch column {
                case .weight: return weight
                case .reps: return repetitions.map(Double.init)
                case .duration: return duration
                case .distance: return distance
                }
            }
            set {
                switch column {
                case .weight: weight = newValue
                case .reps: repetitions = newValue.map { Int($0) }
                case .duration: duration = newValue
                case .distance: distance = newValue
                }
            }
        }
    }

    struct SetInput {
        var values = Values()
        var userEnteredFields: Set<SetTrackingType.Column> = []
        var targets = Values()
        var isCompleted = false
        var isWarmup = false
    }

    /// Resolve in workout order so even an unfinished, automatically filled
    /// predecessor supplies the next row. Only the first row consults history;
    /// kind matching applies there, not between rows in the current workout.
    static func resolve(
        currentSets: [SetInput], previousSets: [SetInput], trackingType: SetTrackingType
    ) -> [Values] {
        var result: [Values] = []
        for set in currentSets {
            if set.isCompleted {
                result.append(set.values)
                continue
            }
            let inherited = result.last
                ?? previousSets.first(where: { $0.isWarmup == set.isWarmup })?.values
                ?? Values()
            var values = Values()
            for column in trackingType.columns {
                values[column] = set.userEnteredFields.contains(column)
                    ? set.values[column] : (set.targets[column] ?? inherited[column])
            }
            result.append(values)
        }
        return result
    }
}

enum SyncedPreferenceStorage {
    // UserDefaults is thread-safe, but a read/merge/write transaction also has
    // to exclude local edits while the connection's background queue applies it.
    static let lock = NSRecursiveLock()
}

/// One decoded value per defaults instance. Rendering never reads UserDefaults.
/// Defaults notifications have no changed-key list, so compare this key's bytes
/// before decoding or publishing. The private notification also keeps copies of
/// this shared source in different modules current after silent peer saves.
/// Receipt-only caches disable view publication but still share invalidations.
final class DefaultsValueCache<Value: Equatable>: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private let lock = NSRecursiveLock()
    private let key: String
    private let decode: (Data?) -> Value
    private let notificationCenter: NotificationCenter
    private let publishesChanges: Bool
    private var observers: [NSObjectProtocol] = []
    private var entries: [ObjectIdentifier: Entry] = [:]
    private let writeNotification = Notification.Name("ironCachedDefaultsValueDidChange")

    private final class Entry {
        weak var defaults: UserDefaults?
        var data: Data?
        var value: Value

        init(defaults: UserDefaults, data: Data?, value: Value) {
            self.defaults = defaults
            self.data = data
            self.value = value
        }
    }

    init(key: String, notification: Notification.Name? = nil,
         notificationCenter: NotificationCenter = .default,
         publishesChanges: Bool = true,
         decode: @escaping (Data?) -> Value) {
        self.key = key
        self.decode = decode
        self.notificationCenter = notificationCenter
        self.publishesChanges = publishesChanges
        var names = [UserDefaults.didChangeNotification, writeNotification]
        if let notification { names.append(notification) }
        for name in names {
            observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard let self else { return }
                if note.name == self.writeNotification, note.userInfo?["key"] as? String != self.key { return }
                self.refresh()
            })
        }
    }

    deinit { observers.forEach { notificationCenter.removeObserver($0) } }

    func load(defaults: UserDefaults = .standard) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return entry(for: defaults).value
    }

    /// Write through before defaults can notify observers. Local and peer saves
    /// retain their existing content/timestamp guards and notification rules.
    func store(_ value: Value, data: Data, defaults: UserDefaults) {
        lock.lock()
        let entry = entry(for: defaults)
        let changed = entry.value != value
        entry.data = data
        entry.value = value
        lock.unlock()
        // Never hold a cache lock while defaults or another module notifies.
        defaults.set(data, forKey: key)
        notificationCenter.post(name: writeNotification, object: defaults, userInfo: ["key": key])
        if changed { publishChange() }
    }

    private func entry(for defaults: UserDefaults) -> Entry {
        let id = ObjectIdentifier(defaults)
        if let entry = entries[id], entry.defaults === defaults { return entry }
        entries = entries.filter { $0.value.defaults != nil }
        let data = defaults.data(forKey: key)
        let entry = Entry(defaults: defaults, data: data, value: decode(data))
        entries[id] = entry
        return entry
    }

    private func refresh() {
        lock.lock()
        defer { lock.unlock() }
        for entry in entries.values {
            guard let defaults = entry.defaults else { continue }
            let data = defaults.data(forKey: key)
            guard data != entry.data else { continue }
            let value = decode(data)
            let changed = value != entry.value
            entry.data = data
            entry.value = value
            if changed { publishChange() }
        }
    }

    private func publishChange() {
        guard publishesChanges else { return }
        // Always enqueue: a remote save may hold the preference transaction lock,
        // and SwiftUI must never be notified while a view is evaluating a value.
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
    }
}

/// Small non-schema preferences shared by phone and Watch. Updates merge by
/// timestamp, with deterministic ties; peer saves don't emit local-edit notifications.
struct SetTrackingPreferences: Codable, Equatable {
    static let storageKey = "setTracking.preferences.v1"
    static let payloadKey = "setTrackingPreferences"
    static let didChangeNotification = Notification.Name("setTrackingPreferencesDidChange")

    struct Override: Codable, Equatable {
        var type: SetTrackingType
        var updatedAt: TimeInterval
    }
    struct DistanceTarget: Codable, Equatable {
        var meters: Double
        var updatedAt: TimeInterval
    }
    struct LoggerFields: Codable, Equatable {
        var fields: Set<SetTrackingType.Column>
        /// Frozen plan targets, with load in canonical kilograms.
        var targets: SetValuePrefill.Values? = nil
        var updatedAt: TimeInterval

        var contentKey: String {
            let measurements = [targets?.weight, targets?.repetitions.map(Double.init), targets?.duration, targets?.distance]
            return fields.map(\.rawValue).sorted().joined(separator: ",") + ":"
                + measurements.map { $0.map { String($0) } ?? "nil" }.joined(separator: ",")
        }
    }
    var overrides: [String: Override] = [:]
    // WorkoutRoutineSet has no distance attribute. Keep its target by stable set UUID.
    var routineDistances: [String: DistanceTarget] = [:]
    // Optional for archives written before logger provenance was tracked.
    // Sync field ownership and frozen plan targets. Logged measurements stay
    // in the workout store.
    var loggerFields: [String: LoggerFields]? = nil
    var loggerWorkoutID: UUID? = nil
    var loggerWorkoutStartedAt: TimeInterval? = nil

    static let cache = DefaultsValueCache<Self>(key: storageKey, notification: didChangeNotification) { data in
        data.flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }

    // Receipt clocks live separately so timestamp-only merges never invalidate
    // views observing the content cache. Keep the matching values alongside the
    // clocks so a later replacement cannot inherit an unrelated old watermark.
    private static let mergeWatermarks = DefaultsValueCache<Self?>(
        key: storageKey + ".mergeWatermarks.v1", publishesChanges: false
    ) { data in
        data.flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        var stored = cache.load(defaults: defaults)
        if let watermarks = mergeWatermarks.load(defaults: defaults) {
            for (key, entry) in stored.overrides {
                if let watermark = watermarks.overrides[key], watermark.type == entry.type,
                   watermark.updatedAt > entry.updatedAt {
                    stored.overrides[key] = watermark
                }
            }
            for (key, entry) in stored.routineDistances {
                if let watermark = watermarks.routineDistances[key], watermark.meters == entry.meters,
                   watermark.updatedAt > entry.updatedAt {
                    stored.routineDistances[key] = watermark
                }
            }
            for (key, entry) in stored.loggerFields ?? [:] where stored.loggerWorkoutID == watermarks.loggerWorkoutID {
                if let watermark = watermarks.loggerFields?[key], watermark.contentKey == entry.contentKey,
                   watermark.updatedAt > entry.updatedAt {
                    stored.loggerFields?[key] = watermark
                }
            }
        }
        return stored
    }
    static func override(for exerciseID: UUID?, defaults: UserDefaults = .standard) -> SetTrackingType? {
        exerciseID.flatMap { load(defaults: defaults).overrides[$0.uuidString]?.type }
    }
    static func setOverride(_ type: SetTrackingType, for exerciseID: UUID, defaults: UserDefaults = .standard) {
        SyncedPreferenceStorage.lock.lock()
        defer { SyncedPreferenceStorage.lock.unlock() }
        var preferences = load(defaults: defaults)
        guard preferences.overrides[exerciseID.uuidString]?.type != type else { return }
        preferences.overrides[exerciseID.uuidString] = Override(type: type, updatedAt: Date().timeIntervalSince1970)
        preferences.save(defaults: defaults)
        NotificationCenter.default.post(name: didChangeNotification, object: defaults)
    }
    static func routineDistance(for setID: UUID?, defaults: UserDefaults = .standard) -> Double? {
        guard let setID, let value = load(defaults: defaults).routineDistances[setID.uuidString]?.meters, value > 0 else { return nil }
        return value
    }
    static func setRoutineDistance(_ meters: Double?, for setID: UUID, defaults: UserDefaults = .standard) {
        SyncedPreferenceStorage.lock.lock()
        defer { SyncedPreferenceStorage.lock.unlock() }
        let value = meters.map { $0.isFinite ? max($0, 0) : 0 } ?? 0
        var preferences = load(defaults: defaults)
        guard (preferences.routineDistances[setID.uuidString]?.meters ?? 0) != value else { return }
        preferences.routineDistances[setID.uuidString] = DistanceTarget(meters: value, updatedAt: Date().timeIntervalSince1970)
        preferences.save(defaults: defaults)
        NotificationCenter.default.post(name: didChangeNotification, object: defaults)
    }
    static func loggerFields(for setID: UUID?, defaults: UserDefaults = .standard) -> Set<SetTrackingType.Column>? {
        setID.flatMap { load(defaults: defaults).loggerFields?[$0.uuidString]?.fields }
    }
    /// There is one active workout. A new session replaces the old provenance
    /// rather than growing every subsequent Watch preference payload forever.
    static func beginLoggerSession(workoutID: UUID?, startedAt: Date?, defaults: UserDefaults = .standard) {
        guard let workoutID else { return }
        SyncedPreferenceStorage.lock.lock()
        defer { SyncedPreferenceStorage.lock.unlock() }
        var preferences = load(defaults: defaults)
        guard preferences.loggerWorkoutID != workoutID else { return }
        preferences.loggerWorkoutID = workoutID
        preferences.loggerWorkoutStartedAt = (startedAt ?? Date()).timeIntervalSince1970
        preferences.loggerFields = nil
        preferences.save(defaults: defaults)
        NotificationCenter.default.post(name: didChangeNotification, object: defaults)
    }
    static func setLoggerFields(_ fields: Set<SetTrackingType.Column>, for setID: UUID?,
                                targets: SetValuePrefill.Values? = nil, defaults: UserDefaults = .standard) {
        guard let setID else { return }
        SyncedPreferenceStorage.lock.lock()
        defer { SyncedPreferenceStorage.lock.unlock() }
        var preferences = load(defaults: defaults)
        let savedTargets = targets ?? preferences.loggerFields?[setID.uuidString]?.targets
        guard preferences.loggerFields?[setID.uuidString]?.fields != fields ||
                preferences.loggerFields?[setID.uuidString]?.targets != savedTargets else { return }
        if preferences.loggerFields == nil { preferences.loggerFields = [:] }
        preferences.loggerFields?[setID.uuidString] = LoggerFields(fields: fields, targets: savedTargets,
                                                                  updatedAt: Date().timeIntervalSince1970)
        preferences.save(defaults: defaults)
        NotificationCenter.default.post(name: didChangeNotification, object: defaults)
    }
    static func markLoggerField(_ field: SetTrackingType.Column, for setID: UUID?) {
        SyncedPreferenceStorage.lock.lock()
        defer { SyncedPreferenceStorage.lock.unlock() }
        var fields = loggerFields(for: setID) ?? []
        fields.insert(field)
        setLoggerFields(fields, for: setID)
    }
    var isEmpty: Bool { overrides.isEmpty && routineDistances.isEmpty && (loggerFields?.isEmpty ?? true) && loggerWorkoutID == nil }
    var dictionaryRepresentation: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let payload = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return [Self.payloadKey: payload]
    }
    init() {}
    init?(payload: [String: Any]) {
        guard let value = payload[Self.payloadKey], JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let result = try? JSONDecoder().decode(Self.self, from: data),
              result.overrides.values.allSatisfy({ $0.updatedAt.isFinite && $0.updatedAt >= 0 }),
              result.routineDistances.values.allSatisfy({ $0.meters.isFinite && $0.meters >= 0 && $0.updatedAt.isFinite && $0.updatedAt >= 0 }),
              (result.loggerFields ?? [:]).values.allSatisfy({ $0.updatedAt.isFinite && $0.updatedAt >= 0 }),
              result.loggerWorkoutStartedAt.map({ $0.isFinite && $0 >= 0 }) ?? true else { return nil }
        self = result
    }
    func merging(_ incoming: Self) -> Self {
        var result = self
        result.overrides.merge(incoming.overrides) { local, remote in
            if local.updatedAt != remote.updatedAt { return remote.updatedAt > local.updatedAt ? remote : local }
            return remote.type.rawValue > local.type.rawValue ? remote : local
        }
        result.routineDistances.merge(incoming.routineDistances) { local, remote in
            if local.updatedAt != remote.updatedAt { return remote.updatedAt > local.updatedAt ? remote : local }
            return remote.meters > local.meters ? remote : local
        }
        let sameSession = loggerWorkoutID == incoming.loggerWorkoutID
        let incomingSessionWins = (incoming.loggerWorkoutStartedAt ?? 0) > (loggerWorkoutStartedAt ?? 0) ||
            ((incoming.loggerWorkoutStartedAt ?? 0) == (loggerWorkoutStartedAt ?? 0) &&
             (incoming.loggerWorkoutID?.uuidString ?? "") > (loggerWorkoutID?.uuidString ?? ""))
        if !sameSession, incomingSessionWins {
            result.loggerWorkoutID = incoming.loggerWorkoutID
            result.loggerWorkoutStartedAt = incoming.loggerWorkoutStartedAt
        }
        var fields = (!sameSession && incomingSessionWins ? incoming.loggerFields : loggerFields) ?? [:]
        fields.merge(sameSession ? incoming.loggerFields ?? [:] : [:]) { local, remote in
            var merged = remote.updatedAt > local.updatedAt ||
                (remote.updatedAt == local.updatedAt && remote.contentKey > local.contentKey) ? remote : local
            // Ownership only grows during a session. A delayed initialization
            // or concurrent edit on the other device cannot untype a field.
            merged.fields.formUnion(local.fields)
            merged.fields.formUnion(remote.fields)
            merged.targets = merged.targets ?? local.targets ?? remote.targets
            return merged
        }
        result.loggerFields = fields.isEmpty ? nil : fields
        return result
    }
    func save(defaults: UserDefaults = .standard) {
        SyncedPreferenceStorage.lock.lock()
        defer { SyncedPreferenceStorage.lock.unlock() }
        let stored = Self.load(defaults: defaults)
        if hasSameContent(as: stored) {
            let merged = stored.merging(self)
            guard merged != stored, let data = try? JSONEncoder().encode(merged) else { return }
            Self.mergeWatermarks.store(merged, data: data, defaults: defaults)
            return
        }
        guard let data = try? JSONEncoder().encode(self) else { return }
        Self.cache.store(self, data: data, defaults: defaults)
    }

    func hasSameContent(as other: Self) -> Bool {
        overrides.mapValues(\.type) == other.overrides.mapValues(\.type) &&
            routineDistances.mapValues(\.meters) == other.routineDistances.mapValues(\.meters) &&
            loggerWorkoutID == other.loggerWorkoutID &&
            (loggerFields ?? [:]).mapValues(\.contentKey) == (other.loggerFields ?? [:]).mapValues(\.contentKey)
    }
}
