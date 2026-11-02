//
//  NotificationManager.swift
//  Sunrise Fit
//
//  Created by Karim Abou Zeid on 03.09.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import UserNotifications

class NotificationManager: NSObject {
    static let shared = NotificationManager(notificationCenter: UNUserNotificationCenter.current())
    
    let notificationCenter: UNUserNotificationCenter
    private let notificationOperationQueue = DispatchQueue(
        label: "com.iron.notifications.operations",
        qos: .utility
    )
    private var restTimerNotificationGeneration: UInt = 0
    private struct RestTimerRequest {
        let deadline: Date
        let totalTime: TimeInterval?
        let playsSound: Bool
    }
    private var restTimerRequest: RestTimerRequest?
    private var ownershipObserver: NSObjectProtocol?
    private var watchOwnedRest = NotificationManager.watchOwnsRestAlerts

    /// The existing durable handoff gives Watch priority, including while the
    /// phone is foregrounded or connectivity drops. Reachability is not proof
    /// that the Watch session stopped. Without an acknowledged alert-owner
    /// field, a failed handoff can leave the phone quiet until it is cleared.
    static var watchOwnsRestAlerts: Bool {
        UserDefaults.standard.watchWorkoutUuid != nil
    }
    
    init(notificationCenter: UNUserNotificationCenter) {
        self.notificationCenter = notificationCenter
        super.init()
        self.notificationCenter.delegate = self
        
        let restTimerAdd30Action = UNNotificationAction(identifier: NotificationActionIdentifier.restTimerAdd30.rawValue, title: "+30s")
        let restTimerAdd60Action = UNNotificationAction(identifier: NotificationActionIdentifier.restTimerAdd60.rawValue, title: "+60s")
        let restTimerAdd90Action = UNNotificationAction(identifier: NotificationActionIdentifier.restTimerAdd90.rawValue, title: "+90s")
        // Define the notification type
        let restTimerUpCategory =
            UNNotificationCategory(identifier: NotificationCategoryIdentifier.restTimerUp.rawValue,
                                   actions: [restTimerAdd30Action, restTimerAdd60Action, restTimerAdd90Action],
                                   intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: "",
                                   options: [.hiddenPreviewsShowTitle, .hiddenPreviewsShowSubtitle, .allowAnnouncement])
        // Register the notification type.
        notificationCenter.setNotificationCategories([restTimerUpCategory])

        ownershipObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.notificationOperationQueue.async {
                let watchOwned = Self.watchOwnsRestAlerts
                guard watchOwned != self.watchOwnedRest else { return }
                self.watchOwnedRest = watchOwned
                self.replaceRestTimerNotification()
            }
        }
        if Self.watchOwnsRestAlerts {
            // Also remove a phone request left over from the previous launch.
            notificationOperationQueue.async { self.replaceRestTimerNotification() }
        }
    }

    deinit {
        if let ownershipObserver { NotificationCenter.default.removeObserver(ownershipObserver) }
    }
    
    func requestAuthorization() {
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { (granted, error) in
            if let error = error {
                print(error)
            }
        }
    }
    
    func removePendingNotificationRequests(withIdentifiers: [NotificationIdentifier]) {
        let identifiers = withIdentifiers.map { $0.rawValue }
        notificationOperationQueue.async { [weak self] in
            guard let self else { return }
            if withIdentifiers.contains(.restTimerUp) {
                self.restTimerNotificationGeneration &+= 1
                self.restTimerRequest = nil
            }
            self.notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
        }
    }
    
    func removeDeliveredNotification(withIdentifiers: [NotificationIdentifier]) {
        let identifiers = withIdentifiers.map { $0.rawValue }
        notificationOperationQueue.async { [notificationCenter] in
            notificationCenter.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    func removeAllDeliveredNotifications() {
        notificationOperationQueue.async { [notificationCenter] in
            notificationCenter.removeAllDeliveredNotifications()
        }
    }

    func requestUnfinishedWorkoutNotification() {
        notificationCenter.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            
            let content = UNMutableNotificationContent()
            content.title = "Unfinished workout"
            content.body = "You have an unfinished workout. Do you want to finish it?"
            if settings.soundSetting == .enabled {
                content.sound = UNNotificationSound.default
            }
            
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 15*60, repeats: true)
            
            let request = UNNotificationRequest(identifier: NotificationIdentifier.unfinishedWorkout.rawValue, content: content, trigger: trigger)
            
            self.notificationCenter.add(request) { (error) in
                if let error = error {
                    print("error \(String(describing: error))")
                }
            }
        }
    }
    
    /// Atomically replaces the rest timer alert. A generation check prevents a
    /// slow settings callback from resurrecting a request cancelled meanwhile.
    func updateRestTimerUpNotificationRequest(
        deadline: Date?,
        totalTime: TimeInterval? = nil,
        playsSound: Bool
    ) {
        notificationOperationQueue.async { [weak self] in
            guard let self else { return }
            self.restTimerRequest = deadline.map {
                RestTimerRequest(deadline: $0, totalTime: totalTime, playsSound: playsSound)
            }
            self.replaceRestTimerNotification()
        }
    }

    /// Called only on notificationOperationQueue. Retain the requested timer
    /// while Watch owns delivery, so clearing the handoff can rearm the phone.
    private func replaceRestTimerNotification() {
        self.restTimerNotificationGeneration &+= 1
        let generation = self.restTimerNotificationGeneration
        self.notificationCenter.removePendingNotificationRequests(
            withIdentifiers: [NotificationIdentifier.restTimerUp.rawValue]
        )

        guard !Self.watchOwnsRestAlerts, let restRequest = restTimerRequest else { return }
        self.notificationCenter.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            self.notificationOperationQueue.async {
                guard generation == self.restTimerNotificationGeneration,
                      !Self.watchOwnsRestAlerts,
                      [.authorized, .provisional].contains(settings.authorizationStatus) else { return }

                let remainingTime = restRequest.deadline.timeIntervalSinceNow
                guard remainingTime > 0 else { return }

                let content = UNMutableNotificationContent()
                content.title = "You've rested enough!"
                if let totalTime = restRequest.totalTime,
                   let totalTimeString = restTimerDurationFormatter.string(from: totalTime) {
                    content.title += " (\(totalTimeString))"
                }
                content.body = "Back to work 💪"
                if Self.shouldPlayRestTimerSound(
                    appSoundsEnabled: restRequest.playsSound,
                    systemSoundSetting: settings.soundSetting
                ) {
                    content.sound = UNNotificationSound(named: UNNotificationSoundName("rest_complete.caf"))
                }
                content.categoryIdentifier = NotificationCategoryIdentifier.restTimerUp.rawValue
                if #available(iOS 15.0, *) {
                    content.interruptionLevel = .timeSensitive
                }

                let trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: remainingTime,
                    repeats: false
                )
                let request = UNNotificationRequest(
                    identifier: NotificationIdentifier.restTimerUp.rawValue,
                    content: content,
                    trigger: trigger
                )
                self.notificationCenter.add(request) { error in
                    if let error {
                        print("error \(String(describing: error))")
                    }
                }
            }
        }
    }

    static func shouldPlayRestTimerSound(
        appSoundsEnabled: Bool,
        systemSoundSetting: UNNotificationSetting
    ) -> Bool {
        appSoundsEnabled && systemSoundSetting == .enabled
    }
    
    func requestStartedWorkoutFromBackgroundNotification() {
        notificationCenter.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            
            let content = UNMutableNotificationContent()
            content.title = "Your workout was started"
            content.body = "Open Light to launch the Apple Watch companion."
            if #available(iOS 15.0, *) {
                content.interruptionLevel = .timeSensitive
            }
            
            let request = UNNotificationRequest(identifier: NotificationIdentifier.startedWorkout.rawValue, content: content, trigger: nil)
            
            self.notificationCenter.add(request) { (error) in
                if let error = error {
                    print("error \(String(describing: error))")
                }
            }
        }
    }
    
    enum NotificationIdentifier: String {
        case unfinishedWorkout
        case unfinishedTraining // TODO: remove unfinishedTraining in future version
        case restTimerUp
        case startedWorkout
    }
    
    enum NotificationCategoryIdentifier: String {
        case restTimerUp
    }
    
    enum NotificationActionIdentifier: String {
        case restTimerAdd30
        case restTimerAdd60
        case restTimerAdd90
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.content.categoryIdentifier == NotificationCategoryIdentifier.restTimerUp.rawValue {
            guard !Self.watchOwnsRestAlerts else {
                completionHandler([])
                return
            }
            // RestTimerStore owns the foreground chime and haptic.
            completionHandler([.banner, .list])
        } else {
            completionHandler([.banner, .list, .sound])
        }
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        guard response.notification.request.content.categoryIdentifier == NotificationCategoryIdentifier.restTimerUp.rawValue,
              let actionIdentifier = NotificationActionIdentifier(rawValue: response.actionIdentifier) else {
            completionHandler()
            return
        }

        let interval: TimeInterval
        switch actionIdentifier {
        case .restTimerAdd30: interval = 30
        case .restTimerAdd60: interval = 60
        case .restTimerAdd90: interval = 90
        }

        DispatchQueue.main.async {
            guard RestTimerStore.shared.restTimerDuration != nil else {
                completionHandler()
                return
            }
            RestTimerStore.shared.adjust(by: interval)
            if #available(iOS 16.1, *) {
                WorkoutLiveActivityManager.shared.refreshCurrentWorkoutRestTimer()
            }
            completionHandler()
        }
    }
}
