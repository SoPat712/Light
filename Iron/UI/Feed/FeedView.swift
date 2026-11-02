//
//  FeedView.swift
//  Sunrise Fit
//
//  Created by Karim Abou Zeid on 19.06.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import SwiftUI
import Charts
import CoreData
import Combine
import PhotosUI
import UIKit
import WorkoutDataKit

struct FeedView : View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.managedObjectContext) private var managedObjectContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject var exerciseStore: ExerciseStore
    @EnvironmentObject private var sceneState: SceneState
    @ObservedObject private var bodyMetricsStore = BodyMetricsStore.shared
    @EnvironmentObject private var pinnedChartsStore: PinnedChartsStore

    @ObservedObject private var historyStore = TrainingHistoryStore.shared
    @FetchRequest(fetchRequest: FeedView.currentWorkoutFetchRequest) private var currentWorkouts: FetchedResults<Workout>

    @State private var showingMeasurements = false
    @State private var showingChartSelector = false
    @State private var showingChartEditor = false
    @State private var showingCustomize = false
    @State private var persistenceError: String?
    @AppStorage(HomeWeekStyle.storageKey) private var weekStyleRaw = HomeWeekStyle.rings.rawValue
    @AppStorage(HomeSection.orderKey) private var sectionOrder = ""
    @AppStorage(HomeSection.hiddenKey) private var hiddenSections = ""
    @AppStorage(WeeklySetTarget.lowKey) private var setTargetLow = WeeklySetTarget.defaultLow
    @AppStorage(WeeklySetTarget.highKey) private var setTargetHigh = WeeklySetTarget.defaultHigh

    static var workoutFetchRequest: NSFetchRequest<Workout> {
        let request: NSFetchRequest<Workout> = Workout.fetchRequest()
        request.predicate = NSPredicate(format: "\(#keyPath(Workout.isCurrentWorkout)) != %@", NSNumber(booleanLiteral: true))
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Workout.start, ascending: false)]
        return request
    }

    static var currentWorkoutFetchRequest: NSFetchRequest<Workout> {
        Workout.currentWorkoutFetchRequest
    }

    private var completedWorkouts: [TrainingSessionSnapshot] { historyStore.snapshot.sessions }
    private var recentWorkouts: [TrainingSessionSnapshot] { Array(completedWorkouts.prefix(3)) }
    private var weekStyle: HomeWeekStyle { HomeWeekStyle(rawValue: weekStyleRaw) ?? .rings }
    private var trainingStreak: Int { historyStore.snapshot.streak() }

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: Date())
    }

    private func startEmptyWorkout() {
        do {
            _ = try Workout.startNew(in: managedObjectContext)
            sceneState.selectedTab = .workout
            sceneState.isCurrentWorkoutExpanded = true
        } catch {
            persistenceError = "The workout was not started. \(error.localizedDescription)"
        }
    }

    private var weekRangeText: String {
        guard let week = Calendar.current.dateInterval(of: .weekOfYear, for: Date()) else { return "" }
        let last = week.end.addingTimeInterval(-1)
        return week.start.formatted(.dateTime.month(.abbreviated).day()) + " – " + last.formatted(.dateTime.month(.abbreviated).day())
    }

    /// Fitness-style summary: the week drawn the way the user chose, and the way into a workout.
    private func weekSection(_ summary: HomeWeekSummary) -> some View {
        let unit = settingsStore.weightUnit.unit.symbol
        return Section {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center) {
                    Text("This Week")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(IronTheme.primaryText)
                    Spacer(minLength: 8)
                    Text(weekRangeText)
                        .font(.subheadline)
                        .foregroundStyle(IronTheme.secondaryText)
                    Menu {
                        Picker("Show As", selection: $weekStyleRaw) {
                            ForEach(HomeWeekStyle.allCases) { style in
                                Label(style.title, systemImage: style.systemImage).tag(style.rawValue)
                            }
                        }
                        Button("Customize Home", systemImage: "slider.horizontal.3") { showingCustomize = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .frame(minWidth: IronTheme.controlHeight, minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("This Week Options")
                    .padding(.trailing, -10)
                }

                switch weekStyle {
                case .rings:
                    WeekRingsView(summary: summary, unit: unit, valueLabel: { compactWeight($0) })
                case .pace:
                    WeekPaceView(summary: summary, unit: unit, valueLabel: { compactWeight($0) })
                    Divider()
                    weekMetrics(summary, showsTime: true)
                case .muscles:
                    weekMetrics(summary)
                    Divider()
                    MuscleWeekGrid(summary: summary)
                case .bars:
                    weekMetrics(summary)
                    WeeklyVolumeChart(
                        days: summary.days.map { DayVolume(date: $0.date, volume: $0.volume, isFuture: $0.isFuture) },
                        unit: unit,
                        valueLabel: { compactWeight($0) }
                    )
                    if let comparison = weekComparisonText(summary) {
                        comparison
                            .font(.footnote)
                            .foregroundStyle(IronTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Button {
                    if currentWorkouts.isEmpty {
                        startEmptyWorkout()
                    } else {
                        sceneState.selectedTab = .workout
                        sceneState.isCurrentWorkoutExpanded = true
                    }
                } label: {
                    Label(
                        currentWorkouts.isEmpty ? "Start Workout" : "Resume Workout",
                        systemImage: "play.fill"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
            .background(IronTheme.surface, in: RoundedRectangle(cornerRadius: IronTheme.heroCornerRadius, style: .continuous))
            .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: weekStyleRaw)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    /// Workouts, sets and volume; Pace swaps volume, already in its header, for time.
    private func weekMetrics(_ summary: HomeWeekSummary, showsTime: Bool = false) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return layout {
            weekMetric(value: "\(summary.workouts)", label: summary.workouts == 1 ? "Workout" : "Workouts",
                       tint: IronTheme.accent, index: 0)
            weekMetric(value: "\(summary.sets)", label: "Sets", tint: IronTheme.metricSets, index: 1)
            if showsTime {
                weekMetric(value: Workout.durationFormatter.string(from: summary.duration) ?? "0m", label: "Time",
                           tint: IronTheme.metricTime, index: 2)
            } else {
                weekMetric(value: compactWeight(summary.volume), label: "Volume",
                           unit: settingsStore.weightUnit.unit.symbol, tint: IronTheme.metricVolume, index: 2)
            }
        }
    }

    /// A colored label over its number, as Fitness labels Move, Exercise and Stand.
    private func weekMetric(value: String, label: String, unit: String? = nil, tint: Color, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .textCase(.uppercase)
            IronMetricValue(value: value, unit: unit, style: .title2, tint: tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ironStaggeredEntrance(index: index)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value)\(unit.map { " " + $0 } ?? "") \(label)")
    }

    private func weekComparisonText(_ summary: HomeWeekSummary) -> Text? {
        guard summary.lastVolume > 0 else { return nil }
        let change = (summary.volume - summary.lastVolume) / summary.lastVolume * 100
        guard abs(change) > 3 else {
            return Text(Image(systemName: "equal")) + Text("  Volume is about the same as last week")
        }
        let direction = change > 0 ? "up" : "down"
        let tint = change > 0 ? IronTheme.metricVolume : IronTheme.secondaryText
        return Text(Image(systemName: change > 0 ? "arrow.up.right" : "arrow.down.right")).foregroundColor(tint)
            + Text("  Volume is \(direction) ")
            + Text("\(Int(abs(change).rounded()))%")
                .font(.ironMetric(.footnote, weight: .semibold))
                .foregroundColor(tint)
            + Text(" on last week")
    }

    /// Average weekly sets per muscle group over the last four weeks against the user's target,
    /// so the user can see what they have been neglecting.
    private func muscleFocusSection(_ summary: HomeWeekSummary) -> some View {
        let target = setTargetLow...max(setTargetHigh, setTargetLow + 1)
        let trained = summary.weeklyAverages.values.contains { $0 > 0 }
        return Section {
            if trained {
                WeeklySetsChart(averages: summary.weeklyAverages, target: target)
                    .padding(.vertical, 6)
            } else {
                Text("Complete a few workouts to see how many sets each muscle group gets a week.")
                    .font(.subheadline)
                    .foregroundStyle(IronTheme.secondaryText)
            }
        } header: {
            Text("Muscle Focus")
        } footer: {
            if trained {
                Text(muscleFocusFooter(summary, target: target))
            } else {
                Text("Based on completed sets over the last 4 weeks.")
            }
        }
    }

    private func muscleFocusFooter(_ summary: HomeWeekSummary, target: ClosedRange<Int>) -> String {
        let isDefault = target == WeeklySetTarget.defaultLow...WeeklySetTarget.defaultHigh
        let guideline = isDefault
            ? "Many lifters aim for 10–20 sets a week per muscle. Change your target in Customize Home."
            : "Your target is \(target.lowerBound)–\(target.upperBound) sets a week per muscle."
        guard let lowest = HomeWeekSummary.muscleGroups.min(by: { (summary.weeklyAverages[$0] ?? 0) < (summary.weeklyAverages[$1] ?? 0) }),
              let sets = summary.weeklyAverages[lowest], sets < Double(target.lowerBound) else {
            return "Every group reaches \(target.lowerBound) sets a week. " + guideline
        }
        guard sets > 0 else {
            return "\(HomeWeekSummary.displayName(lowest)) has no sets in the last 4 weeks. " + guideline
        }
        let amount = WeeklySetsChart.format(sets)
        return "\(HomeWeekSummary.displayName(lowest)) averages \(amount) \(amount == "1" ? "set" : "sets") a week. " + guideline
    }

    private var calendarSection: some View {
        Section {
            HomeTrainingCalendar(workoutsByDay: historyStore.snapshot.byDay)
                .padding(.vertical, 6)

            NavigationLink("Open Training Calendar") {
                WorkoutCalendarView()
            }
        } header: {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Last 4 Weeks")
                    Spacer()
                    streakChip
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last 4 Weeks")
                    streakChip
                }
            }
        } footer: {
            if trainingStreak == 0 {
                Text("Train this week to start a streak.")
            } else {
                Text("\(trainingStreak)").font(.ironMetric(.footnote, weight: .semibold))
                + Text(" week streak.")
            }
        }
    }

    @ViewBuilder
    private var streakChip: some View {
        let streak = trainingStreak
        if streak >= 2 {
            Label {
                Text("\(streak)-week streak")
            } icon: {
                Image(systemName: "flame.fill")
            }
            .font(.ironMetric(.caption))
            .foregroundStyle(IronTheme.accent)
            .padding(.horizontal, 8)
            .frame(minHeight: 24)
            .background(IronTheme.accentSoft, in: Capsule())
            .textCase(nil)
            .accessibilityLabel("\(streak) week training streak")
        }
    }

    private func compactWeight(_ kilograms: Double) -> String {
        let value = WeightUnit.convert(weight: kilograms, from: .metric, to: settingsStore.weightUnit)
        return WorkoutPreviewFormatting.volume(value)
    }

    /// Body lives on Home, not in Settings: measurements are training data, not
    /// a device preference.
    private var measurementsSection: some View {
        Section {
            ForEach(homeMeasurementKinds, id: \.self) { kind in
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                    : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
                layout {
                    Text(kind.title)
                        .font(.headline)
                        .foregroundStyle(IronTheme.primaryText)
                    if !dynamicTypeSize.isAccessibilitySize {
                        Spacer(minLength: 0)
                        BodyTrendSparkline(values: recentValues(kind))
                    }
                    // Health-style: the value, with the change since the previous entry under it.
                    VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 1) {
                        measurementValue(kind)
                        if let change = measurementChange(kind) {
                            measurementChangeLabel(change)
                        }
                    }
                    .fixedSize()
                }
                .padding(.vertical, 2)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                .accessibilityElement(children: .combine)
            }

            NavigationLink("Measurements & Trends") {
                BodyMeasurementsDashboardView(store: bodyMetricsStore)
                    .environmentObject(settingsStore)
                    .ironScreen()
            }

            Button(bodyMetricsStore.entries.isEmpty ? "Log First Measurement" : "Log Measurement") {
                showingMeasurements = true
            }
        } header: {
            Text("Body")
        } footer: {
            if let latest = bodyMetricsStore.latest {
                Text("Last logged \(latest.date.formatted(.relative(presentation: .named))).")
            } else {
                Text("Weight, body fat, and tape measurements stay on this device.")
            }
        }
    }

    private var homeMeasurementKinds: [BodyMeasurementKind] {
        [.bodyWeight, .bodyFat, .waist]
    }

    private func measurementChangeLabel(_ change: Double) -> some View {
        let value = String(format: "%.1f", abs(change))
        return (Text(Image(systemName: change > 0 ? "arrow.up" : "arrow.down")) + Text(" " + value))
            .font(.ironMetric(.caption, weight: .semibold))
            .foregroundStyle(IronTheme.secondaryText)
            .accessibilityLabel("\(change > 0 ? "Up" : "Down") \(value) since the previous measurement")
    }

    @ViewBuilder
    private func measurementValue(_ kind: BodyMeasurementKind) -> some View {
        if let value = bodyMetricsStore.latestValue(for: kind) {
            let display = kind.displayValue(from: value, weightUnit: settingsStore.weightUnit)
            IronMetricValue(
                value: String(format: "%.1f", display),
                unit: kind.unitLabel(weightUnit: settingsStore.weightUnit),
                style: .body, weight: .semibold, unitStyle: .caption,
                tint: IronTheme.metricBody
            )
        } else {
            Text("—").font(.ironMetric(.body))
        }
    }

    /// Up to the last 12 entries for this kind, oldest first, for the row's sparkline.
    private func recentValues(_ kind: BodyMeasurementKind) -> [Double] {
        Array(bodyMetricsStore.entries.compactMap { $0[kind] }.prefix(12).reversed())
    }

    /// Change between the two most recent entries that recorded this kind, in
    /// display units, so the row shows direction rather than a bare number.
    private func measurementChange(_ kind: BodyMeasurementKind) -> Double? {
        let values = bodyMetricsStore.entries
            .compactMap { $0[kind] }
            .prefix(2)
        guard values.count == 2 else { return nil }
        let unit = settingsStore.weightUnit
        let change = kind.displayValue(from: values[0], weightUnit: unit)
            - kind.displayValue(from: values[1], weightUnit: unit)
        return abs(change) < 0.05 ? nil : change
    }

    private var pinnedChartsSection: some View {
        Section {
            if pinnedChartsStore.pinnedCharts.isEmpty {
                Button("Pin an Exercise Chart") { showingChartSelector = true }
            } else {
                ForEach(pinnedChartsStore.pinnedCharts, id: \.self) { chart in
                    if let exercise = exerciseStore.find(with: chart.exerciseUuid) {
                        PinnedExerciseChartRow(exercise: exercise, measurementType: chart.measurementType)
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    }
                }
            }
        } header: {
            HStack {
                Label("Pinned Charts", systemImage: "pin.fill")
                    .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : pinnedChartsStore.pinnedCharts.count)
                Spacer()
                Menu("Chart Options", systemImage: "ellipsis.circle") {
                    Button("Pin Chart", systemImage: "pin") { showingChartSelector = true }
                    if !pinnedChartsStore.pinnedCharts.isEmpty {
                        Button("Edit Pins", systemImage: "slider.horizontal.3") { showingChartEditor = true }
                    }
                }
                .labelStyle(.iconOnly)
                .textCase(nil)
            }
        }
    }

    private var recentSection: some View {
        Section("Recent Training") {
            if recentWorkouts.isEmpty {
                Text("Completed workouts build a private training timeline here.")
                    .font(.subheadline)
                    .foregroundStyle(IronTheme.secondaryText)
            } else {
                ForEach(recentWorkouts.prefix(3)) { workout in
                    NavigationLink {
                        WorkoutDetailView(workout: managedObjectContext.object(with: workout.id) as! Workout)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(workout.displayTitle(in: exerciseStore))
                                    .font(.headline)
                                    .foregroundStyle(IronTheme.primaryText)
                                    .lineLimit(2)
                                Spacer(minLength: 8)
                                Text(WorkoutPreviewFormatting.date(workout.date))
                                    .font(.subheadline)
                                    .foregroundStyle(IronTheme.secondaryText)
                            }
                            IronWorkoutMetricLine(
                                duration: Workout.durationFormatter.string(from: workout.duration) ?? "0m",
                                sets: workout.setCount,
                                volume: compactWeight(workout.volume),
                                unit: settingsStore.weightUnit.unit.symbol
                            )
                        }
                        .padding(.vertical, 2)
                    }
                }

                Button("See All History") {
                    sceneState.selectedTab = .history
                }
            }
        }
    }

    private var visibleSections: [HomeSection] {
        let hidden = HomeSection.hidden(hiddenSections)
        return HomeSection.ordered(sectionOrder).filter { !hidden.contains($0) }
    }

    @ViewBuilder
    private func homeSection(_ section: HomeSection, summary: HomeWeekSummary) -> some View {
        switch section {
        case .week: weekSection(summary)
        case .calendar: calendarSection
        case .recent: recentSection
        case .muscles: muscleFocusSection(summary)
        case .body: measurementsSection
        case .pinned: pinnedChartsSection
        }
    }

    var body: some View {
        let summary = HomeWeekSummary(sessions: completedWorkouts, muscleGroup: { exerciseStore.exercisesByUUID[$0]?.muscleGroup })
        NavigationStack {
            List {
                if historyStore.isLoading && completedWorkouts.isEmpty {
                    Section { ProgressView("Loading Training…") }
                }
                if let error = historyStore.error {
                    Section { Button("Retry Loading Training") { historyStore.refresh() } } footer: { Text(error) }
                }
                ForEach(visibleSections) { section in
                    homeSection(section, summary: summary)
                }
                Section {
                    Button("Customize Home", systemImage: "slider.horizontal.3") { showingCustomize = true }
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.bottom, IronTheme.floatingWorkoutBottomClearance, for: .scrollContent)
            .task { historyStore.observe(in: managedObjectContext) }
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.large)
            .modifier(HomeDateSubtitle(text: dateText))
            .navigationDestination(isPresented: $showingMeasurements) {
                BodyMeasurementsView(store: bodyMetricsStore)
                    .environmentObject(settingsStore)
            }
            .sheet(isPresented: $showingChartSelector) {
                PinnedChartSelectorSheet(exercises: exerciseStore.shownExercises) { chart in
                    pinnedChartsStore.pinnedCharts.append(chart)
                }
                .environmentObject(pinnedChartsStore)
                .environmentObject(exerciseStore)
            }
            .sheet(isPresented: $showingChartEditor) {
                PinnedChartEditSheet()
                    .environmentObject(pinnedChartsStore)
                    .environmentObject(exerciseStore)
            }
            .sheet(isPresented: $showingCustomize) {
                CustomizeHomeSheet()
            }
            .alert("Workout Not Started", isPresented: Binding(
                get: { persistenceError != nil },
                set: { if !$0 { persistenceError = nil } }
            )) {
                Button("OK", role: .cancel) { persistenceError = nil }
            } message: {
                Text(persistenceError ?? "Please try again.")
            }
            .sensoryFeedback(.error, trigger: persistenceError) { _, error in error != nil }
        }
    }
}

/// Today's date under the large title, where Fitness and Health put it.
private struct HomeDateSubtitle: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.navigationSubtitle(text)
        } else {
            content
        }
    }
}

/// Home owns its presentation of the rolling 28-day calendar. The standalone
/// calendar keeps its existing implementation and navigation.
private struct HomeTrainingCalendar: View {
    @Environment(\.calendar) private var calendar
    @ScaledMetric(relativeTo: .subheadline) private var dayDiameter: CGFloat = 34
    let workoutsByDay: [Date: [TrainingSessionSnapshot]]
    @State private var selectedDay: TrainingDay?

    private var cellSize: CGFloat { max(IronTheme.controlHeight, dayDiameter + 10) }

    private var days: [Date?] {
        let today = calendar.startOfDay(for: Date())
        guard let firstDay = calendar.date(byAdding: .day, value: -27, to: today),
              let firstWeek = calendar.dateInterval(of: .weekOfYear, for: firstDay),
              let lastWeek = calendar.dateInterval(of: .weekOfYear, for: today) else { return [] }
        let count = calendar.dateComponents([.day], from: firstWeek.start, to: lastWeek.end).day ?? 0
        return (0..<count).map { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstWeek.start),
                  day >= firstDay, day <= today else { return nil }
            return day
        }
    }

    private func workouts(on day: Date) -> [TrainingSessionSnapshot] {
        workoutsByDay[calendar.startOfDay(for: day)] ?? []
    }

    var body: some View {
        let days = days
        ScrollView(.horizontal) {
            Grid(horizontalSpacing: 0, verticalSpacing: 4) {
                GridRow {
                    ForEach(0..<7, id: \.self) { index in
                        Text(calendar.veryShortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1 + index) % 7])
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(IronTheme.secondaryText)
                            .frame(width: cellSize)
                            .accessibilityHidden(true)
                    }
                }
                ForEach(0..<(days.count / 7), id: \.self) { week in
                    GridRow {
                        ForEach(0..<7, id: \.self) { weekday in
                            if let day = days[week * 7 + weekday] {
                                dayCell(day)
                            } else {
                                Color.clear.frame(width: cellSize, height: cellSize)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .navigationDestination(item: $selectedDay) { day in TrainingDayRecapView(date: day.date) }
        .preference(key: WorkoutsLast28DaysKey.self, value: days.compactMap { $0 }.reduce(0) { $0 + workouts(on: $1).count })
    }

    @ViewBuilder
    private func dayCell(_ day: Date) -> some View {
        let sessions = workouts(on: day)
        let date = day.formatted(date: .complete, time: .omitted)
        Button { selectedDay = TrainingDay(date: day) } label: {
            dayCircle(day, trained: !sessions.isEmpty)
                .frame(width: cellSize, height: cellSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(date), \(sessions.isEmpty ? "rest day" : "\(sessions.count) workout\(sessions.count == 1 ? "" : "s")")")
        .accessibilityHint("Opens the daily recap")
    }

    private func dayCircle(_ day: Date, trained: Bool) -> some View {
        Text("\(calendar.component(.day, from: day))")
            .font(.ironMetric(.subheadline))
            .foregroundStyle(trained ? IronTheme.onAccent : IronTheme.secondaryText)
            .frame(width: dayDiameter, height: dayDiameter)
            .background(trained ? IronTheme.accent : IronTheme.tertiaryFill, in: Circle())
            .overlay {
                if !trained && calendar.isDateInToday(day) {
                    Circle().strokeBorder(IronTheme.accent, lineWidth: 1.5)
                }
            }
    }
}

struct DayVolume: Identifiable {
    var id: Date { date }
    let date: Date
    let volume: Double
    let isFuture: Bool

    var weekdayInitial: String {
        date.formatted(.dateTime.weekday(.narrow))
    }
}

/// Seven fixed columns for the current week, in the volume color, on the shared chart axes.
/// Scrubbing a day replaces the best-day line with that day's volume.
private struct WeeklyVolumeChart: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false
    @State private var selectedDayID: Date?

    let days: [DayVolume]
    let unit: String
    let valueLabel: (Double) -> String

    private var maxVolume: Double {
        let maximum = days.map(\.volume).max() ?? 0
        return maximum > 0 ? maximum * 1.1 : 1
    }

    private var selectedDay: DayVolume? {
        guard let selectedDayID else { return nil }
        return days.first { Calendar.current.isDate($0.date, inSameDayAs: selectedDayID) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart(days) { day in
                BarMark(
                    x: .value("Day", day.date, unit: .day),
                    y: .value("Volume", hasAppeared || reduceMotion ? day.volume : 0),
                    width: .ratio(0.55)
                )
                .cornerRadius(4)
                .foregroundStyle(IronTheme.metricVolume.opacity(IronChartEmphasis.opacity(
                    isSelected: selectedDay?.id == day.id, hasSelection: selectedDay != nil)))
                .accessibilityLabel(day.date.formatted(.dateTime.weekday(.wide)))
                .accessibilityValue("\(valueLabel(day.volume)) \(unit)")
            }
            .chartYScale(domain: 0...maxVolume)
            .ironValueAxis(.automatic(desiredCount: 2), label: valueLabel)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { value in
                    AxisValueLabel(centered: true) {
                        if let date = value.as(Date.self) {
                            let isToday = Calendar.current.isDateInToday(date)
                            Text(date.formatted(.dateTime.weekday(.narrow)))
                                .font(.caption.weight(isToday ? .bold : .regular))
                                .foregroundStyle(isToday ? IronTheme.accent : IronTheme.secondaryText)
                        }
                    }
                }
            }
            .chartXSelection(value: $selectedDayID)
            .ironHorizontalChartScrubbing { selectedDayID = nil }
            .frame(height: 120)
            .opacity(!reduceMotion || hasAppeared ? 1 : 0)
            .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: hasAppeared)
            .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: days.map(\.volume))
            .onAppear { hasAppeared = true }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Volume by day this week")
            .accessibilityValue(accessibilitySummary)
            .accessibilityAdjustableAction(adjustDay)
            .sensoryFeedback(.selection, trigger: selectedDay?.id)

            if let day = selectedDay ?? days.max(by: { $0.volume < $1.volume }), day.volume > 0 || selectedDay != nil {
                (Text(selectedDay == nil ? "Best day \(day.date.formatted(.dateTime.weekday(.wide))) · " : "\(day.date.formatted(.dateTime.weekday(.wide))) · ")
                 + Text(valueLabel(day.volume))
                    .font(.ironMetric(.footnote, weight: .semibold))
                    .foregroundColor(IronTheme.metricVolume)
                 + Text(" \(unit)").font(.caption).foregroundColor(IronTheme.secondaryText))
                    .font(.footnote)
                    .foregroundStyle(IronTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(reduceMotion ? .opacity : .numericText())
                    .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: day.volume)
            }
        }
    }

    private var accessibilitySummary: String {
        let selectedDays = selectedDayID.map { id in days.filter { $0.id == id } } ?? days
        return selectedDays.map {
            "\($0.date.formatted(.dateTime.weekday(.wide))), \(valueLabel($0.volume)) \(unit)"
        }.joined(separator: "; ")
    }

    private func adjustDay(_ direction: AccessibilityAdjustmentDirection) {
        guard !days.isEmpty else { return }
        let current = selectedDayID.flatMap { id in days.firstIndex { $0.id == id } }
        switch direction {
        case .increment: selectedDayID = days[min((current ?? -1) + 1, days.count - 1)].id
        case .decrement: selectedDayID = days[max((current ?? days.count) - 1, 0)].id
        @unknown default: break
        }
    }
}

/// A small axis-free trend for a Body row, ending on a dot at the latest entry.
private struct BodyTrendSparkline: View {
    let values: [Double]

    var body: some View {
        if values.count >= 2 {
            let low = values.min() ?? 0, high = values.max() ?? 1
            let pad = max((high - low) * 0.2, 0.01)
            Chart {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    LineMark(x: .value("Entry", index), y: .value("Value", value))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(IronTheme.metricBody.opacity(0.7))
                }
                PointMark(x: .value("Entry", values.count - 1), y: .value("Value", values[values.count - 1]))
                    .symbolSize(16)
                    .foregroundStyle(IronTheme.metricBody)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: (low - pad)...(high + pad))
            .frame(width: 40, height: 16)
            .accessibilityHidden(true)
        }
    }
}

struct BodyMeasurementsDashboardView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var settingsStore: SettingsStore
    @ObservedObject var store: BodyMetricsStore

    @State private var selectedKind: BodyMeasurementKind = .bodyWeight
    @State private var selectedTimeFrame = WorkoutExerciseChartData.TimeFrame.month
    @State private var showingEditor = false
    @State private var editorEntryID: UUID?
    @State private var entryToDelete: BodyMeasurementEntry?

    private let featuredKinds: [BodyMeasurementKind] = [
        .bodyWeight, .bodyFat, .waist, .chest, .leftBicep, .rightBicep
    ]
    private let coreKinds: [BodyMeasurementKind] = [.bodyWeight, .bodyFat, .height]
    private let torsoKinds: [BodyMeasurementKind] = [.neck, .shoulders, .chest, .waist, .abdomen, .hips]
    private let limbKinds: [BodyMeasurementKind] = [
        .leftBicep, .rightBicep, .leftForearm, .rightForearm,
        .leftThigh, .rightThigh, .leftCalf, .rightCalf
    ]

    private var photoEntries: [BodyMeasurementEntry] {
        store.entries.filter { $0.progressPhotoData != nil }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Latest Entry", value: latestEntrySubtitle)
                ForEach(coreKinds) { kind in
                    LabeledContent(kind.title) {
                        measurementValue(store.latestValue(for: kind), kind: kind)
                    }
                }
            } header: {
                Text("Overview")
            } footer: {
                Text("Measurements stay on this device unless you sync them with Apple Health.")
            }

            if !photoEntries.isEmpty {
                progressPhotosSection
            }

            trendSection
            latestMeasurementsSection
            historySection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Measures")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Log Measurements", systemImage: "plus") { openEditor() }
                    .labelStyle(.iconOnly)
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(isPresented: $showingEditor) {
            BodyMeasurementsView(store: store, initialEntryID: editorEntryID)
                .environmentObject(settingsStore)
        }
        .confirmationDialog(
            "Delete measurement entry?",
            isPresented: Binding(
                get: { entryToDelete != nil },
                set: { if !$0 { entryToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Entry", role: .destructive) {
                guard let entry = entryToDelete else { return }
                entryToDelete = nil
                store.delete(id: entry.id)
            }
            Button("Cancel", role: .cancel) {
                entryToDelete = nil
            }
        } message: {
            if let entry = entryToDelete {
                Text("This removes the measurements saved on \(DateFormatter.localizedString(from: entry.date, dateStyle: .medium, timeStyle: .short)).")
            }
        }
    }

    private var latestEntrySubtitle: String {
        guard let latest = store.latest else { return "No entries yet" }
        return RelativeDateTimeFormatter().localizedString(for: latest.date, relativeTo: Date())
    }

    private var progressPhotosSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(photoEntries) { entry in
                        Button(action: { openEditor(entry.id) }) {
                            VStack(alignment: .leading, spacing: 8) {
                                if let data = entry.progressPhotoData,
                                   let image = UIImage(data: data) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 132, height: 158)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }

                                Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 132, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Progress photo from \(entry.date.formatted(date: .long, time: .omitted))")
                        .accessibilityHint("Opens this measurement entry")
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 0))
        } header: {
            Text("Progress Photos")
        } footer: {
            Text("\(photoEntries.count) photo\(photoEntries.count == 1 ? "" : "s") stored privately on this device.")
        }
    }

    private var trendSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Measurement", selection: $selectedKind) {
                        ForEach(featuredKinds) { kind in Text(compactTitle(for: kind)).tag(kind) }
                    }
                    .pickerStyle(.menu).labelsHidden()
                    Spacer()
                    Picker("Period", selection: $selectedTimeFrame) {
                        ForEach(WorkoutExerciseChartData.TimeFrame.allCases, id: \.title) { frame in Text(frame.compactTitle).tag(frame) }
                    }
                    .pickerStyle(.menu).labelsHidden()
                }
                if trendSamples.isEmpty {
                    ContentUnavailableView("No \(selectedKind.title) Data", systemImage: "chart.line.flattrend.xyaxis",
                        description: Text("Add this measurement to start its private trend."))
                } else {
                BodyMeasurementTrendChart(
                    samples: trendSamples,
                    measurementTitle: selectedKind.title,
                    domainStart: selectedTimeFrame.domainStart(earliestDate: trendSamples.first?.date),
                    domainEnd: Date(),
                    valueLabel: { value in String(format: value >= 100 ? "%.0f" : "%.1f", value) },
                    unit: selectedKind.unitLabel(weightUnit: settingsStore.weightUnit)
                )
                .frame(height: dynamicTypeSize.isAccessibilitySize ? 380 : 236)


                }
            }
            .padding(.vertical, 6)
            .sensoryFeedback(.selection, trigger: selectedKind)
            .sensoryFeedback(.selection, trigger: selectedTimeFrame)
            if !trendSamples.isEmpty {
                if let delta = selectedDelta {
                    LabeledContent("Change") {
                        Label(delta.text, systemImage: delta.symbol).font(.ironMetric(.body, weight: .semibold)).foregroundStyle(delta.color)
                    }
                }
            }
        } header: { Text("Progress") }
    }

    private var latestMeasurementsSection: some View {
        Group {
            measurementGroup(title: "Core", kinds: coreKinds)
            measurementGroup(title: "Torso", kinds: torsoKinds)
            measurementGroup(title: "Arms & Legs", kinds: limbKinds)
        }
    }

    private func measurementGroup(title: String, kinds: [BodyMeasurementKind]) -> some View {
        Section(title) {
            ForEach(kinds) { kind in
                Button {
                    selectedKind = kind
                } label: {
                    HStack {
                        Label(kind.title, systemImage: icon(for: kind))
                            .foregroundStyle(.primary)
                        Spacer()
                        measurementValue(store.latestValue(for: kind), kind: kind)
                        if selectedKind == kind {
                            Image(systemName: "chart.xyaxis.line")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .accessibilityHint("Charts \(kind.title) in the progress section")
            }
        }
    }

    private var historySection: some View {
        Section {
            if store.entries.isEmpty {
                ContentUnavailableView {
                    Label("No History Yet", systemImage: "calendar.badge.plus")
                } description: {
                    Text("Your saved entries appear here and remain private.")
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(store.entries) { entry in
                    Button {
                        openEditor(entry.id)
                    } label: {
                        HStack(spacing: 12) {
                            if let data = entry.progressPhotoData,
                               let image = UIImage(data: data) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 36, height: 36)
                                    .clipShape(Circle())
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(DateFormatter.localizedString(from: entry.date, dateStyle: .medium, timeStyle: .short))
                                    .foregroundStyle(.primary)
                                Text(entrySummary(entry))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if let weight = entry[.bodyWeight] {
                                measurementValue(weight, kind: .bodyWeight)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            entryToDelete = entry
                        }
                    }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { openEditor(entry.id) }
                        Button("Delete", systemImage: "trash", role: .destructive) { entryToDelete = entry }
                    }
                }
            }
        } header: {
            Text("History")
        } footer: {
            if !store.entries.isEmpty {
                Text("\(store.entries.count) entr\(store.entries.count == 1 ? "y" : "ies")")
            }
        }
    }

    private var trendSamples: [BodyMeasurementTrendSample] {
        let start = selectedTimeFrame.from
        return store.entries.reversed().compactMap { entry in
            if let start, entry.date < start { return nil }
            guard let canonical = entry[selectedKind] else { return nil }
            return BodyMeasurementTrendSample(
                id: entry.id,
                date: entry.date,
                value: selectedKind.displayValue(from: canonical, weightUnit: settingsStore.weightUnit)
            )
        }
    }

    private var selectedDelta: (text: String, symbol: String, color: Color)? {
        guard trendSamples.count >= 2 else { return nil }
        let delta = trendSamples[trendSamples.count - 1].value - trendSamples[trendSamples.count - 2].value
        guard abs(delta) >= 0.001 else {
            return ("No change", "minus", Color.secondary)
        }
        let format = abs(delta) >= 10 ? "%.0f" : "%.1f"
        let text = (delta > 0 ? "+" : "") + String(format: format, delta)
        return (text, delta > 0 ? "arrow.up.right" : "arrow.down.right", IronTheme.metricBody)
    }

    private func latestEntry(for kind: BodyMeasurementKind) -> BodyMeasurementEntry? {
        store.entries.first { $0[kind] != nil }
    }

    private func measurementValue(_ canonical: Double?, kind: BodyMeasurementKind) -> Text {
        guard let canonical else { return Text("—").font(.ironMetric(.body)).foregroundColor(IronTheme.secondaryText) }
        return Text(displayText(value: canonical, kind: kind, includeUnit: false))
            .font(.ironMetric(.body, weight: .semibold)).foregroundColor(IronTheme.metricBody)
            + Text(" \(kind.unitLabel(weightUnit: settingsStore.weightUnit))")
                .font(.caption.weight(.semibold)).foregroundColor(IronTheme.secondaryText)
    }

    private func displayText(value canonical: Double, kind: BodyMeasurementKind, includeUnit: Bool) -> String {
        let display = kind.displayValue(from: canonical, weightUnit: settingsStore.weightUnit)
        let value = String(format: display >= 100 ? "%.0f" : "%.1f", display)
        return includeUnit ? "\(value) \(kind.unitLabel(weightUnit: settingsStore.weightUnit))" : value
    }

    private func latestDateText(for kind: BodyMeasurementKind) -> String {
        guard let entry = latestEntry(for: kind) else { return "Not logged" }
        return RelativeDateTimeFormatter().localizedString(for: entry.date, relativeTo: Date())
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter.string(from: date)
    }

    private func compactTitle(for kind: BodyMeasurementKind) -> String {
        switch kind {
        case .bodyWeight: return "Weight"
        case .bodyFat: return "Body fat"
        case .leftBicep: return "L. bicep"
        case .rightBicep: return "R. bicep"
        default: return kind.title
        }
    }

    private func icon(for kind: BodyMeasurementKind) -> String {
        switch kind {
        case .bodyWeight: return "scalemass.fill"
        case .bodyFat: return "percent"
        case .height: return "ruler.fill"
        case .neck, .shoulders, .chest, .waist, .abdomen, .hips: return "figure.arms.open"
        default: return "ruler"
        }
    }

    private func entrySummary(_ entry: BodyMeasurementEntry) -> String {
        var parts: [String] = []
        if !entry.values.isEmpty {
            parts.append("\(entry.values.count) measurement\(entry.values.count == 1 ? "" : "s")")
        }
        if entry.progressPhotoData != nil {
            parts.append("Progress photo")
        }
        return parts.joined(separator: " · ")
    }

    private func openEditor(_ entryID: UUID? = nil) {
        editorEntryID = entryID
        showingEditor = true
    }
}

private struct BodyMeasurementTrendSample: Identifiable {
    let id: UUID
    let date: Date
    let value: Double
}

private struct BodyMeasurementTrendChart: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var hasAppeared = false
    let samples: [BodyMeasurementTrendSample]
    let measurementTitle: String
    var domainStart: Date? = nil
    var domainEnd: Date? = nil
    let valueLabel: (Double) -> String
    var unit: String = ""

    @State private var selectedDate: Date?

    private var firstDate: Date { domainStart ?? samples.first?.date ?? Date() }
    private var lastDate: Date { domainEnd ?? samples.last?.date ?? firstDate.addingTimeInterval(60) }

    private var selectedSample: BodyMeasurementTrendSample? {
        guard let selectedDate else { return nil }
        return samples.min {
            abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
        }
    }

    /// Body measurements move a little at a time, so the axis hugs the data instead of starting at zero.
    private var yDomain: ClosedRange<Double> {
        let values = samples.map(\.value)
        let low = values.min() ?? 0, high = values.max() ?? 1
        let pad = max((high - low) * 0.25, high * 0.02, 0.5)
        return max(0, low - pad)...(high + pad)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let shown = selectedSample ?? samples.last {
                IronChartHeader(
                    caption: selectedSample == nil ? "Latest" : "Logged",
                    value: IronChartText.value(valueLabel(shown.value), unit: unit, tint: IronTheme.metricBody),
                    detail: shown.date.formatted(date: .abbreviated, time: .omitted)
                )
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: shown.id)
            }

            Chart {
                ForEach(samples) { sample in
                    let value = hasAppeared || reduceMotion ? sample.value : yDomain.lowerBound
                    LineMark(x: .value("Date", sample.date), y: .value(measurementTitle, value))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(IronTheme.metricBody.opacity(selectedSample == nil ? 1 : IronChartEmphasis.dimmed))

                    PointMark(x: .value("Date", sample.date), y: .value(measurementTitle, value))
                        .symbolSize(samples.count > 40 ? 0 : (sample.id == selectedSample?.id ? 64 : 24))
                        .foregroundStyle(IronTheme.metricBody.opacity(
                            IronChartEmphasis.opacity(isSelected: sample.id == selectedSample?.id, hasSelection: selectedSample != nil)))
                }

                if let selectedSample {
                    IronChartSelectionRule(date: selectedSample.date)
                }
            }
            .chartYScale(domain: yDomain)
            .opacity(!reduceMotion || hasAppeared ? 1 : 0)
            .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: hasAppeared)
            .onAppear { hasAppeared = true }
            .chartXScale(domain: firstDate...max(lastDate, firstDate.addingTimeInterval(60)))
            .ironValueAxis(.automatic(desiredCount: 3), label: valueLabel)
            .ironDateAxis(.automatic(desiredCount: dynamicTypeSize.isAccessibilitySize ? 2 : 4), format: .dateTime.month(.abbreviated).day())
            .chartXSelection(value: $selectedDate)
            .ironHorizontalChartScrubbing { selectedDate = nil }
            .accessibilityLabel("\(measurementTitle) trend with \(samples.count) entries")
        }
    }
}

struct BodyMeasurementsView: View {
    private struct HealthImportNotice: Identifiable {
        let id = UUID()
        let isError: Bool
        let message: String
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settingsStore: SettingsStore
    @ObservedObject var store: BodyMetricsStore

    @State private var date = Date()
    @State private var inputs: [String: String] = [:]
    @State private var originalValues: [String: Double] = [:]
    @State private var editedKinds: Set<String> = []
    @State private var loadedInitialValues = false
    @State private var syncingHealth = false
    @State private var editingEntryID: UUID?
    @State private var healthImportNotice: HealthImportNotice?
    @State private var measurementToDelete: BodyMeasurementEntry?
    @State private var progressPhotoItem: PhotosPickerItem?
    @State private var progressPhotoData: Data?
    @State private var isLoadingProgressPhoto = false
    @State private var progressPhotoError: String?
    @State private var measurementSaveFailed = false
    @State private var isEditingFields = true

    let initialEntryID: UUID?

    private let primaryKinds: [BodyMeasurementKind] = [.bodyWeight, .bodyFat, .height]
    private let torsoKinds: [BodyMeasurementKind] = [.neck, .shoulders, .chest, .waist, .abdomen, .hips]
    private let limbKinds: [BodyMeasurementKind] = [.leftBicep, .rightBicep, .leftForearm, .rightForearm, .leftThigh, .rightThigh, .leftCalf, .rightCalf]

    init(store: BodyMetricsStore, initialEntryID: UUID? = nil) {
        self.store = store
        self.initialEntryID = initialEntryID
    }

    private var measurementDeleteMessage: String {
        guard let entry = measurementToDelete else {
            return "This removes the saved measurements."
        }
        let date = DateFormatter.localizedString(
            from: entry.date,
            dateStyle: .medium,
            timeStyle: .short
        )
        return "This removes the measurements saved on \(date)."
    }

    private var isReviewingEntry: Bool {
        editingEntryID != nil && !isEditingFields
    }

    private var recordedKinds: [BodyMeasurementKind] {
        BodyMeasurementKind.allCases.filter { kind in
            if let raw = inputs[kind.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                return true
            }
            return originalValues[kind.rawValue] != nil
        }
    }

    private func valueBinding(for kind: BodyMeasurementKind) -> Binding<String> {
        Binding(
            get: { inputs[kind.rawValue] ?? "" },
            set: {
                inputs[kind.rawValue] = sanitizedMeasurementInput($0)
                editedKinds.insert(kind.rawValue)
            }
        )
    }

    private func editableMeasurementText(_ value: Double) -> String {
        var text = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.last == "0" { text.removeLast() }
        if text.last == "." { text.removeLast() }
        return text
    }

    private func sanitizedMeasurementInput(_ input: String) -> String {
        var result = ""
        var hasDecimalSeparator = false

        for character in input.replacingOccurrences(of: ",", with: ".") {
            if character.isNumber {
                result.append(character)
            } else if character == ".", !hasDecimalSeparator {
                hasDecimalSeparator = true
                result.append(character)
            }
        }
        return result
    }

    private func isInvalidInput(_ kind: BodyMeasurementKind) -> Bool {
        guard let raw = inputs[kind.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return false }
        return kind.validatedCanonicalValue(from: raw, weightUnit: settingsStore.weightUnit) == nil
    }

    private var hasInvalidInputs: Bool {
        BodyMeasurementKind.allCases.contains(where: isInvalidInput)
    }

    private func field(_ kind: BodyMeasurementKind) -> some View {
        let invalid = isInvalidInput(kind)

        return LabeledContent(kind.title) {
            HStack(spacing: 4) {
                TextField(latestPlaceholder(for: kind), text: valueBinding(for: kind))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.ironMetric(.body))
                    .foregroundStyle(invalid ? IronTheme.danger : IronTheme.primaryText)
                    .accessibilityLabel("\(kind.title), \(kind.unitLabel(weightUnit: settingsStore.weightUnit))")
                    .accessibilityHint(invalid ? "Enter a number greater than zero" : "Numeric measurement")

                Text(kind.unitLabel(weightUnit: settingsStore.weightUnit))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }

    private func fieldsSection(title: String, kinds: [BodyMeasurementKind]) -> some View {
        Section(title) {
            ForEach(kinds) { kind in
                field(kind)
            }
        }
    }

    private func loadLatestValuesIfNeeded() {
        guard !loadedInitialValues else { return }
        loadedInitialValues = true
        // A new entry is intentionally sparse. Previous values remain visible
        // as placeholders, but are not silently written again when the user
        // changes only one measurement.
        inputs.removeAll()
        originalValues.removeAll()
        editedKinds.removeAll()
        isEditingFields = true
    }

    private func loadInitialValuesIfNeeded() {
        guard !loadedInitialValues else { return }
        if let initialEntryID,
           let entry = store.entries.first(where: { $0.id == initialEntryID }) {
            loadedInitialValues = true
            load(entry)
        } else {
            loadLatestValuesIfNeeded()
        }
    }

    private func load(_ entry: BodyMeasurementEntry) {
        editingEntryID = entry.id
        date = entry.date
        progressPhotoData = entry.progressPhotoData
        progressPhotoItem = nil
        progressPhotoError = nil
        inputs.removeAll()
        originalValues = entry.values
        editedKinds.removeAll()
        isEditingFields = false
        for kind in BodyMeasurementKind.allCases {
            guard let value = entry[kind] else { continue }
            let display = kind.displayValue(from: value, weightUnit: settingsStore.weightUnit)
            inputs[kind.rawValue] = editableMeasurementText(display)
        }
    }

    private func startNewEntry() {
        editingEntryID = nil
        date = Date()
        progressPhotoData = nil
        progressPhotoItem = nil
        progressPhotoError = nil
        inputs.removeAll()
        originalValues.removeAll()
        editedKinds.removeAll()
        isEditingFields = true
    }

    private func latestPlaceholder(for kind: BodyMeasurementKind) -> String {
        guard editingEntryID == nil,
              let canonical = store.latestValue(for: kind) else { return "—" }
        let display = kind.displayValue(from: canonical, weightUnit: settingsStore.weightUnit)
        return String(format: display >= 100 ? "%.0f" : "%.1f", display)
    }

    private var parsedValues: [String: Double] {
        var values: [String: Double] = [:]
        for kind in BodyMeasurementKind.allCases {
            if editingEntryID != nil,
               !editedKinds.contains(kind.rawValue),
               let originalValue = originalValues[kind.rawValue] {
                values[kind.rawValue] = originalValue
                continue
            }

            guard let raw = inputs[kind.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let canonical = kind.validatedCanonicalValue(from: raw, weightUnit: settingsStore.weightUnit) else { continue }
            values[kind.rawValue] = canonical
        }
        return values
    }

    private var canSave: Bool {
        (!parsedValues.isEmpty || progressPhotoData != nil) && !hasInvalidInputs
    }

    private func save() {
        let values = parsedValues
        guard canSave else { return }
        let saved = store.save(
            BodyMeasurementEntry(
                id: editingEntryID ?? UUID(),
                date: date,
                values: values,
                progressPhotoData: progressPhotoData
            ),
            exportToHealth: !values.isEmpty
        )
        if saved {
            dismiss()
        } else {
            measurementSaveFailed = true
        }
    }

    @MainActor
    private func importProgressPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        isLoadingProgressPhoto = true
        progressPhotoError = nil
        defer { isLoadingProgressPhoto = false }

        do {
            guard let originalData = try await item.loadTransferable(type: Data.self),
                  let compressedData = compressedProgressPhotoData(from: originalData) else {
                throw NSError(
                    domain: "Iron.ProgressPhoto",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Light could not read that image."]
                )
            }
            progressPhotoData = compressedData
        } catch {
            progressPhotoError = error.localizedDescription
            progressPhotoItem = nil
        }
    }

    private func compressedProgressPhotoData(from data: Data) -> Data? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let maximumDimension: CGFloat = 1_280
        let largestDimension = max(image.size.width, image.size.height)
        let scale = min(1, maximumDimension / largestDimension)
        let targetSize = CGSize(
            width: max(1, (image.size.width * scale).rounded()),
            height: max(1, (image.size.height * scale).rounded())
        )
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return rendered.jpegData(compressionQuality: 0.76)
    }

    private func syncHealth() {
        healthImportNotice = nil
        syncingHealth = true
        HealthManager.shared.fetchLatestBodyMeasurements { result in
            syncingHealth = false
            switch result {
            case .success(let read):
                guard !read.values.isEmpty else {
                    healthImportNotice = HealthImportNotice(
                        isError: true,
                        message: "No body measurements were found. Check Light's Health access in Settings and try again."
                    )
                    return
                }
                for (kind, value) in read.values {
                    let display = kind.displayValue(from: value, weightUnit: settingsStore.weightUnit)
                    inputs[kind.rawValue] = editableMeasurementText(display)
                    editedKinds.insert(kind.rawValue)
                }
                if let healthDate = read.date { date = healthDate }
                healthImportNotice = HealthImportNotice(
                    isError: false,
                    message: "Imported \(read.values.count) latest measurement\(read.values.count == 1 ? "" : "s"). Review the values, then save."
                )
            case .failure(let error):
                healthImportNotice = HealthImportNotice(isError: true, message: error.localizedDescription)
            }
        }
    }

    var body: some View {
        Form {
            if isReviewingEntry {
                Section {
                    LabeledContent("Recorded", value: date.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent(
                        "Measurements",
                        value: recordedKinds.isEmpty ? "Photo only" : "\(recordedKinds.count)"
                    )
                } header: {
                    Text("Entry")
                } footer: {
                    Text("Only values recorded in this entry are shown.")
                }

                if progressPhotoData != nil {
                    progressPhotoSection
                }

                Section("Recorded Values") {
                    if recordedKinds.isEmpty {
                        Text("This entry only saved a progress photo.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(recordedKinds) { kind in
                            LabeledContent(kind.title, value: reviewValueText(for: kind))
                        }
                    }
                }
            } else {
                Section {
                    DatePicker(
                        "Measurement Date",
                        selection: $date,
                        in: Date.distantPast...Date(),
                        displayedComponents: [.date, .hourAndMinute]
                    )

                    if editingEntryID != nil {
                        Button("Start a New Entry", systemImage: "plus", action: startNewEntry)
                    }
                } footer: {
                    Text(editingEntryID == nil
                         ? "Track only what matters to you. Empty fields are ignored."
                         : "Update this entry. Empty fields stay omitted.")
                }

                if HealthSettingsView.isSupported {
                    Section {
                        Button(action: syncHealth) {
                            HStack {
                                Label(
                                    syncingHealth ? "Reading Apple Health…" : "Import Latest from Apple Health",
                                    systemImage: "heart.fill"
                                )
                                Spacer()
                                if syncingHealth {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(syncingHealth)
                    } footer: {
                        if let notice = healthImportNotice {
                            Label(notice.message, systemImage: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(notice.isError ? IronTheme.danger : IronTheme.success)
                        }
                    }
                }

                progressPhotoSection

                fieldsSection(title: "Core", kinds: primaryKinds)
                fieldsSection(title: "Torso", kinds: torsoKinds)
                fieldsSection(title: "Arms & Legs", kinds: limbKinds)

                if hasInvalidInputs || !canSave {
                    Section {
                        Label(
                            hasInvalidInputs
                                ? "Correct the highlighted values before saving."
                                : "Enter at least one measurement to save.",
                            systemImage: hasInvalidInputs ? "exclamationmark.circle.fill" : "info.circle"
                        )
                        .foregroundStyle(hasInvalidInputs ? IronTheme.danger : IronTheme.secondaryText)
                    }
                }
            }

            if editingEntryID == nil, !store.entries.isEmpty {
                historySection
            }
        }
        .navigationTitle(isReviewingEntry ? "Measurement" : (editingEntryID == nil ? "Log Measurements" : "Edit Measurements"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isReviewingEntry {
                    Button("Edit", systemImage: "pencil") { isEditingFields = true }
                        .labelStyle(.iconOnly)
                } else {
                    Button(editingEntryID == nil ? "Save" : "Update", action: save)
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .onAppear(perform: loadInitialValuesIfNeeded)
        .alert("Measurements Not Saved", isPresented: $measurementSaveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Light could not save these measurements. Your previous entries are unchanged. Check the values and try again.")
        }
        .onChange(of: progressPhotoItem) { _, item in
            Task { await importProgressPhoto(item) }
        }
        .confirmationDialog(
            "Delete measurement entry?",
            isPresented: Binding(
                get: { measurementToDelete != nil },
                set: { if !$0 { measurementToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Entry", role: .destructive) {
                guard let entry = measurementToDelete else { return }
                measurementToDelete = nil
                store.delete(id: entry.id)
                if editingEntryID == entry.id { startNewEntry() }
            }
            Button("Cancel", role: .cancel) {
                measurementToDelete = nil
            }
        } message: {
            Text(measurementDeleteMessage)
        }
    }

    private func reviewValueText(for kind: BodyMeasurementKind) -> String {
        if let raw = inputs[kind.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return "\(raw) \(kind.unitLabel(weightUnit: settingsStore.weightUnit))"
        }
        if let canonical = originalValues[kind.rawValue] {
            let display = kind.displayValue(from: canonical, weightUnit: settingsStore.weightUnit)
            return "\(String(format: display >= 100 ? "%.0f" : "%.1f", display)) \(kind.unitLabel(weightUnit: settingsStore.weightUnit))"
        }
        return "—"
    }

    private var progressPhotoSection: some View {
        Section {
            if let data = progressPhotoData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                if !isReviewingEntry {
                    PhotosPicker(
                        selection: $progressPhotoItem,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        Label("Replace Photo", systemImage: "arrow.triangle.2.circlepath")
                    }

                    Button("Remove Photo", systemImage: "trash", role: .destructive) {
                        progressPhotoData = nil
                        progressPhotoItem = nil
                        progressPhotoError = nil
                    }
                }
            } else if !isReviewingEntry {
                PhotosPicker(
                    selection: $progressPhotoItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Label("Add Progress Photo", systemImage: "photo.badge.plus")
                }
            }

            if isLoadingProgressPhoto {
                HStack {
                    ProgressView()
                    Text("Preparing photo…")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Progress Photo")
        } footer: {
            if let progressPhotoError {
                Label(progressPhotoError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else {
                Text("Stored locally and included in Light backups.")
            }
        }
    }

    private var historySection: some View {
        Section {
            ForEach(store.entries) { entry in
                Button {
                    load(entry)
                } label: {
                    HStack(spacing: 12) {
                        if let data = entry.progressPhotoData,
                           let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 36, height: 36)
                                .clipShape(Circle())
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(DateFormatter.localizedString(from: entry.date, dateStyle: .medium, timeStyle: .short))
                                .foregroundStyle(.primary)
                            Text(historySummary(entry))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if let weight = entry[.bodyWeight] {
                            (Text(String(
                                format: "%.1f",
                                BodyMeasurementKind.bodyWeight.displayValue(from: weight, weightUnit: settingsStore.weightUnit)
                            )).font(.ironMetric(.body)).foregroundColor(IronTheme.primaryText)
                             + Text(" \(BodyMeasurementKind.bodyWeight.unitLabel(weightUnit: settingsStore.weightUnit))")
                                .font(.caption).foregroundColor(IronTheme.secondaryText))
                        }
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        measurementToDelete = entry
                    }
                }
            }
        } header: {
            Text("History")
        } footer: {
            Text("Tap an entry to load its values.")
        }
    }

    private func historySummary(_ entry: BodyMeasurementEntry) -> String {
        var parts: [String] = []
        if !entry.values.isEmpty {
            parts.append("\(entry.values.count) measurement\(entry.values.count == 1 ? "" : "s")")
        }
        if entry.progressPhotoData != nil {
            parts.append("Progress photo")
        }
        return parts.joined(separator: " · ")
    }
}

struct PinnedExerciseChartRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var hasAppeared = false
    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.managedObjectContext) private var managedObjectContext

    let exercise: Exercise
    let measurementType: WorkoutExerciseChartData.MeasurementType

    @State private var selectedDate: Date?

    private struct Point: Identifiable {
        let id: NSManagedObjectID
        let date: Date
        let value: Double
    }

    private var points: [Point] {
        let timeFrame = WorkoutExerciseChartData.TimeFrame.threeMonths
        let request = WorkoutExercise.historyFetchRequest(
            of: exercise.uuid,
            from: timeFrame.from,
            until: timeFrame.until
        )
        let evaluator = WorkoutExerciseChartData.evaluator(
            for: measurementType,
            weightUnit: settingsStore.weightUnit,
            maxRepetitionsForOneRepMax: settingsStore.maxRepetitionsOneRepMax
        )

        let workoutExercises = (try? managedObjectContext.fetch(request)) ?? []
        return workoutExercises
            .compactMap { workoutExercise -> Point? in
                guard let date = workoutExercise.workout?.start,
                      let value = evaluator(workoutExercise),
                      value > 0, value.isFinite else { return nil }
                return Point(id: workoutExercise.objectID, date: date, value: value)
            }
            .sorted { $0.date < $1.date }
    }

    private var metricColor: Color {
        switch measurementType {
        case .oneRM: return IronTheme.accent
        case .totalWeight: return IronTheme.metricVolume
        case .totalSets, .totalRepetitions: return IronTheme.metricSets
        }
    }

    private var unitSuffix: String {
        switch measurementType {
        case .oneRM, .totalWeight: return " \(settingsStore.weightUnit.unit.symbol)"
        case .totalSets, .totalRepetitions: return ""
        }
    }

    private func numberLabel(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value >= 1_000 ? 0...0 : 0...1)).grouping(.automatic))
    }

    var body: some View {
        let points = points

        // A Health-style summary card: what it is, the number, then the trend without axes.
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(exercise.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(metricColor)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let shown = selectedPoint(in: points) ?? points.last {
                    Text(shown.date.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.footnote)
                        .foregroundStyle(IronTheme.secondaryText)
                }
            }

            if points.isEmpty {
                Text("No completed sets in the last 3 months.")
                    .font(.subheadline)
                    .foregroundStyle(IronTheme.secondaryText)
            } else {
                let shown = selectedPoint(in: points) ?? points.last!
                HStack(alignment: .lastTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        IronChartText.value(numberLabel(shown.value), unit: unitSuffix.trimmingCharacters(in: .whitespaces), tint: metricColor)
                            .contentTransition(reduceMotion ? .opacity : .numericText())
                            .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: shown.id)
                        Text(selectedDate == nil ? "\(measurementType.title) · last 3 months" : measurementType.title)
                            .font(.footnote)
                            .foregroundStyle(IronTheme.secondaryText)
                    }
                    .fixedSize()

                    Chart {
                        ForEach(points) { point in
                            LineMark(x: .value("Date", point.date), y: .value(measurementType.title, hasAppeared || reduceMotion ? point.value : sparkDomain(points).lowerBound))
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                                .foregroundStyle(metricColor.opacity(selectedDate == nil ? 1 : IronChartEmphasis.dimmed))
                        }
                        if let marked = selectedPoint(in: points) ?? points.last {
                            PointMark(x: .value("Date", marked.date), y: .value(measurementType.title, marked.value))
                                .symbolSize(36)
                                .foregroundStyle(metricColor)
                        }
                        if let selected = selectedPoint(in: points) {
                            IronChartSelectionRule(date: selected.date)
                        }
                    }
                    .chartYScale(domain: sparkDomain(points))
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .opacity(!reduceMotion || hasAppeared ? 1 : 0)
                    .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: hasAppeared)
                    .onAppear { hasAppeared = true }
                    .chartXSelection(value: $selectedDate)
                    .ironHorizontalChartScrubbing { selectedDate = nil }
                    .frame(height: dynamicTypeSize.isAccessibilitySize ? 120 : 52)
                    .accessibilityLabel("\(exercise.title) \(measurementType.title) over the last 3 months")
                }
            }
        }
    }

    /// The sparkline hugs its data so small progress is visible.
    private func sparkDomain(_ points: [Point]) -> ClosedRange<Double> {
        let values = points.map(\.value)
        let low = values.min() ?? 0, high = values.max() ?? 1
        let pad = max((high - low) * 0.15, 0.5)
        return (low - pad)...(high + pad)
    }

    private func selectedPoint(in points: [Point]) -> Point? {
        guard let selectedDate else { return nil }
        return points.min {
            abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
        }
    }
}

private struct PinnedChartEditSheet: View {
    @EnvironmentObject var pinnedChartsStore: PinnedChartsStore
    @EnvironmentObject var exerciseStore: ExerciseStore
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(pinnedChartsStore.pinnedCharts, id: \.self) { chart in
                    HStack {
                        Text(exerciseStore.find(with: chart.exerciseUuid)?.title ?? "Unknown Exercise")
                        Spacer()
                        Text(chart.measurementType.title)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    self.pinnedChartsStore.pinnedCharts.remove(atOffsets: offsets)
                }
                .onMove { source, destination in
                    self.pinnedChartsStore.pinnedCharts.move(fromOffsets: source, toOffset: destination)
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if pinnedChartsStore.pinnedCharts.isEmpty {
                    ContentUnavailableView {
                        Label("No Pinned Charts", systemImage: "chart.xyaxis.line")
                    } description: {
                        Text("Pin an exercise chart from Home to keep it close at hand.")
                    }
                }
            }
            .navigationTitle("Edit Charts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
    }
}

private struct PinnedChartSelectorSheet: View {
    @EnvironmentObject var pinnedChartsStore: PinnedChartsStore
    @Environment(\.dismiss) private var dismiss

    let onSelection: (PinnedChart) -> Void
    
    @State private var selectedExercise: Exercise? = nil

    @ObservedObject private var filter: ExerciseGroupFilter
    
    init(exercises: [Exercise], onSelection: @escaping (PinnedChart) -> Void) {
        filter = ExerciseGroupFilter(exerciseGroups: ExerciseStore.splitIntoMuscleGroups(exercises: exercises))
        self.onSelection = onSelection
    }
    
    private func resetAndDismiss() {
        dismiss()
        self.filter.filter = ""
    }

    private func isAvailable(_ measurementType: WorkoutExerciseChartData.MeasurementType, for exercise: Exercise) -> Bool {
        !pinnedChartsStore.pinnedCharts.contains(
            PinnedChart(exerciseUuid: exercise.uuid, measurementType: measurementType)
        )
    }

    private func select(_ measurementType: WorkoutExerciseChartData.MeasurementType, for exercise: Exercise) {
        onSelection(PinnedChart(exerciseUuid: exercise.uuid, measurementType: measurementType))
        resetAndDismiss()
    }
    
    var body: some View {
        NavigationStack {
            ExerciseSingleSelectionView(exerciseGroups: filter.exerciseGroups) { exercise in
                selectedExercise = exercise
            }
            .navigationTitle("Pin Chart")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $filter.filter, prompt: "Search exercises")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { resetAndDismiss() }
                }
            }
        }
        .confirmationDialog(
            selectedExercise?.title ?? "Choose a chart",
            isPresented: Binding(
                get: { selectedExercise != nil },
                set: { if !$0 { selectedExercise = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let exercise = selectedExercise {
                ForEach(
                    WorkoutExerciseChartData.MeasurementType.allCases.filter { isAvailable($0, for: exercise) },
                    id: \.self
                ) { measurementType in
                    Button(measurementType.title) {
                        select(measurementType, for: exercise)
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                selectedExercise = nil
            }
        }
    }
}

#if DEBUG
struct FeedView_Previews : PreviewProvider {
    static var previews: some View {
        Group {
            FeedView()
                .mockEnvironment(weightUnit: .metric)
        }
    }
}
#endif
