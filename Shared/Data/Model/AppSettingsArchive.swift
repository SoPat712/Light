import Foundation
import CoreFoundation

/// Portable defaults domains, independent of the bundle ID and app-group name.
/// Only stored user choices are archived; absent keys retain the receiving app's defaults.
enum AppSettingsArchive {
    private enum Domain: String, CaseIterable {
        case standard, appGroup
    }

    private enum ValueType {
        case string, bool, integer, number, data, uuidStrings, plateInventory, plateLoadouts

        func accepts(_ value: Any) -> Bool {
            switch self {
            case .string: return value is String
            case .bool:
                guard let number = value as? NSNumber else { return false }
                return CFGetTypeID(number) == CFBooleanGetTypeID()
            case .integer:
                guard let number = value as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      !["f", "d"].contains(String(cString: number.objCType)) else { return false }
                return Int(number.stringValue) != nil
            case .number:
                guard let number = value as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
                return number.doubleValue.isFinite
            case .data: return value is Data
            case .uuidStrings:
                guard let strings = value as? [String] else { return false }
                return strings.allSatisfy { UUID(uuidString: $0) != nil }
            case .plateInventory:
                guard let data = value as? Data else { return false }
                return (try? JSONDecoder().decode(PlateInventory.self, from: data)) != nil
            case .plateLoadouts:
                guard let data = value as? Data,
                      let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
                return payload.values.allSatisfy {
                    ($0 as? [String: Any]).flatMap { PlateLoadout(payload: $0) } != nil
                }
            }
        }
    }

    // The sole export AND import allowlist. Do not infer it from the defaults
    // dictionary or SettingsKeys.allCases: those also contain device/debug state.
    private static let allowlist: [Domain: [String: ValueType]] = [
        .appGroup: [
            "weightUnit": .string,
            "ironAppearance": .string,
            "defaultRestTime": .number,
            "defaultRestTimeDumbbellBased": .number,
            "defaultRestTimeBarbellBased": .number,
            "keepRestTimerRunning": .bool,
            "maxRepetitionsOneRepMax": .integer,
            "autoBackup": .bool,
            "watchCompanion": .bool,
            "autoStartRestTimer": .bool,
            "keepScreenAwakeDuringWorkout": .bool,
            "showPlateCalculator": .bool,
            "showWarmUpCalculator": .bool,
            "logRPE": .bool,
            "prefillPreviousValues": .bool,
            "supersetAutoScroll": .bool,
            "inlineSetTimer": .bool,
            "workoutSounds": .bool,
            "workoutHaptics": .bool,
            "personalRecordAlerts": .bool,
            // Stable catalog UUIDs, never Core Data object IDs or store URLs.
            "hiddenExerciseUuids": .uuidStrings
        ],
        .standard: [
            "Iron.finishWorkout.syncWithHealth": .bool,
            "home.cards": .string,
            // Still read when home.cards has not yet been customized.
            "home.weekStyle": .string,
            "home.sectionOrder": .string,
            "home.hiddenSections": .string,
            "home.weeklySetTargetLow": .integer,
            "home.weeklySetTargetHigh": .integer,
            "exerciseDetail.metric": .string,
            "exerciseDetail.range": .string,
            "pinnedChartsKey": .data,
            "plateCalculator.inventory.v1": .plateInventory,
            "plateCalculator.loadouts.v1": .plateLoadouts
        ]
    ]

    static func capture(standard: UserDefaults, appGroup: UserDefaults) throws -> Data {
        SyncedPreferenceStorage.lock.lock()
        defer { SyncedPreferenceStorage.lock.unlock() }
        var archive: [String: [String: Any]] = [:]
        for domain in Domain.allCases {
            let defaults = domain == .standard ? standard : appGroup
            var values: [String: Any] = [:]
            for (key, type) in allowlist[domain] ?? [:] {
                if let value = defaults.object(forKey: key), type.accepts(value) {
                    switch type {
                    case .plateInventory, .plateLoadouts:
                        // Persist user content, not the Watch merge clocks. The
                        // local-edit save path supplies new clocks on restore.
                        if let data = value as? Data {
                            values[key] = try plateContentData(data)
                        }
                    default:
                        values[key] = value
                    }
                }
            }
            archive[domain.rawValue] = values
        }
        return try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
    }

    private static func plateContentData(_ data: Data) throws -> Data {
        func withoutClocks(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                return dictionary.filter { $0.key != "updatedAt" }.mapValues(withoutClocks)
            }
            if let array = value as? [Any] { return array.map(withoutClocks) }
            return value
        }
        return try JSONSerialization.data(withJSONObject:
            withoutClocks(JSONSerialization.jsonObject(with: data)), options: [.sortedKeys])
    }

    /// Best effort per key: unknown domains/keys, malformed blobs and wrong
    /// value types never invalidate an otherwise restorable workout archive.
    static func restore(_ data: Data, standard: UserDefaults, appGroup: UserDefaults) {
        guard let archive = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
                as? [String: Any] else { return }
        SyncedPreferenceStorage.lock.lock()
        var restoredAny = false
        for domain in Domain.allCases {
            guard let values = archive[domain.rawValue] as? [String: Any] else { continue }
            let defaults = domain == .standard ? standard : appGroup
            for (key, type) in allowlist[domain] ?? [:] {
                guard let value = values[key], type.accepts(value) else { continue }
                switch type {
                case .plateInventory:
                    if let data = value as? Data,
                       let inventory = try? JSONDecoder().decode(PlateInventory.self, from: data) {
                        // A restore is a local edit: old archive clocks must not
                        // lose to newer Watch preferences on the next connection.
                        inventory.save(defaults: defaults)
                    }
                case .plateLoadouts:
                    if let data = value as? Data,
                       let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        for (exercise, loadout) in PlateLoadout.loadouts(from: payload) {
                            loadout.save(exerciseKey: exercise, defaults: defaults)
                        }
                    }
                default:
                    defaults.set(value, forKey: key)
                }
                restoredAny = true
            }
        }
        SyncedPreferenceStorage.lock.unlock()
        guard restoredAny else { return }

        // Refresh SettingsStore, AppStorage, hidden-exercise and decoded-value
        // caches after the complete batch. Notify both even for one-domain archives
        // so Home also re-reads its pinned charts through its SettingsStore observer.
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: standard)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: appGroup)
        NotificationCenter.default.post(name: SettingsStore.restoredFromBackupNotification, object: nil)
        // The existing preference sync observer rebuilds both the Watch library
        // and current-workout projection, which carry weight units and rest options.
        NotificationCenter.default.post(name: SetTrackingPreferences.didChangeNotification, object: standard)
    }
}
