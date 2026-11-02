import Combine
import CoreData
import Foundation
import WorkoutDataKit

/// Immutable dashboard values. Managed objects stay on their context's queue;
/// screens only resolve an object ID when opening a workout.
struct TrainingExerciseSnapshot {
    let id: NSManagedObjectID
    let uuid: UUID?
    let setCount: Int
    let repetitions: Int
    let volume: Double
}

struct TrainingSessionSnapshot: Identifiable {
    let id: NSManagedObjectID
    let date: Date
    let title: String?
    let duration: TimeInterval
    let setCount: Int
    let repetitions: Int
    let volume: Double
    let effort: Double?
    let exercises: [TrainingExerciseSnapshot]
}

struct TrainingExerciseTotals {
    var sessions: Int = 0
    var sets: Int = 0
    var lastTrained: Date = .distantPast
}

struct TrainingHistorySnapshot {
    var sessions: [TrainingSessionSnapshot] = []
    var byDay: [Date: [TrainingSessionSnapshot]] = [:]
    var trainedWeeks: Set<Date> = []
    var exerciseTotals: [UUID: TrainingExerciseTotals] = [:]
    var recordSetIDs: Set<NSManagedObjectID> = []

    func streak(now: Date = Date(), calendar: Calendar = .current) -> Int {
        guard var week = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return 0 }
        var count = 0
        for offset in 0..<520 {
            if trainedWeeks.contains(week) { count += 1 }
            else if offset > 0 { break }
            guard let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: week) else { break }
            week = previous
        }
        return count
    }

    static func build(from workouts: [Workout], calendar: Calendar = .current,
                      catalog: [UUID: Exercise] = [:]) -> Self {
        var result = Self()
        for workout in workouts where !workout.isCurrentWorkout {
            let exercises = (workout.workoutExercises?.array as? [WorkoutExercise] ?? []).compactMap { exercise -> TrainingExerciseSnapshot? in
                let sets = (exercise.workoutSets?.array as? [WorkoutSet] ?? []).filter(\.isCompleted)
                guard !sets.isEmpty else { return nil }
                let preferred = exercise.trackingType(catalogExercise: exercise.exerciseUuid.flatMap { catalog[$0] })
                let volume = sets.reduce(0.0) { sum, set in
                    let type = SetTrackingType.resolved(preferred, from: set.trackingData)
                    return sum + type.volume(weight: set.weightValue, reps: Int(set.repetitionsValue))
                }
                return TrainingExerciseSnapshot(id: exercise.objectID, uuid: exercise.exerciseUuid,
                    setCount: sets.count, repetitions: sets.reduce(0) { $0 + Int($1.repetitionsValue) }, volume: volume)
            }
            guard !exercises.isEmpty else { continue }
            let date = workout.start ?? .distantPast
            let session = TrainingSessionSnapshot(id: workout.objectID, date: date, title: workout.title,
                duration: max(0, workout.duration ?? 0), setCount: exercises.reduce(0) { $0 + $1.setCount },
                repetitions: exercises.reduce(0) { $0 + $1.repetitions }, volume: exercises.reduce(0) { $0 + $1.volume },
                effort: workout.sessionEffortValue, exercises: exercises)
            result.sessions.append(session)
            if let week = calendar.dateInterval(of: .weekOfYear, for: date) { result.trainedWeeks.insert(week.start) }
            result.byDay[calendar.startOfDay(for: date), default: []].append(session)
            // Count a workout once even if the same exercise appears twice.
            for (uuid, entries) in Dictionary(grouping: exercises.compactMap { entry in entry.uuid.map { ($0, entry) } }, by: { $0.0 }) {
                var total = result.exerciseTotals[uuid, default: TrainingExerciseTotals()]
                total.sessions += 1
                total.sets += entries.reduce(0) { $0 + $1.1.setCount }
                total.lastTrained = max(total.lastTrained, date)
                result.exerciseTotals[uuid] = total
            }
        }
        result.sessions.sort { $0.date > $1.date }
        result.recordSetIDs = TrainingRecordIndex.recordSetIDs(in: workouts.filter { !$0.isCurrentWorkout })
        return result
    }
}

/// One debounced background history read shared by Home, History and day recaps.
/// No history traversal, Core Data faulting or catalog search runs from a view body.
@MainActor final class TrainingHistoryStore: ObservableObject {
    static let shared = TrainingHistoryStore()
    @Published private(set) var snapshot = TrainingHistorySnapshot()
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private var context: NSManagedObjectContext?
    private var observers: Set<AnyCancellable> = []
    private var refreshPending = false

    func observe(in source: NSManagedObjectContext) {
        guard let coordinator = source.persistentStoreCoordinator,
              context?.persistentStoreCoordinator !== coordinator else { return }
        let reader = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        reader.persistentStoreCoordinator = coordinator
        reader.undoManager = nil
        context = reader
        observers.removeAll()
        NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)
            .filter { notification in
                guard (notification.object as? NSManagedObjectContext)?.persistentStoreCoordinator === coordinator else { return false }
                let entities: Set<String> = ["Workout", "WorkoutExercise", "WorkoutSet"]
                return [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey].contains { key in
                    (notification.userInfo?[key] as? Set<NSManagedObject>)?.contains { entities.contains($0.entity.name ?? "") } ?? false
                }
            }
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &observers)
        NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .merge(with: NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &observers)
        // Peer merges save silently, so observe the persisted value as well as
        // local edits. Ignore unrelated defaults writes to avoid history rescans.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: UserDefaults.standard)
            .merge(with: NotificationCenter.default.publisher(for: SetTrackingPreferences.didChangeNotification, object: UserDefaults.standard))
            .map { _ in UserDefaults.standard.data(forKey: SetTrackingPreferences.storageKey) }
            .prepend(UserDefaults.standard.data(forKey: SetTrackingPreferences.storageKey))
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &observers)
        refresh()
    }

    func refresh() {
        guard let context else { return }
        guard !isLoading else { refreshPending = true; return }
        isLoading = true
        // Capture the catalog on the main actor; the background context must
        // not read the observable exercise store while it is being updated.
        let catalog = ExerciseStore.shared.exercisesByUUID
        Task {
            do {
                let value = try await context.perform {
                    defer { context.reset() }
                    let request = Workout.fetchRequest()
                    request.predicate = NSPredicate(format: "isCurrentWorkout != YES")
                    request.sortDescriptors = [NSSortDescriptor(key: "start", ascending: false)]
                    request.relationshipKeyPathsForPrefetching = ["workoutExercises", "workoutExercises.workoutSets"]
                    return TrainingHistorySnapshot.build(from: try context.fetch(request), catalog: catalog)
                }
                snapshot = value
                error = nil
            } catch { self.error = error.localizedDescription }
            isLoading = false
            if refreshPending { refreshPending = false; refresh() }
        }
    }
}

/// Pareto comparisons for lifting records; scalar metrics use the first value
/// with a zero second value so reps, meters and seconds never mix dimensions.
private struct TrainingRecordFrontier {
    private var pairs: [SetTrackingType.PersonalRecordMeasurement] = []

    func dominates(_ value: SetTrackingType.PersonalRecordMeasurement) -> Bool {
        pairs.contains { $0.dominates(value) }
    }

    mutating func insert(_ value: SetTrackingType.PersonalRecordMeasurement) {
        guard !dominates(value) else { return }
        pairs.removeAll { value.dominates($0) }
        pairs.append(value)
    }
}

private enum TrainingRecordIndex {
    private static func measurement(for set: WorkoutSet, preferred: SetTrackingType) -> (key: String, value: SetTrackingType.PersonalRecordMeasurement)? {
        let data = set.trackingData
        let type = SetTrackingType.resolved(preferred, from: data)
        if type.usesWeight, set.weight == nil { return nil }
        if type.usesReps, set.repetitions == nil { return nil }
        guard let value = type.personalRecordMeasurement(from: data) else { return nil }
        return (type.rawValue, value)
    }

    static func recordSetIDs(in workouts: [Workout]) -> Set<NSManagedObjectID> {
        var records: Set<NSManagedObjectID> = []
        var trained: Set<String> = []
        var previous: [String: TrainingRecordFrontier] = [:]
        let dated = Dictionary(grouping: workouts.filter { $0.start != nil }, by: { $0.start! })
        // The model resolves every row using its UUID override (or weight/reps),
        // independent of catalog metadata and other rows in this exercise.
        let overrides = SetTrackingPreferences.load().overrides

        // Workouts sharing a start are peers, never each other's prior history.
        for date in dated.keys.sorted() {
            let batch = dated[date] ?? []
            for workout in batch {
                for exercise in workout.workoutExercises?.array as? [WorkoutExercise] ?? [] {
                    guard let uuid = exercise.exerciseUuid else { continue }
                    let preferred = overrides[uuid.uuidString]?.type ?? .weightReps
                    var earlier: [String: TrainingRecordFrontier] = [:]
                    for set in exercise.workoutSets?.array as? [WorkoutSet] ?? [] {
                        guard let metric = measurement(for: set, preferred: preferred) else { continue }
                        let key = uuid.uuidString + ":" + metric.key
                        if set.isCompleted, trained.contains(key),
                           !(previous[key]?.dominates(metric.value) ?? false),
                           !(earlier[key]?.dominates(metric.value) ?? false) {
                            records.insert(set.objectID)
                        }
                        earlier[key, default: TrainingRecordFrontier()].insert(metric.value)
                    }
                }
            }
            for workout in batch {
                for exercise in workout.workoutExercises?.array as? [WorkoutExercise] ?? [] {
                    guard let uuid = exercise.exerciseUuid else { continue }
                    let preferred = overrides[uuid.uuidString]?.type ?? .weightReps
                    for set in exercise.workoutSets?.array as? [WorkoutSet] ?? [] where set.isCompleted {
                        guard let metric = measurement(for: set, preferred: preferred) else { continue }
                        let key = uuid.uuidString + ":" + metric.key
                        trained.insert(key)
                        previous[key, default: TrainingRecordFrontier()].insert(metric.value)
                    }
                }
            }
        }
        return records
    }
}
