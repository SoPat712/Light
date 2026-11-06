//
//  IronWidget.swift
//  IronWidget
//
//  Created by Karim Abou Zeid on 12.10.20.
//  Copyright © 2020 Karim Abou Zeid Software. All rights reserved.
//

import WidgetKit
import SwiftUI
import WorkoutDataKit
import CoreData
import ActivityKit
import Charts

// MARK: - This Week

private struct ThisWeekEntry: TimelineEntry {
    let date: Date
    let summary: ThisWeekWidgetSummary?
    let unit: UnitMass

    func volume(_ kilograms: Double) -> String {
        let value = Measurement(value: kilograms, unit: UnitMass.kilograms).converted(to: unit).value
        // Match Home's WorkoutPreviewFormatting.volume.
        if value >= 10_000 {
            return (value / 1_000).formatted(.number.precision(.fractionLength(1))) + "k"
        }
        return value.formatted(.number.precision(.fractionLength(0)).grouping(.automatic))
    }

    static func sample(at date: Date = Date()) -> Self {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        var sessions: [ThisWeekWidgetHistory.Session] = []
        for offset in 1...28 {
            if let day = calendar.date(byAdding: .weekOfYear, value: -offset, to: start) {
                sessions.append(.init(date: day, sets: 10, volume: 3_000))
            }
        }
        sessions.append(.init(date: calendar.startOfDay(for: date), sets: 12, volume: 5_200))
        return .init(date: date, summary: ThisWeekWidgetHistory(sessions: sessions).summary(at: date), unit: .pounds)
    }
}

private struct ThisWeekProvider: TimelineProvider {
    func placeholder(in context: Context) -> ThisWeekEntry { .sample() }

    func getSnapshot(in context: Context, completion: @escaping (ThisWeekEntry) -> Void) {
        completion(context.isPreview ? .sample() : entry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ThisWeekEntry>) -> Void) {
        let now = Date()
        let midnight = ThisWeekWidgetHistory.nextMidnight(after: now)
        let history = ThisWeekWidgetCache.load()
        let unit = ThisWeekWidgetCache.displayUnit
        // Include midnight itself so today/week rollover does not depend on the
        // system granting a new background refresh exactly at the boundary.
        let entries = [now, midnight].map {
            ThisWeekEntry(date: $0, summary: history?.summary(at: $0), unit: unit)
        }
        completion(Timeline(entries: entries, policy: .after(midnight)))
    }

    private func entry(at date: Date) -> ThisWeekEntry {
        .init(date: date, summary: ThisWeekWidgetCache.load()?.summary(at: date), unit: ThisWeekWidgetCache.displayUnit)
    }
}

private struct ThisWeekWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: ThisWeekEntry

    private var monochrome: Bool {
        family == .accessoryRectangular || family == .accessoryCircular || renderingMode != .fullColor
    }

    var body: some View {
        Group {
            if let summary = entry.summary {
                switch family {
                case .accessoryCircular:
                    circular(summary).widgetAccentable()
                case .accessoryRectangular:
                    rectangular(summary).widgetAccentable()
                case .systemMedium:
                    medium(summary)
                default:
                    small(summary)
                }
            } else {
                unavailable
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        // No Home/feed deep link exists. The default tap opens Light normally.
    }

    private var caption: some View {
        Text("This Week")
            .font(.caption.weight(.semibold))
            .foregroundStyle(monochrome ? Color.primary : IronTheme.secondaryText)
            .lineLimit(1)
    }

    private func small(_ summary: ThisWeekWidgetSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            caption
            Spacer(minLength: 0)
            bars(summary, height: 48)
            Spacer(minLength: 0)
            streakOrCount(summary)
        }
    }

    private func medium(_ summary: ThisWeekWidgetSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                caption
                Spacer(minLength: 0)
                streakOrCount(summary)
            }
            HStack(alignment: .top, spacing: 12) {
                metric("Workouts", value: "\(summary.workouts)", tint: IronTheme.accent)
                metric("Sets", value: "\(summary.sets)", tint: IronTheme.metricSets)
                metric("Volume", value: entry.volume(summary.volume), unit: entry.unit.symbol, tint: IronTheme.metricVolume)
            }
            bars(summary, height: 28)
        }
    }

    private func metric(_ label: String, value: String, unit: String? = nil, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.ironMetric(.title2))
                    .foregroundStyle(monochrome ? Color.primary : tint)
                    .widgetAccentable()
                if let unit {
                    Text(unit)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(monochrome ? Color.secondary : IronTheme.secondaryText)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            Text(label)
                .font(.caption2)
                .foregroundStyle(monochrome ? Color.secondary : IronTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value + (unit.map { " " + $0 } ?? ""))
    }

    private func streakOrCount(_ summary: ThisWeekWidgetSummary) -> some View {
        Label {
            Text(summary.streak >= 2 ? "\(summary.streak) wk" : workoutCount(summary))
                .font(.ironMetric(.caption))
        } icon: {
            Image(systemName: summary.streak >= 2 ? "flame.fill" : "figure.strengthtraining.traditional")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(monochrome ? Color.primary : IronTheme.accent)
        .padding(.horizontal, 8)
        .frame(minHeight: 24)
        .background(monochrome ? Color.primary.opacity(0.12) : IronTheme.accentSoft, in: Capsule())
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .widgetAccentable()
        .accessibilityLabel(summary.streak >= 2 ? "\(summary.streak) week training streak" : "\(workoutCount(summary)) this week")
    }

    private func rectangular(_ summary: ThisWeekWidgetSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(workoutCount(summary)) · \(summary.streak)-wk streak")
                .font(.ironMetric(.caption, weight: .semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            bars(summary, height: 14, showsWeekdays: false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This week")
        .accessibilityValue("\(workoutCount(summary)), \(summary.streak) week training streak. \(daySummary(summary))")
    }

    private func circular(_ summary: ThisWeekWidgetSummary) -> some View {
        Gauge(value: Double(min(summary.workouts, summary.workoutTarget)), in: 0...Double(summary.workoutTarget)) {
            Image(systemName: "figure.strengthtraining.traditional")
        } currentValueLabel: {
            Text("\(summary.workouts)").font(.ironMetric(.title2))
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Workouts this week")
        .accessibilityValue("\(summary.workouts) of \(summary.workoutTarget)")
    }

    private func bars(_ summary: ThisWeekWidgetSummary, height: CGFloat, showsWeekdays: Bool = true) -> some View {
        VStack(spacing: 2) {
            // Matches Home's week chart: volume-colored bars on a faint baseline, no tracks.
            Chart {
                RuleMark(y: .value("Baseline", 0))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(monochrome ? Color.primary.opacity(0.18) : IronTheme.tertiaryFill)
                ForEach(summary.days) { day in
                    BarMark(x: .value("Day", Double(day.index)), yStart: .value("Baseline", 0),
                            yEnd: .value("Volume", day.volume), width: .ratio(0.5))
                        .cornerRadius(3)
                        .foregroundStyle(monochrome ? Color.primary : IronTheme.metricVolume)
                }
            }
            .chartXScale(domain: -0.5...6.5)
            .chartYScale(domain: 0...maximumVolume(summary))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: height)
            .widgetAccentable()

            if showsWeekdays {
                HStack(spacing: 0) {
                    ForEach(summary.days) { day in
                        Text(day.date.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption2.weight(day.isToday ? .bold : .regular))
                            .foregroundStyle(monochrome ? Color.primary : (day.isToday ? IronTheme.accent : IronTheme.secondaryText))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume by day this week")
        .accessibilityValue(daySummary(summary))
    }

    private func maximumVolume(_ summary: ThisWeekWidgetSummary) -> Double {
        max(summary.days.map(\.volume).max() ?? 0, 1)
    }

    private func daySummary(_ summary: ThisWeekWidgetSummary) -> String {
        summary.days.map {
            "\($0.date.formatted(.dateTime.weekday(.wide)))\($0.isToday ? ", today" : ""), \(entry.volume($0.volume)) \(entry.unit.symbol)"
        }.joined(separator: "; ")
    }

    private func workoutCount(_ summary: ThisWeekWidgetSummary) -> String {
        "\(summary.workouts) \(summary.workouts == 1 ? "workout" : "workouts")"
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "figure.strengthtraining.traditional")
            if family != .accessoryCircular {
                caption
                Text("Open Light to update")
                    .font(.caption2)
                    .lineLimit(2)
            }
        }
        .foregroundStyle(.primary)
        .widgetAccentable()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This Week. Open Light to update workout history.")
    }
}

struct ThisWeekWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.thisWeek.rawValue, provider: ThisWeekProvider()) { entry in
            ThisWeekWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("This Week")
        .description("Your weekly workouts, daily volume and training streak.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

private struct ThisWeekWidget_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ThisWeekWidgetEntryView(entry: .sample())
                .previewContext(WidgetPreviewContext(family: .systemSmall))
            ThisWeekWidgetEntryView(entry: .sample())
                .previewContext(WidgetPreviewContext(family: .systemMedium))
            ThisWeekWidgetEntryView(entry: .sample())
                .previewContext(WidgetPreviewContext(family: .accessoryRectangular))
            ThisWeekWidgetEntryView(entry: .sample())
                .previewContext(WidgetPreviewContext(family: .accessoryCircular))
        }
    }
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), workoutInfo: WorkoutDataStorage.shared.lastWorkoutInfo)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> ()) {
        completion(Entry(date: Date(), workoutInfo: WorkoutDataStorage.shared.lastWorkoutInfo))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
        let date = Date()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: date)!
        let startOfTomorrow = Calendar.current.startOfDay(for: tomorrow)
        
        completion(Timeline(entries: [Entry(date: date, workoutInfo: WorkoutDataStorage.shared.lastWorkoutInfo)], policy: .after(startOfTomorrow)))
    }
}

private extension WorkoutDataStorage {
    var lastWorkoutInfo: WorkoutInfo? {
        let request: NSFetchRequest<Workout> = Workout.fetchRequest()
        request.predicate = NSPredicate(format: "\(#keyPath(Workout.isCurrentWorkout)) != %@", NSNumber(booleanLiteral: true))
        request.sortDescriptors = [.init(keyPath: \Workout.start, ascending: false)]
        request.propertiesToFetch = ["\(#keyPath(Workout.start))", "\(#keyPath(Workout.end))"]
        request.fetchLimit = 1
        do {
            let workouts = try persistentContainer.viewContext.fetch(request)
            assert(workouts.count <= 1) // the request should only fetch the max
            guard let start = workouts.first?.start, let end = workouts.first?.end else { return nil }
            return WorkoutInfo(start: start, end: end)
        } catch {
            fatalError("Could not execute fetch request for last workout date.")
        }
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let workoutInfo: WorkoutInfo?
}

struct WorkoutInfo {
    let start: Date
    let end: Date
    
    var duration: TimeInterval {
        end.timeIntervalSince(start)
    }
}

struct LastWorkoutWidgetEntryView : View {
    @Environment(\.widgetFamily) var widgetFamily
    @Environment(\.calendar) var calendar

    var entry: Provider.Entry

    private var daysSinceLastWorkout: Int? {
        guard let workoutInfo = entry.workoutInfo else { return nil }
        return calendar.calendarDays(from: workoutInfo.start, to: entry.date)
    }

    private var headline: String {
        guard let days = daysSinceLastWorkout else { return "—" }
        switch days {
        case 0: return "Today"
        case 1: return "Yesterday"
        default: return "\(days) days"
        }
    }

    private var detail: String {
        guard let workoutInfo = entry.workoutInfo else {
            return "No workouts logged yet."
        }
        let duration = Duration.seconds(workoutInfo.duration)
            .formatted(.units(allowed: [.hours, .minutes], width: .narrow))
        return "\(duration) · \(workoutInfo.start.formatted(.dateTime.month(.abbreviated).day()))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Last Workout", systemImage: "figure.strengthtraining.traditional")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
                .lineLimit(1)

            Spacer(minLength: 0)

            Text(headline)
                .font(.ironMetric(.title2))
                .foregroundStyle((daysSinceLastWorkout ?? 0) > 1 ? IronTheme.metricTime : IronTheme.primaryText)
                .minimumScaleFactor(0.7)
                .lineLimit(1)

            if let info = entry.workoutInfo {
                (Text(Duration.seconds(info.duration).formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
                    .font(.ironMetric(.caption, weight: .semibold)).foregroundColor(IronTheme.metricTime)
                 + Text(" · " + info.start.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.caption).foregroundColor(IronTheme.secondaryText))
                    .lineLimit(2)
            } else {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(DeepLink.url(for: .startWorkout))
    }
}

private extension Calendar {
    func calendarDays(from: Date, to: Date) -> Int {
        dateComponents([.day], from: startOfDay(for: from), to: to).day!
    }
}

struct LastWorkoutWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.lastWorkout.rawValue, provider: Provider()) { entry in
            LastWorkoutWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Last Workout")
        .description("The number of days since the last workout.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private enum WorkoutActivityPalette {
    static let accent = IronTheme.accent
    static let completion = IronTheme.accent
    static let surface = IronTheme.mediaBackdrop
    static let onSurface = IronTheme.onMedia
    static let secondary = IronTheme.onMedia.opacity(0.65)
    static let onAccent = IronTheme.onAccent
    static let compactCornerRadius: CGFloat = 12
}

struct WorkoutLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            WorkoutLiveActivityContainer(context: context)
                .environment(\.colorScheme, .dark)
                .activityBackgroundTint(WorkoutActivityPalette.surface)
                .activitySystemActionForegroundColor(WorkoutActivityPalette.onSurface)
                .widgetURL(DeepLink.url(for: .startWorkout))
        } dynamicIsland: { context in
            DynamicIsland {
                // A full-width region below the sensor keeps the exercise and
                // its progress inside the island's rounded-corner safe area.
                DynamicIslandExpandedRegion(.bottom) {
                    WorkoutDynamicIslandBottom(context: context)
                }
            } compactLeading: {
                WorkoutDynamicIslandCompactLeading(context: context)
            } compactTrailing: {
                WorkoutDynamicIslandCompactTrailing(context: context)
            } minimal: {
                WorkoutDynamicIslandMinimal(context: context)
            }
            .contentMargins(.horizontal, 20, for: .expanded)
            .contentMargins(.top, 12, for: .expanded)
            .contentMargins(.bottom, 12, for: .expanded)
            .keylineTint(WorkoutActivityPalette.accent)
            .widgetURL(DeepLink.url(for: .startWorkout))
        }
        .supplementalActivityFamiliesCompat()
    }
}

private extension ActivityConfiguration {
    /// The Apple Watch Smart Stack renders the `.small` activity family. Older
    /// systems keep the default (`.medium`) presentation only.
    func supplementalActivityFamiliesCompat() -> some WidgetConfiguration {
        if #available(iOS 18.0, *) {
            return supplementalActivityFamilies([.small])
        } else {
            return self
        }
    }
}

/// Routes to the Apple Watch Smart Stack layout where the system supports the
/// `.small` activity family, and to the Lock Screen layout everywhere else.
private struct WorkoutLiveActivityContainer: View {
    let context: ActivityViewContext<WorkoutActivityAttributes>

    var body: some View {
        if #available(iOS 18.0, watchOS 11.0, *) {
            WorkoutActivityFamilyRouter(context: context)
        } else {
            WorkoutLiveActivityLockScreenView(context: context)
        }
    }
}

@available(iOS 18.0, watchOS 11.0, *)
private struct WorkoutActivityFamilyRouter: View {
    @Environment(\.activityFamily) private var activityFamily
    let context: ActivityViewContext<WorkoutActivityAttributes>

    var body: some View {
        switch activityFamily {
        case .small:
            WorkoutSmartStackView(context: context)
                .foregroundStyle(IronTheme.onMedia)
        default:
            WorkoutLiveActivityLockScreenView(context: context)
        }
    }
}

/// Compact Smart Stack layout for Apple Watch: one glanceable line of state,
/// the live value, and rest controls only when they are actionable.
private struct WorkoutSmartStackView: View {
    let context: ActivityViewContext<WorkoutActivityAttributes>

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let date = workoutPresentationDate(context, timeline.date)
            let phase = context.state.resolvedPhase(at: date)
            let set = context.state.visibleSet(at: date)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    WorkoutActivityExerciseArtwork(set: set, phase: phase, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(set?.exerciseName ?? "Light Workout")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(WorkoutActivityPalette.onSurface)
                            .lineLimit(2)
                        Text(workoutSetPositionTitle(set, phase: phase))
                            .font(.caption2)
                            .foregroundStyle(WorkoutActivityPalette.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    WorkoutActivitySetProgress(set: set, state: context.state, size: 28)
                }

                if phase == .resting, context.state.isRestPaused {
                    WorkoutPausedRestControls(context: context, compact: true)
                } else if phase == .resting, let end = context.state.restTimerEnd {
                    HStack(spacing: 8) {
                        Text("Rest")
                            .font(.caption2)
                            .foregroundStyle(WorkoutActivityPalette.secondary)
                        workoutRestTimerText(until: end)
                            .font(.ironMetric(.body, weight: .semibold))
                            .foregroundStyle(IronTheme.metricTime)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Button(intent: SkipWorkoutRestTimerIntent(workoutID: context.attributes.workoutID)) {
                            Text("Skip").font(.caption2.weight(.semibold))
                                .frame(minWidth: 32, minHeight: 32)
                        }
                        .buttonStyle(WorkoutActivityControlButtonStyle())
                        .accessibilityLabel("Skip rest timer")
                    }
                } else if phase == .currentSet, let set {
                    HStack(spacing: 8) {
                        Text(set.result == "—" || set.result.isEmpty ? "Ready for your next set" : set.result)
                            .font(.ironMetric(.caption, weight: .semibold))
                            .foregroundStyle(WorkoutActivityPalette.onSurface)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        WorkoutActivityCompleteSetButton(
                            workoutID: context.attributes.workoutID, set: set, size: 30
                        )
                    }
                }
            }
        }
    }
}

private struct WorkoutLiveActivityLockScreenView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let context: ActivityViewContext<WorkoutActivityAttributes>

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let presentationDate = workoutPresentationDate(context, timeline.date)
            let phase = context.state.resolvedPhase(at: presentationDate)
            let set = context.state.visibleSet(at: presentationDate)
            let tint = phaseTint(phase)

            // ActivityKit already provides the rounded system surface. Iron contributes
            // hierarchy and color, while avoiding a second card or custom chrome.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "dumbbell.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(tint)
                        .frame(width: 20, height: 20)

                    Text(context.attributes.workoutTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WorkoutActivityPalette.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .allowsTightening(true)

                    Spacer(minLength: 8)

                    WorkoutActivitySetProgress(set: set, state: context.state, size: 28)
                }

                HStack(spacing: 10) {
                    WorkoutActivityExerciseArtwork(
                        set: set,
                        phase: phase,
                        size: 34
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(primaryTitle(phase: phase, set: set))
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(WorkoutActivityPalette.onSurface)
                            .lineLimit(1)
                            .minimumScaleFactor(0.70)
                            .allowsTightening(true)

                        Text(secondaryTitle(phase: phase, set: set))
                            .font(.ironMetric(.caption, weight: .semibold))
                            .foregroundStyle(WorkoutActivityPalette.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.68)
                            .allowsTightening(true)
                    }

                    Spacer(minLength: 4)
                }

                activityProgress(phase: phase, date: presentationDate)

                if phase == .resting, context.state.isRestPaused {
                    WorkoutPausedRestControls(context: context)
                } else if phase == .resting, let end = context.state.restTimerEnd {
                    WorkoutRunningRestControls(
                        workoutID: context.attributes.workoutID,
                        end: end,
                        duration: context.state.restDuration
                    )
                } else {
                    HStack(spacing: 10) {
                        Text(activityResult(set))
                            .font(.ironMetric(.title2, weight: .semibold))
                            .contentTransition(reduceMotion ? .opacity : .numericText())
                            .foregroundStyle(
                                phaseIsCompletion(phase)
                                    ? WorkoutActivityPalette.completion
                                    : WorkoutActivityPalette.onSurface
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.70)

                        Spacer(minLength: 8)

                        Text("\(context.state.completedSets)/\(context.state.totalSets) sets")
                            .font(.ironMetric(.caption, weight: .semibold))
                            .contentTransition(reduceMotion ? .opacity : .numericText())
                            .foregroundStyle(IronTheme.metricSets)
                            .lineLimit(1)

                        if phase == .currentSet, let set {
                            WorkoutActivityCompleteSetButton(
                                workoutID: context.attributes.workoutID,
                                set: set,
                                size: 38
                            )
                        } else {
                            Image(systemName: phaseSystemImage(phase))
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(
                                    phaseIsCompletion(phase)
                                        ? WorkoutActivityPalette.onAccent
                                        : tint
                                )
                                .frame(width: 38, height: 38)
                                .background(
                                    Circle()
                                        .fill(
                                            phaseIsCompletion(phase)
                                                ? tint
                                                : tint.opacity(0.14)
                                        )
                                )
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func primaryTitle(
        phase: WorkoutActivityAttributes.Phase,
        set: WorkoutActivityAttributes.SetSnapshot?
    ) -> String {
        switch phase {
        case .setCompleted: return set?.exerciseName ?? "Set complete"
        case .resting: return set?.exerciseName ?? "Rest"
        case .finished: return "Workout complete"
        case .currentSet: return set?.exerciseName ?? "Workout"
        }
    }

    private func secondaryTitle(
        phase: WorkoutActivityAttributes.Phase,
        set: WorkoutActivityAttributes.SetSnapshot?
    ) -> String {
        guard let set else {
            return "\(context.state.completedSets) of \(context.state.totalSets) sets"
        }
        switch phase {
        case .setCompleted:
            return "Set \(set.setNumber) of \(set.setCount) complete · \(activityResult(set))"
        case .resting:
            return "Next: set \(set.setNumber) of \(set.setCount) · \(activityResult(set))"
        case .currentSet:
            return "Set \(set.setNumber) of \(set.setCount) · \(activityResult(set))"
        case .finished:
            return "\(context.state.completedSets) sets logged"
        }
    }

    @ViewBuilder
    private func activityProgress(
        phase: WorkoutActivityAttributes.Phase,
        date: Date
    ) -> some View {
        if phase == .resting {
            WorkoutRestProgressView(state: context.state, date: date)
        } else {
            let progress = context.state.totalSets > 0
                ? Double(context.state.completedSets) / Double(context.state.totalSets)
                : 0
            Capsule(style: .continuous)
                .fill(WorkoutActivityPalette.secondary.opacity(0.20))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule(style: .continuous)
                            .fill(phaseTint(phase))
                            .frame(width: proxy.size.width * min(max(progress, 0), 1))
                    }
                }
        }
    }

    private func phaseSystemImage(_ phase: WorkoutActivityAttributes.Phase) -> String {
        switch phase {
        case .currentSet: return "checkmark"
        case .setCompleted: return "checkmark"
        case .resting: return "forward.fill"
        case .finished: return "checkmark.seal.fill"
        }
    }

    private func activityResult(_ set: WorkoutActivityAttributes.SetSnapshot?) -> String {
        guard let result = set?.result, result != "—" else {
            return "Enter weight & reps"
        }
        return result
    }

}

/// Exercise identity stays visible during rest. ActivityKit uses a cached still,
/// never a GIF or a remote request in the rendered activity.
private struct WorkoutActivityExerciseArtwork: View {
    let set: WorkoutActivityAttributes.SetSnapshot?
    let phase: WorkoutActivityAttributes.Phase
    let size: CGFloat

    var body: some View {
        Group {
            if let fileURL = WorkoutLiveActivityArtwork.fileURL(for: set?.artworkFileName),
               let image = UIImage(contentsOfFile: fileURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.17)
                    .frame(width: size, height: size)
                    .background(IronTheme.diagramCanvas, in: Circle())
                    .clipShape(Circle())
            } else {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(IronTheme.accent)
                    .frame(width: size, height: size)
                    .background(IronTheme.accentSoft, in: Circle())
            }
        }
        .accessibilityHidden(true)
    }
}

/// Timer-based ProgressView is rendered by the system between ActivityKit updates.
/// A TimelineView-derived width freezes as soon as the widget process is suspended.
private struct WorkoutRestProgressView: View {
    let state: WorkoutActivityAttributes.ContentState
    let date: Date

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(WorkoutActivityPalette.secondary.opacity(0.20))

            if state.isRestPaused {
                // A missing interval means the producer supplied only remaining
                // seconds. Leave the track neutral rather than imply set progress.
                if let progress = state.restProgress(at: date) {
                    GeometryReader { proxy in
                        Capsule(style: .continuous)
                            .fill(IronTheme.metricTime)
                            .frame(width: proxy.size.width * progress)
                    }
                }
            } else if let interval = state.restTimerInterval {
                ProgressView(timerInterval: interval, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.linear)
                .tint(IronTheme.metricTime)
                .labelsHidden()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 4)
        .clipShape(Capsule(style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rest progress")
        .accessibilityValue(accessibilityValue)
        .invalidatableContent(false)
        .unredacted()
    }

    private var accessibilityValue: Text {
        let total = state.restDuration.map { " of \(workoutRestSpokenDuration($0))" }
            ?? ", total unavailable"
        if state.isRestPaused, let remaining = state.pausedRestRemaining {
            return Text("\(workoutRestSpokenDuration(remaining)) left\(total), paused")
        }
        if let end = state.restTimerInterval?.upperBound {
            // Keep VoiceOver's remaining time system-driven too, using the same
            // wide interval as the visible countdown to avoid timer placeholders.
            return Text(timerInterval: end.addingTimeInterval(-24 * 60 * 60)...end,
                        countsDown: true, showsHours: false)
                + Text(" left\(total)")
        }
        return Text("Rest time unavailable")
    }
}

private struct WorkoutRestTotalLabel: View {
    let duration: TimeInterval?

    var body: some View {
        if let duration {
            Text("of \(workoutRestDurationText(duration))")
                .font(.ironMetric(.caption2, weight: .semibold))
                .foregroundStyle(WorkoutActivityPalette.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .accessibilityLabel("Total rest \(workoutRestSpokenDuration(duration))")
                .contentTransition(.identity)
                .invalidatableContent(false)
                .unredacted()
        }
    }
}

private func workoutRestSeconds(_ duration: TimeInterval) -> Int {
    duration.isFinite ? Int(min(max(duration.rounded(.up), 0), 86_400)) : 0
}

private func workoutRestDurationText(_ duration: TimeInterval) -> String {
    let seconds = workoutRestSeconds(duration)
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

private func workoutRestSpokenDuration(_ duration: TimeInterval) -> String {
    Duration.seconds(workoutRestSeconds(duration))
        .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
}

/// Keep Skip anchored at the trailing edge while the three rest controls
/// share the remaining space equally on both full-size activity surfaces.
private struct WorkoutRunningRestControls: View {
    let workoutID: String
    let end: Date
    let duration: TimeInterval?
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(intent: AdjustWorkoutRestTimerIntent(
                    workoutID: workoutID,
                    seconds: -15
                )) {
                    Text("−15s")
                }
                .buttonStyle(WorkoutActivityControlButtonStyle(fillsWidth: true))
                .frame(minWidth: 0, maxWidth: .infinity)
                .accessibilityLabel("Subtract 15 seconds")

                VStack(spacing: 2) {
                    workoutRestTimerText(until: end)
                        .font(.ironMetric(compact ? .title3 : .title2))
                        .foregroundStyle(IronTheme.metricTime)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)

                    WorkoutRestTotalLabel(duration: duration)
                }
                .multilineTextAlignment(.center)
                .frame(minWidth: 0, maxWidth: .infinity)
                .accessibilityElement(children: .combine)

                Button(intent: AdjustWorkoutRestTimerIntent(
                    workoutID: workoutID,
                    seconds: 15
                )) {
                    Text("+15s")
                }
                .buttonStyle(WorkoutActivityControlButtonStyle(fillsWidth: true))
                .frame(minWidth: 0, maxWidth: .infinity)
                .accessibilityLabel("Add 15 seconds")
            }
            .frame(maxWidth: .infinity)

            Button(intent: SkipWorkoutRestTimerIntent(
                workoutID: workoutID
            )) {
                Text("Skip")
            }
            .buttonStyle(WorkoutActivityControlButtonStyle(isProminent: true))
            .accessibilityLabel("Skip rest timer")
        }
    }
}

private struct WorkoutActivityControlButtonStyle: ButtonStyle {
    var isProminent = false
    var fillsWidth = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ironMetric(.caption, weight: .semibold))
            .foregroundStyle(
                isProminent
                    ? WorkoutActivityPalette.onAccent
                    : WorkoutActivityPalette.onSurface
            )
            .frame(minWidth: 52, maxWidth: fillsWidth ? .infinity : nil, minHeight: 38)
            .padding(.horizontal, isProminent ? 4 : 0)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        isProminent
                            ? WorkoutActivityPalette.accent
                            : WorkoutActivityPalette.secondary.opacity(0.18)
                    )
            )
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct WorkoutActivityCompletionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(WorkoutActivityPalette.onAccent)
            .background(
                Circle()
                    .fill(WorkoutActivityPalette.accent)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

private struct WorkoutActivityCompleteSetButton: View {
    let workoutID: String
    let set: WorkoutActivityAttributes.SetSnapshot
    let size: CGFloat

    @ViewBuilder
    var body: some View {
        if let setID = set.setID {
            Button(intent: CompleteWorkoutSetIntent(
                workoutID: workoutID,
                setID: setID
            )) {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .frame(width: size, height: size)
            }
            .buttonStyle(WorkoutActivityCompletionButtonStyle())
            .accessibilityLabel("Complete set \(set.setNumber)")
        }
    }
}

private struct WorkoutDynamicIslandBottom: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let context: ActivityViewContext<WorkoutActivityAttributes>

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let presentationDate = workoutPresentationDate(context, timeline.date)
            let phase = context.state.resolvedPhase(at: presentationDate)
            let set = context.state.visibleSet(at: presentationDate)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    WorkoutActivityExerciseArtwork(set: set, phase: phase, size: 30)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(dynamicTitle(phase: phase, set: set))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(
                                phaseIsCompletion(phase)
                                    ? WorkoutActivityPalette.completion
                                    : WorkoutActivityPalette.onSurface
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.70)

                        Text(dynamicSubtitle(phase: phase, set: set))
                            .font(.ironMetric(.caption2, weight: .semibold))
                            .foregroundStyle(WorkoutActivityPalette.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.68)
                    }

                    Spacer(minLength: 4)
                    WorkoutActivitySetProgress(set: set, state: context.state, size: 28)
                }

                if phase == .resting {
                    VStack(spacing: 8) {
                        WorkoutRestProgressView(state: context.state, date: presentationDate)

                        if context.state.isRestPaused {
                            WorkoutPausedRestControls(context: context)
                                .padding(.horizontal, 12)
                        } else if let end = context.state.restTimerEnd {
                            WorkoutRunningRestControls(
                                workoutID: context.attributes.workoutID,
                                end: end,
                                duration: context.state.restDuration,
                                compact: true
                            )
                            .padding(.horizontal, 12)
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        Text(dynamicResult(set))
                            .font(.ironMetric(.title3, weight: .semibold))
                            .contentTransition(reduceMotion ? .opacity : .numericText())
                            .foregroundStyle(
                                phaseIsCompletion(phase)
                                    ? WorkoutActivityPalette.completion
                                    : WorkoutActivityPalette.onSurface
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.68)
                            .allowsTightening(true)
                        Spacer(minLength: 4)
                        Text("\(context.state.completedSets)/\(context.state.totalSets) sets")
                            .font(.ironMetric(.caption2, weight: .semibold))
                            .contentTransition(reduceMotion ? .opacity : .numericText())
                            .foregroundStyle(IronTheme.metricSets)
                            .lineLimit(1)

                        if phase == .currentSet, let set {
                            WorkoutActivityCompleteSetButton(
                                workoutID: context.attributes.workoutID,
                                set: set,
                                size: 34
                            )
                        } else {
                            Image(systemName: phaseIsCompletion(phase) ? "checkmark.circle.fill" : "checkmark.seal.fill")
                                .font(.title3)
                                .foregroundStyle(WorkoutActivityPalette.completion)
                        }
                    }
                }
            }
        }
    }

    private func dynamicTitle(
        phase: WorkoutActivityAttributes.Phase,
        set: WorkoutActivityAttributes.SetSnapshot?
    ) -> String {
        if phase == .finished { return "Workout complete" }
        return set?.exerciseName ?? "Workout"
    }

    private func dynamicSubtitle(
        phase: WorkoutActivityAttributes.Phase,
        set: WorkoutActivityAttributes.SetSnapshot?
    ) -> String {
        let position = workoutSetPositionTitle(set, phase: phase)
        return phase == .resting ? "Next · " + position : position
    }

    private func dynamicResult(_ set: WorkoutActivityAttributes.SetSnapshot?) -> String {
        guard let result = set?.result, result != "—" else {
            return "Enter weight & reps"
        }
        return result
    }
}


/// Optional snapshot counts keep activities from older builds readable until
/// the app publishes a fresh state. Never infer completions from the set ordinal.
private struct WorkoutActivitySetProgress: View {
    let set: WorkoutActivityAttributes.SetSnapshot?
    let state: WorkoutActivityAttributes.ContentState
    let size: CGFloat

    private var total: Int { max(set?.setCount ?? state.totalSets, 0) }
    private var completed: Int? {
        if let set { return set.completedSetCount.map { min(max($0, 0), total) } }
        return min(max(state.completedSets, 0), total)
    }

    var body: some View {
        Group {
            if let completed {
                WorkoutSetProgressTile(completed: completed, total: total, size: size)
                    .accessibilityLabel("\(set?.exerciseName ?? "Workout") progress")
                    .accessibilityValue(total == 0 ? "No sets yet" : "\(completed) of \(total) sets done")
            } else if let set {
                Text("\(set.setNumber)/\(set.setCount)")
                    .font(.ironMetric(.caption2, weight: .semibold))
                    .foregroundStyle(WorkoutActivityPalette.onSurface)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityLabel("Set \(set.setNumber) of \(set.setCount)")
            }
        }
    }
}

private struct WorkoutSetProgressTile: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let completed: Int
    let total: Int
    let size: CGFloat

    private var cells: Int { min(max(total, 1), 12) }
    private var columns: Int { cells == 1 ? 1 : (cells <= 4 ? 2 : 3) }
    private var rows: Int { (cells + columns - 1) / columns }
    private var progress: Double {
        guard total > 0 else { return 0 }
        return Double(min(max(completed, 0), total)) / Double(total)
    }

    var body: some View {
        GeometryReader { geometry in
            let gap: CGFloat = 2
            let width = (geometry.size.width - CGFloat(columns - 1) * gap) / CGFloat(columns)
            let height = (geometry.size.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
            let side = max(0, min(width, height))
            let originX = (geometry.size.width - (CGFloat(columns) * side + CGFloat(columns - 1) * gap)) / 2
            let originY = (geometry.size.height - (CGFloat(rows) * side + CGFloat(rows - 1) * gap)) / 2
            ZStack(alignment: .topLeading) {
                ForEach(0..<cells, id: \.self) { cell in
                    let fill = min(max(progress * Double(cells) - Double(cell), 0), 1)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(WorkoutActivityPalette.secondary.opacity(0.45))
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(IronTheme.accent)
                                .scaleEffect(x: 1, y: CGFloat(fill), anchor: .bottom)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                        .frame(width: side, height: side)
                        .position(
                            x: originX + CGFloat(cell % columns) * (side + gap) + side / 2,
                            y: originY + CGFloat(cell / columns) * (side + gap) + side / 2
                        )
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: completed)
    }
}

private func workoutSetPositionTitle(
    _ set: WorkoutActivityAttributes.SetSnapshot?,
    phase: WorkoutActivityAttributes.Phase
) -> String {
    if phase == .finished { return "Workout complete" }
    guard let set else { return "Open Light to add sets" }
    if phase == .setCompleted { return "Set \(set.setNumber) complete" }
    return "Set \(set.setNumber) of \(set.setCount)"
}

private struct WorkoutDynamicIslandCompactLeading: View {
    let context: ActivityViewContext<WorkoutActivityAttributes>

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let date = workoutPresentationDate(context, timeline.date)
            WorkoutActivityExerciseArtwork(
                set: context.state.visibleSet(at: date),
                phase: context.state.resolvedPhase(at: date),
                size: 24
            )
        }
    }
}

private struct WorkoutDynamicIslandCompactTrailing: View {
    let context: ActivityViewContext<WorkoutActivityAttributes>

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let date = workoutPresentationDate(context, timeline.date)
            WorkoutActivitySetProgress(
                set: context.state.visibleSet(at: date), state: context.state, size: 20
            )
            .padding(.trailing, 6)
            .frame(height: 24)
        }
    }
}

private struct WorkoutPausedRestControls: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let context: ActivityViewContext<WorkoutActivityAttributes>
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Paused")
                    .font(.caption2)
                    .foregroundStyle(WorkoutActivityPalette.secondary)
                Text(remainingText)
                    .font(.ironMetric(.title3, weight: .semibold))
                    .contentTransition(reduceMotion ? .opacity : .numericText())
                    .foregroundStyle(IronTheme.metricTime)
                WorkoutRestTotalLabel(duration: context.state.restDuration)
            }
            Spacer(minLength: 4)
            Button(intent: ResumeWorkoutRestTimerIntent(workoutID: context.attributes.workoutID)) {
                Image(systemName: "play.fill")
            }
            .buttonStyle(WorkoutActivityControlButtonStyle(isProminent: true))
            .accessibilityLabel("Resume rest timer")
            if !compact {
                Button(intent: SkipWorkoutRestTimerIntent(workoutID: context.attributes.workoutID)) {
                    Text("Skip")
                }
                .buttonStyle(WorkoutActivityControlButtonStyle())
                .accessibilityLabel("Skip rest timer")
            }
        }
    }

    private var remainingText: String {
        workoutRestDurationText(context.state.pausedRestRemaining ?? 0)
    }
}

private struct WorkoutDynamicIslandMinimal: View {
    let context: ActivityViewContext<WorkoutActivityAttributes>

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let date = workoutPresentationDate(context, timeline.date)
            WorkoutActivitySetProgress(
                set: context.state.visibleSet(at: date), state: context.state, size: 20
            )
        }
    }
}

/// `TimelineView` animates system timer text, but Live Activities don't receive widget
/// timeline entries. Referencing `isStale` ensures ActivityKit re-evaluates the phase when
/// the app-provided stale date reaches a confirmation or rest boundary.
private func workoutPresentationDate(
    _ context: ActivityViewContext<WorkoutActivityAttributes>,
    _ timelineDate: Date
) -> Date {
    context.isStale ? Date.now : timelineDate
}

@ViewBuilder
private func workoutRestTimerText(until end: Date) -> some View {
    // Keep the current date inside the interval even when a 10-minute preset is
    // extended from the app or watch. SwiftUI otherwise waits for the lower
    // bound and briefly renders placeholder seconds in the Live Activity.
    let start = end.addingTimeInterval(-24 * 60 * 60)
    Text(
        timerInterval: start...end,
        countsDown: true,
        showsHours: false
    )
    // The system keeps counting while the intent updates the deadline. Avoid
    // invalidation shimmer and replacement fades on each ±15-second action.
    .contentTransition(.identity)
    .invalidatableContent(false)
    .unredacted()
    .transaction { transaction in
        transaction.animation = nil
        transaction.disablesAnimations = true
    }
}

private func phaseSystemImage(_ phase: WorkoutActivityAttributes.Phase) -> String {
    switch phase {
    case .currentSet: return "dumbbell.fill"
    case .setCompleted: return "checkmark"
    case .resting: return "timer"
    case .finished: return "checkmark.seal.fill"
    }
}

private func phaseTint(_ phase: WorkoutActivityAttributes.Phase) -> Color {
    phase == .resting ? IronTheme.metricTime : WorkoutActivityPalette.accent
}

private func phaseIsCompletion(_ phase: WorkoutActivityAttributes.Phase) -> Bool {
    phase == .setCompleted || phase == .finished
}

@main
struct IronWidgetBundle: WidgetBundle {
    var body: some Widget {
        LastWorkoutWidget()
        ThisWeekWidget()
        WorkoutLiveActivityWidget()
    }
}

struct IronWidget_Previews: PreviewProvider {
    static let start = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
    static let end = Calendar.current.date(byAdding: .minute, value: 72, to: start)!
    
    static var previews: some View {
        Group {
            LastWorkoutWidgetEntryView(entry: Entry(date: Date(), workoutInfo: nil))
                .previewContext(WidgetPreviewContext(family: .systemSmall))
            
            LastWorkoutWidgetEntryView(entry: Entry(date: Date(), workoutInfo: WorkoutInfo(start: start, end: end)))
                .previewContext(WidgetPreviewContext(family: .systemSmall))

            LastWorkoutWidgetEntryView(entry: Entry(date: Date(), workoutInfo: WorkoutInfo(start: start, end: end)))
                .previewContext(WidgetPreviewContext(family: .systemSmall))
                .environment(\.colorScheme, .dark)
        }
    }
}
