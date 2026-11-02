//
//  ExercisesView.swift
//  Sunrise Fit
//
//  Created by Karim Abou Zeid on 04.07.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import SwiftUI
import WorkoutDataKit

struct ExerciseDiagramThumbnail: View {
    let exercise: Exercise
    var size: CGFloat = 58

    @State private var loadedRemoteMediaURL: URL?

    var body: some View {
        ZStack {
            Circle()
                .fill(IronTheme.diagramCanvas)
            if exercise.imageURL == nil || loadedRemoteMediaURL != exercise.imageURL {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(IronTheme.secondaryText)
            }
            if let remoteURL = exercise.imageURL {
                ExerciseRemoteMediaView(
                    url: remoteURL,
                    animated: false,
                    targetPixelSize: min(size * UIScreen.main.scale, 240),
                    onLoaded: { loadedRemoteMediaURL = remoteURL }
                )
                // Keep the complete movement canvas inside the circular mask.
                // Several wide machine/cable frames reach all four corners,
                // so the usual 1/sqrt(2) circle fit is still too tight.
                .frame(width: size * 0.66, height: size * 0.66)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(IronTheme.outline.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: IronTheme.mediaBackdrop.opacity(0.08), radius: 2, x: 0, y: 1)
        .onChange(of: exercise.imageURL) { _, newURL in
            if loadedRemoteMediaURL != newURL {
                loadedRemoteMediaURL = nil
            }
        }
        .accessibilityHidden(true)
    }
}

struct ExerciseLibraryTag: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(IronTheme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(IronTheme.field, in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Shared plain-text metadata for library and selection rows.
@MainActor
struct ExerciseLibraryMetadata {
    let exercise: Exercise
    let lastPerformed: Date?

    private var muscleTitle: String {
        exercise.primaryMuscleCommonName.first?.capitalized ?? exercise.muscleGroup.capitalized
    }

    private var details: [String] {
        [muscleTitle, exercise.equipment.first?.equipmentTitle].compactMap { $0 }
    }

    var title: String {
        (details + (lastPerformed.map { [ExerciseRecencyCaption.title(for: $0)] } ?? []))
            .joined(separator: " · ")
    }

    var accessibilityLabel: String {
        let recency = lastPerformed.map { ["last done \(ExerciseRecencyCaption.title(for: $0).lowercased())"] } ?? []
        return ([exercise.title] + details + recency).joined(separator: ", ")
    }
}

struct ExerciseLibraryRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var exerciseStore: ExerciseStore

    let exercise: Exercise

    private var lastPerformed: Date? {
        exerciseStore.lastPerformedDates[exercise.uuid]
    }

    private var metadata: ExerciseLibraryMetadata {
        ExerciseLibraryMetadata(exercise: exercise, lastPerformed: lastPerformed)
    }

    var body: some View {
        HStack(spacing: 12) {
            ExerciseDiagramThumbnail(exercise: exercise, size: 48)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metadata.accessibilityLabel)
    }
}

/// A single formatter keeps relative ages consistent across the library and picker.
struct ExerciseRecencyCaption: View {
    let date: Date

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter
    }()

    static func title(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        Text(Self.title(for: date))
            .font(.caption.weight(.semibold))
            .foregroundStyle(IronTheme.secondaryText)
            .fixedSize()
            .accessibilityLabel("Last performed \(Self.title(for: date))")
    }
}

struct ExercisesView : View {
    @EnvironmentObject private var exerciseStore: ExerciseStore
    var exercises: [Exercise]
    
    var body: some View {
        List(exerciseStore.orderedByRecency(exercises), id: \.id) { exercise in
            NavigationLink(destination: ExerciseDetailView(exercise: exercise)) {
                ExerciseLibraryRow(exercise: exercise)
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.horizontal, 10, for: .scrollContent)
    }
}

/// Shared content for grouped library and selection lists. Search is represented
/// by a single untitled group; browsing keeps the existing sections after Recent.
struct ExerciseRecencyListContent<Row: View>: View {
    @EnvironmentObject private var exerciseStore: ExerciseStore
    let exerciseGroups: [ExerciseGroup]
    @ViewBuilder var row: (Exercise) -> Row

    private var isSearchResult: Bool {
        exerciseGroups.count == 1 && exerciseGroups[0].title.isEmpty
    }

    private var recentExercises: [Exercise] {
        exerciseStore.orderedByRecency(exerciseGroups.flatMap(\.exercises))
            .filter { exerciseStore.lastPerformedDates[$0.uuid] != nil }
    }

    var body: some View {
        if isSearchResult {
            ForEach(exerciseStore.orderedByRecency(exerciseGroups[0].exercises), id: \.self, content: row)
        } else {
            let recent = recentExercises
            if !recent.isEmpty {
                Section("Recent") {
                    ForEach(recent, id: \.self, content: row)
                }
            }
            ForEach(exerciseGroups) { group in
                let remaining = group.exercises.filter { exerciseStore.lastPerformedDates[$0.uuid] == nil }
                if !remaining.isEmpty {
                    Section(group.title.capitalized) {
                        ForEach(remaining, id: \.self, content: row)
                    }
                }
            }
        }
    }
}

#if DEBUG
struct ExercisesView_Previews : PreviewProvider {
    static var previews: some View {
        NavigationView {
            ExercisesView(exercises: ExerciseStore.shared.shownExercises)
                .mockEnvironment(weightUnit: .metric)
        }
    }
}
#endif
