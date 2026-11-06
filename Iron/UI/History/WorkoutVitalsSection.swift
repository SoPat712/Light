import SwiftUI
import Charts
import UIKit

/// Heart rate and active energy from Apple Health for a finished workout.
/// The section stays hidden when Health has nothing for the workout's window.
struct WorkoutVitalsSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("workoutVitals.autoLoad") private var autoLoad = false

    let start: Date
    let end: Date

    private enum LoadState: Equatable {
        case notLoaded
        case loading
        case needsAccess
        case empty
        case loaded(HealthManager.WorkoutVitals)
    }

    private struct ChartPoint: Identifiable {
        let id: Int
        let minutes: Double
        let bpm: Double
    }

    @State private var state = LoadState.notLoaded
    @State private var selectedPointID: Int?

    var body: some View {
        Group {
            switch state {
            case .notLoaded:
                if autoLoad {
                    Color.clear.frame(height: 0)
                } else {
                    accessPrompt
                }
            case .loading, .empty:
                // A real (zero-height) view, so `.task` still runs.
                Color.clear.frame(height: 0)
            case .needsAccess:
                accessPrompt
            case .loaded(let vitals):
                section { content(vitals) }
            }
        }
        .task(id: [start, end]) {
            selectedPointID = nil
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ironDemoVitals") {
                await load()
                return
            }
            #endif
            if autoLoad {
                await load()
            } else {
                state = .notLoaded
            }
        }
    }

    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(IronTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.top, 12)
    }

    // MARK: Access

    private var accessPrompt: some View {
        Button(action: requestAccess) {
            Label("Show Heart Rate", systemImage: "heart.fill")
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: IronTheme.controlHeight)
        }
        .buttonStyle(.bordered)
        .tint(IronTheme.accent)
        .accessibilityLabel("Show Heart Rate")
        .accessibilityHint("Reads heart rate and active calories from Apple Health for this workout")
        .padding(.top, 12)
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ vitals: HealthManager.WorkoutVitals) -> some View {
        let bpms = vitals.heartRate.map(\.bpm)
        let average = bpms.isEmpty ? nil : bpms.reduce(0, +) / Double(bpms.count)
        let maximum = bpms.max()
        let points = chartPoints(vitals.heartRate)

        VStack(alignment: .leading, spacing: 14) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 0))
            layout {
                stat("Average", value: average, unit: "bpm", tint: IronTheme.metricHeartRate)
                stat("Maximum", value: maximum, unit: "bpm", tint: IronTheme.metricHeartRate)
                stat("Active", value: vitals.activeEnergyKilocalories, unit: "kcal", tint: IronTheme.metricEnergy)
            }

            if points.count > 1, let average {
                chart(points, average: average)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Heart rate over the workout")
                    .accessibilityValue(
                        chartAccessibilityValue(points, average: average, maximum: maximum ?? average)
                    )
                    .accessibilityHint("Adjust to explore the previous or next reading. Double-tap to clear the selection.")
                    .accessibilityAdjustableAction { adjustSelection($0, in: points) }
                    .accessibilityAction { selectedPointID = nil }
                    .accessibilityAction(named: Text("Clear Selection")) { selectedPointID = nil }
            }
        }
    }

    private func stat(_ title: String, value: Double?, unit: String, tint: Color) -> some View {
        let number = value.map { $0.formatted(.number.precision(.fractionLength(0))) }
        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(IronTheme.secondaryText)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(number ?? "—")
                    .font(.ironMetric(.title2, weight: .semibold))
                    .foregroundStyle(number == nil ? IronTheme.secondaryText : tint)
                Text(unit)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(IronTheme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(number.map { "\($0) \(unit == "bpm" ? "beats per minute" : "active kilocalories")" } ?? "No reading")
    }

    private func chart(_ points: [ChartPoint], average: Double) -> some View {
        let selectedPoint = points.first { $0.id == selectedPointID }

        let low = Int((points.map(\.bpm).min() ?? average).rounded())
        let high = Int((points.map(\.bpm).max() ?? average).rounded())
        return VStack(alignment: .leading, spacing: 10) {
            // The header keeps one height either way, so the plot never moves under the finger.
            Group {
                if let selectedPoint {
                    IronChartHeader(
                        caption: "Heart Rate",
                        value: IronChartText.value(selectedPoint.bpm.formatted(.number.precision(.fractionLength(0))), unit: "bpm", tint: IronTheme.metricHeartRate),
                        detail: elapsedTime(at: selectedPoint)
                    )
                } else {
                    IronChartHeader(
                        caption: "Average",
                        value: IronChartText.value(average.formatted(.number.precision(.fractionLength(0))), unit: "bpm", tint: IronTheme.metricHeartRate),
                        detail: "Range \(low)–\(high) bpm"
                    )
                }
            }
            .contentTransition(reduceMotion ? .opacity : .numericText())
            .contentShape(Rectangle())
            .onTapGesture { selectedPointID = nil }
            .animation(IronMotion.preferred(.snappy, reduceMotion: reduceMotion), value: selectedPoint?.id)

            heartRatePlot(points, average: average, selectedPoint: selectedPoint)
                .frame(height: dynamicTypeSize.isAccessibilitySize ? 200 : 150)
        }
        .sensoryFeedback(.selection, trigger: selectedPointID) { _, id in id != nil }
        .onDisappear { selectedPointID = nil }
    }

    private func heartRatePlot(_ points: [ChartPoint], average: Double, selectedPoint: ChartPoint?) -> some View {
        let low = points.map(\.bpm).min() ?? average
        let high = points.map(\.bpm).max() ?? average
        let floor = max(0, (low - 10).rounded(.down))
        let ceiling = (high + 10).rounded(.up)
        let totalMinutes = max(points.last?.minutes ?? 1, 1)

        return Chart {
            ForEach(points) { point in
                LineMark(x: .value("Minute", point.minutes), y: .value("BPM", point.bpm))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(IronTheme.metricHeartRate)
                    .opacity(selectedPoint == nil ? 1 : IronChartEmphasis.dimmed)
            }
            RuleMark(y: .value("Average", average))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(IronTheme.secondaryText.opacity(0.6))
            if let selectedPoint {
                RuleMark(x: .value("Selected minute", selectedPoint.minutes))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(IronTheme.secondaryText.opacity(0.45))
                PointMark(
                    x: .value("Minute", selectedPoint.minutes),
                    y: .value("BPM", selectedPoint.bpm)
                )
                .symbolSize(64)
                .foregroundStyle(IronTheme.metricHeartRate)
            }
        }
        .chartXScale(domain: 0...totalMinutes)
        .chartYScale(domain: floor...ceiling)
        .ironValueAxis(.automatic(desiredCount: 3)) { $0.formatted(.number.precision(.fractionLength(0))) }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: dynamicTypeSize.isAccessibilitySize ? 2 : 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(IronTheme.outline)
                AxisValueLabel(anchor: .topLeading) {
                    if let minutes = value.as(Double.self) {
                        Text("\(Int(minutes))m")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(IronTheme.secondaryText)
                    }
                }
            }
        }
        .chartXSelection(value: Binding<Double?>(
            get: { selectedPoint?.minutes },
            set: { minute in
                selectedPointID = minute.flatMap { minute in
                    points.min { abs($0.minutes - minute) < abs($1.minutes - minute) }?.id
                }
            }
        ))
        // Replace Charts' immediate drag with a hold-gated UIKit recognizer.
        // A pan before the hold succeeds remains available to the enclosing scroll view.
        .chartGesture { _ in
            SpatialTapGesture().onEnded { _ in selectedPointID = nil }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    let frame = geometry[plotFrame]
                    WorkoutHeartRateScrubber(
                        onChanged: { x in
                            proxy.selectXValue(at: min(max(x, 0), frame.width))
                        },
                        onEnded: { selectedPointID = nil }
                    )
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .accessibilityHidden(true)
                }
            }
        }
    }

    private func elapsedTime(at point: ChartPoint) -> String {
        let seconds = Int(max(0, point.minutes * 60).rounded())
        let remainder = seconds % 60
        return "\(seconds / 60):\(remainder < 10 ? "0" : "")\(remainder)"
    }

    private func chartAccessibilityValue(_ points: [ChartPoint], average: Double, maximum: Double) -> String {
        let summary = "Average \(Int(average.rounded())) beats per minute, maximum \(Int(maximum.rounded()))"
        guard let selectedPoint = points.first(where: { $0.id == selectedPointID }) else { return summary }
        return "\(summary). Selected \(Int(selectedPoint.bpm.rounded())) beats per minute at \(elapsedTime(at: selectedPoint)) elapsed"
    }

    private func adjustSelection(_ direction: AccessibilityAdjustmentDirection, in points: [ChartPoint]) {
        guard !points.isEmpty else { return }
        let index = points.firstIndex { $0.id == selectedPointID }
        switch direction {
        case .increment:
            selectedPointID = points[min(index.map { $0 + 1 } ?? 0, points.count - 1)].id
        case .decrement:
            selectedPointID = points[max(index.map { $0 - 1 } ?? points.count - 1, 0)].id
        @unknown default:
            break
        }
    }

    /// Watch sessions record every few seconds; 30-second means keep an hour
    /// under ~120 marks without flattening the effort peaks much.
    private func chartPoints(_ samples: [HealthManager.WorkoutVitals.HeartRatePoint]) -> [ChartPoint] {
        guard samples.count > 1 else {
            return samples.map { ChartPoint(id: 0, minutes: $0.date.timeIntervalSince(start) / 60, bpm: $0.bpm) }
        }
        let bucketSeconds: TimeInterval = samples.count > 240 ? 30 : 0
        guard bucketSeconds > 0 else {
            return samples.enumerated().map {
                ChartPoint(id: $0.offset, minutes: max(0, $0.element.date.timeIntervalSince(start)) / 60, bpm: $0.element.bpm)
            }
        }
        let grouped = Dictionary(grouping: samples) {
            Int(max(0, $0.date.timeIntervalSince(start)) / bucketSeconds)
        }
        return grouped.keys.sorted().map { bucket in
            let values = grouped[bucket]!.map(\.bpm)
            return ChartPoint(
                id: bucket,
                minutes: (Double(bucket) + 0.5) * bucketSeconds / 60,
                bpm: values.reduce(0, +) / Double(values.count)
            )
        }
    }

    // MARK: Loading

    @MainActor
    private func load(requestAccessIfNeeded: Bool = false) async {
        state = .loading
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ironDemoVitals") {
            state = .loaded(Self.demoVitals(start: start, end: end))
            return
        }
        #endif
        let needsRequest = await withCheckedContinuation { continuation in
            HealthManager.shared.needsVitalsReadRequest { continuation.resume(returning: $0) }
        }
        guard !Task.isCancelled else { return }
        if needsRequest {
            guard requestAccessIfNeeded else {
                state = .needsAccess
                return
            }
            let result = await withCheckedContinuation { continuation in
                HealthManager.shared.requestVitalsReadPermission { continuation.resume(returning: $0) }
            }
            guard !Task.isCancelled else { return }
            guard case .success = result else {
                state = .needsAccess
                return
            }
        }
        let vitals = await withCheckedContinuation { continuation in
            HealthManager.shared.fetchWorkoutVitals(start: start, end: end) { continuation.resume(returning: $0) }
        }
        guard !Task.isCancelled else { return }
        if vitals.isEmpty {
            state = .empty
        } else {
            autoLoad = true
            state = .loaded(vitals)
        }
    }

    private func requestAccess() {
        Task { await load(requestAccessIfNeeded: true) }
    }

    #if DEBUG
    private static func demoVitals(start: Date, end: Date) -> HealthManager.WorkoutVitals {
        let duration = max(end.timeIntervalSince(start), 600)
        let points = stride(from: 0.0, to: duration, by: 10).map { offset -> HealthManager.WorkoutVitals.HeartRatePoint in
            let set = sin(offset / 150 * .pi)
            let bpm = 112 + 28 * max(0, set) + 10 * (offset / duration) + 4 * sin(offset / 37)
            return .init(date: start.addingTimeInterval(offset), bpm: bpm)
        }
        return .init(heartRate: points, activeEnergyKilocalories: duration / 60 * 4.6)
    }
    #endif
}

/// A stationary hold begins selection; only then does movement scrub the chart.
/// Unlike an immediate SwiftUI drag, this fails when a normal scroll starts.
private struct WorkoutHeartRateScrubber: UIViewRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isOpaque = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true

        let hold = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.holdChanged(_:))
        )
        hold.minimumPressDuration = 0.25
        hold.allowableMovement = 10

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.tapped(_:))
        )
        tap.require(toFail: hold)
        view.addGestureRecognizer(hold)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: WorkoutHeartRateScrubber

        init(parent: WorkoutHeartRateScrubber) { self.parent = parent }

        @objc func holdChanged(_ hold: UILongPressGestureRecognizer) {
            switch hold.state {
            case .began, .changed:
                parent.onChanged(hold.location(in: hold.view).x)
            case .ended, .cancelled, .failed:
                parent.onEnded()
            default:
                break
            }
        }

        @objc func tapped(_ tap: UITapGestureRecognizer) {
            guard tap.state == .ended else { return }
            parent.onEnded()
        }
    }
}
