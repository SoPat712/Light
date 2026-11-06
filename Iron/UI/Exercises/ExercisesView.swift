//
//  ExercisesView.swift
//  Sunrise Fit
//
//  Created by Karim Abou Zeid on 04.07.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import SwiftUI
import UIKit
import ImageIO
import WorkoutDataKit

private struct ExerciseThumbnailRequest: Hashable, Sendable {
    let url: URL
    let pixelSize: Int
}

/// The cached CGImage has already been downsampled and decoded. Creating its
/// UIImage on the main actor never defers compressed-image work to scrolling.
private actor ExerciseThumbnailCache {
    static let shared = ExerciseThumbnailCache()

    private let images: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 128
        cache.totalCostLimit = 16 * 1_024 * 1_024
        return cache
    }()
    private var pending: [ExerciseThumbnailRequest: Task<CGImage?, Never>] = [:]

    func image(for request: ExerciseThumbnailRequest) async -> CGImage? {
        let key = "\(request.url.absoluteString)|\(request.pixelSize)" as NSString
        if let image = images.object(forKey: key) { return image }
        if let task = pending[request] { return await task.value }

        let task = Task.detached(priority: .utility) {
            guard let data = await ExerciseMediaStore.shared.stillData(for: request.url),
                  let source = CGImageSourceCreateWithData(data as CFData, [
                    kCGImageSourceShouldCache: false
                  ] as CFDictionary) else { return nil as CGImage? }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: request.pixelSize,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        }
        pending[request] = task
        let image = await task.value
        pending[request] = nil
        if let image {
            images.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        }
        return image
    }
}

struct ExerciseDiagramThumbnail: View {
    @Environment(\.displayScale) private var displayScale
    let exercise: Exercise
    var size: CGFloat = 58

    @State private var loadedRequest: ExerciseThumbnailRequest?
    @State private var loadedImage: UIImage?

    private var request: ExerciseThumbnailRequest? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ironHideExerciseArt") { return nil }
        #endif
        guard let url = exercise.imageURL else { return nil }
        return ExerciseThumbnailRequest(url: url, pixelSize: max(Int(min(size * displayScale, 240).rounded(.up)), 1))
    }

    var body: some View {
        let request = request
        ZStack {
            Circle()
                .fill(IronTheme.diagramCanvas)
            if loadedRequest == request, let loadedImage {
                Image(uiImage: loadedImage)
                    .resizable()
                    .scaledToFit()
                    // Keep wide machine/cable movements inside the same canvas.
                    .frame(width: size * 0.66, height: size * 0.66)
            } else {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(IronTheme.secondaryText)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(IronTheme.outline.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: IronTheme.mediaBackdrop.opacity(0.08), radius: 2, x: 0, y: 1)
        .task(id: request) {
            guard let request else {
                loadedRequest = nil
                loadedImage = nil
                return
            }
            let image = await ExerciseThumbnailCache.shared.image(for: request)
            guard !Task.isCancelled else { return }
            loadedImage = image.map { UIImage(cgImage: $0) }
            loadedRequest = request
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

    @State private var showingMedia = false
    @State private var mediaFeedback = 0

    private var lastPerformed: Date? {
        exerciseStore.lastPerformedDates[exercise.uuid]
    }

    private var metadata: ExerciseLibraryMetadata {
        ExerciseLibraryMetadata(exercise: exercise, lastPerformed: lastPerformed)
    }

    @ViewBuilder
    var body: some View {
        if exercise.hasPlayableDemonstration {
            row.accessibilityAction(named: Text("Play Demonstration")) {
                showingMedia = true
            }
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            ExerciseDiagramThumbnail(exercise: exercise, size: 48)
                .contentShape(Circle())
                // Recognized holds consume the enclosing link's tap. Movement
                // cancels the hold so the List can scroll from the thumbnail.
                .highPriorityGesture(
                    LongPressGesture(minimumDuration: 0.4, maximumDistance: 10)
                        .onEnded { _ in
                            showingMedia = true
                            mediaFeedback += 1
                        },
                    including: exercise.hasPlayableDemonstration ? .all : .none
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metadata.accessibilityLabel)
        .sheet(isPresented: $showingMedia) {
            ExerciseMediaSheet(exercise: exercise)
        }
        .onChange(of: mediaFeedback) { _ in
            if SettingsStore.shared.workoutHaptics {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
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
            ForEach(exerciseGroups[0].exercises, id: \.self, content: row)
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
