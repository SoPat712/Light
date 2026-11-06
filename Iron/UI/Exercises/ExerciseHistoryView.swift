//
//  ExerciseHistoryView.swift
//  Iron
//
//  Created by Karim Abou Zeid on 06.07.19.
//  Rebuilt for Iron's focused exercise history.
//

import SwiftUI
import CoreData
import WorkoutDataKit

struct ExerciseHistoryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FetchRequest(fetchRequest: WorkoutExercise.fetchRequest()) private var history

    let exercise: Exercise
    private let onOpenWorkout: () -> Void
    private let onCloseWorkout: () -> Void

    init(
        exercise: Exercise,
        onOpenWorkout: @escaping () -> Void = {},
        onCloseWorkout: @escaping () -> Void = {}
    ) {
        self.exercise = exercise
        self.onOpenWorkout = onOpenWorkout
        self.onCloseWorkout = onCloseWorkout
        _history = FetchRequest(fetchRequest: WorkoutExercise.historyFetchRequest(of: exercise.uuid, until: nil))
    }

    private var completedHistory: [WorkoutExercise] {
        history.filter { ($0.numberOfCompletedSets ?? 0) > 0 }
    }

    var body: some View {
        List {
            if completedHistory.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No History Yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Completed sets for \(exercise.title) will appear here.")
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(completedHistory) { workoutExercise in
                    sessionSection(workoutExercise)
                }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: IronTheme.floatingWorkoutBottomClearance - 28)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    ExerciseStatisticsView(exercise: exercise)
                        .navigationTitle("Progress")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("Progress", systemImage: "chart.xyaxis.line")
                }
            }
        }
    }

    private func sessionSection(_ workoutExercise: WorkoutExercise) -> some View {
        let sets = workoutExercise.workoutSets?.array as? [WorkoutSet] ?? []
        let completedCount = sets.filter(\.isCompleted).count
        let isFullyCompleted = !sets.isEmpty && completedCount == sets.count

        return Section {
            if let workout = workoutExercise.workout {
                NavigationLink {
                    WorkoutDetailView(workout: workout)
                        .onAppear(perform: onOpenWorkout)
                        .onDisappear(perform: onCloseWorkout)
                } label: {
                    LabeledContent("Workout") {
                        Label(
                            isFullyCompleted ? "Complete" : "Partial",
                            systemImage: isFullyCompleted ? "checkmark.circle.fill" : "circle.lefthalf.filled"
                        )
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(isFullyCompleted ? IronTheme.accent : IronTheme.secondaryText)
                    }
                }
            }

            if let comment = workoutExercise.comment, !comment.isEmpty {
                Text(comment)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(sets.enumerated()), id: \.element.id) { index, set in
                ExerciseHistorySetRow(set: set, index: index)
            }
        } header: {
            Text(Workout.dateFormatter.string(from: workoutExercise.workout?.start, fallback: "Unknown date"))
        } footer: {
            (Text("\(completedCount)").font(.ironMetric(.footnote, weight: .semibold)).foregroundColor(IronTheme.metricSets)
                + Text(" of ")
                + Text("\(sets.count)").font(.ironMetric(.footnote, weight: .semibold)).foregroundColor(IronTheme.metricSets)
                + Text(" sets completed"))
                .font(.caption)
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: completedCount)
                .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: sets.count)
        }
    }

}

/// Full history keeps the detailed set and RPE rows.
struct ExerciseHistorySetRow: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var set: WorkoutSet
    let index: Int

    var body: some View {
        HStack(spacing: 12) {
            Text(set.tagValue?.title.first.map(String.init) ?? "\(index + 1)")
                .font(.ironMetric(.subheadline, weight: .semibold))
                .foregroundStyle(IronTheme.metricSets)
                .frame(width: 24, alignment: .leading)

            resultText(for: set)
                .opacity(set.isCompleted ? 1 : 0.65)
                .contentTransition(reduceMotion ? .opacity : .numericText())

            if set.isPersonalRecord ?? false {
                Image(systemName: "medal.fill")
                    .font(.caption)
                    .foregroundStyle(IronTheme.metricRecord)
            }

            Spacer()

            Text(rpeText(set.rpeValue))
                .font(.ironMetric(.subheadline, weight: .semibold))
                .foregroundStyle(set.rpeValue == nil ? IronTheme.secondaryText : IronTheme.metricEffort)
                .contentTransition(reduceMotion ? .opacity : .numericText())
        }
        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: set.rpeValue)
        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: set.resultTitle(weightUnit: settingsStore.weightUnit))
    }

    private func resultText(for set: WorkoutSet) -> Text {
        let separator = Text(" · ").foregroundColor(IronTheme.secondaryText)
        if let distance = set.distanceValue {
            let result = distanceText(distance)
            if let duration = set.durationValue {
                return result + separator + metricText(IronDurationFormat.title(duration), color: IronTheme.metricTime)
            }
            return result
        }
        if let duration = set.durationValue {
            let time = metricText(IronDurationFormat.title(duration), color: IronTheme.metricTime)
            return set.weightValue > 0 ? weightText(set.weightValue) + separator + time : time
        }
        if set.weightValue > 0 {
            return weightText(set.weightValue)
                + Text(" × ").foregroundColor(IronTheme.secondaryText)
                + metricText("\(set.repetitionsValue)", color: IronTheme.metricSets)
        }
        if set.repetitionsValue > 0 {
            return metricText("\(set.repetitionsValue)", color: IronTheme.metricSets) + unitText(set.repetitionsValue == 1 ? "rep" : "reps")
        }
        return Text("—").foregroundColor(IronTheme.secondaryText)
    }

    private func weightText(_ kilograms: Double) -> Text {
        let weight = WeightUnit.convert(weight: kilograms, from: .metric, to: settingsStore.weightUnit)
        let number = settingsStore.weightUnit.displayNumberFormatter.string(from: NSNumber(value: weight)) ?? "\(weight)"
        return metricText(number, color: IronTheme.metricVolume) + unitText(settingsStore.weightUnit.unit.symbol)
    }

    private func distanceText(_ meters: Double) -> Text {
        let distance: Double
        let unit: String
        switch settingsStore.weightUnit {
        case .metric:
            distance = meters >= 1_000 ? meters / 1_000 : meters
            unit = meters >= 1_000 ? "km" : "m"
        case .imperial:
            let miles = Measurement(value: meters, unit: UnitLength.meters).converted(to: .miles).value
            distance = miles >= 0.1 ? miles : Measurement(value: meters, unit: UnitLength.meters).converted(to: .feet).value
            unit = miles >= 0.1 ? "mi" : "ft"
        }
        let number = distance.formatted(.number.precision(.fractionLength(unit == "km" || unit == "mi" ? 2 : 0)))
        return metricText(number, color: IronTheme.metricTime) + unitText(unit)
    }

    private func metricText(_ value: String, color: Color) -> Text {
        Text(value).font(.ironMetric(.body, weight: .semibold)).foregroundColor(color)
    }

    private func unitText(_ unit: String) -> Text {
        Text(" \(unit)").font(.caption).foregroundColor(IronTheme.secondaryText)
    }

    private func rpeText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// Compact, navigable session rows for the detail card's History segment.
struct ExerciseHistorySessionRow: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var exerciseStore: ExerciseStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var session: WorkoutExercise
    let bestOneRM: Double?
    let isRecord: Bool
    let onOpenWorkout: (Workout) -> Void

    private var sets: [WorkoutSet] {
        (session.workoutSets?.array as? [WorkoutSet] ?? []).filter(\.isCompleted)
    }

    private var recordSetID: NSManagedObjectID? {
        guard isRecord else { return nil }
        return sets.compactMap { set -> (WorkoutSet, Double)? in
            ExerciseProgressData.epleyEstimate(for: set)
                .map { (set, $0) }
        }.max { $0.1 < $1.1 }?.0.id
    }

    var body: some View {
        if let workout = session.workout {
            Button {
                onOpenWorkout(workout)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                        : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
                    layout {
                        (Text(ExerciseSessionDate.string(from: workout.start))
                            .font(.callout.weight(.semibold))
                            .foregroundColor(IronTheme.primaryText)
                         + Text(" · " + workout.displayTitle(in: exerciseStore.exercises))
                            .font(.footnote)
                            .foregroundColor(IronTheme.secondaryText))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(bestOneRM.map(weightNumber) ?? "—")
                                .font(.ironMetric(.callout, weight: .bold))
                                .foregroundStyle(isRecord ? IronTheme.metricRecord : IronTheme.accent)
                            if bestOneRM != nil {
                                Text(settingsStore.weightUnit.unit.symbol)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(IronTheme.secondaryText)
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    ExerciseChipFlowLayout(spacing: 6) {
                        ForEach(sets) { set in
                            setChip(set, isRecord: set.id == recordSetID)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary(workout))
            .accessibilityHint("Opens workout details")
        }
    }

    private func setChip(_ set: WorkoutSet, isRecord: Bool) -> some View {
        let warmUp = set.tagValue == .warmUp
        let color = isRecord ? IronTheme.metricRecord : warmUp ? IronTheme.metricSets : IronTheme.primaryText
        let fill = isRecord ? IronTheme.metricRecordContainer : warmUp ? IronTheme.metricSetsContainer : IronTheme.tertiaryFill
        return HStack(spacing: 6) {
            if isRecord {
                Image(systemName: "trophy.fill").font(.system(size: 11, weight: .bold))
            }
            Text(chipTitle(set)).font(.ironMetric(.caption, weight: .bold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .frame(minHeight: 24)
        .background(fill, in: RoundedRectangle(cornerRadius: IronTheme.compactCornerRadius, style: .continuous))
    }

    private func chipTitle(_ set: WorkoutSet) -> String {
        if set.durationValue == nil, set.distanceValue == nil, set.weightValue > 0 {
            let weight = WeightUnit.convert(weight: set.weightValue, from: .metric, to: settingsStore.weightUnit)
            return "\(weightNumber(weight))×\(set.repetitionsValue)"
        }
        return set.resultTitle(weightUnit: settingsStore.weightUnit)
    }

    private func weightNumber(_ value: Double) -> String {
        settingsStore.weightUnit.displayNumberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func accessibilitySummary(_ workout: Workout) -> String {
        let best = bestOneRM.map { "Best estimated one rep max \(weightNumber($0)) \(settingsStore.weightUnit.unit.symbol)\(isRecord ? ", personal record" : "")." } ?? ""
        let results = sets.enumerated().map { index, set in
            "Set \(index + 1)\(set.tagValue == .warmUp ? ", warm up" : "")\(set.id == recordSetID ? ", personal record" : ""), \(set.resultTitle(weightUnit: settingsStore.weightUnit))"
        }.joined(separator: ". ")
        return "\(ExerciseSessionDate.string(from: workout.start)), \(workout.displayTitle(in: exerciseStore.exercises)). \(best) \(results)"
    }
}

/// A small flow layout shared by set chips and target equipment chips.
struct ExerciseChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    private func arrangement(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), frames)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrangement(width: bounds.width, subviews: subviews).frames
        for (index, frame) in frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }
}

enum ExerciseSessionDate {
    static func string(from date: Date?, relative: Bool = true) -> String {
        guard let date else { return "Unknown date" }
        let calendar = Calendar.current
        if relative && calendar.isDateInToday(date) { return "Today" }
        if relative && calendar.isDateInYesterday(date) { return "Yesterday" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        return (sameYear ? currentYear : previousYear).string(from: date)
    }

    private static let currentYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return formatter
    }()
    private static let previousYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d yyyy")
        return formatter
    }()
}

#if DEBUG
struct ExerciseHistoryView_Previews: PreviewProvider {
    static var previews: some View {
        ExerciseHistoryView(exercise: ExerciseStore.shared.exercises.first(where: { $0.everkineticId == 42 })!)
            .mockEnvironment(weightUnit: .metric)
            .preferredColorScheme(.dark)
    }
}
#endif
