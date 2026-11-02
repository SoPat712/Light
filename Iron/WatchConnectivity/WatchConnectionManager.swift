//
//  WatchConnectionManager.swift
//  Iron
//
//  Created by Karim Abou Zeid on 02.11.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import Foundation
import WatchConnectivity
import CoreData
import Combine
import HealthKit
import WorkoutDataKit
import UIKit
import Intents
import os.log

/// Isolated from connection status so sensor updates do not invalidate the
/// complete workout logger. Only the small metrics row observes this object.
final class WatchWorkoutMetricsStore: ObservableObject {
    @Published private(set) var latest: WatchWorkoutMetrics?

    func receive(_ metrics: WatchWorkoutMetrics, workoutID: UUID, now: Date = Date()) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard metrics.accepts(after: latest, for: workoutID, at: now) else { return }
        latest = metrics
    }

    func clear() {
        DispatchQueue.main.async { self.latest = nil }
    }
}

/// Before activation, retain lifecycle commands in order and only the latest
/// value for each legacy workout field. Snapshots/preferences keep their own
/// existing coalescing and content-deduplication paths.
struct PendingWatchUserInfo {
    private var payloads: [[String: Any]] = []

    mutating func enqueue(_ payload: [String: Any]) {
        let fields = [PayloadKey.updateWorkoutSessionStart, PayloadKey.updateWorkoutSessionEnd,
                      PayloadKey.updateWorkoutSessionRestTimer, PayloadKey.updateWorkoutSessionSelectedSet]
        if payload.count == 1, let field = fields.first(where: { payload[$0] != nil }),
           let arguments = payload[field] as? [String: Any],
           let workoutID = arguments[PayloadKey.Arg.uuid] as? String {
            payloads.removeAll {
                ($0[field] as? [String: Any])?[PayloadKey.Arg.uuid] as? String == workoutID
            }
        }
        payloads.append(payload)
    }

    mutating func takeAll() -> [[String: Any]] {
        let result = payloads
        payloads.removeAll()
        return result
    }
}

/// The following behaviour was tested on watchOS 6.2 and iOS 13.4:
/// When the watch app is not reachable, data often won't arrive until the app is opened. Sometimes the data arrives, but then the watch only answers when the watch app is opened.

/// - BUG:
///     When using the intents extension, and the app is completely closed and then launched by Siri in the background, the app restarts *every* time before receiving a message from the watch. Because of that, when the prepared message arrives, the app is restarted and the preparedHandler is nil.
///     I think this is a bug, because when the app was already in background before that, this doesn't happen.
///     Tested on iOS 13.4, watchOS 6.2, Xcode 11.

class WatchConnectionManager: NSObject, ObservableObject {
    static let shared = WatchConnectionManager()

    /// Drives every phone surface that displays pairing, installation, or
    /// reachability. WCSession changes arrive through delegate callbacks, so
    /// expose a lightweight revision instead of leaving settings stale until
    /// the user manually refreshes.
    @Published private(set) var connectionRevision = 0
    @Published private(set) var watchWorkoutAwaitingOpen: WatchWorkoutSnapshot?
    let liveMetrics = WatchWorkoutMetricsStore()
    
    private let session = WCSession.default

    private struct EventLedger: Codable {
        var recentEventIDs: [UUID] = []
        var latestSequenceByField: [String: Int64] = [:]
        var latestSequenceByWorkout: [String: Int64]? = nil
        var watchStartedWorkoutIDs: Set<UUID>? = nil
    }

    private static let eventLedgerDefaultsKey = "watchWorkoutEventLedger.v1"
    private static let deletedWorkoutIDsDefaultsKey = "watchWorkoutDeletedIDs.v1"
    private static let finalizationDatesDefaultsKey = "watchWorkoutFinalizationDates.v1"
    private static let finalizationValuesDefaultsKey = finalizationDatesDefaultsKey + ".setValues"
    private static let terminalDefaultsLock = NSLock()
    private var eventLedger: EventLedger
    private var selectedWatchSetUuid: UUID?
    private var pendingSnapshot: WatchWorkoutSnapshot?
    private var pendingSnapshotBuild: DispatchWorkItem?
    private var pendingWatchAdoption = false
    private var lastSentSnapshotContent: Data?
    private var workoutThumbnailCache: [UUID: Data] = [:]
    private var lastSnapshotRevision: Int64 = 0
    private var librarySaveObserver: AnyCancellable?
    private let connectivityQueue = DispatchQueue(label: "Light.phoneConnectivity", qos: .utility)
    // Accessed only on connectivityQueue; activation drains each pending item once.
    private var pendingUserInfo = PendingWatchUserInfo()
    private var pendingEventAcknowledgements = Set<UUID>()
    private lazy var preferenceSync = WatchPreferenceSyncManager(queue: connectivityQueue,
        transmit: { [weak self] payload in
            guard let self, self.isActivated else { return false }
            do {
                try self.updateApplicationContextIfChanged(self.applicationContextIncludingPreferences(payload))
            } catch {
                os_log("Could not sync Watch preferences: %@", log: .watch, type: .error, error.localizedDescription)
                return false
            }
            if self.isReachable {
                self.session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
            }
            return true
        }, didChangeLocally: { [weak self] changes in
            guard changes.contains(.tracking) || changes.contains(.notes) else { return }
            self?.syncCurrentWorkoutSnapshot()
            self?.scheduleWorkoutLibrarySync()
        })
    #if DEBUG
    private var healthTestModeObserver: AnyCancellable?
    private var lastSentHealthTestMode: Bool?
    private var healthTestModeEnabledObserver: AnyCancellable?
    #endif
    private var exerciseLibraryObserver: AnyCancellable?
    private var logRPEObserver: AnyCancellable?
    private var lastSentLogRPE: Bool?
    private var pendingLibrarySync: DispatchWorkItem?
    private var libraryBuildGeneration: UInt64 = 0
    private var retainedTransferFiles = Set<URL>()

    private struct PendingPrepareRequest {
        let workoutID: UUID
        let preparedHandler: PrepareHandler
        let errorHandler: StartWatchCompanionErrorHandler?
    }
    private var pendingPrepareRequest: PendingPrepareRequest?

    private static let libraryTransferMarker = "ironWorkoutLibrary"
    private static let libraryFilePrefix = "iron-watch-library-"
    private static let snapshotTransferMarker = "ironWorkoutSnapshot"
    private static let snapshotFilePrefix = "iron-watch-snapshot-"
    private static let eventTransferMarker = "ironWorkoutEvent"
    private static let snapshotMessageLimit = 48 * 1024
    private static let deferredWorkoutsFilename = "watch-deferred-workouts-v1.json"

    private struct DeferredWatchWorkouts: Codable {
        var snapshots: [String: WatchWorkoutSnapshot] = [:]
    }

    private override init() {
        if let data = UserDefaults.standard.data(forKey: Self.eventLedgerDefaultsKey),
           let ledger = WatchWorkoutWire.decode(EventLedger.self, from: data) {
            eventLedger = ledger
        } else {
            eventLedger = EventLedger()
        }
        super.init()
        refreshWatchWorkoutAwaitingOpen()
        observeLibraryChanges()
        _ = preferenceSync
        logRPEObserver = NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification, object: UserDefaults.appGroup)
            .map { _ in SettingsStore.shared.logRPE }
            .prepend(SettingsStore.shared.logRPE)
            .removeDuplicates()
            .debounce(for: .milliseconds(750), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncLogRPE() }
        #if DEBUG
        healthTestModeEnabledObserver = NotificationCenter.default.publisher(for: SettingsStore.healthTestModeEnabledNotification)
            .filter { ($0.object as? SettingsStore) === SettingsStore.shared }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.persistActiveTestProvenance() }
        healthTestModeObserver = NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification, object: UserDefaults.appGroup)
            .map { _ in SettingsStore.shared.healthTestMode }
            .prepend(SettingsStore.shared.healthTestMode)
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .milliseconds(750), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncHealthTestMode()
                self?.syncCurrentWorkoutSnapshot()
            }
        #endif
    }

    #if DEBUG
    private func persistActiveTestProvenance() {
        do {
            try Workout.markCurrentWorkoutAsHealthTestWorkout(
                in: WorkoutDataStorage.shared.persistentContainer.viewContext)
        } catch {
            os_log("Could not persist active test workout provenance: %@", log: .watch, type: .error, error.localizedDescription)
        }
    }

    private func syncHealthTestMode() {
        persistActiveTestProvenance()
        let enabled = SettingsStore.shared.healthTestMode
        let workoutID = currentWatchWorkoutUuid
        connectivityQueue.async {
            guard self.isActivated else { return }
            var context = self.applicationContextIncludingPreferences([PayloadKey.healthTestMode: enabled])
            // Keep the durable active snapshot, but never resurrect an archive.
            if let data = context[PayloadKey.workoutSnapshot] as? Data,
               let snapshot = WatchWorkoutWire.decode(WatchWorkoutSnapshot.self, from: data),
               snapshot.workoutID != workoutID || snapshot.isFinishedRecord {
                context.removeValue(forKey: PayloadKey.workoutSnapshot)
            }
            do { try self.updateApplicationContextIfChanged(context) }
            catch {
                os_log("Could not sync Health test preference: %@", log: .watch, type: .error, error.localizedDescription)
                return
            }
            if enabled != self.lastSentHealthTestMode, self.isReachable {
                self.session.sendMessage([PayloadKey.healthTestMode: enabled], replyHandler: nil, errorHandler: nil)
                self.lastSentHealthTestMode = enabled
            }
            if enabled { self.liveMetrics.clear() }
        }
    }
    #endif

    /// The phone is authoritative for Log RPE. Only local edits and connection
    /// transitions send it; receiving other preferences never schedules a send.
    private func syncLogRPE() {
        let enabled = SettingsStore.shared.logRPE
        connectivityQueue.async {
            guard self.isActivated else { return }
            let payload: [String: Any] = ["logRPE": enabled]
            do {
                try self.updateApplicationContextIfChanged(self.applicationContextIncludingPreferences(payload))
            } catch {
                os_log("Could not sync Log RPE preference: %@", log: .watch, type: .error, error.localizedDescription)
                return
            }
            if self.isReachable, self.lastSentLogRPE != enabled {
                self.session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
                self.lastSentLogRPE = enabled
            }
        }
    }

    private func applicationContextIncludingPreferences(_ payload: [String: Any]) -> [String: Any] {
        var context = session.applicationContext
        // This helper runs on the transport queue. Read the thread-safe value,
        // rather than crossing into the UI's observable settings facade.
        context["logRPE"] = UserDefaults.appGroup.logRPE
        context.merge(PlateCalculatorPreferences.load().dictionaryRepresentation) { _, new in new }
        context.merge(SetTrackingPreferences.load().dictionaryRepresentation) { _, new in new }
        context.merge(ExerciseNotes.load().dictionaryRepresentation) { _, new in new }
        context.merge(payload) { _, new in new }
        if let data = context[PayloadKey.workoutSnapshot] as? Data,
           let snapshot = WatchWorkoutWire.decode(WatchWorkoutSnapshot.self, from: data),
           Self.phoneFinalizationDate(snapshot.workoutID) != nil || Self.wasDeletedOnPhone(snapshot.workoutID) {
            context.removeValue(forKey: PayloadKey.workoutSnapshot)
        }
        return context
    }

    private func updateApplicationContextIfChanged(_ context: [String: Any]) throws {
        dispatchPrecondition(condition: .onQueue(connectivityQueue))
        guard !WatchSyncContent.contextsEqual(context, session.applicationContext) else { return }
        try session.updateApplicationContext(context)
    }

    private func observeLibraryChanges() {
        librarySaveObserver = NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)
            .filter { notification in
                guard let savedContext = notification.object as? NSManagedObjectContext,
                      savedContext.persistentStoreCoordinator === WorkoutDataStorage.shared.persistentContainer.persistentStoreCoordinator else {
                    return false
                }
                return [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey].contains { key in
                    (notification.userInfo?[key] as? Set<NSManagedObject>)?.contains {
                        $0 is Workout || $0 is WorkoutExercise || $0 is WorkoutSet ||
                        $0 is WorkoutPlan || $0 is WorkoutRoutine ||
                        $0 is WorkoutRoutineExercise || $0 is WorkoutRoutineSet
                    } == true
                }
            }
            .map { notification -> [UUID] in
                let deleted = Self.recordDeletedWorkouts(from: notification)
                let updated = notification.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject> ?? []
                let finished = updated.compactMap { $0 as? Workout }.filter {
                    !$0.isCurrentWorkout && !$0.isImported && $0.end != nil
                }
                for workout in finished { Self.recordPhoneFinalization(workout) }
                return deleted + finished.compactMap(\.uuid)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] terminalIDs in
                for id in terminalIDs { self?.retireSnapshotDelivery(workoutID: id) }
                self?.scheduleWorkoutLibrarySync()
            }

        exerciseLibraryObserver = ExerciseStore.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleWorkoutLibrarySync() }
    }
    
    func activateSession() {
        guard WCSession.isSupported() else {
            os_log("WatchConnectivity is not supported on this device", log: .watch, type: .error)
            return
        }
        session.delegate = self
        session.activate()
    }

    /// Re-reads the current pairing/install/reachability state for settings.
    /// An already-activated WCSession does not need a synthetic delay: publish
    /// its current values immediately. Otherwise the activation delegate will
    /// publish when WatchConnectivity has actually completed the request.
    func refreshConnectionStatus() {
        guard WCSession.isSupported() else {
            publishConnectionStatus()
            return
        }

        session.delegate = self
        if session.activationState == .activated {
            publishConnectionStatus()
        } else {
            session.activate()
        }
    }
    
    var isReachable: Bool {
        isActivated && session.isReachable
    }
    
    var isActivated: Bool {
        session.activationState == .activated
    }

    var isPaired: Bool {
        isActivated && session.isPaired
    }

    var isWatchAppInstalled: Bool {
        isActivated && session.isWatchAppInstalled
    }

    private func publishConnectionStatus() {
        DispatchQueue.main.async {
            self.connectionRevision &+= 1
        }
    }
    
    typealias PrepareHandler = (() -> Void)
    private var preparedHandler: PrepareHandler?
    
    typealias StartWatchCompanionErrorHandler = ((Error) -> Void)
    
    let selectedSetChangePublisher = PassthroughSubject<(WorkoutSet?, UUID), Never>()
    var selectedSetChangePublisherCancellable: Cancellable?
    var selectedSetCancellable: Cancellable?
}

extension WatchConnectionManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        os_log("Session activation completed isActivated=%@ error=%@", log: .watch, type: .info, String(describing: activationState == .activated), error?.localizedDescription ?? "nil") // printing activationState directly doesn't work
        publishConnectionStatus()
        DispatchQueue.main.async {
            guard activationState == .activated else {
                if let pending = self.pendingPrepareRequest {
                    self.pendingPrepareRequest = nil
                    pending.errorHandler?(error ?? GenericError(description: "Activating Watch connectivity was unsuccessful"))
                }
                return
            }
            self.connectivityQueue.async {
                self.preferenceSync.applyReceived(session.receivedApplicationContext)
                do {
                    try self.updateApplicationContextIfChanged(self.applicationContextIncludingPreferences([:]))
                } catch {
                    os_log("Could not clear obsolete Watch context: %@", log: .watch, type: .error, error.localizedDescription)
                }
                self.flushPendingUserInfo()
                let acknowledgements = self.pendingEventAcknowledgements
                self.pendingEventAcknowledgements.removeAll()
                for eventID in acknowledgements { self.acknowledge(eventID: eventID, replyHandler: nil) }
                self.preferenceSync.requestSync()
            }
            self.syncLogRPE()
            self.resumePendingPrepareRequest()
            #if DEBUG
            self.syncHealthTestMode()
            #endif
            if let snapshot = self.pendingSnapshot {
                self.sendWorkoutSnapshot(snapshot)
            } else {
                self.syncCurrentWorkoutSnapshot()
            }
            self.scheduleWorkoutLibrarySync(immediate: true)
        }
    }
    
    func sessionDidBecomeInactive(_ session: WCSession) {
        os_log("Session did become inactive", log: .watch, type: .debug)
        publishConnectionStatus()
        liveMetrics.clear()
    }
    
    func sessionDidDeactivate(_ session: WCSession) {
        os_log("Session was deactivated", log: .watch, type: .debug)
        publishConnectionStatus()
        connectivityQueue.async {
            self.lastSentSnapshotContent = nil
            self.lastSentLogRPE = nil
            #if DEBUG
            self.lastSentHealthTestMode = nil
            #endif
        }
        preferenceSync.resetTransmission()
        // connect to the new Apple Watch
        os_log("Reactivating session", log: .watch, type: .debug)
        activateSession()
    }
    
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        os_log("Received Watch application context", log: .watch, type: .debug)
        
        receive(message: applicationContext)
    }
    
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any]) {
        os_log("Received Watch user info", log: .watch, type: .debug)
        
        receive(message: userInfo)
    }
    
    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        os_log("Received Watch message", log: .watch, type: .debug)
        
        receive(message: message)
    }
    
    func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        os_log("Received Watch message with reply", log: .watch, type: .debug)
        
        receive(message: message, replyHandler: replyHandler)
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard file.metadata?[Self.eventTransferMarker] as? Bool == true else { return }
        do {
            let data = try Data(contentsOf: file.fileURL)
            connectivityQueue.async {
                guard let event = WatchWorkoutWire.decode(WatchWorkoutEvent.self, from: data) else {
                    os_log("Could not decode transferred Watch workout event", log: .watch, type: .error)
                    return
                }
                self.handleWorkoutEvent(event, replyHandler: nil)
            }
        } catch {
            os_log("Could not read transferred Watch workout event: %@", log: .watch, type: .error,
                   error.localizedDescription)
        }
    }
    
    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.activationState == .activated && session.isReachable
        os_log("Session reachability did change isReachable=%@", log: .watch, type: .debug, String(describing: reachable))
        publishConnectionStatus()
        guard reachable else { return }
        DispatchQueue.main.async {
            self.preferenceSync.requestSync()
            self.syncLogRPE()
            #if DEBUG
            self.syncHealthTestMode()
            #endif
            self.syncCurrentWorkoutSnapshot()
            self.scheduleWorkoutLibrarySync(immediate: true)
        }
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        let paired = session.activationState == .activated && session.isPaired
        let installed = session.activationState == .activated && session.isWatchAppInstalled
        os_log(
            "Watch state changed paired=%@ installed=%@",
            log: .watch,
            type: .debug,
            String(describing: paired),
            String(describing: installed)
        )
        publishConnectionStatus()
        if paired && installed {
            scheduleWorkoutLibrarySync(immediate: true)
        }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let file = fileTransfer.file
        let isLibrary = file.metadata?[Self.libraryTransferMarker] as? Bool == true
        let isSnapshot = file.metadata?[Self.snapshotTransferMarker] as? Bool == true
        guard isLibrary || isSnapshot else { return }
        connectivityQueue.async {
            if self.retainedTransferFiles.remove(file.fileURL) != nil {
                try? FileManager.default.removeItem(at: file.fileURL)
            }
            if let error {
                os_log("Watch workout file transfer failed: %@", log: .watch, type: .error,
                       error.localizedDescription)
            }
        }
    }
}

extension WatchConnectionManager {
    private func receive(message: [String : Any], replyHandler: (([String: Any]) -> Void)? = nil) {
        connectivityQueue.async { self.receiveOnConnectivityQueue(message, replyHandler: replyHandler) }
    }

    private func receiveOnConnectivityQueue(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)?) {
        preferenceSync.applyReceived(message)
        if message[PayloadKey.requestWorkoutLibrary] as? Bool == true {
            scheduleWorkoutLibrarySync(immediate: true)
            replyHandler?([:])
        } else if message[PayloadKey.requestWorkoutSnapshot] as? Bool == true {
            syncCurrentWorkoutSnapshot(allowWatchAdoption: true)
            replyHandler?([:])
        } else if let data = message[PayloadKey.workoutMetrics] as? Data,
           let metrics = WatchWorkoutWire.decode(WatchWorkoutMetrics.self, from: data) {
            DispatchQueue.main.async {
                let context = WorkoutDataStorage.shared.persistentContainer.viewContext
                guard let workout = try? context.fetch(Workout.currentWorkoutFetchRequest).first,
                      workout.isCurrentWorkout, !workout.isImported,
                      workout.uuid == metrics.workoutID else { return }
                if SettingsStore.shared.healthTestMode || workout.healthExportState == "test" {
                    self.liveMetrics.clear()
                    return
                }
                self.liveMetrics.receive(metrics, workoutID: metrics.workoutID)
            }
            replyHandler?([:])
        } else if let eventData = message[PayloadKey.workoutEvent] as? Data,
           let event = WatchWorkoutWire.decode(WatchWorkoutEvent.self, from: eventData) {
            handleWorkoutEvent(event, replyHandler: replyHandler)
        } else if let prepared = message[PayloadKey.preparedWorkoutSession] as? Bool, prepared {
            DispatchQueue.main.async { self.handlePreparedWorkoutSessionMessage() }
            replyHandler?([:])
        } else {
            replyHandler?([:])
        }
    }
    
    private func handlePreparedWorkoutSessionMessage() {
        os_log("Handling prepared workout session message", log: .watch)
        
        guard let preparedHandler = self.preparedHandler else {
            // if we receive this message and no one is listening for this, tell the watch to unprepare
            os_log("No prepare handler is set", log: .watch, type: .error)
            ignorePreparedWatchWorkout()
            return
        }
        
        preparedHandler()
        self.preparedHandler = nil
    }
}

// MARK: - Durable watch edits
extension WatchConnectionManager {
    @discardableResult
    static func recordDeletedWorkouts(from notification: Notification,
                                     defaults: UserDefaults = .appGroup) -> [UUID] {
        let deleted = notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject> ?? []
        let ids = deleted.compactMap { ($0 as? Workout)?.uuid }
        recordDeletedWorkoutIDs(ids, defaults: defaults)
        return ids
    }

    static func recordDeletedWorkoutIDs(_ ids: [UUID], defaults: UserDefaults = .appGroup) {
        guard !ids.isEmpty else { return }
        terminalDefaultsLock.lock()
        defer { terminalDefaultsLock.unlock() }
        var retained = (defaults.stringArray(forKey: deletedWorkoutIDsDefaultsKey) ?? []).compactMap(UUID.init(uuidString:))
        for id in ids { retained = WatchWorkoutPersistence.retainingTerminalID(id, in: retained) }
        defaults.set(retained.map(\.uuidString), forKey: deletedWorkoutIDsDefaultsKey)
    }

    static func wasDeletedOnPhone(_ id: UUID, defaults: UserDefaults = .appGroup) -> Bool {
        terminalDefaultsLock.lock()
        defer { terminalDefaultsLock.unlock() }
        return defaults.stringArray(forKey: deletedWorkoutIDsDefaultsKey)?.contains(id.uuidString) == true
    }

    static func recordPhoneFinalization(_ workout: Workout, at date: Date = Date(), defaults: UserDefaults = .appGroup) {
        guard let id = workout.uuid, !workout.isImported,
              phoneFinalizationDate(id, defaults: defaults) == nil else { return }
        var values: [String: [String: String]] = [:]
        for exercise in workout.workoutExercises?.array as? [WorkoutExercise] ?? [] {
            for set in exercise.workoutSets?.array as? [WorkoutSet] ?? [] where set.isCompleted {
                if let setID = set.uuid { values[setID.uuidString] = finalizationValues(for: set) }
            }
        }
        recordPhoneFinalization(id, at: date, defaults: defaults, setValues: values)
    }

    static func recordPhoneFinalization(_ id: UUID, at date: Date = Date(), defaults: UserDefaults = .appGroup,
                                        setValues: [String: [String: String]]? = nil) {
        terminalDefaultsLock.lock()
        defer { terminalDefaultsLock.unlock() }
        var dates = defaults.dictionary(forKey: finalizationDatesDefaultsKey) as? [String: Date] ?? [:]
        guard dates[id.uuidString] == nil else { return }
        dates[id.uuidString] = date
        let retained = Set(dates.keys.sorted {
            let first = dates[$0]!, second = dates[$1]!
            return first == second ? $0 < $1 : first > second
        }.prefix(50))
        var baselines = defaults.dictionary(forKey: finalizationValuesDefaultsKey) as? [String: [String: [String: String]]] ?? [:]
        if let setValues { baselines[id.uuidString] = setValues }
        baselines = baselines.filter { retained.contains($0.key) }
        if !baselines.isEmpty || defaults.object(forKey: finalizationValuesDefaultsKey) != nil {
            defaults.set(baselines, forKey: finalizationValuesDefaultsKey)
        }
        defaults.set(Dictionary(uniqueKeysWithValues: retained.map { ($0, dates[$0]!) }),
                     forKey: finalizationDatesDefaultsKey)
    }

    /// Canonical model values, including distinct nil tokens. This is storage
    /// metadata, never a localized display value or a preference notification.
    private static func finalizationValues(for set: WorkoutSet) -> [String: String] {
        func token<T>(_ value: T?) -> String { value.map { "1" + String(describing: $0) } ?? "0" }
        return ["weight": token(set.weight?.doubleValue), "reps": token(set.repetitions?.intValue),
                "rpe": token(set.rpeValue), "tag": token(set.tagValue?.rawValue),
                "duration": token(set.durationValue), "distance": token(set.distanceValue),
                "comment": token(set.comment), "minTargetReps": token(set.minTargetRepetitionsValue),
                "maxTargetReps": token(set.maxTargetRepetitionsValue)]
    }

    static func phoneFinalizationDate(_ id: UUID, defaults: UserDefaults = .appGroup) -> Date? {
        terminalDefaultsLock.lock()
        defer { terminalDefaultsLock.unlock() }
        return defaults.dictionary(forKey: finalizationDatesDefaultsKey)?[id.uuidString] as? Date
    }

    static func removingWorkoutSnapshot(_ id: UUID, from context: [String: Any]) -> [String: Any] {
        guard let data = context[PayloadKey.workoutSnapshot] as? Data,
              WatchWorkoutWire.decode(WatchWorkoutSnapshot.self, from: data)?.workoutID == id else { return context }
        var context = context
        context.removeValue(forKey: PayloadKey.workoutSnapshot)
        return context
    }

    private func retireSnapshotDelivery(workoutID: UUID) {
        Self.recordPhoneFinalization(workoutID)
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.retireSnapshotDelivery(workoutID: workoutID) }
            return
        }
        if pendingSnapshot?.workoutID == workoutID { pendingSnapshot = nil }
        if currentWatchWorkoutUuid == workoutID {
            pendingSnapshotBuild?.cancel()
            pendingSnapshotBuild = nil
            pendingWatchAdoption = false
        }
        connectivityQueue.async {
            self.cancelOutstandingTransfers(marker: Self.snapshotTransferMarker, workoutID: workoutID)
            self.lastSentSnapshotContent = nil
            guard self.isActivated else { return }
            let context = Self.removingWorkoutSnapshot(workoutID, from: self.applicationContextIncludingPreferences([:]))
            do { try self.updateApplicationContextIfChanged(context) }
            catch {
                os_log("Could not clear ended Watch snapshot: %@", log: .watch, type: .error, error.localizedDescription)
            }
        }
    }

    struct DeferredWatchEventEffects {
        let perform: () -> Void

        static var none: DeferredWatchEventEffects { DeferredWatchEventEffects(perform: {}) }
    }

    /// Captures only changes made by one Watch event. Pre-existing unsaved user
    /// edits are processed before the temporary undo group begins and therefore
    /// survive an event save failure.
    static func persistWatchEventMutation(
        in context: NSManagedObjectContext,
        save: () throws -> Void,
        mutation: () throws -> DeferredWatchEventEffects
    ) throws -> DeferredWatchEventEffects {
        try context.persistMutation(save: save, mutation: mutation)
    }

    static func commitWatchEventMutation(
        in context: NSManagedObjectContext,
        save: () throws -> Void,
        mutation: () throws -> DeferredWatchEventEffects,
        didPersist: () -> Void
    ) throws {
        let effects = try persistWatchEventMutation(
            in: context,
            save: save,
            mutation: mutation
        )
        effects.perform()
        didPersist()
    }

    private func handleWorkoutEvent(_ event: WatchWorkoutEvent,
                                    replyHandler: (([String: Any]) -> Void)?) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.handleWorkoutEvent(event, replyHandler: replyHandler) }
            return
        }
        guard event.schemaVersion <= WatchWorkoutWire.schemaVersion else {
            os_log("Ignoring unsupported Watch workout event version=%d", log: .watch, type: .error, event.schemaVersion)
            replyHandler?([:])
            return
        }

        let context = WorkoutDataStorage.shared.persistentContainer.viewContext
        context.perform {
            // Both devices advance the same logical clock. After an offline
            // Watch burst, a phone response must be newer than that projection.
            self.lastSnapshotRevision = max(self.lastSnapshotRevision, event.snapshot?.revision ?? 0)
            if self.eventLedger.recentEventIDs.contains(event.id) {
                self.acknowledge(eventID: event.id, replyHandler: replyHandler)
                return
            }

            let fieldKey = self.sequenceFieldKey(for: event)
            if let lastSequence = self.eventLedger.latestSequenceByField[fieldKey],
               lastSequence >= event.sequence {
                self.recordProcessed(event, fieldKey: fieldKey)
                self.acknowledge(eventID: event.id, replyHandler: replyHandler)
                return
            }

            do {
                if event.kind == .savedWorkoutUpserted || event.kind == .savedWorkoutDeleted {
                    try Self.commitWatchEventMutation(
                        in: context,
                        save: { if context.hasChanges { try context.save() } },
                        mutation: { try self.applySavedWorkoutEvent(event, in: context) },
                        didPersist: {
                            self.recordProcessed(event, fieldKey: fieldKey)
                            self.acknowledge(eventID: event.id, replyHandler: replyHandler)
                            self.scheduleWorkoutLibrarySync()
                        }
                    )
                    return
                }

                if Self.wasDeletedOnPhone(event.workoutID) {
                    try self.removeDeferredWorkout(event.workoutID)
                    self.recordProcessed(event, fieldKey: fieldKey)
                    self.acknowledge(eventID: event.id, replyHandler: replyHandler)
                    return
                }

                guard let workout = try self.resolveWorkout(for: event, in: context) else {
                    if event.kind == .workoutDiscarded {
                        try self.removeDeferredWorkout(event.workoutID)
                        self.recordProcessed(event, fieldKey: fieldKey)
                        self.acknowledge(eventID: event.id, replyHandler: replyHandler)
                        return
                    }
                    if let snapshot = event.snapshot, !snapshot.isFinishedRecord {
                        let hasPhoneCurrent = try context.fetch(Workout.currentWorkoutFetchRequest).contains {
                            $0.uuid != event.workoutID
                        }
                        let wasDeferred = try self.readDeferredWorkouts().snapshots[event.workoutID.uuidString] != nil
                        if hasPhoneCurrent || wasDeferred {
                            // Keep updating the handoff even if the phone's
                            // competing workout ended before the user opened it.
                            try self.persistDeferredWorkout(snapshot)
                            self.recordProcessed(event, fieldKey: fieldKey)
                            self.acknowledge(eventID: event.id, replyHandler: replyHandler)
                            return
                        }
                    }
                    // The workout may have been removed on the phone while the
                    // watch was offline. Acknowledge so it does not retry forever.
                    self.recordProcessed(event, fieldKey: fieldKey)
                    self.acknowledge(eventID: event.id, replyHandler: replyHandler)
                    return
                }

                try Self.commitWatchEventMutation(
                    in: context,
                    save: {
                        if context.hasChanges { try context.save() }
                    },
                    mutation: { try self.applyWatchEventModelMutation(event, to: workout, in: context) },
                    didPersist: {
                        if !workout.isDeleted {
                            self.persistRoutineNoteLinks(from: event.snapshot, to: workout)
                        }
                        if event.kind == .workoutCreated, workout.isCurrentWorkout {
                            self.currentWatchWorkoutUuid = workout.uuid
                        }
                        if event.kind == .workoutFinished || event.kind == .workoutDiscarded ||
                            event.snapshot?.isFinishedRecord == true || workout.isCurrentWorkout {
                            try? self.removeDeferredWorkout(event.workoutID)
                        }
                        self.recordProcessed(event, fieldKey: fieldKey)
                        self.acknowledge(eventID: event.id, replyHandler: replyHandler)
                    }
                )

                if event.kind != .workoutDiscarded,
                   !workout.isDeleted,
                   workout.isCurrentWorkout {
                    self.syncCurrentWorkoutSnapshot()
                }
            } catch {
                os_log("Could not apply Watch workout event %@: %@", log: .watch, type: .error,
                       event.id.uuidString, error.localizedDescription)
                // No acknowledgement: the durable Watch outbox will retry.
                replyHandler?([:])
            }
        }
    }

    func resolveWorkout(for event: WatchWorkoutEvent,
                        in context: NSManagedObjectContext,
                        tombstoneDefaults: UserDefaults = .appGroup) throws -> Workout? {
        let request: NSFetchRequest<Workout> = Workout.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "uuid == %@", event.workoutID as NSUUID)
        if let workout = try context.fetch(request).first { return workout }
        guard !Self.wasDeletedOnPhone(event.workoutID, defaults: tombstoneDefaults) else { return nil }
        guard let snapshot = event.snapshot,
              event.kind == .workoutCreated || event.kind == .workoutFinished ||
                (event.kind == .workoutFailed && snapshot.isFinishedRecord) else { return nil }

        let hasPhoneCurrent = try context.fetch(Workout.currentWorkoutFetchRequest).contains {
            $0.uuid != event.workoutID
        }
        if !snapshot.isFinishedRecord && hasPhoneCurrent { return nil }
        let workout = Workout.create(context: context)
        workout.uuid = event.workoutID
        workout.importSource = nil
        workout.isCurrentWorkout = !snapshot.isFinishedRecord
        // Replayed offline history must not take the phone's current preference.
        workout.healthExportState = snapshot.isHealthTestWorkout ||
            (workout.isCurrentWorkout && SettingsStore.shared.healthTestMode) ? "test" : "watch"
        applyComplete(snapshot, to: workout, in: context)
        return workout
    }

    private var deferredWorkoutsURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Iron", isDirectory: true)
            .appendingPathComponent(Self.deferredWorkoutsFilename, isDirectory: false)
    }

    private func readDeferredWorkouts() throws -> DeferredWatchWorkouts {
        guard FileManager.default.fileExists(atPath: deferredWorkoutsURL.path) else {
            return DeferredWatchWorkouts()
        }
        let data = try Data(contentsOf: deferredWorkoutsURL)
        guard let decoded = WatchWorkoutWire.decode(DeferredWatchWorkouts.self, from: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return decoded
    }

    private func writeDeferredWorkouts(_ store: DeferredWatchWorkouts) throws {
        guard let data = WatchWorkoutWire.encode(store) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(
            at: deferredWorkoutsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: deferredWorkoutsURL, options: .atomic)
    }

    private func persistDeferredWorkout(_ snapshot: WatchWorkoutSnapshot) throws {
        var store = try readDeferredWorkouts()
        let key = snapshot.workoutID.uuidString
        if let existing = store.snapshots[key],
           existing.revision > snapshot.revision ||
            (existing.revision == snapshot.revision && existing.updatedAt >= snapshot.updatedAt) {
            return
        }
        var compact = snapshot
        compact.library = nil
        compact.exercises = compact.exercises.map { exercise in
            var exercise = exercise
            exercise.imageData = nil
            return exercise
        }
        store.snapshots[key] = compact
        try writeDeferredWorkouts(store)
        refreshWatchWorkoutAwaitingOpen()
    }

    private func removeDeferredWorkout(_ workoutID: UUID) throws {
        var store = try readDeferredWorkouts()
        guard store.snapshots.removeValue(forKey: workoutID.uuidString) != nil else { return }
        try writeDeferredWorkouts(store)
        refreshWatchWorkoutAwaitingOpen()
    }

    private func refreshWatchWorkoutAwaitingOpen() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.refreshWatchWorkoutAwaitingOpen() }
            return
        }
        watchWorkoutAwaitingOpen = (try? readDeferredWorkouts())?.snapshots.values
            .filter { !$0.isFinishedRecord }.max { $0.updatedAt < $1.updatedAt }
    }

    func canReplaceEmptyPhoneWorkout(_ workout: Workout?) -> Bool {
        guard let workout else { return true }
        guard !workout.isImported else { return false }
        return (workout.workoutExercises?.count ?? 0) == 0 && workout.workoutRoutine == nil &&
            (workout.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) &&
            (workout.comment?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// Explicit handoff of the already-running Watch identity. A phone workout
    /// with any exercises, title or notes must be finished/discarded separately.
    @discardableResult
    func openWatchWorkout(in context: NSManagedObjectContext, snapshot: WatchWorkoutSnapshot? = nil) throws -> Workout {
        guard let source = snapshot ?? watchWorkoutAwaitingOpen, !source.isFinishedRecord else {
            throw GenericError(description: "The Watch workout is no longer available.")
        }
        let workout = try persistWatchWorkoutForOpening(source, in: context)
        currentWatchWorkoutUuid = workout.uuid
        recordWatchOrigin(source.workoutID)
        persistEventLedger()
        lastSnapshotRevision = max(lastSnapshotRevision, source.revision)
        try? removeDeferredWorkout(source.workoutID)
        RestTimerStore.shared.applyWatchUpdate(end: source.restTimerEnd, pausedRemaining: source.pausedRestRemaining)
        WorkoutLiveActivityManager.shared.startOrUpdate(for: workout)
        syncCurrentWorkoutSnapshot()
        return workout
    }

    func persistWatchWorkoutForOpening(_ source: WatchWorkoutSnapshot, in context: NSManagedObjectContext,
                                      save: (() throws -> Void)? = nil) throws -> Workout {
        guard !source.isFinishedRecord, source.schemaVersion <= WatchWorkoutWire.schemaVersion else {
            throw GenericError(description: "The Watch workout is no longer available.")
        }
        let current = try context.fetch(Workout.currentWorkoutFetchRequest)
        guard current.allSatisfy({ $0.uuid == source.workoutID || canReplaceEmptyPhoneWorkout($0) }) else {
            throw GenericError(description: "Finish the workout on this iPhone before opening your Watch workout.")
        }
        let event = WatchWorkoutEvent(workoutID: source.workoutID, sequence: 0,
                                      kind: .workoutCreated, snapshot: source)
        let workout = try context.persistMutation(save: { try save?() ?? context.save() }) {
            for placeholder in current where placeholder.uuid != source.workoutID { context.delete(placeholder) }
            context.processPendingChanges()
            guard let workout = try resolveWorkout(for: event, in: context), workout.isCurrentWorkout else {
                throw GenericError(description: "The Watch workout has already ended.")
            }
            return workout
        }
        persistRoutineNoteLinks(from: source, to: workout)
        return workout
    }

    /// Sidecar links are installed only after the Watch projection saves successfully.
    private func persistRoutineNoteLinks(from snapshot: WatchWorkoutSnapshot?, to workout: Workout) {
        if let snapshot, let context = workout.managedObjectContext {
            let logged = Dictionary(uniqueKeysWithValues: orderedExercises(in: workout).compactMap { exercise in
                exercise.uuid.map { ($0, exercise) }
            })
            for source in snapshot.exercises {
                guard let sourceID = source.routineExerciseID,
                      let exercise = logged[source.id],
                      let exerciseID = exercise.exerciseUuid,
                      exerciseID == source.exerciseUuid else { continue }
                let request: NSFetchRequest<WorkoutRoutineExercise> = WorkoutRoutineExercise.fetchRequest()
                request.fetchLimit = 1
                request.predicate = NSPredicate(format: "uuid == %@ AND exerciseUuid == %@",
                                                sourceID as NSUUID, exerciseID as NSUUID)
                guard (try? context.fetch(request))?.first != nil else { continue }
                WorkoutRoutineNoteLinks.setRoutineExerciseID(sourceID, for: source.id)
            }
        }
        workout.persistRoutineNoteLinks()
    }

    func applyWatchEventModelMutation(
        _ event: WatchWorkoutEvent,
        to workout: Workout,
        in context: NSManagedObjectContext,
        healthManager: HealthManager = .shared,
        finalizationDefaults: UserDefaults = .appGroup
    ) throws -> DeferredWatchEventEffects {
        if workout.isCurrentWorkout, !workout.isImported,
           event.snapshot?.isHealthTestWorkout == true {
            workout.healthExportState = "test"
        }
        switch event.kind {
        case .setUpdated:
            guard let set = workoutSet(with: event.setID, in: workout) else { return .none }
            if !acceptsWatchEdits(workout) {
                let fields = delayedWatchValueFields(["weight", "reps", "rpe"], event: event,
                    set: set, workout: workout, defaults: finalizationDefaults)
                apply(weight: event.weight, reps: event.reps, rpe: event.rpe,
                      unit: event.weightUnit, fields: fields, to: set)
                return delayedWatchValueEffects(workoutID: event.workoutID,
                    updates: delayedValueUpdate(for: set, fields: fields), defaults: finalizationDefaults)
            }
            apply(weight: event.weight, reps: event.reps, rpe: event.rpe,
                  unit: event.weightUnit, to: set)
            guard workout.isCurrentWorkout else { return .none }
            return DeferredWatchEventEffects {
                WorkoutLiveActivityManager.shared.startOrUpdate(for: workout)
            }

        case .setCompletionChanged:
            guard acceptsWatchEdits(workout),
                  let set = workoutSet(with: event.setID, in: workout),
                  let completed = event.completed else { return .none }
            set.isCompleted = completed
            set.completedAt = completed ? (set.completedAt ?? event.createdAt) : nil
            guard workout.isCurrentWorkout else { return .none }
            if completed, let workoutExercise = set.workoutExercise {
                let restTimerDuration = workoutExercise.restTimerDurationValue
                    ?? defaultRestTimerDuration(for: workoutExercise)
                let restTimerEnd = event.createdAt.addingTimeInterval(restTimerDuration)
                return DeferredWatchEventEffects {
                    // This applies one atomic timer snapshot and intentionally
                    // does not echo a Watch-originated timer back to the Watch.
                    RestTimerStore.shared.applyWatchUpdate(end: restTimerEnd, startedAt: event.createdAt)
                    WorkoutLiveActivityManager.shared.setCompleted(
                        set,
                        in: workoutExercise,
                        workout: workout
                    )
                }
            } else {
                return DeferredWatchEventEffects {
                    RestTimerStore.shared.cancel()
                    WorkoutLiveActivityManager.shared.startOrUpdate(
                        for: workout,
                        preservingTransition: false
                    )
                }
            }
        case .restTimerUpdated:
            guard workout.isCurrentWorkout else { return .none }
            return DeferredWatchEventEffects {
                RestTimerStore.shared.applyWatchUpdate(
                    end: event.restTimerEnd,
                    pausedRemaining: event.snapshot?.pausedRestRemaining)
                WorkoutLiveActivityManager.shared.refreshRestTimer(for: workout)
            }

        case .workoutFinished:
            guard workout.isCurrentWorkout || isWatchOwned(workout) else { return .none }
            let wasCurrent = workout.isCurrentWorkout
            if event.fieldChanges != nil {
                applyModernWatchCompletion(event, to: workout, state: "watch")
            } else {
                if let snapshot = event.snapshot, isWatchOwned(workout) {
                    applyComplete(snapshot, to: workout, in: context)
                }
                applyWatchCompletion(event, to: workout, state: "watch")
            }
            return DeferredWatchEventEffects { [weak self] in
                self?.retireSnapshotDelivery(workoutID: event.workoutID)
                if wasCurrent {
                    self?.currentWatchWorkoutUuid = nil
                    RestTimerStore.shared.cancel()
                    WorkoutLiveActivityManager.shared.end(for: workout, completed: true)
                }
            }

        case .workoutDiscarded:
            guard acceptsWatchEdits(workout) else { return .none }
            let wasCurrent = workout.isCurrentWorkout
            let activityEndSnapshot = wasCurrent ? WorkoutLiveActivityManager.shared.endSnapshot(for: workout) : nil
            let workoutID = workout.uuid
            context.delete(workout)
            return DeferredWatchEventEffects { [weak self] in
                self?.retireSnapshotDelivery(workoutID: event.workoutID)
                if wasCurrent {
                    self?.currentWatchWorkoutUuid = nil
                    RestTimerStore.shared.cancel()
                    if let activityEndSnapshot {
                        WorkoutLiveActivityManager.shared.end(using: activityEndSnapshot, completed: false)
                    }
                }
                self?.deleteStartWorkoutInteractionDonation(workoutID: workoutID)
            }

        case .workoutFailed:
            // The existing failure event can arrive before the finish event. Its
            // completed snapshot must survive that lifecycle sequence ordering.
            let wasCurrent = workout.isCurrentWorkout
            if event.endDate != nil || event.snapshot?.isFinishedRecord == true {
                if workout.isCurrentWorkout || isWatchOwned(workout) {
                    if event.fieldChanges != nil {
                        if workout.isCurrentWorkout {
                            applyModernWatchCompletion(event, to: workout, state: "pending")
                        } else {
                            workout.healthExportState = watchCompletionExportState(event, workout: workout, fallback: "pending")
                        }
                    } else {
                        applyWatchCompletion(event, to: workout, state: "pending", includeEventTitle: false)
                    }
                } else if workout.healthExportEligibility == .eligible,
                          workout.healthExportState == "watch" {
                    workout.healthExportState = watchCompletionExportState(event, workout: workout, fallback: "pending")
                }
            }
            let shouldClearWatchWorkout = workout.isCurrentWorkout || workout.healthExportState == "pending" || workout.healthExportState == "test"
            return DeferredWatchEventEffects { [weak self] in
                if !workout.isCurrentWorkout { self?.retireSnapshotDelivery(workoutID: event.workoutID) }
                if shouldClearWatchWorkout { self?.currentWatchWorkoutUuid = nil }
                if wasCurrent {
                    RestTimerStore.shared.cancel()
                    WorkoutLiveActivityManager.shared.end(for: workout, completed: true)
                }
                if workout.healthExportEligibility == .eligible, workout.healthExportState == "pending" {
                    healthManager.saveWorkout(workout: workout, exerciseStore: .shared)
                }
                os_log("Watch reported a failed workout session", log: .watch, type: .error)
            }

        case .setAdded:
            guard acceptsWatchEdits(workout),
                  let workoutExercise = workoutExercise(with: event.exerciseID, in: workout) else { return .none }
            if let setID = event.setID, workoutSet(with: setID, in: workout) != nil {
                return .none
            }
            let set = WorkoutSet.create(context: context)
            if let setID = event.setID {
                set.uuid = setID
            }
            set.workoutExercise = workoutExercise
            apply(weight: event.weight, reps: event.reps, rpe: event.rpe,
                  unit: event.weightUnit, to: set)
            set.isCompleted = false
            let selectedSetID = set.uuid
            guard workout.isCurrentWorkout else { return .none }
            return DeferredWatchEventEffects { [weak self] in
                self?.selectedWatchSetUuid = selectedSetID
                WorkoutLiveActivityManager.shared.startOrUpdate(for: workout)
            }

        case .setDeleted:
            guard acceptsWatchEdits(workout),
                  let set = workoutSet(with: event.setID, in: workout),
                  let workoutExercise = set.workoutExercise,
                  (workoutExercise.workoutSets?.count ?? 0) > 1 else { return .none }
            let replacementSelectedSetID: UUID? = selectedWatchSetUuid == set.uuid
                ? (workoutExercise.workoutSets?.array as? [WorkoutSet])?
                    .first { $0.uuid != set.uuid }?.uuid
                : selectedWatchSetUuid
            context.delete(set)
            guard workout.isCurrentWorkout else { return .none }
            return DeferredWatchEventEffects { [weak self] in
                self?.selectedWatchSetUuid = replacementSelectedSetID
                WorkoutLiveActivityManager.shared.startOrUpdate(for: workout)
            }

        case .setTagChanged:
            guard let set = workoutSet(with: event.setID, in: workout) else { return .none }
            if !acceptsWatchEdits(workout) {
                let fields = delayedWatchValueFields(["tag"], event: event, set: set,
                    workout: workout, defaults: finalizationDefaults)
                guard fields.contains("tag") else { return .none }
                set.tagValue = event.tag.flatMap { WorkoutSetTag(rawValue: $0) }
                return delayedWatchValueEffects(workoutID: event.workoutID,
                    updates: delayedValueUpdate(for: set, fields: fields), defaults: finalizationDefaults)
            }
            set.tagValue = event.tag.flatMap { WorkoutSetTag(rawValue: $0) }
            guard workout.isCurrentWorkout else { return .none }
            return DeferredWatchEventEffects {
                WorkoutLiveActivityManager.shared.startOrUpdate(for: workout)
            }

        case .exerciseAdded:
            return addExercise(from: event, to: workout, in: context)

        case .exerciseReplaced:
            guard acceptsWatchEdits(workout),
                  let workoutExercise = workoutExercise(with: event.exerciseID, in: workout),
                  let catalogID = event.catalogExerciseUuid,
                  ExerciseStore.find(in: ExerciseStore.shared.exercises, with: catalogID) != nil else { return .none }
            workoutExercise.exerciseUuid = catalogID
            guard workout.isCurrentWorkout else { return .none }
            return DeferredWatchEventEffects {
                WorkoutLiveActivityManager.shared.startOrUpdate(for: workout)
            }

        case .exerciseDeleted:
            guard acceptsWatchEdits(workout),
                  let workoutExercise = workoutExercise(with: event.exerciseID, in: workout),
                  orderedExercises(in: workout).count > 1 else { return .none }
            context.delete(workoutExercise)
            guard workout.isCurrentWorkout else { return .none }
            return DeferredWatchEventEffects {
                WorkoutLiveActivityManager.shared.startOrUpdate(for: workout)
            }

        case .workoutCreated:
            guard acceptsWatchEdits(workout) else { return .none }
            if !workout.isImported && workout.isCurrentWorkout && SettingsStore.shared.healthTestMode {
                workout.healthExportState = "test"
            }
            if let snapshot = event.snapshot {
                if workout.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                    workout.title = snapshot.title
                }
                // A matching placeholder (including a test workout) has no
                // local graph to protect. Seed its title, dates and full graph.
                if orderedExercises(in: workout).isEmpty {
                    applyComplete(snapshot, to: workout, in: context)
                } else if let changes = event.fieldChanges {
                    applyMaskedStructure(snapshot, changes: changes, to: workout, in: context)
                } else {
                    applyNonDestructiveStructure(snapshot, to: workout, in: context)
                }
            }
            return workout.isCurrentWorkout
                ? DeferredWatchEventEffects { WorkoutLiveActivityManager.shared.startOrUpdate(for: workout) }
                : .none

        case .workoutStructureUpdated:
            guard let snapshot = event.snapshot else { return .none }
            if !acceptsWatchEdits(workout) {
                // Offline value corrections may precede the phone's finish.
                // Apply only masked values to retained completed sets; never
                // recreate removed rows or reopen a completed workout.
                if let changes = event.fieldChanges {
                    let valueFields: Set<String> = ["weight", "reps", "rpe", "tag", "duration", "distance",
                                                    "comment", "minTargetReps", "maxTargetReps"]
                    var updates: [String: [String: String]] = [:]
                    for exercise in snapshot.exercises {
                        for source in exercise.sets {
                            guard let set = workoutSet(with: source.id, in: workout) else { continue }
                            let fields = delayedWatchValueFields(
                                Set(changes.sets[source.id.uuidString] ?? []).intersection(valueFields),
                                event: event, set: set, workout: workout, defaults: finalizationDefaults)
                            applyMaskedSet(source, fields: fields, unit: snapshot.weightUnit,
                                           updatedAt: snapshot.updatedAt, to: set)
                            updates.merge(delayedValueUpdate(for: set, fields: fields)) { _, new in new }
                        }
                    }
                    return delayedWatchValueEffects(workoutID: event.workoutID, updates: updates,
                        defaults: finalizationDefaults)
                }
                return .none
            }
            // Only remove IDs explicitly deleted on the Watch. Missing IDs alone
            // can also mean the phone added something while the Watch was offline.
            let removedExercises = Set(event.removedExerciseIDs ?? [])
            let removedSets = Set(event.removedSetIDs ?? [])
            for exercise in orderedExercises(in: workout) {
                if let id = exercise.uuid, removedExercises.contains(id) { context.delete(exercise) }
                else {
                    for set in exercise.workoutSets?.array as? [WorkoutSet] ?? [] {
                        if let id = set.uuid, removedSets.contains(id) { context.delete(set) }
                    }
                }
            }
            context.processPendingChanges()
            if let fieldChanges = event.fieldChanges {
                applyMaskedStructure(snapshot, changes: fieldChanges, to: workout, in: context)
            } else if isWatchOwned(workout) {
                applyComplete(snapshot, to: workout, in: context)
            } else {
                applyNonDestructiveStructure(snapshot, to: workout, in: context)
            }
            return workout.isCurrentWorkout
                ? DeferredWatchEventEffects { WorkoutLiveActivityManager.shared.startOrUpdate(for: workout) }
                : .none

        case .savedWorkoutUpserted, .savedWorkoutDeleted:
            return .none // Handled before Workout lookup because workoutID is a routine ID.
        }
    }

    private func isWatchOwned(_ workout: Workout) -> Bool {
        // Test provenance is also set on phone-started workouts. It cannot
        // authorize replacing an active phone graph with a Watch projection.
        (workout.healthExportState == "watch" ||
            (workout.healthExportState == "test" && !workout.isCurrentWorkout)) && workout.importSource == nil
    }

    private func acceptsWatchEdits(_ workout: Workout) -> Bool {
        workout.isCurrentWorkout || (isWatchOwned(workout) && workout.end == nil)
    }

    private func delayedWatchValueFields(_ fields: Set<String>, event: WatchWorkoutEvent,
                                         set: WorkoutSet, workout: Workout,
                                         defaults: UserDefaults) -> Set<String> {
        guard !fields.isEmpty, !workout.isImported, !workout.isCurrentWorkout, set.isCompleted,
              let end = Self.phoneFinalizationDate(event.workoutID, defaults: defaults) ?? workout.end,
              event.createdAt <= end, event.snapshot?.isFinishedRecord != true,
              let setID = set.uuid else { return [] }
        Self.terminalDefaultsLock.lock()
        let baselines = defaults.dictionary(forKey: Self.finalizationValuesDefaultsKey) as? [String: [String: [String: String]]]
        let baseline = baselines?[event.workoutID.uuidString]?[setID.uuidString]
        Self.terminalDefaultsLock.unlock()
        // Older finalized records without a baseline cannot prove that the
        // phone field is unchanged. Never overwrite an unprovable correction.
        guard let baseline else { return [] }
        let current = Self.finalizationValues(for: set)
        return fields.filter { baseline[$0] != nil && baseline[$0] == current[$0] }
    }

    private func delayedValueUpdate(for set: WorkoutSet, fields: Set<String>) -> [String: [String: String]] {
        guard let id = set.uuid, !fields.isEmpty else { return [:] }
        return [id.uuidString: Self.finalizationValues(for: set).filter { fields.contains($0.key) }]
    }

    /// Advance only accepted Watch fields, after the model save succeeds, so a
    /// later queued patch can follow them without unprotecting phone changes.
    private func delayedWatchValueEffects(workoutID: UUID, updates: [String: [String: String]],
                                          defaults: UserDefaults) -> DeferredWatchEventEffects {
        guard !updates.isEmpty else { return .none }
        return DeferredWatchEventEffects {
            Self.terminalDefaultsLock.lock()
            defer { Self.terminalDefaultsLock.unlock() }
            var baselines = defaults.dictionary(forKey: Self.finalizationValuesDefaultsKey) as? [String: [String: [String: String]]] ?? [:]
            guard var workout = baselines[workoutID.uuidString] else { return }
            let previous = workout
            for (id, values) in updates {
                guard workout[id] != nil else { continue }
                workout[id]?.merge(values) { _, new in new }
            }
            guard workout != previous else { return }
            baselines[workoutID.uuidString] = workout
            defaults.set(baselines, forKey: Self.finalizationValuesDefaultsKey)
        }
    }

    private func addExercise(from event: WatchWorkoutEvent,
                             to workout: Workout,
                             in context: NSManagedObjectContext) -> DeferredWatchEventEffects {
        guard acceptsWatchEdits(workout),
              let catalogID = event.catalogExerciseUuid,
              ExerciseStore.find(in: ExerciseStore.shared.exercises, with: catalogID) != nil else { return .none }
        if let exerciseID = event.exerciseID, workoutExercise(with: exerciseID, in: workout) != nil {
            return .none
        }

        let workoutExercise = WorkoutExercise.create(context: context)
        if let exerciseID = event.exerciseID {
            workoutExercise.uuid = exerciseID
        }
        workoutExercise.exerciseUuid = catalogID
        insert(workoutExercise, in: workout, after: event.afterExerciseID)
        workoutExercise.restTimerDurationValue = defaultRestTimerDuration(for: workoutExercise)

        let set = WorkoutSet.create(context: context)
        if let setID = event.setID {
            set.uuid = setID
        }
        set.workoutExercise = workoutExercise
        apply(weight: event.weight, reps: event.reps ?? 5, rpe: event.rpe,
              unit: event.weightUnit, to: set)
        set.isCompleted = false
        let selectedSetID = set.uuid
        guard workout.isCurrentWorkout else { return .none }
        return DeferredWatchEventEffects { [weak self] in
            self?.selectedWatchSetUuid = selectedSetID
            WorkoutLiveActivityManager.shared.startOrUpdate(for: workout)
        }
    }

    private func defaultRestTimerDuration(
        for workoutExercise: WorkoutExercise
    ) -> TimeInterval {
        switch workoutExercise.exercise(in: ExerciseStore.shared.exercises)?.type {
        case .barbell:
            return SettingsStore.shared.defaultRestTimeBarbellBased
        case .dumbbell:
            return SettingsStore.shared.defaultRestTimeDumbbellBased
        default:
            return SettingsStore.shared.defaultRestTime
        }
    }

    private func deleteStartWorkoutInteractionDonation(workoutID: UUID?) {
        guard let workoutID else { return }
        os_log("Deleting start workout interaction with uuid=%@", log: .siri, workoutID as NSUUID)
        INInteraction.delete(with: [workoutID.uuidString]) { error in
            if let error {
                os_log("Deleting interaction failed: %@", log: .siri, type: .error, error.localizedDescription)
            } else {
                os_log("Successfully deleted interaction with uuid=%@", log: .siri, type: .info, workoutID as NSUUID)
            }
        }
    }

    private func apply(_ snapshot: WatchWorkoutSnapshot, to workout: Workout) {
        if let effort = snapshot.sessionEffort {
            workout.sessionEffortValue = effort
        }
        workout.comment = snapshot.comment
        let exercises = workout.workoutExercises?.array.compactMap { $0 as? WorkoutExercise } ?? []
        let exerciseByID = Dictionary(uniqueKeysWithValues: exercises.compactMap { exercise in
            exercise.uuid.map { ($0, exercise) }
        })

        for watchExercise in snapshot.exercises {
            guard let exercise = exerciseByID[watchExercise.id] else { continue }
            let sets = exercise.workoutSets?.array.compactMap { $0 as? WorkoutSet } ?? []
            let setByID = Dictionary(uniqueKeysWithValues: sets.compactMap { set in
                set.uuid.map { ($0, set) }
            })
            for watchSet in watchExercise.sets {
                guard let set = setByID[watchSet.id] else { continue }
                apply(watchSet, unit: snapshot.weightUnit, updatedAt: snapshot.updatedAt, to: set)
            }
            exercise.restTimerDurationValue = watchExercise.restTimerDuration
            exercise.supersetUuid = watchExercise.supersetID
            exercise.comment = watchExercise.comment
        }
    }

    /// Replaces a Watch-owned projection from its complete durable snapshot.
    /// Phone-owned records use the non-destructive merge below so an unrelated
    /// phone edit cannot be erased by a delayed finish packet.
    func applyComplete(_ snapshot: WatchWorkoutSnapshot, to workout: Workout,
                       in context: NSManagedObjectContext) {
        workout.title = snapshot.title
        workout.comment = snapshot.comment
        workout.start = snapshot.startDate
        workout.end = snapshot.endDate
        workout.sessionEffortValue = snapshot.sessionEffort
        if let routineID = snapshot.sourceSavedWorkoutID {
            let request: NSFetchRequest<WorkoutRoutine> = WorkoutRoutine.fetchRequest()
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "uuid == %@", routineID as NSUUID)
            workout.workoutRoutine = try? context.fetch(request).first
        }

        let existing = orderedExercises(in: workout)
        let byID = Dictionary(uniqueKeysWithValues: existing.compactMap { exercise in
            exercise.uuid.map { ($0, exercise) }
        })
        var ordered: [WorkoutExercise] = []
        for watchExercise in snapshot.exercises.sorted(by: { $0.order < $1.order }) {
            let exercise = byID[watchExercise.id] ?? WorkoutExercise.create(context: context)
            exercise.uuid = watchExercise.id
            apply(watchExercise, unit: snapshot.weightUnit, updatedAt: snapshot.updatedAt,
                  to: exercise, in: context, replaceSets: true)
            ordered.append(exercise)
        }
        let retainedIDs = Set(snapshot.exercises.map(\.id))
        for exercise in existing where exercise.uuid.map({ !retainedIDs.contains($0) }) ?? true {
            context.delete(exercise)
        }
        workout.workoutExercises = NSOrderedSet(array: ordered)
    }

    private func applyNonDestructiveStructure(_ snapshot: WatchWorkoutSnapshot, to workout: Workout,
                                               in context: NSManagedObjectContext) {
        apply(snapshot, to: workout)
        let existing = orderedExercises(in: workout)
        var byID = Dictionary(uniqueKeysWithValues: existing.compactMap { exercise in
            exercise.uuid.map { ($0, exercise) }
        })
        var ordered: [WorkoutExercise] = []
        for watchExercise in snapshot.exercises.sorted(by: { $0.order < $1.order }) {
            let exercise = byID.removeValue(forKey: watchExercise.id) ?? WorkoutExercise.create(context: context)
            exercise.uuid = watchExercise.id
            apply(watchExercise, unit: snapshot.weightUnit, updatedAt: snapshot.updatedAt,
                  to: exercise, in: context, replaceSets: false)
            ordered.append(exercise)
        }
        ordered.append(contentsOf: existing.filter { byID[$0.uuid ?? UUID()] != nil })
        workout.workoutExercises = NSOrderedSet(array: ordered)
    }

    private func applyMaskedStructure(_ snapshot: WatchWorkoutSnapshot,
                                      changes: WatchWorkoutFieldChanges,
                                      to workout: Workout,
                                      in context: NSManagedObjectContext) {
        let workoutFields = Set(changes.workout)
        if workoutFields.contains("title") { workout.title = snapshot.title }
        if workoutFields.contains("startDate") { workout.start = snapshot.startDate }
        if workoutFields.contains("endDate") { workout.end = snapshot.endDate }
        if workoutFields.contains("comment") { workout.comment = snapshot.comment }
        if workoutFields.contains("sourceSavedWorkoutID") {
            if let routineID = snapshot.sourceSavedWorkoutID {
                let request: NSFetchRequest<WorkoutRoutine> = WorkoutRoutine.fetchRequest()
                request.fetchLimit = 1
                request.predicate = NSPredicate(format: "uuid == %@", routineID as NSUUID)
                workout.workoutRoutine = try? context.fetch(request).first
            } else {
                workout.workoutRoutine = nil
            }
        }

        let existing = orderedExercises(in: workout).filter { !$0.isDeleted }
        var byID = Dictionary(uniqueKeysWithValues: existing.compactMap { exercise in
            exercise.uuid.map { ($0, exercise) }
        })
        var snapshotOrder: [WorkoutExercise] = []
        var newExercises: [WorkoutExercise] = []

        for watchExercise in snapshot.exercises.sorted(by: { $0.order < $1.order }) {
            let exercise: WorkoutExercise
            if let current = byID[watchExercise.id] {
                exercise = current
                applyMaskedExercise(watchExercise, changes: changes, to: exercise,
                                    unit: snapshot.weightUnit, updatedAt: snapshot.updatedAt,
                                    in: context)
            } else {
                guard changes.addedExerciseIDs?.contains(watchExercise.id) == true else {
                    continue
                }
                exercise = WorkoutExercise.create(context: context)
                exercise.uuid = watchExercise.id
                apply(watchExercise, unit: snapshot.weightUnit, updatedAt: snapshot.updatedAt,
                      to: exercise, in: context, replaceSets: true)
                byID[watchExercise.id] = exercise
                newExercises.append(exercise)
            }
            snapshotOrder.append(exercise)
        }

        if changes.exerciseOrder {
            let snapshotIDs = Set(snapshot.exercises.map(\.id))
            let phoneOnly = existing.filter { exercise in
                exercise.uuid.map { !snapshotIDs.contains($0) } ?? true
            }
            workout.workoutExercises = NSOrderedSet(array: snapshotOrder + phoneOnly)
        } else if !newExercises.isEmpty {
            workout.workoutExercises = NSOrderedSet(array: existing + newExercises)
        }
    }

    private func applyMaskedExercise(_ watchExercise: WatchWorkoutExercise,
                                     changes: WatchWorkoutFieldChanges,
                                     to exercise: WorkoutExercise,
                                     unit: WatchWorkoutWeightUnit?,
                                     updatedAt: Date,
                                     in context: NSManagedObjectContext) {
        let fields = Set(changes.exercises[watchExercise.id.uuidString] ?? [])
        if fields.contains("exerciseUuid") { exercise.exerciseUuid = watchExercise.exerciseUuid }
        if fields.contains("restTimerDuration") {
            exercise.restTimerDurationValue = watchExercise.restTimerDuration
        }
        if fields.contains("supersetID") { exercise.supersetUuid = watchExercise.supersetID }
        if fields.contains("comment") { exercise.comment = watchExercise.comment }

        let existing = (exercise.workoutSets?.array as? [WorkoutSet] ?? []).filter { !$0.isDeleted }
        var byID = Dictionary(uniqueKeysWithValues: existing.compactMap { set in
            set.uuid.map { ($0, set) }
        })
        var snapshotOrder: [WorkoutSet] = []
        var newSets: [WorkoutSet] = []
        for watchSet in watchExercise.sets.sorted(by: { $0.order < $1.order }) {
            let set: WorkoutSet
            if let current = byID[watchSet.id] {
                set = current
                applyMaskedSet(watchSet, fields: Set(changes.sets[watchSet.id.uuidString] ?? []),
                               unit: unit, updatedAt: updatedAt, to: set)
            } else {
                guard changes.addedSetIDs?.contains(watchSet.id) == true else {
                    continue
                }
                set = WorkoutSet.create(context: context)
                set.uuid = watchSet.id
                apply(watchSet, unit: unit, updatedAt: updatedAt, to: set)
                byID[watchSet.id] = set
                newSets.append(set)
            }
            snapshotOrder.append(set)
        }

        if changes.setOrder.contains(watchExercise.id) {
            let snapshotIDs = Set(watchExercise.sets.map(\.id))
            let phoneOnly = existing.filter { set in
                set.uuid.map { !snapshotIDs.contains($0) } ?? true
            }
            exercise.workoutSets = NSOrderedSet(array: snapshotOrder + phoneOnly)
        } else if !newSets.isEmpty {
            exercise.workoutSets = NSOrderedSet(array: existing + newSets)
        }
    }

    private func applyMaskedSet(_ watchSet: WatchWorkoutSet, fields: Set<String>,
                                unit: WatchWorkoutWeightUnit?, updatedAt: Date,
                                to set: WorkoutSet) {
        apply(weight: watchSet.weight, reps: watchSet.reps, rpe: watchSet.rpe,
              unit: unit, fields: fields, to: set)
        if fields.contains("completed") {
            set.isCompleted = watchSet.completed
            set.completedAt = watchSet.completed ? (set.completedAt ?? updatedAt) : nil
        }
        if fields.contains("tag") {
            set.tagValue = watchSet.tag.flatMap { WorkoutSetTag(rawValue: $0) }
        }
        if fields.contains("duration") { set.durationValue = watchSet.duration }
        if fields.contains("distance") { set.distanceValue = watchSet.distance }
        if fields.contains("comment") { set.comment = watchSet.comment }
        if fields.contains("minTargetReps") {
            set.minTargetRepetitionsValue = watchSet.minTargetReps.map { Int16(clamping: $0) }
        }
        if fields.contains("maxTargetReps") {
            set.maxTargetRepetitionsValue = watchSet.maxTargetReps.map { Int16(clamping: $0) }
        }
    }

    private func apply(_ watchExercise: WatchWorkoutExercise, unit: WatchWorkoutWeightUnit?,
                       updatedAt: Date, to exercise: WorkoutExercise,
                       in context: NSManagedObjectContext, replaceSets: Bool) {
        exercise.exerciseUuid = watchExercise.exerciseUuid
        exercise.restTimerDurationValue = watchExercise.restTimerDuration
        exercise.supersetUuid = watchExercise.supersetID
        exercise.comment = watchExercise.comment
        let existing = exercise.workoutSets?.array.compactMap { $0 as? WorkoutSet } ?? []
        var byID = Dictionary(uniqueKeysWithValues: existing.compactMap { set in
            set.uuid.map { ($0, set) }
        })
        var ordered: [WorkoutSet] = []
        for watchSet in watchExercise.sets.sorted(by: { $0.order < $1.order }) {
            let set = byID.removeValue(forKey: watchSet.id) ?? WorkoutSet.create(context: context)
            set.uuid = watchSet.id
            apply(watchSet, unit: unit, updatedAt: updatedAt, to: set)
            ordered.append(set)
        }
        if replaceSets {
            byID.values.forEach(context.delete)
        } else {
            ordered.append(contentsOf: existing.filter { byID[$0.uuid ?? UUID()] != nil })
        }
        exercise.workoutSets = NSOrderedSet(array: ordered)
    }

    private func apply(_ watchSet: WatchWorkoutSet, unit: WatchWorkoutWeightUnit?,
                       updatedAt: Date, to set: WorkoutSet) {
        apply(weight: watchSet.weight, reps: watchSet.reps, rpe: watchSet.rpe, unit: unit, to: set)
        set.isCompleted = watchSet.completed
        set.completedAt = watchSet.completed ? (set.completedAt ?? updatedAt) : nil
        set.tagValue = watchSet.tag.flatMap { WorkoutSetTag(rawValue: $0) }
        set.durationValue = watchSet.duration
        set.distanceValue = watchSet.distance
        set.comment = watchSet.comment
        set.minTargetRepetitionsValue = watchSet.minTargetReps.map { Int16(clamping: $0) }
        set.maxTargetRepetitionsValue = watchSet.maxTargetReps.map { Int16(clamping: $0) }
    }

    func applySavedWorkoutEvent(_ event: WatchWorkoutEvent,
                                in context: NSManagedObjectContext) throws -> DeferredWatchEventEffects {
        let request: NSFetchRequest<WorkoutRoutine> = WorkoutRoutine.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "uuid == %@", event.workoutID as NSUUID)
        let existing = try context.fetch(request).first
        if event.kind == .savedWorkoutDeleted {
            if let existing { context.delete(existing) }
            return .none
        }
        guard let saved = event.savedWorkout, saved.id == event.workoutID else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let routine = existing ?? WorkoutRoutine.create(context: context)
        routine.uuid = saved.id
        routine.title = saved.title
        routine.comment = saved.comment
        if routine.workoutPlan == nil {
            let planRequest: NSFetchRequest<WorkoutPlan> = WorkoutPlan.fetchRequest()
            planRequest.fetchLimit = 1
            let plan = try context.fetch(planRequest).first ?? WorkoutPlan.create(context: context)
            plan.addToWorkoutRoutines(routine)
        }
        (routine.workoutRoutineExercises?.array as? [WorkoutRoutineExercise])?.forEach(context.delete)
        var tracking = SetTrackingPreferences()
        let updatedAt = event.createdAt.timeIntervalSince1970
        let exercises = saved.exercises.sorted(by: { $0.order < $1.order }).map { watchExercise -> WorkoutRoutineExercise in
            if let id = watchExercise.exerciseUuid,
               let type = watchExercise.trackingType.flatMap(SetTrackingType.init(rawValue:)) {
                tracking.overrides[id.uuidString] = .init(type: type, updatedAt: updatedAt)
            }
            let exercise = WorkoutRoutineExercise.create(context: context)
            exercise.uuid = watchExercise.id
            exercise.exerciseUuid = watchExercise.exerciseUuid
            exercise.comment = watchExercise.routineNote ?? watchExercise.comment
            exercise.restTimerDurationValue = watchExercise.restTimerDuration
            exercise.supersetUuid = watchExercise.supersetID
            let sets = watchExercise.sets.sorted(by: { $0.order < $1.order }).map { watchSet -> WorkoutRoutineSet in
                let set = WorkoutRoutineSet.create(context: context)
                set.uuid = watchSet.id
                set.weightValue = watchSet.weight.map { canonicalWeight($0, unit: saved.weightUnit) }
                set.minRepetitionsValue = (watchSet.minTargetReps ?? watchSet.reps).map { Int16(clamping: $0) }
                set.maxRepetitionsValue = (watchSet.maxTargetReps ?? watchSet.reps).map { Int16(clamping: $0) }
                set.tagValue = watchSet.tag.flatMap { WorkoutSetTag(rawValue: $0) }
                set.comment = watchSet.comment
                set.durationValue = watchSet.duration
                // Include zero as a timestamped removal when a target is cleared.
                let distance = watchSet.distance.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
                tracking.routineDistances[watchSet.id.uuidString] = .init(meters: distance, updatedAt: updatedAt)
                return set
            }
            exercise.workoutRoutineSets = NSOrderedSet(array: sets)
            return exercise
        }
        routine.workoutRoutineExercises = NSOrderedSet(array: exercises)
        // UserDefaults isn't part of the Core Data undo transaction. Publish
        // targets only after the durable event save, before acknowledging it.
        return DeferredWatchEventEffects {
            SyncedPreferenceStorage.lock.lock()
            defer { SyncedPreferenceStorage.lock.unlock() }
            let stored = SetTrackingPreferences.load()
            let merged = stored.merging(tracking)
            // A Watch event is a remote apply, never a new local preference edit.
            merged.save()
        }
    }

    private func apply(weight: Double?, reps: Int?, rpe: Double?,
                       unit: WatchWorkoutWeightUnit?,
                       fields: Set<String> = ["weight", "reps", "rpe"], to set: WorkoutSet) {
        // A rejected field must remain untouched; nil clears only an accepted
        // field. Keep direct updates and masked snapshots on the same writer.
        if fields.contains("weight") {
            set.weight = weight.map { NSNumber(value: canonicalWeight($0, unit: unit)) }
        }
        if fields.contains("reps") {
            set.repetitions = reps.map { NSNumber(value: min(max($0, 0), Int(WorkoutSet.MAX_REPETITIONS))) }
        }
        if fields.contains("rpe") { set.rpeValue = rpe }
    }

    private func orderedExercises(in workout: Workout) -> [WorkoutExercise] {
        workout.workoutExercises?.array.compactMap { $0 as? WorkoutExercise } ?? []
    }

    private func workoutExercise(with id: UUID?, in workout: Workout) -> WorkoutExercise? {
        guard let id else { return nil }
        return orderedExercises(in: workout).first { $0.uuid == id }
    }

    private func insert(_ workoutExercise: WorkoutExercise,
                        in workout: Workout,
                        after afterID: UUID?) {
        workout.addToWorkoutExercises(workoutExercise)
        guard let afterID,
              var ordered = workout.workoutExercises?.array as? [WorkoutExercise],
              let afterIndex = ordered.firstIndex(where: { $0.uuid == afterID }),
              let currentIndex = ordered.firstIndex(where: { $0.objectID == workoutExercise.objectID }) else { return }
        let exercise = ordered.remove(at: currentIndex)
        let adjustedAfter = currentIndex <= afterIndex ? afterIndex - 1 : afterIndex
        ordered.insert(exercise, at: min(adjustedAfter + 1, ordered.count))
        workout.workoutExercises = NSOrderedSet(array: ordered)
    }

    private func workoutSet(with id: UUID?, in workout: Workout) -> WorkoutSet? {
        guard let id = id else { return nil }
        return orderedExercises(in: workout)
            .flatMap { $0.workoutSets?.array.compactMap { $0 as? WorkoutSet } ?? [] }
            .first { $0.uuid == id }
    }

    private func canonicalWeight(_ value: Double, unit: WatchWorkoutWeightUnit?) -> Double {
        guard unit == .pound else { return value }
        return WeightUnit.convert(weight: value, from: .imperial, to: .metric)
    }

    private func applyWatchCompletion(_ event: WatchWorkoutEvent, to workout: Workout,
                                      state: String, includeEventTitle: Bool = true) {
        if let snapshot = event.snapshot { apply(snapshot, to: workout) }
        let start = event.startDate ?? event.snapshot?.startDate ?? workout.safeStart
        workout.start = start
        workout.end = max(event.endDate ?? event.snapshot?.endDate ?? Date(), start)
        if let title = (includeEventTitle ? event.title : nil) ?? event.snapshot?.title {
            workout.title = title
        }
        if let effort = event.sessionEffort ?? event.snapshot?.sessionEffort {
            workout.sessionEffortValue = effort
        }
        workout.deleteExercisesWhereAllSetsAreUncompleted()
        workout.deleteUncompletedSets()
        workout.isCurrentWorkout = false
        workout.healthExportState = watchCompletionExportState(event, workout: workout, fallback: state)
    }

    private func applyModernWatchCompletion(_ event: WatchWorkoutEvent, to workout: Workout,
                                            state: String) {
        let start = workout.safeStart
        workout.end = max(event.endDate ?? event.snapshot?.endDate ?? Date(), start)
        if let effort = event.sessionEffort ?? event.snapshot?.sessionEffort {
            workout.sessionEffortValue = effort
        }
        workout.deleteExercisesWhereAllSetsAreUncompleted()
        workout.deleteUncompletedSets()
        workout.isCurrentWorkout = false
        workout.healthExportState = watchCompletionExportState(event, workout: workout, fallback: state)
    }

    private func watchCompletionExportState(_ event: WatchWorkoutEvent, workout: Workout,
                                            fallback: String) -> String? {
        guard !workout.isImported else { return nil }
        if workout.healthExportState == "test" || event.snapshot?.isHealthTestWorkout == true {
            return "test"
        }
        return workout.healthExportEligibility == .eligible ? fallback : nil
    }

    private func sequenceFieldKey(for event: WatchWorkoutEvent) -> String {
        switch event.kind {
        case .setUpdated:
            return "\(event.workoutID.uuidString):\(event.setID?.uuidString ?? "unknown"):values"
        case .setCompletionChanged:
            return "\(event.workoutID.uuidString):\(event.setID?.uuidString ?? "unknown"):completion"
        case .restTimerUpdated:
            return "\(event.workoutID.uuidString):timer"
        case .workoutFinished, .workoutDiscarded:
            return "\(event.workoutID.uuidString):lifecycle"
        case .workoutFailed:
            return "\(event.workoutID.uuidString):healthFailure"
        case .workoutCreated, .workoutStructureUpdated:
            return "\(event.workoutID.uuidString):structure"
        case .savedWorkoutUpserted, .savedWorkoutDeleted:
            return "\(event.workoutID.uuidString):savedWorkout"
        case .setAdded, .setDeleted, .setTagChanged,
             .exerciseAdded, .exerciseReplaced, .exerciseDeleted:
            return "\(event.workoutID.uuidString):\(event.id.uuidString):\(event.kind.rawValue)"
        }
    }

    private func recordProcessed(_ event: WatchWorkoutEvent, fieldKey: String) {
        eventLedger.recentEventIDs.append(event.id)
        if eventLedger.recentEventIDs.count > 512 {
            eventLedger.recentEventIDs.removeFirst(eventLedger.recentEventIDs.count - 512)
        }
        eventLedger.latestSequenceByField[fieldKey] = max(
            event.sequence,
            eventLedger.latestSequenceByField[fieldKey] ?? Int64.min)
        let workoutKey = event.workoutID.uuidString
        var sequences = eventLedger.latestSequenceByWorkout ?? [:]
        sequences[workoutKey] = max(sequences[workoutKey] ?? 0, event.sequence)
        eventLedger.latestSequenceByWorkout = sequences
        if event.kind == .workoutCreated || event.snapshot?.startedOnWatch == true { recordWatchOrigin(event.workoutID) }
        if eventLedger.latestSequenceByField.count > 2_048 {
            let keysToRemove = Array(eventLedger.latestSequenceByField.keys.prefix(
                eventLedger.latestSequenceByField.count - 2_048))
            for key in keysToRemove {
                eventLedger.latestSequenceByField.removeValue(forKey: key)
            }
        }
        persistEventLedger()
    }

    private func recordWatchOrigin(_ workoutID: UUID) {
        var origins = eventLedger.watchStartedWorkoutIDs ?? []
        if origins.insert(workoutID).inserted {
            eventLedger.watchStartedWorkoutIDs = origins
            publishConnectionStatus()
        }
    }

    private func persistEventLedger() {
        if let data = WatchWorkoutWire.encode(eventLedger) {
            UserDefaults.standard.set(data, forKey: Self.eventLedgerDefaultsKey)
        }
    }

    private func acknowledge(eventID: UUID,
                             replyHandler: (([String: Any]) -> Void)?) {
        guard let data = WatchWorkoutWire.encode(WatchWorkoutEventAck(eventIDs: [eventID])) else {
            replyHandler?([:])
            return
        }
        let payload: [String: Any] = [PayloadKey.workoutEventAck: data]
        if let replyHandler = replyHandler {
            replyHandler(payload)
            return
        }
        connectivityQueue.async {
            guard self.isActivated else {
                self.pendingEventAcknowledgements.insert(eventID)
                return
            }
            self.session.transferUserInfo(payload)
            if self.isReachable {
                self.session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
            }
        }
    }
}

extension WatchConnectionManager {
    func wasStartedOnWatch(_ workout: Workout) -> Bool {
        guard !workout.isImported, let id = workout.uuid else { return false }
        return eventLedger.watchStartedWorkoutIDs?.contains(id) == true ||
            (workout.isCurrentWorkout && workout.healthExportState == "watch")
    }

    /// Publishes the complete current workout through application context (the
    /// durable latest value) and an immediate message when the Watch is reachable.
    func syncCurrentWorkoutSnapshot(allowWatchAdoption: Bool = false) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.syncCurrentWorkoutSnapshot(allowWatchAdoption: allowWatchAdoption) }
            return
        }
        pendingWatchAdoption = pendingWatchAdoption || allowWatchAdoption
        pendingSnapshotBuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let allowAdoption = self.pendingWatchAdoption
            self.pendingWatchAdoption = false
            self.pendingSnapshotBuild = nil
            self.publishCurrentWorkoutSnapshot(allowWatchAdoption: allowAdoption)
        }
        pendingSnapshotBuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    private func publishCurrentWorkoutSnapshot(allowWatchAdoption: Bool) {
        // The preference controls automatic companion startup, not edits to a
        // workout the user has already started on either device.
        guard allowWatchAdoption || currentWatchWorkoutUuid != nil else { return }
        if (try? readDeferredWorkouts().snapshots.values.contains {
            !$0.isFinishedRecord && $0.workoutID != currentWatchWorkoutUuid
        }) == true {
            // The Watch owns a different active projection that was deferred
            // to preserve the phone's workout. Never overwrite it with the
            // unrelated phone current-workout application context.
            return
        }
        let context = WorkoutDataStorage.shared.persistentContainer.viewContext
        context.perform {
            do {
                guard let workout = try context.fetch(Workout.currentWorkoutFetchRequest).first,
                      !workout.isImported,
                      let workoutID = workout.uuid,
                      allowWatchAdoption || self.currentWatchWorkoutUuid == workoutID else { return }
                if allowWatchAdoption { self.currentWatchWorkoutUuid = workoutID }
                self.sendWorkoutSnapshot(self.makeSnapshot(for: workout))
            } catch {
                os_log("Could not create Watch workout snapshot: %@", log: .watch, type: .error,
                       error.localizedDescription)
            }
        }
    }

    func makeSnapshot(for workout: Workout, after minimumRevision: Int64 = 0) -> WatchWorkoutSnapshot {
        let now = Date()
        let workoutID = workout.uuid ?? UUID()
        if workout.uuid == nil { workout.uuid = workoutID }

        let appWeightUnit = SettingsStore.shared.weightUnit
        let wireWeightUnit: WatchWorkoutWeightUnit = appWeightUnit == .imperial ? .pound : .kilogram
        let displayWeight: (NSNumber?) -> Double? = { weight in
            guard let kilograms = weight?.doubleValue else { return nil }
            return WeightUnit.convert(weight: kilograms, from: .metric, to: appWeightUnit)
        }

        let workoutExercises = workout.workoutExercises?.array.compactMap { $0 as? WorkoutExercise } ?? []
        let watchExercises: [WatchWorkoutExercise] = workoutExercises.enumerated().map { exerciseIndex, workoutExercise in
            let exerciseID = workoutExercise.uuid ?? UUID()
            if workoutExercise.uuid == nil { workoutExercise.uuid = exerciseID }

            let sets = workoutExercise.workoutSets?.array.compactMap { $0 as? WorkoutSet } ?? []
            let watchSets = sets.enumerated().map { setIndex, set -> WatchWorkoutSet in
                let setID = set.uuid ?? UUID()
                if set.uuid == nil { set.uuid = setID }
                return WatchWorkoutSet(
                    id: setID,
                    order: setIndex + 1,
                    weight: displayWeight(set.weight),
                    reps: set.repetitions?.intValue,
                    rpe: set.rpeValue,
                    previousWeight: nil,
                    previousReps: nil,
                    completed: set.isCompleted,
                    tag: set.tagValue?.rawValue,
                    duration: set.durationValue,
                    distance: set.distanceValue,
                    comment: set.comment,
                    minTargetReps: set.minTargetRepetitionsValue.map(Int.init),
                    maxTargetReps: set.maxTargetRepetitionsValue.map(Int.init))
            }
            let catalog = workoutExercise.exercise(in: ExerciseStore.shared.exercises)
            let title = catalog?.title ?? "Exercise"
            let restTimerDuration = workoutExercise.restTimerDurationValue
                ?? defaultRestTimerDuration(for: workoutExercise)
            return WatchWorkoutExercise(id: exerciseID, order: exerciseIndex + 1,
                                        name: title, sets: watchSets,
                                        restTimerDuration: restTimerDuration,
                                        muscleGroup: catalog?.muscleGroup,
                                        exerciseUuid: workoutExercise.exerciseUuid,
                                        imageURL: catalog?.imageURL?.absoluteString,
                                        imageData: nil,
                                        supersetID: workoutExercise.supersetUuid,
                                        comment: workoutExercise.comment,
                                        trackingType: workoutExercise.setTrackingType.rawValue,
                                        exerciseNote: ExerciseNotes.note(for: workoutExercise.exerciseUuid),
                                        routineNote: workoutExercise.routineNote,
                                        routineExerciseID: workoutExercise.routineNoteSource()?.uuid)
        }

        let allSets = watchExercises.flatMap(\.sets)
        let focusedSetID = WorkoutSetFocus.next(in: workout).flatMap { focus in
            orderedExercises(in: workout)
                .flatMap { $0.workoutSets?.array as? [WorkoutSet] ?? [] }
                .first { $0.objectID == focus.setID }?.uuid
        }
        let selectedID = selectedWatchSetUuid.flatMap { selected in
            allSets.contains(where: { $0.id == selected }) ? selected : nil
        } ?? focusedSetID ?? allSets.first(where: { !$0.completed })?.id ?? allSets.first?.id
        let selectedText = allSets.first(where: { $0.id == selectedID })
            .map { $0.displayText(weightUnit: wireWeightUnit) }

        lastSnapshotRevision = WatchWorkoutSnapshot.nextRevision(
            after: max(lastSnapshotRevision, minimumRevision), at: now)
        var snapshot = WatchWorkoutSnapshot(
            workoutID: workoutID,
            title: workout.displayTitle(in: ExerciseStore.shared.exercises),
            startDate: workout.start ?? now,
            endDate: workout.end,
            exercises: watchExercises,
            selectedSetID: selectedID,
            selectedSetText: selectedText,
            restTimerEnd: RestTimerStore.shared.restTimerEnd,
            keepRestTimerRunning: SettingsStore.shared.keepRestTimerRunning,
            weightUnit: wireWeightUnit,
            sessionEffort: workout.sessionEffortValue,
            library: nil,
            revision: lastSnapshotRevision,
            updatedAt: now,
            comment: workout.comment,
            sourceSavedWorkoutID: workout.workoutRoutine?.uuid,
            pausedRestRemaining: RestTimerStore.shared.isPaused
                ? RestTimerStore.shared.restTimerRemainingTime
                : nil,
            isFinished: false)
        snapshot.healthTestMode = workout.healthExportState == "test" || SettingsStore.shared.healthTestMode
        snapshot.startedOnWatch = wasStartedOnWatch(workout)
        let key = workoutID.uuidString
        snapshot.acknowledgedWatchSequence = eventLedger.latestSequenceByWorkout?[key]
            ?? eventLedger.latestSequenceByField.filter { $0.key.hasPrefix(key + ":") }.values.max() ?? 0
        return snapshot
    }

    func scheduleWorkoutLibrarySync(immediate: Bool = false) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.scheduleWorkoutLibrarySync(immediate: immediate)
            }
            return
        }
        pendingLibrarySync?.cancel()
        libraryBuildGeneration &+= 1
        let generation = libraryBuildGeneration
        let work = DispatchWorkItem { [weak self] in
            self?.buildAndTransferWorkoutLibrary(generation: generation)
        }
        pendingLibrarySync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0 : 0.75), execute: work)
    }

    private func buildAndTransferWorkoutLibrary(generation: UInt64) {
        guard SettingsStore.shared.watchCompanion, isActivated else { return }
        let appUnit = SettingsStore.shared.weightUnit
        let wireUnit: WatchWorkoutWeightUnit = appUnit == .imperial ? .pound : .kilogram
        let exerciseCatalog = ExerciseStore.shared.exercises
        let picks = ExerciseStore.shared.shownExercises.map {
            WatchExercisePick(id: $0.uuid, name: $0.title, muscle: $0.muscleGroup,
                              imageURL: $0.imageURL?.absoluteString,
                              listed: ExerciseStore.shared.isBrowsable($0) ? nil : false)
        }
        let context = WorkoutDataStorage.shared.persistentContainer.newBackgroundContext()
        context.undoManager = nil
        context.perform { [weak self] in
            guard let self else { return }
            do {
                let routineRequest: NSFetchRequest<WorkoutRoutine> = WorkoutRoutine.fetchRequest()
                let routines = try context.fetch(routineRequest)
                var saved: [WatchSavedWorkout] = []
                saved.reserveCapacity(routines.count)
                for routine in routines {
                    saved.append(self.makeSavedWorkout(routine, weightUnit: wireUnit,
                                                       appUnit: appUnit, catalog: exerciseCatalog))
                }
                let historyRequest: NSFetchRequest<Workout> = Workout.fetchRequest()
                historyRequest.predicate = NSPredicate(format: "isCurrentWorkout == NO AND end != nil")
                historyRequest.sortDescriptors = [NSSortDescriptor(keyPath: \Workout.start, ascending: false)]
                let completedWorkouts = try context.fetch(historyRequest)
                var history: [WatchWorkoutSnapshot] = []
                history.reserveCapacity(completedWorkouts.count)
                for workout in completedWorkouts {
                    history.append(self.makeLibrarySnapshot(workout, weightUnit: wireUnit,
                                                            appUnit: appUnit, catalog: exerciseCatalog))
                }
                var library = WatchWorkoutLibrary(generatedAt: Date(), exercises: picks,
                                                  savedWorkouts: saved, history: history,
                                                  weightUnit: wireUnit)
                library.revision = Int64(Date().timeIntervalSince1970 * 1_000_000)
                guard let data = WatchWorkoutWire.encode(library) else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.libraryBuildGeneration else { return }
                    self.transferWorkoutLibrary(data)
                }
            } catch {
                os_log("Could not build Watch workout library: %@", log: .watch, type: .error,
                       error.localizedDescription)
            }
        }
    }

    private func makeSavedWorkout(_ routine: WorkoutRoutine, weightUnit: WatchWorkoutWeightUnit,
                                  appUnit: WeightUnit, catalog: [Exercise]) -> WatchSavedWorkout {
        let sourceExercises = routine.workoutRoutineExercises?.array as? [WorkoutRoutineExercise] ?? []
        var exercises: [WatchWorkoutExercise] = []
        exercises.reserveCapacity(sourceExercises.count)
        for (index, source) in sourceExercises.enumerated() {
            let exercise = source.exercise(in: catalog)
            let sourceSets = source.workoutRoutineSets?.array as? [WorkoutRoutineSet] ?? []
            var sets: [WatchWorkoutSet] = []
            sets.reserveCapacity(sourceSets.count)
            for (setIndex, sourceSet) in sourceSets.enumerated() {
                let weight = sourceSet.weightValue.map {
                    WeightUnit.convert(weight: $0, from: .metric, to: appUnit)
                }
                sets.append(WatchWorkoutSet(
                    id: sourceSet.uuid ?? UUID(), order: setIndex + 1,
                    weight: weight, reps: nil, rpe: nil, completed: false,
                    tag: sourceSet.tagValue?.rawValue,
                    duration: sourceSet.durationValue, distance: SetTrackingPreferences.routineDistance(for: sourceSet.uuid), comment: sourceSet.comment,
                    minTargetReps: sourceSet.minRepetitionsValue.map(Int.init),
                    maxTargetReps: sourceSet.maxRepetitionsValue.map(Int.init)))
            }
            exercises.append(WatchWorkoutExercise(
                id: source.uuid ?? UUID(), order: index + 1,
                name: exercise?.title ?? "Exercise", sets: sets,
                restTimerDuration: source.restTimerDurationValue,
                muscleGroup: exercise?.muscleGroup, exerciseUuid: source.exerciseUuid,
                imageURL: exercise?.imageURL?.absoluteString,
                supersetID: source.supersetUuid, comment: nil,
                trackingType: source.trackingType(catalogExercise: exercise).rawValue,
                exerciseNote: ExerciseNotes.note(for: source.exerciseUuid),
                routineNote: source.comment, routineExerciseID: source.uuid))
        }
        return WatchSavedWorkout(id: routine.uuid ?? UUID(), title: routine.displayTitle,
                                 exercises: exercises, weightUnit: weightUnit,
                                 comment: routine.comment, updatedAt: Date())
    }

    private func makeLibrarySnapshot(_ workout: Workout, weightUnit: WatchWorkoutWeightUnit,
                                     appUnit: WeightUnit, catalog: [Exercise]) -> WatchWorkoutSnapshot {
        let sourceExercises = workout.workoutExercises?.array as? [WorkoutExercise] ?? []
        var exercises: [WatchWorkoutExercise] = []
        exercises.reserveCapacity(sourceExercises.count)
        for (index, source) in sourceExercises.enumerated() {
            let exercise = source.exercise(in: catalog)
            let sourceSets = source.workoutSets?.array as? [WorkoutSet] ?? []
            var sets: [WatchWorkoutSet] = []
            sets.reserveCapacity(sourceSets.count)
            for (setIndex, set) in sourceSets.enumerated() {
                let weight = set.weight.map {
                    WeightUnit.convert(weight: $0.doubleValue, from: .metric, to: appUnit)
                }
                sets.append(WatchWorkoutSet(
                    id: set.uuid ?? UUID(), order: setIndex + 1,
                    weight: weight, reps: set.repetitions?.intValue, rpe: set.rpeValue,
                    completed: set.isCompleted, tag: set.tagValue?.rawValue,
                    duration: set.durationValue, distance: set.distanceValue,
                    comment: set.comment,
                    minTargetReps: set.minTargetRepetitionsValue.map(Int.init),
                    maxTargetReps: set.maxTargetRepetitionsValue.map(Int.init)))
            }
            exercises.append(WatchWorkoutExercise(
                id: source.uuid ?? UUID(), order: index + 1,
                name: exercise?.title ?? "Exercise", sets: sets,
                restTimerDuration: source.restTimerDurationValue,
                muscleGroup: exercise?.muscleGroup, exerciseUuid: source.exerciseUuid,
                imageURL: exercise?.imageURL?.absoluteString, imageData: nil,
                supersetID: source.supersetUuid, comment: source.comment,
                trackingType: source.trackingType(catalogExercise: exercise).rawValue,
                exerciseNote: ExerciseNotes.note(for: source.exerciseUuid),
                routineNote: source.routineNote, routineExerciseID: source.routineNoteSource()?.uuid))
        }
        return WatchWorkoutSnapshot(
            workoutID: workout.uuid ?? UUID(), title: workout.displayTitle(in: catalog),
            startDate: workout.start ?? workout.end ?? Date(), endDate: workout.end,
            exercises: exercises, weightUnit: weightUnit,
            sessionEffort: workout.sessionEffortValue, library: nil,
            revision: 0, updatedAt: workout.end ?? workout.start ?? Date(),
            comment: workout.comment, sourceSavedWorkoutID: workout.workoutRoutine?.uuid)
    }

    private func transferWorkoutLibrary(_ data: Data) {
        connectivityQueue.async {
            guard self.isActivated else { return }
            self.cancelOutstandingTransfers(marker: Self.libraryTransferMarker)
            _ = self.stageTransfer(data, prefix: Self.libraryFilePrefix, metadata: [
                Self.libraryTransferMarker: true,
                PayloadKey.workoutLibrary: true,
                "schemaVersion": WatchWorkoutWire.schemaVersion
            ])
        }
    }

    private func cancelOutstandingTransfers(marker: String, workoutID: UUID? = nil) {
        for transfer in session.outstandingFileTransfers
        where transfer.file.metadata?[marker] as? Bool == true {
            if let workoutID {
                let id = (transfer.file.metadata?[PayloadKey.Arg.uuid] as? String).flatMap(UUID.init(uuidString:))
                    ?? (try? Data(contentsOf: transfer.file.fileURL)).flatMap {
                        WatchWorkoutWire.decode(WatchWorkoutSnapshot.self, from: $0)?.workoutID
                    }
                guard id == workoutID else { continue }
            }
            transfer.cancel()
        }
    }

    @discardableResult
    private func stageTransfer(_ data: Data, prefix: String,
                               metadata: [String: Any]) -> Bool {
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                prefix + UUID().uuidString + ".json", isDirectory: false)
            try data.write(to: url, options: [.atomic])
            retainedTransferFiles.insert(url)
            session.transferFile(url, metadata: metadata)
            return true
        } catch {
            os_log("Could not stage Watch file transfer: %@", log: .watch, type: .error,
                   error.localizedDescription)
            return false
        }
    }

    private enum WatchExerciseThumbnailEncoder {
        static func jpeg(for exercise: Exercise) -> Data? {
            guard let path = exercise.pdfPaths.first else { return nil }
            let url = ExerciseStore.defaultBuiltInExercisesResourceURL.appendingPathComponent(path)
            guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else { return nil }
            let pageRect = page.getBoxRect(.mediaBox)
            let edge: CGFloat = 120
            let scale = min(edge / pageRect.width, edge / pageRect.height)
            let renderSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
            let renderer = UIGraphicsImageRenderer(size: renderSize)
            let image = renderer.image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: renderSize))
                context.cgContext.translateBy(x: 0, y: renderSize.height)
                context.cgContext.scaleBy(x: scale, y: -scale)
                context.cgContext.drawPDFPage(page)
            }
            return image.jpegData(compressionQuality: 0.72)
        }
    }

    private func sendWorkoutSnapshot(_ snapshot: WatchWorkoutSnapshot) {
        dispatchPrecondition(condition: .onQueue(.main))
        pendingSnapshot = snapshot
        let catalog = ExerciseStore.shared.exercises
        let healthTestModePreference = SettingsStore.shared.healthTestMode
        connectivityQueue.async {
            guard self.isActivated else { return }
            guard Self.phoneFinalizationDate(snapshot.workoutID) == nil,
                  !Self.wasDeletedOnPhone(snapshot.workoutID) else {
                self.clearPendingSnapshot(snapshot)
                return
            }
            var snapshot = snapshot
            // History lookups and PDF/JPEG rendering must not run on the view
            // context/main queue for each workout message.
            let historyContext = WorkoutDataStorage.shared.persistentContainer.newBackgroundContext()
            historyContext.performAndWait {
                let unit: WeightUnit = snapshot.weightUnit == .pound ? .imperial : .metric
                for index in snapshot.exercises.indices {
                    let request = WorkoutExercise.historyFetchRequest(of: snapshot.exercises[index].exerciseUuid,
                                                                      until: snapshot.startDate)
                    request.fetchLimit = 1
                    let previous = (try? historyContext.fetch(request).first) ?? nil
                    let sets = previous?.workoutSets?.array as? [WorkoutSet] ?? []
                    for setIndex in snapshot.exercises[index].sets.indices {
                        let previousSet = sets.indices.contains(setIndex) ? sets[setIndex] : sets.last
                        snapshot.exercises[index].sets[setIndex].previousWeight = previousSet?.weight.map {
                            WeightUnit.convert(weight: $0.doubleValue, from: .metric, to: unit)
                        }
                        snapshot.exercises[index].sets[setIndex].previousReps = previousSet?.repetitions?.intValue
                    }
                }
            }
            for index in snapshot.exercises.indices {
                let exercise = snapshot.exercises[index]
                guard exercise.imageData == nil, exercise.imageURL == nil,
                      let id = exercise.exerciseUuid else { continue }
                if self.workoutThumbnailCache[id] == nil,
                   let source = catalog.first(where: { $0.uuid == id }) {
                    self.workoutThumbnailCache[id] = WatchExerciseThumbnailEncoder.jpeg(for: source)
                }
                snapshot.exercises[index].imageData = self.workoutThumbnailCache[id]
            }
            // The phone may have finished while artwork/history was prepared.
            guard Self.phoneFinalizationDate(snapshot.workoutID) == nil,
                  !Self.wasDeletedOnPhone(snapshot.workoutID) else {
                self.clearPendingSnapshot(snapshot)
                return
            }
            guard let data = WatchWorkoutWire.encode(snapshot),
                  let content = WatchSyncContent.workoutData(data) else { return }
            guard content != self.lastSentSnapshotContent else {
                self.clearPendingSnapshot(snapshot)
                return
            }
            self.cancelOutstandingTransfers(marker: Self.snapshotTransferMarker)
            var delivered = false
            if data.count > Self.snapshotMessageLimit {
                var metadata: [String: Any] = [
                    Self.snapshotTransferMarker: true,
                    PayloadKey.workoutSnapshot: true,
                    PayloadKey.Arg.uuid: snapshot.workoutID.uuidString,
                    "schemaVersion": WatchWorkoutWire.schemaVersion
                ]
                #if DEBUG
                metadata[PayloadKey.healthTestMode] = healthTestModePreference
                #endif
                delivered = self.stageTransfer(data, prefix: Self.snapshotFilePrefix, metadata: metadata)
                // Preserve the compact-message/full-artwork-file pair. Their
                // revision is identical, but their content deliberately differs.
                var compact = snapshot
                for index in compact.exercises.indices { compact.exercises[index].imageData = nil }
                if let compactData = WatchWorkoutWire.encode(compact), compactData.count <= Self.snapshotMessageLimit {
                    delivered = self.sendSnapshotPayload(compactData, healthTestModePreference: healthTestModePreference) || delivered
                }
            } else {
                delivered = self.sendSnapshotPayload(data, healthTestModePreference: healthTestModePreference)
            }
            if delivered {
                self.lastSentSnapshotContent = content
                self.clearPendingSnapshot(snapshot)
            }
        }
    }

    private func clearPendingSnapshot(_ snapshot: WatchWorkoutSnapshot) {
        DispatchQueue.main.async {
            if self.pendingSnapshot?.workoutID == snapshot.workoutID,
               self.pendingSnapshot?.revision == snapshot.revision {
                self.pendingSnapshot = nil
            }
        }
    }

    private func sendSnapshotPayload(_ data: Data, healthTestModePreference: Bool) -> Bool {
        var payload: [String: Any] = [PayloadKey.workoutSnapshot: data]
        #if DEBUG
        payload[PayloadKey.healthTestMode] = healthTestModePreference
        #endif
        do {
            try updateApplicationContextIfChanged(applicationContextIncludingPreferences(payload))
        } catch {
            os_log("Could not update Watch application context: %@", log: .watch, type: .error,
                   error.localizedDescription)
            return false
        }
        if isReachable {
            session.sendMessage(payload, replyHandler: nil) { error in
                os_log("Could not immediately send Watch workout snapshot: %@", log: .watch,
                       type: .debug, error.localizedDescription)
            }
        }
        return true
    }

    /// wrapper to send either via message or transfer, depending on what's available
    private func sendUserInfo(userInfo: [String : Any]) {
        connectivityQueue.async {
            self.pendingUserInfo.enqueue(userInfo)
            self.flushPendingUserInfo()
        }
    }

    private func flushPendingUserInfo() {
        dispatchPrecondition(condition: .onQueue(connectivityQueue))
        guard isActivated else { return }
        for userInfo in pendingUserInfo.takeAll() {
            if isReachable {
                os_log("Messaging userInfo=%@", log: .watch, type: .debug, userInfo)
                session.sendMessage(userInfo, replyHandler: nil) { error in
                    os_log("Messaging not possible, falling back to transfering", log: .watch, type: .fault)
                    self.connectivityQueue.async {
                        // Activation can be lost between send and its error callback.
                        if self.isActivated {
                            self.session.transferUserInfo(userInfo)
                        } else {
                            self.pendingUserInfo.enqueue(userInfo)
                        }
                    }
                }
            } else {
                os_log("Transfering userInfo=%@", log: .watch, type: .debug, userInfo)
                session.transferUserInfo(userInfo)
            }
        }
    }
    
    
    /// - NOTE: If in the prepare handler a workout session isn't started, a ignorePreparedWorkoutSession should be send
    func prepareWatchWorkout(workoutID: UUID? = nil,
                             startWatchCompanionErrorHandler: StartWatchCompanionErrorHandler? = nil,
                             preparedHandler: @escaping PrepareHandler) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.prepareWatchWorkout(workoutID: workoutID,
                                         startWatchCompanionErrorHandler: startWatchCompanionErrorHandler,
                                         preparedHandler: preparedHandler)
            }
            return
        }
        os_log("Preparing watch app", log: .watch, type: .default)
        guard isActivated else {
            guard let workoutID else {
                startWatchCompanionErrorHandler?(
                    GenericError(description: "Watch connectivity is not active"))
                activateSession()
                return
            }
            pendingPrepareRequest = PendingPrepareRequest(
                workoutID: workoutID,
                preparedHandler: preparedHandler,
                errorHandler: startWatchCompanionErrorHandler)
            os_log("Deferring Watch preparation until connectivity activates", log: .watch, type: .info)
            activateSession()
            return
        }
        beginPreparingWatch(workoutID: workoutID, startWatchCompanionErrorHandler: startWatchCompanionErrorHandler,
                            preparedHandler: preparedHandler)
    }

    private func beginPreparingWatch(
        workoutID: UUID?,
        startWatchCompanionErrorHandler: StartWatchCompanionErrorHandler?,
        preparedHandler: @escaping PrepareHandler
    ) {
        #if DEBUG
        var isTestWorkout = SettingsStore.shared.healthTestMode
        if let workoutID {
            let context = WorkoutDataStorage.shared.persistentContainer.viewContext
            context.performAndWait {
                if let workout = try? context.fetch(Workout.currentWorkoutFetchRequest).first,
                   workout.uuid == workoutID, workout.healthExportState == "test" {
                    isTestWorkout = true
                }
            }
        }
        if isTestWorkout {
            // Send the start/snapshot directly. Asking HealthKit to launch and
            // prepare the Watch can race the preference delivery and create a
            // session for a test whose phone preference has since been disabled.
            preparedHandler()
            return
        }
        #endif
        self.preparedHandler = preparedHandler // set here, because the prepare message can be received even before startWatchApp() completion fires
        os_log("Using HKHealthStore to open watch app", log: .watch, type: .default)
        HealthManager.shared.healthStore.startWatchApp(with: HealthManager.shared.workoutConfiguration) { success, error in
            guard success else {
                // This happens when app is in background (e.g. when started from an intent)
                os_log("HKHealthStore could not open watch app: %@", log: .watch, type: .fault, error?.localizedDescription ?? "nil")
                self.preparedHandler = nil
                startWatchCompanionErrorHandler?(error ?? GenericError(description: "Opening the watch app was unsuccessful"))
                return
            }
            os_log("Successfully opened watch app", log: .watch, type: .info)
        }
    }

    private func resumePendingPrepareRequest() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let pending = pendingPrepareRequest else { return }
        pendingPrepareRequest = nil
        let context = WorkoutDataStorage.shared.persistentContainer.viewContext
        context.perform {
            do {
                guard let workout = try context.fetch(Workout.currentWorkoutFetchRequest).first,
                      workout.uuid == pending.workoutID,
                      !workout.isImported else {
                    os_log("Discarding stale deferred Watch preparation", log: .watch, type: .info)
                    return
                }
                self.beginPreparingWatch(workoutID: pending.workoutID, startWatchCompanionErrorHandler: pending.errorHandler,
                                         preparedHandler: pending.preparedHandler)
            } catch {
                pending.errorHandler?(error)
            }
        }
    }
    
    /// Tells the watch that it should not expect an answer to its prepared message
    func ignorePreparedWatchWorkout() {
        os_log("Notifying watch app that prepared message was ignored", log: .watch, type: .default)
        
        sendUserInfo(userInfo: [PayloadKey.ignoredPreparedWorkoutSession : true])
    }
    
    func startWatchWorkout(start: Date, uuid: UUID, isHealthTestWorkout: Bool = false) {
        os_log("Starting watch workout", log: .watch, type: .default)
        
        if currentWatchWorkoutUuid != nil {
            os_log("Overwriting currentWatchWorkoutUuid", log: .watch, type: .error)
        }
        var arguments: [String: Any] = [PayloadKey.Arg.start: start, PayloadKey.Arg.uuid: uuid.uuidString]
        #if DEBUG
        arguments[PayloadKey.healthTestMode] = SettingsStore.shared.healthTestMode
        arguments[PayloadKey.Arg.isHealthTestWorkout] = isHealthTestWorkout
        #endif
        sendUserInfo(userInfo: [PayloadKey.startWorkoutSession: arguments])
        currentWatchWorkoutUuid = uuid
        syncCurrentWorkoutSnapshot()
    }
    
    func updateWatchWorkoutStart(start: Date, uuid: UUID) {
        os_log("Updating watch workout start date", log: .watch, type: .default)
        
        if currentWatchWorkoutUuid != uuid {
            os_log("Sending update watch workout start date for different uuid", log: .watch, type: .error)
        }
        sendUserInfo(userInfo: [PayloadKey.updateWorkoutSessionStart : [PayloadKey.Arg.start : start, PayloadKey.Arg.uuid : uuid.uuidString]])
    }
    
    func updateWatchWorkoutEnd(end: Date?, uuid: UUID) {
        os_log("Updating watch workout end date", log: .watch, type: .default)
        
        if currentWatchWorkoutUuid != uuid {
            os_log("Sending update watch workout end date for different uuid", log: .watch, type: .error)
        }
        if let end = end {
            sendUserInfo(userInfo: [PayloadKey.updateWorkoutSessionEnd : [PayloadKey.Arg.end : end, PayloadKey.Arg.uuid : uuid.uuidString]])
        } else {
            sendUserInfo(userInfo: [PayloadKey.updateWorkoutSessionEnd : [PayloadKey.Arg.uuid : uuid.uuidString]])
        }
    }
    
    func updateWatchWorkoutRestTimer(end: Date?, keepRunning: Bool?, uuid: UUID) {
        os_log("Updating watch workout rest timer end", log: .watch, type: .default)
        
        if currentWatchWorkoutUuid != uuid {
            os_log("Sending update watch workout rest timer end for different uuid", log: .watch, type: .error)
        }
        
        var args: [String : Any] = [PayloadKey.Arg.uuid : uuid.uuidString]
        if let end = end {
            args[PayloadKey.Arg.end] = end
        }
        if let keepRunning = keepRunning {
            args[PayloadKey.Arg.keepRestTimerRunning] = keepRunning
        }
        
        sendUserInfo(userInfo: [PayloadKey.updateWorkoutSessionRestTimer : args])
        syncCurrentWorkoutSnapshot()
    }
    
    func updateWatchWorkoutSelectedSet(text: String?, uuid: UUID) {
        os_log("Updating watch workout selected set", log: .watch, type: .default)
        
        if currentWatchWorkoutUuid != uuid {
            os_log("Sending update watch workout selected set for different uuid", log: .watch, type: .error)
        }
        if let text = text {
            sendUserInfo(userInfo: [PayloadKey.updateWorkoutSessionSelectedSet : [PayloadKey.Arg.text : text, PayloadKey.Arg.uuid : uuid.uuidString]])
        } else {
            sendUserInfo(userInfo: [PayloadKey.updateWorkoutSessionSelectedSet : [PayloadKey.Arg.uuid : uuid.uuidString]])
        }
        syncCurrentWorkoutSnapshot()
    }
    
    func finishWatchWorkout(start: Date, end: Date, title: String?, uuid: UUID,
                            healthTestMode: Bool = false) {
        os_log("Finishing watch workout", log: .watch, type: .default)
        retireSnapshotDelivery(workoutID: uuid)
        
        if currentWatchWorkoutUuid != uuid {
             os_log("Sending finish watch workout for different uuid", log: .watch, type: .error)
        }
        var arguments: [String: Any] = [PayloadKey.Arg.start: start, PayloadKey.Arg.end: end,
                                       PayloadKey.Arg.uuid: uuid.uuidString]
        if let title { arguments[PayloadKey.Arg.title] = title }
        #if DEBUG
        arguments[PayloadKey.healthTestMode] = healthTestMode || SettingsStore.shared.healthTestMode
        #endif
        sendUserInfo(userInfo: [PayloadKey.endWorkoutSession: arguments])
        currentWatchWorkoutUuid = nil
    }
    
    func discardWatchWorkout(uuid: UUID) {
        os_log("Discarding watch workout", log: .watch, type: .default)
        Self.recordDeletedWorkoutIDs([uuid])
        retireSnapshotDelivery(workoutID: uuid)
        
        if currentWatchWorkoutUuid != uuid {
            os_log("Sending discard watch workout for different uuid", log: .watch, type: .error)
        }
        sendUserInfo(userInfo: [PayloadKey.discardWorkoutSession : [PayloadKey.Arg.uuid : uuid.uuidString]])
        currentWatchWorkoutUuid = nil
    }
    
    var currentWatchWorkoutUuid: UUID? {
        get {
            UserDefaults.standard.watchWorkoutUuid
        }
        set {
            let previous = UserDefaults.standard.watchWorkoutUuid
            guard newValue != previous else { return }
            UserDefaults.standard.watchWorkoutUuid = newValue
            liveMetrics.clear()
        }
    }
}

extension WatchConnectionManager {
    func prepareAndStartWatchWorkout(workout: Workout, startWatchCompanionErrorHandler: StartWatchCompanionErrorHandler? = nil) {
        // Historical imports must never become a Watch HealthKit session.
        guard !workout.isImported, let workoutID = workout.uuid else { return }
        prepareWatchWorkout(workoutID: workoutID,
                            startWatchCompanionErrorHandler: startWatchCompanionErrorHandler) {
            self.startWatchWorkout(workout: workout)
        }
    }
    
    private func startWatchWorkout(workout: Workout) {
        guard let context = workout.managedObjectContext else {
            os_log("Workout context is nil", log: .watch, type: .error)
            self.ignorePreparedWatchWorkout()
            return
        }
        
        context.perform {
            guard workout.isCurrentWorkout, !workout.isImported else {
                os_log("Workout is no longer an eligible current workout", log: .watch, type: .error)
                self.ignorePreparedWatchWorkout()
                return
            }
            guard let start = workout.start else {
                os_log("Start not set on workout", log: .watch, type: .error)
                self.ignorePreparedWatchWorkout()
                assertionFailure("start should always be set at this point")
                return
            }
            guard let uuid = workout.uuid else {
                os_log("UUID not set on workout", log: .watch, type: .error)
                self.ignorePreparedWatchWorkout()
                assertionFailure("uuid is a required property")
                return
            }
            self.startWatchWorkout(start: start, uuid: uuid, isHealthTestWorkout: workout.healthExportState == "test")
        }
    }
}

extension WatchConnectionManager {
    func updateAndObserveWatchWorkoutSelectedSet(workoutSet: WorkoutSet?, uuid: UUID) {
        selectedWatchSetUuid = workoutSet?.uuid
        if selectedSetChangePublisherCancellable == nil {
            selectedSetChangePublisherCancellable = selectedSetChangePublisher
                .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
                .drop { self.currentWatchWorkoutUuid != $0.1 }
                .map { ($0.0?.resultTitle(weightUnit: SettingsStore.shared.weightUnit), $0.1) }
                .removeDuplicates { $0.0 == $1.0 }
                .sink { self.updateWatchWorkoutSelectedSet(text: $0.0, uuid: $0.1) }
        }
        
        selectedSetChangePublisher.send((workoutSet, uuid))
        selectedSetCancellable = workoutSet?.objectWillChange
            .map { _ in (workoutSet, uuid) }
            .subscribe(selectedSetChangePublisher)
    }
}
