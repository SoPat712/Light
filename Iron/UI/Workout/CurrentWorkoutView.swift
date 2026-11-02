//
//  CurrentWorkoutView.swift
//  Iron
//
//  Iron's native inline workout logger for focused, one-handed set entry.
//

import SwiftUI
import StoreKit
import AVKit
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import CoreData
import MuscleMap
import WorkoutDataKit

private struct PersonalRecordBanner: Identifiable, Equatable {
    let id = UUID()
    let exerciseTitle: String
    let detail: String
}

/// Sensor ticks invalidate only this row, not the sets, charts or muscle paths.
private struct WorkoutWatchMetricsView: View {
    @ObservedObject var store: WatchWorkoutMetricsStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let workoutID: UUID?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let metrics = store.latest.flatMap { $0.workoutID == workoutID ? $0 : nil }
            let heartRate = metrics?.currentHeartRate(at: context.date)
            let energy = metrics?.currentActiveEnergy(at: context.date)
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 6) {
                        reading(heartRate, unit: "bpm", symbol: "heart.fill", tint: IronTheme.metricHeartRate,
                                name: "Heart rate", spokenUnit: "beats per minute")
                        reading(energy, unit: "active kcal", symbol: "flame.fill", tint: IronTheme.metricEnergy,
                                name: "Estimated active energy", spokenUnit: "active kilocalories")
                    }
                } else {
                    HStack(spacing: 12) {
                        reading(heartRate, unit: "bpm", symbol: "heart.fill", tint: IronTheme.metricHeartRate,
                                name: "Heart rate", spokenUnit: "beats per minute")
                        reading(energy, unit: "active kcal", symbol: "flame.fill", tint: IronTheme.metricEnergy,
                                name: "Estimated active energy", spokenUnit: "active kilocalories")
                    }
                }
            }
        }
    }

    private func reading(_ value: Double?, unit: String, symbol: String, tint: Color,
                         name: String, spokenUnit: String) -> some View {
        let number = value?.formatted(.number.precision(.fractionLength(0))) ?? "—"
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(number)
                .font(.ironMetric(.subheadline, weight: .semibold))
                .foregroundStyle(value == nil ? IronTheme.secondaryText : tint)
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: number)
            Text(unit)
                .font(.caption.weight(.semibold))
                .foregroundStyle(IronTheme.secondaryText)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(value == nil ? "Waiting for a current Watch reading" : "\(number) \(spokenUnit)")
    }
}

struct CurrentWorkoutView: View {
    @Environment(\.managedObjectContext) private var managedObjectContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var sceneState: SceneState
    @EnvironmentObject private var restTimerStore: RestTimerStore
    @EnvironmentObject private var exerciseStore: ExerciseStore
    @EnvironmentObject private var settingsStore: SettingsStore

    @ObservedObject var workout: Workout
    @ObservedObject private var trackingPreferencesCache = SetTrackingPreferences.cache
    @ObservedObject private var exerciseNotesCache = ExerciseNotes.cache
    @ObservedObject private var watchConnection = WatchConnectionManager.shared
    let onMinimize: () -> Void

    @State private var activeSheet: SheetType?
    @State private var noteEditor: NoteEditor?

    private struct NoteEditor: Identifiable {
        let exercise: WorkoutExercise
        let isRoutine: Bool
        var showsAllNotes = false
        var id: String { "\(exercise.objectID.uriRepresentation())-\(isRoutine)-\(showsAllNotes)" }
    }
    @State private var showingExerciseSelector = false
    @State private var showingFinishEditor = false
    @State private var showingDiscardConfirmation = false
    @State private var showingFinishDiscardConfirmation = false
    @State private var finishTitle = ""
    @State private var sessionEffort = 0.0
    @State private var finishRecap = FinishWorkoutRecap()
    @State private var finishMediaItem: PhotosPickerItem?
    @State private var finishMediaURL: URL?
    @State private var finishMediaKind = FinishWorkoutMediaKind.image
    @State private var isLoadingFinishMedia = false
    @State private var finishMediaError: String?
    @State private var finishStartDate = Date()
    @State private var showingFinishStartDateEditor = false
    @State private var finishDuration: TimeInterval = 0
    @State private var updateLinkedRoutine = false
    @State private var syncWithHealth = true
    @State private var showingVisibilityInfo = false
    /// Height of the collapsed glass summary pill plus its top padding and a gap.
    @ScaledMetric(relativeTo: .caption) private var summaryLineHeight: CGFloat = 16
    @ScaledMetric(relativeTo: .subheadline) private var accessibleSummaryRowHeight: CGFloat = 24
    @ScaledMetric(relativeTo: .subheadline) private var accessibleSyncBannerHeight: CGFloat = 56
    @State private var collapsedSummaryMeasuredHeight: CGFloat = 46
    private var collapsedSummaryClearance: CGFloat {
        max(collapsedSummaryMeasuredHeight, usesAccessibilityHeaderLayout ? summaryLineHeight * 3 + 20 : 46) + 20
    }
    @State private var isFinishingWorkout = false
    @State private var persistenceError: String?
    @State private var restTimerEditorExercise: WorkoutExercise?
    @State private var exercisePendingRemoval: WorkoutExercise?
    @State private var exercisePendingReplacement: WorkoutExercise?
    @State private var supersetExercise: WorkoutExercise?
    @State private var showingArrangeExercises = false
    @State private var selectedExerciseDetail: Exercise?
    @State private var personalRecordBanner: PersonalRecordBanner?
    @State private var scrollTarget: NSManagedObjectID?
    @State private var pendingSetScrollTarget: NSManagedObjectID?
    @State private var openSwipeSetID: NSManagedObjectID?
    @State private var runningSetTimers: [NSManagedObjectID: Date] = [:]
    @State private var restPillExerciseID: NSManagedObjectID?
    @State private var restPillSetID: NSManagedObjectID?
    @State private var isRestPillVisible = false
    @State private var restPillRevealsAt: Date?
    @State private var restRingPulses = false
    @State private var restEndFeedback = 0
    @State private var showsRunningRestRuler = false
    @State private var restLengthClampFeedback = 0
    // Local action counters keep Watch and Live Activity updates silent on iPhone.
    @State private var actionFeedback = 0
    @State private var deleteFeedback = 0
    @State private var restStripScrollRequest = 0
    @State private var restStripHighlighted = false
    @State private var recentExerciseSuggestions: [RecentExerciseSuggestion] = []

    private let loggerHorizontalInset: CGFloat = 10

    private struct RecentExerciseSuggestion: Identifiable {
        let exercise: Exercise
        let date: Date
        let setCount: Int
        let topWeight: Double
        let repetitions: Int
        let duration: TimeInterval?

        var id: UUID { exercise.uuid }
    }

    private struct ExerciseCardGroup: Identifiable {
        var exercises: [WorkoutExercise]
        var id: NSManagedObjectID { exercises[0].objectID }
        var isSuperset: Bool { exercises.count > 1 && exercises[0].supersetUuid != nil }
    }

    init(workout: Workout, onMinimize: @escaping () -> Void = {}) {
        self.workout = workout
        self.onMinimize = onMinimize
    }

    private enum SheetType: Identifiable {
        case workoutTime
        case restTimer
        case workoutOptions
        case plates(WorkoutSet)
        case warmups(WorkoutSet)

        var id: String {
            switch self {
            case .workoutTime: return "workout-time"
            case .restTimer: return "rest-timer"
            case .workoutOptions: return "workout-options"
            case .plates(let set): return "plates-\(set.objectID.uriRepresentation().absoluteString)"
            case .warmups(let set): return "warmups-\(set.objectID.uriRepresentation().absoluteString)"
            }
        }
    }

    private var workoutExercises: [WorkoutExercise] {
        workout.workoutExercises?.array as? [WorkoutExercise] ?? []
    }

    /// Presentation only: preserve the model's order and superset focus behavior.
    private var exerciseCardGroups: [ExerciseCardGroup] {
        var groups: [ExerciseCardGroup] = []
        for exercise in workoutExercises {
            if let supersetID = exercise.supersetUuid,
               let last = groups.last,
               last.exercises.last?.supersetUuid == supersetID {
                groups[groups.count - 1].exercises.append(exercise)
            } else {
                groups.append(ExerciseCardGroup(exercises: [exercise]))
            }
        }
        return groups
    }

    private var exercisePendingRemovalTitle: String {
        exercisePendingRemoval?.exercise(in: exerciseStore.exercises)?.title ?? "this exercise"
    }

    private var usesAccessibilityHeaderLayout: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var workoutTopBarHeight: CGFloat {
        usesAccessibilityHeaderLayout ? 64 : 56
    }

    private var watchSyncBannerHeight: CGFloat {
        guard showsWatchSyncBanner else { return 0 }
        return usesAccessibilityHeaderLayout ? accessibleSyncBannerHeight : 56
    }

    private var showsWatchSyncBanner: Bool {
        (settingsStore.watchCompanion || workout.wasStartedOnWatch) && watchConnection.isPaired
    }

    private let muscleMapHeight: CGFloat = 54
    private let workoutSummaryVerticalPadding: CGFloat = 12

    /// Derived from the muscle map rather than hardcoded: the header is clipped,
    /// so a summary shorter than its tallest child visibly cuts the body figures.
    private var workoutSummaryHeight: CGFloat {
        usesAccessibilityHeaderLayout
            ? max(accessibleSummaryRowHeight, IronTheme.controlHeight) * 3 + workoutSummaryVerticalPadding * 2 + 12
            : muscleMapHeight + workoutSummaryVerticalPadding * 2
    }

    private var sessionHeaderExpandedHeight: CGFloat {
        watchSyncBannerHeight + workoutSummaryHeight
    }

    private var workoutTitle: Binding<String> {
        Binding(
            get: { workout.title ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                workout.title = trimmed.isEmpty ? nil : value
                save()
            }
        )
    }

    private var workoutComment: Binding<String> {
        Binding(
            get: { workout.comment ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                workout.comment = trimmed.isEmpty ? nil : value
                save()
            }
        )
    }

    var body: some View {
        let focus = WorkoutSetFocus.next(in: workout)
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        workoutTopBar
                        if !workoutExercises.isEmpty {
                            WorkoutSessionProgressBar(workout: workout, focusedExerciseID: focus?.exerciseID) { exerciseID in
                                scrollTarget = exerciseID
                            }
                            .padding(.horizontal, IronTheme.horizontalPadding)
                            .padding(.top, 2)
                            .padding(.bottom, 8)
                        }
                        if !isSessionHeaderCollapsed {
                            sessionHeader
                        }
                    }
                    .background(.bar)
                    ZStack(alignment: .top) {
                        VStack(spacing: 0) {
                            ZStack(alignment: .top) {
                                ScrollViewReader { scrollProxy in
                                    ScrollView {
                                        LazyVStack(spacing: 0) {
                                            workoutMetadata

                                            if workoutExercises.isEmpty {
                                                emptyWorkoutState
                                            } else {
                                                ForEach(exerciseCardGroups) { group in
                                                    exerciseCardGroup(group, focusedSetID: focus?.setID)
                                                }
                                            }

                                            if !workoutExercises.isEmpty {
                                                Button {
                                                    showingExerciseSelector = true
                                                } label: {
                                                    Label("Add Exercises", systemImage: "plus")
                                                        .frame(maxWidth: .infinity)
                                                }
                                                .ironProminentGlassButtonStyle()
                                                .buttonBorderShape(.capsule)
                                                .controlSize(.large)
                                                .padding(.horizontal, loggerHorizontalInset)
                                                .padding(.top, 18)
                                            }

                                            workoutBottomActions
                                        }
                                    }
                                    // Reserve the pill's height at the scroll top, but keep its
                                    // glass floating over the viewport as content scrolls behind it.
                                    .contentMargins(.top, isSessionHeaderCollapsed ? collapsedSummaryClearance : 0, for: .scrollContent)
                                    .clipped()
                                    .onChange(of: restStripScrollRequest) { _, _ in
                                        withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) {
                                            scrollProxy.scrollTo("active-rest-strip", anchor: .center)
                                        }
                                    }
                                    .onChange(of: scrollTarget) { _, target in
                                        guard let target else { return }
                                        withAnimation(reduceMotion ? nil : IronMotion.focusScroll) {
                                            scrollProxy.scrollTo(target, anchor: .top)
                                        }
                                        scrollTarget = nil
                                    }
                                }
                                if isSessionHeaderCollapsed {
                                    collapsedWorkoutSummaryPill
                                        .onGeometryChange(for: CGFloat.self) { proxy in
                                            proxy.size.height
                                        } action: { height in
                                            collapsedSummaryMeasuredHeight = max(46, height.rounded(.up))
                                        }
                                        .padding(.horizontal, IronTheme.horizontalPadding)
                                        .padding(.top, 8)
                                        .transition(.opacity)
                                        .zIndex(1)
                                }
                            }
                        }

                        if let banner = personalRecordBanner {
                            personalRecordBannerView(banner)
                                .padding(.horizontal, IronTheme.horizontalPadding)
                                .padding(.top, isSessionHeaderCollapsed ? collapsedSummaryClearance : 8)
                                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                                .zIndex(3)
                        }
                    }
                }
                .navigationBarHidden(true)
                .navigationDestination(item: $selectedExerciseDetail) { exercise in
                    ExerciseDetailView(exercise: exercise)
                }
            }
        }
        .sheet(item: $noteEditor) { target in
            noteEditorSheet(target)
        }
        .sheet(isPresented: $showingExerciseSelector) {
            persistenceAlert(AddExercisesSheet(
                exercises: exerciseStore.shownExercises,
                recentExercises: AddExercisesSheet.loadRecentExercises(
                    context: managedObjectContext,
                    exercises: exerciseStore.shownExercises
                ),
                title: exercisePendingReplacement == nil ? "Add Exercise" : "Replace Exercise",
                actionTitle: exercisePendingReplacement == nil ? "Add" : "Replace",
                maximumSelectionCount: exercisePendingReplacement == nil ? nil : 1,
                onDismiss: {
                    guard persistenceError == nil else { return }
                    showingExerciseSelector = false
                    exercisePendingReplacement = nil
                },
                shouldDismiss: { persistenceError == nil },
                onAdd: { _ = applyExerciseSelection($0) }
            ))
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)        }
        .sheet(isPresented: $showingFinishEditor) {
            finishWorkoutSheet
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)                .interactiveDismissDisabled(isLoadingFinishMedia || isFinishingWorkout)
        }
        .sheet(item: $activeSheet) { sheet in
            persistenceAlert(sheetView(sheet))
        }
        // An alert, not a confirmation dialog: this is irreversible, so it should
        // dim the log behind it and demand an explicit choice.
        .alert("Discard this workout?", isPresented: $showingDiscardConfirmation) {
            Button("Discard Workout", role: .destructive) {
                showingDiscardConfirmation = false
                cancelWorkout()
            }
            Button("Cancel", role: .cancel) {
                showingDiscardConfirmation = false
            }
        } message: {
            Text("The workout, its notes, and every logged set will be permanently deleted.")
        }
        .alert("Workout Not Saved", isPresented: Binding(
            get: {
                persistenceError != nil
                    && !showingFinishEditor
                    && !showingExerciseSelector
                    && activeSheet == nil
                    && noteEditor == nil
            },
            set: { if !$0 { persistenceError = nil } }
        )) {
            Button("OK", role: .cancel) { persistenceError = nil }
        } message: {
            Text(persistenceError ?? "Please try again.")
        }
        .alert(
            "Remove \(exercisePendingRemovalTitle)?",
            isPresented: Binding(
                get: { exercisePendingRemoval != nil },
                set: { if !$0 { exercisePendingRemoval = nil } }
            )
        ) {
            Button("Remove Exercise", role: .destructive) {
                guard let workoutExercise = exercisePendingRemoval else { return }
                exercisePendingRemoval = nil
                DispatchQueue.main.async {
                    deleteWorkoutExercise(workoutExercise)
                }
            }
            Button("Cancel", role: .cancel) {
                exercisePendingRemoval = nil
            }
        } message: {
            Text("Every set logged for this exercise in the current workout will be removed.")
        }
        .sheet(item: $supersetExercise) { source in
            persistenceAlert(WorkoutSupersetSheet(
                source: source,
                exercises: workoutExercises,
                onSave: { partnerIDs in configureSuperset(for: source, partnerIDs: partnerIDs) },
                onRemove: source.supersetUuid == nil ? nil : { removeFromSuperset(source) }
            ))
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingArrangeExercises) {
            persistenceAlert(WorkoutArrangeExercisesSheet(
                exercises: workoutExercises,
                onSave: saveExerciseOrder
            ))
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .ironScreen()
        .ironSelectsNumberOnFocus()
        .onAppear {
            WorkoutLiveActivityManager.shared.startOrUpdate(for: workout)
            refreshRecentExerciseSuggestions()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ironInspectAddExercises") {
                showingExerciseSelector = true
            } else if ProcessInfo.processInfo.arguments.contains("-ironInspectFinishWorkout") {
                showingFinishEditor = true
            } else if ProcessInfo.processInfo.arguments.contains("-ironInspectCollapsedSummary") {
                sceneState.collapsedWorkoutSummaries.insert(workoutSummaryKey)
                if let workoutID = workout.uuid {
                    Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                        watchConnection.liveMetrics.receive(
                            WatchWorkoutMetrics(workoutID: workoutID, state: .running, heartRate: 188,
                                                heartRateDate: Date(), activeEnergyKilocalories: 1024),
                            workoutID: workoutID
                        )
                    }.fire()
                }
            }
            #endif
            applyIdleTimerPreference()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onReceive(managedObjectContext.publisher) { changes in
            // Child-set edits (including Watch events) do not always invalidate
            // an observed Workout. Refresh aggregates on edits, not clock ticks.
            let changed = changes.inserted.union(changes.updated).union(changes.deleted)
            if changed.contains(where: { object in
                if let exercise = object as? WorkoutExercise {
                    return exercise.isDeleted || exercise.workout == workout
                }
                if let set = object as? WorkoutSet {
                    return set.isDeleted || set.workoutExercise?.workout == workout
                }
                return false
            }) {
                workout.objectWillChange.send()
            }
        }
        .onChange(of: settingsStore.keepScreenAwakeDuringWorkout) { _, _ in
            applyIdleTimerPreference()
        }
        .onChange(of: exerciseStore.lastPerformedDates) { _, _ in
            refreshRecentExerciseSuggestions()
        }
        .onChange(of: workoutExercises.map(\.objectID)) { _, _ in
            if workoutExercises.isEmpty { refreshRecentExerciseSuggestions() }
        }
        .task(id: restPillTimerSnapshot) {
            await updateRestPillPresentation()
        }
        .sensoryFeedback(.impact(weight: .light), trigger: restEndFeedback) { _, _ in
            settingsStore.workoutHaptics && !NotificationManager.watchOwnsRestAlerts
        }
        .sensoryFeedback(.error, trigger: restLengthClampFeedback) { _, _ in settingsStore.workoutHaptics }
        .sensoryFeedback(.selection, trigger: actionFeedback) { _, _ in settingsStore.workoutHaptics }
        .sensoryFeedback(.impact(weight: .medium), trigger: deleteFeedback) { _, _ in settingsStore.workoutHaptics }
        .sensoryFeedback(.error, trigger: persistenceError) { _, error in error != nil && settingsStore.workoutHaptics }
    }

    private func applyIdleTimerPreference() {
        UIApplication.shared.isIdleTimerDisabled = settingsStore.keepScreenAwakeDuringWorkout
    }

    @ViewBuilder
    private func noteEditorSheet(_ target: NoteEditor) -> some View {
        if target.showsAllNotes {
            WorkoutExerciseNotesSheet(
                exerciseNote: ExerciseNotes.note(for: target.exercise.exerciseUuid),
                planNote: target.exercise.routineNote,
                workoutNote: target.exercise.comment,
                canEditExercise: target.exercise.exerciseUuid != nil,
                canEditPlan: target.exercise.routineNoteSource() != nil,
                exerciseEditor: {
                    persistentNoteEditor(NoteEditor(exercise: target.exercise, isRoutine: false))
                },
                planEditor: {
                    persistentNoteEditor(NoteEditor(exercise: target.exercise, isRoutine: true))
                },
                onSaveWorkout: { text in
                    guard !target.exercise.isDeleted else { return false }
                    target.exercise.comment = text.isEmpty ? nil : text
                    return save()
                }
            )
        } else {
            persistentNoteEditor(target)
        }
    }

    private func persistentNoteEditor(_ target: NoteEditor) -> ExerciseNoteEditorSheet {
        ExerciseNoteEditorSheet(
            title: target.isRoutine ? "Workout Plan Note" : "Exercise Note",
            subtitle: target.isRoutine
                ? "Shown whenever you start from this saved workout."
                : "Shown in every workout that includes this exercise.",
            text: target.isRoutine ? (target.exercise.routineNote ?? "")
                : (ExerciseNotes.note(for: target.exercise.exerciseUuid) ?? "")
        ) { text in
            guard !target.exercise.isDeleted else { return false }
            if target.isRoutine {
                guard let source = target.exercise.routineNoteSource() else { return false }
                let saved = persistMutation { source.comment = text.isEmpty ? nil : text }
                if saved {
                    persistenceError = nil
                    workout.objectWillChange.send()
                    WatchConnectionManager.shared.syncCurrentWorkoutSnapshot()
                }
                return saved
            }
            guard let exerciseID = target.exercise.exerciseUuid else { return false }
            ExerciseNotes.setNote(text, for: exerciseID)
            return true
        }
    }

    private func persistenceAlert<Content: View>(_ content: Content) -> some View {
        content.alert("Workout Not Saved", isPresented: Binding(
            get: { persistenceError != nil },
            set: { if !$0 { persistenceError = nil } }
        )) {
            Button("OK", role: .cancel) { persistenceError = nil }
        } message: {
            Text(persistenceError ?? "Please try again.")
        }
    }

    @ViewBuilder
    private func sheetView(_ sheet: SheetType) -> some View {
        switch sheet {
        case .workoutTime:
            utilitySheet(
                title: "Workout Duration",
                subtitle: "",
                systemImage: "stopwatch",
                detents: [.large]
            ) {
                EditCurrentWorkoutTimeView(workout: workout) {
                    if save() { activeSheet = nil }
                }
            }

        case .restTimer:
            IronUtilitySheet(
                title: "Rest Timer",
                subtitle: "",
                systemImage: "timer",
                onClose: { activeSheet = nil }
            ) {
                RestTimerView()
                    .environmentObject(restTimerStore)
            }
            // Running and selector states now use one bottom-sheet language;
            // their contextual actions are the only visual difference.
            .presentationDetents([.height(RestTimerSheetLayout.height)])
            .presentationDragIndicator(.visible)

        case .workoutOptions:
            NavigationStack {
                GeneralSettingsView()
                    .contentMargins(.horizontal, loggerHorizontalInset, for: .scrollContent)
                    .font(.body)
                    .navigationTitle("Workout Options")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { activeSheet = nil }
                        }
                    }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)

        case .plates(let set):
            utilitySheet(
                title: "Plate Calculator",
                subtitle: "",
                systemImage: "plusminus",
                detents: [.large],
                showsDone: false
            ) {
                PlateCalculatorView(
                    unit: settingsStore.weightUnit,
                    initialTarget: max(displayWeight(for: set), settingsStore.weightUnit.barbellWeight),
                    exerciseKey: set.workoutExercise?.exerciseUuid?.uuidString,
                    onClose: { activeSheet = nil },
                    onApply: { value in
                        let metricWeight = WeightUnit.convert(
                            weight: value,
                            from: settingsStore.weightUnit,
                            to: .metric
                        )
                        let saved = persistMutation {
                            if let workoutExercise = set.workoutExercise {
                                // Logged sets keep what was actually lifted.
                                workoutSets(for: workoutExercise)
                                    .filter { !$0.isCompleted || $0.objectID == set.objectID }
                                    .forEach { $0.weightValue = metricWeight }
                            } else {
                                set.weightValue = metricWeight
                            }
                        }
                        if saved {
                            WorkoutLiveActivityManager.shared.startOrUpdate(for: workout)
                            activeSheet = nil
                        }
                    }
                )
            }

        case .warmups(let set):
            utilitySheet(
                title: "Warm-Up Calculator",
                subtitle: "",
                systemImage: "flame",
                detents: [.large]
            ) {
                WarmupCalculatorView(
                    unit: settingsStore.weightUnit,
                    workingWeight: displayWeight(for: set),
                    exerciseKey: set.workoutExercise?.exerciseUuid?.uuidString
                        ?? set.workoutExercise?.exercise(in: exerciseStore.exercises)?.title,
                    onAdd: { recommendations in addWarmupSets(recommendations, before: set) }
                )
            }
        }
    }

    private func utilitySheet<Content: View>(
        title: String,
        subtitle: String,
        systemImage: String,
        detents: Set<PresentationDetent>,
        showsDone: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        IronUtilitySheet(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            showsDone: showsDone,
            onClose: { activeSheet = nil },
            content: content
        )
        .presentationDetents(detents)
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)    }

    /// The logger is presented as a sheet, so it owns its own bar. Glass over the
    /// scrolling set list is the one place a floating layer belongs here; an
    /// opaque fill made this read as a third stacked panel above the header.
    private var workoutTopBar: some View {
        HStack(spacing: 10) {
            Button(action: onMinimize) {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: IronTheme.iconButtonSize, height: IronTheme.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Minimize Workout")

            if !usesAccessibilityHeaderLayout {
                Text("Log Workout")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            Spacer(minLength: 4)

            restTimerTopBarButton

            Button { showingFinishEditor = true } label: {
                Text("Finish")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 34) // With the small control's padding, the timer's 44 pt.
            }
                .ironProminentGlassButtonStyle()
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: IronTheme.controlHeight, minHeight: IronTheme.controlHeight)
                .contentShape(Rectangle())
                .layoutPriority(2)
                .disabled(workoutExercises.isEmpty)
        }
        .padding(.horizontal, IronTheme.horizontalPadding)
        .frame(height: workoutTopBarHeight)
    }

    /// Timer control beside Finish: a compact timer glyph at rest, and the
    /// live countdown once a rest is running.
    private var restTimerTopBarButton: some View {
        Button {
            actionFeedback += 1
            activeSheet = .restTimer
        } label: {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if let remaining = restTimerStore.restTimerRemainingTime {
                    Text(restTimerCountdownText(remaining))
                        .font(.ironMetric(.subheadline, weight: .semibold))
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(restTimerTint)
                        .contentTransition(reduceMotion ? .opacity : .numericText())
                        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: Int(remaining))
                        .padding(.horizontal, 10)
                        .accessibilityValue(remaining <= 0 ? "Finished" : restTimerTimeText(remaining))
                } else {
                    Image(systemName: "timer")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(IronTheme.metricTime)
                        .frame(width: 32, height: 32)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(minWidth: IronTheme.controlHeight, minHeight: IronTheme.controlHeight)
        .background(restTimerTint.opacity(0.18), in: Capsule())
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(restTimerTint)
        .animation(IronMotion.preferred(IronMotion.fade, reduceMotion: reduceMotion), value: restTimerStore.isPaused)
        .accessibilityLabel("Rest timer")
    }

    /// Paused rest keeps the warning tint so it reads differently from a live countdown.
    private var restTimerTint: Color {
        restTimerStore.isPaused ? IronTheme.warning : IronTheme.metricTime
    }

    private func personalRecordBannerView(_ banner: PersonalRecordBanner) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "medal.fill")
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: 1) {
                Text("Personal Record")
                    .font(.footnote.weight(.semibold))
                Text("\(banner.exerciseTitle) · \(banner.detail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .ironLiquidGlassPill(tint: .clear)
        .shadow(color: Color.black.opacity(0.16), radius: 16, x: 0, y: 7)
        .accessibilityElement(children: .combine)
        .task(id: banner.id) {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) { personalRecordBanner = nil }
        }
    }

    /// Options and discard share one row of matching glass buttons so the end of
    /// the log does not trail off into a lone red text link.
    private var workoutBottomActions: some View {
        HStack(spacing: 10) {
            Button {
                activeSheet = .workoutOptions
            } label: {
                Label("Options", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .ironGlassButtonStyle()

            Button(role: .destructive) {
                showingDiscardConfirmation = true
            } label: {
                Label("Discard", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .ironGlassButtonStyle()
            .tint(.red)
        }
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .padding(.horizontal, loggerHorizontalInset)
        .padding(.top, 10)
        .padding(.bottom, 28)
    }

    private var sessionHeader: some View {
        VStack(spacing: 0) {
            if showsWatchSyncBanner { watchSyncBanner }
            workoutSummary
                .frame(height: workoutSummaryHeight)
        }
        // A plain conditional swap with the compact pill. An offset-and-clip reveal
        // let individual children linger outside the clip during the transition.
        .frame(height: sessionHeaderExpandedHeight)
    }

    private var watchSyncColor: Color {
        guard settingsStore.watchCompanion || workout.wasStartedOnWatch else { return IronTheme.secondaryText }
        guard watchConnection.isPaired else { return IronTheme.secondaryText }
        guard watchConnection.isWatchAppInstalled else { return IronTheme.warning }
        return watchConnection.isReachable ? IronTheme.success : IronTheme.warning
    }

    private var watchSyncTitle: String {
        if workout.wasStartedOnWatch {
            return watchConnection.isReachable ? "Also on Apple Watch" : "Apple Watch offline · changes queued"
        }
        guard settingsStore.watchCompanion else { return "Saved locally on this iPhone" }
        guard watchConnection.isPaired else { return "Saved on iPhone · Watch not paired" }
        guard watchConnection.isWatchAppInstalled else { return "Saved on iPhone · Install Light on Watch" }
        if watchConnection.isReachable { return "Live Sync Active" }
        return watchConnection.isActivated
            ? "Watch offline · changes queued"
            : "Watch sync preparing"
    }

    private var watchSyncSystemImage: String {
        guard settingsStore.watchCompanion || workout.wasStartedOnWatch,
              watchConnection.isPaired,
              watchConnection.isWatchAppInstalled else {
            return "iphone"
        }
        return "applewatch"
    }

    private var workoutSummaryKey: String {
        workout.uuid?.uuidString ?? workout.objectID.uriRepresentation().absoluteString
    }

    private var isSessionHeaderCollapsed: Bool {
        sceneState.collapsedWorkoutSummaries.contains(workoutSummaryKey)
    }

    private func setSessionHeaderCollapsed(_ collapsed: Bool) {
        guard collapsed != isSessionHeaderCollapsed else { return }
        actionFeedback += 1

        withAnimation(IronMotion.preferred(IronMotion.collapse, reduceMotion: reduceMotion)) {
            if collapsed {
                sceneState.collapsedWorkoutSummaries.insert(workoutSummaryKey)
            } else {
                sceneState.collapsedWorkoutSummaries.remove(workoutSummaryKey)
            }
        }
    }

    private var watchSyncBanner: some View {
        let color = watchSyncColor
        let showsMetrics = (settingsStore.watchCompanion || workout.wasStartedOnWatch) && watchConnection.isPaired
            && watchConnection.isWatchAppInstalled && watchConnection.isReachable

        return HStack(spacing: 9) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .accessibilityLabel(showsMetrics ? "Watch connected" : watchSyncTitle)
            if showsMetrics {
                WorkoutWatchMetricsView(store: watchConnection.liveMetrics, workoutID: workout.uuid)
            } else {
                Text(watchSyncTitle)
                    .font(.subheadline)
                    .lineLimit(usesAccessibilityHeaderLayout ? 2 : 1)
                    .minimumScaleFactor(0.85)
            }
            Spacer()
            if !showsMetrics {
                Image(systemName: watchSyncSystemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
            }

            Button {
                setSessionHeaderCollapsed(!isSessionHeaderCollapsed)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isSessionHeaderCollapsed ? 180 : 0))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .frame(width: IronTheme.controlHeight, height: IronTheme.controlHeight)
            .contentShape(Circle())
            .accessibilityLabel(isSessionHeaderCollapsed ? "Expand workout summary" : "Collapse workout summary")
        }
        .padding(.leading, IronTheme.horizontalPadding)
        .padding(.trailing, IronTheme.horizontalPadding)
        .frame(height: watchSyncBannerHeight)
    }

    private var workoutSummary: some View {
        Group {
            if usesAccessibilityHeaderLayout {
                VStack(spacing: 6) {
                    workoutDurationSummary
                    accessibleSummaryRow(workoutWorkLabel, value: workoutVolumeTitle, tint: workoutWorkTint)
                    workoutSetsSummary
                }
            } else {
                GeometryReader { proxy in
                    // Duration/volume need more room than the set count. Explicit
                    // columns and gutters keep changing numbers inside their lane.
                    let mapWidth: CGFloat = 64
                    let metricWidth = max(0, proxy.size.width - mapWidth - 36)
                    HStack(alignment: .top, spacing: 12) {
                        workoutDurationSummary
                            .frame(width: metricWidth * 0.43)
                        summaryValue(workoutWorkLabel, workoutVolumeNumber, tint: workoutWorkTint, unit: workoutWorkUnit)
                            .frame(width: metricWidth * 0.41)
                        workoutSetsSummary
                            .frame(width: metricWidth * 0.16)
                        liveMuscleMap
                            .frame(width: mapWidth)
                    }
                    .frame(height: proxy.size.height, alignment: .top)
                }
            }
        }
        .padding(.horizontal, IronTheme.horizontalPadding)
        .padding(.vertical, workoutSummaryVerticalPadding)
    }

    /// Keep the summary collapse action available when the idle sync line is hidden.
    private var workoutSetsSummary: some View {
        Group {
            if showsWatchSyncBanner {
                setsSummaryValue
            } else {
                Button { setSessionHeaderCollapsed(true) } label: {
                    setsSummaryValue
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Collapse workout summary")
                .accessibilityValue("\(workout.numberOfCompletedSets ?? 0) sets")
            }
        }
    }

    private var setsSummaryValue: some View {
        Group {
            if usesAccessibilityHeaderLayout {
                HStack(spacing: 6) {
                    accessibleSummaryRow("Sets", value: "\(workout.numberOfCompletedSets ?? 0)", tint: IronTheme.metricSets)
                    if !showsWatchSyncBanner {
                        Image(systemName: "chevron.up")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(IronTheme.secondaryText)
                            .accessibilityHidden(true)
                    }
                }
            } else {
                summaryValue(
                    "Sets", "\(workout.numberOfCompletedSets ?? 0)", tint: IronTheme.metricSets,
                    systemImage: showsWatchSyncBanner ? nil : "chevron.up"
                )
                .frame(minHeight: IronTheme.controlHeight)
                .contentShape(Rectangle())
            }
        }
    }

    /// Only the clock refreshes each second. Metrics and the two muscle paths
    /// refresh when the model changes, rather than on every clock tick.
    private var workoutDurationSummary: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { _ in
            let title = workoutDurationTitle
            Button(action: { activeSheet = .workoutTime }) {
                if usesAccessibilityHeaderLayout {
                    accessibleSummaryRow("Duration", value: title, tint: IronTheme.metricTime)
                } else {
                    summaryValue("Duration", title, tint: IronTheme.metricTime, systemImage: "pencil")
                        .frame(minHeight: IronTheme.controlHeight)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit workout duration")
            .accessibilityValue(title)
        }
    }

    private func accessibleSummaryRow(_ title: String, value: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(IronTheme.secondaryText)
            Spacer(minLength: 0)
            Text(value).font(.ironMetric(.subheadline)).foregroundStyle(tint)
        }
        .font(.subheadline)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .frame(minHeight: max(accessibleSummaryRowHeight, IronTheme.controlHeight))
        .accessibilityElement(children: .combine)
    }

    private var collapsedWorkoutSummaryPill: some View {
        let volume = collapsedVolume
        let sets = collapsedSets
        let volumeTitle = workoutVolumeTitle
        let setCount = workout.numberOfCompletedSets ?? 0
        return TimelineView(.periodic(from: Date(), by: 1)) { context in
            let durationTitle = workoutDurationTitle
            // The clock already redraws this pill every second, so reading the store
            // here adds no sensor invalidation to the rest of the logger.
            let metrics = watchConnection.liveMetrics.latest.flatMap { $0.workoutID == workout.uuid ? $0 : nil }
            let heartRate = metrics?.currentHeartRate(at: context.date)
                .map { $0.formatted(.number.precision(.fractionLength(0))) }
            let energy = metrics?.currentActiveEnergy(at: context.date)
                .map { $0.formatted(.number.precision(.fractionLength(0))) }
            let hasVitals = heartRate != nil || energy != nil
            Button(action: { setSessionHeaderCollapsed(false) }) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(.tint)
                        .frame(width: 7, height: 7)

                    if usesAccessibilityHeaderLayout {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(durationTitle)
                                .font(.ironMetric(.subheadline, weight: .semibold))
                                .foregroundStyle(IronTheme.metricTime)
                            volume
                            sets
                            if hasVitals {
                                collapsedVitals(heartRate: heartRate, energy: energy)
                            }
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // The vitals replace the dots so the row doesn't reflow as numbers grow.
                        // If the type is too large for them, they give way to the expanded header.
                        ViewThatFits(in: .horizontal) {
                            if hasVitals {
                                collapsedSummaryRow(durationTitle, volume: volume, sets: sets,
                                                    heartRate: heartRate, energy: energy, showsDots: false)
                            }
                            collapsedSummaryRow(durationTitle, volume: volume, sets: sets,
                                                heartRate: nil, energy: nil, showsDots: true)
                        }
                        // A Spacer here would take half the row from the fit test.
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                .font(.caption)
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: volumeTitle)
                .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: setCount)
                .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: Int(workout.safeDuration))
                .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: heartRate)
                .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: energy)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 46)
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            // The opaque backing prevents labels in scrolling cards bleeding through.
            .background(IronTheme.surface, in: Capsule(style: .continuous))
            .ironLiquidGlassPill(tint: .clear)
            .clipShape(Capsule(style: .continuous))
            .shadow(color: IronTheme.outline.opacity(0.16), radius: 16, x: 0, y: 7)
            .accessibilityLabel("Expand workout summary")
            .accessibilityValue(
                ["\(durationTitle), \(volumeTitle), \(setCount) \(setCount == 1 ? "set" : "sets")",
                 heartRate.map { "\($0) beats per minute" },
                 energy.map { "\($0) active kilocalories" }]
                    .compactMap { $0 }
                    .joined(separator: ", ")
            )
        }
    }

    private func collapsedSummaryRow(
        _ durationTitle: String,
        volume: IronMetricValue,
        sets: IronMetricValue,
        heartRate: String?,
        energy: String?,
        showsDots: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Text(durationTitle)
                .font(.ironMetric(.subheadline, weight: .semibold))
                .foregroundStyle(IronTheme.metricTime)
            if showsDots { collapsedSummaryDot }
            volume
            if showsDots { collapsedSummaryDot }
            sets
            if heartRate != nil || energy != nil {
                collapsedVitals(heartRate: heartRate, energy: energy)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var collapsedSummaryDot: some View {
        Text("•")
            .foregroundStyle(.tertiary)
    }

    private func collapsedVitals(heartRate: String?, energy: String?) -> some View {
        HStack(spacing: 6) {
            if let heartRate {
                collapsedVital(heartRate, symbol: "heart.fill", tint: IronTheme.metricHeartRate)
            }
            if let energy {
                collapsedVital(energy, symbol: "flame.fill", tint: IronTheme.metricEnergy)
            }
        }
    }

    private func collapsedVital(_ number: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
            Text(number)
                .font(.ironMetric(.subheadline, weight: .semibold))
        }
        .foregroundStyle(tint)
    }

    private var collapsedVolume: IronMetricValue {
        IronMetricValue(
            value: workoutVolumeNumber, unit: workoutWorkUnit,
            style: .subheadline, weight: .semibold, unitStyle: .caption,
            tint: workoutWorkTint
        )
    }

    private var collapsedSets: IronMetricValue {
        let setCount = workout.numberOfCompletedSets ?? 0
        return IronMetricValue(
            value: "\(setCount)", unit: setCount == 1 ? "set" : "sets",
            style: .subheadline, weight: .semibold, unitStyle: .caption,
            tint: IronTheme.metricSets
        )
    }

    private func summaryValue(
        _ label: String,
        _ value: String,
        tint: Color,
        unit: String? = nil,
        systemImage: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(label)
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 8, weight: .semibold))
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            IronMetricValue(value: value, unit: unit, tint: tint)
            .contentTransition(reduceMotion ? .opacity : .numericText())
            .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: value)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var completedExerciseMuscles: (primary: [Muscle], secondary: [Muscle]) {
        var primary: [Muscle] = []
        var secondary: [Muscle] = []

        for workoutExercise in workoutExercises {
            guard workoutSets(for: workoutExercise).contains(where: \.isCompleted),
                  let exercise = workoutExercise.exercise(in: exerciseStore.exercises) else { continue }

            for muscle in exercise.primaryMuscle.compactMap(ironMapMuscle) where !primary.contains(muscle) {
                primary.append(muscle)
            }
            for muscle in exercise.secondaryMuscle.compactMap(ironMapMuscle)
                where !primary.contains(muscle) && !secondary.contains(muscle) {
                secondary.append(muscle)
            }
        }

        return (primary, secondary)
    }

    private var liveMuscleMap: some View {
        let muscles = completedExerciseMuscles
        return HStack(spacing: 2) {
            liveMuscleBody(side: .front, muscles: muscles)
            liveMuscleBody(side: .back, muscles: muscles)
        }
        .frame(height: muscleMapHeight)
        .allowsHitTesting(false)
        .accessibilityRepresentation {
            Text(muscles.primary.isEmpty && muscles.secondary.isEmpty
                 ? "No muscles logged yet"
                 : "Muscles trained in completed sets")
                .accessibilityAddTraits(.isImage)
        }
    }

    private func liveMuscleBody(
        side: BodySide,
        muscles: (primary: [Muscle], secondary: [Muscle])
    ) -> some View {
        let style = BodyViewStyle(
            defaultFillColor: Color(.tertiaryLabel).opacity(0.35),
            strokeColor: Color(.separator),
            strokeWidth: 0.5,
            selectionColor: IronTheme.accent,
            selectionStrokeColor: IronTheme.accent,
            selectionStrokeWidth: 1,
            headColor: Color(.tertiaryLabel).opacity(0.45),
            hairColor: Color(.quaternaryLabel)
        )
        return BodyView(gender: .male, side: side, style: style)
            .highlight(muscles.secondary, color: IronTheme.accent, opacity: 0.42)
            .highlight(muscles.primary, color: IronTheme.accent)
    }

    @ViewBuilder
    private var workoutMetadata: some View {
        if workout.title != nil || workout.comment != nil || workout.wasStartedOnWatch {
            VStack(spacing: 0) {
                if workout.wasStartedOnWatch {
                    Label("Also on Apple Watch", systemImage: "applewatch")
                        .font(.subheadline)
                        .foregroundStyle(IronTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
                if workout.title != nil {
                    TextField(suggestedWorkoutTitle, text: workoutTitle)
                        .font(.headline.weight(.semibold))
                        .padding(.vertical, 11)
                }
                if workout.comment != nil {
                    TextField("Workout notes", text: workoutComment)
                        .font(.subheadline)
                        .foregroundColor(IronTheme.secondaryText)
                        .padding(.vertical, 11)
                }
            }
            .padding(.horizontal, IronTheme.horizontalPadding)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var emptyWorkoutState: some View {
        if workout.wasStartedOnWatch {
            ContentUnavailableView {
                Label("Waiting for Apple Watch…", systemImage: "applewatch")
            } description: {
                Text("Your workout is running on Apple Watch. Exercises and logged sets appear here as they sync.")
            } actions: {
                Button("Add Exercises") { showingExerciseSelector = true }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 24)
        } else if recentExerciseSuggestions.isEmpty {
            originalEmptyWorkoutState
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Tap to add · uses your last weights")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(IronTheme.secondaryText)
                    .padding(.horizontal, 10)

                VStack(spacing: 0) {
                    ForEach(recentExerciseSuggestions) { suggestion in
                        recentExerciseRow(suggestion)
                    }
                }
                .padding(.vertical, 4)
                .background(IronTheme.surface, in: RoundedRectangle(
                    cornerRadius: IronTheme.heroCornerRadius, style: .continuous
                ))

                Button { showingExerciseSelector = true } label: {
                    Text("Browse All Exercises")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(IronTheme.accent)
            }
            .padding(.horizontal, loggerHorizontalInset)
            .padding(.top, 16)
        }
    }

    private var originalEmptyWorkoutState: some View {
        ContentUnavailableView {
            Label("Start with an Exercise", systemImage: "figure.strengthtraining.traditional")
        } description: {
            Text("Add exercises, then log weight, reps, and effort directly on this screen.")
        } actions: {
            Button("Add Exercises") { showingExerciseSelector = true }
                .ironProminentGlassButtonStyle()
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 24)
    }

    private func recentExerciseRow(_ suggestion: RecentExerciseSuggestion) -> some View {
        Button {
            _ = applyExerciseSelection([suggestion.exercise])
        } label: {
            HStack(spacing: 12) {
                ExerciseDiagramThumbnail(exercise: suggestion.exercise, size: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(suggestion.exercise.title)
                        .font(.headline)
                        .foregroundStyle(IronTheme.primaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(recentExerciseSubtitle(suggestion))
                        .font(.ironMetric(.subheadline, weight: .regular))
                        .foregroundStyle(IronTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "plus")
                    .font(.body.weight(.bold))
                    .foregroundStyle(IronTheme.accent)
                    .frame(width: 34, height: 34)
                    .background(IronTheme.accentSoft, in: Circle())
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add \(suggestion.exercise.title)")
        .accessibilityValue(recentExerciseSubtitle(suggestion))
        .accessibilityHint("Uses your previous set values when prefill is enabled")
    }

    private func recentExerciseSubtitle(_ suggestion: RecentExerciseSuggestion) -> String {
        let date = ExerciseRecencyCaption.title(for: suggestion.date)
        if let duration = suggestion.duration {
            return "\(date) · \(suggestion.setCount) × \(restTimerTimeText(duration))"
        }
        let weight = WeightUnit.format(weight: suggestion.topWeight, from: .metric, to: settingsStore.weightUnit)
        return "\(date) · \(suggestion.setCount) × \(weight) × \(suggestion.repetitions)"
    }

    private func refreshRecentExerciseSuggestions() {
        guard workoutExercises.isEmpty else { return }
        let existingIDs = Set(workoutExercises.compactMap(\.exerciseUuid))
        let candidates = AddExercisesSheet.loadRecentExercises(
            context: managedObjectContext, exercises: exerciseStore.shownExercises
        ).filter { !existingIDs.contains($0.uuid) }.prefix(5)

        // At most five latest-session fetches, outside body evaluation. Never scan history.
        recentExerciseSuggestions = candidates.compactMap { exercise in
            let request = WorkoutExercise.historyFetchRequest(of: exercise.uuid)
            request.fetchLimit = 1
            request.relationshipKeyPathsForPrefetching = ["workout", "workoutSets"]
            guard let history = try? managedObjectContext.fetch(request).first,
                  let date = history.workout?.start else { return nil }
            let sets = workoutSets(for: history).filter(\.isCompleted)
            guard let topSet = sets.max(by: { lhs, rhs in
                lhs.weightValue == rhs.weightValue
                    ? lhs.repetitionsValue < rhs.repetitionsValue
                    : lhs.weightValue < rhs.weightValue
            }) else { return nil }
            let duration = sets.allSatisfy { $0.durationValue != nil && $0.distanceValue == nil }
                ? sets.compactMap(\.durationValue).max() : nil
            return RecentExerciseSuggestion(
                exercise: exercise, date: date, setCount: sets.count,
                topWeight: topSet.weightValue, repetitions: Int(topSet.repetitionsValue), duration: duration
            )
        }
    }

    private func exerciseCardGroup(_ group: ExerciseCardGroup, focusedSetID: NSManagedObjectID?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if group.isSuperset {
                Label("SUPERSET", systemImage: "link")
                    .font(.footnote.bold())
                    .foregroundStyle(IronTheme.accent)
                    .padding(.leading, 6)
                    .padding(.bottom, 4)
            }
            VStack(spacing: 6) {
                ForEach(Array(group.exercises.enumerated()), id: \.element.objectID) { index, exercise in
                    workoutExerciseSection(
                        exercise, focusedSetID: focusedSetID,
                        supersetLetter: group.isSuperset ? supersetLetter(at: index) : nil
                    )
                }
            }
            .padding(.leading, group.isSuperset ? 10 : 0)
            .overlay(alignment: .leading) {
                if group.isSuperset {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(IronTheme.accent)
                        .frame(width: 4)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, loggerHorizontalInset)
        .padding(.top, 14)
    }

    private func supersetLetter(at index: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return index < letters.count ? String(letters[index]) : String(index + 1)
    }

    private func workoutExerciseSection(
        _ workoutExercise: WorkoutExercise, focusedSetID: NSManagedObjectID?, supersetLetter: String?
    ) -> some View {
        let exercise = workoutExercise.exercise(in: exerciseStore.exercises)
        let sets = workoutSets(for: workoutExercise)
        let isBarbell = exercise?.type == .barbell
        let trackingType = workoutExercise.setTrackingType

        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                if let exercise = exercise {
                    ExerciseDiagramThumbnail(exercise: exercise, size: 42)
                        .frame(width: IronTheme.iconButtonSize, height: IronTheme.controlHeight)
                        .contentShape(Rectangle())
                        .onLongPressGesture(minimumDuration: 0.35) {
                            showingArrangeExercises = true
                        }
                        .accessibilityAction(named: Text("Reorder Exercises")) {
                            showingArrangeExercises = true
                        }
                        .overlay(alignment: .bottomTrailing) {
                            supersetLetterBadge(supersetLetter)
                        }
                } else {
                    Circle()
                        .fill(IronTheme.tertiaryFill)
                        .frame(width: IronTheme.iconButtonSize, height: IronTheme.controlHeight)
                        .overlay(Image(systemName: "dumbbell.fill").foregroundStyle(.secondary))
                        .overlay(alignment: .bottomTrailing) {
                            supersetLetterBadge(supersetLetter)
                        }
                }

                VStack(alignment: .leading, spacing: 0) {
                    if let exercise {
                        exerciseNameButton(exercise)
                    } else {
                        Text("Unknown Exercise")
                            .font(.headline)
                            .lineLimit(usesAccessibilityHeaderLayout ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    exerciseMetadata(exercise, workoutExercise: workoutExercise, sets: sets)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Menu {
                    exerciseMenuItems(
                        for: workoutExercise,
                        sets: sets,
                        isBarbell: isBarbell && trackingType.usesWeight
                    )
                } label: {
                    Label("Exercise Actions", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                        .frame(width: IronTheme.iconButtonSize, height: IronTheme.controlHeight)
                        .contentShape(Rectangle())
                }
            }

            if restTimerEditorExercise?.objectID == workoutExercise.objectID {
                RestLengthRuler(value: Binding(
                    get: { restTimerDuration(for: workoutExercise) }, set: { _ in }
                )) { duration in
                    setRestTimer(duration, for: workoutExercise)
                }
                .padding(.top, 10)
                .transition(restPillTransition)

                HStack {
                    Spacer(minLength: 0)
                    Button("Done") { toggleDefaultRestRuler(for: workoutExercise) }
                        .buttonStyle(.plain)
                        .foregroundStyle(IronTheme.accent)
                        .frame(minWidth: IronTheme.controlHeight, minHeight: IronTheme.controlHeight)
                }
            }

            workoutExerciseNotes(for: workoutExercise)

            setTableHeader(trackingType: trackingType)
            .padding(.top, 12)

            ForEach(Array(sets.enumerated()), id: \.element.id) { setIndex, set in
                let previousSet = latestHistorySet(for: workoutExercise, at: setIndex)
                InlineWorkoutSetRow(
                    set: set,
                    index: setIndex,
                    trackingType: set.isCompleted ? set.trackingType : trackingType,
                    isBarbell: isBarbell && trackingType.usesWeight,
                    previousTitle: previousSet?.resultTitle(weightUnit: settingsStore.weightUnit) ?? "—",
                    onOpenPlateCalculator: { activeSheet = .plates(set) },
                    onToggleCompleted: { toggleCompleted(set, in: workoutExercise) },
                    onDelete: { deleteSet(set, from: workoutExercise) },
                    onChanged: {
                        let saved = save()
                        if saved {
                            workout.objectWillChange.send()
                            WorkoutLiveActivityManager.shared.startOrUpdate(for: workout)
                        }
                        return saved
                    },
                    allowsSwipeToDelete: true,
                    openSwipeSetID: $openSwipeSetID,
                    isCurrent: focusedSetID == set.objectID,
                    previousWeight: previousSet?.weightValue,
                    previousRepetitions: previousSet.map { Int($0.repetitionsValue) },
                    onCompletionFlow: { advanceToNextSet(after: set) }
                )
                .environmentObject(settingsStore)
                .id(set.objectID)
                .onAppear { revealPendingSet(set.objectID) }
                .onChange(of: pendingSetScrollTarget) { _, _ in revealPendingSet(set.objectID) }
                .transition(
                    reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.96))
                    )
                )

                if isRestPillVisible,
                   restPillExerciseID == workoutExercise.objectID,
                   restPillSetID == set.objectID {
                    activeRestTimerContent
                        .padding(.vertical, 6)
                        .transition(restPillTransition)
                }
            }
            .animation(
                IronMotion.preferred(IronMotion.collapse, reduceMotion: reduceMotion),
                value: sets.count
            )
            .animation(
                IronMotion.preferred(IronMotion.collapse, reduceMotion: reduceMotion),
                value: sets.first(where: { !$0.isCompleted })?.objectID
            )

            if isRestPillVisible,
               restPillExerciseID == workoutExercise.objectID,
               !sets.contains(where: { $0.objectID == restPillSetID }) {
                activeRestTimerContent
                    .padding(.vertical, 6)
                    .transition(restPillTransition)
            }

            Button {
                addSet(to: workoutExercise)
            } label: {
                Label("Add Set", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .ironGlassButtonStyle()
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .padding(.top, 12)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        // One continuous grouped container per exercise. The previous layout
        // stacked five full-bleed rules per block, which is what made the
        // logger read as a flat spreadsheet instead of an Apple surface.
        .background(
            RoundedRectangle(cornerRadius: IronTheme.heroCornerRadius, style: .continuous)
                .fill(IronTheme.surface)
        )
        .clipShape(RoundedRectangle(cornerRadius: IronTheme.heroCornerRadius, style: .continuous))
        .id(workoutExercise.objectID)

    }

    private func workoutExerciseNotes(for workoutExercise: WorkoutExercise) -> some View {
        let exerciseNote = ExerciseNotes.note(for: workoutExercise.exerciseUuid)
        let planNote = workoutExercise.routineNote
        let hasPinnedNotes = exerciseNote != nil || planNote != nil
        // The header's 44 pt thumbnail and 10 pt gap establish the title column.
        let titleInset = IronTheme.iconButtonSize + 10
        let noteIconWidth: CGFloat = 14
        let noteIconGap: CGFloat = 6

        let spokenNotes = [
            exerciseNote.map { "Exercise: \($0)" },
            planNote.map { "Workout Plan: \($0)" },
            workoutExercise.comment.map { "This Workout: \($0)" }
        ].compactMap { $0 }.joined(separator: ". ")

        return VStack(alignment: .leading, spacing: 6) {
            if hasPinnedNotes {
                Button {
                    noteEditor = NoteEditor(exercise: workoutExercise, isRoutine: false, showsAllNotes: true)
                } label: {
                    // One target owns the minimum height; previews retain their
                    // natural text heights rather than becoming separate rows.
                    VStack(alignment: .leading, spacing: 4) {
                        if let exerciseNote {
                            pinnedWorkoutExerciseNote(title: "Exercise", systemImage: "pin", text: exerciseNote,
                                                      iconWidth: noteIconWidth)
                        }
                        if let planNote {
                            pinnedWorkoutExerciseNote(title: "Workout plan", systemImage: "list.bullet", text: planNote,
                                                      iconWidth: noteIconWidth)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight, alignment: .bottomLeading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Notes")
                .accessibilityValue(spokenNotes)
                .accessibilityHint("Opens notes")
            }
            TextField("Add notes here…", text: exerciseCommentBinding(for: workoutExercise), axis: .vertical)
                .lineLimit(1...2)
                .accessibilityLabel("Notes for this workout only")
                .font(.subheadline)
                .foregroundStyle(IronTheme.secondaryText)
                .padding(.leading, hasPinnedNotes ? noteIconWidth + noteIconGap : 0)
                .padding(.top, hasPinnedNotes ? 0 : 8)
        }
        .padding(.leading, hasPinnedNotes ? titleInset - noteIconWidth - noteIconGap : 0)
    }

    private func pinnedWorkoutExerciseNote(
        title: String, systemImage: String, text: String, iconWidth: CGFloat
    ) -> some View {
        let preview = Text("\(title): ").fontWeight(.semibold) + Text(text)

        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .frame(width: iconWidth)
                .accessibilityHidden(true)

            // The hidden clamped copy supplies the actual two-line height at
            // this width and Dynamic Type size. Only overflow selects More.
            preview
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hidden()
                .overlay(alignment: .leading) {
                    ViewThatFits(in: .vertical) {
                        preview
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            preview
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("More")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(IronTheme.accent)
                                .fixedSize()
                        }
                    }
                }
        }
        .font(.footnote)
        .foregroundStyle(IronTheme.secondaryText)
    }

    @ViewBuilder
    private func supersetLetterBadge(_ letter: String?) -> some View {
        if let letter {
            Text(letter)
                .font(.footnote.bold())
                .foregroundStyle(IronTheme.accent)
                .frame(minWidth: 22, minHeight: 22)
                .background(IronTheme.accentSoft, in: Circle())
                .accessibilityLabel("Superset exercise \(letter)")
        }
    }

    private func exerciseNameButton(_ exercise: Exercise) -> some View {
        Button {
            guard !showingArrangeExercises else { return }
            selectedExerciseDetail = exercise
        } label: {
            Text(exercise.title)
                .font(.headline)
                .foregroundStyle(IronTheme.primaryText)
                .lineLimit(usesAccessibilityHeaderLayout ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .highPriorityGesture(
            LongPressGesture(minimumDuration: 0.35)
                .exclusively(before: TapGesture())
                .onEnded { result in
                    switch result {
                    case .first: showingArrangeExercises = true
                    case .second: selectedExerciseDetail = exercise
                    }
                }
        )
        .accessibilityHint("Double tap to open. Touch and hold to arrange exercises.")
        .accessibilityAction(named: Text("Reorder Exercises")) {
            showingArrangeExercises = true
        }
    }

    private func exerciseMetadata(
        _ exercise: Exercise?, workoutExercise: WorkoutExercise, sets: [WorkoutSet]
    ) -> some View {
        let layout = usesAccessibilityHeaderLayout
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 4))
        let equipment = exercise?.equipment.map(\.equipmentTitle).joined(separator: ", ") ?? ""
        let showsRest = !sets.allSatisfy { $0.durationValue != nil }
            || sets.isEmpty || workoutExercise.restTimerDurationValue != nil
        return layout {
            if !equipment.isEmpty {
                Text(equipment + (showsRest && !usesAccessibilityHeaderLayout ? " ·" : ""))
                    .font(.subheadline)
                    .foregroundStyle(IronTheme.secondaryText)
                    .lineLimit(usesAccessibilityHeaderLayout ? 2 : 1)
            }
            if showsRest {
                exerciseRestButton(for: workoutExercise)
            }
        }
    }

    @ViewBuilder
    private func exerciseMenuItems(
        for workoutExercise: WorkoutExercise,
        sets: [WorkoutSet],
        isBarbell: Bool
    ) -> some View {
        if workoutExercise.exerciseUuid != nil {
            Button("Edit Exercise Note", systemImage: "pin") {
                noteEditor = NoteEditor(exercise: workoutExercise, isRoutine: false)
            }
        }
        if workoutExercise.routineNoteSource() != nil {
            Button("Edit Workout Plan Note", systemImage: "list.bullet") {
                noteEditor = NoteEditor(exercise: workoutExercise, isRoutine: true)
            }
        }
        Picker("Set Type", selection: Binding(
            get: { workoutExercise.setTrackingType },
            set: { _ = setTrackingType($0, for: workoutExercise) }
        )) {
            ForEach(SetTrackingType.allCases) { type in
                Text(type.title).tag(type)
            }
        }

        Button("Replace", systemImage: "arrow.triangle.2.circlepath") {
            exercisePendingReplacement = workoutExercise
            showingExerciseSelector = true
        }

        Button("Superset", systemImage: "link") {
            supersetExercise = workoutExercise
        }
        Button("Reorder Exercises", systemImage: "arrow.up.arrow.down") {
            showingArrangeExercises = true
        }

        if isBarbell,
           settingsStore.showPlateCalculator || settingsStore.showWarmUpCalculator,
           let workingSet = sets.first(where: { $0.tagValue != .warmUp }) ?? sets.first {
            Section("Calculators") {
                if settingsStore.showPlateCalculator {
                    Button("Plate Calculator", systemImage: "plusminus") {
                        activeSheet = .plates(workingSet)
                    }
                }
                if settingsStore.showWarmUpCalculator {
                    Button("Warm-up Calculator", systemImage: "flame") {
                        activeSheet = .warmups(workingSet)
                    }
                }
            }
        }

        Section {
            Button("Remove Exercise", systemImage: "trash", role: .destructive) {
                exercisePendingRemoval = workoutExercise
            }
        }
    }

    @ViewBuilder
    private func setTableHeader(trackingType: SetTrackingType) -> some View {
        if !usesAccessibilityHeaderLayout {
            HStack(spacing: InlineWorkoutSetLayout.spacing) {
                Text("SET").frame(width: InlineWorkoutSetLayout.setWidth)
                Text("PREVIOUS").frame(width: InlineWorkoutSetLayout.previousWidth, alignment: .center)
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
                    .accessibilityHidden(true)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(IronTheme.secondaryText)
            .multilineTextAlignment(.center)
            .padding(.bottom, InlineWorkoutSetLayout.spacing)
        }
    }

    private var activeRestTimerExercise: WorkoutExercise? {
        guard restTimerStore.restTimerRemainingTime != nil else { return nil }

        return workoutExercises.max { lhs, rhs in
            latestCompletedSetDate(in: lhs) < latestCompletedSetDate(in: rhs)
        } ?? workoutExercises.first
    }

    private func latestCompletedSetDate(in workoutExercise: WorkoutExercise) -> Date {
        workoutSets(for: workoutExercise)
            .compactMap(\.completedAt)
            .max() ?? .distantPast
    }

    private struct RestPillTimerSnapshot: Equatable {
        let end: Date?
        let duration: TimeInterval?
        let isPaused: Bool
    }

    private var restPillTimerSnapshot: RestPillTimerSnapshot {
        RestPillTimerSnapshot(
            end: restTimerStore.restTimerEnd,
            duration: restTimerStore.restTimerDuration,
            isPaused: restTimerStore.isPaused
        )
    }

    private var restPillTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }

    /// Presentation follows the shared timer; no timer or notification work is delayed.
    /// This task is cancelled on adjustment, pause, skip, restart, or dismissal.
    @MainActor
    private func updateRestPillPresentation() async {
        let snapshot = restPillTimerSnapshot
        guard let remaining = restTimerStore.restTimerRemainingTime, remaining > 0,
              let exercise = activeRestTimerExercise else {
            withAnimation(IronMotion.preferred(IronMotion.collapse, reduceMotion: reduceMotion)) {
                isRestPillVisible = false
                showsRunningRestRuler = false
            }
            return
        }

        if !reduceMotion, let revealDate = restPillRevealsAt {
            do {
                try await Task.sleep(for: .seconds(max(0, revealDate.timeIntervalSinceNow)))
            } catch { return }
        }
        guard !Task.isCancelled else { return }

        restRingPulses = false
        withAnimation(IronMotion.preferred(IronMotion.collapse, reduceMotion: reduceMotion)) {
            restPillExerciseID = exercise.objectID
            restPillSetID = workoutSets(for: exercise)
                .filter(\.isCompleted)
                .max { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }?
                .objectID
            isRestPillVisible = true
        }

        guard !snapshot.isPaused, let end = snapshot.end else { return }
        do {
            try await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
        } catch { return }
        guard !Task.isCancelled, restPillTimerSnapshot == snapshot else { return }

        // Pulse during removal, without holding the pill or delaying the next action.
        restEndFeedback += 1
        withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) {
            restRingPulses = true
        }
        withAnimation(IronMotion.preferred(IronMotion.collapse, reduceMotion: reduceMotion)) {
            isRestPillVisible = false
            showsRunningRestRuler = false
        }
    }

    private var activeRestTimerContent: some View {
        VStack(spacing: 10) {
            activeRestTimerStrip
                .scaleEffect(reduceMotion || !restStripHighlighted ? 1 : 1.03)
                .opacity(reduceMotion && restStripHighlighted ? 0.7 : 1)
            if showsRunningRestRuler {
                RestLengthRuler(value: Binding(
                    get: { restTimerStore.restTimerDuration ?? 90 }, set: { _ in }
                )) { duration in
                    if restTimerStore.setTotalRestLength(duration) { restLengthClampFeedback += 1 }
                    WorkoutLiveActivityManager.shared.refreshRestTimer(for: workout)
                }
                .transition(restPillTransition)
            }
        }
        .id("active-rest-strip")
        .task(id: restStripScrollRequest) {
            guard restStripScrollRequest > 0 else { return }
            withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) {
                restStripHighlighted = true
            }
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) {
                restStripHighlighted = false
            }
        }
    }

    private var activeRestTimerStrip: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let remaining = restTimerStore.restTimerRemainingTime ?? 0
            let duration = restTimerStore.restTimerDuration ?? 0
            let countdown = restTimerCountdownText(remaining)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    activeRestTimerReadout(remaining: remaining, duration: duration, countdown: countdown)
                    activeRestTimerControls
                }
                VStack(alignment: .leading, spacing: 8) {
                    activeRestTimerReadout(remaining: remaining, duration: duration, countdown: countdown)
                    activeRestTimerControls
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(
                IronTheme.metricTimeContainer,
                in: RoundedRectangle(cornerRadius: IronTheme.heroCornerRadius, style: .continuous)
            )
        }
    }

    private func activeRestTimerReadout(remaining: TimeInterval, duration: TimeInterval, countdown: String) -> some View {
        Button {
            actionFeedback += 1
            withAnimation(IronMotion.preferred(IronMotion.collapse, reduceMotion: reduceMotion)) {
                showsRunningRestRuler.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                IronRestRing(progress: duration > 0 ? remaining / duration : 0)
                    .scaleEffect(reduceMotion || !restRingPulses ? 1 : 1.12)
                    .opacity(reduceMotion && restRingPulses ? 0.5 : 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(countdown)
                        .font(.ironMetric(.title3))
                        .foregroundStyle(IronTheme.metricTime)
                        .contentTransition(reduceMotion ? .opacity : .numericText(countsDown: true))
                        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: countdown)
                    Text("Rest of \(restTimerTimeText(duration))")
                        .font(.caption2)
                        .foregroundStyle(IronTheme.secondaryText)
                }
                .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }
            .frame(minHeight: IronTheme.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(restTimerStore.isPaused ? "Rest timer paused" : "Rest timer")
        .accessibilityValue("\(countdown) remaining of \(restTimerTimeText(duration))")
        .accessibilityHint("Shows rest length")
    }

    private var activeRestTimerControls: some View {
        HStack(spacing: 0) {
            activeTimerControl(title: "−15", label: "Subtract 15 seconds") {
                adjustActiveRestTimer(by: -15)
            }
            Spacer(minLength: 4)
            activeTimerControl(
                systemImage: restTimerStore.isPaused ? "play.fill" : "pause.fill",
                label: restTimerStore.isPaused ? "Resume rest timer" : "Pause rest timer"
            ) {
                restTimerStore.isPaused ? restTimerStore.resume() : restTimerStore.pause()
                WorkoutLiveActivityManager.shared.refreshRestTimer(for: workout)
            }
            Spacer(minLength: 4)
            activeTimerControl(title: "+15", label: "Add 15 seconds") {
                adjustActiveRestTimer(by: 15)
            }
            Spacer(minLength: 4)
            activeTimerControl(systemImage: "forward.end.fill", label: "Skip rest", action: stopActiveRestTimer)
        }
        .frame(minWidth: IronTheme.iconButtonSize * 4 + 12)
    }

    private func restTimerTimeText(_ remaining: TimeInterval) -> String {
        restTimerDurationFormatter.string(from: abs(remaining.rounded(.up))) ?? "0:00"
    }

    private func restTimerCountdownText(_ remaining: TimeInterval) -> String {
        restTimerTimeText(max(remaining, 0))
    }

    private func activeTimerControl(
        title: String = "",
        systemImage: String? = nil,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            actionFeedback += 1
            action()
        } label: {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                } else {
                    Text(title)
                }
            }
            .font(.ironMetric(.caption))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(width: IronTheme.iconButtonSize, height: IronTheme.iconButtonSize)
            .background(IronTheme.field, in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(IronTheme.primaryText)
        .accessibilityLabel(label)
    }

    private func adjustActiveRestTimer(by interval: TimeInterval) {
        restTimerStore.adjust(by: interval, feedback: true)
        WorkoutLiveActivityManager.shared.refreshRestTimer(for: workout)
    }

    private func stopActiveRestTimer() {
        withAnimation(IronMotion.preferred(IronMotion.collapse, reduceMotion: reduceMotion)) {
            showsRunningRestRuler = false
        }
        restTimerStore.cancel()
        WorkoutLiveActivityManager.shared.refreshRestTimer(for: workout)
    }

    private func exerciseRestButton(for workoutExercise: WorkoutExercise) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let remaining = restTimerStore.restTimerRemainingTime ?? 0
            let running = activeRestTimerExercise?.objectID == workoutExercise.objectID && remaining > 0
            let time = running ? restTimerCountdownText(remaining) : restTimerTitle(for: workoutExercise)
            Button {
                if running {
                    actionFeedback += 1
                    restStripScrollRequest += 1
                } else {
                    toggleDefaultRestRuler(for: workoutExercise)
                }
            } label: {
                Text("Rest \(time)")
                    .font(.ironMetric(.subheadline, weight: .semibold))
                    .foregroundStyle(running ? restTimerTint : IronTheme.metricTime)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: true, vertical: false)
                    .contentTransition(reduceMotion ? .opacity : .numericText(countsDown: true))
                    .frame(minHeight: 24)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: time)
            .accessibilityLabel("Exercise rest length")
            .accessibilityValue(time)
            .accessibilityHint(running ? "Shows the running rest timer" : "Shows rest length")
            .contextMenu {
                Button("Use Workout Default") {
                    if setRestTimer(nil, for: workoutExercise) { actionFeedback += 1 }
                }
            }
        }
    }

    private func toggleDefaultRestRuler(for workoutExercise: WorkoutExercise) {
        actionFeedback += 1
        withAnimation(IronMotion.preferred(IronMotion.collapse, reduceMotion: reduceMotion)) {
            restTimerEditorExercise = restTimerEditorExercise?.objectID == workoutExercise.objectID
                ? nil : workoutExercise
        }
    }

    private var finishWorkoutSheet: some View {
        NavigationStack {
            Form {
                finishHeaderSection
                finishSummarySection
                finishEffortSection
                finishSessionSection
                finishRecordsSection
                finishSyncSection
                finishTitleSection
                finishTimingSection
                finishNotesSection
                finishMediaSection
                finishExerciseSummarySection
                finishDiscardSection
            }
            .contentMargins(.horizontal, loggerHorizontalInset, for: .scrollContent)
            .safeAreaInset(edge: .bottom) {
                finishSaveButton
            }
            .navigationTitle("Workout Complete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingFinishEditor = false }
                        .disabled(isFinishingWorkout)
                }
            }
        }
        .onAppear(perform: prepareFinishEditor)
        .alert("Workout Not Saved", isPresented: Binding(
            get: { persistenceError != nil && showingFinishEditor },
            set: { if !$0 { persistenceError = nil } }
        )) {
            Button("OK", role: .cancel) { persistenceError = nil }
        } message: {
            Text(persistenceError ?? "Please try again.")
        }
        .alert("Discard this workout?", isPresented: $showingFinishDiscardConfirmation) {
            Button("Discard Workout", role: .destructive) {
                showingFinishDiscardConfirmation = false
                cancelWorkout()
            }
            Button("Cancel", role: .cancel) { showingFinishDiscardConfirmation = false }
        } message: {
            Text("This workout and its logged sets will be permanently deleted.")
        }
        .onChange(of: finishMediaItem) { _, item in
            guard let item = item else { return }
            Task { await importFinishMedia(item) }
        }
        .sheet(isPresented: $showingVisibilityInfo) {
            finishVisibilityInfoSheet
        }
        .sheet(isPresented: $showingFinishStartDateEditor) {
            IronDateTimePickerSheet(
                title: "Workout started",
                subtitle: "Duration stays the same; Light adjusts the finish time automatically.",
                initialDate: finishStartDate,
                range: Date.distantPast...Date()
            ) { newDate in
                finishStartDate = newDate
            }
        }
    }

    private var finishSaveButton: some View {
        Button(action: finishWorkout) {
            Text(isFinishingWorkout ? "Saving…" : "Save Workout")
                .font(.headline)
                .foregroundStyle(IronTheme.onAccent)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(IronTheme.accent, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isLoadingFinishMedia || isFinishingWorkout)
        .opacity(isLoadingFinishMedia || isFinishingWorkout ? 0.5 : 1)
        .padding(.horizontal, loggerHorizontalInset)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var finishHeaderSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "dumbbell.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(IronTheme.onAccent)
                    .frame(width: 44, height: 44)
                    .background(IronTheme.accent, in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(finishTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? suggestedWorkoutTitle : finishTitle)
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(finishDateRange)
                        .font(.subheadline)
                        .foregroundStyle(IronTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var finishDateRange: String {
        if Calendar.current.isDate(finishStartDate, inSameDayAs: finishEndDate) {
            return "\(finishStartDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(finishStartDate.formatted(date: .omitted, time: .shortened))–\(finishEndDate.formatted(date: .omitted, time: .shortened))"
        }
        return "\(finishStartDate.formatted(date: .abbreviated, time: .shortened))–\(finishEndDate.formatted(date: .abbreviated, time: .shortened))"
    }

    private var finishSummarySection: some View {
        Section {
            finishMetricsGrid
                .padding(.vertical, 6)
        } header: {
            Text("Session Summary")
        } footer: {
            Text("Review the session, then tap Save to add it to your history.")
        }
    }

    private var finishMetricsGrid: some View {
        // Two generous columns on a phone; accessibility sizes stack the metrics.
        // Values stay on screen without a horizontal scroll or shrinking numerals.
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: usesAccessibilityHeaderLayout ? 240 : 140), alignment: .leading)],
            alignment: .leading,
            spacing: 16
        ) {
            finishMetric("Duration", value: IronDurationFormat.title(finishDuration), color: IronTheme.metricTime, index: 0)
            finishMetric(workoutWorkLabel, value: workoutVolumeNumber, unit: workoutWorkUnit, color: workoutWorkTint, index: 1)
            finishMetric("Sets", value: "\(finishRecap.setCount)", color: IronTheme.metricSets, index: 2)
            finishMetric("Exercises", value: "\(finishRecap.exerciseCount)", color: IronTheme.accent, index: 3)
            finishMetric("Avg RPE", value: finishRecap.averageRPE, color: IronTheme.metricEffort, index: 4)
            finishMetric("Records", value: "\(finishRecap.records.count)", color: IronTheme.metricRecord, index: 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func finishMetric(_ title: String, value: String, unit: String? = nil, color: Color, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(IronTheme.primaryText)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    finishMetricValue(value, color: color)
                    if let unit { Text(unit).font(.subheadline).foregroundStyle(IronTheme.secondaryText) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    finishMetricValue(value, color: color)
                    if let unit { Text(unit).font(.subheadline).foregroundStyle(IronTheme.secondaryText) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value == "–" ? "No rated sets" : "\(value)\(unit.map { " \($0)" } ?? "")")
        .ironStaggeredEntrance(index: index)
    }

    private func finishMetricValue(_ value: String, color: Color) -> some View {
        Text(value)
            .font(.ironMetric(.title2))
            .foregroundStyle(color)
            .contentTransition(reduceMotion ? .opacity : .numericText())
            .fixedSize(horizontal: false, vertical: true)
            .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: value)
    }

    private var finishSessionSection: some View {
        Section {
            if finishRecap.setCount == 0 {
                Text("No completed sets yet")
                    .foregroundStyle(IronTheme.secondaryText)
            } else {
                IronSessionStrip(
                    groups: finishRecap.groups,
                    accessibilityLabel: finishRecap.accessibilitySummary,
                    sessionStart: finishStartDate,
                    volumeUnit: settingsStore.weightUnit.unit.symbol
                )
                    .padding(.vertical, 6)
            }
        } header: {
            Text("Session")
        } footer: {
            Text("Volume bars compare the sets within each exercise. The thin bar shows when the exercise ran. Rest is the time before a set, counting 40 seconds of work when a set has no recorded duration.")
        }
    }

    @ViewBuilder
    private var finishRecordsSection: some View {
        if !finishRecap.records.isEmpty {
            Section("Personal Records") {
                ForEach(finishRecap.records) { record in
                    FinishWorkoutRecordRow(record: record)
                }
            }
        }
    }

    private var finishTitleSection: some View {
        Section {
            TextField(suggestedWorkoutTitle, text: $finishTitle)
                .textInputAutocapitalization(.words)
        } header: {
            Text("Title")
        } footer: {
            Text("Leave blank to keep \(suggestedWorkoutTitle).")
        }
    }

    private var suggestedWorkoutTitle: String {
        workout.generatedTitle(in: exerciseStore.exercises) ?? "Workout"
    }

    private var finishEffortSection: some View {
        Section {
            FinishWorkoutEffortControl(rating: sessionEffortSelection)
        } footer: {
            Text("Rate your overall session from 1 (easy) to 10 (all out), or leave it unrated.")
        }
    }

    /// Zero represents an unrated session; saving maps it to the model's nil value.
    private var sessionEffortSelection: Binding<Int> {
        Binding(
            get: { min(max(Int(sessionEffort.rounded()), 0), 10) },
            set: { sessionEffort = Double(min(max($0, 0), 10)) }
        )
    }

    private var finishNotesSection: some View {
        Section {
            TextField(
                "What went well? Add context for your future self…",
                text: workoutComment,
                axis: .vertical
            )
            .lineLimit(4...10)
        } header: {
            Text("Notes")
        }
    }

    private var finishMediaSection: some View {
        Section {
            if finishMediaURL != nil {
                finishMediaPreview
            }

            PhotosPicker(
                selection: $finishMediaItem,
                matching: .any(of: [.images, .videos]),
                photoLibrary: .shared()
            ) {
                Label(
                    finishMediaURL == nil ? "Add Photo or Video" : "Replace Media",
                    systemImage: finishMediaURL == nil ? "plus" : "arrow.triangle.2.circlepath"
                )
            }
            .disabled(isLoadingFinishMedia)

            if isLoadingFinishMedia {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Saving media…")
                        .foregroundStyle(.secondary)
                }
            }

            if let finishMediaError = finishMediaError {
                Text(finishMediaError)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Media")
        } footer: {
            Text("One photo or video per workout. It stays on this device.")
        }
    }

    private var finishMediaPreview: some View {
        HStack(spacing: 12) {
            Group {
                if finishMediaKind == .image,
                   let url = finishMediaURL,
                   let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: finishMediaKind == .video ? "video.fill" : "photo.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.tertiarySystemFill))
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(finishMediaKind == .video ? "Video attached" : "Photo attached")

            Spacer()

            Button("Remove", role: .destructive, action: removeFinishMedia)
                .buttonStyle(.borderless)
        }
    }

    private var finishTimingSection: some View {
        Section {
            Button {
                showingFinishStartDateEditor = true
            } label: {
                LabeledContent("Started", value: finishStartDate.formatted(date: .abbreviated, time: .shortened))
            }
        } header: {
            Text("Timing")
        } footer: {
            Text("Duration stays \(workoutDurationFormatter.string(from: finishDuration) ?? "0:00"); the finish time becomes \(finishEndDate.formatted(date: .omitted, time: .shortened)).")
        }
    }

    private var finishSyncSection: some View {
        Section {
            Toggle(isOn: $syncWithHealth) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sync with Apple Health")
                    Text(syncWithHealth ? "Exports when you save" : "Export off for this session")
                        .font(.caption)
                        .foregroundStyle(IronTheme.secondaryText)
                }
            }

            Toggle("Update Linked Workout", isOn: $updateLinkedRoutine)
                .disabled(workout.workoutRoutine == nil)

            Button {
                showingVisibilityInfo = true
            } label: {
                LabeledContent("Visibility", value: "Private")
            }
            .accessibilityHint("Light workouts are private. Tap to learn why.")
        } header: {
            Text("Saving")
        } footer: {
            Text(workout.workoutRoutine == nil
                 ? "This session was not started from a saved workout."
                 : "Completed weights and reps are written back to \(workout.workoutRoutine?.displayTitle ?? "the linked workout").")
        }
    }

    private var finishExerciseSummarySection: some View {
        Section("Exercises") {
            ForEach(workoutExercises) { workoutExercise in
                let exercise = workoutExercise.exercise(in: exerciseStore.exercises)
                HStack(spacing: 12) {
                    if let exercise = exercise {
                        ExerciseDiagramThumbnail(exercise: exercise, size: 38)
                    } else {
                        Circle()
                            .fill(Color(.tertiarySystemFill))
                            .frame(width: 38, height: 38)
                            .overlay(Image(systemName: "dumbbell.fill").foregroundStyle(.secondary))
                    }

                    Text(exercise?.title ?? "Unknown exercise")
                        .font(.headline)
                        .lineLimit(usesAccessibilityHeaderLayout ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("\(workoutExercise.numberOfCompletedSets ?? 0)")
                        .font(.ironMetric(.body))
                        .foregroundStyle(IronTheme.metricSets)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(exercise?.title ?? "Unknown exercise"), \(workoutExercise.numberOfCompletedSets ?? 0) completed sets")
            }
        }
    }

    private var finishDiscardSection: some View {
        Section {
            Button("Discard Workout", role: .destructive) {
                showingFinishDiscardConfirmation = true
            }
            .accessibilityHint("Permanently deletes this workout and its logged sets.")
        }
    }

    private var finishEndDate: Date {
        finishStartDate.addingTimeInterval(max(finishDuration, 0))
    }

    private var finishVisibilityInfoSheet: some View {
        IronUtilitySheet(
            title: "Private by design",
            subtitle: "Visibility for every finished workout",
            systemImage: "lock.fill",
            onClose: { showingVisibilityInfo = false }
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Light has no social feed or public profiles. Finished workouts are always saved as Private · Only you, so your training history stays on this device and in your personal backups.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Only you can see it")
                            .font(.subheadline.weight(.semibold))
                        Text("There is nothing else to publish or configure.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .foregroundStyle(IronTheme.success)
                }

                Spacer(minLength: 0)
            }
            .padding(IronTheme.horizontalPadding)
        }
        .presentationDetents([.height(360), .medium])
        .presentationDragIndicator(.visible)    }

    private let workoutDurationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .positional
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter
    }()

    private var workoutDurationTitle: String {
        let duration = max(0, workout.safeDuration)
        if duration < 60 { return String(format: "0:%02d", Int(duration)) }
        return workoutDurationFormatter.string(from: duration) ?? "0:00"
    }

    private var completedTrackingSets: [WorkoutSet] {
        workoutExercises.flatMap { workoutSets(for: $0) }.filter(\.isCompleted)
    }
    private var workoutWorkLabel: String {
        if workout.trackedCompletedVolume > 0 || completedTrackingSets.isEmpty { return "Volume" }
        if completedTrackingSets.contains(where: { $0.trackingType.usesDistance }) { return "Distance" }
        if completedTrackingSets.contains(where: { $0.trackingType.usesDuration }) { return "Set Time" }
        return "Reps"
    }
    private var workoutWorkUnit: String? {
        switch workoutWorkLabel {
        case "Volume": return settingsStore.weightUnit.unit.symbol
        case "Distance": return WorkoutSet.distanceUnit(settingsStore.weightUnit)
        case "Reps": return "reps"
        default: return nil
        }
    }
    private var workoutWorkTint: Color {
        workoutWorkLabel == "Volume" ? IronTheme.metricVolume : (workoutWorkLabel == "Reps" ? IronTheme.metricSets : IronTheme.metricTime)
    }
    private var workoutVolumeNumber: String {
        if workoutWorkLabel == "Distance" {
            let meters = completedTrackingSets.compactMap(\.distanceValue).reduce(0, +)
            return WorkoutSet.distanceTitle(meters, weightUnit: settingsStore.weightUnit).components(separatedBy: " ").dropLast().joined(separator: " ")
        }
        if workoutWorkLabel == "Set Time" {
            return SetTrackingType.durationText(completedTrackingSets.compactMap(\.durationValue).reduce(0, +))
        }
        if workoutWorkLabel == "Reps" { return String(completedTrackingSets.reduce(0) { $0 + Int($1.repetitionsValue) }) }

        let displayWeight = WeightUnit.convert(
            weight: workout.trackedCompletedVolume,
            from: .metric,
            to: settingsStore.weightUnit
        )
        return settingsStore.weightUnit.displayNumberFormatter.string(from: NSNumber(value: displayWeight)) ?? "0"
    }

    private var workoutVolumeTitle: String {
        [workoutVolumeNumber, workoutWorkUnit].compactMap { $0 }.joined(separator: " ")
    }

    private func workoutSets(for workoutExercise: WorkoutExercise) -> [WorkoutSet] {
        workoutExercise.workoutSets?.array as? [WorkoutSet] ?? []
    }

    private func exerciseCommentBinding(for workoutExercise: WorkoutExercise) -> Binding<String> {
        Binding(
            get: { workoutExercise.comment ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                workoutExercise.comment = trimmed.isEmpty ? nil : value
                save()
            }
        )
    }

    @discardableResult
    private func addExercises(_ selection: [Exercise]) -> Bool {
        var resolvedTypes: [(UUID, SetTrackingType)] = []
        let saved = persistMutation {
            for exercise in selection {
                let workoutExercise = WorkoutExercise.create(context: managedObjectContext)
                workout.addToWorkoutExercises(workoutExercise)
                workoutExercise.exerciseUuid = exercise.uuid
                let defaults = createDefaultWorkoutSets(for: workoutExercise, exercise: exercise)
                workoutExercise.addToWorkoutSets(defaults.sets)
                resolvedTypes.append((exercise.uuid, defaults.type))
            }
        }
        if saved {
            for (exerciseID, type) in resolvedTypes {
                SetTrackingPreferences.setOverride(type, for: exerciseID)
            }
            WorkoutLiveActivityManager.shared.startOrUpdate(for: workout)
        }
        return saved
    }

    @discardableResult
    private func applyExerciseSelection(_ selection: [Exercise]) -> Bool {
        let saved: Bool
        if let target = exercisePendingReplacement, let replacement = selection.first {
            saved = persistMutation {
                target.exerciseUuid = replacement.uuid
            }
            if saved {
                exercisePendingReplacement = nil
                WorkoutLiveActivityManager.shared.startOrUpdate(for: workout)
            }
        } else {
            saved = addExercises(selection)
        }
        if saved {
            showingExerciseSelector = false
        }
        return saved
    }

    @discardableResult
    private func configureSuperset(for source: WorkoutExercise, partnerIDs: Set<NSManagedObjectID>) -> Bool {
        let saved = persistMutation {
            try WorkoutOrganization.setSuperset(in: workout, source: source, partnerIDs: partnerIDs)
        }
        if saved {
            workout.objectWillChange.send()
            WorkoutLiveActivityManager.shared.startOrUpdate(for: workout)
            actionFeedback += 1
        }
        return saved
    }

    @discardableResult
    private func removeFromSuperset(_ source: WorkoutExercise) -> Bool {
        guard workout.isCurrentWorkout, !source.isDeleted,
              workoutExercises.contains(where: { $0.objectID == source.objectID }) else {
            persistenceError = WorkoutOrganization.Failure.changedWorkout.localizedDescription
            return false
        }
        let previousID = source.supersetUuid
        let saved = persistMutation {
            source.supersetUuid = nil

            if let previousID {
                let remaining = workoutExercises.filter { $0.supersetUuid == previousID }
                if remaining.count < 2 {
                    remaining.forEach { $0.supersetUuid = nil }
                }
            }
        }
        if saved {
            WorkoutLiveActivityManager.shared.startOrUpdate(for: workout)
            actionFeedback += 1
        }
        return saved
    }

    private func createDefaultWorkoutSets(for workoutExercise: WorkoutExercise, exercise: Exercise) -> (sets: NSOrderedSet, type: SetTrackingType) {
        let history = settingsStore.prefillPreviousValues
            ? (try? managedObjectContext.fetch(workoutExercise.historyFetchRequest)) ?? []
            : []
        let recentSets = history.first?.workoutSets?.array.compactMap { $0 as? WorkoutSet } ?? []
        let numberOfSets = max(recentSets.count, 3)
        let type = SetTrackingPreferences.override(for: exercise.uuid)
            ?? recentSets.first.map(\.trackingType)
            ?? SetTrackingType.defaultType(name: exercise.title, equipment: exercise.equipment, category: exercise.muscleGroup)

        let sets: [WorkoutSet] = (0..<numberOfSets).map { index in
            let set = WorkoutSet.create(context: managedObjectContext)
            let previous = recentSets.indices.contains(index) ? recentSets[index] : recentSets.last
            if let previous = previous {
                set.durationValue = previous.durationValue
                set.distanceValue = previous.distanceValue
                set.weightValue = previous.weightValue
                set.repetitionsValue = previous.repetitionsValue
                set.tagValue = previous.tagValue
            } else {
                set.repetitionsValue = 5
                if exercise.type == .barbell {
                    set.weightValue = WeightUnit.convert(
                        weight: settingsStore.weightUnit.barbellWeight,
                        from: settingsStore.weightUnit,
                        to: .metric
                    )
                }
            }
            set.prepare(for: type)
            set.isCompleted = false
            return set
        }
        return (NSOrderedSet(array: sets), type)
    }

    @discardableResult
    private func addSet(to workoutExercise: WorkoutExercise) -> Bool {
        var saved = false
        withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) {
            saved = persistMutation {
                let existingSets = workoutSets(for: workoutExercise)
                let set = WorkoutSet.create(context: managedObjectContext)
                set.workoutExercise = workoutExercise

                if let source = existingSets.last ?? latestHistorySet(for: workoutExercise, at: existingSets.count) {
                    set.durationValue = source.durationValue
                    set.distanceValue = source.distanceValue
                    set.weightValue = source.weightValue
                    set.repetitionsValue = source.repetitionsValue
                    set.tagValue = source.tagValue
                } else {
                    set.repetitionsValue = 5
                }
                set.prepare(for: workoutExercise.setTrackingType)
                set.isCompleted = false
            }
        }
        if saved {
            actionFeedback += 1
            workout.objectWillChange.send()
            WorkoutLiveActivityManager.shared.startOrUpdate(for: workout)
        }
        return saved
    }

    @discardableResult
    private func deleteSet(_ set: WorkoutSet, from workoutExercise: WorkoutExercise) -> Bool {
        var saved = false
        withAnimation(IronMotion.preferred(IronMotion.collapse, reduceMotion: reduceMotion)) {
            saved = persistMutation {
                workoutExercise.removeFromWorkoutSets(set)
                managedObjectContext.delete(set)
            }
        }
        if saved {
            deleteFeedback += 1
            workout.objectWillChange.send()
            WorkoutLiveActivityManager.shared.startOrUpdate(for: workout)
        }
        return saved
    }

    @discardableResult
    private func deleteWorkoutExercise(_ workoutExercise: WorkoutExercise) -> Bool {
        let saved = persistMutation {
            workout.removeFromWorkoutExercises(workoutExercise)
            managedObjectContext.delete(workoutExercise)
        }
        if saved {
            deleteFeedback += 1
            WorkoutLiveActivityManager.shared.startOrUpdate(for: workout)
        }
        return saved
    }

    @discardableResult
    private func saveExerciseOrder(_ orderedIDs: [NSManagedObjectID]) -> Bool {
        let saved = persistMutation {
            try WorkoutOrganization.reorder(orderedIDs, in: workout)
        }
        if saved {
            workout.objectWillChange.send()
            WorkoutLiveActivityManager.shared.startOrUpdate(for: workout)
            actionFeedback += 1
        }
        return saved
    }

    private func toggleCompleted(_ set: WorkoutSet, in workoutExercise: WorkoutExercise) {
        let justCompleted = !set.isCompleted
        do {
            try managedObjectContext.persistMutation(save: { try managedObjectContext.save() }) {
                set.isCompleted = justCompleted
                set.completedAt = justCompleted ? Date() : nil
                if justCompleted {
                    if workoutExercise.setTrackingType.usesDuration, set.durationValue == nil {
                        set.durationValue = 60
                    }
                    set.weightValue = max(set.weightValue, 0)
                    set.repetitionsValue = max(set.repetitionsValue, 0)
                    workout.start = workout.start ?? Date()
                }
            }
        } catch {
            persistenceError = "The set was not changed. \(error.localizedDescription)"
            return
        }

        // Remember the resolved catalog default after the first successful log,
        // so aggregate consumers without a catalog also know assistance semantics.
        if justCompleted, let exerciseID = workoutExercise.exerciseUuid,
           SetTrackingPreferences.override(for: exerciseID) == nil {
            SetTrackingPreferences.setOverride(workoutExercise.setTrackingType, for: exerciseID)
        }
        // Summary metrics and the next current row derive from child-set values.
        workout.objectWillChange.send()

        if justCompleted {
            let isRecord = settingsStore.personalRecordAlerts && set.isPersonalRecord == true

            // The row emits success only after a local completion succeeds.
            if settingsStore.workoutSounds {
                IronSoundPlayer.shared.play(isRecord ? .setRecord : .setComplete)
            }
            if isRecord {
                announcePersonalRecord(for: set, in: workoutExercise)
            }

            if settingsStore.autoStartRestTimer {
                restPillRevealsAt = Date().addingTimeInterval(0.38)
                restTimerStore.start(duration: restTimerDuration(for: workoutExercise))
            }
        } else {
            restTimerStore.cancel()
        }

        if justCompleted {
            WorkoutLiveActivityManager.shared.setCompleted(
                set,
                in: workoutExercise,
                workout: workout
            )
        } else {
            WorkoutLiveActivityManager.shared.startOrUpdate(
                for: workout,
                preservingTransition: false
            )
        }
    }

    private func announcePersonalRecord(for set: WorkoutSet, in workoutExercise: WorkoutExercise) {
        let title = workoutExercise.exercise(in: exerciseStore.exercises)?.title ?? "Personal Record"
        let detail = set.resultTitle(weightUnit: settingsStore.weightUnit)
        withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) {
            personalRecordBanner = PersonalRecordBanner(exerciseTitle: title, detail: detail)
        }
    }

    /// Use the editor's schedule for ordinary exercises and superset rounds.
    /// When RPE is requested, the row calls this after its picker is dismissed.
    private func advanceToNextSet(after completed: WorkoutSet) {
        guard let next = WorkoutSetFocus.next(in: workout) else { return }
        // The finished set stays at the top, with the rest timer and the next set under it.
        // Going back to an earlier set has to scroll up to that set instead.
        let keepsCompleted = completedSet(completed, precedes: next)
        let exerciseID = keepsCompleted ? completed.workoutExercise?.objectID ?? next.exerciseID : next.exerciseID
        pendingSetScrollTarget = keepsCompleted ? completed.objectID : next.setID
        // Materialize a distant lazy group first. Its row then supplies the
        // precise anchor, including sets below a long exercise or superset.
        scrollTarget = exerciseCardGroups.first {
            $0.exercises.contains { $0.objectID == exerciseID }
        }?.id ?? exerciseID
    }

    private func completedSet(_ completed: WorkoutSet, precedes next: WorkoutSetFocus) -> Bool {
        guard let exercise = completed.workoutExercise,
              let exercises = workout.workoutExercises?.array as? [WorkoutExercise],
              let completedExercise = exercises.firstIndex(where: { $0.objectID == exercise.objectID }),
              let nextExercise = exercises.firstIndex(where: { $0.objectID == next.exerciseID }) else { return false }
        if completedExercise != nextExercise { return completedExercise < nextExercise }
        let sets = workoutSets(for: exercise)
        guard let completedIndex = sets.firstIndex(where: { $0.objectID == completed.objectID }),
              let nextIndex = sets.firstIndex(where: { $0.objectID == next.setID }) else { return false }
        return completedIndex < nextIndex
    }

    private func revealPendingSet(_ id: NSManagedObjectID) {
        guard pendingSetScrollTarget == id else { return }
        pendingSetScrollTarget = nil
        scrollTarget = id
    }

    @discardableResult
    private func setRestTimer(_ duration: TimeInterval?, for workoutExercise: WorkoutExercise) -> Bool {
        let saved = persistMutation {
            workoutExercise.restTimerDurationValue = duration
        }
        if saved { workout.objectWillChange.send() }
        return saved
    }

    @discardableResult
    private func setTrackingType(_ type: SetTrackingType, for workoutExercise: WorkoutExercise) -> Bool {
        guard type != workoutExercise.setTrackingType, let exerciseID = workoutExercise.exerciseUuid else { return false }
        let saved = persistMutation {
            for set in workoutSets(for: workoutExercise) where !set.isCompleted {
                set.prepare(for: type)
            }
        }
        if saved {
            SetTrackingPreferences.setOverride(type, for: exerciseID)
            actionFeedback += 1
            workout.objectWillChange.send()
            WatchConnectionManager.shared.syncCurrentWorkoutSnapshot()
            WorkoutLiveActivityManager.shared.startOrUpdate(for: workout)
        }
        return saved
    }

    private func restTimerDuration(for workoutExercise: WorkoutExercise) -> TimeInterval {
        if let duration = workoutExercise.restTimerDurationValue { return duration }
        return workoutDefaultRestTimerDuration(for: workoutExercise)
    }

    private func workoutDefaultRestTimerDuration(for workoutExercise: WorkoutExercise) -> TimeInterval {
        switch workoutExercise.exercise(in: exerciseStore.exercises)?.type {
        case .barbell: return settingsStore.defaultRestTimeBarbellBased
        case .dumbbell: return settingsStore.defaultRestTimeDumbbellBased
        default: return settingsStore.defaultRestTime
        }
    }

    private func restTimerTitle(for workoutExercise: WorkoutExercise) -> String {
        let title = restTimerDurationFormatter.string(from: restTimerDuration(for: workoutExercise)) ?? "0:00"
        // "03:00" reads as a clock; rest lengths read better as "3:00".
        return title.count == 5 && title.hasPrefix("0") ? String(title.dropFirst()) : title
    }

    private func latestHistorySet(for workoutExercise: WorkoutExercise, at index: Int) -> WorkoutSet? {
        guard let history = try? managedObjectContext.fetch(workoutExercise.historyFetchRequest),
              let previousExercise = history.first,
              let previousSets = previousExercise.workoutSets?.array.compactMap({ $0 as? WorkoutSet }),
              !previousSets.isEmpty else { return nil }
        return previousSets.indices.contains(index) ? previousSets[index] : previousSets.last
    }

    private func displayWeight(for set: WorkoutSet) -> Double {
        WeightUnit.convert(weight: set.weightValue, from: .metric, to: settingsStore.weightUnit)
    }

    @discardableResult
    private func addWarmupSets(_ recommendations: [WarmupRecommendation], before workingSet: WorkoutSet) -> Bool {
        guard let workoutExercise = workingSet.workoutExercise,
              let index = workoutExercise.workoutSets?.index(of: workingSet),
              index != NSNotFound else { return false }

        let saved = persistMutation {
            var insertionIndex = index
            for recommendation in recommendations {
                let set = WorkoutSet.create(context: managedObjectContext)
                set.tagValue = .warmUp
                set.weightValue = WeightUnit.convert(
                    weight: recommendation.weight,
                    from: settingsStore.weightUnit,
                    to: .metric
                )
                set.repetitionsValue = Int16(recommendation.repetitions)
                set.isCompleted = false
                workoutExercise.insertIntoWorkoutSets(set, at: insertionIndex)
                insertionIndex += 1
            }
        }
        if saved {
            WorkoutLiveActivityManager.shared.startOrUpdate(for: workout)
            activeSheet = nil
        }
        return saved
    }

    private func prepareFinishEditor() {
        if let named = workout.title ?? workout.workoutPlanAndRoutineTitle(),
           !named.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finishTitle = named
        } else {
            finishTitle = workout.generatedTitle(in: exerciseStore.exercises) ?? ""
        }
        finishStartDate = workout.safeStart
        finishDuration = max(workout.safeDuration, 0)
        sessionEffort = workout.sessionEffortValue ?? 0
        finishRecap = FinishWorkoutRecap(workout: workout, exercises: exerciseStore.exercises, weightUnit: settingsStore.weightUnit)
        syncWithHealth = UserDefaults.standard.syncFinishedWorkoutsWithHealth
        updateLinkedRoutine = false
        finishMediaError = nil
        isFinishingWorkout = false

        if let workoutUUID = workout.uuid,
           let mediaURL = FinishWorkoutMediaStore.existingURL(for: workoutUUID) {
            finishMediaURL = mediaURL
            finishMediaKind = FinishWorkoutMediaKind(url: mediaURL)
        } else {
            finishMediaURL = nil
            finishMediaKind = .image
        }
    }

    private func importFinishMedia(_ item: PhotosPickerItem) async {
        let workoutUUID = workout.uuid
        let contentType = item.supportedContentTypes.first
        let mediaKind: FinishWorkoutMediaKind = contentType?.conforms(to: .movie) == true ? .video : .image
        let fileExtension = contentType?.preferredFilenameExtension ?? (mediaKind == .video ? "mov" : "jpg")

        await MainActor.run {
            isLoadingFinishMedia = true
            finishMediaError = nil
        }

        do {
            guard let workoutUUID = workoutUUID else {
                throw FinishWorkoutMediaError.missingWorkoutIdentifier
            }
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw FinishWorkoutMediaError.unreadableMedia
            }
            let mediaURL = try FinishWorkoutMediaStore.save(
                data: data,
                for: workoutUUID,
                fileExtension: fileExtension
            )

            await MainActor.run {
                finishMediaURL = mediaURL
                finishMediaKind = mediaKind
                finishMediaItem = nil
                isLoadingFinishMedia = false
            }
        } catch {
            await MainActor.run {
                finishMediaItem = nil
                isLoadingFinishMedia = false
                finishMediaError = "Could not save that media. Try another photo or video."
            }
        }
    }

    private func removeFinishMedia() {
        if let workoutUUID = workout.uuid {
            FinishWorkoutMediaStore.remove(for: workoutUUID)
        }
        finishMediaItem = nil
        finishMediaURL = nil
        finishMediaKind = .image
        finishMediaError = nil
    }

    private func updateLinkedRoutineFromCompletedSets() -> [(UUID, Double?)] {
        guard let routine = workout.workoutRoutine else { return [] }
        var distanceChanges: [(UUID, Double?)] = []
        let routineExercises = routine.workoutRoutineExercises?.array as? [WorkoutRoutineExercise] ?? []

        for workoutExercise in workoutExercises {
            guard let exerciseUUID = workoutExercise.exerciseUuid,
                  let routineExercise = routineExercises.first(where: { $0.exerciseUuid == exerciseUUID }) else {
                continue
            }

            let completedSets = workoutSets(for: workoutExercise).filter { $0.isCompleted }
            guard !completedSets.isEmpty else { continue }

            var routineSets = routineExercise.workoutRoutineSets?.array as? [WorkoutRoutineSet] ?? []
            for (index, completedSet) in completedSets.enumerated() {
                let routineSet: WorkoutRoutineSet
                if routineSets.indices.contains(index) {
                    routineSet = routineSets[index]
                } else {
                    routineSet = WorkoutRoutineSet.create(context: managedObjectContext)
                    routineSet.workoutRoutineExercise = routineExercise
                    routineSets.append(routineSet)
                }

                let type = completedSet.trackingType
                routineSet.weightValue = type.usesWeight ? completedSet.weightValue : nil
                routineSet.minRepetitionsValue = type.usesReps ? completedSet.repetitionsValue : nil
                routineSet.maxRepetitionsValue = type.usesReps ? completedSet.repetitionsValue : nil
                routineSet.durationValue = type.usesDuration ? completedSet.durationValue : nil
                if let setID = routineSet.uuid {
                    distanceChanges.append((setID, type.usesDistance ? completedSet.distanceValue : nil))
                }
                routineSet.tagValue = completedSet.tagValue
            }
            routineExercise.workoutRoutineSets = NSOrderedSet(array: routineSets)
        }
        return distanceChanges
    }

    private func finishWorkout() {
        guard !isFinishingWorkout, !isLoadingFinishMedia else { return }
        isFinishingWorkout = true
        defer { isFinishingWorkout = false }

        let trimmedTitle = finishTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedComment = workout.comment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var routineDistanceChanges: [(UUID, Double?)] = []
        do {
            try workout.finish(syncToHealth: syncWithHealth) {
                workout.title = trimmedTitle.isEmpty
                    ? workout.generatedTitle(in: exerciseStore.exercises)
                    : trimmedTitle
                workout.comment = trimmedComment.isEmpty ? nil : trimmedComment
                workout.start = finishStartDate
                workout.end = finishEndDate
                workout.sessionEffortValue = sessionEffort > 0 ? sessionEffort : nil
                if updateLinkedRoutine { routineDistanceChanges = updateLinkedRoutineFromCompletedSets() }
            }
        } catch {
            persistenceError = "Your workout is still active. Light could not save it: \(error.localizedDescription)"
            return
        }
        for (setID, distance) in routineDistanceChanges {
            SetTrackingPreferences.setRoutineDistance(distance, for: setID)
        }
        UserDefaults.standard.syncFinishedWorkoutsWithHealth = syncWithHealth
        showingFinishEditor = false

        let feedback = UINotificationFeedbackGenerator()
        feedback.prepare()
        feedback.notificationOccurred(.success)
        IronSoundPlayer.shared.play(.workoutFinish)

        UserDefaults.standard.finishedWorkoutsCount += 1
        if UserDefaults.standard.finishedWorkoutsCount == 6,
           let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) {
            SKStoreReviewController.requestReview(in: windowScene)
        }
    }

    private func cancelWorkout() {
        let workoutUUID = workout.uuid
        do {
            try workout.cancel()
        } catch {
            persistenceError = "Your workout has not been discarded. \(error.localizedDescription)"
            return
        }
        activeSheet = nil
        showingFinishEditor = false
        if let workoutUUID {
            FinishWorkoutMediaStore.remove(for: workoutUUID)
        }
        let feedback = UINotificationFeedbackGenerator()
        feedback.prepare()
        feedback.notificationOccurred(.warning)
    }

    @discardableResult
    private func persistMutation(_ mutation: () throws -> Void) -> Bool {
        do {
            try CurrentWorkoutPersistence.perform(
                in: managedObjectContext,
                save: { try managedObjectContext.save() },
                mutation: mutation
            )
            return true
        } catch {
            persistenceError = "Your latest changes could not be saved. \(error.localizedDescription)"
            return false
        }
    }

    /// Inline controls update their managed values before invoking `onChanged`.
    /// Keep those edits available for retry, but suppress downstream effects
    /// until the context is durably saved.
    @discardableResult
    private func save() -> Bool {
        guard managedObjectContext.hasChanges else { return true }
        do {
            try managedObjectContext.save()
            return true
        } catch {
            persistenceError = "Your latest changes could not be saved. \(error.localizedDescription)"
            return false
        }
    }
}

/// Keeps all note scopes in one presentation, reusing the staged editors and
/// their existing Save/Cancel behavior without stacking another sheet.
private struct WorkoutExerciseNotesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let exerciseNote: String?
    let planNote: String?
    let workoutNote: String?
    let canEditExercise: Bool
    let canEditPlan: Bool
    let exerciseEditor: () -> ExerciseNoteEditorSheet
    let planEditor: () -> ExerciseNoteEditorSheet
    let onSaveWorkout: (String) -> Bool

    private enum Field {
        case exercise, plan, workout
    }
    @State private var editing: Field?

    var body: some View {
        Group {
            if let editing {
                switch editing {
                case .exercise:
                    exerciseEditor()
                case .plan:
                    planEditor()
                case .workout:
                    ExerciseNoteEditorSheet(
                        title: "This Workout",
                        subtitle: "Saved only with this exercise in this workout.",
                        text: workoutNote ?? "",
                        onSave: onSaveWorkout
                    )
                }
            } else {
                NavigationStack {
                    Form {
                        Section {
                            if canEditExercise {
                                noteAction("Add Exercise Note", text: exerciseNote, field: .exercise)
                            } else {
                                Text(exerciseNote ?? "No exercise note.")
                                    .foregroundStyle(IronTheme.secondaryText)
                            }
                        } header: {
                            Text("Exercise")
                        } footer: {
                            Text(canEditExercise
                                 ? "Shown in every workout that includes this exercise."
                                 : "An exercise note needs a linked exercise from the library.")
                        }

                        Section {
                            if canEditPlan {
                                noteAction("Add Workout Plan Note", text: planNote, field: .plan)
                            } else {
                                Text(planNote ?? "No workout plan note.")
                                    .foregroundStyle(IronTheme.secondaryText)
                            }
                        } header: {
                            Text("Workout Plan")
                        } footer: {
                            Text(canEditPlan
                                 ? "Shown whenever you start from this saved workout."
                                 : "This exercise isn't linked to a saved workout plan. Plan notes can't be edited here.")
                        }

                        Section {
                            noteAction("Add Workout Note", text: workoutNote, field: .workout)
                        } header: {
                            Text("This Workout")
                        } footer: {
                            Text("Saved only with this exercise in this workout.")
                        }
                    }
                    .navigationTitle("Notes")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func noteAction(_ prompt: String, text: String?, field: Field) -> some View {
        Button {
            editing = field
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(text ?? prompt)
                    .foregroundStyle(IronTheme.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "pencil")
                    .foregroundStyle(IronTheme.accent)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: IronTheme.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the note for editing")
    }
}

/// Capture the recap once when the editor opens. Record classification queries
/// stay out of the body so scrubbing effort does no Core Data work.
private struct FinishWorkoutRecap {
    struct Record: Identifiable {
        let id: NSManagedObjectID
        let exerciseName: String
        let title: String
        let setSummary: String
    }

    var setCount = 0
    var exerciseCount = 0
    var averageRPE = "–"
    var groups: [IronSessionStrip.ExerciseGroup] = []
    var records: [Record] = []
    var accessibilitySummary = "No completed sets."

    init() {}

    init(workout: Workout, exercises: [Exercise], weightUnit: WeightUnit) {
        let workoutExercises = workout.workoutExercises?.array as? [WorkoutExercise] ?? []
        var entries: [(set: WorkoutSet, exercise: WorkoutExercise, order: Int)] = []
        for exercise in workoutExercises {
            let sets = exercise.workoutSets?.array as? [WorkoutSet] ?? []
            if sets.contains(where: \.isCompleted) { exerciseCount += 1 }
            for set in sets where set.isCompleted {
                entries.append((set, exercise, entries.count))
            }
        }
        // Legacy timestamps fall back to session start, then relationship order.
        let fallback = workout.start ?? .distantPast
        entries.sort {
            let lhs = $0.set.completedAt ?? fallback
            let rhs = $1.set.completedAt ?? fallback
            return lhs == rhs ? $0.order < $1.order : lhs < rhs
        }
        setCount = entries.count
        let rpes = entries.compactMap { $0.set.rpeValue }.filter { $0 > 0 }
        if !rpes.isEmpty {
            averageRPE = (rpes.reduce(0, +) / Double(rpes.count))
                .formatted(.number.precision(.fractionLength(0...1)))
        }

        var groupExercise: NSManagedObjectID?
        var groupLabel = ""
        var bars: [IronSessionStrip.Set] = []
        var historyByExercise: [NSManagedObjectID: [WorkoutSet]] = [:]
        var warmUpCount = 0
        for entry in entries {
            let name = entry.exercise.exercise(in: exercises)?.title ?? "Unknown exercise"
            if groupExercise != entry.exercise.objectID {
                if !bars.isEmpty { groups.append(.init(label: groupLabel, sets: bars)) }
                groupExercise = entry.exercise.objectID
                groupLabel = name
                bars = []
            }

            let isRecord = entry.set.isPersonalRecord == true
            let isWarmUp = entry.set.tagValue == .warmUp
            if isWarmUp { warmUpCount += 1 }
            let volume = Self.volume(of: entry.set)
            bars.append(.init(
                kind: isWarmUp ? .warmUp : isRecord ? .record : .normal,
                completedAt: entry.set.completedAt,
                duration: entry.set.durationValue,
                volume: WeightUnit.convert(weight: volume, from: .metric, to: weightUnit),
                result: entry.set.resultTitle(weightUnit: weightUnit),
                rpe: entry.set.rpeValue
            ))

            if isRecord {
                let id = entry.exercise.objectID
                if historyByExercise[id] == nil, let context = workout.managedObjectContext,
                   let history = try? context.fetch(entry.exercise.historyFetchRequest) {
                    historyByExercise[id] = history.flatMap {
                        ($0.workoutSets?.array as? [WorkoutSet] ?? []).filter(\.isCompleted)
                    }
                }
                let precedingSets = entries.filter {
                    $0.order < entry.order && $0.exercise.exerciseUuid == entry.exercise.exerciseUuid
                }.map(\.set)
                let priorSets = historyByExercise[id].map { $0 + precedingSets }
                records.append(.init(
                    id: entry.set.objectID,
                    exerciseName: name,
                    title: Self.recordTitle(for: entry.set, priorSets: priorSets, weightUnit: weightUnit),
                    setSummary: entry.set.resultTitle(weightUnit: weightUnit)
                ))
            }
        }
        if !bars.isEmpty { groups.append(.init(label: groupLabel, sets: bars)) }
        let exerciseSummary = groups.map { "\($0.label), \($0.sets.count) \($0.sets.count == 1 ? "set" : "sets")" }.joined(separator: "; ")
        accessibilitySummary = "Session: \(setCount) completed sets, \(warmUpCount) warm-up sets, \(records.count) personal records. \(exerciseSummary)."
    }

    private static func volume(of set: WorkoutSet) -> Double {
        set.trackedVolume
    }

    private static func recordTitle(for set: WorkoutSet, priorSets: [WorkoutSet]?, weightUnit: WeightUnit) -> String {
        // isPersonalRecord means a weight/repetition improvement, not necessarily
        // an estimated 1RM record. Only name a more specific record with evidence.
        guard let priorSets, !priorSets.isEmpty else { return "New personal record" }
        if let maximum = priorSets.map(\.weightValue).max(), set.weightValue > maximum {
            return "Heaviest weight"
        }
        let atWeight = priorSets.filter { $0.weightValue == set.weightValue }
        if let maximum = atWeight.map(\.repetitionsValue).max(), set.repetitionsValue > maximum {
            let weight = WeightUnit.format(weight: set.weightValue, from: .metric, to: weightUnit)
            return "Most reps at \(weight)"
        }
        return "New personal record"
    }
}

private struct FinishWorkoutRecordRow: View {
    let record: FinishWorkoutRecap.Record
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "trophy.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(IronTheme.metricRecord)
                .modifier(if: !reduceMotion) {
                    $0.symbolEffect(.bounce, options: .nonRepeating, value: hasAppeared)
                }
                .frame(width: 36, height: 36)
                .background(IronTheme.metricRecordContainer, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.exerciseName)
                    .font(.body.weight(.semibold))
                Text(record.title)
                    .font(.subheadline)
                    .foregroundStyle(IronTheme.secondaryText)
                Text(record.setSummary)
                    .font(.ironMetric(.caption, weight: .semibold))
                    .foregroundStyle(IronTheme.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .opacity(hasAppeared ? 1 : 0)
        .animation(IronMotion.preferred(IronMotion.fade, reduceMotion: reduceMotion), value: hasAppeared)
        .accessibilityElement(children: .combine)
        .onAppear { hasAppeared = true }
    }
}

/// The same effort graph is used when finishing and when editing history.
private struct FinishWorkoutEffortControl: View {
    @Binding var rating: Int

    var body: some View {
        VStack(spacing: 16) {
            Text("Rate Your Effort")
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            EffortRatingGraph(rating: $rating, allowsUnrated: true)
                .frame(maxWidth: .infinity)

            if rating > 0 {
                Button("Clear Rating") { rating = 0 }
                    .font(.body)
                    .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight)
                    .buttonStyle(.borderless)
                    .accessibilityHint("Leaves session effort unrated")
            }
        }
        .padding(.vertical, 8)
    }
}

enum CurrentWorkoutPersistence {
    static func perform(
        in context: NSManagedObjectContext,
        save: () throws -> Void,
        mutation: () throws -> Void
    ) throws {
        try context.persistMutation(save: save, mutation: mutation)
    }
}

private enum FinishWorkoutMediaKind: Equatable {
    case image
    case video

    init(url: URL) {
        let videoExtensions = Set(["mov", "mp4", "m4v", "avi", "hevc"])
        self = videoExtensions.contains(url.pathExtension.lowercased()) ? .video : .image
    }
}

private enum FinishWorkoutMediaError: LocalizedError {
    case missingWorkoutIdentifier
    case unreadableMedia

    var errorDescription: String? {
        switch self {
        case .missingWorkoutIdentifier:
            return "This workout does not have an identifier yet."
        case .unreadableMedia:
            return "The selected media could not be read."
        }
    }
}

enum FinishWorkoutMediaStore {
    private static let directoryName = "IronWorkoutMedia"

    static func existingURL(for workoutUUID: UUID) -> URL? {
        guard let directoryURL = directoryURL(createIfNeeded: false),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        return files.first {
            $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(workoutUUID.uuidString) == .orderedSame
        }
    }

    @discardableResult
    static func save(data: Data, for workoutUUID: UUID, fileExtension: String) throws -> URL {
        guard let directoryURL = directoryURL(createIfNeeded: true) else {
            throw FinishWorkoutMediaError.unreadableMedia
        }

        remove(for: workoutUUID)
        let safeExtension = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let mediaURL = directoryURL
            .appendingPathComponent(workoutUUID.uuidString, isDirectory: false)
            .appendingPathExtension(safeExtension.isEmpty ? "bin" : safeExtension)
        try data.write(to: mediaURL, options: [.atomic])
        return mediaURL
    }

    static func remove(for workoutUUID: UUID) {
        guard let mediaURL = existingURL(for: workoutUUID) else { return }
        try? FileManager.default.removeItem(at: mediaURL)
    }

    private static func directoryURL(createIfNeeded: Bool) -> URL? {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        let directoryURL = applicationSupportURL.appendingPathComponent(directoryName, isDirectory: true)
        if createIfNeeded {
            try? FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
        return directoryURL
    }
}

/// Sits above the scrolling/collapsing region, so the pill's 66 pt content
/// clearance stays relative to the same scroll-view origin in both states.
private struct WorkoutSessionProgressBar: View {
    private static let exerciseGap: CGFloat = 4
    private static let setGap: CGFloat = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var exerciseStore: ExerciseStore
    @ObservedObject var workout: Workout
    let focusedExerciseID: NSManagedObjectID?
    let onSelect: (NSManagedObjectID) -> Void
    private var exercises: [WorkoutExercise] {
        workout.workoutExercises?.array as? [WorkoutExercise] ?? []
    }
    @State private var selectedExerciseID: NSManagedObjectID?
    @State private var selectionFeedback = 0

    private func sets(for exercise: WorkoutExercise) -> [WorkoutSet] {
        exercise.workoutSets?.array as? [WorkoutSet] ?? []
    }

    private var totalCount: Int { exercises.reduce(0) { $0 + sets(for: $1).count } }
    private var completedCount: Int { exercises.reduce(0) { $0 + sets(for: $1).filter(\.isCompleted).count } }
    private var currentExercise: WorkoutExercise? {
        exercises.first { $0.objectID == focusedExerciseID }
    }

    var body: some View {
        GeometryReader { proxy in
            let available = max(0, proxy.size.width - CGFloat(max(exercises.count - 1, 0)) * Self.exerciseGap)
            HStack(spacing: Self.exerciseGap) {
                ForEach(exercises, id: \.objectID) { exercise in
                    let count = sets(for: exercise).count
                    let fraction = totalCount > 0 ? Double(count) / Double(totalCount) : 1 / Double(max(exercises.count, 1))
                    let width = available * fraction
                    segment(exercise, width: width)
                        .frame(width: width, height: 6)
                }
            }
            // One 44 pt tall touch surface maps taps to their segment, including
            // narrow segments, without overlapping individual button targets.
            .frame(height: IronTheme.controlHeight)
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                var edge: CGFloat = 0
                for exercise in exercises {
                    let fraction = totalCount > 0
                        ? Double(sets(for: exercise).count) / Double(totalCount)
                        : 1 / Double(max(exercises.count, 1))
                    edge += available * fraction + Self.exerciseGap
                    if value.location.x <= edge {
                        select(exercise)
                        return
                    }
                }
                if let last = exercises.last { select(last) }
            })
            .frame(height: 6)
        }
        .frame(height: 6)
        .sensoryFeedback(.selection, trigger: selectionFeedback) { _, _ in SettingsStore.shared.workoutHaptics }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Workout progress")
        .accessibilityValue(accessibilitySummary)
        .accessibilityAdjustableAction { direction in
            guard !exercises.isEmpty else { return }
            let id = selectedExerciseID ?? currentExercise?.objectID
            let index = exercises.firstIndex { $0.objectID == id } ?? 0
            switch direction {
            case .increment: select(exercises[min(index + 1, exercises.count - 1)])
            case .decrement: select(exercises[max(index - 1, 0)])
            default: break
            }
        }
    }

    private func segment(_ exercise: WorkoutExercise, width: CGFloat) -> some View {
        let allSets = sets(for: exercise)
        let completed = allSets.filter(\.isCompleted)
        let fillWidth = width * Double(completed.count) / Double(max(allSets.count, 1))
        // With very many sets the gaps would eat the bar, so it stays solid below 4 pt a set.
        let setGap = width / CGFloat(max(allSets.count, 1)) < 4 ? 0 : Self.setGap
        return Capsule()
            .fill(IronTheme.tertiaryFill)
            .overlay(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(completed, id: \.objectID) { set in
                        Rectangle()
                            .fill(set.tagValue == nil ? IronTheme.accent : IronTheme.setFill(for: set.tagValue).tint.opacity(0.7))
                    }
                }
                .frame(width: fillWidth)
            }
            .clipShape(Capsule())
            // Each fill edge lands inside a gap, since both divide the width by the set count.
            .mask {
                HStack(spacing: setGap) {
                    ForEach(0..<max(allSets.count, 1), id: \.self) { _ in Rectangle() }
                }
            }
            .frame(height: 6)
            .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: completed.count)
            .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: allSets.count)
    }

    private var accessibilitySummary: String {
        let progress = "\(completedCount) of \(totalCount) sets complete"
        guard let currentExercise else { return progress }
        let title = currentExercise.exercise(in: exerciseStore.exercises)?.title ?? "Unknown Exercise"
        return "\(progress), current exercise \(title)"
    }

    private func select(_ exercise: WorkoutExercise) {
        selectedExerciseID = exercise.objectID
        selectionFeedback += 1
        onSelect(exercise.objectID)
    }
}

enum InlineWorkoutSetLayout {
    // On a 393 pt phone, the 353 pt card interior leaves 63.5 pt per value
    // with RPE on: 196 pt fixed columns + five 6 pt gaps. Previous stays visible.
    static let spacing: CGFloat = 6
    static let stackedSpacing: CGFloat = 12
    static let labelSpacing: CGFloat = 4
    static let visualHeight: CGFloat = 40
    static let compactRowHeight: CGFloat = 52
    static let completionSymbolSize: CGFloat = 24
    static let completedChromeExpansion: CGFloat = 6
    static let setWidth: CGFloat = 44
    static let previousWidth: CGFloat = 64
    static let rpeWidth: CGFloat = 44
    static let completionWidth: CGFloat = 44
}

struct InlineWorkoutSetRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var settingsStore: SettingsStore
    @ObservedObject var set: WorkoutSet
    // Keep the inline hint current after local setup edits and peer sync.
    @ObservedObject private var plateInventoryCache = PlateCalculatorStorageKeys.inventoryCache
    @ObservedObject private var plateLoadoutsCache = PlateCalculatorStorageKeys.loadoutsCache
    @ScaledMetric(relativeTo: .footnote) private var previousFontSize: CGFloat = 13

    let index: Int
    let trackingType: SetTrackingType
    private var usesDuration: Bool { trackingType.usesDuration }
    let isBarbell: Bool
    let previousTitle: String
    let onOpenPlateCalculator: () -> Void
    let onToggleCompleted: () -> Void
    let onDelete: () -> Bool
    let onChanged: () -> Bool
    var allowsSwipeToDelete = false
    var openSwipeSetID: Binding<NSManagedObjectID?> = .constant(nil)
    var isCurrent = false
    // Stored in kilograms, just like the set; history is only a suggestion.
    var previousWeight: Double? = nil
    var previousRepetitions: Int? = nil
    var onCompletionFlow: (() -> Void)? = nil

    private var showsFocusedEditor: Bool {
        isCurrent && trackingType.usesReps && !set.isCompleted
    }

    @State private var stepFeedback = 0
    @State private var completionFeedback = 0
    @State private var isRaisedCurrent = false
    @State private var completionBounce = 0
    @State private var checkReveal: CGFloat = 0

    private var valueColor: Color {
        return set.isCompleted || isRaisedCurrent ? IronTheme.primaryText : IronTheme.secondaryText
    }

    /// A number that still matches what was filled in stays quiet. One the user changed reads as theirs.
    private var weightIsChanged: Bool {
        let filledIn = previousWeight ?? (isBarbell
            ? WeightUnit.convert(weight: settingsStore.weightUnit.barbellWeight, from: settingsStore.weightUnit, to: .metric)
            : 0)
        return set.weightValue > 0 && abs(set.weightValue - filledIn) > 0.000_001
    }

    private var repetitionsAreChanged: Bool {
        return set.repetitionsValue > 0 && Int(set.repetitionsValue) != previousRepetitions ?? 5
    }

    private var badgeColor: Color {
        if set.isCompleted { return IronTheme.setFill(for: set.tagValue).tint }
        if set.tagValue == .warmUp { return IronTheme.metricSets }
        return set.isCompleted || isRaisedCurrent ? IronTheme.accent : IronTheme.secondaryText
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
        if set.tagValue == .warmUp { return IronTheme.metricSetsContainer }
        if set.isCompleted { return IronTheme.accentSoft }
        return isRaisedCurrent ? .clear : IronTheme.field
    }

    private var completionImage: some View {
        Image(systemName: set.isCompleted ? "checkmark.circle.fill" : "circle")
            .symbolRenderingMode(.palette)
            .foregroundStyle(
                set.isCompleted ? IronTheme.onAccent : (isRaisedCurrent ? IronTheme.accent : IronTheme.tertiaryText),
                IronTheme.accent
            )
            .font(.system(size: InlineWorkoutSetLayout.completionSymbolSize, weight: .regular))
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
            .frame(width: InlineWorkoutSetLayout.completionSymbolSize, height: InlineWorkoutSetLayout.completionSymbolSize)
        }
    }

    @State private var showingRPEPicker = false
    @State private var advancesAfterRPE = false
    @State private var showingDurationPicker = false
    @State private var showingDurationSaveError = false
    @State private var inlineTimerStart: Date?

    /// Timed sets can be run like a stopwatch instead of dialling in a target
    /// first: tap to start, tap to bank the elapsed time.
    @ViewBuilder
    private var durationControl: some View {
        if settingsStore.inlineSetTimer, !set.isCompleted {
            TimelineView(.periodic(from: Date(), by: 0.5)) { context in
                Button {
                    stepFeedback += 1
                    toggleInlineTimer()
                } label: {
                    durationLabel(
                        text: inlineTimerText(now: context.date),
                        isRunning: inlineTimerStart != nil
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(inlineTimerStart == nil ? "Start set timer" : "Stop set timer")
                .accessibilityValue(inlineTimerText(now: context.date))
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
            .accessibilityValue(set.durationValue.map(SetTrackingType.durationText) ?? "Not entered")
        }
    }

    private func durationLabel(text: String, isRunning: Bool) -> some View {
        HStack(spacing: InlineWorkoutSetLayout.spacing) {
            if trackingType.columns.count == 1 || isRunning {
                Image(systemName: isRunning ? "stop.fill" : "stopwatch")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(
                        isRunning ? IronTheme.danger : (set.isCompleted || isRaisedCurrent ? IronTheme.metricTime : IronTheme.secondaryText)
                    )
            }
            Text(text)
                .font(.ironMetric(.title3))
                .foregroundColor(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: text)
        }
        .frame(maxWidth: .infinity, minHeight: InlineWorkoutSetLayout.visualHeight)
    }

    private func inlineTimerText(now: Date) -> String {
        guard let inlineTimerStart else {
            return SetTrackingType.durationText(set.durationValue ?? 0)
        }
        let elapsed = max(0, now.timeIntervalSince(inlineTimerStart))
        return SetTrackingType.durationText(elapsed)
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
    @State private var weightText = ""
    @State private var repetitionsText = ""
    @State private var distanceText = ""
    @State private var swipeOffset: CGFloat = 0
    @State private var swipeStartOffset: CGFloat = 0
    @State private var isSwipingSet = false
    @State private var isPerformingSwipeDelete = false
    @State private var measuredRowWidth: CGFloat = 0
    @State private var measuredRowHeight: CGFloat = 52
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
        case distance
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

    private var formattedDistance: String {
        guard let meters = set.distanceValue else { return "" }
        return weightFormatter.string(from: NSNumber(value: WorkoutSet.distanceDisplayValue(meters, weightUnit: settingsStore.weightUnit))) ?? ""
    }
    private var distanceTextBinding: Binding<String> {
        Binding(get: { distanceText }, set: { input in
            let sanitized = sanitizedDecimalInput(input)
            guard input.isEmpty || !sanitized.isEmpty else { return }
            distanceText = sanitized
            let value = weightFormatter.number(from: sanitized)?.doubleValue ?? 0
            let meters = WorkoutSet.distanceMeters(value, weightUnit: settingsStore.weightUnit)
            guard (set.distanceValue ?? 0) != meters else { return }
            set.distanceValue = meters
            _ = onChanged()
        })
    }

    private var weightFormatter: NumberFormatter {
        settingsStore.weightUnit.numberFormatter
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            if allowsSwipeToDelete, deleteRevealWidth > 0.5 {
                swipeDeleteAction
            }

            Group {
                if showsFocusedEditor {
                    focusedEditor
                        .transition(.opacity)
                } else {
                    compactRow
                        .transition(.opacity)
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
                IronMotion.preferred(isCurrent && !usesDuration ? IronMotion.collapse : IronMotion.snappy, reduceMotion: reduceMotion),
                value: set.isCompleted
            )
            .animation(IronMotion.preferred(IronMotion.collapse, reduceMotion: reduceMotion), value: showsFocusedEditor)
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
        .setRowSwipe(
            enabled: allowsSwipeToDelete,
            legacy: swipeDeleteGesture,
            onChanged: handleSwipeChanged,
            onEnded: handleSwipeEnded
        )
        .onChange(of: openSwipeSetID.wrappedValue) { _, id in
            if id != set.objectID, !isPerformingSwipeDelete { closeSwipe() }
        }
        .sensoryFeedback(.selection, trigger: stepFeedback) { _, _ in settingsStore.workoutHaptics }
        .sensoryFeedback(.success, trigger: completionFeedback) { _, _ in settingsStore.workoutHaptics }
        .onChange(of: showsFocusedEditor) { _, _ in
            if focusedField == nil { synchronizeEntryText() }
        }
        .onAppear {
            synchronizeEntryText()
            isRaisedCurrent = isCurrent && !set.isCompleted
            checkReveal = set.isCompleted ? 1 : 0
        }
        .onChange(of: isCurrent) { _, current in
            withAnimation(IronMotion.preferred(
                current ? IronMotion.snappy.delay(0.18) : IronMotion.snappy,
                reduceMotion: reduceMotion
            )) {
                isRaisedCurrent = current && !set.isCompleted
            }
        }
        .onChange(of: set.isCompleted) { _, isCompleted in
            if focusedField != .weight { weightText = formattedWeight }
            if isCompleted {
                completionBounce += 1
                withAnimation(IronMotion.preferred(IronMotion.snappy.delay(0.12), reduceMotion: reduceMotion)) {
                    checkReveal = 1
                }
            } else {
                checkReveal = 0
            }
            withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) {
                isRaisedCurrent = isCurrent && !isCompleted
            }
            // Banking the elapsed time on completion keeps a running stopwatch
            // from being silently discarded.
            guard isCompleted, inlineTimerStart != nil else { return }
            toggleInlineTimer()
        }
        .onChange(of: set.weightValue) { _, _ in
            guard focusedField != .weight else { return }
            weightText = formattedWeight
        }
        .onChange(of: set.distanceValue) { _, _ in
            if focusedField != .distance { distanceText = formattedDistance }
        }
        .onChange(of: trackingType) { _, _ in
            inlineTimerStart = nil
            focusedField = nil
            synchronizeEntryText()
        }
        .onChange(of: set.repetitionsValue) { _, _ in
            guard focusedField != .repetitions else { return }
            repetitionsText = formattedRepetitions
        }
        .onChange(of: settingsStore.weightUnit) { _, _ in
            focusedField = nil
            synchronizeEntryText()
        }
        .onChange(of: focusedField) { _, newValue in
            if newValue != .distance { distanceText = formattedDistance }
            weightText = formattedWeight
            if newValue != .repetitions {
                repetitionsText = formattedRepetitions
            }
        }
        .toolbar {
            if focusedField != nil {
                ToolbarItemGroup(placement: .keyboard) {
                    if trackingType.usesWeight, focusedField == .weight, settingsStore.showPlateCalculator {
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
        .sheet(isPresented: $showingRPEPicker, onDismiss: {
            guard advancesAfterRPE else { return }
            advancesAfterRPE = false
            onCompletionFlow?()
        }) {
            RPEPickerSheet(set: set, onChanged: onChanged)
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

    private var focusedEditor: some View {
        VStack(spacing: InlineWorkoutSetLayout.stackedSpacing) {
            focusedHeaderLayout {
                Menu {
                    setTypeMenuItems
                } label: {
                    HStack(spacing: 4) {
                        Text("Set \(index + 1)")
                        if let tag = set.tagValue {
                            Image(systemName: setTypeIcon(for: tag))
                                .foregroundStyle(badgeColor)
                        }
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(IronTheme.secondaryText)
                    }
                    .font(.ironMetric(.headline))
                    .foregroundStyle(IronTheme.primaryText)
                    .frame(minWidth: IronTheme.controlHeight, minHeight: IronTheme.controlHeight)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Set \(index + 1) type")
                .accessibilityValue(set.tagValue?.title ?? "Normal set")
                .accessibilityHint("Change set type")

                Spacer(minLength: 0)
                if !previousTitle.isEmpty && previousTitle != "—" {
                    Text("Last time \(previousTitle)")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(IronTheme.secondaryText)
                        .multilineTextAlignment(.trailing)
                }
            }

            focusedFieldsLayout {
                if trackingType.usesWeight { focusedTile(.weight) }
                focusedTile(.repetitions)
            }

            HStack(spacing: 8) {
                if isBarbell, settingsStore.showPlateCalculator, let hint = plateHint {
                    Button(action: openPlateCalculator) {
                        Label(hint, systemImage: "circle.circle")
                            .font(.subheadline)
                            .foregroundStyle(IronTheme.secondaryText)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the plate calculator")
                }
                Spacer(minLength: 0)
                if settingsStore.logRPE {
                    Button { showingRPEPicker = true } label: {
                        Text(set.rpeValue.map { "RPE \(String(format: "%g", $0))" } ?? "Add RPE")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(IronTheme.metricEffort)
                            .padding(.horizontal, 12)
                            .frame(minHeight: IronTheme.controlHeight)
                            .background(IronTheme.metricEffortContainer, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(rpeAccessibilityLabel)
                    .accessibilityHint("Opens the effort selector")
                }
            }

            Button(action: toggleCompletion) {
                Label("Log Set", systemImage: "checkmark")
                    .font(.headline)
                    .foregroundStyle(IronTheme.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 52)
                    .background(IronTheme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Log set \(index + 1)")
        }
        .padding(10)
        .background(IronTheme.raisedSurface, in: RoundedRectangle(cornerRadius: IronTheme.heroCornerRadius, style: .continuous))
        .padding(.vertical, 6)
    }

    private var focusedHeaderLayout: AnyLayout {
        dynamicTypeSize >= .xxxLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: InlineWorkoutSetLayout.spacing))
            : AnyLayout(HStackLayout(alignment: .center, spacing: InlineWorkoutSetLayout.spacing))
    }

    private var focusedFieldsLayout: AnyLayout {
        dynamicTypeSize >= .xxxLarge
            ? AnyLayout(VStackLayout(spacing: InlineWorkoutSetLayout.spacing))
            : AnyLayout(HStackLayout(alignment: .center, spacing: InlineWorkoutSetLayout.spacing))
    }

    private func focusedTile(_ field: EntryField) -> some View {
        let isWeight = field == .weight
        let placeholder = isWeight ? previousWeightPlaceholder : previousRepetitions.map { String($0) } ?? "0"
        return VStack(alignment: .leading, spacing: InlineWorkoutSetLayout.spacing) {
            Text(isWeight ? weightAccessibilityTitle : "Reps")
                .font(.subheadline)
                .foregroundStyle(IronTheme.secondaryText)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                TextField(placeholder, text: isWeight ? weightTextBinding : repetitionsTextBinding)
                    .font(.ironMetric(.largeTitle))
                    .foregroundStyle(IronTheme.primaryText)
                    .keyboardType(isWeight ? .decimalPad : .numberPad)
                    .focused($focusedField, equals: field)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(minWidth: 0, minHeight: 48)
                    .accessibilityLabel(isWeight ? "\(weightAccessibilityTitle) in \(settingsStore.weightUnit.unit.symbol)" : "Repetitions")
                    .accessibilityHint("Double tap to type")
                if isWeight {
                    Text(trackingType.weightPrefix + settingsStore.weightUnit.unit.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(IronTheme.secondaryText)
                }
            }
            HStack(spacing: 8) {
                stepButton(field, direction: -1)
                stepButton(field, direction: 1)
            }
        }
        .padding(12)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(IronTheme.surface, in: RoundedRectangle(cornerRadius: IronTheme.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: IronTheme.cornerRadius, style: .continuous)
                .stroke(focusedField == field ? IronTheme.accent : IronTheme.outline, lineWidth: focusedField == field ? 2 : 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isWeight ? weightAccessibilityTitle : "Reps")
        .accessibilityValue(isWeight
            ? WeightUnit.format(weight: set.weightValue, from: .metric, to: settingsStore.weightUnit)
            : String(Int(set.repetitionsValue)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(field, direction: 1)
            case .decrement: step(field, direction: -1)
            @unknown default: break
            }
        }
    }

    private func stepButton(_ field: EntryField, direction: Int) -> some View {
        let action = direction > 0 ? "Increase" : "Decrease"
        let unitName = settingsStore.weightUnit == .imperial ? "pounds" : "kilograms"
        let increment = weightFormatter.string(from: NSNumber(value: settingsStore.weightUnit.barbellIncrement)) ?? "0"
        return Button { step(field, direction: direction) } label: {
            Image(systemName: direction > 0 ? "plus" : "minus")
                .font(.body.weight(.bold))
                .foregroundStyle(IronTheme.primaryText)
                .frame(width: InlineWorkoutSetLayout.visualHeight, height: InlineWorkoutSetLayout.visualHeight)
                .background(IronTheme.field, in: Circle())
                .frame(width: IronTheme.controlHeight, height: IronTheme.controlHeight)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(field == .weight ? "\(action) \(weightAccessibilityTitle.lowercased()) by \(increment) \(unitName)" : "\(action) reps by 1")
    }

    private var displayWeight: Double {
        WeightUnit.convert(weight: set.weightValue, from: .metric, to: settingsStore.weightUnit)
    }

    private var previousWeightPlaceholder: String {
        guard let previousWeight else { return "0" }
        let value = WeightUnit.convert(weight: previousWeight, from: .metric, to: settingsStore.weightUnit)
        return weightFormatter.string(from: NSNumber(value: value)) ?? "0"
    }

    private func step(_ field: EntryField, direction: Int) {
        let oldWeight = set.weightValue
        let oldRepetitions = set.repetitionsValue
        if field == .weight {
            let previous = WeightUnit.convert(weight: previousWeight ?? 0, from: .metric, to: settingsStore.weightUnit)
            let base = set.weightValue == 0 && direction > 0 ? previous : displayWeight
            let maximum = WeightUnit.convert(weight: WorkoutSet.MAX_WEIGHT, from: .metric, to: settingsStore.weightUnit)
            let value = min(max(base + Double(direction) * settingsStore.weightUnit.barbellIncrement, 0), maximum)
            weightTextBinding.wrappedValue = weightFormatter.string(from: NSNumber(value: value)) ?? "0"
        } else {
            let base = set.repetitionsValue == 0 && direction > 0 ? previousRepetitions ?? 0 : Int(set.repetitionsValue)
            let value = min(max(base + direction, 0), Int(WorkoutSet.MAX_REPETITIONS))
            repetitionsTextBinding.wrappedValue = String(value)
        }
        if set.weightValue != oldWeight || set.repetitionsValue != oldRepetitions {
            stepFeedback += 1
            IronSoundPlayer.shared.play(.tick)
        }
    }

    private var plateHint: String? {
        let unit = settingsStore.weightUnit
        let preferences = PlateCalculatorPreferences.load()
        let exerciseKey = set.workoutExercise?.exerciseUuid?.uuidString
        let loadout = exerciseKey.flatMap { preferences.loadouts[$0] }?.converted(to: unit.plateLoadUnit)
            ?? PlateLoadout.standard(for: unit.plateLoadUnit)
        guard displayWeight >= loadout.baseWeight else { return nil }
        let solution = PlateLoadSolver.solve(target: displayWeight, loadout: loadout,
                                            inventory: preferences.inventory ?? PlateInventory())
        // A hint must describe the actual load, not a rounded-down approximation.
        guard abs(solution.loadedTotal - displayWeight) < 0.001 else { return nil }
        guard !solution.platesPerSide.isEmpty else {
            switch loadout.mode {
            case .barbell: return "Empty bar"
            case .noBar: return "No plates"
            case .machine: return "Starting weight only"
            }
        }
        let weights = solution.platesPerSide.map { plate in
            let title = weightFormatter.string(from: NSNumber(value: plate.weight)) ?? "0"
            return plate.count > 1 ? "\(plate.count) × \(title)" : title
        }
        return weights.joined(separator: " + ") + (loadout.loadedSides == .both ? " per side" : " on one side")
    }

    private func toggleCompletion() {
        let wasCompleted = set.isCompleted
        let animation = showsFocusedEditor ? IronMotion.collapse : IronMotion.snappy
        if showsFocusedEditor { focusedField = nil }
        withAnimation(IronMotion.preferred(animation, reduceMotion: reduceMotion)) {
            onToggleCompleted()
        }
        if !wasCompleted, set.isCompleted {
            completionFeedback += 1
            focusedField = nil
            // This callback is supplied only by the active logger. Historical
            // editing keeps its existing presentation and completion behavior.
            if let onCompletionFlow {
                if settingsStore.logRPE, set.rpeValue == nil {
                    advancesAfterRPE = true
                    if !showingRPEPicker { showingRPEPicker = true }
                } else {
                    onCompletionFlow()
                }
            }
        }
        if wasCompleted, !set.isCompleted { stepFeedback += 1 }
    }

    @ViewBuilder
    private var compactRow: some View {
        if needsExpandedCompactLayout {
            accessibleCompactRow
        } else {
            regularCompactRow
        }
    }

    private var compactPreviousTitle: String {
        let title = previousTitle.isEmpty ? "—" : previousTitle
        let font = UIFont.monospacedDigitSystemFont(ofSize: previousFontSize, weight: .semibold)
        guard (title as NSString).size(withAttributes: [.font: font]).width > InlineWorkoutSetLayout.previousWidth,
              !usesDuration, title.contains(" × "),
              let previousWeight, let previousRepetitions else { return title }
        // resultTitle includes the weight unit. The column header already supplies it;
        // format from the history values so localized units never need string stripping.
        let weight = WeightUnit.convert(weight: previousWeight, from: .metric, to: settingsStore.weightUnit)
        let value = settingsStore.weightUnit.displayNumberFormatter.string(from: NSNumber(value: weight)) ?? "0"
        let sign = title.hasPrefix("+") ? "+" : (title.hasPrefix("−") ? "−" : "")
        return "\(sign)\(value) × \(previousRepetitions)"
    }

    private var needsExpandedCompactLayout: Bool { dynamicTypeSize.isAccessibilitySize }

    private var weightAccessibilityTitle: String {
        trackingType == .assistedBodyweight ? "Assistance" : (trackingType == .weightedBodyweight ? "Added weight" : "Weight")
    }

    @ViewBuilder
    private func measurementField(_ column: SetTrackingType.Column) -> some View {
        switch column {
        case .weight:
            setField(isFocused: focusedField == .weight, isChanged: weightIsChanged) {
                TextField("0", text: weightTextBinding)
                    .keyboardType(.decimalPad).focused($focusedField, equals: .weight)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("\(weightAccessibilityTitle) in \(settingsStore.weightUnit.unit.symbol)")
            }
        case .reps:
            setField(isFocused: focusedField == .repetitions, isChanged: repetitionsAreChanged) {
                TextField("0", text: repetitionsTextBinding)
                    .keyboardType(.numberPad).focused($focusedField, equals: .repetitions)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("Repetitions")
            }
        case .duration:
            setField { durationControl }
        case .distance:
            setField(isFocused: focusedField == .distance) {
                TextField("0", text: distanceTextBinding)
                    .keyboardType(.decimalPad).focused($focusedField, equals: .distance)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("Distance in \(WorkoutSet.distanceUnit(settingsStore.weightUnit))")
            }
        }
    }

    private var accessibleCompactRow: some View {
        VStack(alignment: .leading, spacing: InlineWorkoutSetLayout.stackedSpacing) {
            accessibleSetActionsLayout {
                Menu { setTypeMenuItems } label: {
                    Text(set.tagValue == nil ? "Set \(index + 1)" : "\(setLabel) · Set \(index + 1)")
                        .font(.ironMetric(.headline))
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
                            .font(.ironMetric(.title3))
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
            Text("Previous: \(previousTitle.isEmpty ? "—" : previousTitle)")
                .font(.ironMetric(.footnote, weight: .semibold))
                .foregroundStyle(IronTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, InlineWorkoutSetLayout.labelSpacing)
                .frame(minHeight: InlineWorkoutSetLayout.visualHeight, alignment: .center)
                .background(IronTheme.tertiaryFill, in: RoundedRectangle(cornerRadius: IronTheme.compactCornerRadius, style: .continuous))
            ForEach(trackingType.columns) { column in
                VStack(alignment: .leading, spacing: InlineWorkoutSetLayout.labelSpacing) {
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

    private var accessibleSetActionsLayout: AnyLayout {
        dynamicTypeSize >= .accessibility3
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: InlineWorkoutSetLayout.spacing))
            : AnyLayout(HStackLayout(alignment: .center, spacing: InlineWorkoutSetLayout.spacing))
    }

    private var regularCompactRow: some View {
        HStack(alignment: .center, spacing: InlineWorkoutSetLayout.spacing) {
            Menu {
                setTypeMenuItems
            } label: {
                Text(setLabel)
                    .font(.ironMetric(.title3))
                    .foregroundStyle(badgeColor)
                    .frame(width: InlineWorkoutSetLayout.visualHeight, height: InlineWorkoutSetLayout.visualHeight)
                    .background(badgeFill, in: Circle())
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "chevron.down.circle.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(badgeColor, IronTheme.surface)
                            .offset(x: 2, y: 2)
                            .accessibilityHidden(true)
                    }
                    .overlay {
                        Circle()
                            .stroke(IronTheme.accent, lineWidth: 1.5)
                            .opacity(isRaisedCurrent && !set.isCompleted && set.tagValue != .warmUp ? 1 : 0)
                    }
                    .frame(width: IronTheme.iconButtonSize, height: IronTheme.controlHeight)
                    .contentShape(Rectangle())
                    .frame(width: InlineWorkoutSetLayout.setWidth)
            }
            .accessibilityLabel("Set type")
            .accessibilityValue(set.tagValue?.title ?? "Normal set")
            .accessibilityHint("Change set type")

            Text(compactPreviousTitle)
                .font(.ironMetric(.footnote, weight: .semibold))
                .foregroundColor(IronTheme.secondaryText)
                .lineLimit(3)
                .minimumScaleFactor(0.75)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .frame(width: InlineWorkoutSetLayout.previousWidth, alignment: .center)
                .frame(minHeight: InlineWorkoutSetLayout.visualHeight)
                .background(IronTheme.tertiaryFill, in: RoundedRectangle(cornerRadius: IronTheme.compactCornerRadius, style: .continuous))
                .accessibilityLabel("Previous: \(previousTitle.isEmpty ? "—" : previousTitle)")

            ForEach(trackingType.columns) { column in
                measurementField(column)
            }

            if settingsStore.logRPE {
                Button(action: { showingRPEPicker = true }) {
                    Group {
                        if let rpe = set.rpeValue {
                            Text(String(format: "%g", rpe))
                        } else if set.isCompleted {
                            Text("–")
                        } else {
                            Image(systemName: "gauge.with.dots.needle.50percent")
                                .font(.title3.weight(.semibold))
                        }
                    }
                    .font(.ironMetric(.title3))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .foregroundStyle(set.rpeValue != nil || (!set.isCompleted && isRaisedCurrent) ? IronTheme.metricEffort : IronTheme.secondaryText)
                    .frame(width: InlineWorkoutSetLayout.visualHeight, height: InlineWorkoutSetLayout.visualHeight)
                    .background(
                        Capsule(style: .continuous)
                            .fill(IronTheme.metricEffortContainer)
                            .opacity(isRaisedCurrent && !set.isCompleted ? 1 : 0)
                    )
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
        .frame(maxWidth: .infinity, minHeight: InlineWorkoutSetLayout.compactRowHeight)
        .padding(.horizontal, InlineWorkoutSetLayout.completedChromeExpansion)
        .background {
            RoundedRectangle(cornerRadius: IronTheme.compactCornerRadius, style: .continuous)
                .fill(IronTheme.field)
                .opacity(isRaisedCurrent && !set.isCompleted ? 1 : 0)
        }
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
                if onChanged() { stepFeedback += 1 }
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
        if showsFocusedEditor && set.weightValue == 0 { return "" }
        let displayValue = WeightUnit.convert(
            weight: set.weightValue,
            from: .metric,
            to: settingsStore.weightUnit
        )
        let formatter = focusedField == .weight ? weightFormatter : settingsStore.weightUnit.displayNumberFormatter
        return formatter.string(from: NSNumber(value: displayValue)) ?? "0"
    }

    private var formattedRepetitions: String {
        showsFocusedEditor && set.repetitionsValue == 0 ? "" : String(Int(set.repetitionsValue))
    }

    private func synchronizeEntryText() {
        weightText = formattedWeight
        repetitionsText = formattedRepetitions
        distanceText = formattedDistance
    }

    private func sanitizedDecimalInput(_ proposedValue: String) -> String {
        let decimalSeparator = weightFormatter.decimalSeparator
            ?? Locale.current.decimalSeparator
            ?? "."
        let maximumFractionDigits = settingsStore.weightUnit.maximumFractionDigits
        var result = ""
        var hasDecimalSeparator = false
        var fractionDigitCount = 0

        for character in proposedValue {
            if let digit = character.wholeNumberValue {
                if hasDecimalSeparator {
                    guard fractionDigitCount < maximumFractionDigits else { continue }
                    fractionDigitCount += 1
                }
                result.append(contentsOf: String(digit))
            } else if (character == "." || character == "," || String(character) == decimalSeparator),
                      maximumFractionDigits > 0,
                      !hasDecimalSeparator {
                if result.isEmpty {
                    result = "0"
                }
                result.append(contentsOf: decimalSeparator)
                hasDecimalSeparator = true
            }
        }

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
        isChanged: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .font(.ironMetric(.title3))
            .foregroundColor(isFocused || isChanged ? IronTheme.primaryText : valueColor)
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(minWidth: 0, maxWidth: width == nil ? .infinity : nil, minHeight: InlineWorkoutSetLayout.visualHeight)
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

private struct RPEPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var exerciseStore: ExerciseStore
    @ObservedObject var set: WorkoutSet
    let onChanged: () -> Bool

    @State private var selection: Double?
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
        _selection = State(initialValue: set.rpeValue)
    }

    private var valueTitle: String { selection.map { String(format: "%g", $0) } ?? "–" }

    private var title: String {
        let exercise = set.workoutExercise?.exercise(in: exerciseStore.exercises)
        return "Set \(setNumber) · \(exercise?.title ?? "Exercise")"
    }

    private var effortDescription: String {
        guard let selection else { return "Not rated · tap a bar" }
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
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
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
                .foregroundStyle(selection == nil ? IronTheme.secondaryText : IronTheme.metricEffort)
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
        .accessibilityValue(selection == nil ? "Not rated" : "RPE \(valueTitle), \(effortDescription)")
        .accessibilityHint("Swipe up or down to adjust by half a point. Double tap to save, or use the Save action.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: selection = min((selection ?? 4.5) + 0.5, 10)
            case .decrement: selection = max((selection ?? 5.5) - 0.5, 5)
            @unknown default: break
            }
        }
        .accessibilityAction { save(selection) }
        .accessibilityAction(named: Text("Save")) { save(selection) }
    }

    private func effortBar(index: Int) -> some View {
        let value = 5 + Double(index) * 0.5
        let tint = selection.map { value <= $0 } == true
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

#if DEBUG
struct WorkoutView_Previews: PreviewProvider {
    static var previews: some View {
        CurrentWorkoutView(workout: MockWorkoutData.metricRandom.currentWorkout)
            .mockEnvironment(weightUnit: .metric)
    }
}
#endif

// MARK: - Set row swipe

/// A pan that begins only when the drag is mostly horizontal, so vertical drags
/// that start on a set row scroll the logger instead of being swallowed.
@available(iOS 18.0, *)
private struct HorizontalSwipeRecognizer: UIGestureRecognizerRepresentable {
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
    func setRowSwipe<Legacy: Gesture>(
        enabled: Bool,
        legacy: Legacy,
        onChanged: @escaping (CGFloat) -> Void,
        onEnded: @escaping (CGFloat, CGFloat) -> Void
    ) -> some View {
        if !enabled {
            self
        } else if #available(iOS 18.0, *) {
            gesture(HorizontalSwipeRecognizer(onChanged: onChanged, onEnded: onEnded))
        } else {
            simultaneousGesture(legacy)
        }
    }
}
