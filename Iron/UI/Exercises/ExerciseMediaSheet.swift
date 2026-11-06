import SwiftUI
import UIKit
import WorkoutDataKit

extension Exercise {
    /// Matches the detail header's play badge: an animation, or multiple local
    /// frames when there is no remote media taking precedence.
    var hasPlayableDemonstration: Bool {
        animationURL != nil || (imageURL == nil && pdfPaths.count > 1)
    }
}

private final class ExercisePDFFrameCache {
    final class Entry {
        let images: [UIImage]

        init(images: [UIImage]) {
            self.images = images
        }
    }

    static let shared = ExercisePDFFrameCache()
    let entries = NSCache<NSString, Entry>()
}

struct ExerciseMediaSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var exerciseStore: ExerciseStore

    let exercise: Exercise

    @State private var loadedRemoteMediaURL: URL?

    private var currentExercise: Exercise {
        exerciseStore.find(with: exercise.uuid) ?? exercise
    }

    private var currentRemoteMediaURL: URL? {
        currentExercise.animationURL ?? currentExercise.imageURL
    }

    private func pdfToImage(url: URL, fit: CGSize) -> UIImage? {
        guard fit.width.isFinite,
              fit.height.isFinite,
              fit.width > 0,
              fit.height > 0 else { return nil }
        guard let document = CGPDFDocument(url as CFURL) else { return nil }
        guard let page = document.page(at: 1) else { return nil }
        
        let pageRect = page.getBoxRect(.mediaBox)
        guard pageRect.width > 0, pageRect.height > 0 else { return nil }
        let scale = min(fit.width / pageRect.width, fit.height / pageRect.height)
        let size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        guard scale.isFinite,
              scale > 0,
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else { return nil }
        
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            // flip
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: 1, y: -1)
            
            // aspect fit
            ctx.cgContext.scaleBy(x: scale, y: scale)
            
            // draw
            ctx.cgContext.drawPDFPage(page)
        }
        
        return img
    }

    private func exerciseImages(width: CGFloat, height: CGFloat) -> [UIImage] {
        let cacheKey = "\(currentExercise.uuid.uuidString)|\(Int(width.rounded(.up)))x\(Int(height.rounded(.up)))" as NSString
        if let cached = ExercisePDFFrameCache.shared.entries.object(forKey: cacheKey) {
            return cached.images
        }

        let images = currentExercise.pdfPaths
            .map { ExerciseStore.defaultBuiltInExercisesResourceURL.appendingPathComponent($0) }
            .compactMap { pdfToImage(url: $0, fit: CGSize(width: width, height: height)) }
            // The diagram always sits on a white media canvas. Dynamic
            // `label` becomes white in dark mode and made the fallback
            // illustration disappear whenever remote media was unavailable.
            .compactMap { $0.tinted(with: UIColor(IronTheme.mediaBackdrop).withAlphaComponent(0.82)) }

        ExercisePDFFrameCache.shared.entries.setObject(
            ExercisePDFFrameCache.Entry(images: images),
            forKey: cacheKey
        )
        return images
    }
    
    /// The provider's diagram canvas is intentionally fixed white; the media
    /// keeps a continuous corner and no decorative stroke so it reads as a hero
    /// rather than another bordered card.
    private var mediaHero: some View {
        GeometryReader { geometry in
            ZStack {
                IronTheme.diagramCanvas

                if currentRemoteMediaURL == nil || loadedRemoteMediaURL != currentRemoteMediaURL {
                    if currentRemoteMediaURL == nil, !currentExercise.pdfPaths.isEmpty {
                        AnimatedImageView(
                            uiImages: exerciseImages(width: geometry.size.width, height: geometry.size.height),
                            duration: 2,
                            contentKey: currentExercise.uuid.uuidString
                        )
                        .padding(16)
                    } else {
                        Image(systemName: "figure.strengthtraining.traditional")
                            .font(.system(size: 72, weight: .semibold))
                            .foregroundStyle(IronTheme.secondaryText)
                    }
                }

                if let animationURL = currentExercise.animationURL {
                    ExerciseRemoteMediaView(
                        url: animationURL,
                        animated: true,
                        targetPixelSize: min(geometry.size.width * UIScreen.main.scale, 1_200),
                        onLoaded: { loadedRemoteMediaURL = animationURL }
                    )
                    // Match the thumbnail's conservative optical fit. Some
                    // animation frames extend farther than their first frame,
                    // especially on cable and machine exercises.
                    .scaleEffect(0.69)
                } else if let imageURL = currentExercise.imageURL {
                    ExerciseRemoteMediaView(
                        url: imageURL,
                        animated: false,
                        targetPixelSize: min(geometry.size.width * UIScreen.main.scale, 1_200),
                        onLoaded: { loadedRemoteMediaURL = imageURL }
                    )
                    .scaleEffect(0.69)
                }
            }
        }
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: IronTheme.heroCornerRadius, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if currentRemoteMediaURL != nil {
                Link(destination: URL(string: "https://gymvisual.com/")!) {
                    Text(Exercise.mediaAttribution)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(IronTheme.secondaryText)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                }
                .tint(IronTheme.secondaryText)
                .padding(10)
                .accessibilityLabel("Exercise media by Gym Visual")
            }
        }
        .onChange(of: currentRemoteMediaURL) { _, newURL in
            if loadedRemoteMediaURL != newURL {
                loadedRemoteMediaURL = nil
            }
        }
    }

    var body: some View {
        NavigationStack {
            mediaHero
                .padding(IronTheme.horizontalPadding)
                .navigationTitle(currentExercise.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                            .labelStyle(.iconOnly)
                            .accessibilityLabel("Close exercise media")
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

