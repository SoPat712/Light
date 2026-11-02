//
//  CreateCustomExerciseView.swift
//  Iron
//
//  Created by Karim Abou Zeid on 17.09.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import SwiftUI
import WorkoutDataKit

struct CustomExerciseSaveFailure: Identifiable {
    let id = UUID()
    let error: Error
}

struct EditCustomExerciseView: View {
    struct ExerciseValues {
        var title: String
        var description: String
        var muscles: Set<ExerciseMuscle>
        var type: Exercise.ExerciseType
        var stepsText: String = ""
        var tipsText: String = ""

        var steps: [String] {
            Self.instructionItems(from: stepsText)
        }

        var tips: [String] {
            Self.instructionItems(from: tipsText)
        }

        private static func instructionItems(from text: String) -> [String] {
            text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        
        struct ExerciseMuscle: Hashable {
            enum MuscleType: CaseIterable, Hashable {
                case primary
                case secondary

                var title: String {
                    switch self {
                    case .primary: return "Primary"
                    case .secondary: return "Secondary"
                    }
                }
            }
            
            let type: MuscleType
            let muscle: String
        }
    }
    
    @Binding var exerciseValues: ExerciseValues
    @State private var selectionFeedback = 0
    var titleValidationMessage: String? = nil
    var onSelectMuscles: () -> Void = {}
    
    private var primaryMuscles: [ExerciseValues.ExerciseMuscle] {
        exerciseValues.muscles
            .map { $0 }
            .sorted { $0.shortDisplayTitle < $1.shortDisplayTitle }
            .filter { $0.type == .primary }
    }
    
    private var secondaryMuscles: [ExerciseValues.ExerciseMuscle] {
        exerciseValues.muscles
            .map { $0 }
            .sorted { $0.shortDisplayTitle < $1.shortDisplayTitle }
            .filter { $0.type == .secondary }
    }

    private var hasPrimaryMuscle: Bool {
        !primaryMuscles.isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $exerciseValues.title)
                    .textInputAutocapitalization(.words)

                TextField("Description", text: $exerciseValues.description, axis: .vertical)
                    .lineLimit(1...4)
            } header: {
                Text("Exercise")
            } footer: {
                if let titleValidationMessage {
                    Text(titleValidationMessage)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button(action: onSelectMuscles) {
                    LabeledContent("Muscles") {
                        Text(muscleSummary)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Picker("Equipment", selection: Binding(
                    get: { exerciseValues.type },
                    set: {
                        guard exerciseValues.type != $0 else { return }
                        exerciseValues.type = $0
                        selectionFeedback += 1
                    }
                )) {
                    ForEach(Exercise.ExerciseType.allCases, id: \.self) { type in
                        Text(type.title.capitalized).tag(type)
                    }
                }
                .sensoryFeedback(.selection, trigger: selectionFeedback) { _, _ in SettingsStore.shared.workoutHaptics }
            } header: {
                Text("Classification")
            } footer: {
                Text(hasPrimaryMuscle
                     ? "Equipment controls rest defaults and barbell tools."
                     : "A primary muscle is required to power muscle maps and statistics.")
            }

            Section {
                TextField("One instruction per line", text: $exerciseValues.stepsText, axis: .vertical)
                    .lineLimit(3...8)
            } header: {
                Text("Steps")
            }

            Section {
                TextField("One coaching cue per line", text: $exerciseValues.tipsText, axis: .vertical)
                    .lineLimit(3...8)
            } header: {
                Text("Coach Cues")
            } footer: {
                Text("Steps and cues appear in the exercise’s How To section.")
            }
        }
    }

    private var muscleSummary: String {
        if primaryMuscles.isEmpty && secondaryMuscles.isEmpty {
            return "None"
        }

        var parts: [String] = []
        if !primaryMuscles.isEmpty {
            parts.append(primaryMuscles.map(\.shortDisplayTitle).joined(separator: ", "))
        }
        if !secondaryMuscles.isEmpty {
            parts.append("+\(secondaryMuscles.count) secondary")
        }
        return parts.joined(separator: " · ")
    }
}


extension EditCustomExerciseView.ExerciseValues.ExerciseMuscle {
    var shortDisplayTitle: String {
        let title = Exercise.commonMuscleName(for: muscle) ?? "other"
        return title.capitalized
    }
    
    var displayTitle: String {
        var title = shortDisplayTitle
        if title.lowercased() != muscle.lowercased() {
            title.append(" (\(muscle))")
        }
        return title.capitalized
    }
}

struct MuscleSelectionView: View {
    private struct MuscleOption: Identifiable, Hashable {
        let id: String
        let title: String
        let aliases: [String]
    }

    var muscles: [String]
    @Binding var selection: Set<EditCustomExerciseView.ExerciseValues.ExerciseMuscle>

    @State private var activeRole: EditCustomExerciseView.ExerciseValues.ExerciseMuscle.MuscleType = .primary
    @State private var search = ""

    private var options: [MuscleOption] {
        let grouped = Dictionary(grouping: muscles) { muscle in
            canonicalName(for: muscle)
        }

        return grouped.map { name, aliases in
            MuscleOption(
                id: name,
                title: name.capitalized,
                aliases: aliases.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var filteredOptions: [MuscleOption] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return options }
        return options.filter { option in
            option.title.localizedCaseInsensitiveContains(query) ||
                option.aliases.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var primaryCount: Int {
        selectedOptionCount(for: .primary)
    }

    private var secondaryCount: Int {
        selectedOptionCount(for: .secondary)
    }

    var body: some View {
        List {
            Section {
                Picker("Adding As", selection: $activeRole) {
                    ForEach(EditCustomExerciseView.ExerciseValues.ExerciseMuscle.MuscleType.allCases, id: \.self) { role in
                        Text(role.title).tag(role)
                    }
                }
                .pickerStyle(.segmented)
                .sensoryFeedback(.selection, trigger: activeRole) { _, _ in SettingsStore.shared.workoutHaptics }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            } footer: {
                Text("\(primaryCount) primary · \(secondaryCount) secondary. A muscle can only have one role.")
            }

            Section(search.isEmpty ? "All Muscles" : "Results") {
                if filteredOptions.isEmpty {
                    ContentUnavailableView.search(text: search)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(filteredOptions) { option in
                        muscleRow(option)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "Search Muscles")
    }

    private func muscleRow(_ option: MuscleOption) -> some View {
        let selectedRole = role(for: option)

        return Button {
            toggle(option)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .foregroundStyle(.primary)
                    if let selectedRole {
                        Text(selectedRole.title)
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                }

                Spacer()

                if selectedRole != nil {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
        }
        .accessibilityValue(selectedRole.map { "Selected as \($0.title.lowercased())" } ?? "Not selected")
        .accessibilityHint("Adds or removes this muscle as \(activeRole.title.lowercased())")
    }

    private func canonicalName(for muscle: String) -> String {
        (Exercise.commonMuscleName(for: muscle) ?? muscle)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func role(
        for option: MuscleOption
    ) -> EditCustomExerciseView.ExerciseValues.ExerciseMuscle.MuscleType? {
        if selection.contains(where: { canonicalName(for: $0.muscle) == option.id && $0.type == .primary }) {
            return .primary
        }
        if selection.contains(where: { canonicalName(for: $0.muscle) == option.id && $0.type == .secondary }) {
            return .secondary
        }
        return nil
    }

    private func selectedOptionCount(
        for role: EditCustomExerciseView.ExerciseValues.ExerciseMuscle.MuscleType
    ) -> Int {
        Set(selection.compactMap { muscle in
            muscle.type == role ? canonicalName(for: muscle.muscle) : nil
        }).count
    }

    private func toggle(_ option: MuscleOption) {
        let existing = selection.filter { canonicalName(for: $0.muscle) == option.id }
        let wasSelectedForActiveRole = existing.contains { $0.type == activeRole }
        let preservedRawValue = existing.first?.muscle

        selection.subtract(existing)

        if !wasSelectedForActiveRole {
            let representative = preservedRawValue
                ?? option.aliases.first(where: { $0.localizedCaseInsensitiveCompare(option.id) == .orderedSame })
                ?? option.aliases.first

            if let representative = representative {
                selection.insert(
                    EditCustomExerciseView.ExerciseValues.ExerciseMuscle(
                        type: activeRole,
                        muscle: representative
                    )
                )
            }
        }

        let feedback = UISelectionFeedbackGenerator()
        feedback.prepare()
        feedback.selectionChanged()
    }
}


#if DEBUG
struct CreateCustomExerciseView_Previews: PreviewProvider {
    static var previews: some View {
        EditCustomExerciseView(exerciseValues: .constant(.init(title: "", description: "", muscles: Set(), type: .other)))
            .mockEnvironment(weightUnit: .metric)
    }
}
#endif
