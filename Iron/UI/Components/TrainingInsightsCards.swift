//
//  TrainingInsightsCards.swift
//  Light
//

import SwiftUI
import Charts
import CoreData
import MuscleMap
import UIKit
import WorkoutDataKit

/// Home supplies the card title, surface and outer padding.
struct TrainingTrendCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.managedObjectContext) private var managedObjectContext
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var exerciseStore: ExerciseStore
    @ObservedObject private var historyStore = TrainingHistoryStore.shared
    @State private var trendMetric: HistoryTrendMetric = .duration
    @State private var selectedTimeFrame = WorkoutExerciseChartData.TimeFrame.month
    @State private var selectedPointID: Date?

    init() {}

    var body: some View {
        let points = trendPoints
        VStack(alignment: .leading, spacing: 12) {
            Picker("Metric", selection: $trendMetric) {
                ForEach(HistoryTrendMetric.allCases) { metric in Text(metric.title).tag(metric) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Training trend metric")

            VStack(alignment: .leading, spacing: 12) {
                if #available(iOS 16.0, *) {
                    HistoryTrendChart(
                        points: points, metricTitle: trendMetric.title, metricColor: trendMetric.color,
                        valueLabel: { trendMetric.axisLabel(value: $0, weightUnit: settingsStore.weightUnit) },
                        headerValue: { trendMetric.headerText(value: $0, weightUnit: settingsStore.weightUnit) },
                        axisTicks: trendMetric.axisTicks(maximum: points.map(\.value).max() ?? 0),
                        hapticsEnabled: settingsStore.workoutHaptics,
                        selectedPointID: $selectedPointID
                    )
                } else {
                    // Swift Charts starts on iOS 16; retain the totals and period values on iOS 15.
                    IronChartHeader(
                        caption: "Total",
                        value: trendMetric.headerText(value: points.reduce(0) { $0 + $1.value }, weightUnit: settingsStore.weightUnit),
                        detail: HistoryTrendPoint.summary(for: points)
                    )
                    ForEach(points) { point in
                        HStack(alignment: .firstTextBaseline) {
                            Text(point.id.formatted(.dateTime.month(.abbreviated).day()))
                                .foregroundStyle(IronTheme.secondaryText)
                            Spacer()
                            Text(trendMetric.axisLabel(value: point.value, weightUnit: settingsStore.weightUnit))
                                .font(.ironMetric(.subheadline, weight: .semibold))
                                .foregroundStyle(IronTheme.primaryText)
                        }
                        .font(.subheadline)
                    }
                }
            }
            .modifier(HomeCardAccessibilitySummary(title: HomeSection.trainingTrend.title,
                value: accessibilitySummary(points: points)))
            .accessibilityAdjustableAction { adjustSelection($0, points: points) }

            HStack {
                Text("Period").font(.subheadline).foregroundStyle(IronTheme.secondaryText)
                    .accessibilityHidden(true)
                Spacer()
                Picker("Period", selection: $selectedTimeFrame) {
                    ForEach(WorkoutExerciseChartData.TimeFrame.allCases, id: \.title) { frame in
                        Text(frame.title).tag(frame)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel("Training trend period")
            }
        }
        .accessibilityElement(children: .contain)
        .animation(IronMotion.preferred(IronMotion.fade, reduceMotion: reduceMotion), value: trendMetric)
        .onChange(of: trendMetric) { _ in selectionFeedback() }
        .onChange(of: selectedTimeFrame) { _ in
            selectedPointID = nil
            selectionFeedback()
        }
        // observe is idempotent for a persistent-store coordinator.
        .task { historyStore.observe(in: managedObjectContext) }
    }

    private func selectionFeedback() {
        if settingsStore.workoutHaptics { UISelectionFeedbackGenerator().selectionChanged() }
    }

    private func accessibilitySummary(points: [HistoryTrendPoint]) -> String {
        let grouping: String
        let period: String
        switch selectedTimeFrame {
        case .week: grouping = "day"; period = "the last 7 days"
        case .month: grouping = "week"; period = "the last 4 weeks"
        case .threeMonths: grouping = "week"; period = "the last 12 weeks"
        case .sixMonths: grouping = "month"; period = "the selected 6 months"
        case .year: grouping = "month"; period = "the selected year"
        case .all: grouping = "month"; period = "all recorded training"
        }
        let metric = trendMetric == .repetitions ? "Repetitions" : trendMetric.title
        let meaning = "\(metric) by \(grouping) for \(period)."
        let workouts = points.reduce(0) { $0 + $1.workoutCount }
        guard workouts > 0, let first = points.first, let last = points.last else {
            return meaning + " No completed workouts in this period."
        }
        let total = points.reduce(0) { $0 + $1.value }
        var result = "\(meaning) \(first.id.formatted(date: .long, time: .omitted)) through \(last.accessibilityEnd.formatted(date: .long, time: .omitted)). Total \(trendMetric.spokenValue(total, weightUnit: settingsStore.weightUnit)), \(HomeCardSpeech.count(workouts, singular: "workout", plural: "workouts"))."
        if let selected = points.first(where: { $0.id == selectedPointID }) {
            result += " Selected \(selected.accessibilityPeriod), \(trendMetric.spokenValue(selected.value, weightUnit: settingsStore.weightUnit)), \(HomeCardSpeech.count(selected.workoutCount, singular: "workout", plural: "workouts")), \(HomeCardSpeech.count(selected.sets, singular: "set", plural: "sets")), \(HomeCardSpeech.count(selected.repetitions, singular: "repetition", plural: "repetitions"))."
        }
        return result
    }

    private func adjustSelection(_ direction: AccessibilityAdjustmentDirection, points: [HistoryTrendPoint]) {
        guard !points.isEmpty else { return }
        let current = points.firstIndex { $0.id == selectedPointID } ?? (points.count - 1)
        switch direction {
        case .increment: selectedPointID = points[min(current + 1, points.count - 1)].id
        case .decrement: selectedPointID = points[max(current - 1, 0)].id
        @unknown default: break
        }
    }

    private var trendPoints: [HistoryTrendPoint] {
        let calendar = Calendar.current
        let now = Date()

        switch selectedTimeFrame {
        case .week:
            let currentDay = calendar.startOfDay(for: now)
            return (0..<7).compactMap { index in
                guard let start = calendar.date(byAdding: .day, value: index - 6, to: currentDay),
                      let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
                return trendPoint(start: start, end: end)
            }
        case .month, .threeMonths:
            let weekCount = selectedTimeFrame == .month ? 4 : 12
            let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
            return (0..<weekCount).compactMap { index in
                guard let start = calendar.date(byAdding: .weekOfYear, value: index - (weekCount - 1), to: currentWeek),
                      let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) else { return nil }
                return trendPoint(start: start, end: end)
            }
        case .sixMonths, .year, .all:
            let earliest = selectedTimeFrame.from
                ?? historyStore.snapshot.sessions.map(\.date).min()
                ?? calendar.date(byAdding: .year, value: -1, to: now)
                ?? now
            let startMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: earliest)) ?? earliest
            let currentMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
            var months: [Date] = []
            var cursor = startMonth
            while cursor <= currentMonth {
                months.append(cursor)
                guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
                cursor = next
                if months.count > 72 { break }
            }
            return months.compactMap { start in
                guard let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
                return trendPoint(start: start, end: end)
            }
        }
    }

    private func trendPoint(start: Date, end: Date) -> HistoryTrendPoint {
        let bucketWorkouts = historyStore.snapshot.sessions.filter { $0.date >= start && $0.date < end }
        let duration = bucketWorkouts.reduce(0) { $0 + $1.duration }
        let kilograms = bucketWorkouts.reduce(0) { $0 + $1.volume }
        let volume = WeightUnit.convert(weight: kilograms, from: .metric, to: settingsStore.weightUnit)
        let sets = bucketWorkouts.reduce(0) { $0 + $1.setCount }
        let repetitions = bucketWorkouts.reduce(0) { $0 + $1.repetitions }

        let value: Double
        switch trendMetric {
        case .duration:
            value = duration
        case .volume:
            value = volume
        case .repetitions:
            value = Double(repetitions)
        }

        return HistoryTrendPoint(
            id: start,
            end: end,
            value: value,
            workoutCount: bucketWorkouts.count,
            sets: sets,
            repetitions: repetitions
        )
    }
}

/// Home supplies the card title, surface and outer padding.
struct MuscleLoadCard: View {
    @Environment(\.managedObjectContext) private var managedObjectContext
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var exerciseStore: ExerciseStore
    @ObservedObject private var historyStore = TrainingHistoryStore.shared
    @State private var showingMuscleBreakdown = false

    init() {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if weeklyMuscleSets.isEmpty {
                VStack(spacing: 8) {
                    Text("No Muscle Load")
                        .font(.headline).foregroundStyle(IronTheme.primaryText)
                    Text("Complete a working set and your weekly training distribution appears here.")
                        .font(.subheadline).foregroundStyle(IronTheme.secondaryText)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .modifier(HomeCardAccessibilitySummary(title: HomeSection.muscleLoad.title, value: accessibilitySummary))
            } else {
                HStack(spacing: 8) {
                    weeklyBody(side: .front)
                    weeklyBody(side: .back)
                }
                .frame(height: 180)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
                .modifier(HomeCardAccessibilitySummary(title: HomeSection.muscleLoad.title, value: accessibilitySummary))

                Button {
                    showingMuscleBreakdown = true
                    if settingsStore.workoutHaptics { UISelectionFeedbackGenerator().selectionChanged() }
                } label: {
                    HStack {
                        Text("Muscle Breakdown")
                        Spacer()
                        Text("\(weeklyMuscleSets.count) muscles")
                            .font(.ironMetric(.subheadline, weight: .semibold))
                            .foregroundStyle(IronTheme.secondaryText)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(IronTheme.secondaryText)
                    }
                    .frame(minHeight: IronTheme.controlHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(IronTheme.accent)
                .accessibilityLabel("Muscle Breakdown")
                .accessibilityValue("\(weeklyMuscleSets.count) muscles trained")
                .accessibilityHint("Shows set counts for each trained muscle")
            }
            Text("Primary muscles trained over the last 7 days. Darker means more sets.")
                .font(.footnote)
                .foregroundStyle(IronTheme.secondaryText)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .task { historyStore.observe(in: managedObjectContext) }
        .sheet(isPresented: $showingMuscleBreakdown) {
            WeeklyMuscleBreakdownSheet(items: weeklyMuscleBreakdown)
                .modifier(MuscleBreakdownPresentation())
        }
    }

    private var accessibilitySummary: String {
        let muscles = weeklyMuscleBreakdown
        let meaning = "Primary muscles trained over the last 7 days; darker means more sets."
        guard !muscles.isEmpty else {
            return meaning + " No muscle load. Complete a working set to see your weekly training distribution."
        }
        let distribution = muscles.map { "\($0.title) \(HomeCardSpeech.count($0.sets, singular: "set", plural: "sets"))" }.joined(separator: ", ")
        return "\(meaning) \(HomeCardSpeech.count(muscles.count, singular: "muscle", plural: "muscles")) trained. \(distribution)."
    }

    private var weeklyMuscleBreakdown: [WeeklyMuscleLoad] {
        weeklyMuscleSets.map { muscle, sets in
            WeeklyMuscleLoad(
                id: String(describing: muscle),
                title: muscleTitle(muscle),
                sets: sets
            )
        }
        .sorted {
            if $0.sets == $1.sets { return $0.title < $1.title }
            return $0.sets > $1.sets
        }
    }

    private func muscleTitle(_ muscle: Muscle) -> String {
        let titles: [String: String] = [
            "abs": "Abdominals", "lowerAbs": "Lower abdominals", "obliques": "Obliques", "serratus": "Serratus",
            "biceps": "Biceps", "triceps": "Triceps", "forearm": "Forearms", "hands": "Hands",
            "deltoids": "Shoulders", "rearDeltoid": "Rear deltoids",
            "rotatorCuff": "Rotator cuff", "trapezius": "Trapezius",
            "rhomboids": "Rhomboids", "neck": "Neck", "chest": "Chest", "upperChest": "Upper chest", "upperBack": "Upper back",
            "lowerBack": "Lower back", "gluteal": "Glutes", "hamstring": "Hamstrings",
            "quadriceps": "Quadriceps", "adductors": "Adductors",
            "hipFlexors": "Hip flexors", "calves": "Calves", "tibialis": "Shins",
            "ankles": "Ankles", "feet": "Feet"
        ]
        let key = String(describing: muscle)
        return titles[key] ?? key.capitalized
    }

    private var weeklyMuscleSets: [Muscle: Int] {
        var result: [Muscle: Int] = [:]
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        for workout in historyStore.snapshot.sessions where workout.date >= start && workout.date <= now {
            for item in workout.exercises {
                guard let uuid = item.uuid, let exercise = exerciseStore.exercisesByUUID[uuid] else { continue }
                for muscle in Set(exercise.primaryMuscle.compactMap(ironMapMuscle)) {
                    result[muscle, default: 0] += item.setCount
                }
            }
        }
        return result
    }

    private var weeklyHeatmap: [MuscleIntensity] {
        let maximum = max(weeklyMuscleSets.values.max() ?? 1, 1)
        return weeklyMuscleSets.map { muscle, sets in
            MuscleIntensity(muscle: muscle, intensity: Double(sets) / Double(maximum))
        }
    }

    private func weeklyBody(side: BodySide) -> some View {
        let style = BodyViewStyle(
            defaultFillColor: IronTheme.tertiaryText.opacity(0.35),
            strokeColor: IronTheme.outline,
            strokeWidth: 0.5,
            headColor: IronTheme.tertiaryText.opacity(0.45),
            hairColor: IronTheme.tertiaryText.opacity(0.25)
        )
        let scale = HeatmapColorScale(colors: [IronTheme.accent.opacity(0.25), IronTheme.accent.opacity(0.62), IronTheme.accent])
        return BodyView(gender: .male, side: side, style: style)
            .heatmap(weeklyHeatmap, colorScale: scale)
            // This is a read-only visualization. MuscleMap's own gesture
            // handling otherwise steals vertical drags from the surrounding
            // ScrollView and makes the workout history feel unreachable.
            .allowsHitTesting(false)
    }
}

fileprivate enum HistoryTrendMetric: String, CaseIterable, Identifiable {
    case duration
    case volume
    case repetitions

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .duration: return IronTheme.metricTime
        case .volume: return IronTheme.metricVolume
        case .repetitions: return IronTheme.metricSets
        }
    }

    var title: String {
        switch self {
        case .duration: return "Duration"
        case .volume: return "Volume"
        case .repetitions: return "Reps"
        }
    }

    func headerText(value: Double, weightUnit: WeightUnit) -> Text {
        switch self {
        case .duration: return IronChartText.value(LightFormat.duration(value), tint: color)
        case .volume: return IronChartText.value(compact(value), unit: weightUnit.unit.symbol, tint: color)
        case .repetitions: return IronChartText.value("\(Int(value.rounded()))", unit: "reps", tint: color)
        }
    }

    func spokenValue(_ value: Double, weightUnit: WeightUnit) -> String {
        switch self {
        case .duration: return HomeCardSpeech.duration(value)
        case .volume: return HomeCardSpeech.displayWeight(value, unit: weightUnit)
        case .repetitions: return HomeCardSpeech.count(Int(value.rounded()), singular: "repetition", plural: "repetitions")
        }
    }

    /// Duration ticks land on whole hours (or round minutes for short spans).
    func axisTicks(maximum: Double) -> [Double]? {
        guard self == .duration, maximum > 0 else { return nil }
        let steps: [Double] = [5, 10, 15, 30, 60, 120, 180, 300, 600].map { $0 * 60 }
        let step = steps.first { maximum * 1.1 / $0 <= 4 } ?? 600 * 60
        return Array(stride(from: 0, through: maximum * 1.1, by: step))
    }

    func axisLabel(value: Double, weightUnit: WeightUnit) -> String {
        switch self {
        case .duration:
            let minutes = max(Int((value / 60).rounded()), 0)
            if minutes < 60 { return "\(minutes)m" }
            return minutes % 60 == 0 ? "\(minutes / 60)h" : String(format: "%.1fh", Double(minutes) / 60)
        case .volume:
            return "\(compact(value)) \(weightUnit.unit.symbol)"
        case .repetitions:
            return "\(Int(value.rounded()))"
        }
    }

    private func compact(_ value: Double) -> String {
        // "30k", not "30.0k".
        func short(_ scaled: Double, _ suffix: String) -> String {
            String(format: "%.1f", scaled).replacingOccurrences(of: ".0", with: "") + suffix
        }
        if value >= 1_000_000 { return short(value / 1_000_000, "M") }
        if value >= 1_000 { return short(value / 1_000, "k") }
        return String(format: "%.0f", value)
    }
}

fileprivate struct HistoryTrendPoint: Identifiable {
    let id: Date
    let end: Date
    let value: Double
    let workoutCount: Int
    let sets: Int
    let repetitions: Int

    var accessibilityEnd: Date {
        Calendar.current.date(byAdding: .day, value: -1, to: end) ?? end
    }

    var accessibilityPeriod: String {
        let start = id.formatted(date: .long, time: .omitted)
        if Calendar.current.isDate(id, inSameDayAs: accessibilityEnd) { return start }
        return "\(start) through \(accessibilityEnd.formatted(date: .long, time: .omitted))"
    }

    static func summary(for points: [Self]) -> String {
        guard let first = points.first, let last = points.last else { return "No workouts" }
        let end = Calendar.current.date(byAdding: .day, value: -1, to: last.end) ?? last.end
        let formatter = DateIntervalFormatter()
        formatter.dateTemplate = "MMMd"
        let range = formatter.string(from: first.id, to: end)
        let count = points.reduce(0) { $0 + $1.workoutCount }
        return "\(range) · \(count) workout\(count == 1 ? "" : "s")"
    }
}

@available(iOS 16.0, *)
fileprivate struct HistoryTrendChart: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let points: [HistoryTrendPoint]
    let metricTitle: String
    let metricColor: Color
    let valueLabel: (Double) -> String
    let headerValue: (Double) -> Text
    /// Explicit tick values when automatic ones read badly (durations).
    var axisTicks: [Double]? = nil
    var hapticsEnabled = true
    @Binding var selectedPointID: Date?

    @State private var hasAppeared = false

    private var selectedPoint: HistoryTrendPoint? {
        guard let selectedPointID else { return nil }
        return points.first { $0.id == selectedPointID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headline
            selectableChart
        }
    }

    @ViewBuilder
    private var headline: some View {
        let total = points.reduce(0) { $0 + $1.value }
        let header = IronChartHeader(caption: "Total", value: headerValue(total), detail: HistoryTrendPoint.summary(for: points))
        if #available(iOS 17.0, *) {
            header
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: total)
        } else {
            header
        }
    }

    @ViewBuilder
    private var selectableChart: some View {
        if #available(iOS 17.0, *) {
            chart
                .chartXSelection(value: Binding(
                    get: { selectedPoint?.id },
                    set: { newDate in
                        guard let newDate else {
                            selectedPointID = nil
                            return
                        }
                        selectedPointID = points.min {
                            abs($0.id.timeIntervalSince(newDate)) < abs($1.id.timeIntervalSince(newDate))
                        }?.id
                    }
                ))
                .ironHorizontalChartScrubbing { selectedPointID = nil }
        } else {
            chart
        }
    }

    private var chart: some View {
        Chart(points) { point in
            BarMark(
                x: .value("Period", point.id, unit: barUnit),
                y: .value(metricTitle, hasAppeared || reduceMotion ? point.value : 0)
            )
            .cornerRadius(3)
            .foregroundStyle(metricColor)
            .opacity(IronChartEmphasis.opacity(isSelected: selectedPointID == point.id, hasSelection: selectedPointID != nil))
        }
        .chartYScale(domain: 0...max((points.map(\.value).max() ?? 0) * 1.1, 1))
        .opacity(!reduceMotion || hasAppeared ? 1 : 0)
        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: hasAppeared)
        .onAppear { hasAppeared = true }
        .ironValueAxis(axisTicks.map { AxisMarkValues.stride(by: $0.count > 1 ? $0[1] - $0[0] : 1) } ?? .automatic(desiredCount: 3), label: valueLabel)
        .ironDateAxis(.automatic(desiredCount: dynamicTypeSize.isAccessibilitySize ? 2 : 4),
                      format: barUnit == .month ? .dateTime.month(.abbreviated) : .dateTime.month(.abbreviated).day())
        .frame(height: dynamicTypeSize.isAccessibilitySize ? 260 : 160)
        .animation(IronMotion.preferred(IronMotion.fade, reduceMotion: reduceMotion), value: selectedPointID)
        .onChange(of: selectedPointID) { _ in
            if hapticsEnabled { UISelectionFeedbackGenerator().selectionChanged() }
        }
        .onChange(of: points.map(\.id)) { _ in selectedPointID = nil }
    }

    private var barUnit: Calendar.Component {
        guard points.count > 1 else { return .day }
        let spacing = points[1].id.timeIntervalSince(points[0].id)
        if spacing > 60 * 60 * 24 * 20 { return .month }
        if spacing > 60 * 60 * 24 * 3 { return .weekOfYear }
        return .day
    }
}

fileprivate struct WeeklyMuscleLoad: Identifiable {
    let id: String
    let title: String
    let sets: Int
}

fileprivate struct WeeklyMuscleBreakdownSheet: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false
    @Environment(\.dismiss) private var dismiss

    let items: [WeeklyMuscleLoad]

    private var totalTargetedSets: Int {
        items.reduce(0) { $0 + $1.sets }
    }

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack { breakdownList }
        } else {
            NavigationView { breakdownList }.navigationViewStyle(.stack)
        }
    }

    private var breakdownList: some View {
        List {
            if items.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Text("No Muscle Load").font(.headline).foregroundStyle(IronTheme.primaryText)
                        Text("Complete a working set and Light will map your weekly distribution here.")
                            .font(.subheadline).foregroundStyle(IronTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .accessibilityElement(children: .combine)
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    HStack {
                        Text("Targeted Sets")
                        Spacer()
                        Text("\(totalTargetedSets)")
                            .font(.ironMetric(.body))
                            .foregroundStyle(IronTheme.metricSets)
                    }
                    .accessibilityElement(children: .combine)

                    if let leading = items.first {
                        HStack {
                            Text("Most Trained")
                            Spacer()
                            Text(leading.title).foregroundStyle(IronTheme.secondaryText)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("Last 7 Days")
                } footer: {
                    Text("A completed set counts once for every primary muscle assigned to its exercise, so targeted sets can exceed your workout set total.")
                }

                Section("Distribution") {
                    if #available(iOS 16.0, *) {
                        distributionChart
                    } else {
                        ForEach(items) { item in
                            HStack {
                                Text(item.title)
                                Spacer()
                                Text("\(item.sets) sets")
                                    .font(.ironMetric(.body, weight: .semibold))
                                    .foregroundStyle(IronTheme.secondaryText)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Muscle Breakdown")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    @available(iOS 16.0, *)
    private var distributionChart: some View {
        Chart(items) { item in
            BarMark(
                x: .value("Sets", hasAppeared || reduceMotion ? item.sets : 0),
                y: .value("Muscle", item.title)
            )
            .cornerRadius(4)
            .annotation(position: .trailing, alignment: .leading) {
                Text("\(item.sets)")
                    .font(.ironMetric(.caption2, weight: .semibold))
                    .foregroundStyle(IronTheme.secondaryText)
            }
        }
        .foregroundStyle(IronTheme.metricSets)
        .chartXScale(domain: 0...max(items.map(\.sets).max() ?? 0, 1))
        .opacity(!reduceMotion || hasAppeared ? 1 : 0)
        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: hasAppeared)
        .onAppear { hasAppeared = true }
        .chartXAxis(.hidden)
        .frame(height: CGFloat(items.count) * 26 + 12)
        .padding(.vertical, 6)
    }
}

fileprivate struct MuscleBreakdownPresentation: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        } else {
            content
        }
    }
}
