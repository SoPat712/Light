//
//  RestTimerStore.swift
//  Sunrise Fit
//
//  Created by Karim Abou Zeid on 12.08.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import Foundation
import Combine
import UIKit

let restTimerDurationFormatter: DateComponentsFormatter = {
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .positional
    formatter.allowedUnits = [.minute, .second]
    formatter.zeroFormattingBehavior = .pad
    return formatter
}()

let restTimerCustomTimes: [TimeInterval] = {
    stride(from: 30 as TimeInterval, through: 10*60, by: 5).map { $0 }
}()

final class RestTimerStore: ObservableObject {
    static let shared = RestTimerStore(userDefaults: .standard)

    typealias ExpiryCancellation = () -> Void
    typealias ExpiryScheduler = (_ deadline: Date, _ handler: @escaping () -> Void) -> ExpiryCancellation

    let objectWillChange = ObservableObjectPublisher()
    /// Only a running deadline reaching zero emits this; skips and cancellations do not.
    let didExpire = PassthroughSubject<Void, Never>()

    private let userDefaults: UserDefaults
    private let now: () -> Date
    private let keepRunning: () -> Bool
    private let notificationUpdater: (_ deadline: Date?, _ totalTime: TimeInterval?) -> Void
    private let watchUpdater: (_ end: Date?) -> Void
    private let expiryScheduler: ExpiryScheduler
    private let expiryAnnouncement: (() -> Void)?
    private let adjustmentTick: () -> Void
    private let isAppActive: () -> Bool
    private var cancelScheduledExpiry: ExpiryCancellation?
    private var expiryGeneration: UInt = 0
    private var hasDeferredWatchUpdate = false

    init(
        userDefaults: UserDefaults,
        now: @escaping () -> Date = Date.init,
        keepRunning: @escaping () -> Bool = { SettingsStore.shared.keepRestTimerRunning },
        notificationUpdater: @escaping (Date?, TimeInterval?) -> Void = { deadline, totalTime in
            NotificationManager.shared.updateRestTimerUpNotificationRequest(
                deadline: deadline,
                totalTime: totalTime,
                playsSound: SettingsStore.shared.workoutSounds
            )
        },
        watchUpdater: @escaping (Date?) -> Void = { end in
            guard let uuid = WatchConnectionManager.shared.currentWatchWorkoutUuid else { return }
            WatchConnectionManager.shared.updateWatchWorkoutRestTimer(
                end: end,
                keepRunning: SettingsStore.shared.keepRestTimerRunning,
                uuid: uuid
            )
        },
        expiryScheduler: @escaping ExpiryScheduler = { deadline, handler in
            let workItem = DispatchWorkItem(block: handler)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + max(deadline.timeIntervalSinceNow, 0),
                execute: workItem
            )
            return { workItem.cancel() }
        },
        expiryAnnouncement: (() -> Void)? = nil,
        adjustmentTick: @escaping () -> Void = { IronSoundPlayer.shared.play(.tick) },
        isAppActive: @escaping () -> Bool = { UIApplication.shared.applicationState == .active }
    ) {
        self.userDefaults = userDefaults
        self.now = now
        self.keepRunning = keepRunning
        self.notificationUpdater = notificationUpdater
        self.watchUpdater = watchUpdater
        self.expiryScheduler = expiryScheduler
        self.expiryAnnouncement = expiryAnnouncement
        self.adjustmentTick = adjustmentTick
        self.isAppActive = isAppActive
        restorePersistedExpiry()
    }

    var restTimerStart: Date? {
        get { userDefaults.restTimerStart }
        set {
            transition(
                start: newValue,
                duration: restTimerDuration,
                pausedRemaining: newValue == nil ? userDefaults.restTimerPausedRemaining : nil
            )
        }
    }

    var restTimerDuration: TimeInterval? {
        get { userDefaults.restTimerDuration }
        set {
            let duration = Self.validDuration(newValue)
            transition(
                start: duration == nil ? nil : restTimerStart,
                duration: duration,
                pausedRemaining: duration == nil ? nil : userDefaults.restTimerPausedRemaining
            )
        }
    }

    var recentRestTimes: [TimeInterval] {
        get { userDefaults.recentRestTimes }
        set {
            objectWillChange.send()
            userDefaults.recentRestTimes = newValue
        }
    }

    var isPaused: Bool { userDefaults.restTimerPausedRemaining != nil }

    func notifyKeepRestTimerRunningChanged() {
        objectWillChange.send()
        updateWatch()
    }

    private static func validDuration(_ duration: TimeInterval?) -> TimeInterval? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        return duration
    }

    /// Persist a complete snapshot before publishing any timer effects.
    private func transition(
        start: Date?,
        duration: TimeInterval?,
        pausedRemaining: TimeInterval?,
        updateWatch shouldUpdateWatch: Bool = true
    ) {
        let duration = Self.validDuration(duration)
        let pausedRemaining = Self.validDuration(pausedRemaining)
        let start = duration == nil || pausedRemaining != nil ? nil : start

        expiryGeneration &+= 1
        hasDeferredWatchUpdate = false
        cancelScheduledExpiry?()
        cancelScheduledExpiry = nil

        userDefaults.restTimerStart = start
        userDefaults.restTimerDuration = duration
        userDefaults.restTimerPausedRemaining = pausedRemaining
        objectWillChange.send()

        let deadline = start.flatMap { start in
            duration.map { start.addingTimeInterval($0) }
        }
        notificationUpdater(deadline, duration)
        if shouldUpdateWatch { updateWatch() }
        scheduleExpiryAnnouncement(deadline: deadline)
    }

    private func updateWatch() {
        watchUpdater(restTimerEnd)
    }

    private func scheduleExpiryAnnouncement(deadline: Date?) {
        guard let deadline, deadline.timeIntervalSince(now()) > 0.05 else { return }
        let generation = expiryGeneration
        cancelScheduledExpiry = expiryScheduler(deadline) { [weak self] in
            guard let self, self.expiryGeneration == generation else { return }
            self.cancelScheduledExpiry = nil
            self.announceExpiry()
        }
    }

    private func restorePersistedExpiry() {
        guard userDefaults.restTimerPausedRemaining == nil,
              let deadline = restTimerEnd, deadline.timeIntervalSince(now()) > 0.05 else { return }
        // Reapply alert ownership after relaunch and retain this deadline so
        // the phone can rearm it if the Watch handoff is cleared during rest.
        notificationUpdater(deadline, restTimerDuration)
        scheduleExpiryAnnouncement(deadline: deadline)
    }

    private func announceExpiry() {
        // The Watch handoff owns audible expiry even with the phone open.
        // The logger owns the light impact. Background expiry uses the already
        // scheduled notification; extensions never emit app feedback.
        if canPlayAppFeedback && !NotificationManager.watchOwnsRestAlerts {
            if let expiryAnnouncement {
                expiryAnnouncement()
            } else if SettingsStore.shared.workoutSounds {
                IronSoundPlayer.shared.play(.restComplete)
            }
        }
        if canPlayAppFeedback { didExpire.send() }
        objectWillChange.send()
    }

    private var canPlayAppFeedback: Bool {
        #if IRON_WIDGET_EXTENSION
        return false
        #else
        return Bundle.main.bundleURL.pathExtension != "appex" && isAppActive()
        #endif
    }
}

extension RestTimerStore {
    /// Presentation dates retain the total and elapsed portion while paused.
    /// They are not a running deadline: notifications and Watch sync still use
    /// `restTimerEnd`, which remains nil until the timer resumes.
    var restTimerInterval: ClosedRange<Date>? {
        guard let duration = Self.validDuration(restTimerDuration) else { return nil }
        let start: Date
        if let remaining = Self.validDuration(userDefaults.restTimerPausedRemaining) {
            start = now().addingTimeInterval(-max(0, duration - remaining))
        } else if let runningStart = restTimerStart {
            start = runningStart
        } else {
            return nil
        }
        let end = start.addingTimeInterval(duration)
        guard start.timeIntervalSinceReferenceDate.isFinite,
              end.timeIntervalSinceReferenceDate.isFinite, end > start else { return nil }
        return start...end
    }

    var restTimerEnd: Date? {
        guard let duration = restTimerDuration else { return nil }
        return restTimerStart?.addingTimeInterval(duration)
    }

    var restTimerRemainingTime: TimeInterval? {
        if let paused = userDefaults.restTimerPausedRemaining { return paused }
        guard let restTimerEnd else { return nil }
        let remainingTime = restTimerEnd.timeIntervalSince(now())
        guard remainingTime >= 0 || keepRunning() else { return nil }
        return max(remainingTime, 0)
    }
}

extension RestTimerStore {
    func start(duration: TimeInterval, deferringWatchUpdate: Bool = false) {
        guard let duration = Self.validDuration(duration) else {
            cancel()
            return
        }
        transition(start: now(), duration: duration, pausedRemaining: nil, updateWatch: !deferringWatchUpdate)
        hasDeferredWatchUpdate = deferringWatchUpdate
    }

    /// Local logger motion may batch the Watch snapshot without delaying the
    /// timer's persisted start, notifications or expiry scheduling.
    func flushDeferredWatchUpdate() {
        guard hasDeferredWatchUpdate else { return }
        hasDeferredWatchUpdate = false
        updateWatch()
    }

    func setRemaining(_ remaining: TimeInterval) {
        guard let remaining = Self.validDuration(remaining) else {
            cancel()
            return
        }
        if isPaused {
            transition(start: nil, duration: remaining, pausedRemaining: remaining)
        } else {
            transition(start: now(), duration: remaining, pausedRemaining: nil)
        }
    }

    func pause() {
        guard !isPaused, let remaining = restTimerRemainingTime, remaining > 0 else { return }
        transition(start: nil, duration: restTimerDuration, pausedRemaining: remaining)
    }

    func resume() {
        guard let remaining = userDefaults.restTimerPausedRemaining else { return }
        let total = max(restTimerDuration ?? remaining, remaining)
        let resumedAt = now().addingTimeInterval(-(total - remaining))
        transition(start: resumedAt, duration: total, pausedRemaining: nil)
    }

    /// Shared updates are silent. Only local app controls may opt into the tick;
    /// those controls own their selection haptic.
    func adjust(by interval: TimeInterval, feedback: Bool = false) {
        guard interval.isFinite else { return }
        guard isPaused || restTimerEnd != nil else { return }
        if feedback, canPlayAppFeedback { adjustmentTick() }

        if let paused = userDefaults.restTimerPausedRemaining {
            let adjusted = paused + interval
            guard adjusted.isFinite, adjusted > 0 else {
                cancel()
                return
            }
            let total = max((restTimerDuration ?? paused) + interval, adjusted)
            transition(start: nil, duration: total, pausedRemaining: adjusted)
            return
        }

        guard let end = restTimerEnd else { return }

        let currentTime = now()
        if end <= currentTime {
            guard interval > 0 else {
                cancel()
                return
            }
            transition(start: currentTime, duration: interval, pausedRemaining: nil)
            return
        }

        guard let duration = restTimerDuration,
              let adjustedDuration = Self.validDuration(duration + interval),
              end.addingTimeInterval(interval) > currentTime else {
            cancel()
            return
        }
        transition(start: restTimerStart, duration: adjustedDuration, pausedRemaining: nil)
    }

    /// End-only updates adjust the current rest. A new rest (for example, after
    /// completing another set) can supply its start to replace that interval.
    func applyWatchUpdate(end: Date?, pausedRemaining: TimeInterval? = nil, startedAt: Date? = nil) {
        if let pausedRemaining, let remaining = Self.validDuration(pausedRemaining) {
            // An adjustment to an already-paused timer changes the total by the
            // same delta as the remaining time, preserving its elapsed portion.
            let total: TimeInterval
            if let previousRemaining = userDefaults.restTimerPausedRemaining {
                total = max(0, (restTimerDuration ?? previousRemaining) - previousRemaining) + remaining
            } else {
                total = max(restTimerDuration ?? remaining, remaining)
            }
            transition(start: nil, duration: total,
                       pausedRemaining: remaining, updateWatch: false)
            return
        }
        guard let end else {
            transition(start: nil, duration: nil, pausedRemaining: nil, updateWatch: false)
            return
        }
        let currentTime = now()
        guard Self.validDuration(end.timeIntervalSince(currentTime)) != nil else {
            transition(start: nil, duration: nil, pausedRemaining: nil, updateWatch: false)
            return
        }
        let start: Date
        if let startedAt, startedAt.timeIntervalSinceReferenceDate.isFinite,
           startedAt <= currentTime {
            start = startedAt
        } else if let remaining = userDefaults.restTimerPausedRemaining {
            // The Watch deadline includes time spent delivering this update.
            // Keep the captured total so transit time counts as running time.
            start = end.addingTimeInterval(-max(restTimerDuration ?? remaining, remaining))
        } else if let previousStart = restTimerStart, let previousEnd = restTimerEnd,
                  previousEnd > currentTime {
            start = previousStart
        } else {
            // With no active interval (including expired rest), match phone ±15.
            start = currentTime
        }
        transition(
            start: start,
            duration: end.timeIntervalSince(start),
            pausedRemaining: nil,
            updateWatch: false
        )
    }

    func cancel() {
        transition(start: nil, duration: nil, pausedRemaining: nil)
    }
}
