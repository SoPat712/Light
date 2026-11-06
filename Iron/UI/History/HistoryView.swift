//
//  HistoryView.swift
//  Iron
//
//  Created by Karim Abou Zeid on 22.06.19.
//

import SwiftUI
import CoreData
import WorkoutDataKit

struct HistoryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var exerciseStore: ExerciseStore
    @EnvironmentObject private var sceneState: SceneState
    @Environment(\.managedObjectContext) private var managedObjectContext
    @ObservedObject private var historyStore = TrainingHistoryStore.shared

    @State private var activityItems: [Any]?
    @State private var workoutToDelete: Workout?
    @State private var showingRepeatBlocked = false
    @State private var showingShareUnavailable = false
    @State private var persistenceError: String?
    @State private var searchText = ""
    @Namespace private var workoutDetailNamespace

    var body: some View {
        navigationContent
        .confirmationDialog(
            "Delete this workout?",
            isPresented: Binding(
                get: { workoutToDelete != nil },
                set: { if !$0 { workoutToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Workout", role: .destructive) {
                guard let workout = workoutToDelete else { return }
                workoutToDelete = nil
                do {
                    try workout.delete()
                } catch {
                    persistenceError = "The workout was not deleted. \(error.localizedDescription)"
                }
            }
            Button("Cancel", role: .cancel) {
                workoutToDelete = nil
            }
        } message: {
            Text("This removes the workout, its logged sets, and Light’s matching Apple Health workout.")
        }
        .sheet(isPresented: $showingRepeatBlocked) {
            IronStatusSheet(
                headerTitle: "Workout in progress",
                title: "Finish your current workout first",
                message: "Your active workout is safely stored on this iPhone. Finish or discard it before repeating another session.",
                systemImage: "figure.strengthtraining.traditional",
                tint: IronTheme.warning,
                actionTitle: "Got It"
            )
            .modifier(HistoryStatusPresentation())
        }
        .sheet(isPresented: $showingShareUnavailable) {
            IronStatusSheet(
                headerTitle: "Share workout",
                title: "Nothing to share yet",
                message: "This workout does not contain a completed set log. Add or complete a set before sharing it.",
                systemImage: "square.and.arrow.up",
                tint: IronTheme.accent,
                actionTitle: "Got It"
            )
            .modifier(HistoryStatusPresentation())
        }
        .ironActivitySheet(activityItems: $activityItems)
        .alert("Workout Not Saved", isPresented: Binding(
            get: { persistenceError != nil },
            set: { if !$0 { persistenceError = nil } }
        )) {
            Button("OK", role: .cancel) { persistenceError = nil }
        } message: {
            Text(persistenceError ?? "Please try again.")
        }
    }

    @ViewBuilder
    private var navigationContent: some View {
        if #available(iOS 16.0, *) {
            NavigationStack { historyList }
        } else {
            NavigationView { historyList }
                .navigationViewStyle(.stack)
        }
    }

    private var historyList: some View {
        List {
            if let error = historyStore.error {
                Section {
                    Button("Retry Loading History") { historyStore.refresh() }
                } footer: { Text(error) }
            } else if historyStore.isLoading && historyStore.snapshot.sessions.isEmpty {
                Section { ProgressView("Loading History…") }
            } else {
                workoutHistoryContent
            }
        }
        .listStyle(.insetGrouped)
        .modifier(HistoryScrollEdge())
        .modifier(HistoryScrollClearance())
        .navigationTitle("History")
        .modifier(HistoryTitleDisplayMode())
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Workouts")
        .task { historyStore.observe(in: managedObjectContext) }
    }

    private var searchTerms: [String] {
        searchText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private var matchingSessions: [TrainingSessionSnapshot] {
        let terms = searchTerms
        return historyStore.snapshot.sessions.filter { session in
            // Search only immutable history and the in-memory catalog, never managed objects.
            let titles = [session.displayTitle] + session.exercises.compactMap {
                $0.uuid.flatMap { exerciseStore.exercisesByUUID[$0]?.title }
            }
            return terms.allSatisfy { term in
                titles.contains { $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil }
            }
        }.sorted { $0.date > $1.date }
    }

    @ViewBuilder
    private var workoutHistoryContent: some View {
        let completed = historyStore.snapshot.sessions
        let records = historyStore.snapshot.recordSetIDs
        if !searchText.isEmpty {
            let matches = matchingSessions
            if matches.isEmpty {
                historyEmptyRow(title: "No Workouts Found", message: "Try an exercise name, like bench.")
            } else {
                ForEach(matches) { session in
                    workoutHistoryLink(session, recordSetIDs: records)
                }
            }
        } else if completed.isEmpty {
            Section("Workouts") {
                historyEmptyRow(title: "No Workouts Yet", message: "Finished workouts, volume, effort, and personal records appear here.")
            }
        } else {
            let weeks = HistoryWorkoutWeek.group(completed)
            ForEach(weeks) { week in
                Section {
                    ForEach(week.workouts) { session in
                        workoutHistoryLink(session, recordSetIDs: records)
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(LightFormat.weekTitle(start: week.id))
                        Spacer(minLength: 8)
                        Text("\(week.workouts.count) workout\(week.workouts.count == 1 ? "" : "s")")
                            .font(.ironMetric(.caption, weight: .semibold))
                    }
                    .foregroundStyle(IronTheme.secondaryText)
                    .lineLimit(1)
                    .textCase(nil)
                } footer: {
                    if week.id == weeks.last?.id {
                        Text("\(completed.count) completed workout\(completed.count == 1 ? "" : "s").")
                    }
                }
            }
        }
    }

    private func historyEmptyRow(title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline).foregroundStyle(IronTheme.primaryText)
            Text(message).font(.subheadline).foregroundStyle(IronTheme.secondaryText)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
    }

    private func workoutHistoryLink(_ session: TrainingSessionSnapshot, recordSetIDs: Set<NSManagedObjectID>) -> some View {
        let workout = managedObjectContext.object(with: session.id) as! Workout
        return NavigationLink {
            if #available(iOS 18.0, *), !reduceMotion {
                WorkoutDetailView(workout: workout)
                    .environmentObject(settingsStore)
                    .navigationTransition(.zoom(sourceID: workout.objectID, in: workoutDetailNamespace))
            } else {
                WorkoutDetailView(workout: workout)
                    .environmentObject(settingsStore)
            }
        } label: {
            if #available(iOS 18.0, *), !reduceMotion {
                WorkoutHistoryRow(session: session, workout: workout, recordSetIDs: recordSetIDs)
                    .matchedTransitionSource(id: workout.objectID, in: workoutDetailNamespace)
            } else {
                WorkoutHistoryRow(session: session, workout: workout, recordSetIDs: recordSetIDs)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                workoutToDelete = workout
            } label: { Label("Delete", systemImage: "trash") }
            Button {
                share(workout)
            } label: { Label("Share", systemImage: "square.and.arrow.up") }
            .tint(IronTheme.secondaryText)
        }
        .contextMenu {
            Button { share(workout) } label: { Label("Share Workout", systemImage: "square.and.arrow.up") }
            Button { repeatWorkout(workout, blank: false) } label: { Label("Repeat Workout", systemImage: "arrow.clockwise") }
            Button { repeatWorkout(workout, blank: true) } label: { Label("Repeat with Blank Sets", systemImage: "doc") }
            Divider()
            Button(role: .destructive) { workoutToDelete = workout } label: { Label("Delete Workout", systemImage: "trash") }
        }
    }

    private func share(_ workout: Workout) {
        guard let log = workout.logText(
            in: exerciseStore.exercises,
            weightUnit: settingsStore.weightUnit
        ) else {
            showingShareUnavailable = true
            return
        }
        activityItems = [log]
    }

    private func repeatWorkout(_ workout: Workout, blank: Bool) {
        do {
            let didStart: Bool
            if blank {
                didStart = try WorkoutDetailView.repeatWorkoutBlank(
                    workout: workout,
                    settingsStore: settingsStore,
                    sceneState: sceneState
                )
            } else {
                didStart = try WorkoutDetailView.repeatWorkout(
                    workout: workout,
                    settingsStore: settingsStore,
                    sceneState: sceneState
                )
            }

            if !didStart { showingRepeatBlocked = true }
        } catch {
            persistenceError = "The workout was not started. \(error.localizedDescription)"
        }
    }

}

private struct HistoryWorkoutWeek: Identifiable {
    let id: Date
    let workouts: [TrainingSessionSnapshot]

    static func group(_ workouts: [TrainingSessionSnapshot]) -> [Self] {
        let grouped = Dictionary(grouping: workouts) { workout in
            Calendar.current.dateInterval(of: .weekOfYear, for: workout.date)?.start ?? .distantPast
        }
        return grouped.keys.sorted(by: >).map {
            Self(id: $0, workouts: (grouped[$0] ?? []).sorted { $0.date > $1.date })
        }
    }
}

private struct WorkoutHistoryRow: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var exerciseStore: ExerciseStore
    let session: TrainingSessionSnapshot
    @ObservedObject var workout: Workout
    let recordSetIDs: Set<NSManagedObjectID>

    private var recordCount: Int {
        let exercises = workout.workoutExercises?.array as? [WorkoutExercise] ?? []
        return exercises.reduce(0) { total, exercise in
            total + (exercise.workoutSets?.array as? [WorkoutSet] ?? []).filter {
                $0.isCompleted && recordSetIDs.contains($0.objectID)
            }.count
        }
    }

    private var volumeNumber: String {
        WeightUnit.convert(weight: session.volume, from: .metric, to: settingsStore.weightUnit)
            .formatted(.number.precision(.fractionLength(0)))
    }

    private var exerciseSummary: String {
        let titles = session.exercises.enumerated().sorted {
            if $0.element.setCount == $1.element.setCount { return $0.offset < $1.offset }
            return $0.element.setCount > $1.element.setCount
        }.map { item in
            item.element.uuid.flatMap { exerciseStore.exercisesByUUID[$0]?.title } ?? "Unknown Exercise"
        }
        let leading = titles.prefix(2).joined(separator: ", ")
        return titles.count > 2 ? leading + " +\(titles.count - 2)" : leading
    }

    private var metadata: Text {
        let duration = metricNumber(LightFormat.duration(session.duration))
        return Text(LightFormat.listDate(session.date)) + Text(" · ") + duration
            + Text(" · ") + metricNumber("\(session.setCount)") + Text(" sets · ")
            + metricNumber(volumeNumber) + Text(" \(settingsStore.weightUnit.unit.symbol)")
    }

    private func metricNumber(_ value: String) -> Text {
        Text(value)
            .font(.ironMetric(.subheadline, weight: .semibold))
            .foregroundColor(IronTheme.primaryText)
    }

    var body: some View {
        let records = recordCount
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(workout.displayTitle(in: exerciseStore.exercises))
                    .font(.headline)
                    .foregroundStyle(IronTheme.primaryText)
                    .lineLimit(2)
                if records > 0 {
                    Image(systemName: "trophy.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(IronTheme.metricRecord)
                        .accessibilityLabel("\(records) personal record\(records == 1 ? "" : "s")")
                }
            }
            metadata
                .font(.subheadline)
                .foregroundStyle(IronTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(exerciseSummary)
                .font(.footnote)
                .foregroundStyle(IronTheme.secondaryText)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct HistoryScrollEdge: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.scrollEdgeEffectStyle(.hard, for: .top)
        } else if #available(iOS 16, *) {
            content.toolbarBackground(.visible, for: .navigationBar)
        } else {
            content
        }
    }
}

private struct HistoryTitleDisplayMode: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 17, *) {
            content.toolbarTitleDisplayMode(.inlineLarge)
        } else {
            content.navigationBarTitleDisplayMode(.large)
        }
    }
}

private struct HistoryScrollClearance: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.contentMargins(.bottom, IronTheme.floatingWorkoutBottomClearance, for: .scrollContent)
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: IronTheme.floatingWorkoutBottomClearance).allowsHitTesting(false)
            }
        }
    }
}

private struct HistoryStatusPresentation: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.presentationDetents([.height(390), .medium]).presentationDragIndicator(.visible)
        } else {
            content
        }
    }
}

#if DEBUG
struct HistoryView_Previews: PreviewProvider {
    static var previews: some View {
        HistoryView().mockEnvironment(weightUnit: .metric)
    }
}
#endif
