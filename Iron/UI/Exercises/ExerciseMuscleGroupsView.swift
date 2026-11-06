//
//  ExerciseCategoryView.swift
//  Sunrise Fit
//
//  Created by Karim Abou Zeid on 04.07.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import SwiftUI
import UIKit
import Combine
import WorkoutDataKit

struct ExerciseMuscleGroupsView : View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject var exerciseStore: ExerciseStore

    @State private var search = ""
    @State private var selectedMuscleGroup: String? = nil
    @State private var selectedEquipment: String? = nil
    @State private var showingCreateExercise = false
    @StateObject private var catalogSearch = ExerciseCatalogSearch()

    private var hasActiveFilter: Bool {
        selectedMuscleGroup != nil || selectedEquipment != nil
    }

    var body: some View {
        indexedExerciseList
        .listStyle(.insetGrouped)
        .modifier(ExerciseLibraryChrome())
        .onAppear { refreshCatalog() }
        .onReceive(exerciseStore.objectWillChange) { _ in
            // Read the published history after storage, even if this render replaces the subscription.
            DispatchQueue.main.async { refreshCatalog() }
        }
        .onChange(of: [selectedMuscleGroup, selectedEquipment]) { _ in
            catalogSearch.applyFilters(muscleGroup: selectedMuscleGroup, equipment: selectedEquipment)
            if SettingsStore.shared.workoutHaptics {
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }
        .task(id: catalogSearch.request(for: search)) {
            await catalogSearch.search(search)
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: IronTheme.floatingWorkoutBottomClearance - 28)
        }
        .navigationTitle("Exercises")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingCreateExercise = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create Exercise")
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search exercises")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .sheet(isPresented: $showingCreateExercise) {
            let sheet = CreateCustomExerciseSheet(onDismiss: { showingCreateExercise = false })
                .environmentObject(exerciseStore)
            if #available(iOS 16, *) {
                sheet
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            } else {
                sheet
            }
        }
    }

    private func refreshCatalog() {
        catalogSearch.refresh(exercises: exerciseStore.shownExercises, store: exerciseStore,
                              muscleGroup: selectedMuscleGroup, equipment: selectedEquipment)
    }

    @ViewBuilder
    private var indexedExerciseList: some View {
        if #available(iOS 26, *) {
            exerciseList
                .listSectionIndexVisibility(.visible)
        } else {
            exerciseList
        }
    }

    private var exerciseList: some View {
        let candidates = catalogSearch.candidates
        let results = catalogSearch.listing(for: search, showingAll: true).exercises
        return List {
            if search.isEmpty {
                filterRow
                if let candidates {
                    if candidates.exercises.isEmpty {
                        emptyExerciseState
                    } else {
                        if !candidates.recent.isEmpty {
                            Section("Recent") {
                                exerciseRows(candidates.recent)
                            }
                        }
                        ForEach(candidates.sections, id: \.letter) { section in
                            letterSection(section.letter, exercises: section.exercises)
                        }
                    }
                }
            } else {
                Section {
                    if results.isEmpty && catalogSearch.isSearching(search) {
                        ProgressView("Searching Exercises…")
                    } else if results.isEmpty {
                        emptyExerciseState
                    } else {
                        exerciseRows(results)
                    }
                } header: {
                    // A separate, headerless filter section reserved a large gap
                    // before search results. Keep the filters in this header instead.
                    filterControls
                        .textCase(nil)
                        .padding(.bottom, 8)
                }
            }

            Section {
                NavigationLink(destination: CustomExercisesView()) {
                    libraryRowLabel("Custom Exercises", count: catalogSearch.catalog?.customCount ?? 0)
                }
                NavigationLink(destination: HiddenExercisesView()) {
                    libraryRowLabel("Hidden Exercises", count: catalogSearch.catalog?.hiddenCount ?? 0)
                }
            } header: {
                Text("Library")
            } footer: {
                exerciseCountFooter(search.isEmpty ? candidates?.exercises.count ?? 0 : results.count)
            }
        }
        .modifier(ExerciseLibraryScrollEdge())
    }

    @ViewBuilder
    private func letterSection(_ letter: String, exercises: [Exercise]) -> some View {
        let section = Section(letter) {
            exerciseRows(exercises)
        }

        if #available(iOS 26, *) {
            section.sectionIndexLabel(letter)
        } else {
            section
        }
    }

    private func exerciseRows(_ exercises: [Exercise]) -> some View {
        ForEach(exercises) { exercise in
            NavigationLink(destination: ExerciseDetailView(exercise: exercise)) {
                ExerciseLibraryRow(exercise: exercise)
            }
        }
    }

    private func exerciseCountFooter(_ count: Int) -> some View {
        Text("^[\(count) exercise](inflect: true)")
            .font(.ironMetric(.footnote, weight: .semibold))
            .foregroundStyle(IronTheme.secondaryText)
    }

    private func libraryRowLabel(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(IronTheme.primaryText)
            Spacer()
            Text(count.formatted())
                .font(.ironMetric(.body, weight: .semibold))
                .foregroundStyle(IronTheme.secondaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("^[\(count) exercise](inflect: true)")
    }

    @ViewBuilder
    private var filterRow: some View {
        let section = Section {
            filterControls
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }

        if #available(iOS 17, *) {
            // A standalone filter section otherwise adds a grouped-list gap
            // before the first exercise header.
            section.listSectionSpacing(0)
        } else {
            section
        }
    }

    private var filterControls: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    muscleFilterMenu
                    equipmentFilterMenu
                }
            } else {
                HStack(spacing: 8) {
                    muscleFilterMenu
                    equipmentFilterMenu
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var muscleFilterMenu: some View {
        Menu {
            Picker("Muscle", selection: $selectedMuscleGroup) {
                Text("All Muscles").tag(String?.none)
                ForEach(catalogSearch.catalog?.muscleGroups ?? [], id: \.self) { group in
                    Text(group.capitalized).tag(String?.some(group))
                }
            }
        } label: {
            filterLabel(selectedMuscleGroup?.capitalized ?? "All Muscles")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(selectedMuscleGroup == nil ? IronTheme.secondaryText : IronTheme.accent)
        .frame(minHeight: IronTheme.controlHeight)
        .accessibilityLabel("Filter by muscle group")
        .accessibilityValue(selectedMuscleGroup?.capitalized ?? "All muscles")
    }

    private var equipmentFilterMenu: some View {
        Menu {
            Picker("Equipment", selection: $selectedEquipment) {
                Text("All Equipment").tag(String?.none)
                ForEach(catalogSearch.catalog?.equipment ?? [], id: \.self) { item in
                    Text(item.equipmentTitle).tag(String?.some(item))
                }
            }
        } label: {
            filterLabel(selectedEquipment?.equipmentTitle ?? "All Equipment")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(selectedEquipment == nil ? IronTheme.secondaryText : IronTheme.accent)
        .frame(minHeight: IronTheme.controlHeight)
        .accessibilityLabel("Filter by equipment")
        .accessibilityValue(selectedEquipment?.equipmentTitle ?? "All equipment")
    }

    private func filterLabel(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
        }
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var emptyExerciseState: some View {
        let hasSearch = !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if #available(iOS 17, *) {
            if hasSearch {
                ContentUnavailableView.search(text: search)
            } else {
                ContentUnavailableView {
                    emptyExerciseLabel
                } description: {
                    emptyExerciseDescription
                } actions: {
                    if hasActiveFilter {
                        Button("Clear Filters") {
                            selectedEquipment = nil
                            selectedMuscleGroup = nil
                        }
                    }
                }
            }
        } else {
            VStack(spacing: 8) {
                if hasSearch {
                    Text("No results for \"\(search)\"")
                        .font(.headline)
                } else {
                    emptyExerciseLabel
                        .font(.headline)
                    emptyExerciseDescription
                        .font(.subheadline)
                        .foregroundStyle(IronTheme.secondaryText)
                    if hasActiveFilter {
                        Button("Clear Filters") {
                            selectedEquipment = nil
                            selectedMuscleGroup = nil
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.vertical, 16)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var emptyExerciseLabel: some View {
        if hasActiveFilter {
            Label("No matching exercises", systemImage: "line.3.horizontal.decrease")
        } else {
            Label("No exercises available", systemImage: "eye.slash")
        }
    }

    @ViewBuilder
    private var emptyExerciseDescription: some View {
        if hasActiveFilter {
            Text("Try a different muscle group or equipment.")
        } else {
            Text("All exercises are hidden. Restore one from Hidden Exercises in the Library section.")
        }
    }
}

private struct ExerciseLibraryScrollEdge: ViewModifier {
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

private struct ExerciseLibraryChrome: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 17, *) {
            content
                .contentMargins(.top, 0, for: .scrollContent)
                .toolbarTitleDisplayMode(.inlineLarge)
        } else {
            content.navigationBarTitleDisplayMode(.large)
        }
    }
}

private struct HiddenExercisesView: View {
    @EnvironmentObject private var exerciseStore: ExerciseStore

    @State private var search = ""

    private var filteredExercises: [Exercise] {
        let candidates = exerciseStore.hiddenExercises
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return ExerciseStore.filter(exercises: exerciseStore.orderedByRecency(candidates), using: search,
                                    lastPerformedDates: exerciseStore.lastPerformedDates)
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
            Button {
                exerciseStore.show(exercise: exercise)
            } label: {
                Label("Restore", systemImage: "eye")
            }
            .tint(.accentColor)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let hasSearch = !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if #available(iOS 17, *) {
            if hasSearch {
                ContentUnavailableView.search(text: search)
            } else {
                ContentUnavailableView {
                    Label("No hidden exercises", systemImage: "eye")
                } description: {
                    Text("Exercises you hide from the library will appear here.")
                }
            }
        } else {
            VStack(spacing: 8) {
                if hasSearch {
                    Text("No results for \"\(search)\"")
                        .font(.headline)
                } else {
                    Label("No hidden exercises", systemImage: "eye")
                        .font(.headline)
                    Text("Exercises you hide from the library will appear here.")
                        .font(.subheadline)
                        .foregroundStyle(IronTheme.secondaryText)
                }
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.vertical, 16)
            .accessibilityElement(children: .combine)
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
