//
//  WorkoutExerciseDetailView.swift
//  Iron
//
//  Created by Karim Abou Zeid on 23.06.19.
//  Rebuilt around Iron's inline set editor.
//

import SwiftUI
import CoreData
import UIKit
import WorkoutDataKit

enum HistorySetTrackingValues {
    static func copy(from source: WorkoutSet, to destination: WorkoutSet) {
        destination.durationValue = source.durationValue
        destination.distanceValue = source.distanceValue
        if source.durationValue != nil, source.distanceValue == nil {
            destination.weightValue = 0
            destination.repetitionsValue = 0
        } else {
            destination.weightValue = source.weightValue
            destination.repetitionsValue = source.repetitionsValue
        }
        destination.rpeValue = source.rpeValue
        destination.tagValue = source.tagValue
    }
}

struct WorkoutExerciseDetailView: View {
    @Environment(\.managedObjectContext) private var managedObjectContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var restTimerStore: RestTimerStore
    @EnvironmentObject private var exerciseStore: ExerciseStore

    @FetchRequest(fetchRequest: WorkoutExercise.fetchRequest()) private var workoutExerciseHistory
    @ObservedObject var workoutExercise: WorkoutExercise

    @State private var showExerciseInfo = false
    @State private var showAllExerciseHistory = false
    @State private var showingRestTimerEditor = false
    @State private var plateCalculatorSet: WorkoutSet?
    @State private var persistenceError: String?
    @State private var deleteFeedback = 0
    @State private var isEditing = false
    @State private var isNavigationTitleVisible = false
    @State private var headerHeight: CGFloat = 0

    init(workoutExercise: WorkoutExercise) {
        self.workoutExercise = workoutExercise
        _workoutExerciseHistory = FetchRequest(fetchRequest: workoutExercise.historyFetchRequest)
    }

    private var exercise: Exercise? {
        workoutExercise.exercise(in: exerciseStore.exercises)
    }

    private var titleText: String {
        exercise?.title ?? "Exercise Log"
    }

    private var workoutSets: [WorkoutSet] {
        workoutExercise.workoutSets?.array as? [WorkoutSet] ?? []
    }

    private var previousSessions: [WorkoutExercise] {
        workoutExerciseHistory.filter { $0.objectID != workoutExercise.objectID }
    }

    private var isCurrentWorkout: Bool {
        workoutExercise.workout?.isCurrentWorkout ?? false
    }

    private var commentBinding: Binding<String> {
        Binding(
            get: { workoutExercise.comment ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                workoutExercise.comment = trimmed.isEmpty ? nil : value
                save()
            }
        )
    }

    var body: some View {
        List {
            trackedExerciseHeader
                .listRowInsets(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            exerciseSection
            previousSessionsSection
        }
        .listStyle(.insetGrouped)
        .modifier(ListHeaderScrollTitleModifier(
            headerHeight: headerHeight,
            isNavigationTitleVisible: $isNavigationTitleVisible
        ))
        .sensoryFeedback(.impact(weight: .medium), trigger: deleteFeedback) { _, _ in settingsStore.workoutHaptics }
        .sensoryFeedback(.error, trigger: persistenceError) { _, error in error != nil && settingsStore.workoutHaptics }
        .contentMargins(.horizontal, 10, for: .scrollContent)
        .contentMargins(.bottom, IronTheme.floatingWorkoutBottomClearance, for: .scrollContent)
        .navigationTitle(titleText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                navigationTitleView
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if exercise != nil {
                    Button("Exercise Details", systemImage: "info.circle") { showExerciseInfo = true }
                        .labelStyle(.iconOnly)
                }

                if !isCurrentWorkout {
                    Button(isEditing ? "Done" : "Edit") {
                        withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) {
                            isEditing.toggle()
                        }
                    }
                    .accessibilityLabel(isEditing ? "Done Editing Workout Exercise" : "Edit Workout Exercise")
                }

                if isCurrentWorkout {
                    Button("Rest Timer", systemImage: "timer") { showingRestTimerEditor = true }
                        .labelStyle(.iconOnly)
                }
            }
        }
        .alert("Workout Not Saved", isPresented: Binding(
            get: {
                persistenceError != nil
                    && !showingRestTimerEditor
                    && plateCalculatorSet == nil
            },
            set: { if !$0 { persistenceError = nil } }
        )) {
            Button("OK", role: .cancel) { persistenceError = nil }
        } message: {
            Text(persistenceError ?? "Please try again.")
        }
        .navigationDestination(isPresented: $showExerciseInfo) {
            if let exercise {
                ExerciseDetailView(exercise: exercise)
                    .environmentObject(settingsStore)
            }
        }
        .sheet(isPresented: $showAllExerciseHistory) {
            if let exercise {
                IronUtilitySheet(
                    title: "Exercise History",
                    subtitle: "",
                    systemImage: "clock.arrow.circlepath",
                    onClose: { showAllExerciseHistory = false }
                ) {
                    ExerciseHistoryView(exercise: exercise)
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showingRestTimerEditor) {
            RestTimerConfigurationSheet(
                title: "Rest Timer",
                subtitle: "Recovery after each completed set",
                initialDuration: workoutExercise.restTimerDurationValue ?? restTimerDuration,
                secondaryActionTitle: "Use Workout Default · \(restTimerDurationFormatter.string(from: workoutDefaultRestTimerDuration) ?? "0:00")",
                onSecondaryAction: { setRestTimer(nil) },
                shouldDismiss: { persistenceError == nil },
                onApply: { duration in setRestTimer(duration) }
            )
            .alert("Workout Not Saved", isPresented: Binding(
                get: { persistenceError != nil },
                set: { if !$0 { persistenceError = nil } }
            )) {
                Button("OK", role: .cancel) { persistenceError = nil }
            } message: {
                Text(persistenceError ?? "Please try again.")
            }
        }
        .sheet(item: $plateCalculatorSet) { set in
            IronUtilitySheet(
                title: "Plate Calculator",
                subtitle: "",
                systemImage: "plusminus",
                showsDone: false,
                onClose: { plateCalculatorSet = nil }
            ) {
                PlateCalculatorView(
                    unit: settingsStore.weightUnit,
                    initialTarget: displayWeight(for: set),
                    exerciseKey: workoutExercise.exerciseUuid?.uuidString ?? exercise?.title,
                    onClose: { plateCalculatorSet = nil },
                    onApply: { value in
                        performMutation(failureMessage: "The plate-calculator weight was not saved.") {
                            set.weightValue = WeightUnit.convert(
                                weight: value,
                                from: settingsStore.weightUnit,
                                to: .metric
                            )
                        } onSuccess: {
                            plateCalculatorSet = nil
                        }
                    }
                )
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .alert("Workout Not Saved", isPresented: Binding(
                get: { persistenceError != nil },
                set: { if !$0 { persistenceError = nil } }
            )) {
                Button("OK", role: .cancel) { persistenceError = nil }
            } message: {
                Text(persistenceError ?? "Please try again.")
            }
        }
        .onDisappear { _ = save() }
    }

    private var navigationTitleView: some View {
        Text(titleText)
            .font(.headline)
            .lineLimit(1)
            // Fade only the ink so the title remains available to accessibility.
            .foregroundStyle(IronTheme.primaryText.opacity(showsNavigationTitle ? 1 : 0))
            .accessibilityAddTraits(.isHeader)
            .animation(IronMotion.preferred(IronMotion.fade, reduceMotion: reduceMotion), value: showsNavigationTitle)
    }

    /// Before iOS 18 the header's scroll position isn't tracked, so the title stays visible.
    private var showsNavigationTitle: Bool {
        if #available(iOS 18, *) { return isNavigationTitleVisible }
        return true
    }

    @ViewBuilder
    private var exerciseSection: some View {
        Section {
            sessionSummary
                .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 12, trailing: 10))
            if isCurrentWorkout || isEditing {
                setRows
            } else {
                readOnlySetRows
            }
        } header: {
            Text("Overview")
        }
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var trackedExerciseHeader: some View {
        if #available(iOS 18, *) {
            exerciseHeader
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
        } else {
            exerciseHeader
        }
    }

    private var exerciseHeader: some View {
        Button { showExerciseInfo = true } label: {
            HStack(alignment: .top, spacing: 10) {
                if let exercise {
                    ExerciseDiagramThumbnail(exercise: exercise, size: 42)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(titleText)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(IronTheme.primaryText)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(exerciseContextText)
                        .font(.subheadline)
                        .foregroundStyle(IronTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(sessionContextText)
                        .font(.subheadline)
                        .foregroundStyle(IronTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if workoutSets.contains(where: { $0.isPersonalRecord == true }) {
                    Image(systemName: "trophy.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(IronTheme.metricRecord)
                        .accessibilityLabel("Personal record")
                }
                if exercise != nil {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(IronTheme.tertiaryText)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(exercise == nil)
        .accessibilityElement(children: .combine)
    }

    private var sessionSummary: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        let work = sessionWorkDisplay
        return layout {
            summaryMetric("Sets", value: "\(workoutExercise.numberOfCompletedSets ?? 0) of \(workoutSets.count)")
            summaryMetric(sessionWorkLabel.capitalized, value: work.value, unit: work.unit)
        }
    }

    private var sessionWorkDisplay: (value: String, unit: String?) {
        let formatted = sessionWorkValue
        guard sessionWorkLabel == "volume" || sessionWorkLabel == "distance",
              let separator = formatted.lastIndex(where: { $0.isWhitespace }) else {
            return (formatted, nil)
        }
        return (String(formatted[..<separator]), String(formatted[formatted.index(after: separator)...]))
    }

    private func summaryMetric(_ title: String, value: String, unit: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(IronTheme.secondaryText)
            IronMetricValue(value: value, unit: unit, style: .title2, unitStyle: .body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var exerciseContextText: String {
        guard let exercise else { return "Exercise details unavailable" }
        let muscle = exercise.primaryMuscleCommonName.first?.capitalized ?? exercise.muscleGroup.capitalized
        let equipment = exercise.equipment.filter { !$0.isEmpty }.map(\.equipmentTitle).joined(separator: ", ")
        return equipment.isEmpty ? muscle : "\(muscle) · \(equipment)"
    }

    private var sessionContextText: String {
        if isCurrentWorkout { return "Current workout" }
        guard let start = workoutExercise.workout?.start else { return "Completed session" }
        return start.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private var completedWorkoutSets: [WorkoutSet] {
        workoutSets.filter(\.isCompleted)
    }

    private var sessionWorkValue: String {
        let totalDistance = completedWorkoutSets.compactMap(\.distanceValue).reduce(0, +)
        if totalDistance > 0 { return formatDistance(totalDistance) }

        let totalDuration = completedWorkoutSets.compactMap(\.durationValue).reduce(0, +)
        if totalDuration > 0 { return formatDuration(totalDuration) }

        let volume = workoutExercise.trackedCompletedVolume
        if volume > 0 {
            return WeightUnit.format(weight: volume, from: .metric, to: settingsStore.weightUnit)
        }

        let repetitions = workoutExercise.numberOfCompletedRepetitions ?? 0
        return repetitions > 0 ? "\(repetitions)" : "—"
    }

    private var sessionWorkLabel: String {
        if completedWorkoutSets.contains(where: { $0.distanceValue != nil }) { return "distance" }
        if completedWorkoutSets.contains(where: { $0.durationValue != nil }) { return "duration" }
        if workoutExercise.trackedCompletedVolume > 0 { return "volume" }
        return "reps"
    }

    @ViewBuilder
    private var readOnlySetRows: some View {
        Text("Session Sets")
            .font(.headline)
            .foregroundStyle(IronTheme.primaryText)
            .accessibilityAddTraits(.isHeader)
            .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))

        if workoutSets.isEmpty {
            Text("No sets")
                .font(.subheadline)
                .foregroundStyle(IronTheme.secondaryText)
                .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
        } else {
            VStack(spacing: 0) {
                ForEach(Array(workoutSets.enumerated()), id: \.element.id) { index, set in
                    if index > 0 { Divider() }
                    HistoryReadOnlySetRow(set: set, number: index + 1)
                }
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
        }

        if let comment = workoutExercise.comment,
           !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(comment)
                .font(.body)
                .foregroundStyle(IronTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Notes for this workout: \(comment)")
                .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 8, trailing: 10))
        }
    }

    @ViewBuilder
    private var setRows: some View {
        let trackingType = workoutSets.first?.trackingType ?? workoutExercise.setTrackingType

        if isCurrentWorkout {
            Button {
                showingRestTimerEditor = true
            } label: {
                LabeledContent(
                    "Rest Timer",
                    value: restTimerDurationFormatter.string(from: restTimerDuration) ?? "Off"
                )
                .frame(minHeight: IronTheme.controlHeight)
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 4, trailing: 10))
        }

        Text(isCurrentWorkout ? "Log Sets" : "Session Sets")
            .font(.headline)
            .foregroundStyle(IronTheme.primaryText)
            .accessibilityAddTraits(.isHeader)
            .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))

        if !workoutSets.isEmpty, !dynamicTypeSize.isAccessibilitySize {
            setColumnHeaders(trackingType: trackingType)
                .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 4, trailing: 10))
        }

        ForEach(Array(workoutSets.enumerated()), id: \.element.id) { index, set in
            HistoryWorkoutSetRow(
                set: set,
                index: index,
                trackingType: set.isCompleted ? set.trackingType : workoutExercise.setTrackingType,
                onOpenPlateCalculator: { plateCalculatorSet = set },
                onToggleCompleted: { toggleCompleted(set) },
                onDelete: { delete(set) },
                onChanged: save
            )
            .environmentObject(settingsStore)
            .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
        }

        Button(action: addSet) {
            Label("Add Set", systemImage: "plus")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight)
                .background(IronTheme.raisedSurface, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(IronTheme.accent)
        .listRowInsets(EdgeInsets(top: 8, leading: 10, bottom: 12, trailing: 10))

        sessionNotesField
            .font(.body)
            .frame(minHeight: IronTheme.controlHeight)
            .accessibilityLabel("Notes for This Workout")
            .accessibilityHint("Saved with this session only")
            .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 8, trailing: 10))
    }

    @ViewBuilder
    private var sessionNotesField: some View {
        if #available(iOS 16, *) {
            TextField("Notes for This Workout", text: commentBinding, axis: .vertical)
                .lineLimit(1...4)
        } else {
            TextField("Notes for This Workout", text: commentBinding)
        }
    }

    private func setColumnHeaders(trackingType: SetTrackingType) -> some View {
        HStack(spacing: InlineWorkoutSetLayout.spacing) {
            Text("Set").frame(width: InlineWorkoutSetLayout.setWidth)
            ForEach(trackingType.columns) { column in
                Text(trackingType.header(for: column, weightUnit: settingsStore.weightUnit.unit.symbol,
                                         distanceUnit: WorkoutSet.distanceUnit(settingsStore.weightUnit)))
                    .frame(maxWidth: .infinity)
            }
            if settingsStore.logRPE {
                Text("RPE").frame(width: InlineWorkoutSetLayout.rpeWidth)
            }
            Image(systemName: "checkmark")
                .frame(width: InlineWorkoutSetLayout.completionWidth)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(IronTheme.secondaryText)
        .multilineTextAlignment(.center)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var previousSessionsSection: some View {
        Section {
            if previousSessions.isEmpty {
                Text("The next time you train this exercise, your previous sets appear here for quick comparison.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(previousSessions.prefix(8), id: \.objectID) { session in
                    previousSessionRow(session)
                }

                if previousSessions.count > 8, let exercise {
                    Button("View All \(previousSessions.count) Sessions", systemImage: "clock.arrow.circlepath") {
                        showAllExerciseHistory = true
                    }
                    .accessibilityHint("Opens the complete history for \(exercise.title)")
                }
            }
        } header: {
            Text(previousSessions.isEmpty ? "First Session" : "Previous Sessions")
        }
    }

    private func previousSessionRow(_ session: WorkoutExercise) -> some View {
        let sets = session.workoutSets?.array as? [WorkoutSet] ?? []

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(LightFormat.listDate(session.workout?.start))
                if sets.contains(where: { $0.isPersonalRecord ?? false }) {
                    Image(systemName: "medal.fill")
                        .font(.caption)
                        .foregroundStyle(IronTheme.metricRecord)
                }
                Spacer(minLength: 4)
                Text(previousSessionResult(session))
                    .font(.ironMetric(.caption, weight: .semibold))
                    .foregroundStyle(IronTheme.secondaryText)
            }

            if sets.isEmpty {
                Text("No sets")
                    .font(.ironMetric(.caption, weight: .semibold))
                    .foregroundStyle(IronTheme.secondaryText)
                    .lineLimit(2)
            } else if #available(iOS 16, *) {
                ExerciseChipFlowLayout(spacing: 6) {
                    ForEach(sets) { set in
                        ExerciseSetChip(set: set, isRecord: set.isPersonalRecord ?? false, weightUnit: settingsStore.weightUnit)
                    }
                }
                .padding(.top, 4)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(sets) { set in
                        ExerciseSetChip(set: set, isRecord: set.isPersonalRecord ?? false, weightUnit: settingsStore.weightUnit)
                    }
                }
                .padding(.top, 4)
            }

            if let comment = session.comment, !comment.isEmpty {
                Text(comment)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(previousSessionAccessibilityLabel(session, sets: sets))
    }

    private func previousSessionAccessibilityLabel(_ session: WorkoutExercise, sets: [WorkoutSet]) -> String {
        let results = sets.isEmpty ? "No sets" : sets
            .map { $0.resultTitle(weightUnit: settingsStore.weightUnit) }
            .joined(separator: ", ")
        var label = "\(LightFormat.listDate(session.workout?.start)). \(previousSessionResult(session)). \(results)"
        let hasRecord = sets.contains { $0.isPersonalRecord ?? false }
        if hasRecord {
            label += ". Personal record."
        }
        if let comment = session.comment, !comment.isEmpty {
            label += "\(hasRecord ? " " : ". ")\(comment)"
        }
        return label
    }

    private func previousSessionResult(_ session: WorkoutExercise) -> String {
        let sets = (session.workoutSets?.array as? [WorkoutSet] ?? []).filter(\.isCompleted)
        let totalDistance = sets.compactMap(\.distanceValue).reduce(0, +)
        if totalDistance > 0 { return formatDistance(totalDistance) }

        let totalDuration = sets.compactMap(\.durationValue).reduce(0, +)
        if totalDuration > 0 { return formatDuration(totalDuration) }

        let volume = session.trackedCompletedVolume
        if volume > 0 {
            return WeightUnit.format(weight: volume, from: .metric, to: settingsStore.weightUnit)
        }

        let repetitions = session.numberOfCompletedRepetitions ?? 0
        return repetitions > 0 ? "\(repetitions) \(repetitions == 1 ? "rep" : "reps")" : "—"
    }

    private var restTimerDuration: TimeInterval {
        if let customDuration = workoutExercise.restTimerDurationValue {
            return customDuration
        }
        return workoutDefaultRestTimerDuration
    }

    private var workoutDefaultRestTimerDuration: TimeInterval {
        switch exercise?.type {
        case .barbell:
            return settingsStore.defaultRestTimeBarbellBased
        case .dumbbell:
            return settingsStore.defaultRestTimeDumbbellBased
        default:
            return settingsStore.defaultRestTime
        }
    }

    private func setRestTimer(_ duration: TimeInterval?) {
        performMutation(failureMessage: "The rest-timer setting was not saved.") {
            workoutExercise.restTimerDurationValue = duration
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let roundedSeconds = Int(max(seconds, 0).rounded())
        let hours = roundedSeconds / 3_600
        let minutes = (roundedSeconds % 3_600) / 60
        let remainingSeconds = roundedSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    private func formatDistance(_ meters: Double) -> String {
        switch settingsStore.weightUnit {
        case .metric:
            if meters >= 1_000 { return String(format: "%.2f km", meters / 1_000) }
            return String(format: "%.0f m", meters)
        case .imperial:
            let miles = Measurement(value: meters, unit: UnitLength.meters).converted(to: .miles).value
            if miles >= 0.1 { return String(format: "%.2f mi", miles) }
            let feet = Measurement(value: meters, unit: UnitLength.meters).converted(to: .feet).value
            return String(format: "%.0f ft", feet)
        }
    }

    private func displayWeight(for set: WorkoutSet) -> Double {
        WeightUnit.convert(
            weight: set.weightValue,
            from: .metric,
            to: settingsStore.weightUnit
        )
    }

    private func addSet() {
        performMutation(failureMessage: "The set was not added.") {
            let previous = workoutSets.last
            let set = WorkoutSet.create(context: managedObjectContext)
            set.workoutExercise = workoutExercise

            if let previous {
                copyTrackingValues(from: previous, to: set)
            } else if let priorSession = previousSessions.first,
                      let priorSet = priorSession.workoutSets?.firstObject as? WorkoutSet {
                copyTrackingValues(from: priorSet, to: set)
            } else {
                set.repetitionsValue = 5
                if exercise?.type == .barbell {
                    set.weightValue = WeightUnit.convert(
                        weight: settingsStore.weightUnit.barbellWeight,
                        from: settingsStore.weightUnit,
                        to: .metric
                    )
                }
            }

            if !isCurrentWorkout {
                set.isCompleted = true
                set.completedAt = workoutExercise.workout?.end
            }
        }
    }

    private func copyTrackingValues(from source: WorkoutSet, to destination: WorkoutSet) {
        HistorySetTrackingValues.copy(from: source, to: destination)
    }

    private func toggleCompleted(_ set: WorkoutSet) {
        let isCompleting = !set.isCompleted
        let completionDate = Date()
        performMutation(failureMessage: "The set completion was not saved.") {
            if set.isCompleted {
                set.isCompleted = false
                set.completedAt = nil
            } else {
                set.isCompleted = true
                set.completedAt = completionDate
                workoutExercise.workout?.start = workoutExercise.workout?.start ?? completionDate
            }
        } onSuccess: {
            if isCompleting && isCurrentWorkout {
                restTimerStore.start(duration: restTimerDuration)
            }
        }
    }

    @discardableResult
    private func delete(_ set: WorkoutSet) -> Bool {
        performMutation(failureMessage: "The set was not removed.") {
            workoutExercise.removeFromWorkoutSets(set)
            managedObjectContext.delete(set)
        } onSuccess: {
            deleteFeedback += 1
        }
    }

    @discardableResult
    private func save() -> Bool {
        do {
            try managedObjectContext.save()
            return true
        } catch {
            persistenceError = "Your latest changes could not be saved. \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    private func performMutation(
        failureMessage: String,
        mutation: () throws -> Void,
        onSuccess: () -> Void = {}
    ) -> Bool {
        persistenceError = nil
        do {
            try HistoryMutationPersistence.perform(
                context: managedObjectContext,
                mutation: mutation,
                onSuccess: onSuccess
            )
            return true
        } catch {
            persistenceError = "\(failureMessage) \(error.localizedDescription)"
            return false
        }
    }
}

private struct HistoryReadOnlySetRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var settingsStore: SettingsStore
    @ObservedObject var set: WorkoutSet
    let number: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.ironMetric(.body, weight: .semibold))
                .foregroundStyle(IronTheme.secondaryText)
                .frame(width: 32, alignment: .leading)

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    result
                    metadata
                }
            } else {
                result
                Spacer(minLength: 0)
                metadata
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(set.isCompleted ? 1 : 0.45)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 4) {
            resultText
                .font(.ironMetric(.body, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            let additional = set.additionalTrackingTitle(weightUnit: settingsStore.weightUnit)
            if !additional.isEmpty {
                Text(additional)
                    .font(.ironMetric(.footnote, weight: .semibold))
                    .foregroundStyle(IronTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var resultText: Text {
        var title = AttributedString(set.resultTitle(weightUnit: settingsStore.weightUnit))
        title.foregroundColor = IronTheme.primaryText
        let units = [settingsStore.weightUnit.unit.symbol, WorkoutSet.distanceUnit(settingsStore.weightUnit), "reps", "rep"]
        for unit in units {
            if let range = title.range(of: unit) {
                title[range].foregroundColor = IronTheme.secondaryText
            }
        }
        return Text(title)
    }

    @ViewBuilder
    private var metadata: some View {
        if set.rpeValue != nil || set.tagValue != nil {
            HStack(spacing: 8) {
                if let rpe = set.rpeValue {
                    Text("RPE \(String(format: "%g", rpe))")
                        .font(.ironMetric(.subheadline, weight: .semibold))
                        .foregroundStyle(IronTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let tag = set.tagValue {
                    Text(tagSymbol(tag))
                        .font(.ironMetric(.callout, weight: .semibold))
                        .foregroundStyle(tagTint(tag))
                        .frame(width: 30, height: 30)
                        .background(tagFill(tag), in: Circle())
                }
            }
        }
    }

    private func tagSymbol(_ tag: WorkoutSetTag) -> String {
        switch tag {
        case .warmUp: return "W"
        case .dropSet: return "D"
        case .failure: return "F"
        }
    }

    private func tagTint(_ tag: WorkoutSetTag) -> Color {
        if set.isCompleted { return IronTheme.setFill(for: tag).tint }
        return tag == .warmUp ? IronTheme.metricSets : IronTheme.secondaryText
    }

    private func tagFill(_ tag: WorkoutSetTag) -> Color {
        if !set.isCompleted { return tag == .warmUp ? IronTheme.metricSetsContainer : IronTheme.field }
        switch tag {
        case .warmUp: return IronTheme.setWarmUpContainer
        case .dropSet: return IronTheme.setDropContainer
        case .failure: return IronTheme.setFailureContainer
        }
    }

    private var accessibilitySummary: String {
        var parts = ["Set \(number)"]
        if let tag = set.tagValue { parts.append(tag.title) }
        if let duration = set.durationValue {
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .full
            formatter.allowedUnits = [.hour, .minute, .second]
            parts.append(formatter.string(from: duration) ?? SetTrackingType.durationText(duration))
        }
        if let distance = set.distanceValue {
            parts.append("Distance " + WorkoutSet.distanceTitle(distance, weightUnit: settingsStore.weightUnit))
        }
        if set.trackingType.usesWeight || set.weightValue > 0 {
            let weight = WeightUnit.convert(weight: set.weightValue, from: .metric, to: settingsStore.weightUnit)
            let value = settingsStore.weightUnit.displayNumberFormatter.string(from: weight as NSNumber) ?? "—"
            let label = set.trackingType == .assistedBodyweight ? "Assistance" : (set.trackingType == .weightedBodyweight ? "Added weight" : "Weight")
            let unit = settingsStore.weightUnit == .metric ? "kilograms" : "pounds"
            parts.append("\(label), \(value) \(unit)")
        }
        if set.trackingType.usesReps || set.repetitionsValue > 0 {
            parts.append("\(set.repetitionsValue) \(set.repetitionsValue == 1 ? "rep" : "reps")")
        }
        if let rpe = set.rpeValue { parts.append("RPE \(String(format: "%g", rpe))") }
        parts.append(set.isCompleted ? "completed" : "not completed")
        if set.isPersonalRecord == true { parts.append("personal record") }
        return parts.joined(separator: ", ")
    }
}

// A history variant of the logger row: history gives the Previous column's
// width to the editable values, while keeping the logger's tokens and save path.
private struct HistoryWorkoutSetRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var settingsStore: SettingsStore
    @ObservedObject var set: WorkoutSet

    let index: Int
    let trackingType: SetTrackingType
    let onOpenPlateCalculator: () -> Void
    let onToggleCompleted: () -> Void
    let onDelete: () -> Bool
    let onChanged: () -> Bool

    @State private var showingRPEPicker = false
    @State private var showingDurationPicker = false
    @State private var showingDurationSaveError = false
    @State private var inlineTimerStart: Date?
    @State private var weightText = ""
    @State private var repetitionsText = ""
    @State private var measuredRowWidth: CGFloat = 0
    @State private var swipeOffset: CGFloat = 0
    @State private var swipeStartOffset: CGFloat = 0
    @State private var isSwipingSet = false
    @State private var isPerformingSwipeDelete = false
    @State private var measuredRowHeight: CGFloat = 52
    private let allowsSwipeToDelete = true
    private let openSwipeSetID: Binding<NSManagedObjectID?> = .constant(nil)
    @State private var completionBounce = 0
    @State private var completionFeedback = 0
    @State private var selectionFeedback = 0
    @State private var checkReveal: CGFloat = 0
    @FocusState private var focusedField: EntryField?

    private let deleteActionWidth: CGFloat = 76
    private let deleteActionGap: CGFloat = 8

    private var openSwipeOffset: CGFloat {
        -(deleteActionWidth + deleteActionGap + InlineWorkoutSetLayout.completedChromeExpansion)
    }

    private var fullSwipeDeleteThreshold: CGFloat {
        effectiveRowWidth * 0.55
    }

    private var effectiveRowWidth: CGFloat {
        if measuredRowWidth > 0 {
            return measuredRowWidth
        }
        return max(
            deleteActionWidth,
            UIScreen.main.bounds.width - (IronTheme.horizontalPadding * 2)
        )
    }

    private enum EntryField: Hashable {
        case weight
        case repetitions
    }

    private var valueColor: Color {
        return set.isCompleted ? IronTheme.primaryText : IronTheme.secondaryText
    }

    private var badgeColor: Color {
        if set.isCompleted { return IronTheme.setFill(for: set.tagValue).tint }
        return set.tagValue == .warmUp ? IronTheme.metricSets : IronTheme.secondaryText
    }

    private var badgeFill: Color {
        if set.isCompleted {
            switch set.tagValue {
            case .warmUp: return IronTheme.setWarmUpContainer
            case .dropSet: return IronTheme.setDropContainer
            case .failure: return IronTheme.setFailureContainer
            case nil: return IronTheme.accentSoft
            }
        }
        return set.tagValue == .warmUp ? IronTheme.metricSetsContainer : IronTheme.field
    }

    private var completionImage: some View {
        Image(systemName: set.isCompleted ? "checkmark.circle.fill" : "circle")
            .symbolRenderingMode(.palette)
            .foregroundStyle(
                set.isCompleted ? IronTheme.onAccent : IronTheme.tertiaryText,
                IronTheme.accent
            )
            .font(.system(size: 28, weight: .semibold))
    }

    @ViewBuilder
    private var completionSymbol: some View {
        if reduceMotion {
            completionImage.contentTransition(.opacity)
        } else {
            ZStack {
                // Keep the blue disc visible while the symbol's white check draws in.
                Circle()
                    .fill(IronTheme.accent)
                    .opacity(set.isCompleted ? 1 : 0)
                completionImage
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, options: .nonRepeating, value: completionBounce)
                    .mask {
                        Rectangle()
                            .scaleEffect(x: set.isCompleted ? checkReveal : 1, anchor: .leading)
                    }
            }
            .frame(width: 28, height: 28)
        }
    }

    /// Timed sets can be run like a stopwatch instead of dialling in a target
    /// first: tap to start, tap to bank the elapsed time.
    @ViewBuilder
    private var durationControl: some View {
        if settingsStore.inlineSetTimer, !set.isCompleted {
            TimelineView(.periodic(from: Date(), by: 0.5)) { context in
                Button {
                    selectionFeedback += 1
                    toggleInlineTimer()
                } label: {
                    durationLabel(
                        text: inlineTimerText(now: context.date),
                        isRunning: inlineTimerStart != nil
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(inlineTimerStart == nil ? "Start set timer" : "Stop set timer")
            }
            .contextMenu {
                Button("Enter Duration", systemImage: "keyboard") { showingDurationPicker = true }
            }
        } else {
            Button(action: { showingDurationPicker = true }) {
                durationLabel(
                    text: set.durationValue.map(SetTrackingType.durationText) ?? (set.isCompleted ? "—" : "1:00"),
                    isRunning: false
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Set duration")
        }
    }

    private func durationLabel(text: String, isRunning: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isRunning ? "stop.fill" : "stopwatch")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(
                    isRunning ? IronTheme.danger : (set.isCompleted ? IronTheme.metricTime : IronTheme.secondaryText)
                )
            Text(text)
                .font(.ironMetric(.title3, weight: .semibold))
                .foregroundColor(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: text)
        }
        .frame(maxWidth: .infinity, minHeight: 40)
    }

    private func inlineTimerText(now: Date) -> String {
        guard let inlineTimerStart else {
            return SetTrackingType.durationText(set.durationValue ?? 0)
        }
        let elapsed = max(0, now.timeIntervalSince(inlineTimerStart))
        return restTimerDurationFormatter.string(from: elapsed) ?? "0:00"
    }

    private func toggleInlineTimer() {
        if let inlineTimerStart {
            set.durationValue = max(1, (Date().timeIntervalSince(inlineTimerStart)).rounded())
            self.inlineTimerStart = nil
            _ = onChanged()
        } else {
            inlineTimerStart = Date()
        }
    }

    private var weightTextBinding: Binding<String> {
        Binding(
            get: { weightText },
            set: { proposedValue in
                let sanitizedValue = sanitizedDecimalInput(proposedValue)
                guard proposedValue.isEmpty || !sanitizedValue.isEmpty else { return }
                weightText = sanitizedValue

                guard let displayValue = weightFormatter.number(from: sanitizedValue)?.doubleValue else {
                    if sanitizedValue.isEmpty, set.weightValue != 0 {
                        set.weightValue = 0
                        _ = onChanged()
                    }
                    return
                }

                let metricValue = min(
                    max(WeightUnit.convert(weight: displayValue, from: settingsStore.weightUnit, to: .metric), 0),
                    WorkoutSet.MAX_WEIGHT
                )
                if abs(set.weightValue - metricValue) > 0.000_001 {
                    set.weightValue = metricValue
                    _ = onChanged()
                }
            }
        )
    }

    private var repetitionsTextBinding: Binding<String> {
        Binding(
            get: { repetitionsText },
            set: { proposedValue in
                let sanitizedValue = sanitizedIntegerInput(proposedValue)
                guard proposedValue.isEmpty || !sanitizedValue.isEmpty else { return }
                repetitionsText = sanitizedValue

                let value = min(
                    max(Int(sanitizedValue) ?? 0, 0),
                    Int(WorkoutSet.MAX_REPETITIONS)
                )
                if set.repetitionsValue != Int16(value) {
                    set.repetitionsValue = Int16(value)
                    _ = onChanged()
                }
            }
        )
    }

    private var weightFormatter: NumberFormatter {
        settingsStore.weightUnit.numberFormatter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            swipeableRow
            let additional = set.additionalTrackingTitle(weightUnit: settingsStore.weightUnit)
            if !additional.isEmpty {
                Text(additional)
                    .font(.ironMetric(.footnote, weight: .semibold))
                    .foregroundStyle(IronTheme.secondaryText)
            }
        }
        .sensoryFeedback(.selection, trigger: selectionFeedback) { _, _ in settingsStore.workoutHaptics }
        .sensoryFeedback(.success, trigger: completionFeedback) { _, _ in settingsStore.workoutHaptics }
        .onAppear {
            synchronizeEntryText()
            checkReveal = set.isCompleted ? 1 : 0
        }
        .onChange(of: set.isCompleted) { _, completed in
            if focusedField != .weight { weightText = formattedWeight }
            if completed {
                completionBounce += 1
                withAnimation(IronMotion.preferred(IronMotion.snappy.delay(0.12), reduceMotion: reduceMotion)) {
                    checkReveal = 1
                }
            } else {
                checkReveal = 0
            }
            if completed, inlineTimerStart != nil { toggleInlineTimer() }
        }
        .onChange(of: set.weightValue) { _, _ in
            if focusedField != .weight { weightText = formattedWeight }
        }
        .onChange(of: set.repetitionsValue) { _, _ in
            if focusedField != .repetitions { repetitionsText = formattedRepetitions }
        }
        .onChange(of: settingsStore.weightUnit) { _, _ in
            if focusedField != .weight { weightText = formattedWeight }
        }
        .onChange(of: focusedField) { _, newValue in
            weightText = formattedWeight
            if newValue != .repetitions { repetitionsText = formattedRepetitions }
        }
        .toolbar {
            if focusedField != nil {
                ToolbarItemGroup(placement: .keyboard) {
                    if focusedField == .weight, settingsStore.showPlateCalculator {
                        Button("Plate Calculator", systemImage: "plusminus", action: openPlateCalculator)
                            .labelStyle(.iconOnly)
                            .accessibilityHint("Calculates the plates to load for this set")
                    }
                    Spacer()
                    Button("Done") { focusedField = nil }
                        .fontWeight(.semibold)
                        .accessibilityLabel("Dismiss number pad")
                }
            }
        }
        .sheet(isPresented: $showingRPEPicker) {
            HistorySetRPEPickerSheet(set: set, onChanged: onChanged)
        }
        .sheet(isPresented: $showingDurationPicker) {
            IronDurationPickerSheet(
                initialDuration: set.durationValue ?? 60,
                shouldDismiss: { !showingDurationSaveError }
            ) { duration in
                set.durationValue = duration
                showingDurationSaveError = !onChanged()
            }
            .alert("Duration Not Saved", isPresented: $showingDurationSaveError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Your duration could not be saved. Keep this sheet open and try again.")
            }
        }
    }

    private var swipeableRow: some View {
        ZStack(alignment: .trailing) {
            if allowsSwipeToDelete, deleteRevealWidth > 0.5 {
                swipeDeleteAction
            }

            Group {
                if needsExpandedCompactLayout {
                    accessibleCompactRow
                } else {
                    regularCompactRow
                }
            }
            // Keep sweep state and success feedback alive across presentation changes.
            .ironSetCompletion(
                isComplete: set.isCompleted, feedbackEnabled: false,
                tint: IronTheme.setFill(for: set.tagValue).tint,
                settledOpacity: IronTheme.setFill(for: set.tagValue).settled,
                peakOpacity: IronTheme.setFill(for: set.tagValue).peak
            )
            .padding(.horizontal, -InlineWorkoutSetLayout.completedChromeExpansion)
            .animation(
                IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion),
                value: set.isCompleted
            )
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { measuredRowHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, height in measuredRowHeight = height }
                }
            }
            .allowsHitTesting(swipeOffset == 0)
            .accessibilityHidden(swipeOffset < 0)
            .overlay {
                if swipeOffset < 0 {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: closeSwipe)
                        .padding(.horizontal, -InlineWorkoutSetLayout.completedChromeExpansion)
                        .accessibilityLabel("Close delete action")
                        .accessibilityAddTraits(.isButton)
                }
            }
            .padding(.vertical, 2)
            .offset(x: swipeOffset)
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        measuredRowWidth = proxy.size.width
                    }
                    .onChange(of: proxy.size.width) { _, width in
                        measuredRowWidth = width
                    }
            }
        )
        .contentShape(Rectangle())
        .historySetRowSwipe(
            enabled: allowsSwipeToDelete,
            legacy: swipeDeleteGesture,
            onChanged: handleSwipeChanged,
            onEnded: handleSwipeEnded
        )
        .onChange(of: openSwipeSetID.wrappedValue) { _, id in
            if id != set.objectID, !isPerformingSwipeDelete { closeSwipe() }
        }
    }

    private var needsExpandedCompactLayout: Bool { dynamicTypeSize.isAccessibilitySize }

    @ViewBuilder
    private func measurementField(_ column: SetTrackingType.Column) -> some View {
        switch column {
        case .weight:
            setField(isFocused: focusedField == .weight) {
                TextField("0", text: weightTextBinding)
                    .keyboardType(.decimalPad).focused($focusedField, equals: .weight)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("\(trackingType == .assistedBodyweight ? "Assistance" : "Weight") in \(settingsStore.weightUnit.unit.symbol)")
            }
        case .reps:
            setField(isFocused: focusedField == .repetitions) {
                TextField("0", text: repetitionsTextBinding)
                    .keyboardType(.numberPad).focused($focusedField, equals: .repetitions)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("Repetitions")
            }
        case .duration: setField { durationControl }
        case .distance:
            setField {
                Text(set.distanceValue.map { WorkoutSet.distanceDisplayValue($0, weightUnit: settingsStore.weightUnit).formatted(.number.precision(.fractionLength(2))) } ?? "—")
                    .accessibilityLabel("Distance in \(WorkoutSet.distanceUnit(settingsStore.weightUnit))")
                    .accessibilityValue(set.distanceValue.map { WorkoutSet.distanceTitle($0, weightUnit: settingsStore.weightUnit) } ?? "Not entered")
            }
        }
    }

    private var accessibleSetActionsLayout: AnyLayout {
        dynamicTypeSize >= .accessibility3
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 10))
    }

    private func toggleCompletion() {
        let wasCompleted = set.isCompleted
        withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) {
            onToggleCompleted()
        }
        if !wasCompleted, set.isCompleted { completionFeedback += 1 }
        if wasCompleted, !set.isCompleted { selectionFeedback += 1 }
    }

    private var accessibleCompactRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            accessibleSetActionsLayout {
                Menu { setTypeMenuItems } label: {
                    Text(set.tagValue == nil ? "Set \(index + 1)" : "\(setLabel) · Set \(index + 1)")
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 8)
                        .frame(minHeight: IronTheme.controlHeight)
                        .background(badgeFill, in: Capsule())
                }
                .accessibilityLabel("Set type")
                .accessibilityValue(set.tagValue?.title ?? "Normal set")
                .accessibilityHint("Change set type")
                if settingsStore.logRPE {
                    Button { showingRPEPicker = true } label: {
                        Text(set.rpeValue.map { "RPE " + String(format: "%g", $0) } ?? "RPE")
                            .font(.ironMetric(.subheadline, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(IronTheme.metricEffort)
                            .frame(minWidth: IronTheme.controlHeight, minHeight: IronTheme.controlHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(rpeAccessibilityLabel)
                    .accessibilityHint("Opens the effort selector")
                }
                Button(action: toggleCompletion) {
                    completionSymbol
                        .frame(width: IronTheme.controlHeight, height: IronTheme.controlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(set.isCompleted ? "Set \(index + 1) completed" : "Mark set \(index + 1) complete")
                .accessibilityValue(set.isCompleted ? "Completed" : "Not completed")
                .accessibilityAddTraits(set.isCompleted ? .isSelected : [])
            }
            ForEach(trackingType.columns) { column in
                VStack(alignment: .leading, spacing: 4) {
                    Text(trackingType.header(for: column, weightUnit: settingsStore.weightUnit.unit.symbol,
                                             distanceUnit: WorkoutSet.distanceUnit(settingsStore.weightUnit)))
                        .font(.caption).foregroundStyle(IronTheme.secondaryText)
                    measurementField(column)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, InlineWorkoutSetLayout.completedChromeExpansion)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var regularCompactRow: some View {
        HStack(spacing: InlineWorkoutSetLayout.spacing) {
            Menu {
                setTypeMenuItems
            } label: {
                Text(setLabel)
                    .font(.ironMetric(.callout, weight: .semibold))
                    .foregroundStyle(badgeColor)
                    .frame(width: 30, height: 30)
                    .background(badgeFill, in: Circle())
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "chevron.down.circle.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(badgeColor, IronTheme.surface)
                            .offset(x: 4, y: 4)
                            .accessibilityHidden(true)
                    }
                    .frame(width: IronTheme.iconButtonSize, height: IronTheme.controlHeight)
                    .contentShape(Rectangle())
                    .frame(width: InlineWorkoutSetLayout.setWidth)
            }
            .accessibilityLabel("Set type")
            .accessibilityValue(set.tagValue?.title ?? "Normal set")
            .accessibilityHint("Change set type")

            ForEach(trackingType.columns) { column in measurementField(column) }

            if settingsStore.logRPE {
                Button(action: { showingRPEPicker = true }) {
                    Group {
                        if let rpe = set.rpeValue {
                            Text(String(format: "%g", rpe))
                        } else if set.isCompleted {
                            Text("–")
                        } else {
                            Image(systemName: "gauge.with.dots.needle.50percent")
                        }
                    }
                    .font(.ironMetric(.subheadline, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .foregroundStyle(set.rpeValue != nil ? IronTheme.metricEffort : IronTheme.secondaryText)
                    .frame(width: IronTheme.iconButtonSize, height: IronTheme.controlHeight)
                    .contentShape(Rectangle())
                    .frame(width: InlineWorkoutSetLayout.rpeWidth)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(rpeAccessibilityLabel)
                .accessibilityHint("Opens the effort selector")
            }

            Button(action: toggleCompletion) {
                completionSymbol
                    .frame(width: IronTheme.iconButtonSize, height: IronTheme.controlHeight)
                    .contentShape(Rectangle())
                    .frame(width: InlineWorkoutSetLayout.completionWidth)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                set.isCompleted
                    ? "Set \(index + 1) completed"
                    : "Mark set \(index + 1) complete"
            )
            .accessibilityValue(set.isCompleted ? "Completed" : "Not completed")
            .accessibilityRemoveTraits(.isSelected)
            .accessibilityAddTraits(set.isCompleted ? .isSelected : [])
        }
        // Keep a 52 pt compact row while preserving its columns and 44 pt targets.
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, minHeight: 52)
        .padding(.horizontal, InlineWorkoutSetLayout.completedChromeExpansion)
    }

    private var rpeAccessibilityLabel: String {
        guard let rpe = set.rpeValue else { return "Set RPE" }
        return "RPE \(String(format: "%g", rpe))"
    }

    @ViewBuilder
    private var setTypeMenuItems: some View {
        Picker("Set Type", selection: setTagBinding) {
            Label("Normal Set", systemImage: "number").tag(WorkoutSetTag?.none)
            ForEach(WorkoutSetTag.allCases, id: \.self) { tag in
                Label(tag.title.capitalized, systemImage: setTypeIcon(for: tag))
                    .tag(WorkoutSetTag?.some(tag))
            }
        }

        Section {
            Button("Delete Set", systemImage: "trash", role: .destructive) {
                _ = onDelete()
            }
        }
    }

    private var setTagBinding: Binding<WorkoutSetTag?> {
        Binding(
            get: { set.tagValue },
            set: {
                guard set.tagValue != $0 else { return }
                set.tagValue = $0
                if onChanged() { selectionFeedback += 1 }
            }
        )
    }

    private func setTypeIcon(for tag: WorkoutSetTag) -> String {
        switch tag {
        case .warmUp: return "flame"
        case .dropSet: return "arrow.down.right"
        case .failure: return "bolt.fill"
        }
    }

    private var setLabel: String {
        switch set.tagValue {
        case .warmUp: return "W"
        case .dropSet: return "D"
        case .failure: return "F"
        case nil: return "\(index + 1)"
        }
    }

    private var formattedWeight: String {
        let displayValue = WeightUnit.convert(
            weight: set.weightValue,
            from: .metric,
            to: settingsStore.weightUnit
        )
        return weightFormatter.string(from: NSNumber(value: displayValue)) ?? "0"
    }

    private var formattedRepetitions: String {
        String(Int(set.repetitionsValue))
    }

    private func synchronizeEntryText() {
        weightText = formattedWeight
        repetitionsText = formattedRepetitions
    }

    private func sanitizedDecimalInput(_ proposedValue: String) -> String {
        let result = WeightUnit.sanitizedDecimalInput(
            proposedValue,
            maximumFractionDigits: settingsStore.weightUnit.maximumFractionDigits,
            decimalSeparator: weightFormatter.decimalSeparator ?? Locale.current.decimalSeparator ?? ".",
            groupingSeparator: weightFormatter.groupingSeparator ?? Locale.current.groupingSeparator ?? ","
        )

        if let value = weightFormatter.number(from: result)?.doubleValue {
            let maximumDisplayWeight = WeightUnit.convert(
                weight: WorkoutSet.MAX_WEIGHT,
                from: .metric,
                to: settingsStore.weightUnit
            )
            if value > maximumDisplayWeight {
                return weightFormatter.string(from: NSNumber(value: maximumDisplayWeight)) ?? result
            }
        }
        return result
    }

    private func sanitizedIntegerInput(_ proposedValue: String) -> String {
        let digits = proposedValue.compactMap(\.wholeNumberValue).map(String.init).joined()
        guard let value = Int(digits) else { return "" }
        return String(min(value, Int(WorkoutSet.MAX_REPETITIONS)))
    }

    private func openPlateCalculator() {
        focusedField = nil
        DispatchQueue.main.async(execute: onOpenPlateCalculator)
    }

    private func setField<Content: View>(
        width: CGFloat? = nil,
        isFocused: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .font(.ironMetric(.title3, weight: .semibold))
            .foregroundColor(valueColor)
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(minWidth: 0, maxWidth: width == nil ? .infinity : nil, minHeight: 40)
            .frame(width: width)
            .background(
                RoundedRectangle(cornerRadius: IronTheme.compactCornerRadius, style: .continuous)
                    .fill(isFocused ? IronTheme.accentSoft : IronTheme.tertiaryFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: IronTheme.compactCornerRadius, style: .continuous)
                            .strokeBorder(isFocused ? IronTheme.accent : IronTheme.outline.opacity(set.isCompleted ? 0.5 : 1), lineWidth: isFocused ? 2 : 0.5)
                    }
            )
            .frame(minHeight: IronTheme.controlHeight)
            .contentShape(Rectangle())
            .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: isFocused)
    }
    private var swipeDeleteAction: some View {
        Button(action: performSwipeDelete) {
            HStack(spacing: 6) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 14, weight: .bold))
                if revealedActionWidth >= 52 {
                    Text("Delete")
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .fixedSize()
            .foregroundStyle(IronTheme.onMedia)
            .opacity(min(revealedActionWidth / 52, 1))
            .scaleEffect(reduceMotion ? 1 : 0.82 + 0.18 * min(revealedActionWidth / 52, 1))
            .frame(width: revealedActionWidth, height: measuredRowHeight)
            .background(IronTheme.danger, in: RoundedRectangle(
                cornerRadius: IronTheme.compactCornerRadius, style: .continuous
            ))
            .clipped()
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .allowsHitTesting(revealedActionWidth >= deleteActionWidth * 0.8)
        .accessibilityLabel("Delete set \(index + 1)")
        .accessibilityHidden(revealedActionWidth < deleteActionWidth * 0.8)
    }

    private var revealedActionWidth: CGFloat {
        // With row width W, reveal R and chrome expansion E, the row ends at
        // W - R + E. The action begins at W - (R - 8 - E), exactly 8 pt later.
        // This holds for every offset and for compact, timed and focused rows.
        max(0, deleteRevealWidth - deleteActionGap - InlineWorkoutSetLayout.completedChromeExpansion)
    }

    private func closeSwipe() {
        withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) {
            swipeOffset = 0
            isSwipingSet = false
            if openSwipeSetID.wrappedValue == set.objectID { openSwipeSetID.wrappedValue = nil }
        }
    }

    private var deleteRevealWidth: CGFloat {
        max(0, -swipeOffset)
    }

    /// iOS 17 fallback only. On iOS 18+ a SwiftUI drag inside the logger's
    /// ScrollView competes with scrolling, so `setRowSwipe` uses a UIKit pan
    /// that begins only for horizontal movement instead.
    private var swipeDeleteGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                handleSwipeChanged(value.translation.width)
            }
            .onEnded { value in
                handleSwipeEnded(value.translation.width, value.predictedEndTranslation.width)
            }
    }

    private func handleSwipeChanged(_ horizontal: CGFloat) {
        guard allowsSwipeToDelete else { return }
        guard horizontal < 0 || swipeOffset < 0 || isSwipingSet else { return }

        if !isSwipingSet {
            isSwipingSet = true
            swipeStartOffset = swipeOffset
            openSwipeSetID.wrappedValue = set.objectID
            focusedField = nil
        }

        swipeOffset = min(
            0,
            max(-effectiveRowWidth, swipeStartOffset + horizontal)
        )
    }

    private func handleSwipeEnded(_ horizontal: CGFloat, _ predictedHorizontal: CGFloat) {
        guard allowsSwipeToDelete else { return }
        guard isSwipingSet else { return }
        let projectedOffset = swipeStartOffset + predictedHorizontal
        isSwipingSet = false

        if swipeOffset <= -fullSwipeDeleteThreshold {
            performSwipeDelete()
        } else {
            withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) {
                swipeOffset = projectedOffset < -deleteActionWidth * 0.42
                    ? openSwipeOffset
                    : 0
            }
        }
    }

    private func performSwipeDelete() {
        guard !isPerformingSwipeDelete else { return }
        isPerformingSwipeDelete = true
        focusedField = nil

        withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) {
            swipeOffset = -effectiveRowWidth
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            withAnimation(IronMotion.preferred(IronMotion.collapse, reduceMotion: reduceMotion)) {
                if onDelete() {
                    if openSwipeSetID.wrappedValue == set.objectID { openSwipeSetID.wrappedValue = nil }
                } else {
                    swipeOffset = 0
                    isPerformingSwipeDelete = false
                }
            }
        }
    }
}

private struct HistorySetRPEPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var exerciseStore: ExerciseStore
    @ObservedObject var set: WorkoutSet
    let onChanged: () -> Bool

    @State private var selection: Double
    @State private var isScrubbing = false
    @State private var showingSaveError = false
    @State private var contentHeight: CGFloat = 280
    @ScaledMetric(relativeTo: .footnote) private var graphLabelHeight: CGFloat = 20
    private let graphHeight: CGFloat = 108
    private let setNumber: Int

    init(set: WorkoutSet, onChanged: @escaping () -> Bool) {
        self.set = set
        self.onChanged = onChanged
        let sets = set.workoutExercise?.workoutSets?.array as? [WorkoutSet] ?? []
        let index = sets.firstIndex(of: set) ?? 0
        setNumber = index + 1
        let previousRPE = index > 0 ? sets[index - 1].rpeValue : nil
        _selection = State(initialValue: set.rpeValue ?? previousRPE ?? 8)
    }

    private var valueTitle: String { String(format: "%g", selection) }

    private var title: String {
        let exercise = set.workoutExercise?.exercise(in: exerciseStore.exercises)
        return "Set \(setNumber) · \(exercise?.title ?? "Exercise")"
    }

    private var effortDescription: String {
        if selection >= 10 { return "RPE · max effort" }
        let remaining = String(format: "%g", 10 - selection)
        return "RPE · about \(remaining) \(selection == 9 ? "rep" : "reps") left"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                sheetHeader
                effortReadout
                effortGraph
                Text("Tap a bar to save. Drag to scrub.")
                    .font(.footnote)
                    .foregroundStyle(IronTheme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.top, 22) // A two-line title must clear the drag indicator.
            .padding(.bottom, 12)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0.rounded(.up) }
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.height(contentHeight)])
        .presentationDragIndicator(.visible)
        .presentationBackground(IronTheme.surface)
        .sensoryFeedback(.selection, trigger: selection) { _, _ in SettingsStore.shared.workoutHaptics }
        .alert("Effort Not Saved", isPresented: $showingSaveError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your effort change has not been saved. Try applying it again before closing.")
        }
    }

    private var sheetHeader: some View {
        HStack(spacing: 10) {
            if set.rpeValue != nil {
                Button("Clear") { save(nil) }
                    .font(.body)
                    .foregroundStyle(IronTheme.accent)
                    .frame(minWidth: IronTheme.controlHeight, minHeight: IronTheme.controlHeight)
                    .accessibilityLabel("Clear RPE")
            }
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight)
                .accessibilityAddTraits(.isHeader)
            if set.rpeValue != nil {
                Color.clear
                    .frame(width: IronTheme.controlHeight, height: 1)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
    }

    private var effortReadout: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 10))
        return layout {
            Text(valueTitle)
                .font(.ironMetric(.largeTitle))
                .foregroundStyle(IronTheme.metricEffort)
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .fixedSize()
            Text(effortDescription)
                .font(.body)
                .foregroundStyle(IronTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 56, alignment: .leading)
        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: selection)
        .accessibilityElement(children: .combine)
    }

    private var effortGraph: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(0..<11) { index in
                        effortBar(index: index)
                    }
                }
                .frame(height: graphHeight, alignment: .bottom)
                .contentShape(Rectangle())
                .ironHorizontalScrub { location in
                    guard proxy.size.width > 0 else { return }
                    let index = min(max(Int(location.x / proxy.size.width * 11), 0), 10)
                    isScrubbing = true
                    selection = 5 + Double(index) * 0.5
                } onEnded: {
                    guard isScrubbing else { return }
                    isScrubbing = false
                    save(selection)
                }
            }
            .frame(height: graphHeight)

            GeometryReader { proxy in
                let barWidth = max(0, (proxy.size.width - 50) / 11)
                ForEach(0..<6) { index in
                    Text("\(5 + index)")
                        .font(.ironMetric(.footnote, weight: .regular))
                        .foregroundStyle(IronTheme.secondaryText)
                        .position(
                            x: CGFloat(index * 2) * (barWidth + 5) + barWidth / 2,
                            y: graphLabelHeight / 2
                        )
                }
            }
            .frame(height: graphLabelHeight)
            .accessibilityHidden(true)
        }
        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: selection)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Set RPE")
        .accessibilityValue("RPE \(valueTitle), \(effortDescription)")
        .accessibilityHint("Swipe up or down to adjust by half a point. Double tap to save, or use the Save action.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: selection = min(selection + 0.5, 10)
            case .decrement: selection = max(selection - 0.5, 5)
            @unknown default: break
            }
        }
        .accessibilityAction { save(selection) }
        .accessibilityAction(named: Text("Save")) { save(selection) }
    }

    private func effortBar(index: Int) -> some View {
        let value = 5 + Double(index) * 0.5
        let tint = value <= selection
            ? (value == selection ? IronTheme.metricEffort : IronTheme.metricEffort.opacity(0.45))
            : IronTheme.solidTrack
        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(tint)
            .frame(maxWidth: .infinity)
            .frame(height: CGFloat(34 + index * 7))
            .frame(height: graphHeight, alignment: .bottom)
    }

    private func save(_ value: Double?) {
        set.rpeValue = value
        if onChanged() {
            dismiss()
        } else {
            showingSaveError = true
        }
    }
}

/// A pan that begins only when the drag is mostly horizontal, so vertical drags
/// that start on a set row scroll the page instead of being swallowed.
@available(iOS 18.0, *)
private struct HistorySetHorizontalSwipeRecognizer: UIGestureRecognizerRepresentable {
    let onChanged: (CGFloat) -> Void
    /// Translation and a velocity-projected end translation, both horizontal.
    let onEnded: (CGFloat, CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .changed:
            onChanged(translation)
        case .ended, .cancelled, .failed:
            // Roughly where a flick would carry the row, like predictedEndTranslation.
            let velocity = recognizer.velocity(in: recognizer.view).x
            onEnded(translation, translation + velocity * 0.18)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}

private extension View {
    @ViewBuilder
    func historySetRowSwipe<Legacy: Gesture>(
        enabled: Bool,
        legacy: Legacy,
        onChanged: @escaping (CGFloat) -> Void,
        onEnded: @escaping (CGFloat, CGFloat) -> Void
    ) -> some View {
        if !enabled {
            self
        } else if #available(iOS 18.0, *) {
            gesture(HistorySetHorizontalSwipeRecognizer(onChanged: onChanged, onEnded: onEnded))
        } else {
            simultaneousGesture(legacy)
        }
    }
}

#if DEBUG
struct WorkoutExerciseDetailView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            WorkoutExerciseDetailView(workoutExercise: MockWorkoutData.metricRandom.workoutExercise)
                .mockEnvironment(weightUnit: .metric)
        }
        .preferredColorScheme(.dark)
    }
}
#endif
