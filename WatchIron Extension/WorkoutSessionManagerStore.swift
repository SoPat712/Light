//
//  WorkoutSessionManagerStore.swift
//  WatchIron Extension
//
//  Created by Karim Abou Zeid on 09.11.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import Foundation
import CryptoKit
import os.log
#if !os(watchOS)
// IronTests compiles the portable store against Iron's existing shared types.
@testable import Iron
#endif
#if os(watchOS)
import HealthKit
import Combine
import WatchKit
import WatchConnectivity
#endif

/// Durable watch-side projection and at-least-once event outbox. HealthKit
/// owns sensor samples; this store owns the workout the user is editing.
final class WatchWorkoutStore {
    static let shared = WatchWorkoutStore()
    static let libraryDidChange = Notification.Name("WatchWorkoutStore.libraryDidChange")
    static let persistenceDidFail = Notification.Name("WatchWorkoutStore.persistenceDidFail")
    enum SnapshotReceipt: Equatable { case rejected, unchanged, changed }

    private struct Checkpoint {
        let state: WatchWorkoutPersistedState
        let library: WatchWorkoutLibrary
        let libraryGeneration: UInt64
    }

    private let defaults: UserDefaults
    private let defaultsKey: String
    private let encode: (WatchWorkoutPersistedState) -> Data?
    // Readers only acquire this lock to retain an immutable value. In
    // particular, no encoder, event replay, notification or I/O runs under it.
    private let lock = NSLock()
    private var state: WatchWorkoutPersistedState
    private var cachedLibrary: WatchWorkoutLibrary
    private var cachedHistoryIndex: WatchWorkoutHistoryIndex
    private var cachedLibraryVersion: UInt64 = 0
    private let libraryURL: URL
    private let mutationQueue = DispatchQueue(label: "Light.watchStore.mutations", qos: .userInitiated)
    private let persistenceQueue = DispatchQueue(label: "Light.watchStore.persistence", qos: .utility)
    private let debounceInterval: TimeInterval

    // Mutation-queue owned. The base excludes unacknowledged library events;
    // replaying those once produces cachedLibrary, never in a reader's getter.
    private var baseLibrary: WatchWorkoutLibrary
    private var libraryGeneration: UInt64 = 0
    // Persistence-queue owned. A single writer gives checkpoints durable order.
    private var pendingCheckpoint: Checkpoint?
    private var pendingWrite: DispatchWorkItem?
    private var pendingWriteID: UUID?
    private var pendingWriteDeadline: DispatchTime?
    private var persistedLibraryGeneration: UInt64 = 0
    private var persistedLibrary: WatchWorkoutLibrary?
    private var persistedState: WatchWorkoutPersistedState?

    init(
        defaults: UserDefaults = .standard,
        defaultsKey: String = "watchWorkoutStore.v1",
        libraryURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchWorkoutLibrary.json"),
        debounceInterval: TimeInterval = 0.25,
        loadLibrarySynchronously: Bool = false,
        bundledLibrary: @escaping () -> WatchWorkoutLibrary = {
            #if os(watchOS)
            WatchBundledLibrary.load()
            #else
            WatchWorkoutLibrary(generatedAt: .distantPast, exercises: [], savedWorkouts: [], history: [], weightUnit: .kilogram)
            #endif
        },
        encode: @escaping (WatchWorkoutPersistedState) -> Data? = { WatchWorkoutWire.encode($0) }
    ) {
        self.libraryURL = libraryURL
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        self.debounceInterval = debounceInterval
        self.encode = encode
        let restored = defaults.data(forKey: defaultsKey)
            .flatMap { WatchWorkoutWire.decode(WatchWorkoutPersistedState.self, from: $0) }
        var restoredState = restored ?? WatchWorkoutPersistedState()
        if var snapshot = restoredState.snapshot, snapshot.isFinished == nil {
            // Older active projections could carry an editable end date. Only
            // a durable finish event makes an ambiguous legacy record terminal.
            snapshot.isFinished = restoredState.outbox.contains {
                $0.workoutID == snapshot.workoutID && $0.kind == .workoutFinished
            }
            restoredState.snapshot = snapshot
        }
        state = restoredState
        persistedState = restored
        let clock = defaults.dictionary(forKey: defaultsKey + ".libraryClock")
        let initialUnit = (clock?["weightUnit"] as? String).flatMap(WatchWorkoutWeightUnit.init(rawValue:))
            ?? restoredState.snapshot?.weightUnit
            ?? (Locale.current.measurementSystem == .us ? .pound : .kilogram)
        let initialBase = WatchWorkoutLibrary(generatedAt: .distantPast, exercises: [], savedWorkouts: [],
                                             history: [], weightUnit: initialUnit)
        baseLibrary = initialBase
        let initialLibrary = Self.applyingLibraryEvents(restoredState.outbox, to: initialBase)
        cachedLibrary = initialLibrary
        cachedHistoryIndex = WatchWorkoutHistoryIndex(history: initialLibrary.history)
        // The large JSON file and the bundled picker never load on the scene's
        // main-thread read path. Mutations/barriers queue behind hydration.
        // The synchronous option is for deterministic storage-only tests.
        if loadLibrarySynchronously { hydrateLibrary(bundledLibrary: bundledLibrary) }
        else { mutationQueue.async { self.hydrateLibrary(bundledLibrary: bundledLibrary) } }
    }

    private func hydrateLibrary(bundledLibrary: () -> WatchWorkoutLibrary) {
        let onDisk = (try? Data(contentsOf: libraryURL))
            .flatMap { WatchWorkoutWire.decode(WatchWorkoutLibrary.self, from: $0) }
        var base = (onDisk ?? bundledLibrary()).removingHistoryMedia()
        if onDisk != nil, let clock = defaults.dictionary(forKey: defaultsKey + ".libraryClock"),
           let generatedAt = clock["generatedAt"] as? Date, generatedAt >= base.generatedAt {
            base.generatedAt = generatedAt
            base.revision = (clock["revision"] as? NSNumber)?.int64Value ?? base.revision
        }
        baseLibrary = base
        // Initialization precedes every persistence job on the mutation queue.
        persistedLibrary = onDisk
        if let onDisk { cacheHistoryMedia(onDisk) }
        let pendingHistory = read { state.outbox }.filter { $0.kind == .workoutFinished }.compactMap(\.snapshot)
        if !pendingHistory.isEmpty {
            var pendingLibrary = base
            pendingLibrary.history = pendingHistory
            cacheHistoryMedia(pendingLibrary)
        }
        let library = Self.applyingLibraryEvents(read { state.outbox }, to: base)
        let index = WatchWorkoutHistoryIndex(history: library.history)
        lock.lock()
        cachedLibrary = library
        cachedHistoryIndex = index
        cachedLibraryVersion &+= 1
        lock.unlock()
        NotificationCenter.default.post(name: Self.libraryDidChange, object: self)
        if let onDisk, onDisk != onDisk.removingHistoryMedia() {
            libraryGeneration = 1
            schedulePersistence(checkpoint(), immediately: false)
        }
    }

    private func read<Value>(_ body: () -> Value) -> Value {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    private func checkpoint() -> Checkpoint {
        Checkpoint(state: read { state }, library: baseLibrary, libraryGeneration: libraryGeneration)
    }

    /// Mutation callers serialize without blocking readers. Publication happens
    /// before asynchronous persistence; failed checkpoints remain pending and
    /// are reported, and transport must flush before sending their events.
    private func commit<Result>(immediately: Bool = false,
                                _ mutation: (inout WatchWorkoutPersistedState) throws -> Result) rethrows -> Result {
        var candidate = read { state }
        let result = try mutation(&candidate)
        lock.lock()
        state = candidate
        lock.unlock()
        schedulePersistence(checkpoint(), immediately: immediately)
        return result
    }

    func snapshot() -> WatchWorkoutSnapshot? { read { state.snapshot } }
    func pendingEvents() -> [WatchWorkoutEvent] { read { state.outbox } }
    func library() -> WatchWorkoutLibrary { read { cachedLibrary } }
    func libraryPresentation() -> (library: WatchWorkoutLibrary, historyIndex: WatchWorkoutHistoryIndex, version: UInt64) {
        read { (cachedLibrary, cachedHistoryIndex, cachedLibraryVersion) }
    }

    /// Newer revisions win; duplicate transports advance the watermark without
    /// invalidating the UI. Even watermark-only updates are durably ordered.
    @discardableResult
    func replaceSnapshot(_ snapshot: WatchWorkoutSnapshot, fromPhone: Bool = false) throws -> SnapshotReceipt {
        mutationQueue.sync {
            let current = read { state }
            if current.terminalWorkoutIDs?.contains(snapshot.workoutID) == true,
               fromPhone || snapshot.isFinished != true { return .rejected }
            let acknowledged = fromPhone ? (current.acknowledgedSequences?[snapshot.workoutID.uuidString] ?? 0) : 0
            guard snapshot.canReplace(current.snapshot, acknowledgedSequence: acknowledged) else { return .rejected }
            let unchanged = current.snapshot.map(WatchSyncContent.workoutContent) == WatchSyncContent.workoutContent(snapshot)
            commit { $0.snapshot = snapshot }
            return unchanged ? .unchanged : .changed
        }
    }

    @discardableResult
    func commitEvent(
        snapshotChange: WatchWorkoutSnapshotChange,
        requiresImmediatePersistence: Bool = false,
        makeEvent: (Int64, WatchWorkoutSnapshot?) -> WatchWorkoutEvent
    ) throws -> WatchWorkoutEvent {
        try mutationQueue.sync {
            var candidate = read { state }
            guard candidate.nextSequence < Int64.max else { throw WatchWorkoutPersistenceError.sequenceOverflow }
            candidate.nextSequence += 1
            if case .replace(let snapshot) = snapshotChange { candidate.snapshot = snapshot }
            let event = makeEvent(candidate.nextSequence, candidate.snapshot)
            candidate.outbox.append(event)
            if event.kind == .workoutFinished || event.kind == .workoutDiscarded {
                WatchWorkoutPersistence.markTerminal(event.workoutID, in: &candidate)
            }
            let immediate = requiresImmediatePersistence ||
                [.workoutCreated, .setCompletionChanged, .workoutFinished, .workoutDiscarded,
                 .savedWorkoutUpserted, .savedWorkoutDeleted].contains(event.kind)
            if immediate {
                // Discrete Save/Log/Finish actions keep their durable success
                // boundary. Only the mutation/session queue waits; readers and
                // SwiftUI never wait for this encoder or its disk writes.
                try persistImmediately(candidate)
            }
            lock.lock()
            state = candidate
            lock.unlock()
            if Self.isLibraryEvent(event) { rebuildLibrary() }
            if !immediate { schedulePersistence(checkpoint(), immediately: false) }
            return event
        }
    }

    func acknowledge(eventIDs: [UUID]) throws {
        guard !eventIDs.isEmpty else { return }
        mutationQueue.sync {
            let ids = Set(eventIDs)
            let acknowledged = read { state.outbox }.filter { ids.contains($0.id) }
            guard !acknowledged.isEmpty else { return }
            if acknowledged.contains(where: Self.isLibraryEvent) {
                // Fold only ACKed events into the base. They were flushed before
                // transmission. Write this base BEFORE removing their outbox
                // copies, so a crash between files can only replay a duplicate.
                let next = Self.applyingLibraryEvents(acknowledged, to: baseLibrary)
                if !next.hasSameContent(as: baseLibrary) {
                    baseLibrary = next
                    libraryGeneration &+= 1
                }
            }
            commit(immediately: true) { WatchWorkoutPersistence.acknowledge(eventIDs: eventIDs, in: &$0) }
            if acknowledged.contains(where: Self.isLibraryEvent) { rebuildLibrary() }
        }
    }

    func clear() throws {
        mutationQueue.sync {
            let hadLibraryEvents = read { state.outbox }.contains(where: Self.isLibraryEvent)
            commit(immediately: true) {
                if let id = $0.snapshot?.workoutID { WatchWorkoutPersistence.markTerminal(id, in: &$0) }
                $0.snapshot = nil
                $0.outbox.removeAll()
            }
            if hadLibraryEvents { rebuildLibrary() }
        }
    }

    func clearSnapshot() throws {
        mutationQueue.sync {
            commit(immediately: true) {
                if let id = $0.snapshot?.workoutID { WatchWorkoutPersistence.markTerminal(id, in: &$0) }
                $0.snapshot = nil
            }
        }
    }

    func isTerminalWorkout(_ workoutID: UUID) -> Bool {
        read { state.terminalWorkoutIDs?.contains(workoutID) == true }
    }

    func shouldDiscardRecoveredWorkout(_ workoutID: UUID) -> Bool {
        read {
            let pending = state.outbox.filter { $0.workoutID == workoutID }
            if pending.contains(where: { $0.kind == .workoutDiscarded }) { return true }
            // A finished projection still owns finalization. An archived finish
            // or discard must never acquire a new editable recovery placeholder.
            if state.snapshot?.workoutID == workoutID, state.snapshot?.isFinished == true { return false }
            return state.terminalWorkoutIDs?.contains(workoutID) == true ||
                pending.contains(where: { $0.kind == .workoutFinished })
        }
    }

    func rememberTerminalWorkout(_ workoutID: UUID) {
        mutationQueue.sync {
            commit(immediately: true) { WatchWorkoutPersistence.markTerminal(workoutID, in: &$0) }
        }
    }

    /// Recovery has either found the saved Health workout or exhausted session
    /// recovery. Archive atomically with any failure receipt, keeping the finish
    /// outbox intact. Encoding failure leaves the finished projection retryable.
    @discardableResult
    func reconcileFinishedSnapshot(workoutID: UUID, healthWorkoutSaved: Bool,
                                   failureMessage: String = "Not saved to Apple Health. The workout is still saved in Light.",
                                   at date: Date = Date()) throws -> Bool {
        try mutationQueue.sync {
            var candidate = read { state }
            guard let snapshot = candidate.snapshot, snapshot.workoutID == workoutID,
                  snapshot.isFinished == true else { return false }
            if !healthWorkoutSaved, !snapshot.isHealthTestWorkout,
               !candidate.outbox.contains(where: { $0.workoutID == workoutID && $0.kind == .workoutFailed && $0.snapshot?.isFinishedRecord == true }) {
                guard candidate.nextSequence < Int64.max else { throw WatchWorkoutPersistenceError.sequenceOverflow }
                candidate.nextSequence += 1
                candidate.outbox.append(WatchWorkoutEvent(
                    workoutID: workoutID, sequence: candidate.nextSequence, kind: .workoutFailed,
                    startDate: snapshot.startDate, endDate: snapshot.endDate, title: failureMessage,
                    weightUnit: snapshot.weightUnit, snapshot: Self.compactSnapshot(snapshot),
                    fieldChanges: WatchWorkoutFieldChanges(), createdAt: date))
            }
            WatchWorkoutPersistence.markTerminal(workoutID, in: &candidate)
            candidate.snapshot = nil
            try persistImmediately(candidate)
            lock.lock()
            state = candidate
            lock.unlock()
            return true
        }
    }

    private func persistImmediately(_ candidate: WatchWorkoutPersistedState) throws {
        let checkpoint = Checkpoint(state: candidate, library: baseLibrary, libraryGeneration: libraryGeneration)
        try persistenceQueue.sync {
            try self.persistCheckpoint(checkpoint)
            self.pendingWrite?.cancel()
            self.pendingWrite = nil
            self.pendingWriteID = nil
            self.pendingWriteDeadline = nil
            self.pendingCheckpoint = nil
        }
    }

    static func compactSnapshot(_ snapshot: WatchWorkoutSnapshot) -> WatchWorkoutSnapshot {
        var copy = snapshot
        copy.library = nil
        for index in copy.exercises.indices {
            let exercise = copy.exercises[index]
            if exercise.imageData != nil {
                copy.exercises[index].imageURL = WatchWorkoutLibrary.historyMediaURL(for: exercise).absoluteString
            }
            copy.exercises[index].imageData = nil
        }
        return copy
    }

    func replaceLibrary(_ incoming: WatchWorkoutLibrary) throws {
        mutationQueue.sync {
            guard incoming.schemaVersion <= WatchWorkoutWire.schemaVersion,
                  incoming.generatedAt >= baseLibrary.generatedAt else { return }
            if let previous = baseLibrary.revision, let revision = incoming.revision, revision <= previous { return }
            cacheHistoryMedia(incoming)
            let compact = incoming.removingHistoryMedia()
            let changed = !compact.hasSameContent(as: baseLibrary)
            baseLibrary = compact
            if changed {
                libraryGeneration &+= 1
                rebuildLibrary()
            }
            schedulePersistence(checkpoint(), immediately: false)
        }
    }

    private static func isLibraryEvent(_ event: WatchWorkoutEvent) -> Bool {
        [.savedWorkoutUpserted, .savedWorkoutDeleted, .workoutFinished].contains(event.kind)
    }

    private static func applyingLibraryEvents(_ events: [WatchWorkoutEvent], to base: WatchWorkoutLibrary) -> WatchWorkoutLibrary {
        var library = base
        for event in events.filter(isLibraryEvent).sorted(by: { $0.sequence < $1.sequence }) {
            if event.kind == .savedWorkoutUpserted, let saved = event.savedWorkout {
                library.savedWorkouts.removeAll { $0.id == saved.id }
                library.savedWorkouts.append(saved)
            } else if event.kind == .savedWorkoutDeleted {
                library.savedWorkouts.removeAll { $0.id == event.workoutID }
            } else if event.kind == .workoutFinished, let snapshot = event.snapshot {
                library.history.removeAll { $0.workoutID == snapshot.workoutID }
                library.history.insert(snapshot, at: 0)
            }
        }
        library.history.sort { ($0.endDate ?? $0.startDate) > ($1.endDate ?? $1.startDate) }
        return library.removingHistoryMedia()
    }

    private func rebuildLibrary() {
        let next = Self.applyingLibraryEvents(read { state.outbox }, to: baseLibrary)
        guard !next.hasSameContent(as: read { cachedLibrary }) else { return }
        let index = WatchWorkoutHistoryIndex(history: next.history)
        lock.lock()
        cachedLibrary = next
        cachedHistoryIndex = index
        cachedLibraryVersion &+= 1
        lock.unlock()
        NotificationCenter.default.post(name: Self.libraryDidChange, object: self)
    }

    func cacheHistoryMedia(from snapshot: WatchWorkoutSnapshot) {
        let library = WatchWorkoutLibrary(generatedAt: snapshot.updatedAt, exercises: [], savedWorkouts: [],
            history: [snapshot], weightUnit: snapshot.weightUnit ?? .kilogram)
        cacheHistoryMedia(library)
    }

    private func cacheHistoryMedia(_ library: WatchWorkoutLibrary) {
        let media = library.historyMediaForCaching
        guard !media.isEmpty else { return }
        persistenceQueue.async {
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ExerciseMedia", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for entry in media {
                    let key = SHA256.hash(data: Data(entry.url.absoluteString.utf8))
                        .map { String(format: "%02x", $0) }.joined()
                    let url = directory.appendingPathComponent(key)
                    if !FileManager.default.fileExists(atPath: url.path) {
                        try entry.data.write(to: url, options: .atomic)
                    }
                }
            } catch {
                os_log("Could not cache historical exercise media: %@", type: .error, error.localizedDescription)
            }
        }
    }

    private func schedulePersistence(_ checkpoint: Checkpoint, immediately: Bool) {
        persistenceQueue.async {
            self.pendingCheckpoint = checkpoint
            self.pendingWrite?.cancel()
            let id = UUID()
            self.pendingWriteID = id
            let now = DispatchTime.now()
            let latestDeadline = self.pendingWriteDeadline ?? (now + max(1, self.debounceInterval))
            self.pendingWriteDeadline = latestDeadline
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.pendingWriteID == id else { return }
                self.pendingWrite = nil
                self.pendingWriteID = nil
                self.pendingWriteDeadline = nil
                do { try self.persistPendingCheckpoint() }
                catch {
                    NotificationCenter.default.post(name: Self.persistenceDidFail, object: self,
                                                    userInfo: ["error": error])
                }
            }
            self.pendingWrite = work
            // Continuous Crown travel must still checkpoint at least once a
            // second, rather than indefinitely postponing the trailing write.
            let deadline = immediately ? now : min(now + self.debounceInterval, latestDeadline)
            self.persistenceQueue.asyncAfter(deadline: deadline, execute: work)
        }
    }

    /// A transport barrier, also useful to test ordering without timers. It
    /// returns exactly the outbox whose complete checkpoint has been written.
    /// Completion runs on the persistence queue; callers hop to their own queue.
    func flushPersistence(completion: @escaping (Result<[WatchWorkoutEvent], Error>) -> Void) {
        mutationQueue.async {
            let checkpoint = self.checkpoint()
            self.persistenceQueue.async {
                self.pendingWrite?.cancel()
                self.pendingWrite = nil
                self.pendingWriteID = nil
                self.pendingWriteDeadline = nil
                self.pendingCheckpoint = checkpoint
                do {
                    try self.persistPendingCheckpoint()
                    completion(.success(checkpoint.state.outbox))
                } catch {
                    NotificationCenter.default.post(name: Self.persistenceDidFail, object: self,
                                                    userInfo: ["error": error])
                    completion(.failure(error))
                }
            }
        }
    }

    private func persistPendingCheckpoint() throws {
        guard let checkpoint = pendingCheckpoint else { return }
        try persistCheckpoint(checkpoint)
        pendingCheckpoint = nil
    }

    private func persistCheckpoint(_ checkpoint: Checkpoint) throws {
        // Encode before doing any I/O. A failed encoding never drops a durable
        // event; a failed library write never advances the ACK checkpoint.
        let stateChanged = persistedState != checkpoint.state
        let data: Data?
        if stateChanged {
            guard let encoded = encode(checkpoint.state) else { throw WatchWorkoutPersistenceError.encodingFailed }
            data = encoded
        } else { data = nil }
        if persistedLibraryGeneration != checkpoint.libraryGeneration {
            if persistedLibrary?.hasSameContent(as: checkpoint.library) != true {
                guard let data = WatchWorkoutWire.encode(checkpoint.library) else { throw WatchWorkoutPersistenceError.encodingFailed }
                try FileManager.default.createDirectory(at: libraryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: libraryURL, options: .atomic)
                persistedLibrary = checkpoint.library
            }
            persistedLibraryGeneration = checkpoint.libraryGeneration
        }
        var clock: [String: Any] = ["generatedAt": checkpoint.library.generatedAt,
                                    "weightUnit": checkpoint.library.weightUnit.rawValue]
        if let revision = checkpoint.library.revision { clock["revision"] = NSNumber(value: revision) }
        if !NSDictionary(dictionary: clock).isEqual(to: defaults.dictionary(forKey: defaultsKey + ".libraryClock") ?? [:]) {
            defaults.set(clock, forKey: defaultsKey + ".libraryClock")
        }
        if let data {
            defaults.set(data, forKey: defaultsKey)
            persistedState = checkpoint.state
        }
    }
}

/// Built once with each library projection, off the reader lock. Selecting the
/// prior exercise for an active workout happens once per workout/date, and set
/// rows then use two dictionary lookups instead of filtering/sorting history.
struct WatchWorkoutHistoryIndex {
    struct Entry {
        let workoutID: UUID
        let startDate: Date
        let weightUnit: WatchWorkoutWeightUnit?
        let exercise: WatchWorkoutExercise
        let completedSets: [Int: WatchWorkoutSet]
    }

    private var entries: [UUID: [Entry]] = [:]

    init(history: [WatchWorkoutSnapshot]) {
        for workout in history.sorted(by: { $0.startDate > $1.startDate }) {
            var seen = Set<UUID>()
            for exercise in workout.exercises {
                guard let id = exercise.exerciseUuid, seen.insert(id).inserted else { continue }
                var sets: [Int: WatchWorkoutSet] = [:]
                for set in exercise.sets where set.completed && sets[set.order] == nil { sets[set.order] = set }
                entries[id, default: []].append(Entry(workoutID: workout.workoutID,
                    startDate: workout.startDate, weightUnit: workout.weightUnit,
                    exercise: exercise, completedSets: sets))
            }
        }
    }

    func previousExercises(for snapshot: WatchWorkoutSnapshot) -> [UUID: Entry] {
        var result: [UUID: Entry] = [:]
        for (id, history) in entries {
            var lower = 0
            var upper = history.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if history[middle].startDate >= snapshot.startDate { lower = middle + 1 }
                else { upper = middle }
            }
            while lower < history.count, history[lower].workoutID == snapshot.workoutID { lower += 1 }
            if lower < history.count { result[id] = history[lower] }
        }
        return result
    }
}

#if os(watchOS)
class WorkoutSessionManagerStore: ObservableObject {
    static let shared = WorkoutSessionManagerStore()

    struct PersistenceFailure: Identifiable, Equatable {
        let id = UUID()
        let message: String
    }
    
    let objectWillChange = ObservableObjectPublisher()
    private var automaticRecordingAttemptedFor: UUID?
    private var finishedRecoveryLookupID: UUID?
    private var restExpiry: DispatchWorkItem?
    private var lastRestAlertEnd: Date?

    private func syncTrackingPreferences() {
        // Local editor compatibility only. The connection manager is the sole
        // preference sender; receive/apply paths never call this method.
        PhoneConnectionManager.shared.syncPreferences()
    }

    private(set) var recordingError: String? {
        didSet { DispatchQueue.main.async { self.objectWillChange.send() } }
    }
    private(set) var isRecoveringRecording = true {
        didSet { DispatchQueue.main.async { self.objectWillChange.send() } }
    }
    private(set) var isStartingRecording = false {
        didSet { DispatchQueue.main.async { self.objectWillChange.send() } }
    }

    /// Main-thread presentation value. SwiftUI never enters the durable store
    /// or its lock when reading this property from a body.
    @Published private(set) var library: WatchWorkoutLibrary
    private var historyIndex: WatchWorkoutHistoryIndex
    private var presentedLibraryVersion: UInt64
    private var previousHistoryContext: (workoutID: UUID, startDate: Date)?
    private var previousExercises: [UUID: WatchWorkoutHistoryIndex.Entry] = [:]
    private var libraryObserver: AnyCancellable?
    private var persistenceObserver: AnyCancellable?

    init() {
        let cached = WatchWorkoutStore.shared.libraryPresentation()
        library = cached.library
        historyIndex = cached.historyIndex
        presentedLibraryVersion = cached.version
        libraryObserver = NotificationCenter.default.publisher(for: WatchWorkoutStore.libraryDidChange,
            object: WatchWorkoutStore.shared)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshLibraryPresentation() }
        persistenceObserver = NotificationCenter.default.publisher(for: WatchWorkoutStore.persistenceDidFail,
            object: WatchWorkoutStore.shared)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                if let error = notification.userInfo?["error"] as? Error { self?.recordPersistenceFailure(error) }
            }
        // Covers a library mutation between the initial read and subscription.
        DispatchQueue.main.async { self.refreshLibraryPresentation() }
    }

    private func refreshLibraryPresentation() {
        dispatchPrecondition(condition: .onQueue(.main))
        let cached = WatchWorkoutStore.shared.libraryPresentation()
        guard presentedLibraryVersion != cached.version else { return }
        objectWillChange.send()
        presentedLibraryVersion = cached.version
        historyIndex = cached.historyIndex
        previousHistoryContext = nil
        library = cached.library
    }

    /// O(1) per row after selecting the prior exercises for this workout/date.
    /// UI callers can use this directly without passing or scanning history.
    @MainActor
    func previousSetText(set: WatchWorkoutSet, exercise: WatchWorkoutExercise,
                         snapshot: WatchWorkoutSnapshot? = nil, includesRPE: Bool = true) -> String? {
        guard let snapshot = snapshot ?? workoutSnapshot else { return nil }
        if previousHistoryContext?.workoutID != snapshot.workoutID || previousHistoryContext?.startDate != snapshot.startDate {
            previousExercises = historyIndex.previousExercises(for: snapshot)
            previousHistoryContext = (snapshot.workoutID, snapshot.startDate)
        }
        let entry = exercise.exerciseUuid.flatMap { previousExercises[$0] }
        var previous = entry?.completedSets[set.order]
        let targetUnit = snapshot.weightUnit ?? .kilogram
        if let from = entry?.weightUnit, from != targetUnit {
            let weight = previous?.weight
            previous?.weight = weight.map { $0 * (targetUnit == .pound ? 2.2046226218487757 : 1 / 2.2046226218487757) }
        }
        let weight = set.previousWeight ?? previous?.weight
        let reps = set.previousReps ?? previous?.reps
        guard weight != nil || reps != nil || previous?.duration != nil || previous?.distance != nil else { return nil }
        let prior = WatchWorkoutSet(order: 1, weight: weight, reps: reps, completed: true,
                                   duration: previous?.duration, distance: previous?.distance)
        let type = previous.flatMap { entry?.exercise.effectiveTrackingType(for: $0) } ?? exercise.effectiveTrackingType
        var text = prior.displayText(weightUnit: snapshot.weightUnit ?? .kilogram, trackingType: type)
        guard text != "—" else { return nil }
        if includesRPE, let previous, let rpe = previous.rpe, previous.weight == weight, previous.reps == reps {
            text += " · RPE " + WatchNumber.format(rpe)
        }
        return text
    }

    var preferredWeightUnit: WatchWorkoutWeightUnit {
        UserDefaults.standard.string(forKey: "watch.preferredWeightUnit")
            .flatMap(WatchWorkoutWeightUnit.init(rawValue:)) ?? WatchWorkoutStore.shared.library().weightUnit
    }

    var isHealthTestWorkout: Bool {
        #if DEBUG
        workoutSnapshot?.isHealthTestWorkout == true ||
            (workoutSessionManager?.healthTestMode == true && workoutSessionManager?.uuid != nil)
        #else
        false
        #endif
    }

    #if DEBUG
    private static let retiredTestWorkoutKey = "watch.retiredHealthTestWorkoutDuringRecovery"

    private func preserveTestIdentityDuringRecovery(_ snapshot: WatchWorkoutSnapshot?) {
        if isRecoveringRecording, let snapshot, snapshot.isHealthTestWorkout {
            // Finish/Discard may archive the snapshot before HealthKit returns
            // an older build's session. Retain its identity across another exit.
            UserDefaults.standard.set(snapshot.workoutID.uuidString, forKey: Self.retiredTestWorkoutKey)
        }
    }

    /// Keep the last phone preference for workouts started without the phone.
    /// Once a workout becomes local-only, never re-enable HealthKit for it.
    func setHealthTestMode(_ enabled: Bool, persistPreference: Bool = true) {
        WorkoutSessionManager.perform {
            self.setHealthTestModeOnAccessQueue(enabled, persistPreference: persistPreference)
        }
    }

    private func setHealthTestModeOnAccessQueue(_ enabled: Bool, persistPreference: Bool) {
        dispatchPrecondition(condition: .onQueue(WorkoutSessionManager.accessQueue))
        let preferenceChanged = persistPreference && UserDefaults.standard.healthTestMode != enabled
        let needsProvenance = enabled && workoutSnapshot.map {
            (!$0.isFinishedRecord || !persistPreference) && !$0.isHealthTestWorkout
        } == true
        let useLocalWorkout = isHealthTestWorkout || (enabled && workoutSnapshot?.isFinishedRecord != true)
        let needsManagerChange = useLocalWorkout && workoutSessionManager?.healthTestMode == false
        guard preferenceChanged || needsProvenance || needsManagerChange else { return }
        if persistPreference, UserDefaults.standard.healthTestMode != enabled {
            UserDefaults.standard.healthTestMode = enabled
        }
        if enabled, var snapshot = workoutSnapshot, (!snapshot.isFinishedRecord || !persistPreference),
           !snapshot.isHealthTestWorkout {
            snapshot.healthTestMode = true
            snapshot.healthTestWorkoutPaused = workoutSessionManager?.state == .paused
            snapshot.activeEnergyKilocalories = nil
            if advanceRevision(&snapshot) {
                snapshot.updatedAt = Date()
                persistSnapshot(snapshot)
            }
        }
        // A preference for future tests must not cancel a normal workout that
        // was already finished and is only awaiting its HealthKit save.
        workoutSessionManager?.setHealthTestMode(useLocalWorkout)
        if isHealthTestWorkout {
            isStartingRecording = false
            recordingError = nil
            ensureAutomaticRecording()
        }
        notifySyncStateChanged()
    }

    /// Rehydrates the manager facade from durable app data, without HealthKit.
    private func restoreLocalWorkout(_ snapshot: WatchWorkoutSnapshot) {
        dispatchPrecondition(condition: .onQueue(WorkoutSessionManager.accessQueue))
        if let manager = workoutSessionManager,
           manager.uuid != nil, manager.uuid != snapshot.workoutID,
           manager.state == .running || manager.state == .paused || manager.isFinalizingWorkout {
            recordingError = "Another Watch recording is still running. Finish it before starting this workout."
            return
        }
        if let manager = workoutSessionManager,
           manager.state == .running || manager.state == .paused {
            manager.setHealthTestMode(true)
        } else {
            workoutSessionManager?.discard()
            workoutSessionManager = WorkoutSessionManager(localWorkoutID: snapshot.workoutID,
                start: snapshot.startDate, state: snapshot.healthTestWorkoutPaused == true ? .paused : .running)
            WatchFeedback.play(.start)
        }
        if let manager = workoutSessionManager {
            // Recovered metadata can be absent even though the snapshot is durable.
            if manager.uuid == nil { try? manager.setUuid(snapshot.workoutID) }
            if manager.startDate != snapshot.startDate { manager.updateStartDate(snapshot.startDate) }
            if manager.endDate != snapshot.endDate { manager.updateEndDate(snapshot.endDate) }
            manager.selectedSetText = snapshot.selectedSetText
            applyLocalRest(snapshot)
            manager.publishLiveMetrics()
        }
        automaticRecordingAttemptedFor = snapshot.workoutID
        isStartingRecording = false
        recordingError = nil
        notifySyncStateChanged()
    }
    #endif

    func finishRecordingRecovery() {
        WorkoutSessionManager.perform {
            self.isRecoveringRecording = false
            #if DEBUG
            UserDefaults.standard.removeObject(forKey: Self.retiredTestWorkoutKey)
            #endif
            if let snapshot = self.workoutSnapshot { self.applyLocalRest(snapshot) }
            self.reconcileFinishedWorkoutAfterRecovery()
            self.ensureAutomaticRecording()
        }
    }

    private func reconcileFinishedWorkoutAfterRecovery() {
        dispatchPrecondition(condition: .onQueue(WorkoutSessionManager.accessQueue))
        guard !isRecoveringRecording, let snapshot = workoutSnapshot, snapshot.isFinishedRecord else { return }
        let manager = workoutSessionManager
        let canResume = manager.map { $0.state == .running || $0.state == .paused || $0.state == .stopped } ?? false
        switch WatchWorkoutFinalization.recoveryAction(snapshot: snapshot, recordingWorkoutID: manager?.uuid,
                                                       isFinalizing: manager?.isFinalizingWorkout ?? false,
                                                       canResume: canResume) {
        case .none, .waitForSave:
            return
        case .resume:
            endWorkoutSession(start: snapshot.startDate, end: snapshot.endDate ?? snapshot.updatedAt,
                              title: snapshot.title, uuid: snapshot.workoutID,
                              sessionEffort: snapshot.sessionEffort, notifyPhone: false)
        case .verifySavedWorkout:
            if snapshot.isHealthTestWorkout {
                completeFinishedRecovery(workoutID: snapshot.workoutID, healthWorkoutSaved: true)
                return
            }
            guard finishedRecoveryLookupID != snapshot.workoutID else { return }
            finishedRecoveryLookupID = snapshot.workoutID
            // A crash may happen after HealthKit saved but before archiving.
            // Check this app's external identity before requesting phone fallback.
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID,
                                            allowedValues: [snapshot.workoutID.uuidString]),
                HKQuery.predicateForObjects(from: .default())
            ])
            let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: 1,
                                      sortDescriptors: nil) { _, samples, error in
                WorkoutSessionManager.perform {
                    guard self.finishedRecoveryLookupID == snapshot.workoutID else { return }
                    self.finishedRecoveryLookupID = nil
                    self.completeFinishedRecovery(workoutID: snapshot.workoutID,
                        healthWorkoutSaved: samples?.isEmpty == false,
                        failureMessage: error?.localizedDescription)
                }
            }
            WorkoutSessionManager.healthStore.execute(query)
        }
    }

    private func completeFinishedRecovery(workoutID: UUID, healthWorkoutSaved: Bool,
                                          failureMessage: String? = nil) {
        dispatchPrecondition(condition: .onQueue(WorkoutSessionManager.accessQueue))
        guard workoutSnapshot?.workoutID == workoutID, workoutSnapshot?.isFinishedRecord == true else { return }
        if let manager = workoutSessionManager, manager.uuid == workoutID,
           manager.isFinalizingWorkout { return }
        do {
            guard try WatchWorkoutStore.shared.reconcileFinishedSnapshot(workoutID: workoutID,
                healthWorkoutSaved: healthWorkoutSaved,
                failureMessage: failureMessage ?? "Not saved to Apple Health. The workout is still saved in Light.") else { return }
            if let manager = workoutSessionManager, manager.uuid == workoutID { workoutSessionManager = nil }
            publishSnapshot(nil)
            if let manager = workoutSessionManager, let recoveredID = manager.uuid, recoveredID != workoutID,
               manager.state == .running || manager.state == .paused || manager.state == .stopped {
                // A different recovered recording still needs an editable
                // projection after the older finished workout is archived.
                if WatchWorkoutStore.shared.shouldDiscardRecoveredWorkout(recoveredID) {
                    manager.discard()
                    workoutSessionManager = nil
                } else {
                    persistSnapshot(.placeholder(workoutID: recoveredID, startDate: manager.startDate ?? Date()))
                }
            }
            recordingError = healthWorkoutSaved ? nil : (failureMessage ?? "Not saved to Apple Health. The workout is still saved in Light.")
            DispatchQueue.main.async {
                PhoneConnectionManager.shared.flushEventOutbox()
                PhoneConnectionManager.shared.requestCurrentSnapshotIfReady()
            }
        } catch { recordPersistenceFailure(error) }
    }

    func applyLibrary(_ library: WatchWorkoutLibrary) {
        WorkoutSessionManager.perform {
            do {
                try WatchWorkoutStore.shared.replaceLibrary(library)
            } catch { self.recordPersistenceFailure(error) }
        }
    }

    private(set) var persistenceFailure: PersistenceFailure? {
        didSet {
            DispatchQueue.main.async { self.objectWillChange.send() }
        }
    }

    func clearRecordingError() {
        WorkoutSessionManager.perform { self.recordingError = nil }
    }

    func clearPersistenceFailure() {
        DispatchQueue.main.async { self.persistenceFailure = nil }
    }

    func reportPersistenceFailure(_ error: Error) {
        recordPersistenceFailure(error)
    }

    private func recordPersistenceFailure(_ error: Error) {
        os_log("Could not persist watch workout change: %@", type: .error, error.localizedDescription)
        DispatchQueue.main.async {
            self.persistenceFailure = PersistenceFailure(message: error.localizedDescription)
        }
    }

    private func advanceRevision(_ snapshot: inout WatchWorkoutSnapshot) -> Bool {
        do {
            try WatchWorkoutPersistence.incrementRevision(&snapshot)
            return true
        } catch {
            recordPersistenceFailure(error)
            return false
        }
    }
    
    private var _workoutSessionManager: WorkoutSessionManager? {
        didSet { // don't use willSet, somehow this is sometimes to early in this case
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        }
    }
    
    var workoutSessionManager: WorkoutSessionManager? {
        get {
            return _workoutSessionManager
        }
        set {
            dispatchPrecondition(condition: DispatchPredicate.onQueue(WorkoutSessionManager.accessQueue))
            _workoutSessionManager = newValue
            // A start callback for a cleared manager is dropped by its identity
            // guard, so clearing must also release the in-flight start latch.
            if newValue == nil { isStartingRecording = false }
        }
    }

    private var _workoutSnapshot: WatchWorkoutSnapshot? = WatchWorkoutStore.shared.snapshot() {
        didSet {
            guard oldValue.map(WatchSyncContent.workoutContent) != _workoutSnapshot.map(WatchSyncContent.workoutContent) else { return }
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        }
    }

    var workoutSnapshot: WatchWorkoutSnapshot? {
        _workoutSnapshot
    }

    private func targetsCurrentWorkout(_ uuid: UUID) -> Bool {
        dispatchPrecondition(condition: .onQueue(WorkoutSessionManager.accessQueue))
        return (workoutSnapshot?.workoutID == uuid || workoutSessionManager?.uuid == uuid) &&
            (workoutSnapshot == nil || workoutSnapshot?.workoutID == uuid) &&
            (workoutSessionManager?.uuid == nil || workoutSessionManager?.uuid == uuid)
    }

    private func publishSnapshot(_ snapshot: WatchWorkoutSnapshot?) {
        _workoutSnapshot = snapshot
        if let snapshot, let manager = workoutSessionManager, manager.uuid == snapshot.workoutID {
            manager.selectedSetText = snapshot.trackedSelectedSetText ?? snapshot.selectedSetText
        }
        NotificationManager.shared.syncRestNotification(snapshot)
    }

    /// Refreshes UI that derives its state from the durable event outbox.
    /// The outbox intentionally lives outside the published snapshot so it
    /// survives archiving a finished workout.
    func notifySyncStateChanged() {
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
        refreshRecordingDiagnostic()
    }

    /// A read-only support snapshot for development builds. This never starts,
    /// stops or changes a HealthKit session, and contains no workout notes.
    func refreshRecordingDiagnostic() {
        #if DEBUG && !targetEnvironment(simulator)
        WorkoutSessionManager.perform {
            let manager = self.workoutSessionManager
            var state: [String: Any] = [
                "capturedAt": Date().timeIntervalSince1970,
                "recovering": self.isRecoveringRecording,
                "starting": self.isStartingRecording,
                "hasSnapshot": self.workoutSnapshot != nil,
                "isFinished": self.workoutSnapshot?.isFinishedRecord ?? false
            ]
            state["workoutID"] = self.workoutSnapshot?.workoutID.uuidString
            state["sessionWorkoutID"] = manager?.uuid?.uuidString
            state["sessionState"] = manager?.state.name
            state["recordingError"] = self.recordingError
            state["heartRate"] = manager?.mostRecentHeartRate
            state["heartRateDate"] = manager?.mostRecentHeartRateDate?.timeIntervalSince1970
            state["activeEnergyKilocalories"] = manager?.burnedCalories
            state["healthTestMode"] = self.isHealthTestWorkout
            guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
                  let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return }
            try? data.write(to: directory.appendingPathComponent("LightRecordingState.json"), options: .atomic)
        }
        #endif
    }

    @discardableResult
    private func archiveSnapshot(workoutID: UUID) -> Bool {
        guard self.workoutSnapshot?.workoutID == workoutID else { return true }
        #if DEBUG
        preserveTestIdentityDuringRecovery(workoutSnapshot)
        #endif
        do {
            try WatchWorkoutStore.shared.clearSnapshot()
            publishSnapshot(nil)
            return true
        } catch {
            recordPersistenceFailure(error)
            return false
        }
    }

    @discardableResult
    private func persistSnapshot(_ snapshot: WatchWorkoutSnapshot) -> Bool {
        do {
            switch try WatchWorkoutStore.shared.replaceSnapshot(snapshot) {
            case .rejected: return false
            case .unchanged:
                _workoutSnapshot = snapshot
                return true
            case .changed:
                publishSnapshot(snapshot)
                return true
            }
        } catch {
            recordPersistenceFailure(error)
            return false
        }
    }

    @discardableResult
    private func commitEvent(
        snapshotChange: WatchWorkoutSnapshotChange = .keep,
        workoutID: UUID,
        kind: WatchWorkoutEventKind,
        exerciseID: UUID? = nil,
        setID: UUID? = nil,
        weight: Double? = nil,
        reps: Int? = nil,
        rpe: Double? = nil,
        completed: Bool? = nil,
        restTimerEnd: Date? = nil,
        keepRestTimerRunning: Bool? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        title: String? = nil,
        sessionEffort: Double? = nil,
        eventSnapshot: WatchWorkoutSnapshot? = nil,
        tag: String? = nil,
        catalogExerciseUuid: UUID? = nil,
        afterExerciseID: UUID? = nil,
        savedWorkout: WatchSavedWorkout? = nil,
        removedExerciseIDs: [UUID]? = nil, removedSetIDs: [UUID]? = nil,
        fieldChanges: WatchWorkoutFieldChanges? = WatchWorkoutFieldChanges(),
        requiresImmediatePersistence: Bool = false
    ) -> Bool {
        #if DEBUG
        if case .replace(nil) = snapshotChange {
            preserveTestIdentityDuringRecovery(workoutSnapshot)
        }
        #endif
        do {
            if kind == .workoutFinished, let history = eventSnapshot ?? workoutSnapshot {
                // Preserve bundled stills before the compact finish enters the
                // outbox. This job precedes the durable terminal checkpoint on
                // the same writer queue, so history can immediately use it.
                WatchWorkoutStore.shared.cacheHistoryMedia(from: history)
            }
            _ = try WatchWorkoutStore.shared.commitEvent(
                snapshotChange: snapshotChange,
                requiresImmediatePersistence: requiresImmediatePersistence
            ) { sequence, persistedSnapshot in
                self.makeEvent(
                    sequence: sequence,
                    weightUnit: persistedSnapshot?.weightUnit,
                    workoutID: workoutID,
                    kind: kind,
                    exerciseID: exerciseID,
                    setID: setID,
                    weight: weight,
                    reps: reps,
                    rpe: rpe,
                    completed: completed,
                    restTimerEnd: restTimerEnd,
                    keepRestTimerRunning: keepRestTimerRunning,
                    startDate: startDate,
                    endDate: endDate,
                    title: title,
                    sessionEffort: sessionEffort,
                    snapshot: (eventSnapshot ?? ([.savedWorkoutUpserted, .savedWorkoutDeleted].contains(kind) ? nil : persistedSnapshot)).map(WatchWorkoutStore.compactSnapshot),
                    tag: tag,
                    catalogExerciseUuid: catalogExerciseUuid,
                    afterExerciseID: afterExerciseID,
                    savedWorkout: savedWorkout,
                    removedExerciseIDs: removedExerciseIDs, removedSetIDs: removedSetIDs,
                    fieldChanges: fieldChanges
                )
            }
            if case .replace(let snapshot) = snapshotChange {
                publishSnapshot(snapshot)
            }
            DispatchQueue.main.async {
                PhoneConnectionManager.shared.flushEventOutbox()
            }
            return true
        } catch {
            recordPersistenceFailure(error)
            return false
        }
    }

    private func makeEvent(sequence: Int64, weightUnit: WatchWorkoutWeightUnit?,
                           workoutID: UUID, kind: WatchWorkoutEventKind,
                           exerciseID: UUID? = nil, setID: UUID? = nil,
                           weight: Double? = nil, reps: Int? = nil,
                           rpe: Double? = nil, completed: Bool? = nil,
                           restTimerEnd: Date? = nil,
                           keepRestTimerRunning: Bool? = nil,
                           startDate: Date? = nil, endDate: Date? = nil,
                           title: String? = nil,
                           sessionEffort: Double? = nil,
                           snapshot: WatchWorkoutSnapshot? = nil,
                           tag: String? = nil,
                           catalogExerciseUuid: UUID? = nil,
                           afterExerciseID: UUID? = nil,
                           savedWorkout: WatchSavedWorkout? = nil,
                           removedExerciseIDs: [UUID]? = nil, removedSetIDs: [UUID]? = nil,
                           fieldChanges: WatchWorkoutFieldChanges? = WatchWorkoutFieldChanges()) -> WatchWorkoutEvent {
        WatchWorkoutEvent(workoutID: workoutID,
                          sequence: sequence,
                          kind: kind, exerciseID: exerciseID, setID: setID,
                          weight: weight, reps: reps, rpe: rpe,
                          completed: completed, restTimerEnd: restTimerEnd,
                          keepRestTimerRunning: keepRestTimerRunning,
                          startDate: startDate, endDate: endDate, title: title,
                          weightUnit: weightUnit,
                          sessionEffort: sessionEffort,
                          snapshot: snapshot,
                          tag: tag,
                          catalogExerciseUuid: catalogExerciseUuid,
                          afterExerciseID: afterExerciseID,
                          savedWorkout: savedWorkout,
                          removedExerciseIDs: removedExerciseIDs, removedSetIDs: removedSetIDs,
                          fieldChanges: fieldChanges)
    }

}

extension WorkoutSessionManagerStore {
    func applyWorkoutSnapshot(_ snapshot: WatchWorkoutSnapshot, healthTestModePreference: Bool? = nil) {
        WorkoutSessionManager.perform {
            guard snapshot.schemaVersion <= WatchWorkoutWire.schemaVersion else {
                os_log("Ignoring unsupported workout snapshot version=%d", type: .error, snapshot.schemaVersion)
                return
            }
            if let manager = self.workoutSessionManager, manager.isFinalizingWorkout, manager.uuid != snapshot.workoutID { return }
            let pending = WatchWorkoutStore.shared.pendingEvents().filter { $0.workoutID == snapshot.workoutID }
            guard !pending.contains(where: { $0.kind == .workoutFinished || $0.kind == .workoutDiscarded }) else { return }
            if let current = self.workoutSnapshot, !current.isFinishedRecord {
                guard current.workoutID == snapshot.workoutID, pending.isEmpty else { return }
            }
            let explicitUnit = UserDefaults.standard.string(forKey: "watch.preferredWeightUnit")
                .flatMap(WatchWorkoutWeightUnit.init(rawValue:))
            var snapshot = WatchWorkoutEditing.converting(snapshot, to: explicitUnit ?? snapshot.weightUnit ?? self.preferredWeightUnit)
            // Legacy phone snapshots on this path describe the current workout;
            // terminal intent arrives through the explicit finish/discard path.
            if snapshot.isFinished == nil { snapshot.isFinished = false }
            snapshot.selectedSetText = snapshot.trackedSelectedSetText ?? snapshot.selectedSetText
            if let current = self.workoutSnapshot, current.workoutID == snapshot.workoutID {
                if current.startedOnWatch == true { snapshot.startedOnWatch = true }
                snapshot.healthTestMode = snapshot.isHealthTestWorkout || current.isHealthTestWorkout
                // A compact live message can precede the full artwork file.
                let previous = Dictionary(uniqueKeysWithValues: current.exercises.map { ($0.id, $0) })
                for index in snapshot.exercises.indices where snapshot.exercises[index].imageData == nil {
                    let exercise = snapshot.exercises[index]
                    if let old = previous[exercise.id], old.exerciseUuid == exercise.exerciseUuid {
                        snapshot.exercises[index].imageData = old.imageData
                    }
                }
            }
            #if DEBUG
            snapshot.healthTestMode = snapshot.isHealthTestWorkout || healthTestModePreference == true
            // A newer phone projection must not erase test provenance already
            // persisted on the Watch, including after a preference change.
            if self.workoutSnapshot?.workoutID == snapshot.workoutID,
               self.isHealthTestWorkout {
                snapshot.healthTestMode = true
                snapshot.healthTestWorkoutPaused = self.workoutSnapshot?.healthTestWorkoutPaused
            }
            if snapshot.isHealthTestWorkout {
                snapshot.activeEnergyKilocalories = nil
                if let manager = self.workoutSessionManager, manager.uuid == snapshot.workoutID {
                    snapshot.healthTestWorkoutPaused = snapshot.healthTestWorkoutPaused ?? (manager.state == .paused)
                }
            }
            #endif
            let receipt: WatchWorkoutStore.SnapshotReceipt
            do {
                receipt = try WatchWorkoutStore.shared.replaceSnapshot(snapshot, fromPhone: true)
            } catch {
                self.recordPersistenceFailure(error)
                return
            }
            guard receipt != .rejected else { return }
            #if DEBUG
            // Preference bundled with a stale/different workout must not alter
            // the current workout before the projection passes validation.
            if let healthTestModePreference, UserDefaults.standard.healthTestMode != healthTestModePreference {
                UserDefaults.standard.healthTestMode = healthTestModePreference
            }
            #endif
            if receipt == .unchanged {
                self._workoutSnapshot = snapshot
                self.reconcileFinishedWorkoutAfterRecovery()
                if self.workoutSessionManager == nil { self.ensureAutomaticRecording() }
                return
            }
            self.publishSnapshot(snapshot)
            self.applyLocalRest(snapshot)

            if let manager = self.workoutSessionManager,
               manager.uuid == snapshot.workoutID {
                #if DEBUG
                manager.setHealthTestMode(snapshot.isHealthTestWorkout)
                #endif
                if manager.startDate != snapshot.startDate { manager.updateStartDate(snapshot.startDate) }
                if manager.endDate != snapshot.endDate { manager.updateEndDate(snapshot.endDate) }
                manager.restTimerEnd = snapshot.restTimerEnd
                manager.keepRestTimerRunning = snapshot.keepRestTimerRunning
                manager.selectedSetText = snapshot.selectedSetText
            }
            self.reconcileFinishedWorkoutAfterRecovery()
            self.ensureAutomaticRecording()
        }
    }

    func updateSet(workoutID: UUID, exerciseID: UUID, setID: UUID,
                   weight: Double?, reps: Int?, rpe: Double?) {
        WorkoutSessionManager.perform {
            guard var snapshot = self.workoutSnapshot,
                  snapshot.workoutID == workoutID,
                  let exerciseIndex = snapshot.exercises.firstIndex(where: { $0.id == exerciseID }),
                  let setIndex = snapshot.exercises[exerciseIndex].sets.firstIndex(where: { $0.id == setID }) else { return }

            var set = snapshot.exercises[exerciseIndex].sets[setIndex]
            guard set.weight != weight || set.reps != reps || set.rpe != rpe else {
                return
            }
            set.weight = weight
            set.reps = reps
            set.rpe = rpe
            snapshot.exercises[exerciseIndex].sets[setIndex] = set
            snapshot.selectedSetID = setID
            snapshot.selectedSetText = snapshot.trackedSelectedSetText
            guard self.advanceRevision(&snapshot) else { return }
            snapshot.updatedAt = Date()
            self.commitEvent(snapshotChange: .replace(snapshot),
                             workoutID: workoutID, kind: .setUpdated,
                             exerciseID: exerciseID, setID: setID,
                             weight: weight, reps: reps, rpe: rpe)
        }
    }

    func toggleSet(workoutID: UUID, exerciseID: UUID, setID: UUID) {
        WorkoutSessionManager.perform {
            guard var snapshot = self.workoutSnapshot,
                  snapshot.workoutID == workoutID,
                  let exerciseIndex = snapshot.exercises.firstIndex(where: { $0.id == exerciseID }),
                  let setIndex = snapshot.exercises[exerciseIndex].sets.firstIndex(where: { $0.id == setID }) else { return }

            var set = snapshot.exercises[exerciseIndex].sets[setIndex]
            set.completed.toggle()
            snapshot.exercises[exerciseIndex].sets[setIndex] = set
            snapshot.selectedSetID = setID
            snapshot.selectedSetText = snapshot.trackedSelectedSetText
            guard self.advanceRevision(&snapshot) else { return }
            snapshot.updatedAt = Date()
            self.commitEvent(snapshotChange: .replace(snapshot),
                             workoutID: workoutID, kind: .setCompletionChanged,
                             exerciseID: exerciseID, setID: setID,
                             completed: set.completed)
        }
    }

    func addSet(workoutID: UUID, exerciseID: UUID) {
        WorkoutSessionManager.perform {
            guard var snapshot = self.workoutSnapshot,
                  snapshot.workoutID == workoutID,
                  let exerciseIndex = snapshot.exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
            let source = snapshot.exercises[exerciseIndex].sets.last
            var set = WatchWorkoutSet(
                order: snapshot.exercises[exerciseIndex].sets.count + 1,
                weight: source?.weight,
                reps: source?.reps ?? 5,
                rpe: nil, // Rated per set; a copied rating would skip the question.
                previousWeight: source?.previousWeight ?? source?.weight,
                previousReps: source?.previousReps ?? source?.reps,
                completed: false,
                tag: nil, duration: source?.duration, distance: source?.distance
            )
            set.prepareForTracking(snapshot.exercises[exerciseIndex].effectiveTrackingType)
            snapshot.exercises[exerciseIndex].sets.append(set)
            snapshot.selectedSetID = set.id
            snapshot.selectedSetText = snapshot.trackedSelectedSetText
            guard self.advanceRevision(&snapshot) else { return }
            snapshot.updatedAt = Date()
            self.commitEvent(snapshotChange: .replace(snapshot),
                             workoutID: workoutID, kind: .setAdded,
                             exerciseID: exerciseID, setID: set.id,
                             weight: set.weight, reps: set.reps, rpe: set.rpe)
        }
    }

    func deleteSet(workoutID: UUID, exerciseID: UUID, setID: UUID) {
        WorkoutSessionManager.perform {
            guard var snapshot = self.workoutSnapshot,
                  snapshot.workoutID == workoutID,
                  let exerciseIndex = snapshot.exercises.firstIndex(where: { $0.id == exerciseID }),
                  snapshot.exercises[exerciseIndex].sets.count > 1,
                  let setIndex = snapshot.exercises[exerciseIndex].sets.firstIndex(where: { $0.id == setID }) else { return }
            snapshot.exercises[exerciseIndex].sets.remove(at: setIndex)
            for index in snapshot.exercises[exerciseIndex].sets.indices {
                snapshot.exercises[exerciseIndex].sets[index].order = index + 1
            }
            let remaining = snapshot.exercises[exerciseIndex].sets
            snapshot.selectedSetID = remaining[min(setIndex, remaining.count - 1)].id
            snapshot.selectedSetText = remaining.first { $0.id == snapshot.selectedSetID }
                .map { $0.displayText(weightUnit: snapshot.weightUnit ?? .kilogram, trackingType: snapshot.exercises[exerciseIndex].effectiveTrackingType(for: $0)) }
            guard self.advanceRevision(&snapshot) else { return }
            snapshot.updatedAt = Date()
            self.commitEvent(snapshotChange: .replace(snapshot),
                             workoutID: workoutID, kind: .setDeleted,
                             exerciseID: exerciseID, setID: setID)
        }
    }

    func updateSetTag(workoutID: UUID, exerciseID: UUID, setID: UUID, tag: String?) {
        WorkoutSessionManager.perform {
            guard var snapshot = self.workoutSnapshot,
                  snapshot.workoutID == workoutID,
                  let exerciseIndex = snapshot.exercises.firstIndex(where: { $0.id == exerciseID }),
                  let setIndex = snapshot.exercises[exerciseIndex].sets.firstIndex(where: { $0.id == setID }) else { return }
            snapshot.exercises[exerciseIndex].sets[setIndex].tag = tag
            guard self.advanceRevision(&snapshot) else { return }
            snapshot.updatedAt = Date()
            self.commitEvent(snapshotChange: .replace(snapshot),
                             workoutID: workoutID, kind: .setTagChanged,
                             exerciseID: exerciseID, setID: setID, tag: tag)
        }
    }

    func addExercise(workoutID: UUID, afterExerciseID: UUID, catalogExerciseUuid: UUID, name: String, muscleGroup: String?, imageURL: String?) {
        WorkoutSessionManager.perform {
            guard var snapshot = self.workoutSnapshot,
                  snapshot.workoutID == workoutID,
                  let exerciseIndex = snapshot.exercises.firstIndex(where: { $0.id == afterExerciseID }) else { return }
            let set = WatchWorkoutSet(order: 1, reps: 5)
            let exercise = WatchWorkoutExercise(
                order: exerciseIndex + 2,
                name: name,
                sets: [set],
                restTimerDuration: snapshot.exercises[exerciseIndex].restTimerDuration,
                muscleGroup: muscleGroup,
                exerciseUuid: catalogExerciseUuid,
                imageURL: imageURL
            )
            snapshot.exercises.insert(exercise, at: exerciseIndex + 1)
            for index in snapshot.exercises.indices {
                snapshot.exercises[index].order = index + 1
            }
            snapshot.selectedSetID = set.id
            snapshot.selectedSetText = snapshot.trackedSelectedSetText
            guard self.advanceRevision(&snapshot) else { return }
            snapshot.updatedAt = Date()
            self.commitEvent(snapshotChange: .replace(snapshot),
                             workoutID: workoutID, kind: .exerciseAdded,
                             exerciseID: exercise.id, setID: set.id,
                             catalogExerciseUuid: catalogExerciseUuid,
                             afterExerciseID: afterExerciseID)
        }
    }

    func replaceExercise(workoutID: UUID, exerciseID: UUID, catalogExerciseUuid: UUID, name: String, muscleGroup: String?, imageURL: String?) {
        WorkoutSessionManager.perform {
            guard var snapshot = self.workoutSnapshot,
                  snapshot.workoutID == workoutID,
                  let exerciseIndex = snapshot.exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
            snapshot.exercises[exerciseIndex].exerciseUuid = catalogExerciseUuid
            snapshot.exercises[exerciseIndex].name = name
            snapshot.exercises[exerciseIndex].muscleGroup = muscleGroup
            snapshot.exercises[exerciseIndex].imageURL = imageURL
            guard self.advanceRevision(&snapshot) else { return }
            snapshot.updatedAt = Date()
            self.commitEvent(snapshotChange: .replace(snapshot),
                             workoutID: workoutID, kind: .exerciseReplaced,
                             exerciseID: exerciseID,
                             catalogExerciseUuid: catalogExerciseUuid)
        }
    }

    func deleteExercise(workoutID: UUID, exerciseID: UUID) {
        WorkoutSessionManager.perform {
            guard var snapshot = self.workoutSnapshot,
                  snapshot.workoutID == workoutID,
                  snapshot.exercises.count > 1,
                  let exerciseIndex = snapshot.exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
            snapshot.exercises.remove(at: exerciseIndex)
            for index in snapshot.exercises.indices {
                snapshot.exercises[index].order = index + 1
            }
            let fallback = snapshot.exercises[min(exerciseIndex, snapshot.exercises.count - 1)]
            snapshot.selectedSetID = fallback.sets.first?.id
            snapshot.selectedSetText = fallback.sets.first
                .map { $0.displayText(weightUnit: snapshot.weightUnit ?? .kilogram, trackingType: fallback.effectiveTrackingType(for: $0)) }
            guard self.advanceRevision(&snapshot) else { return }
            snapshot.updatedAt = Date()
            self.commitEvent(snapshotChange: .replace(snapshot),
                             workoutID: workoutID, kind: .exerciseDeleted,
                             exerciseID: exerciseID)
        }
    }

    func startRestTimer(workoutID: UUID, duration: TimeInterval = 60) {
        WorkoutSessionManager.perform {
            guard var snapshot = self.workoutSnapshot, snapshot.workoutID == workoutID else { return }
            snapshot.restTimerEnd = Date().addingTimeInterval(duration)
            snapshot.keepRestTimerRunning = true
            guard self.advanceRevision(&snapshot) else { return }
            snapshot.updatedAt = Date()
            guard self.commitEvent(snapshotChange: .replace(snapshot),
                                   workoutID: workoutID, kind: .restTimerUpdated,
                                   restTimerEnd: snapshot.restTimerEnd,
                                   keepRestTimerRunning: true) else { return }
            if let manager = self.workoutSessionManager, manager.uuid == workoutID {
                manager.restTimerEnd = snapshot.restTimerEnd
                manager.keepRestTimerRunning = true
            }
        }
    }

    func stopRestTimer(workoutID: UUID) {
        WorkoutSessionManager.perform {
            guard var snapshot = self.workoutSnapshot, snapshot.workoutID == workoutID else { return }
            snapshot.restTimerEnd = nil
            snapshot.keepRestTimerRunning = false
            guard self.advanceRevision(&snapshot) else { return }
            snapshot.updatedAt = Date()
            guard self.commitEvent(snapshotChange: .replace(snapshot),
                                   workoutID: workoutID, kind: .restTimerUpdated,
                                   restTimerEnd: nil,
                                   keepRestTimerRunning: false) else { return }
            if let manager = self.workoutSessionManager, manager.uuid == workoutID {
                manager.restTimerEnd = nil
                manager.keepRestTimerRunning = false
            }
        }
    }

    func finishPersistedWorkout(start: Date, end: Date, title: String?, uuid: UUID,
                                sessionEffort: Double? = nil) {
        WorkoutSessionManager.perform {
            guard var snapshot = self.workoutSnapshot, snapshot.workoutID == uuid else { return }
            snapshot.startDate = start
            snapshot.endDate = end
            snapshot.isFinished = true
            snapshot.title = title ?? snapshot.title
            snapshot.sessionEffort = sessionEffort.map { min(max($0, 1), 10) }
                ?? snapshot.sessionEffort
            snapshot.activeEnergyKilocalories = self.workoutSessionManager?.burnedCalories
            snapshot.updatedAt = Date()
            guard self.advanceRevision(&snapshot) else { return }
            self.commitEvent(snapshotChange: .replace(snapshot),
                             workoutID: uuid, kind: .workoutFinished,
                             startDate: start, endDate: end, title: title,
                             sessionEffort: snapshot.sessionEffort,
                             eventSnapshot: snapshot)
        }
    }

    func discardPersistedWorkout(uuid: UUID) {
        WorkoutSessionManager.perform {
            guard let snapshot = self.workoutSnapshot, snapshot.workoutID == uuid else { return }
            self.commitEvent(snapshotChange: .replace(nil),
                             workoutID: uuid, kind: .workoutDiscarded,
                             startDate: snapshot.startDate,
                             endDate: snapshot.endDate,
                             title: snapshot.title)
        }
    }

    func recordHealthKitFailure(uuid: UUID, message: String) {
        WorkoutSessionManager.perform {
            self.recordHealthKitFailureOnAccessQueue(uuid: uuid, message: message)
        }
    }

    @discardableResult
    private func recordHealthKitFailureOnAccessQueue(uuid: UUID, message: String) -> Bool {
        guard let snapshot = workoutSnapshot, snapshot.workoutID == uuid else { return false }
        #if DEBUG
        // End/discard callbacks from a session retired by a preference change
        // must never turn a local test workout into a recording failure.
        if isHealthTestWorkout { return true }
        #endif
        recordingError = message
        return commitEvent(workoutID: uuid, kind: .workoutFailed,
                           startDate: snapshot.startDate, endDate: snapshot.endDate,
                           title: message, eventSnapshot: snapshot)
    }

    func ensureWorkoutProjection(uuid: UUID, start: Date) {
        WorkoutSessionManager.perform {
            guard !WatchWorkoutStore.shared.isTerminalWorkout(uuid) else { return }
            var snapshot = self.workoutSnapshot
            if snapshot?.workoutID != uuid {
                snapshot = WatchWorkoutSnapshot.placeholder(workoutID: uuid, startDate: start)
            } else {
                snapshot?.startDate = start
                snapshot?.endDate = nil
                snapshot?.isFinished = false
                snapshot?.updatedAt = Date()
            }
            if let snapshot = snapshot {
                self.persistSnapshot(snapshot)
            }
        }
    }

    func recoverWorkoutSession(workoutSession: HKWorkoutSession,
                               completion: (() -> Void)? = nil) {
        WorkoutSessionManager.perform {
            #if DEBUG
            if let manager = self.workoutSessionManager,
               manager.healthTestMode || (manager.uuid == nil && (manager.state == .prepared || manager.state == .notStarted)) {
                manager.discard()
                self.workoutSessionManager = nil
            }
            #endif
            if let manager = self.workoutSessionManager {
                // Recovery and prepare/start callbacks can race. A duplicate
                // recovery must not trap on the session queue or install a
                // second facade over a live/finalizing recording.
                if manager.manages(workoutSession) || manager.state == .running ||
                    manager.state == .paused || manager.isFinalizingWorkout {
                    if let snapshot = self.workoutSnapshot {
                        manager.associateRecoveredWorkout(snapshot.workoutID)
                    }
                    if let id = manager.uuid, WatchWorkoutStore.shared.shouldDiscardRecoveredWorkout(id),
                       !manager.isFinalizingWorkout {
                        manager.discard()
                        self.workoutSessionManager = nil
                    }
                    self.isRecoveringRecording = false
                    self.reconcileFinishedWorkoutAfterRecovery()
                    self.ensureAutomaticRecording()
                    DispatchQueue.main.async { completion?() }
                    return
                }
                manager.discard()
                self.workoutSessionManager = nil
            }
            #if DEBUG
            let builder = workoutSession.associatedWorkoutBuilder()
            let recoveredID = (builder.metadata[HKMetadataKeyExternalUUID] as? String).flatMap(UUID.init(uuidString:))
            let snapshot = self.workoutSnapshot
            let matchesSnapshot = recoveredID == nil || recoveredID == snapshot?.workoutID
            let retiredTestID = UserDefaults.standard.string(forKey: Self.retiredTestWorkoutKey).flatMap(UUID.init(uuidString:))
            let matchesRetiredTest = retiredTestID != nil && (recoveredID == nil || recoveredID == retiredTestID)
            if UserDefaults.standard.healthTestMode ||
                builder.metadata[WorkoutSessionManager.healthTestMetadataKey] as? Bool == true ||
                (matchesSnapshot && snapshot?.isHealthTestWorkout == true) || matchesRetiredTest {
                let recoveredStart = builder.startDate ?? Date()
                let wasPaused = workoutSession.state == .paused
                // Do this before any manager/data source is attached. These are
                // already-running sessions from an older debug build.
                workoutSession.delegate = nil
                builder.delegate = nil
                workoutSession.end()
                builder.discardWorkout()
                self.isRecoveringRecording = false
                UserDefaults.standard.removeObject(forKey: Self.retiredTestWorkoutKey)
                if var local = snapshot, matchesSnapshot {
                    local.healthTestMode = true
                    local.healthTestWorkoutPaused = local.healthTestWorkoutPaused ?? wasPaused
                    local.activeEnergyKilocalories = nil
                    if self.advanceRevision(&local) {
                        local.updatedAt = Date()
                        self.persistSnapshot(local)
                    }
                } else if snapshot == nil, let recoveredID, !matchesRetiredTest,
                          !WatchWorkoutStore.shared.shouldDiscardRecoveredWorkout(recoveredID) {
                    var local = WatchWorkoutSnapshot.placeholder(workoutID: recoveredID, startDate: recoveredStart)
                    local.healthTestMode = true
                    local.healthTestWorkoutPaused = wasPaused
                    self.persistSnapshot(local)
                }
                self.reconcileFinishedWorkoutAfterRecovery()
                self.ensureAutomaticRecording()
                DispatchQueue.main.async { completion?() }
                return
            }
            UserDefaults.standard.removeObject(forKey: Self.retiredTestWorkoutKey)
            #endif
            // TODO: also recover custom start / end dates
            let workoutSessionManager = WorkoutSessionManager(session: workoutSession) // documentation says this must happen immediately
            if let snapshot = self.workoutSnapshot {
                workoutSessionManager.associateRecoveredWorkout(snapshot.workoutID)
            }
            if let id = workoutSessionManager.uuid, WatchWorkoutStore.shared.shouldDiscardRecoveredWorkout(id) {
                workoutSessionManager.discard()
                self.isRecoveringRecording = false
                self.reconcileFinishedWorkoutAfterRecovery()
                self.ensureAutomaticRecording()
                DispatchQueue.main.async { completion?() }
                return
            }
            self.workoutSessionManager = workoutSessionManager
            self.isRecoveringRecording = false
            if let uuid = workoutSessionManager.uuid {
                if let snapshot = self.workoutSnapshot,
                   snapshot.workoutID == uuid {
                    workoutSessionManager.updateStartDate(snapshot.startDate)
                    workoutSessionManager.updateEndDate(snapshot.endDate)
                    workoutSessionManager.restTimerEnd = snapshot.restTimerEnd
                    workoutSessionManager.keepRestTimerRunning = snapshot.keepRestTimerRunning
                    workoutSessionManager.selectedSetText = snapshot.selectedSetText
                    self.applyLocalRest(snapshot)
                } else if self.workoutSnapshot?.isFinishedRecord != true {
                    // HealthKit can restore a valid session after the durable
                    // projection was lost or replaced. Always synthesize a
                    // minimal editable projection so Finish and Discard remain
                    // available instead of stranding the workout.
                    let recovered = WatchWorkoutSnapshot.placeholder(
                        workoutID: uuid,
                        startDate: workoutSessionManager.startDate ?? Date())
                    self.persistSnapshot(recovered)
                }
            }
            self.reconcileFinishedWorkoutAfterRecovery()
            DispatchQueue.main.async { completion?() }
        }
    }
    
    
    /// - Parameters:
    ///   - completion: Normal workouts prepare/reuse HealthKit; debug tests
    ///                 acknowledge readiness locally, including during recovery.
    func ensurePreparedWorkoutSession(configuration: HKWorkoutConfiguration, completion: @escaping (Result<Void, Error>) -> Void) {
        WorkoutSessionManager.perform {
            os_log("Ensuring prepared workout session")
            #if DEBUG
            if let manager = self.workoutSessionManager, manager.isFinalizingWorkout,
               !self.isHealthTestWorkout {
                DispatchQueue.main.async { completion(.success(())) }
                return
            }
            if self.isRecoveringRecording,
               UserDefaults.standard.string(forKey: Self.retiredTestWorkoutKey) != nil {
                // A normal workout may follow a test discarded during recovery.
                // Retire the old session before preparing its replacement.
                DispatchQueue.main.async { completion(.success(())) }
                return
            }
            if UserDefaults.standard.healthTestMode || self.isHealthTestWorkout {
                // Recovery must inspect/retire any legacy session before a
                // manager is installed; the prepared reply needs no session.
                if self.isRecoveringRecording {
                    DispatchQueue.main.async { completion(.success(())) }
                    return
                }
                if let manager = self.workoutSessionManager {
                    manager.setHealthTestMode(true)
                } else {
                    self.workoutSessionManager = WorkoutSessionManager(localWorkoutID: nil)
                }
                self.recordingError = nil
                DispatchQueue.main.async { completion(.success(())) }
                return
            }
            // A prepared local facade has no recording to reuse for a normal start.
            if let manager = self.workoutSessionManager, manager.healthTestMode,
               manager.uuid == nil {
                self.workoutSessionManager = nil
            }
            #endif
            // check if there already is a current workout session
            if let workoutSessionManager = self.workoutSessionManager {
                let state = workoutSessionManager.state
                os_log("Workout session manager with state=%@ exists", type: .debug, state.name)
                // only create a new session if the current session is not running
                if state == .stopped && !workoutSessionManager.isFinalizingWorkout {
                    workoutSessionManager.discard()
                    self.workoutSessionManager = nil
                } else if state != .ended && state != .notStarted {
                    // there already is a running workout session, startWorkout will take care of it
                    os_log("Keeping workout session with state=%@", state.name)
                    DispatchQueue.main.async { completion(.success(())) }
                    return
                }
            }
            
            let workoutSession: HKWorkoutSession
            do {
                os_log("Creating new workout session")
                workoutSession = try HKWorkoutSession(healthStore: WorkoutSessionManager.healthStore, configuration: configuration)
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            
            self.workoutSessionManager = WorkoutSessionManager(session: workoutSession)
            self.workoutSessionManager?.prepare()
            
            DispatchQueue.main.async { completion(.success(())) }
        }
    }
    
    /**
     Starts a `WorkoutSessionManager`, creating/reusing/overwriting any existing `workoutSessionManager` as necessary.
     - Postcondition
     If an error occured, `workoutSessionManager` is set to `nil`, otherwise `workoutSessionManager.uuid` is set to `uuid` and the `workoutSessionManager` is being started.
     */
    func startWorkoutSession(start: Date, uuid: UUID, healthTestMode: Bool? = nil,
                             isHealthTestWorkout: Bool = false) {
        WorkoutSessionManager.perform {
            defer { self.refreshRecordingDiagnostic() }
            guard !WatchWorkoutStore.shared.isTerminalWorkout(uuid) else { return }
            guard !self.isStartingRecording else { return }
            guard self.workoutSnapshot == nil || self.workoutSnapshot?.workoutID == uuid else {
                self.recordingError = "Finish the workout already on this Watch before starting another."
                return
            }
            guard self.workoutSnapshot?.isFinishedRecord != true else { return }
            if let manager = self.workoutSessionManager,
               let managerID = manager.uuid, managerID != uuid,
               manager.state == .running || manager.state == .paused || manager.isFinalizingWorkout {
                self.recordingError = "Another Watch recording is still running. Finish it before starting this workout."
                return
            }
            if self.workoutSnapshot == nil {
                guard self.persistSnapshot(.placeholder(workoutID: uuid, startDate: start)) else { return }
            }
            #if DEBUG
            // Apply start preferences only after UUID validation on this queue.
            if let healthTestMode, UserDefaults.standard.healthTestMode != healthTestMode {
                UserDefaults.standard.healthTestMode = healthTestMode
            }
            if var snapshot = self.workoutSnapshot,
               snapshot.healthTestMode == nil || isHealthTestWorkout || healthTestMode == true || self.isHealthTestWorkout {
                snapshot.healthTestMode = snapshot.isHealthTestWorkout || isHealthTestWorkout || UserDefaults.standard.healthTestMode || self.isHealthTestWorkout
                guard self.persistSnapshot(snapshot) else { return }
            }
            #endif
            guard !self.isRecoveringRecording else { return }
            #if DEBUG
            if let snapshot = self.workoutSnapshot, snapshot.isHealthTestWorkout {
                self.restoreLocalWorkout(snapshot)
                return
            }
            if let manager = self.workoutSessionManager, manager.healthTestMode {
                manager.discard()
                self.workoutSessionManager = nil
            }
            #endif
            self.automaticRecordingAttemptedFor = uuid
            if let manager = self.workoutSessionManager,
               manager.state == .running || manager.state == .paused {
                guard manager.uuid == uuid || manager.uuid == nil else {
                    self.recordingError = "Another Watch recording is still running. Finish it before starting this workout."
                    return
                }
                if manager.uuid == nil {
                    do { try manager.setUuid(uuid) }
                    catch { self.recordingError = error.localizedDescription; return }
                }
                let displayStart = self.workoutSnapshot?.startDate ?? start
                if manager.startDate != displayStart { manager.updateStartDate(displayStart) }
                self.recordingError = nil
                manager.publishLiveMetrics()
                return
            }
            if let manager = self.workoutSessionManager, manager.state == .stopped {
                if manager.isFinalizingWorkout {
                    self.recordingError = "Your previous recording is still being saved."
                    return
                }
                manager.discard()
                self.workoutSessionManager = nil
            }
            self.isStartingRecording = true
            self.recordingError = nil
            let manager: WorkoutSessionManager
            do {
                if let existing = self.workoutSessionManager,
                   existing.state == .prepared || existing.state == .notStarted {
                    manager = existing
                } else {
                    let configuration = HKWorkoutConfiguration()
                    configuration.activityType = .traditionalStrengthTraining
                    let session = try HKWorkoutSession(healthStore: WorkoutSessionManager.healthStore,
                                                       configuration: configuration)
                    manager = WorkoutSessionManager(session: session)
                    self.workoutSessionManager = manager
                }
                try manager.setUuid(uuid)
            } catch {
                self.isStartingRecording = false
                self.recordingError = error.localizedDescription
                self.workoutSessionManager?.discard()
                self.workoutSessionManager = nil
                return
            }
            // Keep Light's display start, but never invent sensor data for the
            // time before this Watch actually begins recording.
            manager.start(start: max(start, Date())) { result in
                WorkoutSessionManager.perform {
                    guard self.workoutSessionManager === manager else { return }
                    defer { self.refreshRecordingDiagnostic() }
                    self.isStartingRecording = false
                    // A phone edit can arrive while HealthKit is starting. The
                    // durable projection, rather than the captured argument,
                    // owns the latest display date.
                    let displayStart = self.workoutSnapshot.flatMap {
                        $0.workoutID == uuid ? $0.startDate : nil
                    } ?? start
                    #if DEBUG
                    if manager.healthTestMode {
                        self.recordingError = nil
                        if manager.startDate != displayStart { manager.updateStartDate(displayStart) }
                        manager.publishLiveMetrics()
                        return
                    }
                    #endif
                    switch result {
                    case .success:
                        if manager.startDate != displayStart { manager.updateStartDate(displayStart) }
                        manager.publishLiveMetrics()
                        WatchFeedback.play(.start)
                    case .failure(let error):
                        self.recordingError = error.localizedDescription
                        manager.discard()
                        self.workoutSessionManager = nil
                    }
                }
            }
        }
    }

    func endWorkoutSession(start: Date, end: Date, title: String?, uuid: UUID,
                           sessionEffort: Double? = nil,
                           notifyPhone: Bool = true,
                           healthTestMode: Bool? = nil) {
        WorkoutSessionManager.perform {
            os_log("Ending workout session start=%@ end=%@ title=%@ uuid=%@", start as NSDate, end as NSDate, title ?? "nil", uuid as NSUUID)
            if !notifyPhone { WatchWorkoutStore.shared.rememberTerminalWorkout(uuid) }
            // A delayed finish for A must have no effect on active workout B,
            // including preference/provenance changes and HealthKit teardown.
            guard self.targetsCurrentWorkout(uuid) else { return }
            // A phone finish can race the Watch's own finish. The original
            // HealthKit completion owns archiving and any failure handling.
            guard !WatchWorkoutFinalization.isDuplicateFinish(workoutID: uuid,
                recordingWorkoutID: self.workoutSessionManager?.uuid,
                isFinalizing: self.workoutSessionManager?.isFinalizingWorkout ?? false) else { return }
            #if DEBUG
            if healthTestMode == true {
                self.setHealthTestModeOnAccessQueue(true, persistPreference: false)
            }
            #endif

            if notifyPhone, self.workoutSnapshot?.isFinishedRecord == true { return }

            // Queue the finish before HealthKit finalization so a process
            // termination cannot lose the explicit user action.
            var finishSnapshot = self.workoutSnapshot
            if notifyPhone,
               finishSnapshot == nil,
               self.workoutSessionManager?.uuid == uuid {
                finishSnapshot = WatchWorkoutSnapshot.placeholder(
                    workoutID: uuid,
                    startDate: self.workoutSessionManager?.startDate ?? start
                )
            }
            if notifyPhone,
               finishSnapshot?.workoutID != uuid {
                self.recordPersistenceFailure(WatchWorkoutPersistenceError.missingProjection)
                return
            }
            if var snapshot = finishSnapshot, snapshot.workoutID == uuid {
                #if DEBUG
                if self.isHealthTestWorkout {
                    snapshot.healthTestMode = true
                    self.workoutSessionManager?.setHealthTestMode(true)
                }
                #endif
                snapshot.startDate = start
                snapshot.endDate = end
                snapshot.isFinished = true
                snapshot.activeEnergyKilocalories = self.workoutSessionManager?.burnedCalories
                snapshot.title = title ?? snapshot.title
                snapshot.sessionEffort = sessionEffort.map { min(max($0, 1), 10) }
                    ?? snapshot.sessionEffort
                guard self.advanceRevision(&snapshot) else { return }
                snapshot.updatedAt = Date()
                let persisted = notifyPhone
                    ? self.commitEvent(snapshotChange: .replace(snapshot),
                                       workoutID: uuid, kind: .workoutFinished,
                                       startDate: start, endDate: end, title: title,
                                       sessionEffort: snapshot.sessionEffort,
                                       eventSnapshot: snapshot)
                    : self.persistSnapshot(snapshot)
                guard persisted else { return }
            }
            
            guard let workoutSessionManager = self.workoutSessionManager else {
                os_log("No HealthKit session; persisted workout finish locally", type: .info)
                #if DEBUG
                if self.workoutSnapshot?.isHealthTestWorkout == true {
                    self.archiveSnapshot(workoutID: uuid)
                    return
                }
                #endif
                // Queue the existing failure event before removing its snapshot.
                guard self.recordHealthKitFailureOnAccessQueue(uuid: uuid, message: "Not saved to Apple Health. The workout is still saved in Light.") else { return }
                self.archiveSnapshot(workoutID: uuid)
                return
            }
            #if DEBUG
            if workoutSessionManager.healthTestMode, workoutSessionManager.uuid == nil {
                // A finish can arrive between snapshot delivery and automatic
                // local start. A prepared facade needs no start/state callback.
                try? workoutSessionManager.setUuid(uuid)
            }
            #endif
            
            // make sure the message means the current workout
            guard workoutSessionManager.uuid == uuid else {
                // invalid
                // should not happen normally, but maybe could happen?
                if workoutSessionManager.uuid == nil {
                    os_log("Attempt to end workout session manager that has no UUID", type: .fault)
                } else {
                    os_log("Attempt to end workout session manager with different UUID", type: .fault)
                }
                return
            }
            
            workoutSessionManager.updateStartDate(start)

            if let title = title {
                do {
                    os_log("Setting title for workout session manager")
                    try workoutSessionManager.setTitle(title)
                } catch {
                    os_log("Could not set title: %@", type: .error, error.localizedDescription)
                    // continue though
                }
            }
            
            os_log("Ending workout session manager")
            workoutSessionManager.end(end: end) { result in
                WorkoutSessionManager.perform {
                    guard self.workoutSessionManager === workoutSessionManager else { return }
                    switch result {
                    case .success:
                        // The local Save/summary path owns the single success
                        // cue. HealthKit finalization must not add a stop cue.
                        self.workoutSessionManager = nil
                        self.archiveSnapshot(workoutID: uuid)
                        DispatchQueue.main.async { PhoneConnectionManager.shared.requestCurrentSnapshotIfReady() }
                        os_log("Successfully ended workout session manager", type: .info)
                    case .failure(let error):
                        WatchFeedback.play(.failure)
                        os_log("Could not end workout session manager: %@", type: .error, error.localizedDescription)
                        os_log("Discarding workout session manager", type: .info)
                        workoutSessionManager.discard()
                        self.workoutSessionManager = nil
                        guard self.recordHealthKitFailureOnAccessQueue(uuid: uuid, message: error.localizedDescription) else { return }
                        // The finish event was durably queued before HealthKit
                        // finalization. Archive the editor even if HealthKit
                        // fails so the user cannot submit the finish twice.
                        self.archiveSnapshot(workoutID: uuid)
                    }
                }
            }
        }
    }
    
    func updateWorkoutSessionStart(start: Date, uuid: UUID) {
        WorkoutSessionManager.perform {
            os_log("Updating workout session start=%@ uuid=%@", start as NSDate, uuid as NSUUID)
            if var snapshot = self.workoutSnapshot, snapshot.workoutID == uuid, snapshot.startDate != start {
                snapshot.startDate = start
                guard self.advanceRevision(&snapshot) else { return }
                snapshot.updatedAt = Date()
                guard self.persistSnapshot(snapshot) else { return }
            }
            guard let workoutSessionManager = self.workoutSessionManager else {
                os_log("No HealthKit session; persisted start time locally", type: .info)
                return
            }
            
            // make sure the message means the current workout
            guard workoutSessionManager.uuid == uuid else {
                // invalid
                if workoutSessionManager.uuid == nil {
                    print("warning: attempt to update start for workout with no UUID")
                } else {
                    print("warning: attempt to update start for workout with different UUID")
                }
                return
            }
            
            if workoutSessionManager.startDate != start { workoutSessionManager.updateStartDate(start) }
        }
    }
    
    func updateWorkoutSessionEnd(end: Date?, uuid: UUID) {
        WorkoutSessionManager.perform {
            os_log("Updating workout session end=%@ uuid=%@", (end as NSDate?) ?? "nil", uuid as NSUUID)
            if var snapshot = self.workoutSnapshot, snapshot.workoutID == uuid,
               snapshot.endDate != end || snapshot.isFinished == nil {
                snapshot.endDate = end
                // An end-time edit cannot finish an active projection. Preserve
                // an explicit finish already being reconciled by recovery.
                if snapshot.isFinished == nil { snapshot.isFinished = false }
                guard self.advanceRevision(&snapshot) else { return }
                snapshot.updatedAt = Date()
                guard self.persistSnapshot(snapshot) else { return }
            }
            guard let workoutSessionManager = self.workoutSessionManager else {
                os_log("No HealthKit session; persisted end time locally", type: .info)
                return
            }
            
            // make sure the message means the current workout
            guard workoutSessionManager.uuid == uuid else {
                // invalid
                // should not happen normally, but maybe could happen?
                if workoutSessionManager.uuid == nil {
                    os_log("Attempt to update end for workout session manager that has no UUID", type: .fault)
                } else {
                    os_log("Attempt to update end for workout session manager with different UUID", type: .fault)
                }
                return
            }
            
            if workoutSessionManager.endDate != end { workoutSessionManager.updateEndDate(end) }
        }
    }
    
    func discardWorkoutSession(uuid: UUID, notifyPhone: Bool = true) {
        WorkoutSessionManager.perform {
            os_log("Discarding workout session uuid=%@", uuid as NSUUID)
            if !notifyPhone { WatchWorkoutStore.shared.rememberTerminalWorkout(uuid) }
            guard self.targetsCurrentWorkout(uuid) else { return }
            var discardSnapshot = self.workoutSnapshot
            if notifyPhone,
               discardSnapshot == nil,
               self.workoutSessionManager?.uuid == uuid {
                discardSnapshot = WatchWorkoutSnapshot.placeholder(
                    workoutID: uuid,
                    startDate: self.workoutSessionManager?.startDate ?? Date()
                )
            }
            if notifyPhone,
               discardSnapshot?.workoutID != uuid {
                self.recordPersistenceFailure(WatchWorkoutPersistenceError.missingProjection)
                return
            }
            if let snapshot = discardSnapshot, snapshot.workoutID == uuid {
                let persisted = notifyPhone
                    ? self.commitEvent(snapshotChange: .replace(nil),
                                       workoutID: uuid, kind: .workoutDiscarded,
                                       startDate: snapshot.startDate,
                                       endDate: snapshot.endDate,
                                       title: snapshot.title)
                    : self.archiveSnapshot(workoutID: uuid)
                guard persisted else { return }
            }
            guard let workoutSessionManager = self.workoutSessionManager else {
                os_log("No HealthKit session; discarded persisted workout locally", type: .info)
                return
            }
            #if DEBUG
            if workoutSessionManager.healthTestMode, workoutSessionManager.uuid == nil {
                try? workoutSessionManager.setUuid(uuid)
            }
            #endif
            
            // make sure the message means the current workout
            guard workoutSessionManager.uuid == uuid else {
                // invalid
                // should not happen normally, but maybe could happen?
                if workoutSessionManager.uuid == nil {
                    os_log("Attempt to discard workout session manager that has no UUID", type: .fault)
                } else {
                    os_log("Attempt to discard workout session manager with different UUID", type: .fault)
                }
                return
            }
            
            workoutSessionManager.discard()
            self.workoutSessionManager = nil
            print("success: discarded workout session")
        }
    }
    
    func discardUnstartedWorkoutSession() {
        WorkoutSessionManager.perform {
            os_log("Discarding unstarted workout session")
            guard let workoutSessionManager = self.workoutSessionManager else {
                // invalid
                // should not happen normally, but can happen
                os_log("Attempt to discard unstarted workout session while no workout session manager is set", type: .fault)
                return
            }
            
            // make sure no UUID is set
            if let uuid = workoutSessionManager.uuid {
                // can happen, but something probably went wrong before
                os_log("Attempt to discard unstarted workout session with uuid=%@", type: .fault, uuid as NSUUID)
                return // treat a workout session with a UUID as started, return here!
            }
            
            guard workoutSessionManager.state == .prepared || workoutSessionManager.state == .notStarted else {
                // can happen, but something probably went wrong before
                os_log("Attempt to discard unstarted workout session with state=%@", type: .fault, workoutSessionManager.state.name)
                return
            }
            
            workoutSessionManager.discard()
            self.workoutSessionManager = nil
            os_log("Discarded unstarted workout session", type: .info)
        }
    }
    
    func discardWorkoutSession() {
        WorkoutSessionManager.perform {
            os_log("Discarding workout session")
            let managerID = self.workoutSessionManager?.uuid
            var discardSnapshot = self.workoutSnapshot
            if let snapshotID = discardSnapshot?.workoutID,
               let managerID,
               snapshotID != managerID {
                self.recordPersistenceFailure(WatchWorkoutPersistenceError.missingProjection)
                return
            }
            if discardSnapshot == nil, let managerID {
                discardSnapshot = WatchWorkoutSnapshot.placeholder(
                    workoutID: managerID,
                    startDate: self.workoutSessionManager?.startDate ?? Date()
                )
            }
            guard let snapshot = discardSnapshot else {
                self.recordPersistenceFailure(WatchWorkoutPersistenceError.missingProjection)
                return
            }
            guard self.commitEvent(snapshotChange: .replace(nil),
                                   workoutID: snapshot.workoutID, kind: .workoutDiscarded,
                                   startDate: snapshot.startDate,
                                   endDate: snapshot.endDate,
                                   title: snapshot.title) else { return }
            guard let workoutSessionManager = self.workoutSessionManager else {
                os_log("No HealthKit session; discarded persisted workout locally", type: .info)
                return
            }
            
            workoutSessionManager.discard()
            self.workoutSessionManager = nil
            print("success: discarded workout session")
        }
    }
    
    func updateWorkoutSessionRestTimer(end: Date?, keepRunning: Bool?, uuid: UUID) {
        WorkoutSessionManager.perform {
            os_log("Updating workout session rest timer end=%@ keepRunning=%@ uuid=%@", (end as NSDate?) ?? "nil", keepRunning.map { String(describing: $0) } ?? "nil", uuid as NSUUID)
            if var snapshot = self.workoutSnapshot, snapshot.workoutID == uuid {
                snapshot.restTimerEnd = end
                if let keepRunning = keepRunning {
                    snapshot.keepRestTimerRunning = keepRunning
                }
                guard self.advanceRevision(&snapshot) else { return }
                snapshot.updatedAt = Date()
                guard self.persistSnapshot(snapshot) else { return }
            }
            guard let workoutSessionManager = self.workoutSessionManager else {
                os_log("No HealthKit session; persisted rest timer locally", type: .info)
                return
            }
            
            // make sure the message means the current workout
            guard workoutSessionManager.uuid == uuid else {
                // invalid
                // should not happen normally, but maybe could happen?
                if workoutSessionManager.uuid == nil {
                    os_log("Attempt to update rest timer for workout session manager that has no UUID", type: .fault)
                } else {
                    os_log("Attempt to update rest timer for workout session manager with different UUID", type: .fault)
                }
                return
            }
            
            workoutSessionManager.restTimerEnd = end
            if let keepRunning = keepRunning {
                workoutSessionManager.keepRestTimerRunning = keepRunning
            }

        }
    }
    
    func updateWorkoutSessionSelectedSetText(text: String?, uuid: UUID) {
        WorkoutSessionManager.perform {
            os_log("Updating workout session selected text=%@ uuid=%@", text ?? "nil", uuid as NSUUID)
            if var snapshot = self.workoutSnapshot, snapshot.workoutID == uuid {
                snapshot.selectedSetText = text
                guard self.advanceRevision(&snapshot) else { return }
                snapshot.updatedAt = Date()
                guard self.persistSnapshot(snapshot) else { return }
            }
            guard let workoutSessionManager = self.workoutSessionManager else {
                os_log("No HealthKit session; persisted selected set text locally", type: .info)
                return
            }
            
            // make sure the message means the current workout
            guard workoutSessionManager.uuid == uuid else {
                // invalid
                // should not happen normally, but maybe could happen?
                if workoutSessionManager.uuid == nil {
                    os_log("Attempt to update selected text for workout session manager that has no UUID", type: .fault)
                } else {
                    os_log("Attempt to update selected text for workout session manager with different UUID", type: .fault)
                }
                return
            }
            
            workoutSessionManager.selectedSetText = text
        }
    }
}

// MARK: - Watch-first training
extension WorkoutSessionManagerStore {
    /// A completion requests the durable boundary for a discrete structural
    /// action. Continuous Crown edits omit it and retain their debounced writes.
    func updateCurrent(persistenceCompletion: ((Bool) -> Void)? = nil,
                       _ mutation: @escaping (inout WatchWorkoutSnapshot) -> Void) {
        WorkoutSessionManager.perform {
            var persisted = false
            defer {
                if let persistenceCompletion {
                    let success = persisted
                    DispatchQueue.main.async { persistenceCompletion(success) }
                }
            }
            guard var snapshot = self.workoutSnapshot, !snapshot.isFinishedRecord else { return }
            let previous = snapshot
            // SwiftUI callers can capture main-actor bindings/state in this
            // closure. Keep session edit ordering, but execute the UI closure
            // on main, with no durable-store lock held during the hop.
            DispatchQueue.main.sync { mutation(&snapshot) }
            WatchWorkoutEditing.normalize(&snapshot)
            guard snapshot != previous, self.advanceRevision(&snapshot) else { return }
            snapshot.updatedAt = Date()
            snapshot.selectedSetText = snapshot.trackedSelectedSetText
            guard self.commitEvent(snapshotChange: .replace(snapshot), workoutID: snapshot.workoutID,
                                   kind: .workoutStructureUpdated, eventSnapshot: snapshot,
                                   removedExerciseIDs: previous.exercises.map(\.id).filter { oldID in
                                       !snapshot.exercises.contains { $0.id == oldID }
                                   },
                                   removedSetIDs: previous.exercises.flatMap(\.sets).map(\.id).filter { oldID in
                                       !snapshot.exercises.flatMap(\.sets).contains { $0.id == oldID }
                                   }, fieldChanges: .between(previous: previous, next: snapshot),
                                   requiresImmediatePersistence: persistenceCompletion != nil) else { return }
            var trackingChanges: [(UUID, SetTrackingType)] = []
            for exercise in snapshot.exercises {
                guard let old = previous.exercises.first(where: { $0.id == exercise.id }),
                      old.trackingType != exercise.trackingType,
                      let type = exercise.trackingType.flatMap(SetTrackingType.init(rawValue:)),
                      let catalogID = exercise.exerciseUuid else { continue }
                trackingChanges.append((catalogID, type))
            }
            if !trackingChanges.isEmpty {
                let changes = trackingChanges
                DispatchQueue.main.async {
                    for (id, type) in changes { SetTrackingPreferences.setOverride(type, for: id) }
                    self.syncTrackingPreferences()
                }
            }
            self.applyLocalRest(snapshot)
            persisted = true
        }
    }

    func setTrackingType(_ type: SetTrackingType, exerciseID: UUID) {
        updateCurrent { snapshot in
            guard let index = snapshot.exercises.firstIndex(where: { $0.id == exerciseID }),
                  snapshot.exercises[index].effectiveTrackingType != type else { return }
            snapshot.exercises[index].trackingType = type.rawValue
            for set in snapshot.exercises[index].sets.indices where !snapshot.exercises[index].sets[set].completed {
                snapshot.exercises[index].sets[set].prepareForTracking(type)
            }
        }
    }

    func selectSet(_ id: UUID) {
        WorkoutSessionManager.perform {
            guard var snapshot = self.workoutSnapshot, snapshot.selectedSetID != id,
                  snapshot.exercises.flatMap(\.sets).contains(where: { $0.id == id }) else { return }
            snapshot.selectedSetID = id
            snapshot.selectedSetText = snapshot.trackedSelectedSetText
            snapshot.updatedAt = Date()
            guard self.advanceRevision(&snapshot) else { return }
            self.persistSnapshot(snapshot)
        }
    }

    func completeSet(exerciseID: UUID, setID: UUID) {
        WorkoutSessionManager.perform {
            guard var snapshot = self.workoutSnapshot, !snapshot.isFinishedRecord,
                  let exercise = snapshot.exercises.firstIndex(where: { $0.id == exerciseID }),
                  let set = snapshot.exercises[exercise].sets.firstIndex(where: { $0.id == setID }) else { return }
            snapshot.exercises[exercise].sets[set].completed.toggle()
            let completed = snapshot.exercises[exercise].sets[set].completed
            snapshot.selectedSetID = completed ? WatchWorkoutEditing.nextSet(in: snapshot, after: setID) : setID
            if completed {
                snapshot.restTimerEnd = Date().addingTimeInterval(snapshot.exercises[exercise].restTimerDuration ?? 60)
                snapshot.pausedRestRemaining = nil
            } else {
                snapshot.restTimerEnd = nil
                snapshot.pausedRestRemaining = nil
            }
            snapshot.updatedAt = Date()
            snapshot.selectedSetText = snapshot.trackedSelectedSetText
            guard self.advanceRevision(&snapshot),
                  self.commitEvent(snapshotChange: .replace(snapshot), workoutID: snapshot.workoutID,
                                   kind: .setCompletionChanged, exerciseID: exerciseID, setID: setID,
                                   completed: completed, eventSnapshot: snapshot) else { return }
            self.applyLocalRest(snapshot)
            // Only a committed local log announces completion. Phone snapshot
            // delivery uses applyLocalRest and never replays this cue.
            let isRecord = completed && WatchWorkoutSummary.recordSetIDs(in: snapshot, history: WatchWorkoutStore.shared.library().history).contains(setID)
            WatchFeedback.play(completed ? (isRecord ? .directionUp : .success) : .click)
        }
    }

    func addExercise(_ pick: WatchExercisePick, after: UUID? = nil) {
        updateCurrent { snapshot in
            let index = after.flatMap { id in snapshot.exercises.firstIndex { $0.id == id } }.map { $0 + 1 }
                ?? snapshot.exercises.count
            let type = SetTrackingPreferences.override(for: pick.id)
                ?? SetTrackingType.defaultType(name: pick.name, equipment: WatchWorkoutSummary.equipment(pick.name).map { [$0] } ?? [])
            var set = WatchWorkoutSet(order: 1, reps: 8)
            set.prepareForTracking(type)
            let exercise = WatchWorkoutExercise(order: index + 1, name: pick.name, sets: [set],
                                               restTimerDuration: 90, muscleGroup: pick.muscle,
                                               exerciseUuid: pick.id, imageURL: pick.imageURL, trackingType: type.rawValue)
            snapshot.exercises.insert(exercise, at: index)
            if snapshot.selectedSetID == nil { snapshot.selectedSetID = set.id }
        }
    }

    func startBlankWorkout(title: String = "Workout") {
        begin(WatchWorkoutEditing.newWorkout(exercises: [], title: title, unit: preferredWeightUnit))
    }

    func startWorkout(from saved: WatchSavedWorkout) {
        var snapshot = WatchWorkoutEditing.newWorkout(exercises: saved.exercises, title: saved.title,
                                                      unit: saved.weightUnit, sourceSavedWorkoutID: saved.id)
        copyNotes(from: saved.exercises, into: &snapshot, sourceIsSavedWorkout: true)
        snapshot.comment = saved.comment
        copyTrackingTypes(from: saved.exercises, into: &snapshot)
        begin(WatchWorkoutEditing.converting(snapshot, to: preferredWeightUnit))
    }

    func repeatWorkout(_ history: WatchWorkoutSnapshot) {
        var snapshot = WatchWorkoutEditing.newWorkout(exercises: history.exercises,
                                                      title: history.title ?? "Workout",
                                                      unit: history.weightUnit ?? preferredWeightUnit)
        copyNotes(from: history.exercises, into: &snapshot)
        copyTrackingTypes(from: history.exercises, into: &snapshot)
        begin(WatchWorkoutEditing.converting(snapshot, to: preferredWeightUnit))
    }

    private func copyTrackingTypes(from source: [WatchWorkoutExercise], into snapshot: inout WatchWorkoutSnapshot) {
        for (index, exercise) in source.enumerated() where snapshot.exercises.indices.contains(index) {
            let type = SetTrackingPreferences.override(for: exercise.exerciseUuid) ?? exercise.effectiveTrackingType
            snapshot.exercises[index].trackingType = type.rawValue
            for set in snapshot.exercises[index].sets.indices {
                snapshot.exercises[index].sets[set].prepareForTracking(type)
            }
        }
    }

    /// Logged comments belong to one session. Pinned cues and their exact
    /// plan-row link survive the fresh logging identities created above.
    private func copyNotes(from source: [WatchWorkoutExercise], into snapshot: inout WatchWorkoutSnapshot,
                           sourceIsSavedWorkout: Bool = false) {
        snapshot.comment = nil
        let preferences = ExerciseNotes.load()
        for (index, exercise) in source.enumerated() where snapshot.exercises.indices.contains(index) {
            snapshot.exercises[index].comment = nil
            if let id = exercise.exerciseUuid, let entry = preferences.entries[id.uuidString] {
                snapshot.exercises[index].exerciseNote = entry.text
            } else {
                snapshot.exercises[index].exerciseNote = exercise.exerciseNote
            }
            // Older saved workouts carried their plan cue in comment. Never
            // promote a logged session's transient comment into a plan cue.
            snapshot.exercises[index].routineNote = exercise.routineNote
                ?? (sourceIsSavedWorkout ? exercise.comment : nil)
            // A saved copy has its own plan rows even when it retains the
            // originating plan's metadata. Launches link to those current rows.
            snapshot.exercises[index].routineExerciseID = sourceIsSavedWorkout ? exercise.id : exercise.routineExerciseID
            if !sourceIsSavedWorkout {
                for set in snapshot.exercises[index].sets.indices {
                    snapshot.exercises[index].sets[set].comment = nil
                }
            }
        }
    }

    private func begin(_ snapshot: WatchWorkoutSnapshot) {
        WorkoutSessionManager.perform {
            guard self.workoutSnapshot == nil else {
                self.recordingError = "Finish your current workout first."
                return
            }
            var snapshot = snapshot
            snapshot.startedOnWatch = true
            snapshot.selectedSetText = snapshot.trackedSelectedSetText
            #if DEBUG
            snapshot.healthTestMode = UserDefaults.standard.healthTestMode
            #endif
            guard self.commitEvent(snapshotChange: .replace(snapshot), workoutID: snapshot.workoutID,
                                   kind: .workoutCreated, eventSnapshot: snapshot) else { return }
            self.startWorkoutSession(start: snapshot.startDate, uuid: snapshot.workoutID)
        }
    }

    /// A live normal workout owns HealthKit recording; a test uses local state.
    /// Recovery gets first chance before either manager is created.
    /// A failed automatic attempt stays visible and requires an explicit retry.
    func ensureAutomaticRecording() {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--light-watch-demo") { return }
        #endif
        WorkoutSessionManager.perform {
            defer { self.refreshRecordingDiagnostic() }
            guard !self.isRecoveringRecording, !self.isStartingRecording,
                  let snapshot = self.workoutSnapshot, !snapshot.isFinishedRecord else { return }
            #if DEBUG
            if self.isHealthTestWorkout {
                self.restoreLocalWorkout(snapshot)
                return
            }
            #endif
            if let manager = self.workoutSessionManager {
                if manager.state == .running || manager.state == .paused {
                    if manager.uuid == snapshot.workoutID { return }
                    if manager.uuid != nil {
                        self.recordingError = "A different Watch recording is still running. Finish it before starting another."
                        return
                    }
                }
                if manager.state == .stopped && manager.isFinalizingWorkout { return }
            }
            guard self.automaticRecordingAttemptedFor != snapshot.workoutID else { return }
            self.automaticRecordingAttemptedFor = snapshot.workoutID
            self.startWorkoutSession(start: snapshot.startDate, uuid: snapshot.workoutID)
        }
    }

    func startRecording() {
        WorkoutSessionManager.perform {
            guard !self.isRecoveringRecording, let snapshot = self.workoutSnapshot,
                  !snapshot.isFinishedRecord else { return }
            self.automaticRecordingAttemptedFor = snapshot.workoutID
            self.startWorkoutSession(start: snapshot.startDate, uuid: snapshot.workoutID)
        }
    }

    func toggleWorkoutPause() {
        WorkoutSessionManager.perform {
            #if DEBUG
            if let manager = self.workoutSessionManager, manager.healthTestMode,
               var snapshot = self.workoutSnapshot, snapshot.workoutID == manager.uuid {
                snapshot.healthTestWorkoutPaused = manager.state == .running
                guard self.advanceRevision(&snapshot) else { return }
                snapshot.updatedAt = Date()
                guard self.persistSnapshot(snapshot) else { return }
            }
            #endif
            self.workoutSessionManager?.togglePause()
        }
    }

    func setPreferredWeightUnit(_ unit: WatchWorkoutWeightUnit) {
        UserDefaults.standard.set(unit.rawValue, forKey: "watch.preferredWeightUnit")
        updateCurrent { $0 = WatchWorkoutEditing.converting($0, to: unit) }
        notifySyncStateChanged()
    }

    func saveWorkout(_ saved: WatchSavedWorkout, completion: @escaping (Bool) -> Void = { _ in }) {
        WorkoutSessionManager.perform {
            guard !saved.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                DispatchQueue.main.async { completion(false) }; return
            }
            let success = self.commitEvent(workoutID: saved.id, kind: .savedWorkoutUpserted, savedWorkout: saved)
            self.notifySyncStateChanged()
            self.completeLibraryEdit(success: success, completion: completion)
        }
    }

    func deleteSavedWorkout(id: UUID, completion: @escaping (Bool) -> Void = { _ in }) {
        WorkoutSessionManager.perform {
            let success = self.commitEvent(workoutID: id, kind: .savedWorkoutDeleted)
            self.notifySyncStateChanged()
            self.completeLibraryEdit(success: success, completion: completion)
        }
    }

    private func completeLibraryEdit(success: Bool, completion: @escaping (Bool) -> Void) {
        guard success else { DispatchQueue.main.async { completion(false) }; return }
        WatchWorkoutStore.shared.flushPersistence { result in
            DispatchQueue.main.async {
                switch result {
                case .success: completion(true)
                case .failure: completion(false)
                }
            }
        }
    }

    func saveCurrentAsWorkout(completion: @escaping (Bool) -> Void = { _ in }) {
        guard let snapshot = workoutSnapshot else { completion(false); return }
        saveAsWorkout(snapshot, completion: completion)
    }

    func saveAsWorkout(_ snapshot: WatchWorkoutSnapshot, completion: @escaping (Bool) -> Void = { _ in }) {
        var template = WatchWorkoutEditing.newWorkout(exercises: snapshot.exercises,
            title: snapshot.title ?? "Workout", unit: snapshot.weightUnit ?? preferredWeightUnit)
        copyNotes(from: snapshot.exercises, into: &template)
        saveWorkout(WatchSavedWorkout(id: UUID(), title: template.title ?? "Workout",
            exercises: template.exercises, weightUnit: template.weightUnit ?? preferredWeightUnit,
            comment: nil, updatedAt: Date()), completion: completion)
    }

    func finishWorkout(effort: Double?) {
        WorkoutSessionManager.perform {
            guard let snapshot = self.workoutSnapshot, !snapshot.isFinishedRecord,
                  snapshot.exercises.flatMap(\.sets).contains(where: \.completed) else { return }
            self.endWorkoutSession(start: snapshot.startDate, end: Date(), title: snapshot.title,
                                   uuid: snapshot.workoutID, sessionEffort: effort)
        }
    }

    func discardWorkout() {
        guard let snapshot = workoutSnapshot else { return }
        discardWorkoutSession(uuid: snapshot.workoutID)
    }

    func adjustRest(by interval: TimeInterval) {
        changeRest { snapshot in
            if let paused = snapshot.pausedRestRemaining {
                snapshot.pausedRestRemaining = max(0, paused + interval)
            } else if let end = snapshot.restTimerEnd {
                snapshot.restTimerEnd = max(end, Date()).addingTimeInterval(interval)
            }
        }
    }

    func toggleRestPause() {
        changeRest { snapshot in
            if let paused = snapshot.pausedRestRemaining {
                snapshot.restTimerEnd = Date().addingTimeInterval(paused)
                snapshot.pausedRestRemaining = nil
            } else if let end = snapshot.restTimerEnd {
                snapshot.pausedRestRemaining = max(0, end.timeIntervalSinceNow)
                snapshot.restTimerEnd = nil
            }
        }
    }

    func skipRest() {
        changeRest { $0.restTimerEnd = nil; $0.pausedRestRemaining = nil }
    }

    private func changeRest(feedback: Bool = true, _ mutation: @escaping (inout WatchWorkoutSnapshot) -> Void) {
        WorkoutSessionManager.perform {
            guard var snapshot = self.workoutSnapshot, !snapshot.isFinishedRecord else { return }
            mutation(&snapshot)
            if let paused = snapshot.pausedRestRemaining, paused <= 0 { snapshot.pausedRestRemaining = nil }
            if let end = snapshot.restTimerEnd, end <= Date() { snapshot.restTimerEnd = nil }
            guard self.advanceRevision(&snapshot) else { return }
            snapshot.updatedAt = Date()
            guard self.commitEvent(snapshotChange: .replace(snapshot), workoutID: snapshot.workoutID,
                                   kind: .restTimerUpdated, restTimerEnd: snapshot.restTimerEnd,
                                   keepRestTimerRunning: snapshot.keepRestTimerRunning,
                                   eventSnapshot: snapshot) else { return }
            self.applyLocalRest(snapshot)
            if feedback { WatchFeedback.play(.click) }
        }
    }

    private func applyLocalRest(_ snapshot: WatchWorkoutSnapshot) {
        restExpiry?.cancel()
        NotificationManager.shared.syncRestNotification(snapshot)
        if let manager = workoutSessionManager, manager.uuid == snapshot.workoutID {
            manager.restTimerEnd = snapshot.restTimerEnd
            manager.keepRestTimerRunning = snapshot.keepRestTimerRunning
        }
        guard !snapshot.isFinishedRecord, snapshot.pausedRestRemaining == nil,
              let end = snapshot.restTimerEnd else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let current = self.workoutSnapshot,
                  current.workoutID == snapshot.workoutID, current.restTimerEnd == end,
                  current.pausedRestRemaining == nil, !current.isFinishedRecord else { return }
            if self.lastRestAlertEnd != end {
                self.lastRestAlertEnd = end
                NotificationManager.shared.restDidFinish(workoutID: snapshot.workoutID, end: end)
            }
            if current.keepRestTimerRunning { self.notifySyncStateChanged() }
            else {
                // Expiry already owns the notification-style cue. Clearing the
                // timer is not another user adjustment and must not click.
                self.changeRest(feedback: false) { $0.restTimerEnd = nil; $0.pausedRestRemaining = nil }
            }
        }
        restExpiry = work
        WorkoutSessionManager.accessQueue.asyncAfter(deadline: .now() + max(0, end.timeIntervalSinceNow), execute: work)
    }
}

/// The Watch keeps its own copy of the iPhone's Health test mode preference
/// (same key as `UserDefaults+Settings`, which isn't compiled into the Watch).
extension UserDefaults {
    var healthTestMode: Bool {
        get {
            #if DEBUG
            object(forKey: "healthTestMode") as? Bool ?? true
            #else
            false
            #endif
        }
        set {
            #if DEBUG
            set(newValue, forKey: "healthTestMode")
            #endif
        }
    }
}

// MARK: - Watch tracking presentation (no persistence schema changes)
extension WatchWorkoutExercise {
    var effectiveTrackingType: SetTrackingType {
        if let type = trackingType.flatMap(SetTrackingType.init(rawValue:)) { return type }
        if let type = SetTrackingPreferences.override(for: exerciseUuid) { return type }
        let fallback = SetTrackingType.defaultType(name: name,
            equipment: WatchWorkoutSummary.equipment(name).map { [$0] } ?? [])
        if let timed = sets.first(where: { ($0.duration ?? 0) > 0 || ($0.distance ?? 0) > 0 }) {
            return SetTrackingType.resolved(fallback, from: timed.trackingData)
        }
        if fallback == .bodyweightReps, sets.contains(where: { ($0.weight ?? 0) > 0 }) { return .weightedBodyweight }
        return fallback
    }

    func effectiveTrackingType(for set: WatchWorkoutSet) -> SetTrackingType {
        set.completed ? SetTrackingType.resolved(effectiveTrackingType, from: set.trackingData) : effectiveTrackingType
    }
}

extension WatchWorkoutSet {
    var trackingData: SetTrackingType.SetData {
        .init(weight: weight ?? 0, reps: reps ?? 0, duration: duration, distance: distance)
    }

    mutating func prepareForTracking(_ type: SetTrackingType) {
        if !type.usesWeight { weight = nil }
        if !type.usesReps {
            reps = nil; minTargetReps = nil; maxTargetReps = nil
        } else if (reps ?? 0) == 0 { reps = 5 }
        duration = type.usesDuration ? (duration ?? 60) : nil
        if !type.usesDistance { distance = nil }
    }

    func displayText(weightUnit: WatchWorkoutWeightUnit, trackingType type: SetTrackingType) -> String {
        var parts: [String] = []
        if type.usesWeight {
            parts.append(type.weightPrefix + WatchNumber.format(max(0, weight ?? 0)) + " " + weightUnit.symbol)
        }
        if type.usesReps {
            let reps = reps ?? (completed ? nil : maxTargetReps ?? minTargetReps) ?? 0
            if type.usesWeight, let weight = parts.first { return weight + " × \(reps)" }
            parts.append(WatchNumber.count(reps, "rep"))
        }
        if type.usesDistance, let distance, distance.isFinite, distance >= 0 {
            let value = distance / (weightUnit == .pound ? 1_609.344 : 1_000)
            parts.append(value.formatted(.number.precision(.fractionLength(2))) + " " + (weightUnit == .pound ? "mi" : "km"))
        }
        if type.usesDuration, let duration { parts.append(SetTrackingType.durationText(duration)) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

extension WatchWorkoutSnapshot {
    var trackedSelectedSetText: String? {
        selectedSet.map { $0.set.displayText(weightUnit: weightUnit ?? .kilogram,
                                            trackingType: $0.exercise.effectiveTrackingType(for: $0.set)) }
    }
    var trackedVolume: Double {
        exercises.reduce(0) { total, exercise in
            total + exercise.sets.filter(\.completed).reduce(0) {
                $0 + exercise.effectiveTrackingType(for: $1).volume(weight: $1.weight ?? 0, reps: $1.reps ?? 0)
            }
        }
    }
    private var completedTrackingTypes: [SetTrackingType] {
        exercises.flatMap { exercise in exercise.sets.filter(\.completed).map { exercise.effectiveTrackingType(for: $0) } }
    }
    var trackingMetricTitle: String {
        if trackedVolume > 0 || completedSets.isEmpty { return "Volume" }
        if completedTrackingTypes.contains(where: \.usesDistance) { return "Distance" }
        if completedTrackingTypes.contains(where: \.usesDuration) { return "Set Time" }
        return "Reps"
    }
    func trackingMetricUnit(unit: WatchWorkoutWeightUnit) -> String {
        switch trackingMetricTitle {
        case "Volume": return unit.symbol
        case "Distance": return unit == .pound ? "mi" : "km"
        case "Reps": return "reps"
        default: return ""
        }
    }
    func trackingMetricValue(unit: WatchWorkoutWeightUnit) -> String {
        switch trackingMetricTitle {
        case "Distance":
            let meters = completedSets.compactMap(\.distance).filter { $0.isFinite && $0 >= 0 }.reduce(0, +)
            return (meters / (unit == .pound ? 1_609.344 : 1_000)).formatted(.number.precision(.fractionLength(2)))
        case "Set Time": return SetTrackingType.durationText(completedSets.compactMap(\.duration).filter { $0.isFinite && $0 >= 0 }.reduce(0, +))
        case "Reps": return String(completedSets.reduce(0) { $0 + max(0, $1.reps ?? 0) })
        default: return WatchNumber.format(trackedVolume)
        }
    }
}
#endif // os(watchOS)
