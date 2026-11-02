import SwiftUI

/// The session, exercise by exercise, with every set's result, effort and rest.
/// Callers own completion order, display-unit volumes and record classification.
/// Work without a recorded duration is estimated at 40 seconds; a set without a
/// completion time still lists its result, with no rest or time position.
struct IronSessionStrip: View {
    struct ExerciseGroup {
        let label: String
        let sets: [Set]
    }

    struct Set {
        var kind: Kind = .normal
        var completedAt: Date?
        var duration: TimeInterval?
        var volume: Double = 0
        var result: String = ""
        var rpe: Double?

        enum Kind {
            case warmUp, normal, record
        }

        fileprivate var workDuration: TimeInterval {
            guard let duration, duration.isFinite, duration > 0 else { return 40 }
            return duration
        }

        fileprivate var hasCompletionTime: Bool {
            completedAt?.timeIntervalSinceReferenceDate.isFinite == true
        }

        fileprivate var chartVolume: Double {
            volume.isFinite ? max(volume, 0) : 0
        }
    }

    let accessibilityLabel: String
    let volumeUnit: String
    private let summary: Summary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var setColumnWidth: CGFloat = 26
    @ScaledMetric(relativeTo: .footnote) private var resultColumnWidth: CGFloat = 96
    @ScaledMetric(relativeTo: .caption) private var rpeColumnWidth: CGFloat = 26
    @ScaledMetric(relativeTo: .caption) private var restColumnWidth: CGFloat = 38
    @State private var hasAppeared = false

    private struct Row: Identifiable {
        let id: Int
        let label: String
        let set: Set
        let rest: TimeInterval?
    }

    private struct Exercise: Identifiable {
        let id: Int
        let title: String
        let rows: [Row]
        let maximumVolume: Double
        let totalVolume: Double
        /// When it ran, as fractions of the session.
        let span: ClosedRange<Double>?
        let minutes: Int?
    }

    /// Built once per input update.
    private struct Summary {
        var exercises: [Exercise] = []
        var rests: [TimeInterval] = []

        var showsRPE: Bool { exercises.contains { $0.rows.contains { ($0.set.rpe ?? 0) > 0 } } }
        var showsRest: Bool { !rests.isEmpty }

        init(groups: [ExerciseGroup], sessionStart: Date?) {
            var ordered: [(id: Int, label: String, set: Set)] = []
            for group in groups {
                for set in group.sets {
                    ordered.append((ordered.count, group.label, set))
                }
            }

            let timed = ordered.filter { $0.set.hasCompletionTime }.sorted {
                let lhs = $0.set.completedAt!
                let rhs = $1.set.completedAt!
                return lhs == rhs ? $0.id < $1.id : lhs < rhs
            }
            var times: [Int: ClosedRange<TimeInterval>] = [:]
            var restBefore: [Int: TimeInterval] = [:]
            var sessionEnd: TimeInterval = 0
            if let first = timed.first {
                let firstWork = first.set.completedAt!.addingTimeInterval(-first.set.workDuration)
                let origin: Date
                if let sessionStart, sessionStart <= firstWork,
                   firstWork.timeIntervalSince(sessionStart) <= 120 {
                    origin = sessionStart
                } else {
                    origin = firstWork
                }
                var previous: (id: Int, end: TimeInterval)?
                for item in timed {
                    let end = item.set.completedAt!.timeIntervalSince(origin)
                    // Overlapping work (e.g. supersets) must not double-count time.
                    let start = min(end, max(previous?.end ?? 0, end - item.set.workDuration))
                    if let previous, start > previous.end {
                        let lower = min(previous.id, item.id)
                        let upper = max(previous.id, item.id)
                        let hasMissingTime = ordered.contains {
                            $0.id > lower && $0.id < upper && !$0.set.hasCompletionTime
                        }
                        if !hasMissingTime {
                            restBefore[item.id] = start - previous.end
                            rests.append(start - previous.end)
                        }
                    }
                    times[item.id] = start...end
                    previous = (item.id, end)
                }
                // Never extend to workout.end: an idle finish editor isn't activity.
                sessionEnd = previous?.end ?? 0
            }

            // Superset rounds alternate exercises, so their sets gather under one heading.
            var titles: [String] = []
            for item in ordered where !titles.contains(item.label) {
                titles.append(item.label)
            }
            for (index, title) in titles.enumerated() {
                let items = ordered.filter { $0.label == title }
                var workingSetNumber = 0
                let rows = items.map { item -> Row in
                    if item.set.kind != .warmUp { workingSetNumber += 1 }
                    return Row(id: item.id, label: item.set.kind == .warmUp ? "W" : "\(workingSetNumber)",
                               set: item.set, rest: restBefore[item.id])
                }
                let ranges = items.compactMap { times[$0.id] }
                var span: ClosedRange<Double>?
                var minutes: Int?
                if let start = ranges.map(\.lowerBound).min(), let end = ranges.map(\.upperBound).max(), sessionEnd > 0 {
                    span = (start / sessionEnd)...(end / sessionEnd)
                    minutes = max(1, Int(((end - start) / 60).rounded()))
                }
                exercises.append(.init(
                    id: index,
                    title: title,
                    rows: rows,
                    maximumVolume: items.map(\.set.chartVolume).max() ?? 0,
                    totalVolume: items.reduce(0) { $0 + $1.set.chartVolume },
                    span: span,
                    minutes: minutes
                ))
            }
        }
    }

    init(groups: [ExerciseGroup], accessibilityLabel: String, sessionStart: Date? = nil, volumeUnit: String = "") {
        self.accessibilityLabel = accessibilityLabel
        self.volumeUnit = volumeUnit
        self.summary = Summary(groups: groups.filter { !$0.sets.isEmpty }, sessionStart: sessionStart)
    }

    private var usesStackedRows: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            restSummary
            ForEach(summary.exercises) { exercise in
                Divider()
                exerciseSection(exercise)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilityLabel))
        .task { hasAppeared = true }
    }

    @ViewBuilder
    private var restSummary: some View {
        if summary.rests.isEmpty {
            Text("Rest times weren't recorded for this workout.")
                .font(.caption)
                .foregroundStyle(IronTheme.secondaryText)
        } else {
            let total = summary.rests.reduce(0, +)
            let layout = usesStackedRows
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            layout {
                restStat("Total Rest", restTotal(total))
                restStat("Avg Rest", restDuration(total / Double(summary.rests.count)))
                restStat("Longest", restDuration(summary.rests.max() ?? 0))
            }
        }
    }

    private func restStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(IronTheme.secondaryText)
            Text(value)
                .font(.ironMetric(.title3, weight: .semibold))
                .foregroundStyle(IronTheme.metricTime)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func exerciseSection(_ exercise: Exercise) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(exercise.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(IronTheme.primaryText)
                        .lineLimit(usesStackedRows ? nil : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if exercise.totalVolume > 0 {
                        IronMetricValue(
                            value: exercise.totalVolume.formatted(.number.precision(.fractionLength(0))),
                            unit: volumeUnit,
                            style: .subheadline, weight: .semibold, unitStyle: .caption,
                            tint: IronTheme.metricVolume
                        )
                        .lineLimit(1)
                        .fixedSize()
                    }
                }
                HStack(spacing: 8) {
                    Text(exerciseDetail(exercise))
                        .font(.caption)
                        .foregroundStyle(IronTheme.secondaryText)
                        .fixedSize(horizontal: !usesStackedRows, vertical: true)
                    if let span = exercise.span, !usesStackedRows {
                        IronSessionSpan(span: span)
                            .accessibilityHidden(true)
                    }
                }
            }
            .accessibilityElement(children: .combine)

            if !usesStackedRows {
                columnHeader
            }
            VStack(alignment: .leading, spacing: usesStackedRows ? 10 : 6) {
                ForEach(exercise.rows) { row in
                    Group {
                        if usesStackedRows {
                            stackedRow(row, in: exercise)
                        } else {
                            setRow(row, in: exercise)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(rowDescription(row))
                }
            }
        }
    }

    private func exerciseDetail(_ exercise: Exercise) -> String {
        let count = exercise.rows.count
        let sets = "\(count) \(count == 1 ? "set" : "sets")"
        return exercise.minutes.map { "\(sets) · \($0) min" } ?? sets
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("SET").frame(width: setColumnWidth, alignment: .leading)
            Text("RESULT").frame(width: resultColumnWidth, alignment: .leading)
            Text("VOLUME").frame(maxWidth: .infinity, alignment: .leading)
            if summary.showsRPE {
                Text("RPE").frame(width: rpeColumnWidth, alignment: .trailing)
            }
            if summary.showsRest {
                Text("REST").frame(width: restColumnWidth, alignment: .trailing)
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(IronTheme.secondaryText)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityHidden(true)
    }

    private func setRow(_ row: Row, in exercise: Exercise) -> some View {
        HStack(spacing: 8) {
            Text(row.label)
                .font(.ironMetric(.caption, weight: .semibold))
                .foregroundStyle(row.set.kind == .warmUp ? IronTheme.metricSets : IronTheme.secondaryText)
                .frame(width: setColumnWidth, alignment: .leading)
            resultLabel(row)
                .frame(width: resultColumnWidth, alignment: .leading)
            volumeBar(row, in: exercise)
            if summary.showsRPE {
                rpeLabel(row)
                    .frame(width: rpeColumnWidth, alignment: .trailing)
            }
            if summary.showsRest {
                restLabel(row)
                    .frame(width: restColumnWidth, alignment: .trailing)
            }
        }
    }

    private func stackedRow(_ row: Row, in exercise: Exercise) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(row.label)
                    .font(.ironMetric(.caption, weight: .semibold))
                    .foregroundStyle(row.set.kind == .warmUp ? IronTheme.metricSets : IronTheme.secondaryText)
                resultLabel(row)
            }
            volumeBar(row, in: exercise)
            HStack(spacing: 12) {
                if (row.set.rpe ?? 0) > 0 { rpeLabel(row) }
                if row.rest != nil { restLabel(row) }
            }
        }
    }

    private func resultLabel(_ row: Row) -> some View {
        HStack(spacing: 3) {
            Text(row.set.result.isEmpty ? "Completed" : row.set.result)
                .font(.ironMetric(.footnote, weight: .semibold))
                .foregroundStyle(row.set.kind == .warmUp ? IronTheme.secondaryText : IronTheme.primaryText)
                .lineLimit(usesStackedRows ? nil : 1)
                .minimumScaleFactor(0.75)
            if row.set.kind == .record {
                Image(systemName: "trophy.fill")
                    .font(.caption2)
                    .foregroundStyle(IronTheme.metricRecord)
            }
        }
    }

    /// Scaled within the exercise, so one heavy machine can't flatten every other set.
    /// Bars stay one color: warm-ups are labeled W and records carry a trophy.
    private func volumeBar(_ row: Row, in exercise: Exercise) -> some View {
        GeometryReader { proxy in
            if row.set.chartVolume > 0, exercise.maximumVolume > 0 {
                Capsule()
                    .fill(row.set.kind == .warmUp ? IronTheme.tertiaryText : IronTheme.accent)
                    .frame(width: max(6, proxy.size.width * row.set.chartVolume / exercise.maximumVolume))
                    .scaleEffect(x: hasAppeared || reduceMotion ? 1 : 0, anchor: .leading)
                    .animation(IronMotion.preferred(
                        IronMotion.snappy.delay(Double(row.id) * 0.02), reduceMotion: reduceMotion
                    ), value: hasAppeared)
            }
        }
        .frame(height: 6)
    }

    private func rpeLabel(_ row: Row) -> some View {
        let rpe = row.set.rpe.flatMap { $0 > 0 ? $0 : nil }
        return Text(rpe.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "–")
            .font(.ironMetric(.caption, weight: .semibold))
            .foregroundStyle(rpe == nil ? IronTheme.tertiaryText : IronTheme.metricEffort)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    private func restLabel(_ row: Row) -> some View {
        Text(row.rest.map(restDuration) ?? "–")
            .font(.ironMetric(.caption))
            .foregroundStyle(row.rest == nil ? IronTheme.tertiaryText : IronTheme.metricTime)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    private func rowDescription(_ row: Row) -> String {
        var parts = [row.set.kind == .warmUp ? "Warm-up set" : "Set \(row.label)"]
        parts.append(row.set.result.isEmpty ? "Completed" : row.set.result)
        if row.set.kind == .record { parts.append("personal record") }
        if let rpe = row.set.rpe, rpe > 0 {
            parts.append("RPE \(rpe.formatted(.number.precision(.fractionLength(0...1))))")
        }
        if let rest = row.rest { parts.append("rested \(restDuration(rest)) before") }
        return parts.joined(separator: ", ")
    }

    private func restDuration(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded()))
        return "\(value / 60):\(String(format: "%02d", value % 60))"
    }

    private func restTotal(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

/// A thin track marking when an exercise ran. Stacked down the card, these read as the session's timeline.
private struct IronSessionSpan: View {
    let span: ClosedRange<Double>

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(IronTheme.tertiaryFill)
            Capsule()
                .fill(IronTheme.metricTime)
                .frame(width: max(4, proxy.size.width * (span.upperBound - span.lowerBound)))
                .offset(x: min(proxy.size.width * span.lowerBound, max(0, proxy.size.width - 4)))
        }
        .frame(height: 4)
    }
}

#Preview("Session") {
    let start = Date()
    let groups: [IronSessionStrip.ExerciseGroup] = [
        .init(label: "Bench Press: Barbell", sets: [
            .init(kind: .warmUp, completedAt: start.addingTimeInterval(50), volume: 250, result: "50 lb × 5"),
            .init(completedAt: start.addingTimeInterval(200), volume: 800, result: "160 lb × 5", rpe: 7),
            .init(kind: .record, completedAt: start.addingTimeInterval(410), volume: 1000, result: "200 lb × 5", rpe: 9)
        ]),
        .init(label: "Incline Press: Dumbbell", sets: [
            .init(completedAt: start.addingTimeInterval(650), volume: 600, result: "60 lb × 10"),
            .init(completedAt: start.addingTimeInterval(800), volume: 650, result: "65 lb × 10")
        ])
    ]
    List {
        Section("Session") {
            IronSessionStrip(groups: groups, accessibilityLabel: "Five completed sets across two exercises.", sessionStart: start, volumeUnit: "lb")
        }
    }
}
