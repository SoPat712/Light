import CoreData
import Foundation

/// Canonical kilograms and immutable set values; no managed objects or fetches.
/// The history store builds these once on its reader queue, alongside History's PR index.
struct ExerciseBests {
    struct SetResult {
        let id: NSManagedObjectID
        let exerciseID: UUID
        let workoutID: NSManagedObjectID
        let date: Date
        let weight: Double
        let repetitions: Int
        let trackingType: SetTrackingType
        var duration: TimeInterval? = nil
        var distance: Double? = nil
        var isCompleted = true
        var isWarmUp = false
        var isCurrentWorkout = false

        var isEligible: Bool {
            isCompleted && !isWarmUp && !isCurrentWorkout && weight.isFinite
                && date.timeIntervalSinceReferenceDate.isFinite
        }

        var volume: Double { trackingType.volume(weight: weight, reps: repetitions) }

        /// Same Epley calculation as WorkoutSet.estimatedOneRepMax().
        /// Use scalars here: ExerciseProgressData.epleyEstimate resolves the live
        /// catalog, which must not be read from the history store's background queue.
        var estimatedOneRepMax: Double? {
            guard isCompleted, trackingType.volumeRule == .externalLoadTimesReps,
                  weight > 0, repetitions > 0 else { return nil }
            return repetitions == 1 ? weight : weight * (1 + Double(repetitions) / 30)
        }
    }

    struct Best {
        let value: Double
        let date: Date
        let workoutID: NSManagedObjectID
        let weight: Double
        let repetitions: Int

        fileprivate init(value: Double, set: SetResult) {
            self.value = value
            date = set.date
            workoutID = set.workoutID
            weight = set.weight
            repetitions = set.repetitions
        }
    }

    enum Kind: String, CaseIterable, Identifiable {
        case heaviest, estimatedOneRepMax, mostReps, sessionVolume
        var id: Self { self }

        var title: String {
            switch self {
            case .heaviest: return "Heaviest"
            case .estimatedOneRepMax: return "Best Est. 1RM"
            case .mostReps: return "Most Reps"
            case .sessionVolume: return "Best Session"
            }
        }
    }

    struct RecordEvent: Identifiable {
        enum Kind: Equatable { case heaviest, estimatedOneRepMax, set }
        let result: SetResult
        let kind: Kind
        var id: NSManagedObjectID { result.id }
        var date: Date { result.date }
        var exerciseID: UUID { result.exerciseID }
        var workoutID: NSManagedObjectID { result.workoutID }
    }

    let heaviest: Best?
    let estimatedOneRepMax: Best?
    let mostReps: Best?
    let sessionVolume: Best?

    var isEmpty: Bool { Kind.allCases.allSatisfy { self[$0] == nil } }

    subscript(kind: Kind) -> Best? {
        switch kind {
        case .heaviest: return heaviest
        case .estimatedOneRepMax: return estimatedOneRepMax
        case .mostReps: return mostReps
        case .sessionVolume: return sessionVolume
        }
    }

    /// Call with one exercise's sets. Strict improvements preserve the earliest date on ties.
    init(sets: [SetResult]) {
        let sets = sets.filter(\.isEligible).sorted(by: Self.chronological)
        func best(_ value: (SetResult) -> Double?) -> Best? {
            var result: Best?
            for set in sets {
                guard let candidate = value(set), candidate.isFinite,
                      result.map({ candidate > $0.value }) ?? true else { continue }
                result = Best(value: candidate, set: set)
            }
            return result
        }
        heaviest = best { $0.volume > 0 ? $0.weight : nil }
        estimatedOneRepMax = best { $0.estimatedOneRepMax }
        mostReps = best { $0.trackingType.usesReps && $0.repetitions > 0 ? Double($0.repetitions) : nil }

        var sessions: [NSManagedObjectID: (set: SetResult, volume: Double)] = [:]
        for set in sets where set.volume > 0 {
            let previous = sessions[set.workoutID]
            sessions[set.workoutID] = (previous?.set ?? set, (previous?.volume ?? 0) + set.volume)
        }
        sessionVolume = sessions.values
            .sorted { Self.chronological($0.set, $1.set) }
            .reduce(nil as Best?) { best, session in
                guard session.volume.isFinite,
                      best.map({ session.volume > $0.value }) ?? true else { return best }
                return Best(value: session.volume, set: session.set)
            }
    }

    /// History's Pareto rule also recognizes improved rep/load combinations and scalar records.
    /// Reuse its exact set IDs rather than creating a conflicting PR definition on Home.
    /// Warm-ups, unfinished sets and the active workout remain excluded from this surface.
    static func recordEvents(in sets: [SetResult], historyRecordSetIDs: Set<NSManagedObjectID>) -> [RecordEvent] {
        let eligible = sets.filter(\.isEligible)
        let batches = Dictionary(grouping: eligible, by: \.date)
        var heaviest: [String: Double] = [:]
        var estimates: [String: Double] = [:]
        var events: [RecordEvent] = []
        for date in batches.keys.sorted() {
            let batch = (batches[date] ?? []).sorted(by: chronological)
            // Same-date workouts are peers in History; neither supplies the other's baseline.
            for set in batch where historyRecordSetIDs.contains(set.id) {
                let key = set.exerciseID.uuidString + ":" + set.trackingType.rawValue
                let kind: RecordEvent.Kind
                if set.volume > 0, set.weight > (heaviest[key] ?? .infinity) {
                    kind = .heaviest
                } else if let estimate = set.estimatedOneRepMax, estimate > (estimates[key] ?? .infinity) {
                    kind = .estimatedOneRepMax
                } else {
                    kind = .set
                }
                events.append(RecordEvent(result: set, kind: kind))
            }
            for set in batch {
                let key = set.exerciseID.uuidString + ":" + set.trackingType.rawValue
                if set.volume > 0 { heaviest[key] = max(heaviest[key] ?? 0, set.weight) }
                if let estimate = set.estimatedOneRepMax { estimates[key] = max(estimates[key] ?? 0, estimate) }
            }
        }
        return events.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return chronological($0.result, $1.result)
        }
    }

    private static func chronological(_ lhs: SetResult, _ rhs: SetResult) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        return lhs.id.uriRepresentation().absoluteString < rhs.id.uriRepresentation().absoluteString
    }
}
