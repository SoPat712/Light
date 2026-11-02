//
//  UserDefaults+Settings.swift
//  Sunrise Fit
//
//  Created by Karim Abou Zeid on 11.07.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import Foundation

extension UserDefaults {
    /// Respect an explicit preference; new Iron completions sync by default.
    var syncFinishedWorkoutsWithHealth: Bool {
        get { object(forKey: "Iron.finishWorkout.syncWithHealth") as? Bool ?? true }
        set { set(newValue, forKey: "Iron.finishWorkout.syncWithHealth") }
    }

    enum SettingsKeys: String, CaseIterable {
        case weightUnit
        case ironAppearance
        case defaultRestTime
        case defaultRestTimeDumbbellBased
        case defaultRestTimeBarbellBased
        case keepRestTimerRunning
        case maxRepetitionsOneRepMax
        case autoBackup
        case watchCompanion
        case healthTestMode
        case autoStartRestTimer
        case keepScreenAwakeDuringWorkout
        case showPlateCalculator
        case showWarmUpCalculator
        case logRPE
        case prefillPreviousValues
        case supersetAutoScroll
        case inlineSetTimer
        case workoutSounds
        case workoutHaptics
        case personalRecordAlerts
    }

    var weightUnit: WeightUnit {
        set {
            self.set(newValue.rawValue, forKey: SettingsKeys.weightUnit.rawValue)
        }
        get {
            let weightUnit = WeightUnit(rawValue: self.string(forKey: SettingsKeys.weightUnit.rawValue) ?? "")
            if let weightUnit = weightUnit {
                return weightUnit
            } else {
                let fallback = Locale.current.usesMetricSystem ? WeightUnit.metric : WeightUnit.imperial
                self.weightUnit = fallback // safe the new weight unit
                return fallback
            }
        }
    }

    var ironAppearance: IronAppearance {
        set {
            self.set(newValue.rawValue, forKey: SettingsKeys.ironAppearance.rawValue)
        }
        get {
            guard let rawValue = self.string(forKey: SettingsKeys.ironAppearance.rawValue),
                  let appearance = IronAppearance(rawValue: rawValue) else {
                return .system
            }
            return appearance
        }
    }
    
    var defaultRestTime: TimeInterval {
        set {
            self.set(newValue, forKey: SettingsKeys.defaultRestTime.rawValue)
        }
        get {
            self.value(forKey: SettingsKeys.defaultRestTime.rawValue) as? TimeInterval ?? 90 // default 1:30
        }
    }
    
    var defaultRestTimeDumbbellBased: TimeInterval {
        set {
            self.set(newValue, forKey: SettingsKeys.defaultRestTimeDumbbellBased.rawValue)
        }
        get {
            self.value(forKey: SettingsKeys.defaultRestTimeDumbbellBased.rawValue) as? TimeInterval ?? 150 // default 2:30
        }
    }
    
    var defaultRestTimeBarbellBased: TimeInterval {
        set {
            self.set(newValue, forKey: SettingsKeys.defaultRestTimeBarbellBased.rawValue)
        }
        get {
            self.value(forKey: SettingsKeys.defaultRestTimeBarbellBased.rawValue) as? TimeInterval ?? 180 // default 3:00
        }
    }
    
    var keepRestTimerRunning: Bool {
        set {
            self.set(newValue, forKey: SettingsKeys.keepRestTimerRunning.rawValue)
        }
        get {
            self.value(forKey: SettingsKeys.keepRestTimerRunning.rawValue) as? Bool ?? true // default true
        }
    }
    
    var maxRepetitionsOneRepMax: Int {
        set {
            self.set(newValue, forKey: SettingsKeys.maxRepetitionsOneRepMax.rawValue)
        }
        get {
            (self.value(forKey: SettingsKeys.maxRepetitionsOneRepMax.rawValue) as? Int)?.clamped(to: maxRepetitionsOneRepMaxValues) ?? 5 // default 5
        }
    }
    
    var autoBackup: Bool {
        set {
            self.set(newValue, forKey: SettingsKeys.autoBackup.rawValue)
        }
        get {
            self.value(forKey: SettingsKeys.autoBackup.rawValue) as? Bool ?? false // default false
        }
    }
    
    var watchCompanion: Bool {
        set {
            self.set(newValue, forKey: SettingsKeys.watchCompanion.rawValue)
        }
        get {
            self.value(forKey: SettingsKeys.watchCompanion.rawValue) as? Bool ?? true // default true
        }
    }

    /// Debug builds protect the owner's real Health data by default.
    /// Release builds ignore even a preference left by an installed debug build.
    var healthTestMode: Bool {
        get {
            #if DEBUG
            object(forKey: SettingsKeys.healthTestMode.rawValue) as? Bool ?? true
            #else
            false
            #endif
        }
        set {
            #if DEBUG
            set(newValue, forKey: SettingsKeys.healthTestMode.rawValue)
            #endif
        }
    }

    var autoStartRestTimer: Bool {
        set {
            self.set(newValue, forKey: SettingsKeys.autoStartRestTimer.rawValue)
        }
        get {
            self.value(forKey: SettingsKeys.autoStartRestTimer.rawValue) as? Bool ?? true // default true
        }
    }

    var keepScreenAwakeDuringWorkout: Bool {
        set {
            self.set(newValue, forKey: SettingsKeys.keepScreenAwakeDuringWorkout.rawValue)
        }
        get {
            self.value(forKey: SettingsKeys.keepScreenAwakeDuringWorkout.rawValue) as? Bool ?? false // default false
        }
    }

    var showPlateCalculator: Bool {
        set {
            self.set(newValue, forKey: SettingsKeys.showPlateCalculator.rawValue)
        }
        get {
            self.value(forKey: SettingsKeys.showPlateCalculator.rawValue) as? Bool ?? true // default true
        }
    }

    var showWarmUpCalculator: Bool {
        set {
            self.set(newValue, forKey: SettingsKeys.showWarmUpCalculator.rawValue)
        }
        get {
            self.value(forKey: SettingsKeys.showWarmUpCalculator.rawValue) as? Bool ?? true // default true
        }
    }

    var logRPE: Bool {
        set {
            self.set(newValue, forKey: SettingsKeys.logRPE.rawValue)
        }
        get {
            self.value(forKey: SettingsKeys.logRPE.rawValue) as? Bool ?? true // default true
        }
    }

    var prefillPreviousValues: Bool {
        set {
            self.set(newValue, forKey: SettingsKeys.prefillPreviousValues.rawValue)
        }
        get {
            self.value(forKey: SettingsKeys.prefillPreviousValues.rawValue) as? Bool ?? true // default true
        }
    }

    var supersetAutoScroll: Bool {
        set {
            self.set(newValue, forKey: SettingsKeys.supersetAutoScroll.rawValue)
        }
        get {
            self.value(forKey: SettingsKeys.supersetAutoScroll.rawValue) as? Bool ?? true // default true
        }
    }

    var inlineSetTimer: Bool {
        set {
            self.set(newValue, forKey: SettingsKeys.inlineSetTimer.rawValue)
        }
        get {
            self.value(forKey: SettingsKeys.inlineSetTimer.rawValue) as? Bool ?? true // default true
        }
    }

    var workoutSounds: Bool {
        set {
            self.set(newValue, forKey: SettingsKeys.workoutSounds.rawValue)
        }
        get {
            self.value(forKey: SettingsKeys.workoutSounds.rawValue) as? Bool ?? true // default true
        }
    }

    var workoutHaptics: Bool {
        set {
            self.set(newValue, forKey: SettingsKeys.workoutHaptics.rawValue)
        }
        get {
            self.value(forKey: SettingsKeys.workoutHaptics.rawValue) as? Bool ?? true // default true
        }
    }

    var personalRecordAlerts: Bool {
        set {
            self.set(newValue, forKey: SettingsKeys.personalRecordAlerts.rawValue)
        }
        get {
            self.value(forKey: SettingsKeys.personalRecordAlerts.rawValue) as? Bool ?? true // default true
        }
    }
}

let maxRepetitionsOneRepMaxValues = 1...10
