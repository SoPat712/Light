//
//  PhoneConnectionManager.swift
//  WatchIron Extension
//
//  Created by Karim Abou Zeid on 02.11.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import Foundation
import WatchConnectivity
import Combine
import HealthKit
import os.log

class PhoneConnectionManager: NSObject, ObservableObject {
    static let shared = PhoneConnectionManager()
    
    private let session = WCSession.default
    
    var objectWillChange = ObservableObjectPublisher() // called when something with the connection changes
    
    func activateSession() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.activateSession() }
            return
        }
        assert(WCSession.isSupported())
        session.delegate = self
        session.activate()
    }
    
    var isReachable: Bool {
        session.isReachable
    }
    
    var isActivated: Bool {
        session.activationState == .activated
    }
    
    private let scheduleDiscardUnstartedWorkoutSessionSubject = PassthroughSubject<Void, Never>()
    private var cancellable: AnyCancellable?
    private let connectivityQueue = DispatchQueue(label: "Light.watchConnectivity", qos: .utility)
    private lazy var preferenceSync = WatchPreferenceSyncManager(queue: connectivityQueue,
        transmit: { [weak self] payload in
            guard let self, self.isActivated else { return false }
            var context = self.session.applicationContext
            context.merge(payload) { _, new in new }
            do {
                if !WatchSyncContent.contextsEqual(context, self.session.applicationContext) {
                    try self.session.updateApplicationContext(context)
                }
            } catch {
                os_log("Could not sync phone preferences: %@", type: .error, error.localizedDescription)
                return false
            }
            if self.isReachable {
                self.session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
            }
            return true
        })
    private var pendingUserInfo: [[String: Any]] = []
    private var eventSendInFlight = Set<UUID>()
    private var eventTransferSent = Set<UUID>()
    private var eventFiles: [URL: UUID] = [:]
    private var eventRetries: [UUID: DispatchWorkItem] = [:]
    private var eventRetryAttempts: [UUID: Int] = [:]
    private var pendingOutboxFlush: DispatchWorkItem?
    private var outboxFlushID: UUID?
    private var outboxPersistenceInFlight = false
    private var outboxFlushRequested = false

    override init() {
        super.init()
        _ = preferenceSync
        cancellable = scheduleDiscardUnstartedWorkoutSessionSubject
            .debounce(for: .seconds(60), scheduler: RunLoop.main) // seems to be a bug in watchOS, when using the accessQueue, debounce fires immediately (watchOS 6.2)
            .receive(on: WorkoutSessionManager.accessQueue)
            .sink {
                os_log("Running scheduled check whether current workout session was never started")
                guard let state = WorkoutSessionManagerStore.shared.workoutSessionManager?.state, state == .prepared || state == .notStarted else { return } // not really necessary
                guard WorkoutSessionManagerStore.shared.workoutSessionManager?.uuid == nil else { return } // make sure the UUID is nil
                os_log("Discarding workout session that is still in the prepared state after 60 seconds have passed since last prepare message")
                WorkoutSessionManagerStore.shared.discardUnstartedWorkoutSession()
            }
    }

    func syncPreferences() {
        preferenceSync.requestSync()
    }

    private func queueUntilActivated(_ userInfo: [String: Any]) {
        // Keep only a bounded number of legacy commands. Durable workout edits
        // use the outbox below and are never held in this transient queue.
        if pendingUserInfo.count >= 32 {
            pendingUserInfo.removeFirst()
        }
        pendingUserInfo.append(userInfo)
    }

    private func flushPendingUserInfo() {
        guard isActivated else { return }
        let pending = pendingUserInfo
        pendingUserInfo.removeAll()
        pending.forEach { sendUserInfo(userInfo: $0) }
    }
}

// MARK: - Receiving
extension PhoneConnectionManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        print(#function + " \(activationState)")
        
        DispatchQueue.main.async {
            if !session.receivedApplicationContext.isEmpty {
                self.receive(message: session.receivedApplicationContext)
            }
            self.preferenceSync.requestSync()
            self.objectWillChange.send()
            self.flushPendingUserInfo()
            self.flushEventOutbox()
            self.sendCurrentWorkoutMetrics()
            self.requestLibrary()
            self.requestCurrentSnapshotIfReady()
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        print(#function)
        
        receive(message: applicationContext)
    }
    
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        print(#function)
        
        receive(message: userInfo)
    }
    
    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        print(#function)
        
        receive(message: message)
    }
    
    func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        print(#function)
        
        receive(message: message)
        replyHandler([:])
    }
    
    func sessionReachabilityDidChange(_ session: WCSession) {
        print(#function + " \(session.isReachable)")
        
        DispatchQueue.main.async {
            self.objectWillChange.send()
            self.preferenceSync.requestSync()
            self.flushEventOutbox()
            self.sendCurrentWorkoutMetrics()
            self.requestLibrary()
            self.requestCurrentSnapshotIfReady()
        }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let isLibrary = file.metadata?["ironWorkoutLibrary"] as? Bool == true
        let isSnapshot = file.metadata?["ironWorkoutSnapshot"] as? Bool == true
        let healthTestMode = file.metadata?[PayloadKey.healthTestMode] as? Bool
        guard isLibrary || isSnapshot else { return }
        do {
            // WCSession owns the temporary URL only for this callback.
            let data = try Data(contentsOf: file.fileURL)
            connectivityQueue.async {
                if isLibrary, let library = WatchWorkoutWire.decode(WatchWorkoutLibrary.self, from: data) {
                    DispatchQueue.main.async { WorkoutSessionManagerStore.shared.applyLibrary(library) }
                } else if isSnapshot, let snapshot = WatchWorkoutWire.decode(WatchWorkoutSnapshot.self, from: data) {
                    DispatchQueue.main.async {
                        WorkoutSessionManagerStore.shared.applyWorkoutSnapshot(snapshot, healthTestModePreference: healthTestMode)
                    }
                } else {
                    DispatchQueue.main.async {
                        WorkoutSessionManagerStore.shared.reportPersistenceFailure(WatchWorkoutPersistenceError.encodingFailed)
                    }
                }
            }
        } catch {
            DispatchQueue.main.async { WorkoutSessionManagerStore.shared.reportPersistenceFailure(error) }
        }
    }
}

extension PhoneConnectionManager {
    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let file = fileTransfer.file
        guard file.metadata?["ironWorkoutEvent"] as? Bool == true else { return }
        connectivityQueue.async {
            guard let eventID = self.eventFiles.removeValue(forKey: file.fileURL) else { return }
            try? FileManager.default.removeItem(at: file.fileURL)
            self.scheduleEventRetry(eventID)
        }
    }

    func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        guard let data = userInfoTransfer.userInfo[PayloadKey.workoutEvent] as? Data else { return }
        connectivityQueue.async {
            guard let event = WatchWorkoutWire.decode(WatchWorkoutEvent.self, from: data) else { return }
            // Transport completion is not a durable phone ACK. Retry if the
            // phone could not save, or if its acknowledgement was lost.
            self.scheduleEventRetry(event.id)
        }
    }
}

// MARK: - Message Handling
extension PhoneConnectionManager {
    private func receive(message: [String : Any]) {
        // An empty reply is a valid transport receipt, not a workout command.
        guard !message.isEmpty else { return }
        connectivityQueue.async {
            self.preferenceSync.applyReceived(message)
            // Apply the phone-owned setting independently of workout commands.
            // Equal contexts do not write defaults, and receipt never resends.
            if let enabled = message["logRPE"] as? Bool {
                DispatchQueue.main.async {
                    if enabled != WatchPreferences.logRPE { WatchPreferences.logRPE = enabled }
                }
            }
            if let data = message[PayloadKey.workoutSnapshot] as? Data,
               let snapshot = WatchWorkoutWire.decode(WatchWorkoutSnapshot.self, from: data) {
                DispatchQueue.main.async {
                    WorkoutSessionManagerStore.shared.applyWorkoutSnapshot(snapshot,
                        healthTestModePreference: message[PayloadKey.healthTestMode] as? Bool)
                }
            } else if let data = message[PayloadKey.workoutEventAck] as? Data,
                      let ack = WatchWorkoutWire.decode(WatchWorkoutEventAck.self, from: data) {
                self.receiveAcknowledgement(ack)
            } else {
                DispatchQueue.main.async { self.receiveCommand(message) }
            }
        }
    }

    private func receiveAcknowledgement(_ ack: WatchWorkoutEventAck) {
        let pending = Set(WatchWorkoutStore.shared.pendingEvents().map(\.id))
        let acknowledged = ack.eventIDs.filter { pending.contains($0) }
        // Reply, message and user-info can all carry the same ACK. Only the
        // delivery that actually drains the outbox may request a fresh snapshot.
        guard !acknowledged.isEmpty else { return }
        do {
            try WatchWorkoutStore.shared.acknowledge(eventIDs: acknowledged)
        } catch {
            acknowledged.forEach {
                eventSendInFlight.remove($0)
                eventTransferSent.remove($0)
            }
            DispatchQueue.main.async { WorkoutSessionManagerStore.shared.reportPersistenceFailure(error) }
            return
        }
        acknowledged.forEach {
            eventSendInFlight.remove($0)
            eventTransferSent.remove($0)
            eventRetries.removeValue(forKey: $0)?.cancel()
            eventRetryAttempts.removeValue(forKey: $0)
        }
        DispatchQueue.main.async { WorkoutSessionManagerStore.shared.notifySyncStateChanged() }
        flushEventOutbox()
        requestCurrentSnapshotIfReady()
    }

    private func receiveCommand(_ message: [String: Any]) {
        #if DEBUG
        if message[PayloadKey.startWorkoutSession] == nil, message[PayloadKey.endWorkoutSession] == nil,
           let enabled = message[PayloadKey.healthTestMode] as? Bool {
            WorkoutSessionManagerStore.shared.setHealthTestMode(enabled)
        }
        #endif
        if let startMessage = message[PayloadKey.startWorkoutSession] as? [String: Any] {
            handleStartWorkoutSessionMessage(message: startMessage)
        } else if let endMessage = message[PayloadKey.endWorkoutSession] as? [String : Any] {
            handleEndWorkoutSessionMessage(message: endMessage)
        } else if let updateStartMessage = message[PayloadKey.updateWorkoutSessionStart] as? [String : Any] {
            handleUpdateWorkoutSessionStartMessage(message: updateStartMessage)
        } else if let updateEndMessage = message[PayloadKey.updateWorkoutSessionEnd] as? [String : Any] {
            handleUpdateWorkoutSessionEndMessage(message: updateEndMessage)
        } else if let updateRestTimerMessage = message[PayloadKey.updateWorkoutSessionRestTimer] as? [String : Any] {
            handleUpdateRestTimerMessage(message: updateRestTimerMessage)
        } else if let updateSelectedSetMessage = message[PayloadKey.updateWorkoutSessionSelectedSet] as? [String : Any] {
            handleUpdateSelectedSetMessage(message: updateSelectedSetMessage)
        } else if let discardMessage = message[PayloadKey.discardWorkoutSession] as? [String : Any] {
            handleDiscardWorkoutSessionMessage(message: discardMessage)
        } else if let unprepare = message[PayloadKey.ignoredPreparedWorkoutSession] as? Bool, unprepare {
            handleIgnoredPreparedWorkoutSession()
        } else if message["logRPE"] is Bool {
            // Log RPE was applied on the serial receive queue without an echo.
        } else if message[PayloadKey.healthTestMode] is Bool {
            // Preference-only context/message; release builds intentionally ignore it.
        } else if message[PayloadKey.plateInventory] != nil || message[PayloadKey.plateLoadouts] != nil {
            // Plate preferences were merged independently of workout commands.
        } else if message[SetTrackingPreferences.payloadKey] != nil {
            // Set types were merged independently of workout commands.
        } else if message[ExerciseNotes.payloadKey] != nil {
            // Exercise notes were merged independently of workout commands.
        } else {
            os_log("Ignoring unrecognized phone workout message", type: .debug)
        }
    }
    
    /**
     starts the workout session with the given uuid
     if there is a current workout session with the same uuid, only the start date will be updated
     if there is a current workout session with a different uuid, it is discarded and a new workout session is started
     */
    private func handleStartWorkoutSessionMessage(message: [String : Any]) {
        guard let start = message[PayloadKey.Arg.start] as? Date else {
            assertionFailure("start workout with no start parameter")
            return
        }
        guard let uuidString = message[PayloadKey.Arg.uuid] as? String, let uuid = UUID(uuidString: uuidString) else {
            assertionFailure("start workout with no uuid parameter")
            return
        }
        
        WorkoutSessionManagerStore.shared.startWorkoutSession(start: start, uuid: uuid,
            healthTestMode: message[PayloadKey.healthTestMode] as? Bool ?? false,
            isHealthTestWorkout: message[PayloadKey.Arg.isHealthTestWorkout] as? Bool ?? false)
    }
    
    private func handleEndWorkoutSessionMessage(message: [String : Any]) {
        // this message is only valid if the current workoutSession was started with the same UUID
        
        guard let start = message[PayloadKey.Arg.start] as? Date else {
            assertionFailure("end workout with no start parameter")
            return
        }
        guard let end = message[PayloadKey.Arg.end] as? Date else {
            assertionFailure("end workout with no end parameter")
            return
        }
        let title = message[PayloadKey.Arg.title] as? String // nil is allowed
        guard let uuidString = message[PayloadKey.Arg.uuid] as? String, let uuid = UUID(uuidString: uuidString) else {
            assertionFailure("end workout with no uuid parameter")
            return
        }
        
        // The store validates the UUID on its accessQueue before applying the
        // finish's provenance. This must never mutate the next workout.
        WorkoutSessionManagerStore.shared.endWorkoutSession(start: start, end: end,
                                                            title: title, uuid: uuid,
                                                            notifyPhone: false,
                                                            healthTestMode: message[PayloadKey.healthTestMode] as? Bool)
    }
    
    private func handleUpdateWorkoutSessionStartMessage(message: [String : Any]) {
        // this message is only valid if the current workoutSession was started with the same UUID
        
        guard let start = message[PayloadKey.Arg.start] as? Date else {
            assertionFailure("update workout start with no start parameter")
            return
        }
        guard let uuidString = message[PayloadKey.Arg.uuid] as? String, let uuid = UUID(uuidString: uuidString) else {
            assertionFailure("update workout start with no uuid parameter")
            return
        }

        WorkoutSessionManagerStore.shared.updateWorkoutSessionStart(start: start, uuid: uuid)
    }
    
    private func handleUpdateWorkoutSessionEndMessage(message: [String : Any]) {
        // this message is only valid if the current workoutSession was started with the same UUID
        
        let end = message[PayloadKey.Arg.end] as? Date // nil is allowed
        guard let uuidString = message[PayloadKey.Arg.uuid] as? String, let uuid = UUID(uuidString: uuidString) else {
            assertionFailure("update workout end with no uuid parameter")
            return
        }
        
        WorkoutSessionManagerStore.shared.updateWorkoutSessionEnd(end: end, uuid: uuid)
    }
    
    private func handleUpdateRestTimerMessage(message: [String : Any]) {
        // this message is only valid if the current workoutSession was started with the same UUID
        
        let end = message[PayloadKey.Arg.end] as? Date // nil is allowed
        let keepRunning = message[PayloadKey.Arg.keepRestTimerRunning] as? Bool // nil is allowed
        guard let uuidString = message[PayloadKey.Arg.uuid] as? String, let uuid = UUID(uuidString: uuidString) else {
            assertionFailure("update rest timer with no uuid parameter")
            return
        }
        
        WorkoutSessionManagerStore.shared.updateWorkoutSessionRestTimer(end: end, keepRunning: keepRunning, uuid: uuid)
    }
    
    private func handleUpdateSelectedSetMessage(message: [String : Any]) {
        // this message is only valid if the current workoutSession was started with the same UUID
        
        let text = message[PayloadKey.Arg.text] as? String // nil is allowed
        guard let uuidString = message[PayloadKey.Arg.uuid] as? String, let uuid = UUID(uuidString: uuidString) else {
            assertionFailure("update selected set with no uuid parameter")
            return
        }
        
        WorkoutSessionManagerStore.shared.updateWorkoutSessionSelectedSetText(text: text, uuid: uuid)
    }
    
    private func handleDiscardWorkoutSessionMessage(message: [String : Any]) {
        // this message is only valid if the current workoutSession was started with the same UUID
        
        guard let uuidString = message[PayloadKey.Arg.uuid] as? String, let uuid = UUID(uuidString: uuidString) else {
            assertionFailure("discard workout with no uuid parameter")
            return
        }
        
        WorkoutSessionManagerStore.shared.discardWorkoutSession(uuid: uuid,
                                                                notifyPhone: false)
    }
    
    private func handleIgnoredPreparedWorkoutSession() {
        WorkoutSessionManagerStore.shared.discardUnstartedWorkoutSession()
    }
}

extension PhoneConnectionManager {
    func requestLibrary() {
        guard isActivated, isReachable else { return }
        session.sendMessage([PayloadKey.requestWorkoutLibrary: true], replyHandler: nil, errorHandler: nil)
    }

    private func scheduleEventRetry(_ eventID: UUID) {
        dispatchPrecondition(condition: .onQueue(connectivityQueue))
        guard WatchWorkoutStore.shared.pendingEvents().contains(where: { $0.id == eventID }) else { return }
        eventRetries.removeValue(forKey: eventID)?.cancel()
        let attempt = eventRetryAttempts[eventID, default: 0]
        eventRetryAttempts[eventID] = attempt + 1
        let delay = [15.0, 30, 60, 120, 300][min(attempt, 4)]
        let work = DispatchWorkItem { [weak self] in
            guard let self, WatchWorkoutStore.shared.pendingEvents().contains(where: { $0.id == eventID }) else { return }
            self.eventRetries.removeValue(forKey: eventID)
            self.eventTransferSent.remove(eventID)
            self.eventSendInFlight.remove(eventID)
            self.flushEventOutbox()
        }
        eventRetries[eventID] = work
        connectivityQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func requestCurrentSnapshotIfReady() {
        if let active = WatchWorkoutStore.shared.snapshot(),
           WatchWorkoutStore.shared.pendingEvents().contains(where: { $0.workoutID == active.workoutID }) { return }
        requestCurrentSnapshot()
    }

    func requestCurrentSnapshot() {
        guard isActivated, isReachable else { return }
        session.sendMessage([PayloadKey.requestWorkoutSnapshot: true], replyHandler: nil, errorHandler: nil)
    }

    func handlePrepareWorkoutSession(_ workoutConfiguration: HKWorkoutConfiguration) {
        os_log("Ensuring we have a workout session that keeps the app alive")
        WorkoutSessionManagerStore.shared.ensurePreparedWorkoutSession(configuration: workoutConfiguration) { [weak self] result in
            switch result {
            case .success:
                self?.sendPreparedWorkoutSession()
                self?.scheduleDiscardUnstartedWorkoutSessionSubject.send()
            case .failure(let error):
                os_log("Could not prepare workout session: %@", error.localizedDescription)
            }
        }
    }
}

// MARK: - Sending
extension PhoneConnectionManager {
    /// Live readings deliberately have no transferUserInfo fallback: replaying
    /// old heart rates after reconnecting would misrepresent them as current.
    func sendWorkoutMetrics(_ metrics: WatchWorkoutMetrics) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isActivated, isReachable,
              let data = WatchWorkoutWire.encode(metrics) else { return }
        session.sendMessage([PayloadKey.workoutMetrics: data], replyHandler: nil) { _ in }
    }

    private func sendCurrentWorkoutMetrics() {
        guard isActivated, isReachable else { return }
        WorkoutSessionManager.perform {
            WorkoutSessionManagerStore.shared.workoutSessionManager?.publishLiveMetrics()
        }
    }

    /// wrapper to send either via message or transfer, depending on what's available
    private func sendUserInfo(userInfo: [String : Any]) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.sendUserInfo(userInfo: userInfo) }
            return
        }
        guard isActivated else {
            // Activation is asynchronous. Keep the command bounded in memory
            // and flush it from activationDidComplete instead of recursively
            // scheduling an unbounded retry chain.
            queueUntilActivated(userInfo)
            return
        }
        if isReachable {
            os_log("Messaging userInfo=%@", type: .debug, userInfo)
            session.sendMessage(userInfo, replyHandler: nil) { error in
                os_log("Messaging not possible, falling back to transfering", type: .debug)
                self.session.transferUserInfo(userInfo)
            }
        } else {
            os_log("Transfering userInfo=%@", type: .debug, userInfo)
            session.transferUserInfo(userInfo)
        }
    }
    
    func sendPreparedWorkoutSession() {
        os_log("Sending prepared message")
        sendUserInfo(userInfo: [PayloadKey.preparedWorkoutSession : true])
    }

    /// Sends every local edit through transferUserInfo for durability and also
    /// sends an immediate message when reachable. The phone acknowledges by
    /// event ID; duplicate deliveries are therefore safe for the phone adapter.
    func flushEventOutbox() {
        connectivityQueue.async {
            self.pendingOutboxFlush?.cancel()
            let id = UUID()
            self.outboxFlushID = id
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.outboxFlushID == id else { return }
                self.pendingOutboxFlush = nil
                self.outboxFlushID = nil
                self.flushEventOutboxOnConnectivityQueue()
            }
            self.pendingOutboxFlush = work
            // A Crown burst shares one disk checkpoint and one drain request.
            self.connectivityQueue.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    private func flushEventOutboxOnConnectivityQueue() {
        dispatchPrecondition(condition: .onQueue(connectivityQueue))
        guard isActivated else { return }
        guard !outboxPersistenceInFlight else { outboxFlushRequested = true; return }
        outboxPersistenceInFlight = true
        WatchWorkoutStore.shared.flushPersistence { result in
            self.connectivityQueue.async {
                self.outboxPersistenceInFlight = false
                if case .success(let events) = result { self.sendDurableEvents(events) }
                // The store reports failed persistence on the main queue and
                // retains the checkpoint for a later edit/reconnect/retry.
                if self.outboxFlushRequested {
                    self.outboxFlushRequested = false
                    self.flushEventOutbox()
                }
            }
        }
    }

    private func sendDurableEvents(_ events: [WatchWorkoutEvent]) {
        dispatchPrecondition(condition: .onQueue(connectivityQueue))
        guard isActivated else { return }
        // Drain in sequence, waiting for each durable ACK. A later structural
        // edit must never overtake creation (or undo a newer set completion).
        // Duplicate deliveries from the fallback transport remain idempotent.
        for event in events.sorted(by: { $0.sequence < $1.sequence }).prefix(1) {
            guard WatchWorkoutStore.shared.pendingEvents().contains(where: { $0.id == event.id }) else { continue }
            if eventRetries[event.id] == nil { scheduleEventRetry(event.id) }
            guard !eventSendInFlight.contains(event.id),
                  let data = WatchWorkoutWire.encode(event) else { continue }

            if data.count > 48 * 1_024 {
                if !eventTransferSent.contains(event.id) {
                    do {
                        let url = FileManager.default.temporaryDirectory
                            .appendingPathComponent("light-watch-event-" + UUID().uuidString + ".json")
                        try data.write(to: url, options: .atomic)
                        eventFiles[url] = event.id
                        session.transferFile(url, metadata: ["ironWorkoutEvent": true])
                        eventTransferSent.insert(event.id)
                    } catch {
                        DispatchQueue.main.async { WorkoutSessionManagerStore.shared.reportPersistenceFailure(error) }
                    }
                }
                continue
            }
            let payload: [String: Any] = [PayloadKey.workoutEvent: data]
            if !eventTransferSent.contains(event.id) {
                session.transferUserInfo(payload)
                eventTransferSent.insert(event.id)
            }
            guard isReachable else { continue }

            eventSendInFlight.insert(event.id)
            session.sendMessage(payload, replyHandler: { [weak self] reply in
                self?.receive(message: reply)
            }, errorHandler: { [weak self] _ in
                // transferUserInfo above remains queued; allow a later
                // reachability/activation transition to try the fast path.
                self?.connectivityQueue.async {
                    self?.eventSendInFlight.remove(event.id)
                    self?.eventTransferSent.remove(event.id)
                }
            })
        }
    }
}
