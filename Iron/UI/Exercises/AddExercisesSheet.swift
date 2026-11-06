//
//  AddExercisesSheet.swift
//  Sunrise Fit
//
//  Created by Karim Abou Zeid on 03.09.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import SwiftUI
import UIKit
import Combine
import WorkoutDataKit
import CoreData

/// Query-independent library data, rebuilt only for catalog/history changes.
/// Both exercise lists use the same prepared text and browse/search ordering.
final class AddExerciseCatalog {
    private struct Entry {
        let exercise: Exercise
        let prepared: ExerciseSearch.Prepared<UUID>
        let isBrowsable: Bool
    }

    private let entries: [Entry]
    private let lastPerformedDates: [UUID: Date]
    let muscleGroups: [String]
    let equipment: [String]
    let equipmentCounts: [String: Int]
    let customCount: Int
    let hiddenCount: Int
    /// Matching exercises the last result left out until the person asks for more.
    private(set) var moreCount = 0

    init(exercises: [Exercise], store: ExerciseStore) {
        let sorted = exercises.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        lastPerformedDates = store.lastPerformedDates
        entries = store.orderedByRecency(sorted).map { exercise in
            Entry(exercise: exercise, prepared: ExerciseSearch.Prepared(
                id: exercise.uuid, title: exercise.title, aliases: exercise.alias, originalTitle: exercise.originalTitle),
                  isBrowsable: store.isBrowsable(exercise))
        }
        muscleGroups = Array(Set(exercises.map(\.muscleGroup))).sorted()
        var counts: [String: Int] = [:]
        exercises.forEach { exercise in
            exercise.equipment.forEach { counts[$0, default: 0] += 1 }
        }
        equipmentCounts = counts
        equipment = counts.keys.sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }
        customCount = store.customExercises.count
        hiddenCount = max(store.exercises.count - exercises.count, 0)
    }

    struct Listing {
        let exercises: [Exercise]
        let recent: [Exercise]
        let remaining: [Exercise]
        let moreCount: Int

        static let empty = Listing(exercises: [], recent: [], remaining: [], moreCount: 0)
    }

    struct LetterSection {
        let letter: String
        let exercises: [Exercise]
    }

    /// Only these immutable, Sendable values cross into a search task.
    struct SearchInput: Sendable {
        let prepared: [ExerciseSearch.Prepared<UUID>]
        let lastPerformedDates: [UUID: Date]
        let browsableIDs: Set<UUID>

        func rankedIDs(matching query: ExerciseSearch.Query) -> [UUID] {
            let matches = ExerciseSearch.ranked(prepared, matching: query, lastPerformedDates: lastPerformedDates)
            // ExerciseStore.listed(showingAll: true) partitions after ranking.
            return matches.filter { browsableIDs.contains($0.id) }.map(\.id)
                + matches.filter { !browsableIDs.contains($0.id) }.map(\.id)
        }
    }

    struct Candidates {
        let revision = UUID()
        let exercises: [Exercise]
        let exercisesByID: [UUID: Exercise]
        let recent: [Exercise]
        let sections: [LetterSection]
        let collapsed: Listing
        let expanded: Listing
        let searchInput: SearchInput

        func searchListing(ids: [UUID]) -> Listing {
            Listing(exercises: ids.compactMap { exercisesByID[$0] }, recent: [], remaining: [], moreCount: 0)
        }
    }

    func candidates(muscleGroup: String?, equipment: String?) -> Candidates {
        let filtered = entries.filter { entry in
            (muscleGroup == nil || entry.exercise.muscleGroup == muscleGroup)
                && (equipment.map { entry.exercise.equipment.contains($0) } ?? true)
        }
        let exercises = filtered.map(\.exercise)
        let browsable = filtered.filter(\.isBrowsable).map(\.exercise)
        let secondary = filtered.filter { !$0.isBrowsable }.map(\.exercise)
        let collapsed = browsable.isEmpty ? exercises : browsable
        let recent = ExerciseRecency.ordered(exercises.filter { lastPerformedDates[$0.uuid] != nil },
                                            dates: lastPerformedDates)
        let alphabetical = exercises.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let groups = Dictionary(grouping: alphabetical) { exercise in
            let initial = String(exercise.title.prefix(1)).uppercased()
            return initial.count == 1 && "ABCDEFGHIJKLMNOPQRSTUVWXYZ".contains(initial) ? initial : "#"
        }
        let sections = groups.keys.sorted {
            if $0 == "#" { return false }
            if $1 == "#" { return true }
            return $0 < $1
        }.map { LetterSection(letter: $0, exercises: groups[$0] ?? []) }

        func listing(_ listed: [Exercise]) -> Listing {
            Listing(exercises: listed,
                    recent: listed.filter { lastPerformedDates[$0.uuid] != nil },
                    remaining: listed.filter { lastPerformedDates[$0.uuid] == nil },
                    moreCount: exercises.count - listed.count)
        }

        return Candidates(
            exercises: exercises,
            exercisesByID: Dictionary(uniqueKeysWithValues: exercises.map { ($0.uuid, $0) }),
            recent: Array(recent.prefix(8)),
            sections: sections,
            collapsed: listing(collapsed),
            expanded: listing(browsable + secondary),
            searchInput: SearchInput(prepared: filtered.map(\.prepared), lastPerformedDates: lastPerformedDates,
                                     browsableIDs: Set(browsable.map(\.uuid)))
        )
    }

    /// Synchronous entry point retained for ranking parity tests and existing callers.
    /// SwiftUI uses cached Candidates and ExerciseCatalogSearch instead.
    func matches(search: String, muscleGroup: String?, equipment: String?, showingAll: Bool = false) -> [Exercise] {
        let candidates = candidates(muscleGroup: muscleGroup, equipment: equipment)
        let query = ExerciseSearch.Query(search)
        let listing = query.isEmpty
            ? (showingAll ? candidates.expanded : candidates.collapsed)
            : candidates.searchListing(ids: candidates.searchInput.rankedIDs(matching: query))
        moreCount = listing.moreCount
        return listing.exercises
    }
}

/// Main-actor publication with cancellable debounce; the detached worker sees
/// prepared text, IDs and a history snapshot, never the observable store.
@MainActor
final class ExerciseCatalogSearch: ObservableObject {
    struct Request: Equatable {
        let query: String
        let revision: UUID?
    }

    private struct Source: Equatable {
        let exercises: [Exercise]
        // History changes must invalidate candidates even with identical exercises and filters.
        let dates: [UUID: Date]
        let referencedIDs: Set<UUID>
        let customCount: Int
        let totalCount: Int
    }

    @Published private(set) var catalog: AddExerciseCatalog?
    @Published private(set) var candidates: AddExerciseCatalog.Candidates?
    @Published private(set) var searchResult = AddExerciseCatalog.Listing.empty
    private var completedRequest: Request?
    private var source: Source?
    private var activeFilters: [String?]?

    func refresh(exercises: [Exercise], store: ExerciseStore, muscleGroup: String?, equipment: String?) {
        let source = Source(exercises: exercises, dates: store.lastPerformedDates,
                            referencedIDs: store.workoutReferencedExerciseIDs,
                            customCount: store.customExercises.count, totalCount: store.exercises.count)
        guard self.source != source else {
            applyFilters(muscleGroup: muscleGroup, equipment: equipment)
            return
        }
        self.source = source
        catalog = AddExerciseCatalog(exercises: exercises, store: store)
        applyFilters(muscleGroup: muscleGroup, equipment: equipment, force: true)
    }

    func applyFilters(muscleGroup: String?, equipment: String?, force: Bool = false) {
        let filters = [muscleGroup, equipment]
        guard force || activeFilters != filters else { return }
        activeFilters = filters
        candidates = catalog?.candidates(muscleGroup: muscleGroup, equipment: equipment)
        completedRequest = nil
        searchResult = .empty
    }

    func request(for query: String) -> Request {
        Request(query: query, revision: candidates?.revision)
    }

    func isSearching(_ query: String) -> Bool {
        !ExerciseSearch.Query(query).isEmpty && completedRequest != request(for: query)
    }

    func listing(for query: String, showingAll: Bool) -> AddExerciseCatalog.Listing {
        guard let candidates else { return .empty }
        if ExerciseSearch.Query(query).isEmpty {
            return showingAll ? candidates.expanded : candidates.collapsed
        }
        return searchResult
    }

    func search(_ text: String) async {
        let request = request(for: text)
        let query = ExerciseSearch.Query(text)
        // Clearing search reads the cached browse lists in the same render.
        guard let candidates, !query.isEmpty else { return }
        do {
            try await Task.sleep(nanoseconds: 120_000_000)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        let input = candidates.searchInput
        let worker = Task.detached(priority: .userInitiated) {
            input.rankedIDs(matching: query)
        }
        let ids = await withTaskCancellationHandler(operation: {
            await worker.value
        }, onCancel: {
            worker.cancel()
        })
        guard !Task.isCancelled, self.candidates?.revision == request.revision else { return }
        completedRequest = request
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            searchResult = candidates.searchListing(ids: ids)
        }
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
    @State private var mediaExercise: Exercise?
    @State private var mediaFeedback = 0
    @State private var selectionFeedback = 0
    @State private var showingCreateExercise = false
    @StateObject private var catalogSearch = ExerciseCatalogSearch()

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
        catalogSearch.refresh(exercises: shown.isEmpty ? exercises : shown, store: exerciseStore,
                              muscleGroup: selectedMuscleGroup, equipment: selectedEquipment)
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
        let listing = catalogSearch.listing(for: search, showingAll: showingAllExercises)
        let matches = listing.exercises
        let showsRecents = search.isEmpty && selectedMuscleGroup == nil && selectedEquipment == nil
            && !listing.recent.isEmpty
        ExercisePickerNavigation {
            List {
                if catalogSearch.catalog == nil {
                    EmptyView()
                } else if matches.isEmpty && catalogSearch.isSearching(search) {
                    ProgressView("Searching Exercises…")
                } else if matches.isEmpty {
                    emptyState
                } else if showsRecents {
                    Section("Recent") {
                        ForEach(listing.recent) { exercise in
                            exerciseRow(exercise)
                        }
                    }

                    Section("All Exercises") {
                        ForEach(listing.remaining) { exercise in
                            exerciseRow(exercise)
                        }
                        showMoreRow(count: listing.moreCount)
                    }
                } else {
                    Section {
                        ForEach(matches) { exercise in
                            exerciseRow(exercise)
                        }
                        showMoreRow(count: listing.moreCount)
                    } footer: {
                        Text("^[\(matches.count) exercise](inflect: true)")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .modifier(ExercisePickerScrollEdge())
            .modifier(ExercisePickerListMargins())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search exercises")
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
                            ForEach(catalogSearch.catalog?.muscleGroups ?? [], id: \.self) { group in
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
                            ForEach(catalogSearch.catalog?.equipment ?? [], id: \.self) { item in
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

                    Button {
                        showingCreateExercise = true
                    } label: {
                        Label("Create Exercise", systemImage: "plus")
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        .onAppear { refreshCatalog() }
        .onReceive(exerciseStore.objectWillChange) { _ in
            // objectWillChange precedes storage. Queue the read itself instead of
            // debouncing a subscription SwiftUI can replace during that change.
            DispatchQueue.main.async { refreshCatalog() }
        }
        .onChange(of: [selectedMuscleGroup, selectedEquipment]) { _ in
            catalogSearch.applyFilters(muscleGroup: selectedMuscleGroup, equipment: selectedEquipment)
            if SettingsStore.shared.workoutHaptics {
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }
        .onChange(of: selectionFeedback) { _ in
            if SettingsStore.shared.workoutHaptics {
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }
        .task(id: catalogSearch.request(for: search)) {
            await catalogSearch.search(search)
        }
        .sheet(isPresented: $showingCreateExercise) {
            CreateCustomExerciseSheet(
                onDismiss: { showingCreateExercise = false }
            )
            .environmentObject(exerciseStore)
            .modifier(ExercisePickerSheetPresentation())
        }
        .sheet(item: $detailExercise) { exercise in
            ExercisePickerNavigation {
                ExerciseDetailView(exercise: exercise)
                    .ironScreen()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { detailExercise = nil }
                        }
                    }
            }
            .modifier(ExercisePickerSheetPresentation())
        }
        .sheet(item: $mediaExercise) { exercise in
            ExerciseMediaSheet(exercise: exercise)
        }
        .onChange(of: mediaFeedback) { _ in
            if SettingsStore.shared.workoutHaptics {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
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
                    Label("No matching exercises", systemImage: "line.3.horizontal.decrease")
                } description: {
                    Text("Try a different muscle group or equipment.")
                } actions: {
                    clearFiltersButton
                }
            }
        } else {
            VStack(spacing: 8) {
                if hasSearch {
                    Text("No results for \"\(search)\"").font(.headline)
                } else {
                    Label("No matching exercises", systemImage: "line.3.horizontal.decrease").font(.headline)
                    Text("Try a different muscle group or equipment.")
                        .font(.subheadline)
                        .foregroundStyle(IronTheme.secondaryText)
                    clearFiltersButton
                }
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.vertical, 16)
            .accessibilityElement(children: .combine)
        }
    }

    private var clearFiltersButton: some View {
        Button("Clear Filters") {
            selectedMuscleGroup = nil
            selectedEquipment = nil
        }
    }

    @ViewBuilder
    private func exerciseRow(_ exercise: Exercise) -> some View {
        let selectionNumber = exerciseSelectorSelection.firstIndex(of: exercise).map { $0 + 1 }
        let metadata = ExerciseLibraryMetadata(
            exercise: exercise,
            lastPerformed: exerciseStore.lastPerformedDates[exercise.uuid]
        )

        let row = Button(action: { toggle(exercise) }) {
            HStack(spacing: 12) {
                selectionIndicator(number: selectionNumber)

                ExerciseDiagramThumbnail(exercise: exercise, size: 44)
                    .contentShape(Circle())
                    // A hold consumes the touch; only a short tap opens details.
                    // Movement cancels the hold so the List can scroll.
                    .highPriorityGesture(
                        LongPressGesture(minimumDuration: 0.4, maximumDistance: 10)
                            .exclusively(before: TapGesture())
                            .onEnded { result in
                                switch result {
                                case .first:
                                    guard exercise.hasPlayableDemonstration else { return }
                                    mediaExercise = exercise
                                    mediaFeedback += 1
                                case .second:
                                    detailExercise = exercise
                                }
                            }
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

        if exercise.hasPlayableDemonstration {
            row.accessibilityAction(named: Text("Play Demonstration")) {
                mediaExercise = exercise
            }
        } else {
            row
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

private struct ExercisePickerNavigation<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @ViewBuilder var body: some View {
        if #available(iOS 16, *) {
            NavigationStack { content }
        } else {
            NavigationView { content }
                .navigationViewStyle(.stack)
        }
    }
}

private struct ExercisePickerScrollEdge: ViewModifier {
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

private struct ExercisePickerListMargins: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 17, *) {
            content.contentMargins(.horizontal, 10, for: .scrollContent)
        } else {
            content
        }
    }
}

private struct ExercisePickerSheetPresentation: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 16, *) {
            content.presentationDetents([.large]).presentationDragIndicator(.visible)
        } else {
            content
        }
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
