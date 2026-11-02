//
//  ExerciseCategoryView.swift
//  Sunrise Fit
//
//  Created by Karim Abou Zeid on 04.07.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import SwiftUI
import WorkoutDataKit

struct ExerciseMuscleGroupsView : View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject var exerciseStore: ExerciseStore

    @State private var search = ""
    @State private var selectedMuscleGroup: String? = nil
    @State private var selectedEquipment: String? = nil
    @State private var showingCreateExercise = false
    @State private var showingHiddenExercises = false
    @State private var showingCustomExercises = false
    @State private var showingAllExercises = false

    private var muscleGroups: [String] {
        Array(Set(exerciseStore.shownExercises.map { $0.muscleGroup })).sorted()
    }

    private var equipment: [String] {
        var counts: [String: Int] = [:]
        exerciseStore.shownExercises.forEach { exercise in
            exercise.equipment.forEach { counts[$0, default: 0] += 1 }
        }
        return counts.keys.sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }
    }

    private var matchingExercises: [Exercise] {
        let matches = ExerciseStore.filter(exercises: exerciseStore.shownExercises, using: search)
            .filter { selectedMuscleGroup == nil || $0.muscleGroup == selectedMuscleGroup }
            .filter { selectedEquipment == nil || $0.equipment.contains(selectedEquipment!) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return exerciseStore.orderedByRecency(matches)
    }

    private var hasActiveFilter: Bool {
        selectedMuscleGroup != nil || selectedEquipment != nil
    }

    var body: some View {
        let matchingExercises = matchingExercises
        let filteredExercises = exerciseStore.listed(matchingExercises, showingAll: showingAllExercises || !search.isEmpty)
        let moreCount = matchingExercises.count - filteredExercises.count
        List {
            if filteredExercises.isEmpty {
                emptyExerciseState
            } else {
                Section {
                    ForEach(filteredExercises) { exercise in
                        NavigationLink(destination: ExerciseDetailView(exercise: exercise)) {
                            ExerciseLibraryRow(exercise: exercise)
                        }
                    }
                    if moreCount > 0 {
                        Button("Show \(moreCount.formatted()) More Exercises") { showingAllExercises = true }
                            .foregroundStyle(IronTheme.accent)
                    }
                } header: {
                    if hasActiveFilter {
                        HStack {
                            activeFilterSummaryView
                            Spacer()
                            Button("Clear") {
                                selectedEquipment = nil
                                selectedMuscleGroup = nil
                            }
                            .textCase(nil)
                            .frame(minHeight: IronTheme.controlHeight)
                        }
                    }
                } footer: {
                    Text("^[\(filteredExercises.count) exercise](inflect: true)")
                        .font(.footnote)
                        .foregroundStyle(IronTheme.secondaryText)
                }
            }
        }
        .listStyle(.insetGrouped)
        .sensoryFeedback(.selection, trigger: [selectedMuscleGroup, selectedEquipment]) { _, _ in SettingsStore.shared.workoutHaptics }
        .animation(IronMotion.preferred(IronMotion.fade, reduceMotion: reduceMotion), value: search)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: IronTheme.floatingWorkoutBottomClearance - 28)
        }
        .navigationTitle("Exercises")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Muscle", selection: $selectedMuscleGroup) {
                        Text("All Muscles").tag(String?.none)
                        ForEach(muscleGroups, id: \.self) { group in
                            Text(group.capitalized).tag(String?.some(group))
                        }
                    }
                } label: {
                    Image(systemName: "figure.arms.open")
                        .foregroundStyle(selectedMuscleGroup == nil ? IronTheme.primaryText : IronTheme.accent)
                }
                .accessibilityLabel("Filter by muscle group")
                .accessibilityValue(selectedMuscleGroup?.capitalized ?? "All muscles")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Equipment", selection: $selectedEquipment) {
                        Text("All Equipment").tag(String?.none)
                        ForEach(equipment, id: \.self) { item in
                            Text(item.equipmentTitle).tag(String?.some(item))
                        }
                    }
                } label: {
                    Image(systemName: "dumbbell")
                        .foregroundStyle(selectedEquipment == nil ? IronTheme.primaryText : IronTheme.accent)
                }
                .accessibilityLabel("Filter by equipment")
                .accessibilityValue(selectedEquipment?.equipmentTitle ?? "All equipment")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Create Exercise", systemImage: "plus") {
                        showingCreateExercise = true
                    }

                    Section("Library") {
                        Button("Hidden (\(exerciseStore.hiddenExercises.count))", systemImage: "eye.slash") {
                            showingHiddenExercises = true
                        }
                        Button("Custom (\(exerciseStore.customExercises.count))", systemImage: "square.grid.2x2") {
                            showingCustomExercises = true
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create exercise or manage library")
            }
        }
        .searchable(text: $search, prompt: "Search exercises")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .sheet(isPresented: $showingCreateExercise) {
            CreateCustomExerciseSheet(onDismiss: { showingCreateExercise = false })
                .environmentObject(exerciseStore)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .navigationDestination(isPresented: $showingHiddenExercises) {
            HiddenExercisesView()
        }
        .navigationDestination(isPresented: $showingCustomExercises) {
            CustomExercisesView()
        }
    }

    @ViewBuilder
    private var emptyExerciseState: some View {
        let hasSearch = !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if hasSearch {
            ContentUnavailableView.search(text: search)
        } else if hasActiveFilter {
            ContentUnavailableView {
                Label("No matching exercises", systemImage: "line.3.horizontal.decrease")
            } description: {
                Text("Try a different muscle group or equipment.")
            } actions: {
                Button("Clear Filters") {
                    selectedEquipment = nil
                    selectedMuscleGroup = nil
                }
            }
        } else {
            ContentUnavailableView {
                Label("No exercises available", systemImage: "eye.slash")
            } description: {
                Text("All exercises are hidden. Restore one from the library menu.")
            }
        }
    }

    private var activeFilterSummary: String {
        [selectedMuscleGroup?.capitalized, selectedEquipment?.equipmentTitle]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    @ViewBuilder
    private var activeFilterSummaryView: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    activeFilterTags
                }
            } else {
                HStack(spacing: 6) {
                    activeFilterTags
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Active filters: \(activeFilterSummary)")
    }

    @ViewBuilder
    private var activeFilterTags: some View {
        if let selectedMuscleGroup {
            ExerciseLibraryTag(title: selectedMuscleGroup.capitalized)
        }
        if let selectedEquipment {
            ExerciseLibraryTag(title: selectedEquipment.equipmentTitle)
        }
    }
}

private struct HiddenExercisesView: View {
    @EnvironmentObject private var exerciseStore: ExerciseStore

    @State private var search = ""

    private var filteredExercises: [Exercise] {
        let matches = ExerciseStore.filter(exercises: exerciseStore.hiddenExercises, using: search)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return exerciseStore.orderedByRecency(matches)
    }

    var body: some View {
        List {
            if filteredExercises.isEmpty {
                emptyState
            } else {
                Section {
                    ForEach(filteredExercises) { exercise in
                        hiddenExerciseRow(exercise)
                    }
                } footer: {
                    Text("\(filteredExercises.count) hidden exercises")
                }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: IronTheme.floatingWorkoutBottomClearance - 28)
        }
        .navigationTitle("Hidden exercises")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search hidden exercises")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }

    private func hiddenExerciseRow(_ exercise: Exercise) -> some View {
        NavigationLink(destination: ExerciseDetailView(exercise: exercise)) {
            ExerciseLibraryRow(exercise: exercise)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Restore", systemImage: "eye") {
                exerciseStore.show(exercise: exercise)
            }
            .tint(.accentColor)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            ContentUnavailableView {
                Label("No hidden exercises", systemImage: "eye")
            } description: {
                Text("Exercises you hide from the library will appear here.")
            }
        }
    }
}

private struct AllExercisesView: View {
    @ObservedObject private var filter: ExerciseGroupFilter
    
    init(exerciseGroups: [ExerciseGroup]) {
        self.filter = ExerciseGroupFilter(exerciseGroups: exerciseGroups)
    }
    
    var body: some View {
        MuscleGroupSectionedExercisesView(exerciseGroups: filter.exerciseGroups)
            .navigationTitle("All exercises")
        .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $filter.filter, prompt: "Search exercises")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
}

#if DEBUG
struct ExerciseCategoryView_Previews : PreviewProvider {
    static var previews: some View {
        ExerciseMuscleGroupsView()
            .mockEnvironment(weightUnit: .metric)
    }
}
#endif
