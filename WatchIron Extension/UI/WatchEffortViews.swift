import SwiftUI

struct WatchEffortRatingPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Binding private var rating: Int
    private let context: String
    @State private var crownValue: Double
    @FocusState private var crownFocused: Bool

    init(rating: Binding<Int>, context: String) {
        _rating = rating
        self.context = context
        _crownValue = State(initialValue: Double(min(max(rating.wrappedValue, 0), 10)) * 2)
    }

    var body: some View {
        WatchRatingPageLayout(title: "Rate Your Effort", context: context,
                              description: rating == 0 ? "No rating" : EffortTierPalette.tier(for: rating).title) { budget in
            WatchRatingReadout(value: rating == 0 ? "—" : "\(rating)",
                               text: rating == 0 ? "No rating" : EffortTierPalette.tier(for: rating).title,
                               color: rating == 0 ? IronTheme.secondaryText : IronTheme.effortColor(rating),
                               label: "Effort", budget: budget)
                .focusable()
                .focused($crownFocused)
                .focusEffectDisabled()
                .watchCrownRotation(detent: $crownValue, in: 0...20, by: 2, sensitivity: .low, haptics: false)
                .onTapGesture { crownFocused = true }
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: select(rating + 1)
                    case .decrement: select(rating - 1)
                    @unknown default: break
                    }
                }
        } scale: {
            WatchRatingScale(count: 10, selectedIndex: rating == 0 ? nil : rating - 1,
                             color: { IronTheme.effortColor($0 + 1) },
                             onSelect: { index in
                                 select(index + 1)
                                 crownFocused = true
                             })
        }
        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: rating)
        .onAppear {
            crownValue = Double(min(max(rating, 0), 10)) * 2
            crownFocused = true
        }
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            crownFocused = true
        }
        .onChange(of: scenePhase) { if scenePhase == .active { crownFocused = true } }
        .onChange(of: crownValue) { _, value in select(Int((value / 2).rounded())) }
        .onChange(of: rating) { _, value in
            // Preserve accumulated sub-detent travel, and silently follow sync.
            let detent = min(max(value, 0), 10)
            if Int((crownValue / 2).rounded()) != detent { crownValue = Double(detent) * 2 }
        }
    }

    private func select(_ value: Int) {
        let selected = min(max(value, 0), 10)
        guard rating != selected else { return }
        rating = selected
        WatchFeedback.play(.click)
    }
}

struct WatchRPEPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Binding private var value: Double?
    private let context: String
    private let onInteraction: () -> Void
    private let automaticallyAccepts: Bool
    private let isSuggestion: Bool
    private let onConfirm: (() -> Void)?
    @State private var crownValue: Double
    @FocusState private var crownFocused: Bool

    init(value: Binding<Double?>, context: String, onInteraction: @escaping () -> Void = {},
         automaticallyAccepts: Bool = false, isSuggestion: Bool = false, onConfirm: (() -> Void)? = nil) {
        _value = value
        self.context = context
        self.onInteraction = onInteraction
        self.automaticallyAccepts = automaticallyAccepts
        self.isSuggestion = isSuggestion
        self.onConfirm = onConfirm
        _crownValue = State(initialValue: (WatchSetRPEScale.normalized(value.wrappedValue) ?? WatchSetRPEScale.unratedValue) * 4)
    }

    private var selectedValue: Double? { WatchSetRPEScale.normalized(value) }

    var body: some View {
        WatchRatingPageLayout(title: "RPE", context: context,
                              description: (isSuggestion ? "Suggested · " : "") + WatchSetRPEScale.description(selectedValue),
                              onInteraction: interacted, onConfirm: onConfirm) { budget in
            WatchRatingReadout(value: selectedValue.map { WatchNumber.format($0) } ?? "—",
                               text: WatchSetRPEScale.description(selectedValue),
                               color: selectedValue == nil ? IronTheme.secondaryText : IronTheme.metricEffort,
                               label: "RPE", budget: budget, automaticallyAccepts: automaticallyAccepts)
                .opacity(isSuggestion ? 0.45 : 1)
                .focusable()
                .focused($crownFocused)
                .focusEffectDisabled()
                // One detent below the model's minimum clears the rating.
                .watchCrownRotation(detent: $crownValue, in: (WatchSetRPEScale.unratedValue * 4)...40, by: 2,
                                    sensitivity: .low, haptics: false,
                                    // Crown events count even when the bound detent is at a limit.
                                    onChange: { _ in interacted() })
                .onTapGesture {
                    interacted()
                    crownFocused = true
                }
                .accessibilityAdjustableAction { direction in
                    interacted()
                    switch direction {
                    case .increment: select((selectedValue ?? WatchSetRPEScale.unratedValue) + 0.5)
                    case .decrement: select((selectedValue ?? WatchSetRPEScale.unratedValue) - 0.5)
                    @unknown default: break
                    }
                }
        } scale: {
            WatchRatingScale(count: WatchSetRPEScale.allowedValues.count,
                             selectedIndex: selectedValue.flatMap { WatchSetRPEScale.allowedValues.firstIndex(of: $0) },
                             color: { _ in IronTheme.metricEffort.opacity(isSuggestion ? 0.45 : 1) },
                             onSelect: { index in
                                 interacted()
                                 select(WatchSetRPEScale.allowedValues[index])
                                 crownFocused = true
                             })
        }
        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: value)
        .onAppear {
            crownValue = (selectedValue ?? WatchSetRPEScale.unratedValue) * 4
            crownFocused = true
        }
        .task {
            // Reassert after the presentation has installed its focus scope.
            await Task.yield()
            guard !Task.isCancelled else { return }
            crownFocused = true
        }
        .onChange(of: scenePhase) { if scenePhase == .active { crownFocused = true } }
        .onChange(of: crownValue) { _, newValue in
            onInteraction()
            select(newValue / 4)
        }
        .onChange(of: value) { _, newValue in
            let detent = WatchSetRPEScale.normalized(newValue) ?? WatchSetRPEScale.unratedValue
            if Self.snapped(crownValue / 4) != detent { crownValue = detent * 4 }
        }
    }

    private func interacted() {
        onInteraction()
    }

    private static func snapped(_ value: Double) -> Double {
        guard value.isFinite else { return 8 }
        return min(max((value * 2).rounded() / 2, WatchSetRPEScale.unratedValue), 10)
    }

    private func select(_ newValue: Double) {
        let detent = Self.snapped(newValue)
        let selected = WatchSetRPEScale.normalized(detent)
        guard value != selected else { return }
        value = selected
        WatchFeedback.play(.click)
    }
}

/// Both ratings share context, number, graph and explanation below the toolbar.
/// The confirmation button reserves the toolbar; these pages have no vitals pill.
/// Only automatic RPE's owner schedules acceptance.
private struct WatchRatingReadoutBudget {
    let height: CGFloat
    var fontSize: CGFloat { height / 0.74 }
}

private struct WatchRatingPageLayout<Readout: View, Scale: View>: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isLuminanceReduced) private var reducedLuminance
    let title: String
    let context: String
    let description: String
    var onInteraction: () -> Void = {}
    var onConfirm: (() -> Void)? = nil
    @ViewBuilder let readout: (WatchRatingReadoutBudget) -> Readout
    @ViewBuilder let scale: () -> Scale

    var body: some View {
        GeometryReader { proxy in
            let clearance: CGFloat = proxy.size.width < 180 ? 6 : 10
            let free = max(0, proxy.size.height - 18 - 16 - clearance - 12)
            let numberHeight = free * 0.34
            let graphHeight = free * 0.66
            VStack(spacing: 4) {
                WatchRatingVitalsHeader(title: title, context: context, textSize: 13, showsVitals: false)
                    .frame(height: 18)
                readout(WatchRatingReadoutBudget(height: numberHeight))
                    .frame(height: numberHeight)
                    .opacity(reducedLuminance ? 0.45 : 1)
                scale()
                    .frame(height: graphHeight)
                    .opacity(reducedLuminance ? 0.45 : 1)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onInteraction)
                    .accessibilityHidden(true)
                Text(description)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IronTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity)
                    .frame(height: 16)
                    .opacity(reducedLuminance ? 0.45 : 1)
            }
            .padding(.bottom, clearance)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .padding(.horizontal, IronTheme.workoutGutter)
        .navigationTitle("")
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .bottomBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    WatchFeedback.play(.success)
                    if let onConfirm { onConfirm() }
                    else { dismiss() }
                } label: { Image(systemName: "checkmark") }
                    .accessibilityLabel("Confirm Rating")
                    .disabled(store.persistenceFailure != nil)
            }
        }
    }
}

private struct WatchRatingReadout: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: String
    let text: String
    let color: Color
    let label: String
    let budget: WatchRatingReadoutBudget
    var automaticallyAccepts = false

    var body: some View {
        Text(value)
            .font(.ironMetric(size: budget.fontSize))
            .foregroundStyle(color)
            .lineLimit(1).minimumScaleFactor(0.9)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentTransition(reduceMotion || value == "—" ? .opacity : .numericText())
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value == "—" ? text : value + ", " + text.replacingOccurrences(of: "–", with: " to "))
            .accessibilityHint(automaticallyAccepts
                ? "Turn the Digital Crown to adjust. Continues after five seconds without Crown movement. A suggestion is only saved if you use the checkmark. Turn below the minimum for no rating."
                : "Turn the Digital Crown to adjust. Turn below the minimum for no rating. Use the checkmark to confirm.")
    }
}

/// A visual scale only. The Crown (or VoiceOver adjustable action) owns input.
private struct WatchRatingScale: View {
    let count: Int
    let selectedIndex: Int?
    let color: (Int) -> Color
    var onSelect: ((Int) -> Void)? = nil

    var body: some View {
        GeometryReader { proxy in
            let gap: CGFloat = count > 10 ? 3 : 4
            let width = max(0, (proxy.size.width - CGFloat(count - 1) * gap) / CGFloat(count))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(0..<count, id: \.self) { index in
                    SlantedBarShape(leftHeight: 0.25 + 0.75 * CGFloat(index) / CGFloat(count),
                                    rightHeight: 0.25 + 0.75 * CGFloat(index + 1) / CGFloat(count),
                                    cornerRadius: min(3, width / 3))
                        .fill(selectedIndex.map { index <= $0 } == true ? color(index) : IronTheme.effortInactive)
                        .frame(width: width)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
            .contentShape(Rectangle())
            // A finger picks the bar under it: tap one, or slide across to scrub.
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let slot = (proxy.size.width + gap) / CGFloat(count)
                guard slot > 0, drag.location.x.isFinite else { return }
                onSelect?(min(max(Int(drag.location.x / slot), 0), count - 1))
            }, including: onSelect == nil ? .none : .all)
        }
    }
}

// WorkoutDataKit is not linked by the Watch app. Mirror RPE.allowedValues and
// the titles in WorkoutDataKit/Model/RPE.swift, shortened for a single Watch line.
// This scale is only for set RPE; workout effort retains its separate 1–10 scale.
enum WatchSetRPEScale {
    static let allowedValues = Array(stride(from: 5.0, through: 10.0, by: 0.5))
    static let unratedValue = 4.5

    /// Ignore unsupported legacy ratings and snap valid-range input to a model value.
    static func normalized(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (5...10).contains(value) else { return nil }
        return (value * 2).rounded() / 2
    }

    static func description(_ value: Double?) -> String {
        guard let value else { return "No rating" }
        switch value {
        case 5: return "5 in reserve"
        case 5.5: return "Easy to moderate"
        case 6: return "4 in reserve"
        case 6.5: return "3–4 in reserve"
        case 7: return "3 in reserve"
        case 7.5: return "2–3 in reserve"
        case 8: return "2 in reserve"
        case 8.5: return "1–2 in reserve"
        case 9: return "1 in reserve"
        case 9.5: return "Could lift heavier"
        case 10: return "Max effort"
        default: return "No rating"
        }
    }
}
