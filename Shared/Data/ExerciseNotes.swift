import Foundation

/// Exercise-wide cues shared by phone and Watch without a Core Data migration.
/// Nil text is retained as a deletion tombstone so an older peer cannot revive it.
struct ExerciseNotes: Codable, Equatable {
    static let storageKey = "exerciseNotes.v1"
    static let payloadKey = "exerciseNotes"
    static let didChangeNotification = Notification.Name("exerciseNotesDidChange")

    struct Entry: Codable, Equatable {
        var text: String?
        var updatedAt: TimeInterval
    }

    var entries: [String: Entry] = [:]

    init() {}

    static let cache = DefaultsValueCache<Self>(key: storageKey, notification: didChangeNotification) { data in
        guard let data, let notes = try? JSONDecoder().decode(Self.self, from: data), notes.isValid else { return Self() }
        return notes
    }

    private static let mergeWatermarks = DefaultsValueCache<Self?>(
        key: storageKey + ".mergeWatermarks.v1", publishesChanges: false
    ) { data in
        guard let data, let notes = try? JSONDecoder().decode(Self.self, from: data), notes.isValid else { return nil }
        return notes
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        var stored = cache.load(defaults: defaults)
        if let watermarks = mergeWatermarks.load(defaults: defaults) {
            for (key, entry) in stored.entries {
                if let watermark = watermarks.entries[key], watermark.text == entry.text,
                   watermark.updatedAt > entry.updatedAt {
                    stored.entries[key] = watermark
                }
            }
        }
        return stored
    }

    static func note(for exerciseID: UUID?, defaults: UserDefaults = .standard) -> String? {
        exerciseID.flatMap { load(defaults: defaults).entries[$0.uuidString]?.text }
    }

    /// Local edits publish once. Peer application uses `merging(_:).save(defaults:)`
    /// or `notify: false` to avoid sending the same update back to its origin.
    static func setNote(
        _ text: String?,
        for exerciseID: UUID,
        updatedAt: Date = Date(),
        defaults: UserDefaults = .standard,
        notify: Bool = true
    ) {
        SyncedPreferenceStorage.lock.lock()
        defer { SyncedPreferenceStorage.lock.unlock() }
        let timestamp = updatedAt.timeIntervalSince1970
        guard timestamp.isFinite, timestamp >= 0 else { return }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.flatMap { $0.isEmpty ? nil : $0 }
        let stored = load(defaults: defaults)
        guard !notify || stored.entries[exerciseID.uuidString]?.text != value else { return }
        var update = Self()
        update.entries[exerciseID.uuidString] = Entry(text: value, updatedAt: timestamp)
        let merged = stored.merging(update)
        guard merged != stored else { return }
        merged.save(defaults: defaults)
        if notify {
            NotificationCenter.default.post(name: didChangeNotification, object: defaults)
        }
    }

    var isEmpty: Bool { entries.isEmpty }

    var isValid: Bool {
        entries.allSatisfy { key, entry in
            UUID(uuidString: key)?.uuidString == key && entry.updatedAt.isFinite && entry.updatedAt >= 0
                && (entry.text.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true)
        }
    }

    var dictionaryRepresentation: [String: Any] {
        guard isValid, let data = try? JSONEncoder().encode(self),
              let payload = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return [Self.payloadKey: payload]
    }

    init?(payload: [String: Any]) {
        guard let value = payload[Self.payloadKey], JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let notes = try? JSONDecoder().decode(Self.self, from: data),
              notes.isValid else { return nil }
        self = notes
    }

    func merging(_ incoming: Self) -> Self {
        var result = self
        result.entries.merge(incoming.entries) { local, remote in
            if local.updatedAt != remote.updatedAt {
                return remote.updatedAt > local.updatedAt ? remote : local
            }
            // Deletion wins a simultaneous edit. Other ties use text order so
            // both devices converge regardless of their message arrival order.
            guard let localText = local.text else { return local }
            guard let remoteText = remote.text else { return remote }
            return remoteText > localText ? remote : local
        }
        return result
    }

    /// Saving a snapshot deliberately never publishes a local-edit notification.
    func save(defaults: UserDefaults = .standard) {
        SyncedPreferenceStorage.lock.lock()
        defer { SyncedPreferenceStorage.lock.unlock() }
        guard isValid else { return }
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
        entries.mapValues(\.text) == other.entries.mapValues(\.text)
    }
}

/// Preserves the exact plan-row identity after its exercise is logged in a workout.
/// This distinguishes repeated appearances of the same catalog exercise.
struct WorkoutRoutineNoteLinks: Codable, Equatable {
    static let storageKey = "workoutRoutineNoteLinks.v1"

    var links: [String: String] = [:]

    init() {}

    private static let cache = DefaultsValueCache<Self>(key: storageKey) { data in
        guard let data, let links = try? JSONDecoder().decode(Self.self, from: data), links.isValid else { return Self() }
        return links
    }

    var isValid: Bool {
        links.allSatisfy { workoutExerciseID, routineExerciseID in
            UUID(uuidString: workoutExerciseID)?.uuidString == workoutExerciseID
                && UUID(uuidString: routineExerciseID)?.uuidString == routineExerciseID
        }
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        cache.load(defaults: defaults)
    }

    static func routineExerciseID(for workoutExerciseID: UUID?, defaults: UserDefaults = .standard) -> UUID? {
        workoutExerciseID.flatMap { load(defaults: defaults).links[$0.uuidString] }.flatMap(UUID.init(uuidString:))
    }

    static func setRoutineExerciseID(
        _ routineExerciseID: UUID?,
        for workoutExerciseID: UUID,
        defaults: UserDefaults = .standard
    ) {
        SyncedPreferenceStorage.lock.lock()
        defer { SyncedPreferenceStorage.lock.unlock() }
        var stored = load(defaults: defaults)
        guard stored.links[workoutExerciseID.uuidString] != routineExerciseID?.uuidString else { return }
        stored.links[workoutExerciseID.uuidString] = routineExerciseID?.uuidString
        stored.save(defaults: defaults)
    }

    func save(defaults: UserDefaults = .standard) {
        SyncedPreferenceStorage.lock.lock()
        defer { SyncedPreferenceStorage.lock.unlock() }
        guard isValid, self != Self.load(defaults: defaults),
              let data = try? JSONEncoder().encode(self) else { return }
        Self.cache.store(self, data: data, defaults: defaults)
    }

    func merging(_ incoming: Self) -> Self {
        var result = self
        result.links.merge(incoming.links) { _, incoming in incoming }
        return result
    }
}
