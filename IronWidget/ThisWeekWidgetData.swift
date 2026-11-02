import Foundation

/// Value-only projection of Home's TrainingHistorySnapshot. Home owns completed-set
/// eligibility and volume (including imports and tracking preferences); extensions
/// must not reinterpret those using their separate process-local defaults.
struct ThisWeekWidgetHistory: Codable, Equatable {
    struct Session: Codable, Equatable {
        let date: Date
        let sets: Int
        /// Kilograms × repetitions, exactly as in Home's snapshot.
        let volume: Double
    }

    let sessions: [Session]

    func summary(at date: Date, calendar: Calendar = .current) -> ThisWeekWidgetSummary {
        let week = calendar.dateInterval(of: .weekOfYear, for: date)
        let current = sessions.filter { week?.contains($0.date) == true }
        let byDay = Dictionary(grouping: sessions, by: { calendar.startOfDay(for: $0.date) })
        let days = (0..<7).compactMap { offset -> ThisWeekWidgetSummary.Day? in
            guard let start = week?.start,
                  let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return .init(date: day, index: offset,
                         volume: byDay[calendar.startOfDay(for: day), default: []].reduce(0) { $0 + $1.volume },
                         isToday: calendar.isDate(day, inSameDayAs: date))
        }
        let trainedWeeks = Set(sessions.compactMap {
            calendar.dateInterval(of: .weekOfYear, for: $0.date)?.start
        })
        return .init(workouts: current.count, sets: current.reduce(0) { $0 + $1.sets },
                     volume: current.reduce(0) { $0 + $1.volume }, days: days,
                     streak: Self.streak(trainedWeeks: trainedWeeks, now: date, calendar: calendar))
    }

    /// Same definition as TrainingHistorySnapshot.streak: an untrained current
    /// week is a grace week; the first missing previous week ends the streak.
    /// The parity test pins this to Home without changing its lane-owned source.
    static func streak(trainedWeeks: Set<Date>, now: Date, calendar: Calendar) -> Int {
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

    static func nextMidnight(after date: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
            ?? date.addingTimeInterval(60 * 60)
    }
}

struct ThisWeekWidgetSummary {
    struct Day: Identifiable {
        var id: Date { date }
        let date: Date
        let index: Int
        let volume: Double
        let isToday: Bool
    }

    let workouts: Int
    let sets: Int
    let volume: Double
    let days: [Day]
    let streak: Int

    /// There is currently no configured weekly workout target in Light.
    var workoutTarget: Int { 7 }
}

enum ThisWeekWidgetCache {
    private static var fileURL: URL? {
        // Use the real shared group, never a process-local development fallback.
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: FileManager.appGroupIdentifier)?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("ThisWeekWidget-v1.json")
    }

    static func load() -> ThisWeekWidgetHistory? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ThisWeekWidgetHistory.self, from: data)
    }

    static func save(_ history: ThisWeekWidgetHistory) throws {
        guard let url = fileURL else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(history).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static var displayUnit: UnitMass {
        let stored = UserDefaults(suiteName: FileManager.appGroupIdentifier)?.string(forKey: "weightUnit")
        let metric = stored.map { $0 == "metric" } ?? Locale.current.usesMetricSystem
        return metric ? .kilograms : .pounds
    }
}
