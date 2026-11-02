//
//  WidgetKind.swift
//  Iron
//
//  Created by Karim Abou Zeid on 12.10.20.
//  Copyright © 2020 Karim Abou Zeid Software. All rights reserved.
//

import Foundation
import WidgetKit
import AppIntents
import os.log
#if canImport(ActivityKit)
import ActivityKit
#endif

enum WidgetKind: String {
    case lastWorkout
    case thisWeek
}

/// Resolves the small, static exercise artwork shared with the Live Activity.
/// Unlike the general app-group helper, this never falls back to a process-local
/// container because those paths are not readable by the widget extension.
enum WorkoutLiveActivityArtwork {
    private static var appGroupIdentifier: String {
        #if DEBUG && targetEnvironment(simulator)
        return "group.com.joshpatra.IronDev.live-activity"
        #else
        return FileManager.appGroupIdentifier
        #endif
    }

    static let directoryURL: URL? = {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("LiveActivityArtwork", isDirectory: true)
    }()

    static func fileURL(for fileName: String?) -> URL? {
        guard let fileName,
              !fileName.isEmpty,
              fileName.count <= 200,
              fileName.hasSuffix(".png"),
              fileName.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_").contains($0)
              }),
              let directoryURL else { return nil }
        return directoryURL.appendingPathComponent(fileName, isDirectory: false)
    }
}

#if canImport(ActivityKit)
/// The value-only contract shared by Iron and its WidgetKit extension.
/// Keep this payload compact: ActivityKit limits static and dynamic data to 4 KB.
@available(iOS 16.1, *)
struct WorkoutActivityAttributes: ActivityAttributes {
    struct SetSnapshot: Codable, Hashable {
        /// Optional so activities started by an older app build still decode after updating.
        let setID: String?
        let exerciseName: String
        let setNumber: Int
        let setCount: Int
        let result: String
        var artworkFileName: String? = nil
        /// Count this exercise's completed sets; its current set number can have holes.
        /// Optional so an activity encoded by an earlier build still decodes.
        var completedSetCount: Int? = nil

        var completedSetProgress: Double? {
            guard let completedSetCount, setCount > 0 else { return nil }
            return Double(min(max(completedSetCount, 0), setCount)) / Double(setCount)
        }
    }

    enum Phase: String, Codable, Hashable {
        case currentSet
        case setCompleted
        case resting
        case finished
    }

    struct ContentState: Codable, Hashable {
        let phase: Phase
        let displaySet: SetSnapshot?
        let nextSet: SetSnapshot?
        let confirmationUntil: Date?
        let restTimerStart: Date?
        let restTimerEnd: Date?
        let completedSets: Int
        let totalSets: Int
        // Optional for activities encoded by app versions without pause support.
        var pausedRestRemaining: TimeInterval? = nil

        var isRestPaused: Bool {
            pausedRestRemaining.map { $0.isFinite && $0 > 0 } == true
        }

        /// Resolve time-driven presentation locally so the Live Activity can advance while
        /// the containing app is suspended. App-side ActivityKit updates still reconcile state.
        func resolvedPhase(at date: Date) -> Phase {
            switch phase {
            case .setCompleted:
                guard nextSet != nil else {
                    if let confirmationUntil, date < confirmationUntil {
                        return .setCompleted
                    }
                    return .finished
                }
                if isRestPaused || restTimerEnd.map({ date < $0 }) == true {
                    return .resting
                }
                if let confirmationUntil, date < confirmationUntil {
                    return .setCompleted
                }
                return .currentSet
            case .resting:
                guard nextSet != nil else { return .finished }
                if isRestPaused || restTimerEnd.map({ date < $0 }) == true {
                    return .resting
                }
                return .currentSet
            case .currentSet, .finished:
                return phase
            }
        }

        func visibleSet(at date: Date) -> SetSnapshot? {
            switch resolvedPhase(at: date) {
            case .setCompleted:
                return displaySet
            case .currentSet, .resting:
                return nextSet ?? displaySet
            case .finished:
                return displaySet
            }
        }

        /// The adjusted interval is also the source of truth for the total. Keeping
        /// the start fixed while moving the end preserves elapsed time after ±15 s.
        var restTimerInterval: ClosedRange<Date>? {
            guard let restTimerStart, let restTimerEnd,
                  restTimerStart.timeIntervalSinceReferenceDate.isFinite,
                  restTimerEnd.timeIntervalSinceReferenceDate.isFinite,
                  restTimerEnd > restTimerStart,
                  restTimerEnd.timeIntervalSince(restTimerStart).isFinite else {
                return nil
            }
            return restTimerStart...restTimerEnd
        }

        var restDuration: TimeInterval? {
            restTimerInterval.map { $0.upperBound.timeIntervalSince($0.lowerBound) }
        }

        func restProgress(at date: Date) -> Double? {
            guard let interval = restTimerInterval, let duration = restDuration else { return nil }
            // A paused payload must retain the interval to recover its fraction.
            // Older/current producers may omit it; don't invent an elapsed value.
            let elapsed = isRestPaused
                ? duration - (pausedRestRemaining ?? duration)
                : date.timeIntervalSince(interval.lowerBound)
            return min(max(elapsed / duration, 0), 1)
        }
    }

    let workoutID: String
    let workoutTitle: String
    let workoutStart: Date
}

@available(iOS 17.0, *)
struct CompleteWorkoutSetIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Complete Workout Set"
    static var description = IntentDescription("Marks the displayed Light workout set complete.")
    static var openAppWhenRun = false
    static var isDiscoverable = false

    @Parameter(title: "Workout ID")
    var workoutID: String

    @Parameter(title: "Set ID")
    var setID: String

    init() {
        workoutID = ""
        setID = ""
    }

    init(workoutID: String, setID: String) {
        self.workoutID = workoutID
        self.setID = setID
    }

    func perform() async throws -> some IntentResult {
        #if IRON_WIDGET_EXTENSION
        // The system executes this LiveActivityIntent in the containing app.
        #else
        await WorkoutLiveActivityIntentHandler.completeSet(
            workoutID: workoutID,
            setID: setID
        )
        #endif
        return .result()
    }
}

@available(iOS 17.0, *)
struct AdjustWorkoutRestTimerIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Adjust Workout Rest Timer"
    static var description = IntentDescription("Adds or removes time from Light's active rest timer.")
    static var openAppWhenRun = false
    static var isDiscoverable = false

    @Parameter(title: "Workout ID")
    var workoutID: String

    @Parameter(title: "Seconds")
    var seconds: Int

    init() {
        workoutID = ""
        seconds = 0
    }

    init(workoutID: String, seconds: Int) {
        self.workoutID = workoutID
        self.seconds = seconds
    }

    func perform() async throws -> some IntentResult {
        #if IRON_WIDGET_EXTENSION
        // LiveActivityIntent is performed by the containing app. This copy exists so
        // the widget extension can archive the button's intent metadata.
        #else
        await WorkoutLiveActivityIntentHandler.adjustRestTimer(
            workoutID: workoutID,
            by: TimeInterval(seconds)
        )
        #endif
        return .result()
    }
}

@available(iOS 17.0, *)
struct ResumeWorkoutRestTimerIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Resume Workout Rest Timer"
    static var openAppWhenRun = false
    static var isDiscoverable = false

    @Parameter(title: "Workout ID")
    var workoutID: String

    init() { workoutID = "" }
    init(workoutID: String) { self.workoutID = workoutID }

    func perform() async throws -> some IntentResult {
        #if !IRON_WIDGET_EXTENSION
        await WorkoutLiveActivityIntentHandler.resumeRestTimer(workoutID: workoutID)
        #endif
        return .result()
    }
}

@available(iOS 17.0, *)
struct SkipWorkoutRestTimerIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Skip Workout Rest Timer"
    static var description = IntentDescription("Skips Light's active rest timer.")
    static var openAppWhenRun = false
    static var isDiscoverable = false

    @Parameter(title: "Workout ID")
    var workoutID: String

    init() {
        workoutID = ""
    }

    init(workoutID: String) {
        self.workoutID = workoutID
    }

    func perform() async throws -> some IntentResult {
        #if IRON_WIDGET_EXTENSION
        // See AdjustWorkoutRestTimerIntent.perform().
        #else
        await WorkoutLiveActivityIntentHandler.skipRestTimer(workoutID: workoutID)
        #endif
        return .result()
    }
}
#endif

@available(iOS 14.0, *)
extension WidgetKind {
    func reloadTimelines() {
        os_log("Reload timeline", log: .widgets, type: .debug)
        WidgetCenter.shared.reloadTimelines(ofKind: rawValue)
    }
}
