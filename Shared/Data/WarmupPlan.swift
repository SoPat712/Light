import Foundation

/// Warm-up recommendations in the workout's display unit. No persistence or UI.
enum WarmupPlan {
    struct Recommendation: Identifiable, Hashable {
        let percentage: Double
        let weight: Double
        let repetitions: Int

        var id: String { "\(percentage)-\(weight)-\(repetitions)" }
    }

    static func recommendations(
        workingWeight: Double,
        unit: WatchWorkoutWeightUnit,
        loadout: PlateLoadout? = nil,
        inventory: PlateInventory = PlateInventory()
    ) -> [Recommendation] {
        guard workingWeight.isFinite, workingWeight > 0 else { return [] }
        let templates: [(Double, Int)] = [(0.40, 10), (0.55, 8), (0.70, 5), (0.82, 3), (0.92, 1)]
        let setup = loadout?.converted(to: unit)
        if let setup, workingWeight <= setup.baseWeight { return [] }
        let loadable = setup.map { LoadableWeights(loadout: $0, inventory: inventory) }
        var seen = Set<Double>()
        return templates.compactMap { percentage, reps in
            let raw = workingWeight * percentage
            let weight: Double
            if let setup, let loadable {
                weight = loadable.nearest(to: raw, base: setup.baseWeight, maximum: workingWeight)
            } else {
                // Preserve the phone's original algorithm, including tie rounding.
                let increment = unit == .kilogram ? 2.5 : 5.0
                let bar = unit == .kilogram ? 20.0 : 45.0
                weight = max((raw / increment).rounded() * increment, bar)
            }
            guard weight < workingWeight, seen.insert(weight).inserted else { return nil }
            return Recommendation(percentage: percentage, weight: weight, repetitions: reps)
        }
    }

    /// Available plate sizes have quarter-unit precision and unlimited quantities,
    /// as in PlateLoadSolver. A greedy solver can miss combinations (e.g. 35/25).
    /// For each remainder modulo the smallest plate, retain the lightest load.
    /// Adding the smallest plate then describes every load in that remainder.
    /// This bounds memory by plate size rather than by the working weight.
    private struct LoadableWeights {
        let step: Int
        let minimums: [Int]

        init(loadout: PlateLoadout, inventory: PlateInventory) {
            let plates = inventory.enabledPlates(for: loadout.unit).map {
                Int(($0 * Double(loadout.loadedSides.count) * 4).rounded())
            }
            guard let smallest = plates.min(), smallest > 0 else {
                step = 0
                minimums = [0]
                return
            }
            step = smallest
            var distances = [Int](repeating: .max, count: smallest)
            var visited = [Bool](repeating: false, count: smallest)
            distances[0] = 0
            for _ in 0..<smallest {
                guard let index = distances.indices.filter({ !visited[$0] }).min(by: { distances[$0] < distances[$1] }),
                      distances[index] != .max else { break }
                visited[index] = true
                for plate in plates {
                    let distance = distances[index] + plate
                    let remainder = distance % smallest
                    distances[remainder] = min(distances[remainder], distance)
                }
            }
            minimums = distances.filter { $0 != .max }
        }

        func nearest(to target: Double, base: Double, maximum: Double) -> Double {
            // An empty inventory permits only the starting weight.
            guard step > 0 else { return base }
            let cap = floor(max(0, maximum - base) * 4)
            let desired = max(0, target - base) * 4
            var best = base
            var bestDistance = abs(target - base)
            for minimum in minimums where Double(minimum) <= cap {
                let stride = Double(step)
                let last = floor((cap - Double(minimum)) / stride)
                let ideal = (desired - Double(minimum)) / stride
                for count in [floor(ideal), ceil(ideal)] {
                    let bounded = min(last, max(0, count))
                    let candidate = base + (Double(minimum) + bounded * stride) / 4
                    let distance = abs(candidate - target)
                    // Lower wins exact ties; a rounded sum must never exceed work.
                    if candidate <= maximum,
                       distance < bestDistance || (distance == bestDistance && candidate < best) {
                        best = candidate
                        bestDistance = distance
                    }
                }
            }
            return best
        }
    }
}
