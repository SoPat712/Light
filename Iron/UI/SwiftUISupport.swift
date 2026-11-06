//
//  SwiftUISupport.swift
//  Iron
//
//  Created by Karim Abou Zeid on 18.09.20.
//  Copyright © 2020 Karim Abou Zeid Software. All rights reserved.
//

import SwiftUI
import Charts
import UIKit
import MuscleMap
import WorkoutDataKit

// Palette and motion live in IronStyle; metric fonts live in IronMetricFont.

/// Flips the binding once a List has scrolled past its first row of the given height (iOS 18+; no-op before).
struct ListHeaderScrollTitleModifier: ViewModifier {
    let headerHeight: CGFloat
    @Binding var isNavigationTitleVisible: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top > headerHeight
                } action: { _, visible in
                    isNavigationTitleVisible = visible
                }
        } else {
            content
        }
    }
}

/// Consistent compact durations and calendar-aware dates for workout lists.
enum LightFormat {
    private struct FormatterKey: Hashable {
        let locale: Locale
        let calendar: Calendar
        let template: String
    }

    private static let formatterLock = NSLock()
    private static var dateFormatters: [FormatterKey: DateFormatter] = [:]
    private static var intervalFormatters: [FormatterKey: DateIntervalFormatter] = [:]

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0m" }
        guard seconds >= 60 else { return "<1m" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }

        // Formatting the whole hours also avoids overflowing Int for large finite intervals.
        let hours = String(format: "%.0f", (seconds / 3_600).rounded(.down))
        let minutes = Int(seconds.truncatingRemainder(dividingBy: 3_600) / 60)
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

    static func listDate(
        _ date: Date?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        guard let date = date else { return "Unknown date" }
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }

        let template = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? "EEE, MMM d" : "MMM d, yyyy"
        let key = FormatterKey(locale: locale, calendar: calendar, template: template)
        formatterLock.lock()
        defer { formatterLock.unlock() }
        let formatter: DateFormatter
        if let cached = dateFormatters[key] {
            formatter = cached
        } else {
            formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            dateFormatters[key] = formatter
        }
        return formatter.string(from: date)
    }

    static func weekTitle(
        start: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        if let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now) {
            if calendar.isDate(start, inSameDayAs: thisWeek.start) { return "This Week" }
            if let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek.start),
               calendar.isDate(start, inSameDayAs: lastWeek) {
                return "Last Week"
            }
        }

        let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        let template = calendar.component(.year, from: end) == calendar.component(.year, from: now)
            ? "MMMd" : "yMMMd"
        let key = FormatterKey(locale: locale, calendar: calendar, template: template)
        formatterLock.lock()
        defer { formatterLock.unlock() }
        let formatter: DateIntervalFormatter
        if let cached = intervalFormatters[key] {
            formatter = cached
        } else {
            formatter = DateIntervalFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateTemplate = template
            intervalFormatters[key] = formatter
        }
        return formatter.string(from: start, to: end)
    }
}

/// The same number/unit hierarchy for summary columns, data rows and chart headlines.
/// A single Text keeps the unit baseline aligned and lets it wrap at accessibility sizes.
struct IronMetricValue: View {
    let value: String
    var unit: String? = nil
    var style: Font.TextStyle = .title2
    var weight: Font.Weight = .bold
    var unitStyle: Font.TextStyle = .footnote
    var tint: Color = IronTheme.primaryText

    var body: some View {
        (Text(value).font(.ironMetric(style, weight: weight)).foregroundColor(tint)
         + Text(unit.map { " " + $0 } ?? "")
            .font(.system(unitStyle).weight(.semibold)).foregroundColor(IronTheme.secondaryText))
    }
}

extension String {
    /// Display form of a catalog equipment key: "ez-curl-bar" → "EZ Curl Bar".
    var equipmentTitle: String {
        let words = replacingOccurrences(of: "-", with: " ").capitalized
        let fixes = ["Ez ": "EZ ", "T Bar": "T-Bar", "Skierg": "SkiErg", "Bosu": "BOSU"]
        return fixes.reduce(words) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }
}

/// Shared inline summary for the same workout wherever it appears in a list.
struct IronWorkoutMetricLine: View {
    let duration: String
    let sets: Int
    let volume: String
    let unit: String

    var body: some View {
        (Text(duration).foregroundColor(IronTheme.primaryText)
         + Text(" · ").foregroundColor(IronTheme.secondaryText)
         + Text("\(sets)").foregroundColor(IronTheme.primaryText)
         + Text(sets == 1 ? " set" : " sets").font(.caption.weight(.semibold)).foregroundColor(IronTheme.secondaryText)
         + Text(" · ").foregroundColor(IronTheme.secondaryText)
         + Text(volume).foregroundColor(IronTheme.primaryText)
         + Text(" \(unit)").font(.caption.weight(.semibold)).foregroundColor(IronTheme.secondaryText))
            .font(.ironMetric(.subheadline, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct IronLiquidGlassPillModifier: ViewModifier {
    let tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(
                .regular.tint(tint).interactive(),
                in: Capsule(style: .continuous)
            )
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(IronTheme.outline.opacity(0.52), lineWidth: 1)
                )
        }
    }
}

extension View {
    /// Shared transparent pill chrome for UI that floats above changing content.
    func ironLiquidGlassPill(
        tint: Color = IronTheme.accent.opacity(0.08)
    ) -> some View {
        modifier(IronLiquidGlassPillModifier(tint: tint))
    }

    /// Glass chrome for hero and summary clusters that sit above scrolling
    /// content. Unlike `IronCard` this is a refracting layer, not an opaque
    /// surface, so it reads as depth instead of another stacked panel.
    func ironLiquidGlassSurface(
        cornerRadius: CGFloat = IronTheme.heroCornerRadius,
        tint: Color = IronTheme.accent.opacity(0.06)
    ) -> some View {
        modifier(IronLiquidGlassSurfaceModifier(cornerRadius: cornerRadius, tint: tint))
    }

    /// Secondary action chrome. Every button that floats over scrolling content
    /// should use this so a screen never mixes glass and flat bordered fills.
    @ViewBuilder
    func ironGlassButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// The single primary action on a surface.
    @ViewBuilder
    func ironProminentGlassButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}

private struct IronLiquidGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(tint), in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(IronTheme.outline.opacity(0.32), lineWidth: 1))
        }
    }
}

private struct IronSetCompletionModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isComplete: Bool
    let feedbackEnabled: Bool
    let tint: Color
    let settledOpacity: Double
    let peakOpacity: Double
    @State private var lastCompletion: Bool
    @State private var fillProgress: CGFloat
    @State private var fillOpacity: Double

    init(isComplete: Bool, feedbackEnabled: Bool, tint: Color, settledOpacity: Double, peakOpacity: Double) {
        self.isComplete = isComplete
        self.feedbackEnabled = feedbackEnabled
        self.tint = tint
        self.settledOpacity = settledOpacity
        self.peakOpacity = peakOpacity
        _lastCompletion = State(initialValue: isComplete)
        _fillProgress = State(initialValue: isComplete ? 1 : 0)
        _fillOpacity = State(initialValue: isComplete ? settledOpacity : 0)
    }

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: IronTheme.compactCornerRadius, style: .continuous)
                    .fill(tint.opacity(fillOpacity))
                    .scaleEffect(x: reduceMotion ? 1 : fillProgress, anchor: .leading)
                    .clipShape(RoundedRectangle(
                        cornerRadius: IronTheme.compactCornerRadius, style: .continuous
                    ))
                    .allowsHitTesting(false)
            }
            .task(id: isComplete) {
                // Existing completed rows appear settled, without replaying feedback.
                guard lastCompletion != isComplete else {
                    fillProgress = isComplete ? 1 : 0
                    fillOpacity = isComplete ? settledOpacity : 0
                    return
                }
                lastCompletion = isComplete
                withAnimation(IronMotion.preferred(IronMotion.collapse, reduceMotion: reduceMotion)) {
                    fillProgress = isComplete ? 1 : 0
                    fillOpacity = isComplete ? (reduceMotion ? settledOpacity : peakOpacity) : 0
                }
                guard isComplete, !reduceMotion else { return }
                do {
                    try await Task.sleep(for: .milliseconds(420))
                } catch {
                    return
                }
                withAnimation(IronMotion.preferred(IronMotion.fade, reduceMotion: reduceMotion)) {
                    fillOpacity = settledOpacity
                }
            }
            .onChange(of: settledOpacity) { _, opacity in
                if isComplete { fillOpacity = opacity }
            }
            .sensoryFeedback(.success, trigger: isComplete) { _, completed in
                completed && feedbackEnabled
            }
    }
}

private struct IronStaggeredEntranceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false
    let index: Int

    func body(content: Content) -> some View {
        content
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared || reduceMotion ? 0 : 8)
            .onAppear {
                withAnimation(IronMotion.preferred(
                    IronMotion.snappy.delay(Double(max(index, 0)) * 0.04),
                    reduceMotion: reduceMotion
                )) {
                    hasAppeared = true
                }
            }
            // Plays once. Resetting on disappear hides List rows that were
            // prefetched off screen and replays the entrance on every scroll.
    }
}

extension View {
    /// Leading accent sweep, faint settled fill, and completion success haptic.
    /// Apply to the row content inside its existing inset; this adds no geometry.
    /// Callers still own check symbols, field states, and the completion label.
    /// Reduce Motion uses a fade and keeps the haptic.
    func ironSetCompletion(
        isComplete: Bool,
        feedbackEnabled: Bool = true,
        tint: Color = IronTheme.accent,
        settledOpacity: Double = 0.12,
        peakOpacity: Double = 0.24
    ) -> some View {
        modifier(IronSetCompletionModifier(
            isComplete: isComplete, feedbackEnabled: feedbackEnabled,
            tint: tint, settledOpacity: settledOpacity, peakOpacity: peakOpacity
        ))
    }

    /// Fades and rises 8 points on appearance, delayed 40 ms per zero-based index.
    /// Reduce Motion uses an immediate short fade without translation or stagger.
    func ironStaggeredEntrance(index: Int) -> some View {
        modifier(IronStaggeredEntranceModifier(index: index))
    }
}

/// Rest countdown ring: pass the fraction remaining (1 = full, 0 = elapsed).
/// Timer state and ticking stay with the caller. Hide from accessibility when
/// the containing pill already announces the remaining time.
struct IronRestRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let progress: Double
    var size: CGFloat = 34
    var tint: Color = IronTheme.metricTime
    var accessibilityLabel: String = "Rest remaining"

    private var fraction: Double {
        progress.isFinite ? min(max(progress, 0), 1) : 0
    }

    var body: some View {
        ZStack {
            Circle().stroke(IronTheme.tertiaryFill, lineWidth: 4)
            if reduceMotion {
                progressArc.id(fraction).transition(.opacity)
            } else {
                progressArc
            }
        }
        .padding(2)
        .frame(width: size, height: size)
        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: fraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }

    private var progressArc: some View {
        Circle()
            .trim(from: 0, to: fraction)
            .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .opacity(fraction > 0 ? 1 : 0)
    }
}

struct IronConfirmationButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var tint: Color = IronTheme.danger

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundColor(IronTheme.onAccent.opacity(isEnabled ? 1 : 0.62))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 50)
            .background(
                RoundedRectangle(cornerRadius: IronTheme.cornerRadius, style: .continuous)
                    .fill(
                        isEnabled
                            ? tint.opacity(configuration.isPressed ? 0.76 : 1)
                            : tint.opacity(0.34)
                    )
            )
            .opacity(configuration.isPressed && isEnabled ? 0.82 : 1)
    }
}

/// Compact Cupertino chrome for workout utilities presented from the bottom.
extension View {
    /// Tapping a number field selects its value, so typing replaces it without a double tap.
    func ironSelectsNumberOnFocus() -> some View {
        onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { notification in
            guard let field = notification.object as? UITextField,
                  field.keyboardType == .decimalPad || field.keyboardType == .numberPad else { return }
            // The tap places its caret after editing begins.
            DispatchQueue.main.async {
                field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
            }
        }
    }
}

struct IronUtilitySheet<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let showsDone: Bool
    let onClose: () -> Void
    private let content: Content

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        showsDone: Bool = true,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.showsDone = showsDone
        self.onClose = onClose
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, IronTheme.horizontalPadding)
                        .padding(.top, 8)
                        .padding(.bottom, 12)
                }

                content
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDone {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onClose)
                    }
                }
            }
        }
        .ironScreen()
    }
}

/// A bottom confirmation surface for consequential actions. Destructive roles
/// use the platform red and the secondary action remains visually quiet.
struct IronConfirmationSheet: View {
    let title: String
    let message: String
    let confirmTitle: String
    var systemImage: String = "exclamationmark.triangle.fill"
    var tint: Color = IronTheme.danger
    var cancelTitle: String = "Cancel"
    var secondaryTitle: String = "Keep current data"
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(tint)
                    .padding(.top, 8)

                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340)

                Spacer(minLength: 0)

                Button(confirmTitle, role: .destructive, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(tint)
                    .frame(maxWidth: .infinity)

                Button(secondaryTitle, action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, IronTheme.horizontalPadding)
            .padding(.top, 14)
            .padding(.bottom, 18)
            .navigationTitle("Confirm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(cancelTitle, action: onCancel)
                }
            }
        }
        .ironScreen()
    }
}

/// A compact bottom-modal result for completed operations and recoverable
/// failures using the same platform hierarchy as other sheets.
struct IronStatusSheet: View {
    @Environment(\.dismiss) private var dismiss

    let headerTitle: String
    let title: String
    let message: String
    let systemImage: String
    let tint: Color
    let actionTitle: String

    init(
        headerTitle: String = "Status",
        title: String,
        message: String,
        systemImage: String,
        tint: Color,
        actionTitle: String = "Done"
    ) {
        self.headerTitle = headerTitle
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.tint = tint
        self.actionTitle = actionTitle
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        Image(systemName: systemImage)
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(tint)
                            .padding(.top, 8)

                        Text(title)
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 340)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, IronTheme.horizontalPadding)
                    .padding(.top, 14)
                    .padding(.bottom, 12)
                }

                Button(actionTitle) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, IronTheme.horizontalPadding)
                    .padding(.top, 12)
                    .padding(.bottom, 18)
            }
            .navigationTitle(headerTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .ironScreen()
        .presentationDetents([.height(390), .medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// A consistent Cupertino date row used anywhere a workout or body entry
/// exposes an editable timestamp.
struct IronDateTimePickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let subtitle: String
    let range: ClosedRange<Date>
    let onApply: (Date) -> Void

    @State private var selection: Date

    init(
        title: String,
        subtitle: String,
        initialDate: Date,
        range: ClosedRange<Date>,
        onApply: @escaping (Date) -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.range = range
        self.onApply = onApply
        _selection = State(initialValue: min(max(initialDate, range.lowerBound), range.upperBound))
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    VStack(spacing: 4) {
                        Text(selection.formatted(date: .complete, time: .omitted))
                            .font(.headline.weight(.semibold))
                            .multilineTextAlignment(.center)
                        Text(selection.formatted(date: .omitted, time: .shortened))
                            .font(.ironMetric(.title2, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    DatePicker(
                        title,
                        selection: $selection,
                        in: range,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .labelsHidden()
                    .datePickerStyle(.wheel)
                    .frame(height: 190)
                    .clipped()
                }
                .padding(.horizontal, IronTheme.horizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onApply(selection)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .ironScreen()
        .presentationDetents([.height(450), .large])
        .presentationDragIndicator(.visible)
    }
}

/// Four slanted tiers, with one dot for each whole-number session rating.
struct EffortRatingGraph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Binding var rating: Int
    var allowsUnrated: Bool = false
    @ScaledMetric(relativeTo: .caption) private var levelLabelHeight: CGFloat = 18
    @State private var selectionFeedback = 0
    private static let levelGap: CGFloat = 4
    private static let tierGap: CGFloat = 12

    private var userRating: Binding<Int> {
        Binding(get: { rating }, set: {
            guard rating != $0 else { return }
            rating = $0
            selectionFeedback += 1
        })
    }

    private var tier: EffortTierPalette { .tier(for: rating) }
    private var readoutColor: Color {
        rating == 0 ? IronTheme.secondaryText : tier.textColor(in: colorScheme)
    }

    var body: some View {
        VStack(spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) { readout }
                VStack(spacing: 4) { readout }
            }
            .foregroundStyle(readoutColor)
            .accessibilityHidden(true)

            VStack(spacing: 6) {
                GeometryReader { proxy in
                    let layout = EffortLevelLayout(width: proxy.size.width, levelGap: Self.levelGap, tierGap: Self.tierGap)
                    ZStack(alignment: .leading) {
                        EffortLevelBars(rating: rating, levelGap: Self.levelGap, tierGap: Self.tierGap,
                                        cornerRadius: 7, inactiveColor: IronTheme.solidTrack)
                        // Each level owns its full column, so a tap anywhere above a number picks it.
                        HStack(spacing: 0) {
                            ForEach(EffortLevelLayout.levels, id: \.self) { level in
                                Button { userRating.wrappedValue = level } label: {
                                    Color.clear.contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .frame(width: layout.barWidth + layout.gap(after: level))
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .ironHorizontalScrub(includingTaps: false) { location in
                        userRating.wrappedValue = layout.level(at: location.x)
                    } onEnded: { }
                }
                .frame(height: 170)

                GeometryReader { proxy in
                    let layout = EffortLevelLayout(width: proxy.size.width, levelGap: Self.levelGap, tierGap: Self.tierGap)
                    ForEach(EffortLevelLayout.levels, id: \.self) { level in
                        Text("\(level)")
                            .font(.ironMetric(.caption, weight: .semibold))
                            .foregroundStyle(level == rating ? IronTheme.primaryText : IronTheme.secondaryText)
                            .position(x: layout.minX(of: level) + layout.barWidth / 2, y: proxy.size.height / 2)
                    }
                }
                .frame(height: levelLabelHeight)
            }
        }
        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: rating)
        .sensoryFeedback(.selection, trigger: selectionFeedback) { _, _ in SettingsStore.shared.workoutHaptics }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Session effort")
        .accessibilityValue(rating == 0 ? "Not rated" : "\(rating) of 10, \(tier.title)")
        .accessibilityHint("Swipe up or down to adjust")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: userRating.wrappedValue = min(rating + 1, 10)
            case .decrement: userRating.wrappedValue = max(rating - 1, allowsUnrated ? 0 : 1)
            default: break
            }
        }
    }

    @ViewBuilder private var readout: some View {
        Text(rating == 0 ? "—" : "\(rating)")
            .font(.ironMetric(.largeTitle))
            .contentTransition(reduceMotion ? .opacity : .numericText())
        Text(rating == 0 ? "Not rated" : tier.title)
            .font(.title2.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            // Changes at once, so two tier names never overlap mid-animation.
            .transaction { $0.animation = nil }
    }
}

/// Each half step is a separate segment of one continuous slanted ramp.
struct RPEGraph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var labelHeight: CGFloat = 18
    @Binding var selection: Double?
    @State private var selectionFeedback = 0

    private func select(_ value: Double) {
        guard selection != value else { return }
        selection = value
        selectionFeedback += 1
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let width = max(0, (proxy.size.width - 40) / 11)
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(0..<11) { index in
                        bar(index: index, width: width, totalWidth: proxy.size.width)
                    }
                }
                .contentShape(Rectangle())
                .ironHorizontalScrub(includingTaps: false) { location in
                    guard width > 0 else { return }
                    let index = min(max(Int(floor((location.x + 2) / (width + 4))), 0), 10)
                    select(5 + Double(index) * 0.5)
                } onEnded: { }
            }
            .frame(height: 96)

            GeometryReader { proxy in
                let width = max(0, (proxy.size.width - 40) / 11)
                ForEach(0..<6) { index in
                    Text("\(5 + index)")
                        .font(.ironMetric(.caption, weight: .semibold))
                        .foregroundStyle(IronTheme.secondaryText)
                        .position(x: CGFloat(index * 2) * (width + 4) + width / 2, y: labelHeight / 2)
                }
            }
            .frame(height: labelHeight)
            .accessibilityHidden(true)
        }
        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: selection)
        .sensoryFeedback(.selection, trigger: selectionFeedback) { _, _ in SettingsStore.shared.workoutHaptics }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Set RPE")
        .accessibilityValue(selection.map { "RPE \(String(format: "%g", $0)), \(RPE.title($0) ?? "")" } ?? "Not rated")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: select(min((selection ?? 4.5) + 0.5, 10))
            case .decrement: select(max((selection ?? 5.5) - 0.5, 5))
            default: break
            }
        }
    }

    private func bar(index: Int, width: CGFloat, totalWidth: CGFloat) -> some View {
        let x0 = CGFloat(index) * (width + 4)
        let x1 = x0 + width
        let value = 5 + Double(index) * 0.5
        let divisor = max(totalWidth, 1)
        let shape = SlantedBarShape(leftHeight: 0.28 + 0.72 * x0 / divisor,
                                    rightHeight: 0.28 + 0.72 * x1 / divisor,
                                    cornerRadius: min(8, width / 2.6))
        // A tap selects a bar directly; dragging across the ramp scrubs.
        return Button { select(value) } label: {
            shape
                .fill(selection.map { value <= $0 } == true ? IronTheme.metricEffort : Color(uiColor: .systemFill))
                .frame(width: width)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Horizontal controls yield vertical intent to their containing scroll view.
@available(iOS 18.0, *)
private struct IronHorizontalScrubRecognizer: UIGestureRecognizerRepresentable {
    let onChanged: (CGPoint) -> Void
    let onEnded: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed: onChanged(context.converter.localLocation)
        case .ended:
            onChanged(context.converter.localLocation)
            onEnded()
        case .cancelled, .failed: onEnded()
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}

extension View {
    @ViewBuilder
    func ironHorizontalScrub(
        includingTaps: Bool = true,
        onChanged: @escaping (CGPoint) -> Void,
        onEnded: @escaping () -> Void
    ) -> some View {
        let tap = SpatialTapGesture().onEnded { value in
            onChanged(value.location)
            onEnded()
        }
        if #available(iOS 18.0, *) {
            let horizontal = self.gesture(IronHorizontalScrubRecognizer(onChanged: onChanged, onEnded: onEnded))
            if includingTaps { horizontal.simultaneousGesture(tap) } else { horizontal }
        } else {
            let horizontal = self.simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        onChanged(value.location)
                    }
                    .onEnded { _ in onEnded() }
            )
            if includingTaps { horizontal.simultaneousGesture(tap) } else { horizontal }
        }
    }
}

/// A reusable Cupertino bottom modal for timed exercise targets and logged
/// efforts. Duration is adjusted with the same direct radial interaction as
/// Iron's rest timer, so time-based sets never fall back to a keyboard-only
/// text field or a platform picker.
struct IronDurationPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let subtitle: String
    let systemImage: String
    let secondaryActionTitle: String?
    let onSecondaryAction: (() -> Void)?
    let shouldDismiss: () -> Bool
    let onApply: (TimeInterval) -> Void

    @State private var selection: TimeInterval

    private let minimumDuration: TimeInterval
    private let maximumDuration: TimeInterval
    private let durationStep: TimeInterval
    private let presets: [TimeInterval]

    init(
        title: String = "Set duration",
        subtitle: String = "Choose the target time for this set",
        systemImage: String = "stopwatch.fill",
        initialDuration: TimeInterval,
        minimumDuration: TimeInterval = 5,
        maximumDuration: TimeInterval = 3_600,
        durationStep: TimeInterval = 5,
        presets: [TimeInterval] = [30, 45, 60, 90, 120, 180, 300, 600],
        secondaryActionTitle: String? = nil,
        onSecondaryAction: (() -> Void)? = nil,
        shouldDismiss: @escaping () -> Bool = { true },
        onApply: @escaping (TimeInterval) -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.minimumDuration = minimumDuration
        self.maximumDuration = max(maximumDuration, minimumDuration)
        self.durationStep = max(durationStep, 1)
        self.presets = presets.filter { $0 >= minimumDuration && $0 <= maximumDuration }
        self.secondaryActionTitle = secondaryActionTitle
        self.onSecondaryAction = onSecondaryAction
        self.shouldDismiss = shouldDismiss
        self.onApply = onApply
        _selection = State(
            initialValue: min(max(initialDuration, minimumDuration), max(maximumDuration, minimumDuration))
        )
    }

    var body: some View {
        IronUtilitySheet(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            onClose: { dismiss() }
        ) {
            VStack(spacing: 14) {
                IronDurationWheel(
                    selection: $selection,
                    minimumDuration: minimumDuration,
                    maximumDuration: maximumDuration,
                    secondsStep: durationStep
                )

                if !presets.isEmpty {
                    Picker("Presets", selection: $selection) {
                        ForEach(presets, id: \.self) { duration in
                            Text(durationTitle(duration)).tag(duration)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, IronTheme.horizontalPadding)
                }

                VStack(spacing: 10) {
                    Button {
                        onApply(selection)
                        if shouldDismiss() { dismiss() }
                    } label: {
                        Text("Use \(durationTitle(selection))")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    if let secondaryActionTitle, let onSecondaryAction {
                        Button {
                            onSecondaryAction()
                            if shouldDismiss() { dismiss() }
                        } label: {
                            Text(secondaryActionTitle)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
                .padding(.horizontal, IronTheme.horizontalPadding)
            }
            .padding(.bottom, 18)
        }
        .presentationDetents(presentationDetents)
        .presentationDragIndicator(.visible)
        .sensoryFeedback(.selection, trigger: Int(selection))
    }

    private var presentationDetents: Set<PresentationDetent> {
        secondaryActionTitle == nil ? [.height(470), .large] : [.height(540), .large]
    }

    private func durationTitle(_ duration: TimeInterval) -> String {
        IronDurationFormat.title(duration)
    }
}

/// Minute and second wheels, the same control watchOS uses for weight and reps.
/// Replaces Iron's former custom radial dial: a drag-around-a-circle gesture has
/// no platform equivalent, no Digital Crown analogue, and poor VoiceOver support.
struct IronDurationWheel: View {
    @Binding var selection: TimeInterval

    let minimumDuration: TimeInterval
    let maximumDuration: TimeInterval
    let secondsStep: TimeInterval

    private var maximumMinutes: Int {
        max(Int(maximumDuration) / 60, 0)
    }

    private var secondsValues: [Int] {
        let step = max(Int(secondsStep), 1)
        guard step < 60 else { return [0] }
        return Array(stride(from: 0, to: 60, by: step))
    }

    private var minuteSelection: Binding<Int> {
        Binding(
            get: { min(Int(selection) / 60, maximumMinutes) },
            set: { selection = clamped(TimeInterval($0 * 60 + Int(selection) % 60)) }
        )
    }

    private var secondSelection: Binding<Int> {
        Binding(
            get: {
                let current = Int(selection) % 60
                return secondsValues.min(by: { abs($0 - current) < abs($1 - current) }) ?? 0
            },
            set: { selection = clamped(TimeInterval((Int(selection) / 60) * 60 + $0)) }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            wheel(
                label: "Minutes",
                unit: "min",
                values: Array(0...maximumMinutes),
                selection: minuteSelection
            )

            wheel(
                label: "Seconds",
                unit: "sec",
                values: secondsValues,
                selection: secondSelection
            )
        }
        .frame(height: 150)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Duration")
        .accessibilityValue(IronDurationFormat.title(selection))
    }

    private func wheel(
        label: String,
        unit: String,
        values: [Int],
        selection: Binding<Int>
    ) -> some View {
        HStack(spacing: 4) {
            Picker(label, selection: selection) {
                ForEach(values, id: \.self) { value in
                    Text("\(value)")
                        .monospacedDigit()
                        .tag(value)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()

            Text(unit)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func clamped(_ duration: TimeInterval) -> TimeInterval {
        min(max(duration, minimumDuration), max(maximumDuration, minimumDuration))
    }
}

/// One duration string for the logger, rest timer, and Live Activity so a
/// 90-second rest never renders as "1:30" in one place and "90s" in another.
enum IronDurationFormat {
    static func title(_ duration: TimeInterval) -> String {
        let seconds = Int(max(duration, 0).rounded())
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

// MARK: - Native pull-down actions

extension View {
    func ironScreen() -> some View {
        self
            .accentColor(IronTheme.accent)
    }

    @ViewBuilder
    func defaultScrollAnchorCompat_trailing() -> some View {
        if #available(iOS 18.0, *) {
            defaultScrollAnchor(.trailing)
        } else {
            self
        }
    }
}

struct TextCaseNil: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 14.0, *) {
            content.textCase(nil)
        } else {
            content
        }
    }
}

extension View {
    @ViewBuilder
    func textCaseCompat_nil() -> some View {
        if #available(iOS 14.0, *) {
            textCase(nil)
        } else {
            self
        }
    }
}

extension View {
    @ViewBuilder
    func listStyleCompat_InsetGroupedListStyle() -> some View {
        if #available(iOS 14.0, *) {
            listStyle(InsetGroupedListStyle())
        } else {
            listStyle(GroupedListStyle())
        }
    }
}

extension View {
    @ViewBuilder
    func redacted_compat() -> some View {
        if #available(iOS 14.0, *) {
            redacted(reason: .placeholder)
        }
    }
}

extension View {
    /// Applies a modifier to a view conditionally.
    ///
    /// - Parameters:
    ///   - condition: The condition to determine if the content should be applied.
    ///   - content: The modifier to apply to the view.
    /// - Returns: The modified view.
    @ViewBuilder func modifier<T: View>(
        if condition: @autoclosure () -> Bool,
        then content: (Self) -> T
    ) -> some View {
        if condition() {
            content(self)
        } else {
            self
        }
    }
    
    /// Applies a modifier to a view conditionally.
    ///
    /// - Parameters:
    ///   - condition: The condition to determine the content to be applied.
    ///   - trueContent: The modifier to apply to the view if the condition passes.
    ///   - falseContent: The modifier to apply to the view if the condition fails.
    /// - Returns: The modified view.
    @ViewBuilder func modifier<TrueContent: View, FalseContent: View>(
        if condition: @autoclosure () -> Bool,
        then trueContent: (Self) -> TrueContent,
        else falseContent: (Self) -> FalseContent
    ) -> some View {
        if condition() {
            trueContent(self)
        } else {
            falseContent(self)
        }
    }
}

/// Normalizes catalog muscle names for the detail and live-workout maps.
func ironMapMuscle(_ rawName: String) -> Muscle? {
    switch rawName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
    case "abs", "abdominals", "core": return .abs
    case "lower abs", "lowerabs": return .lowerAbs
    case "obliques": return .obliques
    case "serratus", "serratus anterior": return .serratus
    case "biceps", "biceps brachii", "brachialis": return .biceps
    case "triceps", "triceps brachii": return .triceps
    case "forearm", "forearms", "forerm", "wrists", "wrist flexors", "wrist extensors", "grip muscles": return .forearm
    case "hands": return .hands
    case "shoulders", "deltoid", "deltoids", "delts": return .deltoids
    case "rear deltoid", "rear deltoids", "reardeltoid": return .rearDeltoid
    case "rotator cuff", "rotatorcuff": return .rotatorCuff
    case "trapezius", "traps", "levator scapulae": return .trapezius
    case "rhomboids": return .rhomboids
    case "neck", "sternocleidomastoid": return .neck
    case "chest", "pectorals", "pectoralis major": return .chest
    case "upper chest", "upperchest": return .upperChest
    case "lats", "latissimus", "latissimus dorsi", "upper back", "upperback", "back": return .upperBack
    case "lower back", "lowerback", "spine", "erector spinae": return .lowerBack
    case "glutes", "glutaeus maximus", "abductors": return .gluteal
    case "hamstrings", "ischiocrural muscles": return .hamstring
    case "quadriceps", "quads": return .quadriceps
    case "adductors", "groin", "inner thighs": return .adductors
    case "hip flexor", "hip flexors", "hipflexors": return .hipFlexors
    case "calves", "gastrocnemius", "soleus": return .calves
    case "shin", "shins", "tibialis", "tibialis anterior": return .tibialis
    case "ankles", "ankle stabilizers": return .ankles
    case "feet": return .feet
    default: return nil
    }
}


extension View {
    /// Scrub horizontally, leaving vertical pans to the enclosing List.
    func ironHorizontalChartScrubbing(onEnded: @escaping () -> Void) -> some View {
        chartGesture { _ in SpatialTapGesture() }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let plotFrame = proxy.plotFrame {
                        let frame = geometry[plotFrame]
                        IronChartScrubber(
                            onChanged: { x in proxy.selectXValue(at: min(max(x, 0), frame.width)) },
                            onEnded: onEnded
                        )
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .accessibilityHidden(true)
                    }
                }
            }
    }
}

private struct IronChartScrubber: UIViewRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panChanged(_:)))
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { context.coordinator.parent = self }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: IronChartScrubber
        init(parent: IronChartScrubber) { self.parent = parent }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }

        @objc func panChanged(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began, .changed: parent.onChanged(pan.location(in: pan.view).x)
            case .ended, .cancelled, .failed: parent.onEnded()
            default: break
            }
        }
    }
}
