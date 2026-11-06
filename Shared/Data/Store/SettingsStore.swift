//
//  SettingsStore.swift
//  Sunrise Fit
//
//  Created by Karim Abou Zeid on 16.07.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import Foundation
import SwiftUI
import Combine

enum IronAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var subtitle: String {
        switch self {
        case .system: return "Match your iPhone appearance"
        case .light: return "Always use Light appearance"
        case .dark: return "Always use Dark appearance"
        }
    }

    var systemImage: String {
        switch self {
        case .system: return "iphone"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

final class SettingsStore: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    static let healthTestModeEnabledNotification = Notification.Name("Iron.healthTestModeEnabled")
    static let restoredFromBackupNotification = Notification.Name("Iron.settingsRestoredFromBackup")
    
    private var userDefaults: UserDefaults
    private var defaultsObserver: AnyCancellable?
    
    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
        // Backups restore a complete defaults batch, including preferences that
        // don't have a SettingsStore property. Re-read them in live views too.
        // Only on restore: UserDefaults.didChangeNotification fires for every write.
        defaultsObserver = NotificationCenter.default.publisher(
            for: Self.restoredFromBackupNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var weightUnit: WeightUnit {
        get {
            userDefaults.weightUnit
        }
        set {
            self.objectWillChange.send()
            userDefaults.weightUnit = newValue
        }
    }

    var appearance: IronAppearance {
        get {
            userDefaults.ironAppearance
        }
        set {
            objectWillChange.send()
            userDefaults.ironAppearance = newValue
        }
    }
    
    var defaultRestTime: TimeInterval {
        get {
            userDefaults.defaultRestTime
        }
        set {
            self.objectWillChange.send()
            userDefaults.defaultRestTime = newValue
        }
    }
    
    var defaultRestTimeDumbbellBased: TimeInterval {
        get {
            userDefaults.defaultRestTimeDumbbellBased
        }
        set {
            self.objectWillChange.send()
            userDefaults.defaultRestTimeDumbbellBased = newValue
        }
    }
    
    var defaultRestTimeBarbellBased: TimeInterval {
        get {
            userDefaults.defaultRestTimeBarbellBased
        }
        set {
            self.objectWillChange.send()
            userDefaults.defaultRestTimeBarbellBased = newValue
        }
    }
    
    var keepRestTimerRunning: Bool {
        get {
            userDefaults.keepRestTimerRunning
        }
        set {
            self.objectWillChange.send()
            userDefaults.keepRestTimerRunning = newValue
        }
    }
    
    var autoBackup: Bool {
        get {
            userDefaults.autoBackup
        }
        set {
            self.objectWillChange.send()
            userDefaults.autoBackup = newValue
        }
    }
    
    var watchCompanion: Bool {
        get {
            userDefaults.watchCompanion
        }
        set {
            self.objectWillChange.send()
            userDefaults.watchCompanion = newValue
        }
    }

    var healthTestMode: Bool {
        get { userDefaults.healthTestMode }
        set {
            #if DEBUG
            objectWillChange.send()
            userDefaults.healthTestMode = newValue
            if newValue {
                NotificationCenter.default.post(name: Self.healthTestModeEnabledNotification, object: self)
            }
            #endif
        }
    }

    var autoStartRestTimer: Bool {
        get {
            userDefaults.autoStartRestTimer
        }
        set {
            self.objectWillChange.send()
            userDefaults.autoStartRestTimer = newValue
        }
    }

    var keepScreenAwakeDuringWorkout: Bool {
        get {
            userDefaults.keepScreenAwakeDuringWorkout
        }
        set {
            self.objectWillChange.send()
            userDefaults.keepScreenAwakeDuringWorkout = newValue
        }
    }

    var showPlateCalculator: Bool {
        get {
            userDefaults.showPlateCalculator
        }
        set {
            self.objectWillChange.send()
            userDefaults.showPlateCalculator = newValue
        }
    }

    var showWarmUpCalculator: Bool {
        get {
            userDefaults.showWarmUpCalculator
        }
        set {
            self.objectWillChange.send()
            userDefaults.showWarmUpCalculator = newValue
        }
    }

    var logRPE: Bool {
        get {
            userDefaults.logRPE
        }
        set {
            self.objectWillChange.send()
            userDefaults.logRPE = newValue
        }
    }

    var prefillPreviousValues: Bool {
        get {
            userDefaults.prefillPreviousValues
        }
        set {
            self.objectWillChange.send()
            userDefaults.prefillPreviousValues = newValue
        }
    }

    var supersetAutoScroll: Bool {
        get {
            userDefaults.supersetAutoScroll
        }
        set {
            self.objectWillChange.send()
            userDefaults.supersetAutoScroll = newValue
        }
    }

    var inlineSetTimer: Bool {
        get {
            userDefaults.inlineSetTimer
        }
        set {
            self.objectWillChange.send()
            userDefaults.inlineSetTimer = newValue
        }
    }

    var workoutSounds: Bool {
        get {
            userDefaults.workoutSounds
        }
        set {
            self.objectWillChange.send()
            userDefaults.workoutSounds = newValue
        }
    }

    var workoutHaptics: Bool {
        get {
            userDefaults.workoutHaptics
        }
        set {
            self.objectWillChange.send()
            userDefaults.workoutHaptics = newValue
        }
    }

    var personalRecordAlerts: Bool {
        get {
            userDefaults.personalRecordAlerts
        }
        set {
            self.objectWillChange.send()
            userDefaults.personalRecordAlerts = newValue
        }
    }
}

#if DEBUG
extension SettingsStore {
    static let mockMetric: SettingsStore = {
        let store = SettingsStore(userDefaults: UserDefaults(suiteName: "mock_metric")!)
        store.weightUnit = .metric
        return store
    }()

    static let mockImperial: SettingsStore = {
        let store = SettingsStore(userDefaults: UserDefaults(suiteName: "mock_imperial")!)
        store.weightUnit = .imperial
        return store
    }()
}
#endif
