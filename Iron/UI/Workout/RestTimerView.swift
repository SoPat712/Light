//
//  RestTimerView.swift
//  Iron
//
//  Rest length uses the same ruler in the logger and utility sheets.
//

import SwiftUI

enum RestTimerSheetLayout {
    static let height: CGFloat = 320
}

struct RestTimerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var restTimerStore: RestTimerStore
    @State private var selectedDuration: TimeInterval = 90
    @State private var clampFeedback = 0
    @State private var actionFeedback = 0

    private var isRunning: Bool { restTimerStore.restTimerRemainingTime != nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if isRunning {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(timeTitle(max(0, restTimerStore.restTimerRemainingTime ?? 0)))
                            .font(.ironMetric(.title3))
                            .foregroundStyle(restTimerStore.isPaused ? IronTheme.warning : IronTheme.metricTime)
                            .contentTransition(reduceMotion ? .opacity : .numericText(countsDown: true))
                            .accessibilityLabel(restTimerStore.isPaused ? "Rest timer paused" : "Rest remaining")
                    }
                    RestLengthRuler(value: Binding(
                        get: { restTimerStore.restTimerDuration ?? selectedDuration },
                        set: { _ in }
                    )) { duration in
                        if restTimerStore.setTotalRestLength(duration) { clampFeedback += 1 }
                        WorkoutLiveActivityManager.shared.refreshCurrentWorkoutRestTimer()
                    }
                    HStack(spacing: 8) {
                        timerActionButton("−15", label: "Subtract 15 seconds") { adjustRunningTimer(by: -15) }
                        timerActionButton(
                            restTimerStore.isPaused ? "Resume" : "Pause",
                            systemImage: restTimerStore.isPaused ? "play.fill" : "pause.fill",
                            label: restTimerStore.isPaused ? "Resume rest timer" : "Pause rest timer"
                        ) {
                            restTimerStore.isPaused ? restTimerStore.resume() : restTimerStore.pause()
                            WorkoutLiveActivityManager.shared.refreshCurrentWorkoutRestTimer()
                        }
                        timerActionButton("+15", label: "Add 15 seconds") { adjustRunningTimer(by: 15) }
                        timerActionButton("Stop", systemImage: "xmark", label: "Stop rest timer", destructive: true) {
                            restTimerStore.cancel()
                            WorkoutLiveActivityManager.shared.refreshCurrentWorkoutRestTimer()
                        }
                    }
                } else {
                    RestLengthRuler(value: $selectedDuration) { _ in }
                    Button {
                        actionFeedback += 1
                        restTimerStore.start(duration: selectedDuration)
                        restTimerStore.recentRestTimes.removeAll { $0 == selectedDuration }
                        restTimerStore.recentRestTimes.insert(selectedDuration, at: 0)
                        WorkoutLiveActivityManager.shared.refreshCurrentWorkoutRestTimer()
                    } label: {
                        Label("Start Rest", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .ironProminentGlassButtonStyle()
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .frame(height: 50)
                }
            }
            .padding(.horizontal, IronTheme.horizontalPadding)
            .padding(.vertical, 12)
        }
        .onAppear {
            if let recent = restTimerStore.recentRestTimes.first {
                selectedDuration = min(max(recent, 30), 300)
            }
        }
        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: isRunning)
        .sensoryFeedback(.error, trigger: clampFeedback) { _, _ in SettingsStore.shared.workoutHaptics }
        .sensoryFeedback(.selection, trigger: actionFeedback) { _, _ in SettingsStore.shared.workoutHaptics }
    }

    private func timerActionButton(
        _ title: String,
        systemImage: String? = nil,
        label: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            actionFeedback += 1
            action()
        } label: {
            Group {
                if let systemImage { Image(systemName: systemImage) } else { Text(title) }
            }
            .font(.ironMetric(.subheadline, weight: .semibold))
            .foregroundStyle(destructive ? IronTheme.danger : IronTheme.primaryText)
            .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight)
            .background(IronTheme.tertiaryFill, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func timeTitle(_ duration: TimeInterval) -> String {
        restTimerDurationFormatter.string(from: duration.rounded(.up)) ?? "0:00"
    }

    private func adjustRunningTimer(by interval: TimeInterval) {
        restTimerStore.adjust(by: interval, feedback: true)
        WorkoutLiveActivityManager.shared.refreshCurrentWorkoutRestTimer()
    }
}

/// Shared by saved-workout and history editors; keeps their existing save paths.
struct RestTimerConfigurationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let subtitle: String
    let secondaryActionTitle: String?
    let onSecondaryAction: (() -> Void)?
    let shouldDismiss: () -> Bool
    let onApply: (TimeInterval) -> Void
    @State private var selection: TimeInterval

    init(
        title: String = "Rest Timer",
        subtitle: String = "Recovery after each completed set",
        initialDuration: TimeInterval,
        secondaryActionTitle: String? = nil,
        onSecondaryAction: (() -> Void)? = nil,
        shouldDismiss: @escaping () -> Bool = { true },
        onApply: @escaping (TimeInterval) -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.secondaryActionTitle = secondaryActionTitle
        self.onSecondaryAction = onSecondaryAction
        self.shouldDismiss = shouldDismiss
        self.onApply = onApply
        _selection = State(initialValue: min(max(initialDuration, 30), 300))
    }

    var body: some View {
        IronUtilitySheet(title: title, subtitle: subtitle, systemImage: "timer", onClose: { dismiss() }) {
            ScrollView {
                VStack(spacing: 10) {
                    RestLengthRuler(value: $selection) { _ in }
                    Button {
                        onApply(selection)
                        if shouldDismiss() { dismiss() }
                    } label: {
                        Text("Use \(restTimerDurationFormatter.string(from: selection) ?? "0:00")")
                            .frame(maxWidth: .infinity)
                    }
                    .ironProminentGlassButtonStyle()
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .frame(height: 50)

                    if let secondaryActionTitle, let onSecondaryAction {
                        Button {
                            onSecondaryAction()
                            if shouldDismiss() { dismiss() }
                        } label: {
                            Text(secondaryActionTitle)
                                .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(IronTheme.accent)
                    }
                }
                .padding(.horizontal, IronTheme.horizontalPadding)
                .padding(.vertical, 12)
            }
        }
        .presentationDetents([.height(RestTimerSheetLayout.height)])
        .presentationDragIndicator(.visible)
    }
}

extension RestTimerStore {
    /// Keep elapsed time and paused state. `adjust` owns notification and Watch
    /// synchronization, and is invoked only once after the ruler is released.
    /// Returns true when the request needed the elapsed + 15 second clamp.
    @discardableResult
    func setTotalRestLength(_ requested: TimeInterval) -> Bool {
        guard let total = restTimerDuration, let remaining = restTimerRemainingTime,
              remaining > 0 else { return false }
        let minimum = max(0, total - remaining) + 15
        let clamped = max(requested, minimum)
        if clamped != total { adjust(by: clamped - total) }
        return requested < minimum
    }
}

#if DEBUG
struct RestTimerView_Previews: PreviewProvider {
    static var previews: some View {
        RestTimerView().environmentObject(RestTimerStore.shared)
    }
}
#endif
