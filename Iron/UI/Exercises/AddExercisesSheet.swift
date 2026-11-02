//
//  AddExercisesSheet.swift
//  Sunrise Fit
//
//  Created by Karim Abou Zeid on 03.09.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import SwiftUI
import WorkoutDataKit
import CoreData

/// Prepared once, so a keystroke only filters. Sorting the library and rereading the
/// hidden exercises several times for every letter is what made typing lag.
final class AddExerciseCatalog {
    private struct Entry {
        let exercise: Exercise
        let searchTitles: [String]
        let isBrowsable: Bool
    }

    private let entries: [Entry]
    private var last: (search: String, muscleGroup: String?, equipment: String?, entries: [Entry])?
    let muscleGroups: [String]
    let equipment: [String]
    /// Matching exercises the last result left out until the person asks for more.
    private(set) var moreCount = 0

    init(exercises: [Exercise], store: ExerciseStore) {
        let sorted = exercises.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        entries = store.orderedByRecency(sorted).map { exercise in
            Entry(exercise: exercise, searchTitles: ([exercise.title] + exercise.alias).map { $0.lowercased() },
                  isBrowsable: store.isBrowsable(exercise))
        }
        muscleGroups = Array(Set(exercises.map(\.muscleGroup))).sorted()
        var counts: [String: Int] = [:]
        exercises.forEach { exercise in
            exercise.equipment.forEach { counts[$0, default: 0] += 1 }
        }
        equipment = counts.keys.sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }
    }

    /// Keeps the prepared order. Words match anywhere in the title or an alias, as in `ExerciseStore.filter`.
    func matches(search: String, muscleGroup: String?, equipment: String?, showingAll: Bool = false) -> [Exercise] {
        let search = search.lowercased()
        let words = search.split(whereSeparator: \.isWhitespace)
        // Another letter can only narrow the results, so it searches the last matches.
        let narrows = last.map {
            $0.muscleGroup == muscleGroup && $0.equipment == equipment && search.hasPrefix($0.search)
        } ?? false
        let matches = (narrows ? last?.entries ?? entries : entries).filter { entry in
            (muscleGroup == nil || entry.exercise.muscleGroup == muscleGroup)
                && (equipment == nil || entry.exercise.equipment.contains(equipment!))
                && (words.isEmpty || entry.searchTitles.contains { title in words.allSatisfy { title.contains($0) } })
        }
        // The cache keeps every match, so a later letter can still find an unlisted exercise.
        last = (search, muscleGroup, equipment, matches)
        // Mirrors ExerciseStore.listed, using the flags prepared once per entry.
        let browsable = matches.filter(\.isBrowsable)
        let listed = !words.isEmpty || showingAll
            ? browsable + matches.filter { !$0.isBrowsable }
            : (browsable.isEmpty ? matches : browsable)
        moreCount = matches.count - listed.count
        return listed.map(\.exercise)
    }
}

struct AddExercisesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var exerciseStore: ExerciseStore
    @ScaledMetric(relativeTo: .subheadline) private var selectionIndicatorSize: CGFloat = 26

    private let exercises: [Exercise]
    private let title: String
    private let actionTitle: String
    private let maximumSelectionCount: Int?
    let onAdd: ([Exercise]) -> Void
    private let onDismiss: (() -> Void)?
    private let shouldDismiss: () -> Bool

    @State private var exerciseSelectorSelection: [Exercise] = []
    @State private var search = ""
    @State private var selectedMuscleGroup: String?
    @State private var selectedEquipment: String?
    @State private var showingAllExercises = false
    @State private var detailExercise: Exercise?
    @State private var selectionFeedback = 0
    @State private var showingCreateExercise = false
    @State private var catalog: AddExerciseCatalog?

    init(
        exercises: [Exercise],
        recentExercises: [Exercise] = [],
        title: String = "Add Exercise",
        actionTitle: String = "Add",
        maximumSelectionCount: Int? = nil,
        onDismiss: (() -> Void)? = nil,
        shouldDismiss: @escaping () -> Bool = { true },
        onAdd: @escaping ([Exercise]) -> Void
    ) {
        self.exercises = exercises
        // Kept as an initializer argument for existing callers. Recents now
        // come from the live shared cache, rather than a presentation snapshot.
        self.title = title
        self.actionTitle = actionTitle
        self.maximumSelectionCount = maximumSelectionCount
        self.onDismiss = onDismiss
        self.shouldDismiss = shouldDismiss
        self.onAdd = onAdd
    }

    private func refreshCatalog() {
        let shown = exerciseStore.shownExercises
        catalog = AddExerciseCatalog(exercises: shown.isEmpty ? exercises : shown, store: exerciseStore)
    }

    private func resetAndDismiss() {
        guard shouldDismiss() else { return }
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
        self.exerciseSelectorSelection.removeAll()
        self.search = ""
    }
    
    static func loadRecentExercises(context: NSManagedObjectContext, exercises: [Exercise], maxCount: Int = .max) -> [Exercise] {
        guard maxCount > 0 else { return [] }
        // Compatibility for CurrentWorkoutView and other existing callers.
        // No history fetch runs on presentation or on a search keystroke.
        let store = ExerciseStore.shared
        store.observeWorkoutHistory(in: context)
        return Array(store.orderedByRecency(exercises)
            .filter { store.lastPerformedDates[$0.uuid] != nil }
            .prefix(maxCount))
    }

    @ViewBuilder
    private func showMoreRow(count: Int) -> some View {
        if count > 0 {
            Button("Show \(count.formatted()) More Exercises") { showingAllExercises = true }
                .foregroundStyle(IronTheme.accent)
        }
    }

    var body: some View {
        let matches = catalog?.matches(search: search, muscleGroup: selectedMuscleGroup, equipment: selectedEquipment,
                                       showingAll: showingAllExercises) ?? []
        let moreCount = catalog?.moreCount ?? 0
        // Search and filters use a flat list with exactly the same recency order.
        let recents = search.isEmpty && selectedMuscleGroup == nil && selectedEquipment == nil
            ? matches.filter { exerciseStore.lastPerformedDates[$0.uuid] != nil }
            : []
        NavigationStack {
            List {
                if catalog == nil {
                    EmptyView()
                } else if matches.isEmpty {
                    emptyState
                } else if !recents.isEmpty {
                    Section("Recent") {
                        ForEach(recents) { exercise in
                            exerciseRow(exercise)
                        }
                    }

                    let recentSet = Set(recents)
                    Section("All Exercises") {
                        ForEach(matches.filter { !recentSet.contains($0) }) { exercise in
                            exerciseRow(exercise)
                        }
                        showMoreRow(count: moreCount)
                    }
                } else {
                    Section {
                        ForEach(matches) { exercise in
                            exerciseRow(exercise)
                        }
                        showMoreRow(count: moreCount)
                    } footer: {
                        Text("^[\(matches.count) exercise](inflect: true)")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .sensoryFeedback(.selection, trigger: selectionFeedback) { _, _ in SettingsStore.shared.workoutHaptics }
            .sensoryFeedback(.selection, trigger: [selectedMuscleGroup, selectedEquipment]) { _, _ in SettingsStore.shared.workoutHaptics }
            .contentMargins(.horizontal, 10, for: .scrollContent)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search exercises")
            .keepsToolbarWhileSearching()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: resetAndDismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmationTitle, action: addSelectedExercises)
                        .fontWeight(.semibold)
                        .disabled(exerciseSelectorSelection.isEmpty)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Menu {
                        Picker("Muscle", selection: $selectedMuscleGroup) {
                            Text("All Muscles").tag(String?.none)
                            ForEach(catalog?.muscleGroups ?? [], id: \.self) { group in
                                Text(group.capitalized).tag(String?.some(group))
                            }
                        }
                    } label: {
                        Image(systemName: "figure.arms.open")
                            .foregroundStyle(selectedMuscleGroup == nil ? IronTheme.primaryText : IronTheme.accent)
                    }
                    .accessibilityLabel("Filter by muscle group")
                    .accessibilityValue(selectedMuscleGroup?.capitalized ?? "All muscles")

                    Menu {
                        Picker("Equipment", selection: $selectedEquipment) {
                            Text("All Equipment").tag(String?.none)
                            ForEach(catalog?.equipment ?? [], id: \.self) { item in
                                Text(item.equipmentTitle).tag(String?.some(item))
                            }
                        }
                    } label: {
                        Image(systemName: "dumbbell")
                            .foregroundStyle(selectedEquipment == nil ? IronTheme.primaryText : IronTheme.accent)
                    }
                    .accessibilityLabel("Filter by equipment")
                    .accessibilityValue(selectedEquipment?.equipmentTitle ?? "All equipment")

                    Spacer()

                    Button("Create Exercise", systemImage: "plus") {
                        showingCreateExercise = true
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        .onAppear { if catalog == nil { refreshCatalog() } }
        // Fires before the change lands, so read the store on the next turn.
        .onReceive(exerciseStore.objectWillChange) { DispatchQueue.main.async(execute: refreshCatalog) }
        .sheet(isPresented: $showingCreateExercise) {
            CreateCustomExerciseSheet(
                onDismiss: { showingCreateExercise = false }
            )
            .environmentObject(exerciseStore)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $detailExercise) { exercise in
            NavigationStack {
                ExerciseDetailView(exercise: exercise)
                    .ironScreen()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { detailExercise = nil }
                        }
                    }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            ContentUnavailableView {
                Label("No matching exercises", systemImage: "line.3.horizontal.decrease")
            } description: {
                Text("Try a different muscle group or equipment.")
            } actions: {
                Button("Clear Filters") {
                    selectedMuscleGroup = nil
                    selectedEquipment = nil
                }
            }
        }
    }

    private func exerciseRow(_ exercise: Exercise) -> some View {
        let selectionNumber = exerciseSelectorSelection.firstIndex(of: exercise).map { $0 + 1 }
        let metadata = ExerciseLibraryMetadata(
            exercise: exercise,
            lastPerformed: exerciseStore.lastPerformedDates[exercise.uuid]
        )

        return Button(action: { toggle(exercise) }) {
            HStack(spacing: 12) {
                selectionIndicator(number: selectionNumber)

                ExerciseDiagramThumbnail(exercise: exercise, size: 44)
                    .contentShape(Circle())
                    // The thumbnail consumes its tap before the row selects.
                    .highPriorityGesture(
                        TapGesture().onEnded { detailExercise = exercise }
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(IronTheme.primaryText)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(metadata.title)
                        .font(.subheadline)
                        .foregroundStyle(IronTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metadata.accessibilityLabel)
        .accessibilityValue(selectionNumber.map {
            maximumSelectionCount == 1 ? "Selected" : "Selection \($0)"
        } ?? "Not selected")
        .accessibilityAction(named: Text("Show Details")) {
            detailExercise = exercise
        }
    }

    /// Ordered selection mirrors Photos; single-selection callers keep a check.
    private func selectionIndicator(number: Int?) -> some View {
        ZStack {
            if let number {
                Circle().fill(IronTheme.accent)
                if maximumSelectionCount == 1 {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(IronTheme.onAccent)
                } else {
                    Text("\(number)")
                        .font(.ironMetric(.subheadline, weight: .semibold))
                        .foregroundStyle(IronTheme.onAccent)
                }
            } else {
                Circle().strokeBorder(IronTheme.outline, lineWidth: 2)
            }
        }
        .frame(width: selectionIndicatorSize, height: selectionIndicatorSize)
        .accessibilityHidden(true)
    }

    private func toggle(_ exercise: Exercise) {
        if let index = exerciseSelectorSelection.firstIndex(of: exercise) {
            exerciseSelectorSelection.remove(at: index)
        } else if maximumSelectionCount == 1 {
            exerciseSelectorSelection = [exercise]
        } else {
            exerciseSelectorSelection.append(exercise)
        }

        selectionFeedback += 1
    }

    private func addSelectedExercises() {
        guard !exerciseSelectorSelection.isEmpty else { return }
        onAdd(exerciseSelectorSelection)
        resetAndDismiss()
    }

    private var confirmationTitle: String {
        guard !exerciseSelectorSelection.isEmpty else { return actionTitle }
        return maximumSelectionCount == 1
            ? actionTitle
            : "\(actionTitle) \(exerciseSelectorSelection.count)"
    }
}

private extension View {
    /// Cancel and Add stay on screen while searching.
    @ViewBuilder func keepsToolbarWhileSearching() -> some View {
        if #available(iOS 17.1, *) {
            searchPresentationToolbarBehavior(.avoidHidingContent)
        } else {
            self
        }
    }
}

struct AddExercisesSheet_Previews: PreviewProvider {
    static var previews: some View {
//        Color.clear.sheet(isPresented: .constant(true)) {
        AddExercisesSheet(
            exercises: ExerciseStore.shared.shownExercises,
            recentExercises: [],
            onAdd: { _ in }
        )
        .environmentObject(ExerciseStore.shared)
//        }
    }
}
