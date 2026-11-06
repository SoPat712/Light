//
//  ExerciseStatisticsView.swift
//  Iron
//
//  Created by Karim Abou Zeid on 06.07.19.
//  Rebuilt for Iron's focused exercise progress view.
//

import SwiftUI
import Charts
import CoreData
import WorkoutDataKit

struct ExerciseStatisticsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let exercise: Exercise

    @State private var selectedTimeFrame = WorkoutExerciseChartData.TimeFrame.month
    @FetchRequest private var history: FetchedResults<WorkoutExercise>

    init(exercise: Exercise) {
        self.exercise = exercise
        _history = FetchRequest(fetchRequest: WorkoutExercise.historyFetchRequest(of: exercise.uuid))
    }

    private var progress: ExerciseProgressData {
        ExerciseProgressData(exercise: exercise, workoutExercises: Array(history), settingsStore: settingsStore)
    }

    private var completedWorkoutExercises: [WorkoutExercise] {
        history.filter { session in
            (session.numberOfCompletedSets ?? 0) > 0 &&
                (selectedTimeFrame.from.map { (session.workout?.start ?? .distantPast) >= $0 } ?? true)
        }
    }

    private var completedSets: Int {
        completedWorkoutExercises.reduce(0) { $0 + ($1.numberOfCompletedSets ?? 0) }
    }

    private var lastSessionDate: Date? {
        completedWorkoutExercises.compactMap { $0.workout?.start }.max()
    }

    var body: some View {
        List {
            Section {
                Picker("Time Frame", selection: $selectedTimeFrame) {
                    ForEach(WorkoutExerciseChartData.TimeFrame.progressCases, id: \.title) { timeFrame in
                        Text(timeFrame.compactTitle).tag(timeFrame)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            } footer: {
                Text(selectedTimeFrame.subtitle)
            }

            Section("Overview") {
                LabeledContent("Sessions") {
                    Text(completedWorkoutExercises.count, format: .number)
                        .font(.ironMetric(.body))
                        .foregroundStyle(IronTheme.accent)
                        .contentTransition(reduceMotion ? .opacity : .numericText())
                }
                LabeledContent("Completed Sets") {
                    Text(completedSets, format: .number)
                        .font(.ironMetric(.body))
                        .foregroundStyle(IronTheme.metricSets)
                        .contentTransition(reduceMotion ? .opacity : .numericText())
                }
                LabeledContent(
                    "Last Trained",
                    value: lastSessionDate.map(Self.compactDateFormatter.string) ?? "—"
                )
            }

            if completedWorkoutExercises.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No Progress Yet", systemImage: "chart.line.flattrend.xyaxis")
                    } description: {
                        Text("Complete a set of this exercise and Light will chart strength, volume, sets, and reps here.")
                    } actions: {
                        if selectedTimeFrame != .all {
                            Button("Show All History") {
                                setTimeFrame(.all)
                            }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .controlSize(.large)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(progress.progressMetrics, id: \.self) { metric in
                    progressSection(metric)
                }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: IronTheme.floatingWorkoutBottomClearance - 28)
        }
        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: selectedTimeFrame)
        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: completedSets)
        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: completedWorkoutExercises.count)
    }

    private func setTimeFrame(_ timeFrame: WorkoutExerciseChartData.TimeFrame) {
        withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) {
            selectedTimeFrame = timeFrame
        }
    }

    @ViewBuilder
    private func progressSection(_ metric: ExerciseProgressMetric) -> some View {
        let points = progress.progressPoints(for: metric).filter { point in
            selectedTimeFrame.from.map { point.date >= $0 } ?? true
        }

        Section {
            if points.isEmpty {
                Text(metric.emptyMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ExerciseProgressChart(
                    points: points,
                    domainStart: selectedTimeFrame.domainStart(earliestDate: points.first?.date),
                    domainEnd: Date(),
                    valueLabel: { progress.formatted($0, for: metric) },
                    valueText: { value, style, unitStyle in
                        progress.metricText(value, for: metric, style: style, unitStyle: unitStyle)
                    },
                    color: metric.color,
                    dateLabel: { ExerciseProgressData.detailDateFormatter.string(from: $0) },
                    usesBars: metric == .totalWeight,
                    usesDayLabels: selectedTimeFrame == .month
                )
                .frame(height: 236)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))

                if let first = points.first, let latest = points.last, points.count > 1 {
                    let difference = latest.value - first.value
                    LabeledContent("Change") {
                        if abs(difference) < 0.0001 {
                            Text("No change")
                                .foregroundStyle(.secondary)
                        } else {
                            Label {
                                progress.metricText(difference, for: metric, prefix: difference > 0 ? "+" : "")
                                    .contentTransition(reduceMotion ? .opacity : .numericText())
                                    .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: difference)
                            } icon: {
                                Image(systemName: difference > 0 ? "arrow.up.right" : "arrow.down.right")
                                    .foregroundStyle(metric.color)
                            }
                        }
                    }
                }
            }
        } header: {
            Label(metric.title, systemImage: metric.icon)
                .foregroundStyle(metric.color)
        } footer: {
            Text(metric.caption)
        }
    }

    private static let compactDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

}

/// Inline progress owns chart presentation choices; session math is shared with Show All.
struct ExerciseInlineProgressView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FetchRequest private var history: FetchedResults<WorkoutExercise>
    @AppStorage("exerciseDetail.metric") private var storedSelection = Selection.oneRM.rawValue
    @AppStorage("exerciseDetail.range") private var storedRange = "3M"
    @State private var selectedPoint: ExerciseProgressPoint?

    let exercise: Exercise

    private enum Selection: String, CaseIterable {
        case oneRM = "1RM", weight = "Weight", volume = "Volume"

        var metric: ExerciseProgressMetric {
            switch self {
            case .oneRM: return .oneRM
            case .weight: return .topWeight
            case .volume: return .totalWeight
            }
        }
    }

    init(exercise: Exercise) {
        self.exercise = exercise
        _history = FetchRequest(fetchRequest: WorkoutExercise.historyFetchRequest(of: exercise.uuid))
    }

    private var selection: Selection { Selection(rawValue: storedSelection) ?? .oneRM }
    private var selectedTimeFrame: WorkoutExerciseChartData.TimeFrame {
        WorkoutExerciseChartData.TimeFrame.progressCases.first { $0.compactTitle == storedRange } ?? .threeMonths
    }
    private var progress: ExerciseProgressData {
        ExerciseProgressData(exercise: exercise, workoutExercises: Array(history), settingsStore: settingsStore)
    }
    private var completedHistory: [WorkoutExercise] {
        history.filter { ($0.numberOfCompletedSets ?? 0) > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Menu {
                    Picker("Metric", selection: Binding(
                        get: { selection }, set: { storedSelection = $0.rawValue }
                    )) {
                        ForEach(Selection.allCases, id: \.self) { metric in
                            Text(metric.rawValue).tag(metric)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(selection.metric.title)
                            .font(.title3.weight(.semibold))
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(IronTheme.accent)
                    .frame(minHeight: IronTheme.controlHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Chart metric")
                .accessibilityValue(selection.metric.title)
                Spacer(minLength: 0)
            }

            rangePills

            if completedHistory.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 28))
                        .foregroundStyle(IronTheme.secondaryText)
                    Text("No sessions yet").font(.headline).foregroundStyle(IronTheme.primaryText)
                    Text("Log this exercise in a workout and your progress will chart here.")
                        .font(.subheadline)
                        .foregroundStyle(IronTheme.secondaryText)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(24)
            } else {
                metricContent(selection.metric)
                    .id(selection)
                    .transition(.opacity)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IronTheme.surface, in: RoundedRectangle(cornerRadius: IronTheme.heroCornerRadius, style: .continuous))
        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: selection)
        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: selectedTimeFrame)
        .sensoryFeedback(.selection, trigger: selection)
        .sensoryFeedback(.selection, trigger: selectedTimeFrame)
        .onChange(of: selection) { _, _ in selectedPoint = nil }
        .onChange(of: selectedTimeFrame) { _, _ in selectedPoint = nil }
    }

    @ViewBuilder
    private func metricContent(_ metric: ExerciseProgressMetric) -> some View {
        let data = progress
        let start = selectedTimeFrame.from
        let points = data.progressPoints(for: metric).filter { point in start.map { point.date >= $0 } ?? true }
        VStack(alignment: .leading, spacing: 12) {
            if let latest = points.last {
                let displayed = selectedPoint.flatMap { selected in points.first { $0.id == selected.id } } ?? latest
                headline(displayed: displayed, first: points.first ?? latest, latest: latest, metric: metric)
                ExerciseProgressChart(
                    points: points,
                    domainStart: selectedTimeFrame.domainStart(earliestDate: points.first?.date),
                    domainEnd: Date(),
                    valueLabel: { data.formatted($0, for: metric) },
                    valueText: { data.metricText($0, for: metric, style: $1, unitStyle: $2) },
                    color: metric.color,
                    dateLabel: { ExerciseSessionDate.string(from: $0) },
                    usesBars: metric == .totalWeight,
                    usesDayLabels: selectedTimeFrame == .month,
                    showsCallout: false,
                    onSelection: { selectedPoint = $0 }
                )
                .frame(height: 154) // 140 pt plot + 14 pt x-axis band.
            } else {
                VStack(spacing: 8) {
                    Text("No data in this range")
                        .font(.headline)
                        .foregroundStyle(IronTheme.primaryText)
                    Text(metric.emptyMessage)
                        .font(.subheadline)
                        .foregroundStyle(IronTheme.secondaryText)
                        .multilineTextAlignment(.center)
                    Button("Show All History") { storedRange = "All" }
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: IronTheme.controlHeight)
                }
                .frame(maxWidth: .infinity, minHeight: 154)
            }
        }
    }

    private func headline(
        displayed: ExerciseProgressPoint, first: ExerciseProgressPoint,
        latest: ExerciseProgressPoint, metric: ExerciseProgressMetric
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 12) {
                headlineValue(displayed, metric: metric)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                if selectedPoint == nil {
                    delta(value: latest.value - first.value, metric: metric)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                headlineValue(displayed, metric: metric)
                if selectedPoint == nil {
                    delta(value: latest.value - first.value, metric: metric)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: displayed.value)
    }

    private func headlineValue(_ point: ExerciseProgressPoint, metric: ExerciseProgressMetric) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if selectedPoint != nil {
                Text(ExerciseSessionDate.string(from: point.date, relative: false))
                    .font(.footnote)
                    .foregroundStyle(IronTheme.secondaryText)
            }
            IronMetricValue(
                value: progress.valueParts(point.value, for: metric).number,
                unit: settingsStore.weightUnit.unit.symbol,
                style: .largeTitle, tint: metric.color
            )
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .contentTransition(reduceMotion ? .opacity : .numericText())
            .accessibilityElement(children: .combine)
        }
    }

    private func delta(value: Double, metric: ExerciseProgressMetric) -> some View {
        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: value < 0 ? "arrow.down" : value > 0 ? "arrow.up" : "arrow.right")
                    .font(.system(size: 11, weight: .bold))
                Text(progress.valueParts(abs(value), for: metric).number)
                    .font(.ironMetric(.subheadline, weight: .bold))
                    .contentTransition(reduceMotion ? .opacity : .numericText())
                Text(settingsStore.weightUnit.unit.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(IronTheme.secondaryText)
            }
            .foregroundStyle(value > 0 ? IronTheme.metricVolume : IronTheme.secondaryText)
            Text(rangeCaption).font(.caption).foregroundStyle(IronTheme.secondaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value > 0 ? "Up" : value < 0 ? "Down" : "Unchanged") \(progress.formatted(abs(value), for: metric)), \(rangeCaption)")
    }

    private var rangeCaption: String {
        switch selectedTimeFrame {
        case .week: return "past week"
        case .month: return "past month"
        case .threeMonths: return "past 3 months"
        case .sixMonths: return "past 6 months"
        case .year: return "past year"
        case .all: return "all time"
        }
    }

    private var rangePills: some View {
        HStack(spacing: 4) {
            ForEach(WorkoutExerciseChartData.TimeFrame.progressCases, id: \.self) { range in
                let selected = selectedTimeFrame == range
                Button { storedRange = range.compactTitle } label: {
                    Text(range.compactTitle)
                        .font(.ironMetric(.footnote, weight: selected ? .bold : .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(selected ? IronTheme.accent : IronTheme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 30)
                        .background(selected ? IronTheme.accentSoft : Color.clear, in: Capsule())
                        .frame(minHeight: IronTheme.controlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(range.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// Recent sessions remain visible independently of the chart metric and range.
struct ExerciseRecentHistorySection: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @FetchRequest private var history: FetchedResults<WorkoutExercise>

    let exercise: Exercise
    let onOpenWorkout: (Workout) -> Void
    let onShowAllHistory: () -> Void

    init(
        exercise: Exercise,
        onOpenWorkout: @escaping (Workout) -> Void,
        onShowAllHistory: @escaping () -> Void
    ) {
        self.exercise = exercise
        self.onOpenWorkout = onOpenWorkout
        self.onShowAllHistory = onShowAllHistory
        _history = FetchRequest(fetchRequest: WorkoutExercise.historyFetchRequest(of: exercise.uuid))
    }

    private var completedHistory: [WorkoutExercise] {
        history.filter { ($0.numberOfCompletedSets ?? 0) > 0 }
    }

    var body: some View {
        let points = ExerciseProgressData(
            exercise: exercise,
            workoutExercises: Array(history),
            settingsStore: settingsStore
        ).progressPoints(for: .oneRM)
        let sessions = Array(completedHistory.prefix(10))

        Section {
            if sessions.isEmpty {
                Text("Completed sets for \(exercise.title) will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(IronTheme.secondaryText)
            }

            ForEach(sessions) { session in
                let point = points.first { $0.id == ExerciseProgressData.identifier(for: session) }
                ExerciseHistorySessionRow(
                    session: session,
                    bestOneRM: point?.value,
                    isRecord: point?.isRecord ?? false,
                    onOpenWorkout: onOpenWorkout
                )
            }

            if completedHistory.count > sessions.count {
                Button(action: onShowAllHistory) {
                    HStack {
                        Text("Show All")
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(IronTheme.accent)
                    .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show All")
                .accessibilityHint("Opens all \(completedHistory.count) sessions of this exercise")
            }
        } header: {
            HStack {
                Text("History")
                Spacer(minLength: 8)
                if !sessions.isEmpty {
                    Text("Best e1RM")
                }
            }
        }
    }
}

/// Shared session calculations keep standalone and inline progress consistent.
struct ExerciseProgressData {
    let exercise: Exercise
    let workoutExercises: [WorkoutExercise]
    let settingsStore: SettingsStore

    private var completedWorkoutSets: [WorkoutSet] {
        workoutExercises.flatMap { completedSets(for: $0) }
    }

    var progressMetrics: [ExerciseProgressMetric] {
        let hasWeight = completedWorkoutSets.contains { $0.weightValue > 0 }
        let hasRepetitions = completedWorkoutSets.contains { $0.repetitionsValue > 0 }
        let hasDuration = completedWorkoutSets.contains { $0.durationValue != nil }
        let hasDistance = completedWorkoutSets.contains { $0.distanceValue != nil }
        let preferred = SetTrackingPreferences.override(for: exercise.uuid)
            ?? SetTrackingType.defaultType(name: exercise.title, equipment: exercise.equipment, category: exercise.muscleGroup)
        let isBodyweight = preferred == .assistedBodyweight || (preferred == .bodyweightReps && !hasWeight)

        if hasDistance {
            var metrics: [ExerciseProgressMetric] = [.totalDistance, .bestDistance]
            if hasDuration {
                metrics += [.totalDuration, .bestDuration]
            }
            if hasRepetitions {
                metrics.append(.totalRepetitions)
            }
            metrics.append(.totalSets)
            return metrics
        }

        if hasDuration {
            var metrics: [ExerciseProgressMetric] = [.totalDuration, .bestDuration]
            if hasRepetitions {
                metrics.append(.totalRepetitions)
            }
            metrics.append(.totalSets)
            return metrics
        }

        if isBodyweight {
            var metrics: [ExerciseProgressMetric] = []
            if hasRepetitions {
                metrics += [.bestRepetitions, .totalRepetitions]
            }
            metrics.append(.totalSets)
            return metrics
        }

        return [.oneRM, .topWeight, .totalWeight, .totalRepetitions, .totalSets]
    }

    func progressPoints(
        for metric: ExerciseProgressMetric
    ) -> [ExerciseProgressPoint] {
        let points: [ExerciseProgressPoint] = workoutExercises.compactMap { workoutExercise in
            guard let date = workoutExercise.workout?.start,
                  let value = value(for: metric, in: workoutExercise),
                  value > 0,
                  value.isFinite else { return nil }
            let identifier = Self.identifier(for: workoutExercise)
            return ExerciseProgressPoint(
                id: identifier,
                date: date,
                value: value,
                details: sessionDetails(for: workoutExercise)
            )
        }
        .sorted { $0.date < $1.date }
        // Compare with all earlier sessions, never just the visible range.
        var best: Double?
        return points.map { point in
            var point = point
            point.isRecord = best.map { point.value > $0 } ?? false
            best = max(best ?? point.value, point.value)
            return point
        }
    }

    private func sessionDetails(for workoutExercise: WorkoutExercise) -> [Text] {
        let sets = completedSets(for: workoutExercise)
        var details = [detailText(Double(sets.count), for: .totalSets) + detailUnit(sets.count == 1 ? "set" : "sets")]

        let repetitions = sets.reduce(0) { $0 + Int($1.repetitionsValue) }
        if repetitions > 0 {
            details.append(detailText(Double(repetitions), for: .totalRepetitions) + detailUnit("reps"))
        }

        let kilograms = workoutExercise.trackedCompletedVolume
        if kilograms > 0 {
            let weight = WeightUnit.convert(
                weight: kilograms,
                from: .metric,
                to: settingsStore.weightUnit
            )
            details.append(detailText(weight, for: .totalWeight))
        }

        let duration = sets.compactMap(\.durationValue).reduce(0, +)
        if duration > 0 {
            details.append(detailText(duration, for: .totalDuration))
        }

        let distance = sets.compactMap(\.distanceValue).reduce(0, +)
        if distance > 0 {
            details.append(detailText(distance, for: .totalDistance))
        }

        return Array(details.prefix(4))
    }

    func formatted(
        _ value: Double,
        for metric: ExerciseProgressMetric
    ) -> String {
        let parts = valueParts(value, for: metric)
        return parts.number + (parts.unit.map { " \($0)" } ?? "")
    }

    func metricText(
        _ value: Double,
        for metric: ExerciseProgressMetric,
        prefix: String = "",
        style: Font.TextStyle = .body,
        unitStyle: Font.TextStyle = .caption
    ) -> Text {
        let parts = valueParts(value, for: metric)
        let number = Text(prefix + parts.number)
            .font(.ironMetric(style, weight: .semibold))
            .foregroundColor(metric.color)
        guard let unit = parts.unit else { return number }
        return number + Text(" \(unit)").font(.system(unitStyle)).foregroundColor(IronTheme.secondaryText)
    }

    private func detailText(_ value: Double, for metric: ExerciseProgressMetric) -> Text {
        metricText(value, for: metric, style: .caption, unitStyle: .caption2)
    }

    private func detailUnit(_ unit: String) -> Text {
        Text(" \(unit)").font(.caption2).foregroundColor(IronTheme.secondaryText)
    }

    func valueParts(
        _ value: Double,
        for metric: ExerciseProgressMetric
    ) -> (number: String, unit: String?) {
        switch metric {
        case .totalDuration, .bestDuration:
            return (formatDuration(value), nil)
        case .totalDistance, .bestDistance:
            let parts = formatDistance(value).split(separator: " ", maxSplits: 1).map(String.init)
            return (parts[0], parts.count > 1 ? parts[1] : nil)
        case .oneRM, .topWeight, .totalWeight:
            let number = settingsStore.weightUnit.displayNumberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
            return (number, settingsStore.weightUnit.unit.symbol)
        case .totalSets, .totalRepetitions, .bestRepetitions:
            return (value.formatted(.number.precision(.fractionLength(0...1))), nil)
        }
    }

    private func value(for metric: ExerciseProgressMetric, in workoutExercise: WorkoutExercise) -> Double? {
        let sets = completedSets(for: workoutExercise)

        switch metric {
        case .oneRM:
            return sets
                .compactMap { Self.epleyEstimate(for: $0) }
                .max()
                .map {
                    WeightUnit.convert(weight: $0, from: .metric, to: settingsStore.weightUnit)
                }
        case .topWeight:
            return sets.map(\.weightValue).max().map {
                WeightUnit.convert(weight: $0, from: .metric, to: settingsStore.weightUnit)
            }
        case .totalWeight:
            return WeightUnit.convert(weight: workoutExercise.trackedCompletedVolume, from: .metric, to: settingsStore.weightUnit)
        case .totalSets:
            return Double(sets.count)
        case .totalRepetitions:
            return Double(sets.reduce(0) { $0 + Int($1.repetitionsValue) })
        case .bestRepetitions:
            return sets.map { Double($0.repetitionsValue) }.max()
        case .totalDuration:
            return sets.compactMap(\.durationValue).reduce(0, +)
        case .bestDuration:
            return sets.compactMap(\.durationValue).max()
        case .totalDistance:
            return sets.compactMap(\.distanceValue).reduce(0, +)
        case .bestDistance:
            return sets.compactMap(\.distanceValue).max()
        }
    }

    static func identifier(for session: WorkoutExercise) -> String {
        session.uuid?.uuidString ?? session.objectID.uriRepresentation().absoluteString
    }

    /// Apply the display's eligibility filters before using the model's Epley estimate.
    static func epleyEstimate(for set: WorkoutSet) -> Double? {
        guard set.isCompleted, set.trackingType.volumeRule == .externalLoadTimesReps, set.weightValue > 0,
              set.repetitionsValue > 0 else { return nil }
        return set.estimatedOneRepMax()
    }

    private func completedSets(for workoutExercise: WorkoutExercise) -> [WorkoutSet] {
        (workoutExercise.workoutSets?.array as? [WorkoutSet] ?? []).filter(\.isCompleted)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let sign = seconds < 0 ? "−" : ""
        let roundedSeconds = Int(abs(seconds).rounded())
        let hours = roundedSeconds / 3_600
        let minutes = (roundedSeconds % 3_600) / 60
        let remainingSeconds = roundedSeconds % 60
        if hours > 0 {
            return String(format: "%@%d:%02d:%02d", sign, hours, minutes, remainingSeconds)
        }
        return String(format: "%@%d:%02d", sign, minutes, remainingSeconds)
    }

    private func formatDistance(_ meters: Double) -> String {
        let sign = meters < 0 ? "−" : ""
        let absoluteMeters = abs(meters)

        switch settingsStore.weightUnit {
        case .metric:
            if absoluteMeters >= 1_000 {
                return String(format: "%@%.2f km", sign, absoluteMeters / 1_000)
            }
            return String(format: "%@%.0f m", sign, absoluteMeters)
        case .imperial:
            let miles = Measurement(value: absoluteMeters, unit: UnitLength.meters)
                .converted(to: .miles).value
            if miles >= 0.1 {
                return String(format: "%@%.2f mi", sign, miles)
            }
            let feet = Measurement(value: absoluteMeters, unit: UnitLength.meters)
                .converted(to: .feet).value
            return String(format: "%@%.0f ft", sign, feet)
        }
    }

    static let detailDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d yyyy jm")
        return formatter
    }()
}

struct ExerciseProgressPoint: Identifiable {
    let id: String
    let date: Date
    let value: Double
    let details: [Text]
    var isRecord = false
}

struct ExerciseProgressChart: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let points: [ExerciseProgressPoint]
    let domainStart: Date
    let domainEnd: Date
    let valueLabel: (Double) -> String
    let valueText: (Double, Font.TextStyle, Font.TextStyle) -> Text
    let color: Color
    let dateLabel: (Date) -> String
    var usesBars = false
    var usesDayLabels = false
    var showsCallout = true
    var onSelection: (ExerciseProgressPoint?) -> Void = { _ in }

    @State private var selectedDate: Date?
    @State private var hasAppeared = false

    /// Round tick spacing (1, 2, 2.5 or 5 × 10ⁿ) so the axis reads 120 / 140 / 160, not 78.4 / 156.8.
    private var yTickStep: Double {
        let values = points.map(\.value)
        let high = values.max() ?? 0
        let low = usesBars ? 0 : (values.min() ?? 0)
        let span = max(high - low, high * 0.1, 1)
        let rough = span / 2
        let magnitude = pow(10, floor(log10(rough)))
        let step = [1, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= rough } ?? 10 * magnitude
        return max(step, 1)
    }

    /// Bars start at zero; lines hug the data so small progress stays visible.
    private var yDomain: ClosedRange<Double> {
        let values = points.map(\.value)
        let step = yTickStep
        let high = values.max() ?? 0
        let low = usesBars ? 0 : max(0, floor(((values.min() ?? 0) - step * 0.25) / step) * step)
        let top = max(ceil((high + step * 0.25) / step) * step, low + step)
        return low...top
    }

    private var yTicks: [Double] {
        Array(stride(from: yDomain.lowerBound, through: yDomain.upperBound + 0.001, by: yTickStep))
    }

    private var chartIdentity: String {
        let start = Calendar.current.startOfDay(for: domainStart).timeIntervalSinceReferenceDate
        return "\(start)|" + points.map { "\($0.id):\($0.value)" }.joined(separator: "|")
    }

    private var selectedPoint: ExerciseProgressPoint? {
        guard let selectedDate else { return nil }
        return points.min {
            abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
        }
    }

    private var latestRecordID: String? { points.last(where: \.isRecord)?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsCallout, let shown = selectedPoint ?? points.last {
                IronChartHeader(
                    caption: selectedPoint == nil ? "Latest" : (shown.isRecord ? "Record" : "Session"),
                    value: valueText(shown.value, .title2, .subheadline),
                    detail: dateLabel(shown.date)
                )
                .contentTransition(reduceMotion ? .opacity : .numericText())
            }
            Group {
                if reduceMotion {
                    progressChart.id(chartIdentity).transition(.opacity)
                } else {
                    progressChart
                }
            }
            .opacity(reduceMotion && !hasAppeared ? 0 : 1)
        }
        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: hasAppeared)
        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: chartIdentity)
        .onChange(of: chartIdentity) { _, _ in selectedDate = nil }
        .onChange(of: selectedPoint?.id) { _, _ in onSelection(selectedPoint) }
        .sensoryFeedback(.selection, trigger: selectedPoint?.id) { _, id in id != nil }
        .task {
            withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) {
                hasAppeared = true
            }
        }
    }

    private var progressChart: some View {
        Chart {
            ForEach(points) { point in
                let opacity = selectedPoint == nil || selectedPoint?.id == point.id ? 1.0 : 0.45
                let value = usesBars && !hasAppeared && !reduceMotion ? 0 : point.value
                if usesBars {
                    // A continuous Date axis has no categorical band for ratio
                    // widths. Keep sessions visible without coarsening timestamps.
                    BarMark(x: .value("Date", point.date), y: .value("Value", value), width: .fixed(8))
                        .cornerRadius(3)
                        .foregroundStyle(color.opacity(opacity))
                } else {
                    LineMark(x: .value("Date", point.date), y: .value("Value", value))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(color.opacity(selectedPoint == nil ? 1 : IronChartEmphasis.dimmed))
                }
                if point.id == latestRecordID {
                    PointMark(x: .value("Date", point.date), y: .value("Value", value))
                        .symbol {
                            Circle().fill(IronTheme.metricRecord.opacity(0.18))
                                .frame(width: 17, height: 17)
                                .overlay {
                                    Circle().fill(IronTheme.metricRecord)
                                        .overlay(Circle().strokeBorder(IronTheme.surface, lineWidth: 1.5))
                                        .frame(width: 9, height: 9)
                                }
                                .opacity(opacity)
                        }
                } else if !usesBars {
                    PointMark(x: .value("Date", point.date), y: .value("Value", value))
                        .symbol { Circle().fill(color.opacity(opacity)).frame(width: point.id == selectedPoint?.id ? 8 : 5) }
                }
            }
            if let selectedPoint {
                IronChartSelectionRule(date: selectedPoint.date)
            }
        }
        .chartXScale(domain: domainStart...max(domainEnd, domainStart.addingTimeInterval(60)))
        .chartYScale(domain: yDomain)
        .ironValueAxis(ticks: yTicks) { $0.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }
        .ironDateAxis(.automatic(desiredCount: 4), format: usesDayLabels ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated))
        .chartPlotStyle { plot in
            plot.mask(alignment: .leading) {
                Rectangle().scaleEffect(x: usesBars || reduceMotion || hasAppeared ? 1 : 0, anchor: .leading)
            }
        }
        .chartXSelection(value: $selectedDate)
        .ironHorizontalChartScrubbing { selectedDate = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress chart with \(points.count) sessions")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Adjust to inspect the previous or next session")
        .accessibilityAdjustableAction { direction in
            guard !points.isEmpty else { return }
            let index = selectedPoint.flatMap { point in points.firstIndex { $0.id == point.id } } ?? points.count - 1
            switch direction {
            case .increment: selectedDate = points[min(index + 1, points.count - 1)].date
            case .decrement: selectedDate = points[max(index - 1, 0)].date
            @unknown default: break
            }
        }
    }

    private var accessibilityValue: String {
        guard let point = selectedPoint ?? points.last else { return "No sessions" }
        return "\(dateLabel(point.date)), \(valueLabel(point.value))\(point.isRecord ? ", personal record" : "")"
    }
}

/// UIKit's shouldBegin rejects vertical intent before recognition, including on
/// iOS 17. A vertical pan therefore stays with the enclosing List's scroll view.


enum ExerciseProgressMetric: Hashable {
    case oneRM
    case topWeight
    case totalWeight
    case totalSets
    case totalRepetitions
    case bestRepetitions
    case totalDuration
    case bestDuration
    case totalDistance
    case bestDistance

    var color: Color {
        switch self {
        case .oneRM, .topWeight: return IronTheme.accent
        case .totalWeight: return IronTheme.metricVolume
        case .totalSets, .totalRepetitions, .bestRepetitions: return IronTheme.metricSets
        case .totalDuration, .bestDuration, .totalDistance, .bestDistance: return IronTheme.metricTime
        }
    }

    var title: String {
        switch self {
        case .oneRM: return "Estimated 1RM"
        case .topWeight: return "Top weight"
        case .totalWeight: return "Volume"
        case .totalSets: return "Total Sets"
        case .totalRepetitions: return "Total Repetitions"
        case .bestRepetitions: return "Best Set Reps"
        case .totalDuration: return "Total Duration"
        case .bestDuration: return "Best Duration"
        case .totalDistance: return "Total Distance"
        case .bestDistance: return "Best Distance"
        }
    }

    var compactTitle: String {
        switch self {
        case .oneRM: return "1RM"
        case .topWeight: return "Weight"
        case .totalWeight: return "Volume"
        case .totalSets: return "Sets"
        case .totalRepetitions: return "Reps"
        case .bestRepetitions: return "Best reps"
        case .totalDuration: return "Time"
        case .bestDuration: return "Best time"
        case .totalDistance: return "Distance"
        case .bestDistance: return "Best dist."
        }
    }

    var icon: String {
        switch self {
        case .oneRM: return "bolt.fill"
        case .topWeight: return "dumbbell.fill"
        case .totalWeight: return "scalemass.fill"
        case .totalSets: return "square.stack.3d.up.fill"
        case .totalRepetitions: return "repeat"
        case .bestRepetitions: return "trophy.fill"
        case .totalDuration: return "timer"
        case .bestDuration: return "stopwatch.fill"
        case .totalDistance: return "point.topleft.down.curvedto.point.bottomright.up"
        case .bestDistance: return "flag.checkered"
        }
    }

    var caption: String {
        switch self {
        case .oneRM: return "Best Epley strength estimate per session"
        case .topWeight: return "Heaviest completed set per session"
        case .totalWeight: return "Completed volume per session"
        case .totalSets: return "Completed sets per session"
        case .totalRepetitions: return "Completed reps per session"
        case .bestRepetitions: return "Highest-rep set per session"
        case .totalDuration: return "Completed time per session"
        case .bestDuration: return "Longest completed set per session"
        case .totalDistance: return "Completed distance per session"
        case .bestDistance: return "Longest completed set per session"
        }
    }

    var emptyMessage: String {
        switch self {
        case .oneRM: return "Complete a weighted set with reps to calculate your strength trend."
        case .topWeight: return "Complete a weighted set to track your top weight."
        case .totalWeight: return "Complete a weighted set to start tracking session volume."
        case .totalSets: return "Complete a set of this exercise to start the chart."
        case .totalRepetitions: return "Complete a set with reps to start the chart."
        case .bestRepetitions: return "Complete a set with reps to track your best set."
        case .totalDuration: return "Complete a timed set to start the chart."
        case .bestDuration: return "Complete a timed set to track your longest effort."
        case .totalDistance: return "Complete a distance set to start the chart."
        case .bestDistance: return "Complete a distance set to track your longest effort."
        }
    }
}

#if DEBUG
struct ExerciseStatisticsView_Previews: PreviewProvider {
    static var previews: some View {
        ExerciseStatisticsView(exercise: ExerciseStore.shared.exercises.first(where: { $0.everkineticId == 99 })!)
            .mockEnvironment(weightUnit: .metric)
            .preferredColorScheme(.dark)
    }
}
#endif
