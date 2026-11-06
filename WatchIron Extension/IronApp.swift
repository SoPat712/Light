//
//  IronApp.swift
//  IronWatch WatchKit Extension
//
//  Created by Karim Abou Zeid on 27.05.22.
//

import SwiftUI

@main
struct IronApp: App {
    @WKApplicationDelegateAdaptor private var appDelegate: AppDelegate
    
    init() {
        #if DEBUG && targetEnvironment(simulator)
        WatchFocusDemo.seedIfRequested()
        #endif
    }

    @SceneBuilder var body: some Scene {
        WindowGroup {
            ContentView()
                #if DEBUG && targetEnvironment(simulator)
                .transformEnvironment(\.dynamicTypeSize) { size in
                    if ProcessInfo.processInfo.arguments.contains("--large-watch-text") { size = .accessibility3 }
                }
                .transformEnvironment(\.isLuminanceReduced) { value in
                    if ProcessInfo.processInfo.arguments.contains("--watch-aod-demo") { value = true }
                }
                .transformEnvironment(\.redactionReasons) { reasons in
                    if ProcessInfo.processInfo.arguments.contains("--watch-aod-demo") { reasons.insert(.privacy) }
                }
                #endif
                // Native toolbars choose their own neutral glass treatment.
                // In-content primary actions opt into Iron blue individually.
                .preferredColorScheme(.dark)
        }
    }
}

import HealthKit
import os.log

class AppDelegate: NSObject, WKApplicationDelegate {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "watch")
    
    func applicationDidFinishLaunching() {
        // Perform any final initialization of your application.
        Self.logger.log("Checking whether active workout session can be recovered")
        handleActiveWorkoutRecovery() // somehow this isn't automatically called by the system?! last checked watchOS 8
        _ = NotificationManager.shared
    }

    func handle(_ userActivity: NSUserActivity) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .lightOpenWorkout, object: nil)
        }
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        // Sent when the system needs to launch the application in the background to process tasks. Tasks arrive in a set, so loop through and process each one.
        for task in backgroundTasks {
            // Use a switch statement to check the task type
            switch task {
            case let backgroundTask as WKApplicationRefreshBackgroundTask:
                refreshConnectivity()
                backgroundTask.setTaskCompletedWithSnapshot(false)
            case let snapshotTask as WKSnapshotRefreshBackgroundTask:
                // Snapshot tasks have a unique completion call, make sure to set your expiration date
                snapshotTask.setTaskCompleted(restoredDefaultState: true, estimatedSnapshotExpiration: Date.distantFuture, userInfo: nil)
            case let connectivityTask as WKWatchConnectivityRefreshBackgroundTask:
                // Re-attach the delegate and drain Iron's durable event outbox
                // before releasing the connectivity wake-up. This lets edits
                // made offline progress without requiring a foreground launch.
                refreshConnectivity()
                connectivityTask.setTaskCompletedWithSnapshot(false)
            case let urlSessionTask as WKURLSessionRefreshBackgroundTask:
                // Be sure to complete the URL session task once you’re done.
                urlSessionTask.setTaskCompletedWithSnapshot(false)
            case let relevantShortcutTask as WKRelevantShortcutRefreshBackgroundTask:
                // Be sure to complete the relevant-shortcut task once you're done.
                relevantShortcutTask.setTaskCompletedWithSnapshot(false)
            case let intentDidRunTask as WKIntentDidRunRefreshBackgroundTask:
                // Be sure to complete the intent-did-run task once you're done.
                intentDidRunTask.setTaskCompletedWithSnapshot(false)
            default:
                // make sure to complete unhandled task types
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    private func refreshConnectivity() {
        let connection = PhoneConnectionManager.shared
        if !connection.isActivated {
            connection.activateSession()
        }
        connection.flushEventOutbox()
    }
    
    func handleActiveWorkoutRecovery() {
        Self.logger.log("Recovering active workout session")
        WorkoutSessionManager.healthStore.recoverActiveWorkoutSession { workoutSession, error in
            guard let workoutSession = workoutSession else {
                WorkoutSessionManagerStore.shared.finishRecordingRecovery()
                if let error = error {
                    Self.logger.error("Could not recover active workout session: \(error.localizedDescription)")
                } else {
                    Self.logger.info("No active workout session to recover")
                }
                PhoneConnectionManager.shared.activateSession()
                return
            }
            Self.logger.info("Successfully recovered active workout session")
            WorkoutSessionManagerStore.shared.recoverWorkoutSession(workoutSession: workoutSession) {
                PhoneConnectionManager.shared.activateSession()
            }
        }
    }
    
    /// from `HKHealthStore.startWatchApp`
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        PhoneConnectionManager.shared.handlePrepareWorkoutSession(workoutConfiguration)
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Disposable simulator fixtures. Never present in a device or Release build.
enum WatchFocusDemo {
    /// Flow fixtures must run at the root: a restored Rest destination can
    /// cover the workout page before that page ever receives onAppear.
    static func openFlowIfRequested(snapshot: WatchWorkoutSnapshot, navigation: WatchNavigation) {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "--light-watch-demo"), args.indices.contains(flag + 1),
              ["after-log", "rpe-auto", "after-rest"].contains(args[flag + 1]),
              let logged = snapshot.completedSets.first else { return }
        navigation.showFlowDemo(in: snapshot, after: logged.id, asksRPE: args[flag + 1] != "after-rest")
        if args.contains("--demo-flow-back") {
            Task { @MainActor [weak navigation] in
                guard let navigation else { return }
                for await path in navigation.$path.values {
                    guard path.count == 3, path.first == .workout, path.last == .rest,
                          case .rpe = path[1] else { continue }
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                    catch { return }
                    guard navigation.path == path, navigation.restHasRPEBack else { return }
                    navigation.path.removeLast()
                    return
                }
            }
        }
    }

    /// Debug destinations stay local; no production navigation case is needed.
    enum LocalRoute: Hashable {
        case notes(UUID), plates(UUID), trackingType(UUID)
        case plateSetup(UUID), barWeight(UUID), setOptions(UUID, UUID)
    }

    static func openRootRouteIfRequested(library: WatchWorkoutLibrary, navigation: WatchNavigation) {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "--light-watch-demo"), args.indices.contains(flag + 1) else { return }
        switch args[flag + 1] {
        case "home": navigation.path = []
        case "saved": navigation.path = [.saved]
        case "saved-detail":
            if let workout = library.savedWorkouts.first { navigation.path = [.saved, .savedDetail(workout.id)] }
        case "saved-editor":
            if let workout = library.savedWorkouts.first { navigation.path = [.saved, .editSaved(workout.id)] }
        case "history": navigation.path = [.history]
        case "history-detail":
            if let workout = library.history.first { navigation.path = [.history, .historyDetail(workout.workoutID)] }
        case "settings": navigation.path = [.settings]
        case "summary":
            navigation.savedWorkout = library.history.first
            navigation.path = [.done]
        default: break
        }
    }

    static func openRouteIfRequested(snapshot: WatchWorkoutSnapshot, navigation: WatchNavigation) -> LocalRoute? {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "--light-watch-demo"), args.indices.contains(flag + 1),
              navigation.path == [.workout] || navigation.path == [.workout, .rest] else { return nil }
        let mode = args[flag + 1]
        if ["after-log", "rpe-auto", "after-rest"].contains(mode) { return nil }
        guard navigation.path == [.workout],
              let exercise = snapshot.nextSet?.exercise ?? snapshot.exercises.first,
              let set = snapshot.nextSet?.set ?? exercise.sets.first else { return nil }
        switch mode {
        case "active", "now": navigation.workoutPage = .now
        case "notes": return .notes(snapshot.exercises.first?.id ?? exercise.id)
        case "plates": return .plates(exercise.id)
        case "plate-setup": return .plateSetup(exercise.id)
        case "bar-weight": return .barWeight(exercise.id)
        case "set-options": return .setOptions(exercise.id, set.id)
        case "tracking-type": return .trackingType(exercise.id)
        case "rpe", "rpe-manual": navigation.path.append(.rpe(exercise.id, set.id))
        case "rest-picker": navigation.path.append(.restTimer(exercise.id))
        case "warmup": navigation.path.append(.warmup(exercise.id))
        case "effort": navigation.path.append(.effort)
        case "controls": navigation.workoutPage = .controls
        case "exercises": navigation.workoutPage = .exercises
        case "exercise": navigation.path.append(.exercise(exercise.id))
        case "options": navigation.path.append(.exerciseSettings(exercise.id))
        case "set": navigation.path.append(.set(exercise.id, set.id))
        case "set-type": navigation.path.append(.setType(exercise.id, set.id))
        case "superset": navigation.path.append(.superset(exercise.id))
        case "catalog": navigation.path.append(.catalog(nil))
        case "finish": navigation.path.append(.finish)
        case "discard": navigation.path.append(.discard)
        default: break // Now is the default; active Rest is restored normally.
        }
        return nil
    }

    static func seedIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "--light-watch-demo"), args.indices.contains(flag + 1) else { return }
        let mode = args[flag + 1]
        let demoWeight = args.firstIndex(of: "--demo-weight").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? 135
        let catalog = WatchBundledLibrary.load().exercises
        let group = UUID()
        func exercise(_ name: String, catalogID: String, index: Int) -> WatchWorkoutExercise {
            // Demo identity must survive display-name changes and catalog sorting.
            let pick = catalog.first { $0.id.uuidString == catalogID }
                ?? catalog.first {
                    $0.name.localizedCaseInsensitiveContains(name)
                        || ($0.aliases?.contains { $0.localizedCaseInsensitiveContains(name) } ?? false)
                }
            let id = UUID()
            return WatchWorkoutExercise(id: id, order: index, name: pick?.name ?? name,
                sets: (1...3).map { WatchWorkoutSet(order: $0, weight: demoWeight, reps: 8,
                    previousWeight: 130, previousReps: 8, completed: index == 1 && $0 == 1) },
                restTimerDuration: mode == "rest-picker" ? 165 : 90,
                muscleGroup: pick?.muscle, exerciseUuid: pick?.id, imageURL: pick?.imageURL,
                supersetID: group, comment: index == 1 ? "Controlled tempo today" : nil,
                exerciseNote: index == 1 ? "Perform lateral flexion; keep elbows soft" : nil,
                routineNote: index == 1 ? "Superset with lateral raises" : nil,
                routineExerciseID: index == 1 ? id : nil)
        }
        let exercises = [
            exercise("Barbell Bench Press", catalogID: "C0D3C3CD-9F1F-4A89-B845-DAB5923B22A7", index: 1),
            exercise("Dumbbell Row", catalogID: "13664A80-F9E2-5E0E-A2D5-F5EEEB1769EF", index: 2)
        ]
        if let first = exercises.first, let id = first.exerciseUuid {
            ExerciseNotes.setNote(first.exerciseNote, for: id, notify: false)
        }
        var snapshot = WatchWorkoutSnapshot(workoutID: UUID(), title: "Upper Body", startDate: Date().addingTimeInterval(-240),
            exercises: exercises, restTimerEnd: ["rest", "after-log", "rpe-auto"].contains(mode) ? Date().addingTimeInterval(90) : nil, weightUnit: .pound)
        snapshot.selectedSetID = WatchWorkoutEditing.nextSet(in: snapshot)
        snapshot.activeEnergyKilocalories = args.firstIndex(of: "--demo-energy").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? 1_240
        if ["rpe", "rpe-manual"].contains(mode), let next = snapshot.nextSet,
           let exercise = snapshot.exercises.firstIndex(where: { $0.id == next.exercise.id }),
           let set = snapshot.exercises[exercise].sets.firstIndex(where: { $0.id == next.set.id }) {
            snapshot.exercises[exercise].sets[set].rpe = 5
        }
        if mode == "effort" { snapshot.sessionEffort = 5 }
        if mode == "empty" { snapshot.exercises = [] }
        if mode == "complete" || mode == "after-final-rest" {
            for e in snapshot.exercises.indices { for s in snapshot.exercises[e].sets.indices { snapshot.exercises[e].sets[s].completed = true } }
        }
        var history = snapshot
        history.workoutID = UUID(); history.startDate = Date().addingTimeInterval(-90_000)
        history.endDate = history.startDate.addingTimeInterval(2_400); history.isFinished = true
        let saved = WatchSavedWorkout(id: UUID(), title: "Upper Body", exercises: exercises, weightUnit: .pound,
            comment: "Saved workout", updatedAt: Date())
        do {
            try WatchWorkoutStore.shared.clear()
            try WatchWorkoutStore.shared.replaceLibrary(WatchWorkoutLibrary(generatedAt: Date(), exercises: catalog,
                savedWorkouts: [saved], history: [history], weightUnit: .pound))
            let libraryOnly = ["home", "saved", "saved-detail", "saved-editor", "history", "history-detail", "settings", "summary"]
            if !libraryOnly.contains(mode) { try WatchWorkoutStore.shared.replaceSnapshot(snapshot) }
        } catch { assertionFailure("Could not prepare Watch fixture: \(error)") }
    }
}
#endif

extension Notification.Name {
    static let lightOpenWorkout = Notification.Name("Light.openWorkout")
}
