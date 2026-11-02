//
//  NotificationManager.swift
//  Sunrise Fit
//
//  Created by Karim Abou Zeid on 03.09.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import UserNotifications
import WatchKit

/// WatchKit owns the paired tap/tone and honors the Watch's Silent Mode.
/// It cannot mute the tone independently of the tap; custom CAF playback stays
/// on iPhone. Use one cue per event, never a rapid sequence of haptics.
enum WatchFeedback {
    static var hapticsEnabled: Bool {
        UserDefaults.standard.object(forKey: "workoutHaptics") as? Bool ?? true
    }

    private static var pendingWorkoutSave: UUID?

    static func play(_ type: WKHapticType) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { play(type) }
            return
        }
        guard hapticsEnabled else { return }
        WKInterfaceDevice.current().play(type)
    }

    static func expectWorkoutSave(_ id: UUID) { pendingWorkoutSave = id }
    static func cancelWorkoutSave() { pendingWorkoutSave = nil }
    static func workoutSaved(_ id: UUID) {
        // Only the local Save button arms this cue. Reopening a summary or
        // receiving the phone's finish must not announce another save.
        guard pendingWorkoutSave == id else { return }
        pendingWorkoutSave = nil
        play(.success)
    }
}

class NotificationManager: NSObject {
    static let shared = NotificationManager(notificationCenter: UNUserNotificationCenter.current())
    
    let notificationCenter: UNUserNotificationCenter
    private static let restIdentifier = "light.watch.restComplete"
    private struct RestAlert: Equatable {
        let workoutID: UUID
        let end: Date
    }
    // Accessed on the main queue, including notification delegate callbacks.
    private var currentRest: RestAlert?
    private var scheduledRest: RestAlert?
    private var completedRest: RestAlert?
    private var playedRest: RestAlert?
    
    init(notificationCenter: UNUserNotificationCenter) {
        self.notificationCenter = notificationCenter
        super.init()
        self.notificationCenter.delegate = self
    }

    func syncRestNotification(_ snapshot: WatchWorkoutSnapshot?, force: Bool = false) {
        DispatchQueue.main.async {
            let rest = snapshot.flatMap { value -> RestAlert? in
                guard !value.isFinishedRecord, value.pausedRestRemaining == nil,
                      let end = value.restTimerEnd else { return nil }
                return RestAlert(workoutID: value.workoutID, end: end)
            }
            guard force || rest != self.currentRest else { return }
            // Once a background rest reaches zero, leave its due notification
            // for the system even when the timer clears the persisted deadline.
            let awaitingBackgroundDelivery = rest == nil && self.currentRest != nil &&
                self.currentRest == self.completedRest && self.currentRest == self.scheduledRest &&
                WKApplication.shared().applicationState != .active
            if !awaitingBackgroundDelivery {
                self.notificationCenter.removePendingNotificationRequests(withIdentifiers: [Self.restIdentifier])
                self.scheduledRest = nil
            }
            self.currentRest = rest
            guard WatchFeedback.hapticsEnabled, let rest, rest.end > Date() else { return }
            self.notificationCenter.getNotificationSettings { settings in
                if settings.authorizationStatus == .notDetermined {
                    #if DEBUG
                    // Keep simulator/demo routes visible on a fresh install.
                    // Leave the authorization state untouched for normal launches.
                    guard !ProcessInfo.processInfo.arguments.contains("--light-watch-demo") else { return }
                    #endif
                    self.notificationCenter.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                        if granted { self.schedule(rest) }
                    }
                } else if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                    self.schedule(rest)
                }
            }
        }
    }

    private func schedule(_ rest: RestAlert) {
        DispatchQueue.main.async {
            guard WatchFeedback.hapticsEnabled, self.currentRest == rest, rest.end > Date() else { return }
            let content = UNMutableNotificationContent()
            content.title = "Rest Complete"
            content.body = "Ready for your next set."
            content.categoryIdentifier = Self.restIdentifier
            content.userInfo = ["workoutID": rest.workoutID.uuidString, "restEnd": rest.end.timeIntervalSince1970]
            // A standard Watch notification supplies the wrist-down haptic;
            // watchOS controls its tone, Silent Mode, Focus and wrist detection.
            content.sound = .default
            let request = UNNotificationRequest(identifier: Self.restIdentifier, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(0.1, rest.end.timeIntervalSinceNow), repeats: false))
            self.notificationCenter.add(request) { error in
                DispatchQueue.main.async {
                    guard self.currentRest == rest else { return }
                    if let error { print("Could not schedule Watch rest alert: \(error.localizedDescription)") }
                    else { self.scheduledRest = rest }
                }
            }
        }
    }

    func restDidFinish(workoutID: UUID, end: Date) {
        DispatchQueue.main.async {
            let rest = RestAlert(workoutID: workoutID, end: end)
            guard self.currentRest == rest else { return }
            self.completedRest = rest
            // The scheduled notification owns background delivery. An active
            // HealthKit session can still tap if notifications were denied.
            if WKApplication.shared().applicationState == .active || self.scheduledRest != rest {
                self.playRestOnce(rest)
                self.notificationCenter.removePendingNotificationRequests(withIdentifiers: [Self.restIdentifier])
                self.scheduledRest = nil
            }
        }
    }

    private func playRestOnce(_ rest: RestAlert) {
        guard playedRest != rest else { return }
        playedRest = rest
        WatchFeedback.play(.notification)
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if notification.request.identifier == Self.restIdentifier {
            return await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    guard WatchFeedback.hapticsEnabled else {
                        continuation.resume(returning: [])
                        return
                    }
                    let info = notification.request.content.userInfo
                    guard let rawID = info["workoutID"] as? String, let id = UUID(uuidString: rawID),
                          let end = info["restEnd"] as? TimeInterval else {
                        continuation.resume(returning: [])
                        return
                    }
                    let rest = RestAlert(workoutID: id, end: Date(timeIntervalSince1970: end))
                    guard rest == self.currentRest || (self.currentRest == nil && rest == self.completedRest) else {
                        continuation.resume(returning: [])
                        return
                    }
                    self.playRestOnce(rest)
                    // The explicit tap above owns foreground feedback; asking
                    // for .sound here would produce a second system haptic.
                    continuation.resume(returning: [.banner])
                }
            }
        }
        return [.banner, .sound]
    }
}
