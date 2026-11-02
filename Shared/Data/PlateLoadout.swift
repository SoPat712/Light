import Foundation

/// JSON storage shared by the phone and watch plate calculators.
enum PlateCalculatorStorageKeys {
    static let inventory = "plateCalculator.inventory.v1"
    static let loadouts = "plateCalculator.loadouts.v1"
    /// Local edits only. Applying a peer's snapshot must not echo it back.
    static let didChangeNotification = Notification.Name("plateCalculatorPreferencesDidChange")

    static let inventoryCache = DefaultsValueCache<PlateInventory?>(key: inventory, notification: didChangeNotification) { data in
        data.flatMap { try? JSONDecoder().decode(PlateInventory.self, from: $0) }
    }
    static let loadoutsCache = DefaultsValueCache<[String: PlateLoadout]>(key: loadouts, notification: didChangeNotification) { data in
        guard let data, let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return PlateLoadout.loadouts(from: payload)
    }

    // Matching content accompanies receipt clocks so replacements cannot inherit
    // a watermark for a different value. This cache never publishes view changes.
    static let mergeWatermarks = DefaultsValueCache<PlateCalculatorPreferences?>(
        key: "plateCalculator.mergeWatermarks.v1", publishesChanges: false
    ) { data in
        guard let data, let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return PlateCalculatorPreferences(payload: payload)
    }
}

/// Plate diameters on the phone and Watch diagrams, as a fraction of the largest plate.
/// Change plates are much smaller than the big plates, as they are in a gym.
enum PlateProportions {
    static func height(for weight: Double, unit: WatchWorkoutWeightUnit) -> CGFloat {
        let plates: [Double] = unit == .kilogram ? [25, 20, 15, 10, 5, 2.5, 1.25, 0.5] : [45, 35, 25, 10, 5, 2.5, 1.25]
        let rank = plates.firstIndex(where: { weight >= $0 }) ?? plates.count
        let heights: [CGFloat] = [1, 0.91, 0.8, 0.59, 0.48, 0.4, 0.35, 0.31, 0.28]
        return heights[min(rank, heights.count - 1)]
    }
}

private enum PlateCalculatorValues {
    // Keeps malformed persisted values safely within integer and floating-point
    // arithmetic limits, well beyond any practical gym load.
    static let maximumWeight = 1_000_000_000_000.0

    static func sanitizedWeight(_ weight: Double) -> Double {
        guard weight.isFinite else { return 0 }
        return min(max(weight, 0), maximumWeight)
    }

    static func sanitizedTimestamp(_ timestamp: TimeInterval) -> TimeInterval {
        timestamp.isFinite && timestamp >= 0 ? timestamp : 0
    }

    static func nextTimestamp(after timestamp: TimeInterval) -> TimeInterval {
        let next = timestamp.nextUp
        return max(Date().timeIntervalSince1970, next.isFinite ? next : timestamp)
    }
}

struct PlateInventory: Codable, Equatable {
    private var kilogramPlates: [Double]
    private var poundPlates: [Double]
    private(set) var updatedAt: TimeInterval = 0

    init() {
        kilogramPlates = [25, 20, 15, 10, 5, 2.5, 1.25, 0.5]
        poundPlates = [45, 35, 25, 10, 5, 2.5, 1.25]
    }

    static func availablePlates(for unit: WatchWorkoutWeightUnit) -> [Double] {
        switch unit {
        case .kilogram:
            return [25, 20, 15, 10, 5, 2.5, 2, 1.25, 1, 0.5]
        case .pound:
            return [55, 45, 35, 25, 10, 5, 2.5, 1.25, 0.75, 0.25]
        }
    }

    func enabledPlates(for unit: WatchWorkoutWeightUnit) -> [Double] {
        switch unit {
        case .kilogram: return kilogramPlates
        case .pound: return poundPlates
        }
    }

    mutating func setEnabled(_ enabled: Bool, weight: Double, unit: WatchWorkoutWeightUnit) {
        guard Self.availablePlates(for: unit).contains(weight) else { return }
        var plates = enabledPlates(for: unit)
        if enabled {
            plates.append(weight)
        } else {
            plates.removeAll { $0 == weight }
        }
        switch unit {
        case .kilogram: kilogramPlates = Self.sanitized(plates, unit: unit)
        case .pound: poundPlates = Self.sanitized(plates, unit: unit)
        }
    }

    func isEnabled(_ weight: Double, unit: WatchWorkoutWeightUnit) -> Bool {
        enabledPlates(for: unit).contains(weight)
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        PlateCalculatorPreferences.load(defaults: defaults).inventory ?? Self()
    }

    func save(defaults: UserDefaults = .standard) {
        SyncedPreferenceStorage.lock.lock()
        defer { SyncedPreferenceStorage.lock.unlock() }
        let stored = PlateCalculatorPreferences.load(defaults: defaults).inventory
        guard stored?.kilogramPlates != kilogramPlates || stored?.poundPlates != poundPlates else { return }
        var inventory = self
        inventory.updatedAt = PlateCalculatorValues.nextTimestamp(after: max(updatedAt, stored?.updatedAt ?? 0))
        guard let data = try? JSONEncoder().encode(inventory) else { return }
        PlateCalculatorStorageKeys.inventoryCache.store(inventory, data: data, defaults: defaults)
        NotificationCenter.default.post(name: PlateCalculatorStorageKeys.didChangeNotification, object: defaults)
    }

    var dictionaryRepresentation: [String: Any] {
        ["kilogramPlates": kilogramPlates, "poundPlates": poundPlates, "updatedAt": updatedAt]
    }

    func hasSameContent(as other: Self) -> Bool {
        kilogramPlates == other.kilogramPlates && poundPlates == other.poundPlates
    }

    init?(payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let inventory = try? JSONDecoder().decode(Self.self, from: data) else {
            return nil
        }
        self = inventory
    }

    private enum CodingKeys: String, CodingKey {
        case kilogramPlates, poundPlates, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kilogramPlates = Self.sanitized(
            try container.decode([Double].self, forKey: .kilogramPlates),
            unit: .kilogram
        )
        poundPlates = Self.sanitized(
            try container.decode([Double].self, forKey: .poundPlates),
            unit: .pound
        )
        // Legacy values predate all timestamped edits; decoding must not make
        // an old snapshot look newer every time it is received.
        updatedAt = PlateCalculatorValues.sanitizedTimestamp(
            try container.decodeIfPresent(TimeInterval.self, forKey: .updatedAt) ?? 0
        )
    }

    private static func sanitized(_ plates: [Double], unit: WatchWorkoutWeightUnit) -> [Double] {
        // Starting with the catalog also removes duplicates and imposes the
        // descending order expected by both the picker and the greedy solver.
        availablePlates(for: unit).filter { plates.contains($0) }
    }
}

struct PlateLoadout: Codable, Equatable {
    enum Mode: Codable, Equatable {
        case barbell(Double)
        case noBar
        case machine(Double)

        fileprivate var sanitized: Self {
            switch self {
            case let .barbell(weight):
                return .barbell(PlateCalculatorValues.sanitizedWeight(weight))
            case .noBar:
                return .noBar
            case let .machine(weight):
                return .machine(PlateCalculatorValues.sanitizedWeight(weight))
            }
        }

        private enum CodingKeys: String, CodingKey {
            case kind, weight
        }

        private enum Kind: String, Codable {
            case barbell, noBar, machine
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .barbell:
                self = .barbell(PlateCalculatorValues.sanitizedWeight(
                    try container.decode(Double.self, forKey: .weight)
                ))
            case .noBar:
                self = .noBar
            case .machine:
                self = .machine(PlateCalculatorValues.sanitizedWeight(
                    try container.decode(Double.self, forKey: .weight)
                ))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch sanitized {
            case let .barbell(weight):
                try container.encode(Kind.barbell, forKey: .kind)
                try container.encode(weight, forKey: .weight)
            case .noBar:
                try container.encode(Kind.noBar, forKey: .kind)
            case let .machine(weight):
                try container.encode(Kind.machine, forKey: .kind)
                try container.encode(weight, forKey: .weight)
            }
        }
    }

    enum LoadedSides: String, Codable, CaseIterable {
        case both, one

        var count: Int {
            switch self {
            case .both: return 2
            case .one: return 1
            }
        }
    }

    var mode: Mode {
        didSet { mode = mode.sanitized }
    }
    var loadedSides: LoadedSides
    var unit: WatchWorkoutWeightUnit
    private(set) var updatedAt: TimeInterval

    init(mode: Mode, loadedSides: LoadedSides = .both, unit: WatchWorkoutWeightUnit, updatedAt: TimeInterval = 0) {
        self.mode = mode.sanitized
        self.loadedSides = loadedSides
        self.unit = unit
        self.updatedAt = PlateCalculatorValues.sanitizedTimestamp(updatedAt)
    }

    static func standard(for unit: WatchWorkoutWeightUnit) -> Self {
        Self(mode: .barbell(unit == .kilogram ? 20 : 45), unit: unit)
    }

    var baseWeight: Double {
        switch mode {
        case let .barbell(weight), let .machine(weight):
            return PlateCalculatorValues.sanitizedWeight(weight)
        case .noBar:
            return 0
        }
    }

    func converted(to newUnit: WatchWorkoutWeightUnit) -> Self {
        guard newUnit != unit else { return self }
        // The international avoirdupois pound is exactly 0.45359237 kg.
        let convertedWeight = newUnit == .kilogram
            ? baseWeight * 0.45359237
            : baseWeight / 0.45359237
        let convertedMode: Mode
        switch mode {
        case .barbell: convertedMode = .barbell(convertedWeight)
        case .noBar: convertedMode = .noBar
        case .machine: convertedMode = .machine(convertedWeight)
        }
        return Self(mode: convertedMode, loadedSides: loadedSides, unit: newUnit, updatedAt: updatedAt)
    }

    static func load(
        exerciseKey: String?,
        unit: WatchWorkoutWeightUnit,
        defaults: UserDefaults = .standard
    ) -> Self {
        guard let exerciseKey, let loadout = loadAll(defaults: defaults)[exerciseKey] else {
            return standard(for: unit)
        }
        return loadout.converted(to: unit)
    }

    func save(exerciseKey: String?, defaults: UserDefaults = .standard) {
        SyncedPreferenceStorage.lock.lock()
        defer { SyncedPreferenceStorage.lock.unlock() }
        guard let exerciseKey else { return }
        var loadouts = Self.loadAll(defaults: defaults)
        let stored = loadouts[exerciseKey]
        guard stored?.mode != mode || stored?.loadedSides != loadedSides || stored?.unit != unit else { return }
        var loadout = self
        loadout.updatedAt = PlateCalculatorValues.nextTimestamp(after: max(updatedAt, stored?.updatedAt ?? 0))
        loadouts[exerciseKey] = loadout
        Self.saveAll(loadouts, defaults: defaults)
        NotificationCenter.default.post(name: PlateCalculatorStorageKeys.didChangeNotification, object: defaults)
    }

    /// Returns the complete exercise-keyed map in its stored units. Invalid
    /// individual entries are omitted without discarding other exercises.
    static func loadAll(defaults: UserDefaults = .standard) -> [String: Self] {
        PlateCalculatorPreferences.load(defaults: defaults).loadouts
    }

    /// Replaces the complete map. Use `save(exerciseKey:defaults:)` to merge one
    /// exercise instead; this API is intended for whole-map sync snapshots.
    static func saveAll(_ loadouts: [String: Self], defaults: UserDefaults = .standard) {
        SyncedPreferenceStorage.lock.lock()
        defer { SyncedPreferenceStorage.lock.unlock() }
        guard let data = try? JSONEncoder().encode(loadouts) else { return }
        PlateCalculatorStorageKeys.loadoutsCache.store(loadouts, data: data, defaults: defaults)
    }

    /// Property-list-compatible payload for a complete loadout sync snapshot.
    static func dictionaryRepresentation(for loadouts: [String: Self]) -> [String: Any] {
        loadouts.mapValues { $0.dictionaryRepresentation }
    }

    /// Decodes a complete sync snapshot, omitting malformed individual entries.
    static func loadouts(from payload: [String: Any]) -> [String: Self] {
        payload.reduce(into: [:]) { result, entry in
            guard let value = entry.value as? [String: Any],
                  let loadout = Self(payload: value) else { return }
            result[entry.key] = loadout
        }
    }

    var dictionaryRepresentation: [String: Any] {
        let modePayload: [String: Any]
        switch mode {
        case .barbell: modePayload = ["kind": "barbell", "weight": baseWeight]
        case .noBar: modePayload = ["kind": "noBar"]
        case .machine: modePayload = ["kind": "machine", "weight": baseWeight]
        }
        return [
            "mode": modePayload,
            "loadedSides": loadedSides.rawValue,
            "unit": unit.rawValue,
            "updatedAt": updatedAt
        ]
    }

    func hasSameContent(as other: Self) -> Bool {
        mode == other.mode && loadedSides == other.loadedSides && unit == other.unit
    }

    init?(payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let loadout = try? JSONDecoder().decode(Self.self, from: data) else {
            return nil
        }
        self = loadout
    }

    private enum CodingKeys: String, CodingKey {
        case mode, loadedSides, unit, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mode: try container.decode(Mode.self, forKey: .mode),
            loadedSides: try container.decode(LoadedSides.self, forKey: .loadedSides),
            unit: try container.decode(WatchWorkoutWeightUnit.self, forKey: .unit),
            updatedAt: try container.decodeIfPresent(TimeInterval.self, forKey: .updatedAt) ?? 0
        )
    }
}

/// A union of saved preferences, independent of workout snapshots. An unsaved
/// default inventory is absent so it cannot overwrite a peer's gym inventory.
struct PlateCalculatorPreferences: Equatable {
    private(set) var inventory: PlateInventory?
    private(set) var loadouts: [String: PlateLoadout]

    init(inventoryData: Data?, loadoutsData: Data?) {
        inventory = inventoryData.flatMap { try? JSONDecoder().decode(PlateInventory.self, from: $0) }
        let payload = loadoutsData.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        loadouts = payload.map { PlateLoadout.loadouts(from: $0) } ?? [:]
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        var stored = Self(inventory: PlateCalculatorStorageKeys.inventoryCache.load(defaults: defaults),
                          loadouts: PlateCalculatorStorageKeys.loadoutsCache.load(defaults: defaults))
        if let watermarks = PlateCalculatorStorageKeys.mergeWatermarks.load(defaults: defaults) {
            if let inventory = stored.inventory, let watermark = watermarks.inventory,
               watermark.hasSameContent(as: inventory), watermark.updatedAt > inventory.updatedAt {
                stored.inventory = watermark
            }
            for (key, loadout) in stored.loadouts {
                if let watermark = watermarks.loadouts[key], watermark.hasSameContent(as: loadout),
                   watermark.updatedAt > loadout.updatedAt {
                    stored.loadouts[key] = watermark
                }
            }
        }
        return stored
    }

    private init(inventory: PlateInventory?, loadouts: [String: PlateLoadout]) {
        self.inventory = inventory
        self.loadouts = loadouts
    }

    init?(payload: [String: Any]) {
        guard payload[PayloadKey.plateInventory] != nil || payload[PayloadKey.plateLoadouts] != nil else { return nil }
        inventory = (payload[PayloadKey.plateInventory] as? [String: Any]).flatMap { PlateInventory(payload: $0) }
        loadouts = (payload[PayloadKey.plateLoadouts] as? [String: Any]).map { PlateLoadout.loadouts(from: $0) } ?? [:]
    }

    var isEmpty: Bool { inventory == nil && loadouts.isEmpty }

    func hasSameContent(as other: Self) -> Bool {
        let sameInventory: Bool
        switch (inventory, other.inventory) {
        case (nil, nil): sameInventory = true
        case let (local?, remote?): sameInventory = local.hasSameContent(as: remote)
        default: sameInventory = false
        }
        return sameInventory && hasSameLoadouts(as: other)
    }

    private func hasSameLoadouts(as other: Self) -> Bool {
        loadouts.count == other.loadouts.count && loadouts.allSatisfy { key, value in
            other.loadouts[key].map { value.hasSameContent(as: $0) } == true
        }
    }

    var dictionaryRepresentation: [String: Any] {
        var payload: [String: Any] = [PayloadKey.plateLoadouts: PlateLoadout.dictionaryRepresentation(for: loadouts)]
        if let inventory { payload[PayloadKey.plateInventory] = inventory.dictionaryRepresentation }
        return payload
    }

    func merging(_ incoming: Self) -> Self {
        var merged = self
        if let remote = incoming.inventory {
            if let local = inventory {
                if Self.shouldReplace(localTimestamp: local.updatedAt, remoteTimestamp: remote.updatedAt,
                                      localPayload: local.dictionaryRepresentation, remotePayload: remote.dictionaryRepresentation) {
                    merged.inventory = remote
                }
            } else {
                merged.inventory = remote
            }
        }
        for (key, remote) in incoming.loadouts {
            if let local = loadouts[key],
               !Self.shouldReplace(localTimestamp: local.updatedAt, remoteTimestamp: remote.updatedAt,
                                   localPayload: local.dictionaryRepresentation, remotePayload: remote.dictionaryRepresentation) {
                continue
            }
            merged.loadouts[key] = remote
        }
        return merged
    }

    /// Persists a merged peer snapshot without stamping it or notifying the
    /// local-edit observers. Repeated messages and context echoes are no-ops.
    func save(defaults: UserDefaults = .standard) {
        SyncedPreferenceStorage.lock.lock()
        defer { SyncedPreferenceStorage.lock.unlock() }
        let stored = Self.load(defaults: defaults)
        if let inventory, stored.inventory.map({ inventory.hasSameContent(as: $0) }) != true,
           let data = try? JSONEncoder().encode(inventory) {
            PlateCalculatorStorageKeys.inventoryCache.store(inventory, data: data, defaults: defaults)
        }
        if !hasSameLoadouts(as: stored) {
            PlateLoadout.saveAll(loadouts, defaults: defaults)
        }
        let persisted = Self.load(defaults: defaults)
        let merged = persisted.merging(self)
        if merged != persisted, merged.hasSameContent(as: persisted),
           let data = try? JSONSerialization.data(withJSONObject: merged.dictionaryRepresentation, options: [.sortedKeys]) {
            PlateCalculatorStorageKeys.mergeWatermarks.store(merged, data: data, defaults: defaults)
        }
    }

    private static func shouldReplace(localTimestamp: TimeInterval, remoteTimestamp: TimeInterval,
                                      localPayload: [String: Any], remotePayload: [String: Any]) -> Bool {
        if localTimestamp != remoteTimestamp { return remoteTimestamp > localTimestamp }
        // Deterministic ties make simultaneous/legacy edits converge on both
        // devices, rather than repeatedly returning different local winners.
        guard let local = try? JSONSerialization.data(withJSONObject: localPayload, options: [.sortedKeys]),
              let remote = try? JSONSerialization.data(withJSONObject: remotePayload, options: [.sortedKeys]) else { return false }
        return local.lexicographicallyPrecedes(remote)
    }
}

/// One owner for all small Watch preferences on either device. Decoding, merging
/// and encoding run on the connection's serial utility queue. Only local edits
/// and connectivity transitions schedule a send; receiving never does.
final class WatchPreferenceSyncManager {
    enum Change: Hashable { case plates, tracking, notes }

    private let defaults: UserDefaults
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Bool>()
    private let notificationCenter: NotificationCenter
    private let debounceInterval: TimeInterval
    private let transmit: ([String: Any]) -> Bool
    private let didChangeLocally: (Set<Change>) -> Void
    private var observers: [NSObjectProtocol] = []
    private var pendingSend: DispatchWorkItem?
    private var pendingChanges = Set<Change>()
    private var lastSentContent: Data?
    private var retryAttempt = 0
    private var applyingRemote = false
    // Receipts also persist silent merge watermarks; these snapshots keep the
    // current connection's already merged view handy between messages.
    private var observedPlates: PlateCalculatorPreferences?
    private var observedTracking: SetTrackingPreferences?
    private var observedNotes: ExerciseNotes?

    init(defaults: UserDefaults = .standard,
         queue: DispatchQueue,
         notificationCenter: NotificationCenter = .default,
         debounceInterval: TimeInterval = 0.75,
         transmit: @escaping ([String: Any]) -> Bool,
         didChangeLocally: @escaping (Set<Change>) -> Void = { _ in }) {
        self.defaults = defaults
        self.queue = queue
        self.notificationCenter = notificationCenter
        self.debounceInterval = debounceInterval
        self.transmit = transmit
        self.didChangeLocally = didChangeLocally
        queue.setSpecific(key: queueKey, value: true)
        let names: [(Notification.Name, Change)] = [
            (PlateCalculatorStorageKeys.didChangeNotification, .plates),
            (SetTrackingPreferences.didChangeNotification, .tracking),
            (ExerciseNotes.didChangeNotification, .notes)
        ]
        for (name, change) in names {
            observers.append(notificationCenter.addObserver(forName: name, object: defaults, queue: nil) { [weak self] _ in
                guard let self else { return }
                if DispatchQueue.getSpecific(key: self.queueKey) == true {
                    self.localChange(change)
                } else {
                    self.queue.async { self.localChange(change) }
                }
            })
        }
    }

    deinit {
        pendingSend?.cancel()
        observers.forEach { notificationCenter.removeObserver($0) }
    }

    func requestSync() {
        queue.async {
            self.retryAttempt = 0
            self.scheduleSend()
        }
    }

    func resetTransmission() {
        queue.async { self.lastSentContent = nil }
    }

    /// Called by the connection's receive queue before applying workout data.
    func applyReceived(_ payload: [String: Any]) {
        dispatchPrecondition(condition: .onQueue(queue))
        SyncedPreferenceStorage.lock.lock()
        defer { SyncedPreferenceStorage.lock.unlock() }
        applyingRemote = true
        defer { applyingRemote = false }
        if let incoming = PlateCalculatorPreferences(payload: payload) {
            let stored = PlateCalculatorPreferences.load(defaults: defaults)
            let merged = stored.merging(observedPlates ?? stored).merging(incoming)
            merged.save(defaults: defaults)
            observedPlates = merged
        }
        if let incoming = SetTrackingPreferences(payload: payload) {
            let stored = SetTrackingPreferences.load(defaults: defaults)
            let merged = stored.merging(observedTracking ?? stored).merging(incoming)
            merged.save(defaults: defaults)
            observedTracking = merged
        }
        if let incoming = ExerciseNotes(payload: payload) {
            let stored = ExerciseNotes.load(defaults: defaults)
            let merged = stored.merging(observedNotes ?? stored).merging(incoming)
            merged.save(defaults: defaults)
            observedNotes = merged
        }
    }

    private func localChange(_ change: Change) {
        guard !applyingRemote else { return }
        retryAttempt = 0
        pendingChanges.insert(change)
        scheduleSend()
    }

    private func scheduleSend(after delay: TimeInterval? = nil) {
        pendingSend?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingSend = work
        queue.asyncAfter(deadline: .now() + (delay ?? debounceInterval), execute: work)
    }

    /// Also allows deterministic transport tests without timers or WCSession.
    func flush() {
        dispatchPrecondition(condition: .onQueue(queue))
        let hasPendingSend = pendingSend != nil
        pendingSend?.cancel()
        pendingSend = nil
        guard hasPendingSend, !applyingRemote else { return }
        let changes = pendingChanges
        pendingChanges.removeAll()
        if !changes.isEmpty {
            DispatchQueue.main.async { self.didChangeLocally(changes) }
        }
        let storedPlates = PlateCalculatorPreferences.load(defaults: defaults)
        let storedTracking = SetTrackingPreferences.load(defaults: defaults)
        let storedNotes = ExerciseNotes.load(defaults: defaults)
        let plates = storedPlates.merging(observedPlates ?? storedPlates)
        let tracking = storedTracking.merging(observedTracking ?? storedTracking)
        let notes = storedNotes.merging(observedNotes ?? storedNotes)
        guard !plates.isEmpty || !tracking.isEmpty || !notes.isEmpty else { return }
        var payload = plates.dictionaryRepresentation
        payload.merge(tracking.dictionaryRepresentation) { _, new in new }
        payload.merge(notes.dictionaryRepresentation) { _, new in new }
        guard let content = WatchSyncContent.preferenceData(payload), content != lastSentContent else { return }
        if transmit(payload) {
            lastSentContent = content
            retryAttempt = 0
        } else if retryAttempt < 3 {
            let delay = [15.0, 30, 60][retryAttempt]
            retryAttempt += 1
            scheduleSend(after: delay)
        }
    }
}

/// Content comparisons deliberately exclude merge clocks, never workout dates
/// or acknowledgements. They are shared by both transports and their tests.
enum WatchSyncContent {
    static func preferenceData(_ payload: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: withoutPreferenceTimestamps(payload), options: [.sortedKeys])
    }

    private static func withoutPreferenceTimestamps(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.filter { $0.key != "updatedAt" }.mapValues(withoutPreferenceTimestamps)
        }
        if let array = value as? [Any] { return array.map(withoutPreferenceTimestamps) }
        return value
    }

    static func workoutContent(_ snapshot: WatchWorkoutSnapshot) -> WatchWorkoutSnapshot {
        var content = snapshot
        content.revision = 0
        content.updatedAt = Date(timeIntervalSince1970: 0)
        return content
    }

    static func workoutData(_ data: Data) -> Data? {
        guard var content = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        content.removeValue(forKey: "revision")
        content.removeValue(forKey: "updatedAt")
        return try? JSONSerialization.data(withJSONObject: content, options: [.sortedKeys])
    }

    static func contextsEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        func normalized(_ context: [String: Any]) -> [String: Any] {
            var content = context
            for key in [PayloadKey.plateInventory, PayloadKey.plateLoadouts,
                        SetTrackingPreferences.payloadKey, ExerciseNotes.payloadKey] {
                if let value = content[key] { content[key] = withoutPreferenceTimestamps(value) }
            }
            if let data = content[PayloadKey.workoutSnapshot] as? Data,
               let snapshotContent = workoutData(data) {
                content[PayloadKey.workoutSnapshot] = snapshotContent
            }
            return content
        }
        return NSDictionary(dictionary: normalized(lhs)).isEqual(to: normalized(rhs))
    }
}

struct PlateLoadSolution: Equatable {
    struct Plate: Equatable {
        let weight: Double
        let count: Int
    }

    let platesPerSide: [Plate]
    let loadedTotal: Double
    let shortfall: Double
    let plateWeightPerSide: Double
}

enum PlateLoadSolver {
    static func solve(
        target: Double,
        loadout: PlateLoadout,
        inventory: PlateInventory
    ) -> PlateLoadSolution {
        let target = PlateCalculatorValues.sanitizedWeight(target)
        let base = loadout.baseWeight
        let sides = Double(loadout.loadedSides.count)
        var remaining = max(target - base, 0) / sides
        var plates: [PlateLoadSolution.Plate] = []
        var plateWeightPerSide = 0.0
        let epsilon = max(1e-9, target.ulp * 4)

        for weight in inventory.enabledPlates(for: loadout.unit) {
            // The ceiling prevents integer conversion overflow even if this
            // code is reused on a platform with a smaller Int representation.
            let quotient = min(floor((remaining + epsilon) / weight), Double(Int.max / 4))
            guard quotient >= 1 else { continue }
            let count = Int(quotient)
            let plateWeight = weight * Double(count)
            plates.append(.init(weight: weight, count: count))
            plateWeightPerSide += plateWeight
            remaining = max(remaining - plateWeight, 0)
        }

        let loadedTotal = base + plateWeightPerSide * sides
        return PlateLoadSolution(
            platesPerSide: plates,
            loadedTotal: loadedTotal,
            shortfall: max(target - loadedTotal, 0),
            plateWeightPerSide: plateWeightPerSide
        )
    }

    static func targetStep(loadout: PlateLoadout, inventory: PlateInventory) -> Double {
        let smallest = inventory.enabledPlates(for: loadout.unit).last ?? 0.5
        return 2 * smallest * Double(loadout.loadedSides.count)
    }
}
