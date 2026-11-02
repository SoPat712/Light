//
//  HomeWeekViews.swift
//  Light
//

import SwiftUI
import Charts
import WorkoutDataKit

// MARK: - Home preferences

/// How the This Week card draws the week. Chosen from the card's menu or Customize Home.
enum HomeWeekStyle: String, CaseIterable, Identifiable {
    case rings, pace, muscles, bars

    static let storageKey = "home.weekStyle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rings: return "Rings"
        case .pace: return "Pace"
        case .muscles: return "Muscles"
        case .bars: return "Bars"
        }
    }

    var summary: String {
        switch self {
        case .rings: return "Volume, sets and workouts close as you match last week."
        case .pace: return "Your running volume against last week's line."
        case .muscles: return "Which muscle groups you trained on each day."
        case .bars: return "Volume for each day of the week."
        }
    }

    var systemImage: String {
        switch self {
        case .rings: return "circle.circle"
        case .pace: return "chart.line.uptrend.xyaxis"
        case .muscles: return "circle.grid.3x3"
        case .bars: return "chart.bar"
        }
    }
}

/// The sections Home can show, stored as the user arranged them.
enum HomeSection: String, CaseIterable, Identifiable {
    case week, calendar, recent, muscles, body, pinned

    static let orderKey = "home.sectionOrder"
    static let hiddenKey = "home.hiddenSections"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: return "This Week"
        case .calendar: return "Last 4 Weeks"
        case .recent: return "Recent Training"
        case .muscles: return "Muscle Focus"
        case .body: return "Body"
        case .pinned: return "Pinned Charts"
        }
    }

    /// The stored order, then any section added since the user last arranged Home.
    static func ordered(_ stored: String) -> [HomeSection] {
        var seen = Set<HomeSection>()
        let saved = stored.split(separator: ",")
            .compactMap { HomeSection(rawValue: String($0)) }
            .filter { seen.insert($0).inserted }
        return saved + allCases.filter { !seen.contains($0) }
    }

    static func hidden(_ stored: String) -> Set<HomeSection> {
        Set(stored.split(separator: ",").compactMap { HomeSection(rawValue: String($0)) })
    }

    static func encode<S: Sequence>(_ sections: S) -> String where S.Element == HomeSection {
        sections.map(\.rawValue).joined(separator: ",")
    }
}

/// The weekly sets per muscle that Muscle Focus shades.
enum WeeklySetTarget {
    static let lowKey = "home.weeklySetTargetLow"
    static let highKey = "home.weeklySetTargetHigh"
    static let defaultLow = 10
    static let defaultHigh = 20
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

            Text(summary.lastWorkouts > 0
                 ? "Each ring closes when you match last week."
                 : "Nothing was logged last week, so any training closes a ring.")
                .font(.footnote)
                .foregroundStyle(IronTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            dayStrip
        }
        .animation(IronMotion.preferred(IronMotion.collapse, reduceMotion: reduceMotion), value: hasAppeared)
        .onAppear { hasAppeared = true }
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

            if best > 0, let top = summary.days.first(where: { $0.volume == best }) {
                (Text("Best day \(top.date.formatted(.dateTime.weekday(.wide))) · ")
                 + Text(valueLabel(top.volume))
                    .font(.ironMetric(.footnote, weight: .semibold))
                    .foregroundColor(IronTheme.metricVolume)
                 + Text(" \(unit)").font(.caption).foregroundColor(IronTheme.secondaryText))
                    .font(.footnote)
                    .foregroundStyle(IronTheme.secondaryText)
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
    private var comparison: (text: String, symbol: String?, tint: Color) {
        let now = thisWeek[min(todayEnd, thisWeek.count - 1)]
        let then = lastWeek[min(todayEnd, lastWeek.count - 1)]
        guard summary.lastVolume > 0 else {
            return ("Nothing logged last week", nil, IronTheme.secondaryText)
        }
        let difference = now - then
        guard abs(difference) > max(then, 1) * 0.03 else {
            return ("Level with last \(weekdayName)", "equal", IronTheme.secondaryText)
        }
        let amount = "\(valueLabel(abs(difference))) \(unit)"
        return difference > 0
            ? ("\(amount) ahead of last \(weekdayName)", "arrow.up", IronTheme.metricVolume)
            : ("\(amount) behind last \(weekdayName)", "arrow.down", IronTheme.secondaryText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                IronChartHeader(
                    caption: "Volume so far",
                    value: IronChartText.value(valueLabel(summary.volume), unit: unit, tint: IronTheme.metricVolume, style: .title)
                )
                let pace = comparison
                Label {
                    Text(pace.text)
                } icon: {
                    if let symbol = pace.symbol { Image(systemName: symbol) }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(pace.tint)
                .labelStyle(.titleAndIcon)
            }

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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Running volume this week against last week")
        .accessibilityValue("\(valueLabel(summary.volume)) \(unit) so far. \(comparison.text). Last week finished at \(valueLabel(summary.lastVolume)) \(unit).")
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

/// Fitness-style editor for Home: the This Week style, the weekly set target, and which sections show.
struct CustomizeHomeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(HomeWeekStyle.storageKey) private var weekStyle = HomeWeekStyle.rings.rawValue
    @AppStorage(HomeSection.orderKey) private var storedOrder = ""
    @AppStorage(HomeSection.hiddenKey) private var storedHidden = ""
    @AppStorage(WeeklySetTarget.lowKey) private var targetLow = WeeklySetTarget.defaultLow
    @AppStorage(WeeklySetTarget.highKey) private var targetHigh = WeeklySetTarget.defaultHigh

    private var shownCount: Int { HomeSection.allCases.count - HomeSection.hidden(storedHidden).count }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("This Week", selection: $weekStyle) {
                        ForEach(HomeWeekStyle.allCases) { style in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(style.title)
                                        .foregroundStyle(IronTheme.primaryText)
                                    Text(style.summary)
                                        .font(.footnote)
                                        .foregroundStyle(IronTheme.secondaryText)
                                }
                            } icon: {
                                Image(systemName: style.systemImage)
                            }
                            .tag(style.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("This Week")
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
                    NavigationLink {
                        HomeSectionsEditor()
                    } label: {
                        LabeledContent("Sections", value: "\(shownCount) of \(HomeSection.allCases.count) shown")
                    }
                } footer: {
                    Text("Choose which sections appear on Home and in what order.")
                }
            }
            .navigationTitle("Customize Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Show, hide and reorder Home's sections.
struct HomeSectionsEditor: View {
    @AppStorage(HomeSection.orderKey) private var storedOrder = ""
    @AppStorage(HomeSection.hiddenKey) private var storedHidden = ""

    private var order: [HomeSection] { HomeSection.ordered(storedOrder) }
    private var hidden: Set<HomeSection> { HomeSection.hidden(storedHidden) }

    var body: some View {
        List {
            Section {
                ForEach(order) { section in
                    let isShown = !hidden.contains(section)
                    Button {
                        var updated = hidden
                        if isShown { updated.insert(section) } else { updated.remove(section) }
                        storedHidden = HomeSection.encode(HomeSection.allCases.filter { updated.contains($0) })
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: isShown ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isShown ? IronTheme.accent : IronTheme.tertiaryText)
                            Text(section.title)
                                .foregroundStyle(IronTheme.primaryText)
                        }
                    }
                    .accessibilityValue(isShown ? "Shown" : "Hidden")
                    .accessibilityHint(isShown ? "Hides this section from Home" : "Shows this section on Home")
                }
                .onMove { source, destination in
                    var updated = order
                    updated.move(fromOffsets: source, toOffset: destination)
                    storedOrder = HomeSection.encode(updated)
                }
            } footer: {
                Text("Tap a section to show or hide it. Drag to change the order.")
            }

            Section {
                Button("Restore Default Layout") {
                    storedOrder = ""
                    storedHidden = ""
                }
                .disabled(storedOrder.isEmpty && storedHidden.isEmpty)
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Sections")
        .navigationBarTitleDisplayMode(.inline)
    }
}
