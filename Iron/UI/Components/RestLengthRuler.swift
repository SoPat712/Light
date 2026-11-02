import SwiftUI

/// Scrubs locally; callers persist and synchronize only after a committed choice.
struct RestLengthRuler: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var value: TimeInterval
    var range: ClosedRange<TimeInterval> = 30...300
    var step: TimeInterval = 15
    let onCommit: (TimeInterval) -> Void

    @State private var scrubbedValue: TimeInterval?
    @State private var scrubbedPosition: TimeInterval?
    @State private var stepFeedback = 0
    @State private var rulerWidth: CGFloat = 1
    private let presets: [TimeInterval] = [60, 90, 120, 150, 180]
    // Whole minutes only, at most five, spread over whatever range the caller uses
    // (the logger's 0:30–5:00 or Settings' 0:30–10:00); 0:30 collides with 1:00.
    private var labels: [TimeInterval] {
        let minutes = max(1, ((range.upperBound - range.lowerBound) / 60 / 5).rounded(.up))
        let first = (range.lowerBound / 60).rounded(.up) * 60
        return Array(stride(from: max(first, 60), through: range.upperBound, by: minutes * 60))
    }

    private var displayedValue: TimeInterval { scrubbedValue ?? value }
    private var pointerValue: TimeInterval { scrubbedPosition ?? displayedValue }
    private var scale: RestLengthRulerScale { .init(range: range, step: step) }

    // These are the default ruler's 19 values, reused by captions and presets.
    // Finger updates must not repeatedly invoke DateComponentsFormatter.
    private static let durationTitles: [TimeInterval: String] = Dictionary(uniqueKeysWithValues:
        stride(from: 30.0, through: 300.0, by: 15.0).map {
            ($0, restTimerDurationFormatter.string(from: $0) ?? "0:00")
        }
    )
    private var ticks: [TimeInterval] {
        Array(stride(from: range.lowerBound, through: range.upperBound, by: max(step, 1)))
    }

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Rest length")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(IronTheme.secondaryText)
                    Spacer(minLength: 8)
                    Text(timeTitle(displayedValue))
                        .font(.ironMetric(.title3))
                        .foregroundStyle(IronTheme.metricTime)
                        .contentTransition(reduceMotion ? .opacity : .numericText())
                }

                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        ForEach(ticks, id: \.self) { tick in
                            let height: CGFloat = tick.truncatingRemainder(dividingBy: 60) == 0 ? 26 : 14
                            RoundedRectangle(cornerRadius: 1, style: .continuous)
                                .fill(tick <= displayedValue ? IronTheme.metricTime : IronTheme.tertiaryFill)
                                .frame(width: 2, height: height)
                                .position(x: xPosition(tick, width: proxy.size.width), y: 32 - height / 2)
                        }
                        Capsule()
                            .fill(IronTheme.metricTime)
                            .frame(width: 4, height: 32)
                            .position(x: xPosition(pointerValue, width: proxy.size.width), y: 16)

                        ForEach(labels.filter { range.contains($0) }, id: \.self) { label in
                            Text(timeTitle(label))
                                .font(.ironMetric(.caption2, weight: .semibold))
                                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                                .foregroundStyle(IronTheme.secondaryText)
                                .fixedSize()
                                .position(x: xPosition(label, width: proxy.size.width), y: 46)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onAppear { rulerWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in rulerWidth = width }
                }
                .frame(height: 54)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(SpatialTapGesture().onEnded { value in
                scrub(at: value.location.x)
                if let scrubbedValue { commit(scrubbedValue) }
            })

            HStack(spacing: 4) {
                ForEach(presets.filter { range.contains($0) }, id: \.self) { preset in
                    Button {
                        withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) {
                            scrub(to: preset)
                            commit(preset)
                        }
                    } label: {
                        Text(timeTitle(preset))
                            .font(.ironMetric(.footnote, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(displayedValue == preset ? IronTheme.topBar : IronTheme.primaryText)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(displayedValue == preset ? IronTheme.metricTime : IronTheme.tertiaryFill, in: Capsule())
                            .frame(minHeight: IronTheme.controlHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .contentShape(Rectangle())
        .ironHorizontalScrub(includingTaps: false) { location in
            scrub(at: location.x)
        } onEnded: {
            if let scrubbedValue { commit(scrubbedValue) }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(IronTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .sensoryFeedback(.selection, trigger: stepFeedback) { _, _ in SettingsStore.shared.workoutHaptics }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rest length")
        .accessibilityValue(spokenDuration)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: scrub(to: displayedValue + step)
            case .decrement: scrub(to: displayedValue - step)
            default: return
            }
            if let scrubbedValue { commit(scrubbedValue) }
        }
    }

    private func xPosition(_ duration: TimeInterval, width: CGFloat) -> CGFloat {
        scale.position(for: duration, width: width)
    }

    private func scrub(at x: CGFloat) {
        let proposed = scale.duration(at: x, width: rulerWidth)
        // The marker follows the touch, without a spring chasing every event.
        // The chosen duration and feedback still advance in 15-second steps.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrubbedPosition = proposed
            scrub(to: proposed)
        }
    }

    private func scrub(to proposed: TimeInterval) {
        let next = scale.snapped(proposed)
        if next != displayedValue {
            stepFeedback += 1
            IronSoundPlayer.shared.play(.tick)
        }
        scrubbedValue = next
    }

    private func commit(_ duration: TimeInterval) {
        let selected = scale.snapped(duration)
        value = selected
        onCommit(selected)
        withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) {
            scrubbedValue = nil
            scrubbedPosition = nil
        }
    }

    private func timeTitle(_ duration: TimeInterval) -> String {
        let title = Self.durationTitles[duration] ?? restTimerDurationFormatter.string(from: max(0, duration)) ?? "0:00"
        // Rest lengths read as "2:30", not the clock-style "02:30".
        return title.count == 5 && title.hasPrefix("0") ? String(title.dropFirst()) : title
    }

    private var spokenDuration: String {
        let seconds = max(0, Int(displayedValue.rounded()))
        let minutes = seconds / 60
        let remainder = seconds % 60
        return "\(minutes) \(minutes == 1 ? "minute" : "minutes") \(remainder) \(remainder == 1 ? "second" : "seconds")"
    }
}

/// Geometry and snapping are independent: a continuous pointer can track a touch
/// while the selected timer value remains discrete and is committed on release.
struct RestLengthRulerScale {
    let range: ClosedRange<TimeInterval>
    let step: TimeInterval
    private let inset: CGFloat = 14

    private var span: TimeInterval { max(range.upperBound - range.lowerBound, 1) }
    private var increment: TimeInterval { step.isFinite ? max(step, 1) : 1 }

    func duration(at x: CGFloat, width: CGFloat) -> TimeInterval {
        let fraction = min(max((x - inset) / max(width - 2 * inset, 1), 0), 1)
        return min(range.upperBound, range.lowerBound + Double(fraction) * span)
    }

    func position(for duration: TimeInterval, width: CGFloat) -> CGFloat {
        let fraction = min(max((duration - range.lowerBound) / span, 0), 1)
        return inset + CGFloat(fraction) * max(width - 2 * inset, 0)
    }

    func snapped(_ duration: TimeInterval) -> TimeInterval {
        let snapped = range.lowerBound + ((duration - range.lowerBound) / increment).rounded() * increment
        return min(max(snapped, range.lowerBound), range.upperBound)
    }
}
