//
//  HomeWeekViews.swift
//  Light
//

import SwiftUI
import Charts
import WorkoutDataKit

// MARK: - Home preferences

/// The cards Home can show. Each This Week view is a card of its own, so any number of them can sit on Home together.
enum HomeSection: String, CaseIterable, Identifiable {
    case rings, pace, muscleWeek, bars, calendar, recent, muscles, body, pinned, records, nextWorkout, trainingTrend, muscleLoad

    static let cardsKey = "home.cards"
    static let defaultCards: [HomeSection] = [.rings, .calendar, .muscles, .body, .pinned]

    /// Build 71 stored one This Week style plus a section order and a hidden list.
    static let legacyStyleKey = "home.weekStyle"
    static let legacyOrderKey = "home.sectionOrder"
    static let legacyHiddenKey = "home.hiddenSections"

    var id: String { rawValue }

    /// The cards that draw this week; the first one on Home is titled This Week and shows its date range.
    var isWeekCard: Bool { [.rings, .pace, .muscleWeek, .bars].contains(self) }

    var title: String {
        switch self {
        case .rings: return "Rings"
        case .pace: return "Pace"
        case .muscleWeek: return "Muscle Week"
        case .bars: return "Daily Volume"
        case .calendar: return "Last 4 Weeks"
        case .recent: return "Recent Training"
        case .muscles: return "Muscle Focus"
        case .body: return "Body"
        case .pinned: return "Pinned Charts"
        case .records: return "Recent Records"
        case .nextWorkout: return "Next Workout"
        case .trainingTrend: return "Training Trend"
        case .muscleLoad: return "Muscle Load"
        }
    }

    var summary: String {
        switch self {
        case .rings: return "Volume, sets and workouts close as you match last week."
        case .pace: return "Your running volume against last week's line."
        case .muscleWeek: return "Which muscle groups you trained on each day."
        case .bars: return "Volume for each day of the week."
        case .calendar: return "The days you trained over the last four weeks."
        case .recent: return "Your latest workouts, ready to repeat."
        case .muscles: return "Weekly sets for each muscle group against your target."
        case .body: return "Body weight trend and measurements."
        case .pinned: return "Exercise charts you pinned."
        case .records: return "New personal records from the last 30 days."
        case .nextWorkout: return "The saved workout that's up next, ready to start."
        case .trainingTrend: return "Duration, volume or reps by week or month."
        case .muscleLoad: return "Muscles you trained over the last 7 days."
        }
    }

    var systemImage: String {
        switch self {
        case .rings: return "circle.circle"
        case .pace: return "chart.line.uptrend.xyaxis"
        case .muscleWeek: return "circle.grid.3x3"
        case .bars: return "chart.bar"
        case .calendar: return "calendar"
        case .recent: return "clock.arrow.circlepath"
        case .muscles: return "figure.strengthtraining.traditional"
        case .body: return "figure"
        case .pinned: return "pin"
        case .records: return "trophy"
        case .nextWorkout: return "list.bullet.clipboard"
        case .trainingTrend: return "chart.bar.xaxis"
        case .muscleLoad: return "figure.arms.open"
        }
    }

    /// The saved cards in order, merging Body Weight into Body before skipping unknown and repeated names.
    /// An empty string means Home has no cards.
    static func decode(_ stored: String) -> [HomeSection] {
        var seen = Set<HomeSection>()
        return stored.split(separator: ",")
            .compactMap { HomeSection(rawValue: canonicalName(String($0))) }
            .filter { seen.insert($0).inserted }
    }

    private static func canonicalName(_ name: String) -> String {
        name == "bodyWeight" ? "body" : name
    }

    static func encode<S: Sequence>(_ cards: S) -> String where S.Element == HomeSection {
        cards.map(\.rawValue).joined(separator: ",")
    }

    /// The saved cards, or the build 71 layout carried over, or the default layout.
    static func resolve(_ stored: String?, defaults: UserDefaults = .standard) -> [HomeSection] {
        if let stored { return decode(stored) }
        return migrated(
            style: defaults.string(forKey: legacyStyleKey),
            order: defaults.string(forKey: legacyOrderKey),
            hidden: defaults.string(forKey: legacyHiddenKey)
        )
    }

    /// Build 71's layout as cards: its single This Week section becomes the card for the style it showed.
    static func migrated(style: String?, order: String?, hidden: String?) -> [HomeSection] {
        guard style != nil || order != nil || hidden != nil else { return defaultCards }
        let legacy = ["week", "calendar", "recent", "muscles", "body", "pinned"]
        let hiddenNames = Set((hidden ?? "").split(separator: ",").map { canonicalName(String($0)) })
        var names = (order ?? "").split(separator: ",").map { canonicalName(String($0)) }.filter { legacy.contains($0) }
        names += legacy.filter { !names.contains($0) }
        let weekCard: HomeSection = switch style {
        case "pace": .pace
        case "muscles": .muscleWeek
        case "bars": .bars
        default: .rings
        }
        var seen = Set<HomeSection>()
        return names.filter { !hiddenNames.contains($0) }
            .compactMap { $0 == "week" ? weekCard : HomeSection(rawValue: $0) }
            .filter { seen.insert($0).inserted }
    }
}

/// The weekly sets per muscle that Muscle Focus shades.
enum WeeklySetTarget {
    static let lowKey = "home.weeklySetTargetLow"
    static let highKey = "home.weeklySetTargetHigh"
    static let defaultLow = 10
    static let defaultHigh = 20
}

/// Spoken Home metrics use full units rather than the compact chart labels.
enum HomeCardSpeech {
    static func number(_ value: Double, maximumFractionDigits: Int = 1) -> String {
        let magnitude = abs(value)
        let scale: (Double, String)
        switch magnitude {
        case 1_000_000_000...: scale = (1_000_000_000, " billion")
        case 1_000_000...: scale = (1_000_000, " million")
        case 1_000...: scale = (1_000, " thousand")
        default: scale = (1, "")
        }
        return (value / scale.0).formatted(.number.precision(.fractionLength(0...maximumFractionDigits))) + scale.1
    }

    static func count(_ value: Int, singular: String, plural: String) -> String {
        "\(number(Double(value))) \(value == 1 ? singular : plural)"
    }

    static func weightUnit(_ unit: WeightUnit) -> String {
        unit == .metric ? "kilograms" : "pounds"
    }

    static func displayWeight(_ value: Double, unit: WeightUnit) -> String {
        "\(number(value)) \(weightUnit(unit))"
    }

    static func weight(_ kilograms: Double, unit: WeightUnit) -> String {
        displayWeight(WeightUnit.convert(weight: kilograms, from: .metric, to: unit), unit: unit)
    }

    static func duration(_ seconds: TimeInterval, includesSeconds: Bool = false) -> String {
        let minutes = max(Int(seconds / 60), 0)
        let remainingSeconds = max(Int(seconds), 0) % 60
        guard minutes > 0 else {
            return includesSeconds ? count(remainingSeconds, singular: "second", plural: "seconds") : "less than 1 minute"
        }
        let hours = minutes / 60
        let remaining = minutes % 60
        return [hours > 0 ? count(hours, singular: "hour", plural: "hours") : nil,
                remaining > 0 ? count(remaining, singular: "minute", plural: "minutes") : nil,
                includesSeconds && remainingSeconds > 0 ? count(remainingSeconds, singular: "second", plural: "seconds") : nil]
            .compactMap { $0 }.joined(separator: " ")
    }
}

/// Display-only regions are one element; interactive siblings remain reachable.
struct HomeCardAccessibilitySummary: ViewModifier {
    let title: String
    let value: String
    var isSummary = false

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(value)
            .accessibilityAddTraits(isSummary ? .isSummaryElement : [])
            .accessibilitySortPriority(1)
    }
}

struct HomeCardAccessibilityContainer: ViewModifier {
    var isSingleElement = false

    func body(content: Content) -> some View {
        if isSingleElement {
            // Do not replace an existing display-only summary's ignore behavior.
            content.accessibilitySortPriority(0)
        } else {
            content.accessibilityElement(children: .contain)
        }
    }
}

// MARK: - Week summary

/// This week's training beside last week's, plus per-muscle detail, for the This Week card and Muscle Focus.
struct HomeWeekSummary {
    struct Day: Identifiable {
        var id: Date { date }
        let date: Date
        let volume: Double
        let isToday: Bool
        let isFuture: Bool
    }

    /// The groups Home tracks, in the order Muscle Week lists them. Cardio and unmapped exercises are left out.
    static let muscleGroups = ["legs", "chest", "back", "shoulders", "arms", "abdominals"]

    static func displayName(_ group: String) -> String {
        group == "abdominals" ? "Core" : group.capitalized
    }

    var days: [Day] = []
    var lastWeekVolumes = Array(repeating: 0.0, count: 7)
    var workouts = 0
    var sets = 0
    var volume = 0.0
    var duration: TimeInterval = 0
    var lastWorkouts = 0
    var lastSets = 0
    var lastVolume = 0.0
    /// Sets for each tracked group on each day of this week.
    var muscleSets: [String: [Int]] = [:]
    /// The latest session that trained each tracked group, from all history.
    var lastTrained: [String: Date] = [:]
    /// Average sets a week for each tracked group over the last four weeks.
    var weeklyAverages: [String: Double] = [:]

    var todayIndex: Int { days.firstIndex(where: \.isToday) ?? max(days.count - 1, 0) }

    init() {}

    init(sessions: [TrainingSessionSnapshot], muscleGroup: (UUID) -> String?, now: Date = Date(), calendar: Calendar = .current) {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now),
              let lastWeekStart = calendar.date(byAdding: .day, value: -7, to: week.start),
              let fourWeeksAgo = calendar.date(byAdding: .day, value: -28, to: now) else { return }
        let today = calendar.startOfDay(for: now)
        func dayIndex(_ date: Date, from start: Date) -> Int {
            calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: date)).day ?? -1
        }

        var thisWeekVolumes = Array(repeating: 0.0, count: 7)
        var recentSets: [String: Int] = [:]
        for group in Self.muscleGroups { muscleSets[group] = Array(repeating: 0, count: 7) }

        for session in sessions where session.date <= now {
            let groups = session.exercises.map { item in (item.uuid.flatMap(muscleGroup) ?? "other", item.setCount) }
            for (group, _) in groups where Self.muscleGroups.contains(group) && session.date > (lastTrained[group] ?? .distantPast) {
                lastTrained[group] = session.date
            }
            if session.date >= fourWeeksAgo {
                for (group, count) in groups { recentSets[group, default: 0] += count }
            }
            if session.date >= week.start {
                let index = dayIndex(session.date, from: week.start)
                guard (0..<7).contains(index) else { continue }
                workouts += 1
                sets += session.setCount
                volume += session.volume
                duration += session.duration
                thisWeekVolumes[index] += session.volume
                for (group, count) in groups { muscleSets[group]?[index] += count }
            } else if session.date >= lastWeekStart {
                let index = dayIndex(session.date, from: lastWeekStart)
                guard (0..<7).contains(index) else { continue }
                lastWorkouts += 1
                lastSets += session.setCount
                lastVolume += session.volume
                lastWeekVolumes[index] += session.volume
            }
        }

        days = (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: week.start) else { return nil }
            let start = calendar.startOfDay(for: date)
            return Day(date: date, volume: thisWeekVolumes[offset], isToday: start == today, isFuture: start > today)
        }
        for group in Self.muscleGroups {
            weeklyAverages[group] = Double(recentSets[group] ?? 0) / 4
        }
    }

    /// Running totals at the end of each day, starting from zero before the week begins.
    static func runningTotals(_ volumes: [Double]) -> [Double] {
        volumes.reduce(into: [0]) { $0.append(($0.last ?? 0) + $1) }
    }
}

// MARK: - A · Rings

/// Three rings that close as this week catches up with last week, the way Fitness closes Move, Exercise and Stand.
struct WeekRingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var ringSize: CGFloat = 148
    @State private var hasAppeared = false
    let summary: HomeWeekSummary
    let unit: String
    let valueLabel: (Double) -> String

    private struct Ring: Identifiable {
        let id: String
        let label: String
        let value: String
        let target: String?
        let unit: String?
        let progress: Double
        let tint: Color
        let track: Color
    }

    private var rings: [Ring] {
        [
            Ring(id: "volume", label: "Volume", value: valueLabel(summary.volume),
                 target: summary.lastVolume > 0 ? valueLabel(summary.lastVolume) : nil, unit: unit,
                 progress: progress(summary.volume, of: summary.lastVolume),
                 tint: IronTheme.metricVolume, track: IronTheme.metricVolumeContainer),
            Ring(id: "sets", label: "Sets", value: "\(summary.sets)",
                 target: summary.lastSets > 0 ? "\(summary.lastSets)" : nil, unit: nil,
                 progress: progress(Double(summary.sets), of: Double(summary.lastSets)),
                 tint: IronTheme.metricSets, track: IronTheme.metricSetsContainer),
            Ring(id: "workouts", label: summary.workouts == 1 ? "Workout" : "Workouts", value: "\(summary.workouts)",
                 target: summary.lastWorkouts > 0 ? "\(summary.lastWorkouts)" : nil, unit: nil,
                 progress: progress(Double(summary.workouts), of: Double(summary.lastWorkouts)),
                 tint: IronTheme.accent, track: IronTheme.accentSoft)
        ]
    }

    private func progress(_ value: Double, of target: Double) -> Double {
        guard target > 0 else { return value > 0 ? 1 : 0 }
        return min(value / target, 1)
    }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 20))
        VStack(alignment: .leading, spacing: 14) {
            layout {
                ringStack
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rings) { ring in
                        ringMetric(ring)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            dayStrip
        }
        .animation(IronMotion.preferred(IronMotion.collapse, reduceMotion: reduceMotion), value: hasAppeared)
        .onAppear { hasAppeared = true }
    }

    func accessibilitySummary(weightUnit: WeightUnit) -> String {
        let volume = HomeCardSpeech.weight(summary.volume, unit: weightUnit)
        let volumeTarget = summary.lastVolume > 0
            ? "Volume \(HomeCardSpeech.number(WeightUnit.convert(weight: summary.volume, from: .metric, to: weightUnit))) of \(HomeCardSpeech.weight(summary.lastVolume, unit: weightUnit))"
            : "Volume \(volume)"
        let sets = summary.lastSets > 0 ? "\(summary.sets) of \(summary.lastSets) sets" : HomeCardSpeech.count(summary.sets, singular: "set", plural: "sets")
        let workouts = summary.lastWorkouts > 0 ? "\(summary.workouts) of \(summary.lastWorkouts) workouts" : HomeCardSpeech.count(summary.workouts, singular: "workout", plural: "workouts")
        let meaning = summary.lastWorkouts > 0
            ? "Each ring closes when you match last week."
            : "Nothing was logged last week, so any training closes a ring."
        return "\(volumeTarget), \(sets), \(workouts). \(meaning)"
    }

    private var ringStack: some View {
        let size = min(ringSize, 200)
        let width = size * 0.107
        let step = width + size * 0.024
        return ZStack {
            ForEach(Array(rings.enumerated()), id: \.element.id) { index, ring in
                let diameter = size - CGFloat(index) * step * 2
                ZStack {
                    Circle()
                        .inset(by: width / 2)
                        .stroke(ring.track, lineWidth: width)
                    Circle()
                        .inset(by: width / 2)
                        .trim(from: 0, to: hasAppeared || reduceMotion ? ring.progress : 0)
                        .stroke(ring.tint, style: StrokeStyle(lineWidth: width, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: diameter, height: diameter)
            }
        }
        .frame(width: size, height: size)
    }

    private func ringMetric(_ ring: Ring) -> some View {
        let suffix = [ring.target.map { " / " + $0 }, ring.unit.map { " " + $0 }].compactMap { $0 }.joined()
        return VStack(alignment: .leading, spacing: 1) {
            Text(ring.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ring.tint)
                .textCase(.uppercase)
            (Text(ring.value).font(.ironMetric(.title2, weight: .bold)).foregroundColor(IronTheme.primaryText)
             + Text(suffix).font(.subheadline.weight(.medium)).foregroundColor(IronTheme.secondaryText))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(reduceMotion ? .opacity : .numericText())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ring.label)
        .accessibilityValue("\(ring.value)\(ring.target.map { " of \($0)" } ?? "")\(ring.unit.map { " \($0)" } ?? ""), \(Int((ring.progress * 100).rounded())) percent of last week")
    }

    private var dayStrip: some View {
        let best = summary.days.map(\.volume).max() ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                ForEach(summary.days) { day in
                    VStack(spacing: 6) {
                        Text(day.date.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption.weight(day.isToday ? .bold : .regular))
                            .foregroundStyle(day.isToday ? IronTheme.accent : IronTheme.secondaryText)
                        ZStack {
                            Circle()
                                .inset(by: 2.5)
                                .stroke(day.volume > 0 ? IronTheme.metricVolumeContainer : IronTheme.tertiaryFill, lineWidth: 5)
                            if day.volume > 0, best > 0 {
                                Circle()
                                    .inset(by: 2.5)
                                    .trim(from: 0, to: hasAppeared || reduceMotion ? day.volume / best : 0)
                                    .stroke(IronTheme.metricVolume, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                            }
                        }
                        .frame(width: 28, height: 28)
                        .opacity(day.isFuture ? 0.5 : 1)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(day.date.formatted(.dateTime.weekday(.wide)))
                    .accessibilityValue(day.volume > 0 ? "\(valueLabel(day.volume)) \(unit)" : day.isFuture ? "Upcoming" : "Rest day")
                }
            }
        }
    }
}

// MARK: - B · Pace

/// Running volume this week over last week's line, so the card says whether the week is on pace.
struct WeekPaceView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false
    let summary: HomeWeekSummary
    let unit: String
    let valueLabel: (Double) -> String

    private struct Point: Identifiable {
        var id: String { "\(series)-\(x)" }
        let series: String
        let x: Double
        let y: Double
    }

    private var thisWeek: [Double] { HomeWeekSummary.runningTotals(summary.days.map(\.volume)) }
    private var lastWeek: [Double] { HomeWeekSummary.runningTotals(summary.lastWeekVolumes) }
    private var todayEnd: Int { summary.todayIndex + 1 }

    private var points: [Point] {
        let grow = hasAppeared || reduceMotion ? 1.0 : 0.0
        let last = lastWeek.enumerated().map { Point(series: "Last week", x: Double($0.offset), y: $0.element * grow) }
        let this = thisWeek.prefix(todayEnd + 1).enumerated().map { Point(series: "This week", x: Double($0.offset), y: $0.element * grow) }
        return last + this
    }

    private var yMax: Double {
        let top = max(lastWeek.last ?? 0, thisWeek.last ?? 0)
        return top > 0 ? top * 1.1 : 1
    }

    private var weekdayName: String {
        guard summary.days.indices.contains(summary.todayIndex) else { return "" }
        return summary.days[summary.todayIndex].date.formatted(.dateTime.weekday(.wide))
    }

    /// How far ahead of or behind last week's running total this week is, at the end of the same weekday.
    private var comparison: (difference: Double, detail: String) {
        let now = thisWeek[min(todayEnd, thisWeek.count - 1)]
        let then = lastWeek[min(todayEnd, lastWeek.count - 1)]
        let difference = now - then
        guard summary.lastVolume > 0 else {
            return (abs(difference), "Nothing logged last week")
        }
        guard abs(difference) > max(then, 1) * 0.03 else {
            return (abs(difference), "even with last \(weekdayName)")
        }
        return difference > 0
            ? (difference, "ahead of last \(weekdayName)")
            : (abs(difference), "behind last \(weekdayName)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                let pace = comparison
                IronMetricValue(value: valueLabel(pace.difference), unit: unit,
                                style: .title, weight: .bold, tint: IronTheme.primaryText)
                Text(pace.detail)
                    .font(.subheadline)
                    .foregroundStyle(IronTheme.secondaryText)
            }
            .accessibilityElement(children: .combine)

            chart

            HStack(spacing: 18) {
                legendItem(dashed: false, title: "This week")
                legendItem(dashed: true, title: "Last week · \(valueLabel(summary.lastVolume)) \(unit)")
            }
            .font(.footnote)
            .foregroundStyle(IronTheme.secondaryText)
            .accessibilityHidden(true)
        }
        .animation(IronMotion.preferred(IronMotion.collapse, reduceMotion: reduceMotion), value: hasAppeared)
        .onAppear { hasAppeared = true }
    }

    private var chart: some View {
        let todayX = Double(todayEnd)
        return Chart {
            if todayX < 7 {
                RectangleMark(xStart: .value("Day", todayX), xEnd: .value("Day", 7.0))
                    .foregroundStyle(IronTheme.tertiaryFill.opacity(0.5))
            }
            ForEach(points) { point in
                LineMark(x: .value("Day", point.x), y: .value("Volume", point.y), series: .value("Week", point.series))
                    .foregroundStyle(point.series == "This week" ? IronTheme.metricVolume : IronTheme.tertiaryText)
                    .lineStyle(point.series == "This week"
                               ? StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                               : StrokeStyle(lineWidth: 2, lineJoin: .round, dash: [4, 4]))
            }
            if hasAppeared || reduceMotion, thisWeek.indices.contains(todayEnd), lastWeek.indices.contains(todayEnd) {
                RuleMark(x: .value("Day", todayX),
                         yStart: .value("Volume", lastWeek[todayEnd]),
                         yEnd: .value("Volume", thisWeek[todayEnd]))
                    .lineStyle(StrokeStyle(lineWidth: 6, lineCap: .round))
                    .foregroundStyle(IronTheme.metricVolume.opacity(0.25))
                PointMark(x: .value("Day", todayX), y: .value("Volume", thisWeek[todayEnd]))
                    .symbolSize(120)
                    .foregroundStyle(IronTheme.surface)
                PointMark(x: .value("Day", todayX), y: .value("Volume", thisWeek[todayEnd]))
                    .symbolSize(56)
                    .foregroundStyle(IronTheme.metricVolume)
            }
        }
        .chartXScale(domain: 0...7)
        .chartYScale(domain: 0...yMax)
        .ironValueAxis(.automatic(desiredCount: 3), label: valueLabel)
        .chartXAxis {
            AxisMarks(values: (0..<7).map { Double($0) + 0.5 }) { value in
                AxisValueLabel {
                    if let raw = value.as(Double.self), summary.days.indices.contains(Int(raw)) {
                        let day = summary.days[Int(raw)]
                        Text(day.date.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption.weight(day.isToday ? .bold : .regular))
                            .foregroundStyle(day.isToday ? IronTheme.accent : IronTheme.secondaryText)
                    }
                }
            }
        }
        .frame(height: 150)
    }

    func accessibilitySummary(weightUnit: WeightUnit) -> String {
        let pace = comparison
        let description = summary.lastVolume > 0
            ? "\(HomeCardSpeech.weight(pace.difference, unit: weightUnit)) \(pace.detail)"
            : pace.detail
        return "This week's running volume compared with last week. \(HomeCardSpeech.weight(summary.volume, unit: weightUnit)) so far. \(description). Last week finished at \(HomeCardSpeech.weight(summary.lastVolume, unit: weightUnit))."
    }

    private func legendItem(dashed: Bool, title: String) -> some View {
        HStack(spacing: 6) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1.5))
                path.addLine(to: CGPoint(x: 16, y: 1.5))
            }
            .stroke(dashed ? IronTheme.tertiaryText : IronTheme.metricVolume,
                    style: StrokeStyle(lineWidth: dashed ? 2 : 3, lineCap: dashed ? .butt : .round, dash: dashed ? [4, 4] : []))
            .frame(width: 16, height: 3)
            Text(title)
        }
    }
}

// MARK: - C · Muscles

/// Each tracked muscle group by day of the week, dot size showing sets, with how long since each was trained.
struct MuscleWeekGrid: View {
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 34
    @ScaledMetric(relativeTo: .subheadline) private var nameWidth: CGFloat = 84
    @ScaledMetric(relativeTo: .footnote) private var lastWidth: CGFloat = 46
    let summary: HomeWeekSummary
    var now = Date()

    private var groups: [String] { HomeWeekSummary.muscleGroups }

    private func daysSince(_ group: String) -> Int? {
        guard let date = summary.lastTrained[group] else { return nil }
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day
    }

    private func lastText(_ group: String) -> String {
        guard let days = daysSince(group), days <= 60 else { return "—" }
        return days == 0 ? "Today" : "\(days)d"
    }

    private func dotDiameter(_ sets: Int) -> CGFloat {
        min(7 * sqrt(CGFloat(sets)), rowHeight - 6)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                headerRow
                ForEach(Array(groups.enumerated()), id: \.element) { index, group in
                    row(group, isLast: index == groups.count - 1)
                }
            }

            if let insight = restedInsight {
                Text(insight)
                    .font(.subheadline)
                    .foregroundStyle(IronTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            sizeKey
        }
    }

    var accessibilitySummary: String {
        let details = groups.map { group in
            "\(HomeWeekSummary.displayName(group)): \(accessibilityValue(group, sets: summary.muscleSets[group] ?? []))"
        }.joined(separator: " ")
        return "Muscle groups trained each day this week; larger dots mean more sets. \(details)" + (restedInsight.map { " " + $0 } ?? "")
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: nameWidth, height: 1)
            ForEach(summary.days) { day in
                Text(day.date.formatted(.dateTime.weekday(.narrow)))
                    .font(.caption.weight(day.isToday ? .bold : .regular))
                    .foregroundStyle(day.isToday ? IronTheme.accent : IronTheme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 26)
                    .background(todayColumn(day, top: true, bottom: false))
            }
            Text("Last")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(IronTheme.secondaryText)
                .textCase(.uppercase)
                .frame(width: lastWidth, alignment: .trailing)
        }
        .accessibilityHidden(true)
    }

    private func row(_ group: String, isLast: Bool) -> some View {
        let sets = summary.muscleSets[group] ?? []
        let last = lastText(group)
        return HStack(spacing: 0) {
            Text(HomeWeekSummary.displayName(group))
                .font(.subheadline)
                .foregroundStyle(IronTheme.primaryText)
                .lineLimit(1)
                .frame(width: nameWidth, alignment: .leading)
            ForEach(Array(summary.days.enumerated()), id: \.element.id) { index, day in
                let count = sets.indices.contains(index) ? sets[index] : 0
                ZStack {
                    if count > 0 {
                        Circle()
                            .fill(IronTheme.metricSets)
                            .frame(width: dotDiameter(count), height: dotDiameter(count))
                    } else {
                        Circle()
                            .fill(IronTheme.tertiaryText.opacity(day.isFuture ? 0.25 : 0.5))
                            .frame(width: 4, height: 4)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: rowHeight)
                .background(todayColumn(day, top: false, bottom: isLast))
            }
            Text(last)
                .font(.footnote.weight(last == "Today" ? .semibold : .regular))
                .foregroundStyle(last == "Today" ? IronTheme.primaryText : IronTheme.secondaryText)
                .monospacedDigit()
                .frame(width: lastWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(HomeWeekSummary.displayName(group))
        .accessibilityValue(accessibilityValue(group, sets: sets))
    }

    @ViewBuilder
    private func todayColumn(_ day: HomeWeekSummary.Day, top: Bool, bottom: Bool) -> some View {
        if day.isToday {
            UnevenRoundedRectangle(
                topLeadingRadius: top ? 12 : 0, bottomLeadingRadius: bottom ? 12 : 0,
                bottomTrailingRadius: bottom ? 12 : 0, topTrailingRadius: top ? 12 : 0,
                style: .continuous
            )
            .fill(IronTheme.tertiaryFill)
        }
    }

    private func accessibilityValue(_ group: String, sets: [Int]) -> String {
        let trained = summary.days.enumerated().compactMap { index, day -> String? in
            guard sets.indices.contains(index), sets[index] > 0 else { return nil }
            return "\(sets[index]) \(sets[index] == 1 ? "set" : "sets") \(day.date.formatted(.dateTime.weekday(.wide)))"
        }
        let week = trained.isEmpty ? "No sets this week" : trained.joined(separator: ", ")
        guard let days = daysSince(group), days <= 60 else { return week + ". Not trained recently." }
        return week + ". Last trained " + (days == 0 ? "today." : "\(days) \(days == 1 ? "day" : "days") ago.")
    }

    /// Names the groups that have rested longest, so the card suggests what to train next.
    private var restedInsight: String? {
        guard !summary.lastTrained.isEmpty else { return nil }
        let rested = groups.map { ($0, daysSince($0) ?? Int.max) }
        guard let longest = rested.map(\.1).max(), longest >= 2 else { return nil }
        let names = rested.filter { $0.1 == longest }.map { HomeWeekSummary.displayName($0.0).lowercased() }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        let subject = list.prefix(1).uppercased() + list.dropFirst()
        let verb = names.count == 1 ? "is" : "are"
        guard longest <= 60 else { return "\(subject) \(verb) missing from your recent training." }
        let when: String
        if longest < 7, let group = rested.first(where: { $0.1 == longest })?.0, let date = summary.lastTrained[group] {
            when = date.formatted(.dateTime.weekday(.wide))
        } else {
            when = "\(longest) days ago"
        }
        return "\(subject) \(verb) the most rested, last trained \(when)."
    }

    @ViewBuilder
    private var sizeKey: some View {
        let counts = summary.muscleSets.values.flatMap { $0 }.filter { $0 > 0 }
        if let low = counts.min(), let high = counts.max() {
            HStack(spacing: 6) {
                Text("Dot size shows sets:")
                Circle().fill(IronTheme.metricSets).frame(width: dotDiameter(low), height: dotDiameter(low))
                Text("\(low)").monospacedDigit()
                if high != low {
                    Circle().fill(IronTheme.metricSets).frame(width: dotDiameter(high), height: dotDiameter(high))
                    Text("\(high)").monospacedDigit()
                }
            }
            .font(.footnote)
            .foregroundStyle(IronTheme.secondaryText)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - E · Weekly sets

/// Average weekly sets for each tracked muscle group over the last four weeks, against the user's target range.
struct WeeklySetsChart: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var nameWidth: CGFloat = 92
    @ScaledMetric(relativeTo: .body) private var valueWidth: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 40
    @State private var hasAppeared = false
    let averages: [String: Double]
    let target: ClosedRange<Int>

    private struct Row: Identifiable {
        var id: String { group }
        let group: String
        let sets: Double
    }

    private var rows: [Row] {
        HomeWeekSummary.muscleGroups
            .map { Row(group: $0, sets: averages[$0] ?? 0) }
            .sorted { $0.sets > $1.sets }
    }

    private var scaleMax: Double {
        max(Double(target.upperBound) * 1.2, rows.map(\.sets).max() ?? 0)
    }

    private var reaching: Int { rows.filter { $0.sets >= Double(target.lowerBound) }.count }

    static func format(_ sets: Double) -> String {
        sets.formatted(.number.precision(.fractionLength(sets == sets.rounded() ? 0 : 1)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            IronChartHeader(
                caption: "Sets per week · last 4 weeks",
                value: IronChartText.value("\(reaching) of \(rows.count)", unit: "groups", tint: IronTheme.metricSets, style: .title),
                detail: "reach \(target.lowerBound) sets a week"
            )

            VStack(spacing: 0) {
                axisRow
                ForEach(rows) { row in
                    barRow(row)
                }
            }

            HStack(spacing: 18) {
                HStack(spacing: 6) {
                    Capsule().fill(IronTheme.metricSets).frame(width: 14, height: 8)
                    Text("Your weekly average")
                }
                HStack(spacing: 6) {
                    bandShape.frame(width: 14, height: 12)
                    Text("\(target.lowerBound)–\(target.upperBound) sets")
                }
            }
            .font(.footnote)
            .foregroundStyle(IronTheme.secondaryText)
            .accessibilityHidden(true)
        }
        .animation(IronMotion.preferred(IronMotion.collapse, reduceMotion: reduceMotion), value: hasAppeared)
        .onAppear { hasAppeared = true }
    }

    private var bandShape: some View {
        Rectangle()
            .fill(IronTheme.tertiaryFill)
            .overlay(alignment: .leading) { dashedEdge }
            .overlay(alignment: .trailing) { dashedEdge }
    }

    private var dashedEdge: some View {
        Path { path in
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 0, y: 1000))
        }
        .stroke(IronTheme.outline, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        .frame(width: 1)
        .clipped()
    }

    private var axisRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: nameWidth, height: 1)
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .topLeading) {
                    Text("0")
                    Text("\(target.lowerBound)")
                        .position(x: width * Double(target.lowerBound) / scaleMax, y: 7)
                    Text("\(target.upperBound)")
                        .position(x: width * Double(target.upperBound) / scaleMax, y: 7)
                }
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(IronTheme.secondaryText)
            }
            .frame(height: 16)
            Text("Week")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(IronTheme.secondaryText)
                .textCase(.uppercase)
                .frame(width: valueWidth, alignment: .trailing)
        }
        .accessibilityHidden(true)
    }

    private func barRow(_ row: Row) -> some View {
        HStack(spacing: 0) {
            Text(HomeWeekSummary.displayName(row.group))
                .font(.body)
                .foregroundStyle(IronTheme.primaryText)
                .lineLimit(1)
                .frame(width: nameWidth, alignment: .leading)
            GeometryReader { proxy in
                let width = proxy.size.width
                let low = width * Double(target.lowerBound) / scaleMax
                let high = width * Double(target.upperBound) / scaleMax
                ZStack(alignment: .leading) {
                    bandShape
                        .frame(width: high - low)
                        .offset(x: low)
                    Capsule()
                        .fill(IronTheme.metricSets)
                        .frame(width: hasAppeared || reduceMotion ? max(width * row.sets / scaleMax, row.sets > 0 ? 8 : 0) : 0, height: 8)
                }
                .frame(width: width, height: proxy.size.height, alignment: .leading)
            }
            .frame(height: rowHeight)
            Text(Self.format(row.sets))
                .font(.ironMetric(.body, weight: .semibold))
                .foregroundStyle(IronTheme.primaryText)
                .frame(width: valueWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(HomeWeekSummary.displayName(row.group))
        .accessibilityValue("\(Self.format(row.sets)) sets a week, \(row.sets < Double(target.lowerBound) ? "below" : row.sets > Double(target.upperBound) ? "above" : "within") your \(target.lowerBound) to \(target.upperBound) target")
    }
}

// MARK: - Customize Home

/// Fitness-style Edit Summary for Home: the cards on Home in order, the cards that can be added, and the weekly set target.
struct CustomizeHomeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(HomeSection.cardsKey) private var storedCards: String?
    @AppStorage(WeeklySetTarget.lowKey) private var targetLow = WeeklySetTarget.defaultLow
    @AppStorage(WeeklySetTarget.highKey) private var targetHigh = WeeklySetTarget.defaultHigh

    private var cards: [HomeSection] { HomeSection.resolve(storedCards) }
    private var available: [HomeSection] { HomeSection.allCases.filter { !cards.contains($0) } }

    private func update(_ change: (inout [HomeSection]) -> Void) {
        var updated = cards
        change(&updated)
        withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) {
            storedCards = HomeSection.encode(updated)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(cards) { card in
                        cardLabel(card)
                    }
                    .onMove { source, destination in update { $0.move(fromOffsets: source, toOffset: destination) } }
                    .onDelete { offsets in update { $0.remove(atOffsets: offsets) } }
                } header: {
                    Text("On Home")
                } footer: {
                    Text(cards.isEmpty
                         ? "Add a card below to fill Home."
                         : "Drag to change the order.")
                }

                if !available.isEmpty {
                    Section {
                        // Row IDs differ from On Home's, so an added card arrives as a new editable row
                        // rather than this row moved across, which would keep its non-editable cell.
                        ForEach(available, id: \.addRowID) { card in
                            Button {
                                update { $0.append(card) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(IronTheme.success)
                                    cardLabel(card)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Add \(card.title)")
                            .accessibilityHint(card.summary)
                        }
                    } header: {
                        Text("Add to Home")
                    }
                }

                Section {
                    Stepper(value: $targetLow, in: 1...max(1, targetHigh - 1)) {
                        LabeledContent("At Least", value: "\(targetLow) sets")
                    }
                    Stepper(value: $targetHigh, in: min(targetLow + 1, 60)...60) {
                        LabeledContent("At Most", value: "\(targetHigh) sets")
                    }
                } header: {
                    Text("Weekly Sets per Muscle")
                } footer: {
                    Text("Muscle Focus shades this range. Many lifters aim for 10–20 sets a week per muscle.")
                }

                Section {
                    Button("Restore Default Layout") {
                        update { $0 = HomeSection.defaultCards }
                    }
                    .buttonStyle(.borderless)
                    .disabled(cards == HomeSection.defaultCards)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Customize Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func cardLabel(_ card: HomeSection) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .foregroundStyle(IronTheme.primaryText)
                Text(card.summary)
                    .font(.footnote)
                    .foregroundStyle(IronTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
        } icon: {
            Image(systemName: card.systemImage)
                .foregroundStyle(IronTheme.accent)
        }
    }
}

private extension HomeSection {
    var addRowID: String { "add." + rawValue }
}
