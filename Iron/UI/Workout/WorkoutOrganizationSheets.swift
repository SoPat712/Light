import SwiftUI
import CoreData
import WorkoutDataKit

/// Sheet for choosing the members of a superset without mutating the workout
/// until the parent confirms the transaction.
struct WorkoutSupersetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var exerciseStore: ExerciseStore

    let source: WorkoutExercise
    let exercises: [WorkoutExercise]
    let onSave: (Set<NSManagedObjectID>) -> Bool
    let onRemove: (() -> Bool)?

    @State private var selectedPartnerIDs: Set<NSManagedObjectID>

    init(
        source: WorkoutExercise,
        exercises: [WorkoutExercise],
        onSave: @escaping (Set<NSManagedObjectID>) -> Bool,
        onRemove: (() -> Bool)? = nil
    ) {
        self.source = source
        self.exercises = exercises
        self.onSave = onSave
        self.onRemove = onRemove

        let sourceID = source.objectID
        let sourceGroupID = source.supersetUuid
        let initialSelection: Set<NSManagedObjectID>
        if let sourceGroupID {
            initialSelection = Set(
                exercises
                    .filter {
                        $0.objectID != sourceID
                            && !$0.isDeleted
                            && $0.supersetUuid == sourceGroupID
                    }
                    .map(\.objectID)
            )
        } else {
            initialSelection = []
        }
        _selectedPartnerIDs = State(initialValue: initialSelection)
    }

    private var sourceID: NSManagedObjectID {
        source.objectID
    }

    private var orderedWorkoutExercises: [WorkoutExercise] {
        var result: [WorkoutExercise] = []
        var seenIDs = Set<NSManagedObjectID>()

        for workoutExercise in exercises where !workoutExercise.isDeleted {
            guard seenIDs.insert(workoutExercise.objectID).inserted else { continue }
            result.append(workoutExercise)
        }

        // Callers normally provide the source in the workout's ordered array.
        // Keeping this fallback first preserves a useful source/member order
        // for previews when a focused source is supplied separately.
        if !seenIDs.contains(sourceID), !source.isDeleted {
            result.insert(source, at: 0)
        }
        return result
    }

    private var candidateExercises: [WorkoutExercise] {
        orderedWorkoutExercises.filter { $0.objectID != sourceID }
    }

    private var selectedMembers: [WorkoutExercise] {
        orderedWorkoutExercises.filter {
            $0.objectID == sourceID || selectedPartnerIDs.contains($0.objectID)
        }
    }

    private var actionTitle: String {
        source.supersetUuid == nil ? "Create Superset" : "Save Superset"
    }

    private var previewItems: [WorkoutSetOrderPreviewItem] {
        guard !selectedPartnerIDs.isEmpty else { return [] }
        let members = selectedMembers
        let maximumSetCount = members.map { setCount(for: $0) }.max() ?? 0
        guard maximumSetCount > 0 else { return [] }

        return (0..<maximumSetCount).flatMap { roundIndex in
            members.enumerated().compactMap { memberIndex, member in
                guard setCount(for: member) > roundIndex else { return nil }
                return WorkoutSetOrderPreviewItem(
                    memberIndex: memberIndex,
                    setNumber: roundIndex + 1,
                    title: member.exercise(in: exerciseStore.exercises)?.title ?? "Unknown Exercise"
                )
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Starting Exercise") {
                    WorkoutOrganizationExerciseInfo(
                        workoutExercise: source,
                        exercise: source.exercise(in: exerciseStore.exercises),
                        marker: marker(for: source)
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(startingExerciseAccessibilityLabel)
                }

                Section {
                    if previewItems.isEmpty {
                        Text(selectedPartnerIDs.isEmpty
                             ? "Choose a partner to preview the alternating order."
                             : "Add target sets to preview the alternating order.")
                            .font(.body)
                            .foregroundStyle(IronTheme.secondaryText)
                            .frame(minHeight: IronTheme.controlHeight, alignment: .leading)
                    } else {
                        previewSequence
                    }
                } header: {
                    Text("Set Order Preview")
                } footer: {
                    Text("Rounds follow workout order; exercises without a set in a round are skipped.")
                }

                Section {
                    if candidateExercises.isEmpty {
                        Text("Add another exercise to create a superset.")
                            .font(.body)
                            .foregroundStyle(IronTheme.secondaryText)
                            .frame(minHeight: IronTheme.controlHeight, alignment: .leading)
                    } else {
                        ForEach(candidateExercises, id: \.objectID) { candidate in
                            candidateRow(candidate)
                        }
                    }
                } header: {
                    Text("Pair With")
                } footer: {
                    Text("Selecting an exercise from another superset includes that whole group.")
                }

                if onRemove != nil {
                    Section {
                        Button(role: .destructive, action: removeSuperset) {
                            Label("Remove from Superset", systemImage: "link")
                                .font(.body)
                                .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.horizontal, 10, for: .scrollContent)
            .sensoryFeedback(.selection, trigger: selectedPartnerIDs) { _, _ in SettingsStore.shared.workoutHaptics }
            .navigationTitle("Superset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(selectedPartnerIDs.isEmpty)
                        .accessibilityLabel(actionTitle)
                }
            }
        }
    }

    @ViewBuilder
    private func candidateRow(_ candidate: WorkoutExercise) -> some View {
        let isSelected = selectedPartnerIDs.contains(candidate.objectID)
        Button {
            withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) {
                toggle(candidate)
            }
        } label: {
            HStack(spacing: 8) {
                WorkoutOrganizationExerciseInfo(
                    workoutExercise: candidate,
                    exercise: candidate.exercise(in: exerciseStore.exercises),
                    marker: marker(for: candidate)
                )

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(.semibold))
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                    .foregroundStyle(isSelected ? IronTheme.accent : IronTheme.tertiaryText)
                    .frame(width: IronTheme.iconButtonSize, height: IronTheme.controlHeight)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "Selected, exercise \(marker(for: candidate) ?? "")" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(selectionHint(for: candidate))
    }

    /// Names once in a legend, then the whole alternating order as short
    /// A1 · B1 · A2 chips, so long exercise names never wrap inside the sequence.
    private var previewSequence: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(selectedMembers.enumerated()), id: \.offset) { index, member in
                    HStack(spacing: 8) {
                        WorkoutSupersetLetterBadge(letter: memberMarker(for: index), memberIndex: index)
                        Text(member.exercise(in: exerciseStore.exercises)?.title ?? "Unknown Exercise")
                            .font(.subheadline)
                            .foregroundStyle(IronTheme.primaryText)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    }
                }
            }

            ExerciseChipFlowLayout(spacing: 6) {
                ForEach(Array(previewItems.enumerated()), id: \.offset) { _, item in
                    WorkoutSetOrderPreviewChip(
                        marker: memberMarker(for: item.memberIndex),
                        memberIndex: item.memberIndex,
                        setNumber: item.setNumber
                    )
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(previewAccessibilityLabel)
    }

    private var previewAccessibilityLabel: String {
        let sequence = previewItems.map {
            "\(memberMarker(for: $0.memberIndex))\($0.setNumber) \($0.title)"
        }
        return sequence.isEmpty ? "No set order preview" : "Set order: " + sequence.joined(separator: ", then ")
    }

    private var startingExerciseAccessibilityLabel: String {
        let title = source.exercise(in: exerciseStore.exercises)?.title ?? "Unknown Exercise"
        let count = setCount(for: source)
        let order = marker(for: source).map { ", exercise \($0)" } ?? ""
        return "Starting exercise, \(title), \(count) \(count == 1 ? "set" : "sets")\(order)"
    }

    private func selectionHint(for candidate: WorkoutExercise) -> String {
        if let candidateGroupID = candidate.supersetUuid,
           candidateGroupID != source.supersetUuid {
            return "Selects or removes the entire existing superset."
        }
        return "Adds or removes this exercise from the superset."
    }

    private func marker(for exercise: WorkoutExercise) -> String? {
        guard !selectedPartnerIDs.isEmpty,
              let index = selectedMembers.firstIndex(where: { $0.objectID == exercise.objectID }) else { return nil }
        return memberMarker(for: index)
    }

    private func memberMarker(for index: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard letters.indices.contains(index) else { return "\(index + 1)" }
        return String(letters[index])
    }

    private func setCount(for workoutExercise: WorkoutExercise) -> Int {
        workoutExercise.workoutSets?.array
            .compactMap { $0 as? WorkoutSet }
            .filter { !$0.isDeleted }
            .count ?? 0
    }

    private func toggle(_ candidate: WorkoutExercise) {
        guard candidate.objectID != sourceID else { return }

        let belongsToSourceGroup = source.supersetUuid != nil
            && candidate.supersetUuid == source.supersetUuid

        if belongsToSourceGroup || candidate.supersetUuid == nil {
            if selectedPartnerIDs.contains(candidate.objectID) {
                selectedPartnerIDs.remove(candidate.objectID)
            } else {
                selectedPartnerIDs.insert(candidate.objectID)
            }
            return
        }

        guard let candidateGroupID = candidate.supersetUuid else { return }
        let groupIDs = Set(
            orderedWorkoutExercises
                .filter { $0.supersetUuid == candidateGroupID && $0.objectID != sourceID }
                .map(\.objectID)
        )

        if selectedPartnerIDs.contains(candidate.objectID) {
            selectedPartnerIDs.subtract(groupIDs)
        } else {
            selectedPartnerIDs.formUnion(groupIDs)
        }
    }

    private func save() {
        guard onSave(selectedPartnerIDs) else { return }
        dismiss()
    }

    private func removeSuperset() {
        guard let onRemove, onRemove() else { return }
        dismiss()
    }
}

/// Compact native editor for the workout's ordered exercise list.
struct WorkoutArrangeExercisesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var exerciseStore: ExerciseStore

    let exercises: [WorkoutExercise]
    let onSave: ([NSManagedObjectID]) -> Bool

    @State private var orderedIDs: [NSManagedObjectID]

    init(
        exercises: [WorkoutExercise],
        onSave: @escaping ([NSManagedObjectID]) -> Bool
    ) {
        self.exercises = exercises
        self.onSave = onSave
        _orderedIDs = State(initialValue: exercises.map(\.objectID))
    }

    private var workoutExerciseByID: [NSManagedObjectID: WorkoutExercise] {
        Dictionary(uniqueKeysWithValues: exercises.map { ($0.objectID, $0) })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(orderedIDs.enumerated()), id: \.element) { index, id in
                        arrangedRow(id: id, index: index)
                    }
                    .onMove(perform: move)
                } footer: {
                    Text("Drag to reorder. Superset relationships stay with their exercises.")
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.horizontal, 10, for: .scrollContent)
            .environment(\.editMode, .constant(.active))
            .sensoryFeedback(.selection, trigger: orderedIDs) { _, _ in SettingsStore.shared.workoutHaptics }
            .navigationTitle("Arrange Exercises")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        orderedIDs.move(fromOffsets: offsets, toOffset: destination)
    }

    private func move(id: NSManagedObjectID, by offset: Int) {
        guard let index = orderedIDs.firstIndex(of: id) else { return }
        let destination = index + offset
        guard orderedIDs.indices.contains(destination) else { return }

        let insertionOffset = offset > 0 ? destination + 1 : destination
        orderedIDs.move(
            fromOffsets: IndexSet(integer: index),
            toOffset: insertionOffset
        )
    }

    private func save() {
        guard onSave(orderedIDs) else { return }
        dismiss()
    }

    private func arrangedRow(id: NSManagedObjectID, index: Int) -> AnyView {
        guard let workoutExercise = workoutExerciseByID[id] else {
            return AnyView(EmptyView())
        }

        let row = WorkoutOrganizationExerciseInfo(
            workoutExercise: workoutExercise,
            exercise: workoutExercise.exercise(in: exerciseStore.exercises)
        )
        let accessibleRow = row
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel(for: workoutExercise))
            .accessibilityHint("Touch and hold, then drag to reorder.")
        let lastIndex = orderedIDs.count - 1

        if index == 0 && index == lastIndex {
            return AnyView(accessibleRow)
        }
        if index == 0 {
            return AnyView(
                accessibleRow.accessibilityAction(named: Text("Move Down")) {
                    move(id: id, by: 1)
                }
            )
        }
        if index == lastIndex {
            return AnyView(
                accessibleRow.accessibilityAction(named: Text("Move Up")) {
                    move(id: id, by: -1)
                }
            )
        }
        return AnyView(
            accessibleRow
                .accessibilityAction(named: Text("Move Up")) {
                    move(id: id, by: -1)
                }
                .accessibilityAction(named: Text("Move Down")) {
                    move(id: id, by: 1)
                }
        )
    }

    private func accessibilityLabel(for workoutExercise: WorkoutExercise) -> String {
        let title = workoutExercise.exercise(in: exerciseStore.exercises)?.title ?? "Unknown Exercise"
        let count = workoutExercise.workoutSets?.array
            .compactMap { $0 as? WorkoutSet }
            .filter { !$0.isDeleted }
            .count ?? 0
        let relation = workoutExercise.supersetUuid == nil ? "" : ", in a superset"
        return "\(title), \(count) \(count == 1 ? "set" : "sets")\(relation)"
    }
}

private struct WorkoutOrganizationExerciseInfo: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let workoutExercise: WorkoutExercise
    let exercise: Exercise?
    var marker: String? = nil

    private var markerIndex: Int {
        marker.flatMap { $0.first?.asciiValue }.map { Int($0) - 65 } ?? 0
    }

    private var setCount: Int {
        workoutExercise.workoutSets?.array
            .compactMap { $0 as? WorkoutSet }
            .filter { !$0.isDeleted }
            .count ?? 0
    }

    private var equipmentTitle: String? {
        guard let exercise, !exercise.equipment.isEmpty else { return nil }
        return exercise.equipment.map(\.equipmentTitle).joined(separator: ", ")
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    thumbnail
                    details
                }
            } else {
                HStack(spacing: 12) {
                    thumbnail
                    details
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight, alignment: .leading)
    }

    private var metaTitle: String {
        let sets = setCount == 1 ? "1 set" : "\(setCount) sets"
        return [sets, equipmentTitle].compactMap { $0 }.joined(separator: " · ")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let marker {
                    WorkoutSupersetLetterBadge(letter: marker, memberIndex: markerIndex)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                }
                Text(exercise?.title ?? "Unknown Exercise")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(IronTheme.primaryText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(metaTitle)
                .font(.subheadline)
                .foregroundStyle(IronTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if marker == nil, workoutExercise.supersetUuid != nil {
                Label("Superset", systemImage: "link")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(IronTheme.accent)
            }
        }
    }

    private var thumbnail: some View {
        Group {
            if let exercise {
                ExerciseDiagramThumbnail(exercise: exercise, size: 40)
            } else {
                Circle()
                    .fill(IronTheme.tertiaryFill)
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "figure.strengthtraining.traditional")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(IronTheme.secondaryText)
                    }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct WorkoutSetOrderPreviewItem {
    let memberIndex: Int
    let setNumber: Int
    let title: String
}

/// The first member reads in accent, later members in neutral fill, so the
/// alternation is visible at a glance without inventing extra colors.
private func supersetMemberIsLead(_ memberIndex: Int) -> Bool {
    memberIndex % 2 == 0
}

private struct WorkoutSupersetLetterBadge: View {
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 22
    let letter: String
    let memberIndex: Int

    var body: some View {
        Text(letter)
            .font(.footnote.weight(.bold))
            .foregroundStyle(supersetMemberIsLead(memberIndex) ? IronTheme.onAccent : IronTheme.primaryText)
            .frame(width: size, height: size)
            .background(
                supersetMemberIsLead(memberIndex) ? IronTheme.accent : IronTheme.tertiaryFill,
                in: Circle()
            )
            .accessibilityHidden(true)
    }
}

private struct WorkoutSetOrderPreviewChip: View {
    let marker: String
    let memberIndex: Int
    let setNumber: Int

    var body: some View {
        Text("\(marker)\(setNumber)")
            .font(.ironMetric(.subheadline, weight: .semibold))
            .foregroundStyle(supersetMemberIsLead(memberIndex) ? IronTheme.accent : IronTheme.primaryText)
            .padding(.horizontal, 10)
            .frame(minWidth: 44, minHeight: 30)
            .background(
                supersetMemberIsLead(memberIndex) ? IronTheme.accentSoft : IronTheme.tertiaryFill,
                in: Capsule()
            )
    }
}
