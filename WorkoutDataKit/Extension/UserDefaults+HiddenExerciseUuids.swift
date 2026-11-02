//
//  UserDefaults+HiddenExerciseUuids.swift
//  Iron
//
//  Created by Karim Abou Zeid on 15.10.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import Foundation

extension UserDefaults {
    static let hiddenExercisesDidChangeNotification = Notification.Name("hiddenExercisesDidChange")
    enum HiddenExerciseUuidsKeys: String {
        case hiddenExerciseIds // TODO: previous name, remove in future
        case hiddenExerciseUuids
    }
    
    var hiddenExerciseUuids: [UUID] {
        set {
            HiddenExerciseUUIDCache.shared.store(newValue, defaults: self)
        }
        get {
            HiddenExerciseUUIDCache.shared.load(defaults: self)
        }
    }

    /// Refresh once at a catalog request boundary. didChangeNotification only
    /// covers this process, so a surviving intents/widget process must re-read.
    func refreshedHiddenExerciseUuids() -> [UUID] {
        HiddenExerciseUUIDCache.shared.refresh(defaults: self)
    }
}

/// The library asks about visibility for every row. Notifications and catalog
/// request boundaries inspect defaults; individual row checks stay cached.
private final class HiddenExerciseUUIDCache {
    static let shared = HiddenExerciseUUIDCache()
    private let lock = NSRecursiveLock()
    private let key = UserDefaults.HiddenExerciseUuidsKeys.hiddenExerciseUuids.rawValue
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var observer: NSObjectProtocol?

    private final class Entry {
        weak var defaults: UserDefaults?
        var strings: [String]?
        var uuids: [UUID]

        init(defaults: UserDefaults, strings: [String]?) {
            self.defaults = defaults
            self.strings = strings
            uuids = strings?.compactMap(UUID.init(uuidString:)) ?? []
        }
    }

    private init() {
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                          object: nil, queue: nil) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func load(defaults: UserDefaults) -> [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return entry(for: defaults).uuids
    }

    func refresh(defaults: UserDefaults) -> [UUID] {
        lock.lock()
        let entry = entry(for: defaults)
        let changed = refresh(entry, defaults: defaults)
        let uuids = entry.uuids
        lock.unlock()
        if changed {
            NotificationCenter.default.post(name: UserDefaults.hiddenExercisesDidChangeNotification, object: defaults)
        }
        return uuids
    }

    func store(_ uuids: [UUID], defaults: UserDefaults) {
        lock.lock()
        let entry = entry(for: defaults)
        let changed = entry.uuids != uuids
        entry.strings = uuids.map(\.uuidString)
        entry.uuids = uuids
        lock.unlock()
        defaults.set(uuids.map(\.uuidString), forKey: key)
        if changed {
            NotificationCenter.default.post(name: UserDefaults.hiddenExercisesDidChangeNotification, object: defaults)
        }
    }

    private func entry(for defaults: UserDefaults) -> Entry {
        let id = ObjectIdentifier(defaults)
        if let entry = entries[id], entry.defaults === defaults { return entry }
        entries = entries.filter { $0.value.defaults != nil }
        let entry = Entry(defaults: defaults, strings: defaults.array(forKey: key) as? [String])
        entries[id] = entry
        return entry
    }

    private func refresh() {
        lock.lock()
        var changedDefaults: [UserDefaults] = []
        for entry in entries.values {
            guard let defaults = entry.defaults else { continue }
            if refresh(entry, defaults: defaults) { changedDefaults.append(defaults) }
        }
        lock.unlock()
        for defaults in changedDefaults {
            NotificationCenter.default.post(name: UserDefaults.hiddenExercisesDidChangeNotification, object: defaults)
        }
    }

    private func refresh(_ entry: Entry, defaults: UserDefaults) -> Bool {
        let strings = defaults.array(forKey: key) as? [String]
        guard strings != entry.strings else { return false }
        let uuids = strings?.compactMap(UUID.init(uuidString:)) ?? []
        let changed = uuids != entry.uuids
        entry.strings = strings
        entry.uuids = uuids
        return changed
    }
}
