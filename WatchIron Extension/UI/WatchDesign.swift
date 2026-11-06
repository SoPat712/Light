import SwiftUI
import WatchKit

// Round 6 Watch palette. Keep literal colors here, never in a screen.
enum IronTheme {
    static let background = Color.black
    static let platter = Color(red: 34 / 255, green: 34 / 255, blue: 36 / 255)
    static let platterRaised = Color(red: 51 / 255, green: 51 / 255, blue: 54 / 255)
    static let glassFill = Color.white.opacity(0.16)
    static let glassFillPressed = Color.white.opacity(0.26)
    static let accent = Color(red: 10 / 255, green: 132 / 255, blue: 1)
    static let accentText = Color(red: 64 / 255, green: 156 / 255, blue: 1)
    static let accentWash = accent.opacity(0.20)
    static let accentSoft = accentWash
    static let currentExerciseWash = accent.opacity(0.16)
    static let primaryText = Color.white
    static let secondaryText = Color(red: 156 / 255, green: 156 / 255, blue: 163 / 255)
    static let tertiaryText = secondaryText.opacity(0.7)
    static let field = platterRaised
    static let tertiaryFill = Color.white.opacity(0.20)
    static let outline = Color.white.opacity(0.28)
    static let onAccent = Color.white
    static let diagramCanvas = Color.white
    static let diagramGlyph = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)
    static let metricSets = Color(red: 1, green: 159 / 255, blue: 10 / 255)
    static let metricVolume = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
    static let metricTime = Color(red: 100 / 255, green: 210 / 255, blue: 1)
    static let metricTimeContainer = metricTime.opacity(0.18)
    static let metricEffort = Color(red: 1, green: 55 / 255, blue: 95 / 255)
    static let metricRecord = Color(red: 1, green: 214 / 255, blue: 10 / 255)
    static let metricHeartRate = Color(red: 1, green: 69 / 255, blue: 58 / 255)
    static let metricEnergy = metricSets
    static let metricEnergyUnit = Color(red: 199 / 255, green: 122 / 255, blue: 0)
    static let success = metricVolume
    static let warning = metricSets
    static let danger = metricHeartRate
    static let destructiveText = Color(red: 1, green: 105 / 255, blue: 97 / 255)
    static let destructiveWash = danger.opacity(0.26)
    static let settingsGray = Color(red: 99 / 255, green: 99 / 255, blue: 102 / 255)
    static let settingsCyan = Color(red: 50 / 255, green: 173 / 255, blue: 230 / 255)
    static let setDrop = Color(red: 94 / 255, green: 92 / 255, blue: 230 / 255)
    static let setDropText = Color(red: 165 / 255, green: 163 / 255, blue: 1)
    static let effortInactive = Color(red: 38 / 255, green: 38 / 255, blue: 40 / 255)
    // Gym plate color code: 25 kg red, 20 kg / 45 lb blue, 15 kg / 35 lb yellow, 10 kg / 25 lb green.
    static let plateRed = metricHeartRate
    static let plateBlue = accent
    static let plateYellow = metricRecord
    static let plateGreen = metricVolume
    static let plateWhite = Color(red: 229 / 255, green: 229 / 255, blue: 234 / 255)
    static let plateSteel = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)
    static let barSteel = Color(red: 174 / 255, green: 174 / 255, blue: 178 / 255)
    static let machineFrame = plateSteel
    static let machineRail = barSteel
    static let machineCarriage = platterRaised
    static let machineFootplate = plateWhite
    static let machineSeat = secondaryText
    static let compactCornerRadius: CGFloat = 13
    static let upNextCornerRadius: CGFloat = 15
    static let controlHeight: CGFloat = 44
    static let workoutGutter: CGFloat = 8
    static let pageIndicatorClearance: CGFloat = 16

    static func setTint(_ tag: String?) -> Color {
        switch tag {
        case "warmUp": return metricSets
        case "dropSet": return setDropText
        case "failure": return destructiveText
        default: return primaryText
        }
    }
    static func setBadge(_ tag: String?, completed: Bool = false) -> Color {
        switch tag {
        case "warmUp": return metricSets.opacity(0.26)
        case "dropSet": return setDrop.opacity(0.34)
        case "failure": return danger.opacity(0.26)
        default: return completed ? accent.opacity(0.40) : platterRaised
        }
    }
    static func setFill(_ tag: String?) -> Color {
        switch tag {
        case "warmUp": return metricSets.opacity(0.16)
        case "dropSet": return setDrop.opacity(0.22)
        case "failure": return danger.opacity(0.16)
        default: return accent.opacity(0.22)
        }
    }
    static func setIconColor(_ tag: String?) -> Color {
        switch tag {
        case "warmUp": return metricSets
        case "dropSet": return setDrop
        case "failure": return danger
        default: return settingsGray
        }
    }
    static func effortColor(_ rating: Int) -> Color {
        switch rating {
        case 1...3: return metricVolume
        case 4...6: return metricRecord
        case 7...8: return metricSets
        case 9...10: return danger
        default: return accentText
        }
    }
}

extension Font {
    static func ironMetric(size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .default).monospacedDigit()
    }
}

enum IronMotion {
    static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.82)
    static let fade = Animation.easeOut(duration: 0.14)
    static func preferred(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : animation
    }
}

extension View {
    /// Action buttons only. Data rows own their semantic surface and use .plain.
    @ViewBuilder func watchGlassButton(prominent: Bool = false, destructive: Bool = false) -> some View {
        if destructive {
            buttonStyle(WatchDestructiveButtonStyle())
        } else if prominent {
            buttonStyle(WatchPrimaryButtonStyle())
        } else {
            buttonStyle(WatchSecondaryButtonStyle())
        }
    }

    /// The one primary-action surface: Liquid Glass tinted Iron blue, sized by its
    /// caller. Native `.glassProminent` stops short of full width on larger Watches.
    @ViewBuilder func watchPrimaryCapsule() -> some View {
        if #available(watchOS 26.0, *) {
            glassEffect(.regular.tint(IronTheme.accent), in: Capsule())
        } else {
            background(IronTheme.accent, in: Capsule())
        }
    }

    @ViewBuilder fileprivate func watchDestructiveCapsule() -> some View {
        if #available(watchOS 26.0, *) {
            glassEffect(.regular.tint(IronTheme.danger), in: Capsule())
        } else {
            background(IronTheme.danger, in: Capsule())
        }
    }

    @ViewBuilder fileprivate func watchSecondaryCapsule(isPressed: Bool) -> some View {
        if #available(watchOS 26.0, *) {
            background {
                if isPressed {
                    Capsule(style: .continuous).fill(IronTheme.glassFillPressed)
                }
            }
            .glassEffect(.regular, in: Capsule(style: .continuous))
        } else {
            background(isPressed ? IronTheme.glassFillPressed : IronTheme.glassFill,
                       in: Capsule(style: .continuous))
        }
    }

    @ViewBuilder func watchNeutralCapsule() -> some View {
        if #available(watchOS 26.0, *) {
            glassEffect(.regular, in: Capsule())
        } else {
            background(IronTheme.platterRaised, in: Capsule())
        }
    }

    func watchPlatter(_ color: Color = IronTheme.platter, verticalPadding: CGFloat = 6,
                      minHeight: CGFloat? = nil) -> some View {
        padding(.horizontal, 8).padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .background(color, in: RoundedRectangle(cornerRadius: IronTheme.compactCornerRadius, style: .continuous))
    }
    func watchVitalsInset(showsBack: Bool = true, showsVitals: Bool = true, showsTrailingButton: Bool = false) -> some View {
        modifier(WatchVitalsInset(showsBack: showsBack, showsVitals: showsVitals, showsTrailingButton: showsTrailingButton))
    }

    // Fades scrolled content out behind the toolbar so the vitals stay legible.
    fileprivate func watchHardTopEdge(_ enabled: Bool) -> some View {
        overlay(alignment: .top) {
            if enabled {
                GeometryReader { proxy in
                    LinearGradient(stops: [.init(color: IronTheme.background, location: 0.8),
                                           .init(color: IronTheme.background.opacity(0), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: proxy.safeAreaInsets.top + 8)
                        .frame(maxWidth: .infinity)
                        .offset(y: -proxy.safeAreaInsets.top)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

/// Full-width primary action, so it always lines up with the tiles and cards.
struct WatchPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight)
            .frame(maxHeight: .infinity)
            .foregroundStyle(IronTheme.onAccent)
            .watchPrimaryCapsule()
            .contentShape(Capsule(style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// Full-width destructive confirmation without stretching in an unbounded layout.
struct WatchDestructiveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight)
            .foregroundStyle(IronTheme.onAccent)
            .watchDestructiveCapsule()
            .contentShape(Capsule(style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// The approved neutral action treatment; never apply it to a workout/data row.
struct WatchSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight)
            .watchSecondaryCapsule(isPressed: configuration.isPressed)
            .contentShape(Capsule(style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// Flat scrolling keeps rows at constant width and retains their approved surfaces.
struct WatchContentList<Content: View>: View {
    private let clearsPageDots: Bool
    private let extraBottomInset: CGFloat
    private let content: Content

    /// Lists run to the screen edge with just enough inset to clear its corners.
    /// A list on a dotted page keeps the system margin so it also clears the dots.
    init(clearsPageDots: Bool = false, extraBottomInset: CGFloat = 0, @ViewBuilder content: () -> Content) {
        self.clearsPageDots = clearsPageDots
        self.extraBottomInset = extraBottomInset
        self.content = content()
    }

    var body: some View {
        #if DEBUG
        list.defaultScrollAnchor(ProcessInfo.processInfo.arguments.contains("--watch-list-bottom") ? .bottom : nil)
        #else
        list
        #endif
    }

    private var list: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    content
                }
                .padding(.horizontal, 2)
                .padding(.bottom, (clearsPageDots ? 30 : proxy.size.width < 180 ? 8 : 14) + extraBottomInset)
            }
            .scrollIndicators(.hidden)
        }
        .ignoresSafeArea(.container, edges: clearsPageDots ? [] : .bottom)
    }
}

// Heart rate and calories ride in the leading toolbar slot during a workout.
struct WatchVitalsInset: ViewModifier {
    var showsBack = true
    var showsVitals = true
    var showsTrailingButton = false
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    @Environment(\.isLuminanceReduced) private var reducedLuminance
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .headline) private var clockReserve: CGFloat = 52

    private let toolbarButtonWidth: CGFloat = 34
    private let toolbarSpacing: CGFloat = 4

    /// watchOS hides its clock if the leading item consumes the clock's room.
    /// Budget the pill after both toolbar controls, including their spacing.
    private var vitalsWidth: CGFloat {
        let screen = WKInterfaceDevice.current().screenBounds.width
        // Margins measured on the owner's Ultra (2026-11-01): the device draws this
        // row about 1.5 pt wider than the simulator, so trimming them (32/18 pt was
        // tried on 2026-11-05) hides the clock on device while the simulator still
        // shows it. Don't reduce these without a device check.
        // The fixed widest-value templates choose the pill's form.
        let margins: CGFloat = screen < 180 ? 22 : 34
        let back = showsBack ? toolbarButtonWidth + toolbarSpacing : 0
        let trailing = showsTrailingButton ? toolbarButtonWidth + toolbarSpacing : 0
        return max(0, screen - margins - clockReserve - back - trailing)
    }

    private var activeSnapshot: WatchWorkoutSnapshot? {
        guard let snapshot = store.workoutSnapshot, !snapshot.isFinishedRecord else { return nil }
        return snapshot
    }

    func body(content: Content) -> some View {
        content
            .opacity(reducedLuminance && activeSnapshot != nil ? 0.45 : 1)
            .watchHardTopEdge(activeSnapshot != nil)
            // A leading toolbar item replaces the system back button, so while a
            // workout runs the toolbar carries its own back button beside the vitals.
            .navigationBarBackButtonHidden(activeSnapshot != nil && showsVitals)
            .toolbar {
                if showsVitals, let snapshot = activeSnapshot {
                    ToolbarItem(placement: .topBarLeading) {
                        HStack(alignment: .center, spacing: toolbarSpacing) {
                            if showsBack {
                                Button { dismiss() } label: {
                                    Image(systemName: "chevron.backward")
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(IronTheme.primaryText)
                                        .frame(width: toolbarButtonWidth, height: 34)
                                        .background(IronTheme.glassFill, in: Circle())
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Back")
                            }
                            if !showsTrailingButton {
                                WatchVitalsRow(manager: store.workoutSessionManager, snapshot: snapshot, availableWidth: vitalsWidth)
                                    .privacySensitive(false).unredacted()
                            }
                        }
                    }
                }
            }
    }
}

/// Rating context stays below the toolbar, clear of the clock and confirmation.
struct WatchRatingVitalsHeader: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    let title: String
    let context: String
    let textSize: CGFloat
    var showsVitals = true

    static func vitalsHeight(textSize: CGFloat) -> CGFloat { max(18, textSize * 15 / 13 * 1.2) }
    static func contextHeight(textSize: CGFloat) -> CGFloat { max(16, textSize * 1.2) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsVitals, let snapshot = store.workoutSnapshot, !snapshot.isFinishedRecord {
                vitals(snapshot: snapshot)
                    .privacySensitive(false).unredacted()
                    .frame(height: Self.vitalsHeight(textSize: textSize), alignment: .leading)
            }
            heading
                .frame(height: Self.contextHeight(textSize: textSize), alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var contextParts: [String] {
        context.components(separatedBy: "·").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private var headingParts: (prefix: String, detail: String) {
        // The caller supplies exercise · Set N · measurements, using nonbreaking
        // spaces. Keep the full original context for VoiceOver below.
        if title == "RPE", let setIndex = contextParts.lastIndex(where: {
            $0.split(whereSeparator: { $0.isWhitespace }).first == "Set"
        }) {
            return (contextParts[setIndex], contextParts.prefix(setIndex).joined(separator: " · "))
        }
        // Session context is workout title · elapsed; only the title is needed
        // visually when space is scarce.
        return (title == "RPE" ? title : "Effort", title == "RPE" ? context : contextParts.first ?? "")
    }

    private var heading: some View {
        let parts = headingParts
        return HStack(spacing: 4) {
            Text(parts.prefix)
                .bold().foregroundStyle(IronTheme.primaryText)
                .fixedSize()
            if !parts.detail.isEmpty {
                Text("·").foregroundStyle(IronTheme.secondaryText).fixedSize()
                Text(parts.detail)
                    .foregroundStyle(IronTheme.secondaryText)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.ironMetric(size: textSize, weight: .regular))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(context)
    }

    @ViewBuilder private func vitals(snapshot: WatchWorkoutSnapshot) -> some View {
        let manager = store.workoutSessionManager
        #if DEBUG
        if snapshot.isHealthTestWorkout || manager?.healthTestMode == true {
            VitalsLine(heartRate: "—", energy: "--", textSize: textSize)
        } else {
            measurements(manager: manager, snapshot: snapshot)
        }
        #else
        measurements(manager: manager, snapshot: snapshot)
        #endif
    }

    @ViewBuilder private func measurements(manager: WorkoutSessionManager?, snapshot: WatchWorkoutSnapshot) -> some View {
        if let manager, manager.uuid == snapshot.workoutID {
            LiveVitals(manager: manager, textSize: textSize)
        } else {
            VitalsLine(heartRate: "—", energy: WatchNumber.whole(snapshot.activeEnergyKilocalories), textSize: textSize)
        }
    }

    // Sensor observation stays in a leaf, just like the shared toolbar vitals.
    // Keep its five-second cadence and 30-second stale-reading rule.
    private struct LiveVitals: View {
        @ObservedObject var manager: WorkoutSessionManager
        @Environment(\.isLuminanceReduced) private var reducedLuminance
        let textSize: CGFloat

        var body: some View {
            TimelineView(.periodic(from: Date(), by: reducedLuminance ? 60 : 5)) { context in
                VitalsLine(heartRate: heartRate(at: context.date),
                           energy: WatchNumber.whole(manager.burnedCalories), textSize: textSize)
            }
        }

        private func heartRate(at date: Date) -> String {
            guard let value = manager.mostRecentHeartRate, value.isFinite, value > 0,
                  let sampleDate = manager.mostRecentHeartRateDate,
                  (-5...30).contains(date.timeIntervalSince(sampleDate)) else { return "—" }
            return WatchNumber.whole(value)
        }
    }

    private struct VitalsLine: View {
        let heartRate: String
        let energy: String
        let textSize: CGFloat

        var body: some View {
            HStack(spacing: 6) {
                metric("heart.fill", value: heartRate, color: IronTheme.metricHeartRate)
                metric("flame.fill", value: energy, color: IronTheme.metricEnergy)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel((heartRate == "—" ? "Heart rate unavailable" : "Heart rate \(heartRate) beats per minute")
                                + ", \(energy) active calories")
        }

        private func metric(_ symbol: String, value: String, color: Color) -> some View {
            HStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: textSize, weight: .semibold))
                Text(value).font(.ironMetric(size: textSize * 15 / 13, weight: .semibold))
            }
            .foregroundStyle(value == "—" ? IronTheme.secondaryText : color)
            .fixedSize()
        }
    }
}

struct WatchSectionTitle: View {
    let title: String
    var body: some View {
        Text(title).font(.footnote.weight(.semibold)).foregroundStyle(IronTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
    }
}

struct WatchActionLabel: View {
    let title: String
    var symbol: String? = nil
    /// Shown instead of wrapping when `title` doesn't fit on one line.
    var compactTitle: String? = nil
    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
            if let compactTitle {
                ViewThatFits(in: .horizontal) {
                    Text(title).lineLimit(1)
                    Text(compactTitle).lineLimit(1)
                }.accessibilityLabel(title)
            } else {
                Text(title).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.ironMetric(.body, weight: .semibold)).frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }
}

struct WatchStepGlyph: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol).font(.body.weight(.semibold)).frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}

/// One option-row icon treatment, shared with Watch Settings.
struct WatchSettingsIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol).font(.body.weight(.semibold))
            .foregroundStyle(IronTheme.onAccent)
            .frame(width: 28, height: 28).background(color, in: Circle())
            .accessibilityHidden(true)
    }
}

struct WatchSettingsLabel: View {
    let title: String
    let symbol: String
    let color: Color
    var value: String? = nil
    var valueColor: Color = IronTheme.secondaryText
    var destructive = false
    var metricValue = true
    var valueLineLimit: Int? = nil
    var body: some View {
        HStack(spacing: 7) {
            WatchSettingsIcon(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 2) { titleText; valueText }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .watchPlatter(verticalPadding: 4, minHeight: 46)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
    private var titleText: some View {
        Text(title).font(.body.weight(.semibold)).foregroundStyle(destructive ? IronTheme.destructiveText : IronTheme.primaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder private var valueText: some View {
        if let value {
            Text(value)
                .font(metricValue ? .ironMetric(.footnote, weight: .semibold) : .footnote.weight(.semibold))
                .foregroundStyle(valueColor)
                .lineLimit(valueLineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct WatchMetricValue: View {
    let value: String
    let unit: String
    let color: Color
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value).font(.ironMetric(.headline, weight: .semibold)).foregroundStyle(color)
            Text(unit).font(.footnote.weight(.semibold)).foregroundStyle(IronTheme.secondaryText)
        }.accessibilityElement(children: .combine)
    }
}

struct WatchProgressCells: View {
    let sets: [WatchWorkoutSet]
    var maximumCellWidth: CGFloat? = nil
    var spacing: CGFloat = 2
    var body: some View {
        HStack(spacing: spacing) {
            ForEach(sets) { set in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(set.completed ? IronTheme.accent : IronTheme.tertiaryFill)
                    .frame(maxWidth: maximumCellWidth ?? .infinity).frame(height: 4)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("\(sets.filter(\.completed).count) of " + WatchNumber.count(sets.count, "set") + " done")
    }
}

struct WatchSessionMetrics: View {
    let snapshot: WatchWorkoutSnapshot
    var includesVolume = true
    @Environment(\.isLuminanceReduced) private var reducedLuminance
    var body: some View {
        TimelineView(.periodic(from: Date(), by: reducedLuminance ? 60 : 1)) { context in
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    elapsed(at: context.date)
                    Text("·")
                    counts
                    if includesVolume { Text("·"); volume }
                }
                // Small cases: time and sets on one line, tracked totals below.
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) { elapsed(at: context.date); Text("·"); counts }
                    if includesVolume { volume }
                }
                VStack(alignment: .leading, spacing: 2) {
                    elapsed(at: context.date); counts
                    if includesVolume { volume }
                }
            }.font(.ironMetric(.footnote, weight: .semibold)).foregroundStyle(IronTheme.secondaryText)
        }
    }
    private func elapsed(at date: Date) -> some View {
        Text(WatchNumber.elapsed(snapshot, at: date, reduced: reducedLuminance))
            .foregroundStyle(IronTheme.metricTime)
    }
    private var counts: some View {
        HStack(spacing: 0) {
            Text("\(snapshot.completedSets.count)").foregroundStyle(IronTheme.metricSets)
            Text("/" + WatchNumber.count(snapshot.allSets.count, "set")).foregroundStyle(IronTheme.secondaryText)
        }
    }
    private var volume: some View {
        WatchCompletedSetTotals(exercises: snapshot.exercises).text(unit: snapshot.weightUnit ?? .kilogram)
    }
}

struct WatchWorkoutSummaryRow: View {
    let title: String
    let exercises: [WatchWorkoutExercise]
    var date: Date? = nil
    var duration: TimeInterval? = nil
    var unit: WatchWorkoutWeightUnit = .kilogram
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline).foregroundStyle(IronTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let date {
                Text(WatchNumber.dateAndTime(date)).font(.footnote).foregroundStyle(IronTheme.secondaryText)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { summaryMetrics }
                VStack(alignment: .leading, spacing: 2) { summaryMetrics }
            }.font(.ironMetric(.footnote, weight: .semibold))
            if date == nil {
                Text(WatchWorkoutSummary.muscles(exercises)).font(.footnote).foregroundStyle(IronTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
    @ViewBuilder private var summaryMetrics: some View {
        if let duration {
            Text(WatchNumber.duration(duration)).foregroundColor(IronTheme.metricTime)
            + Text(" · ").foregroundColor(IronTheme.secondaryText)
            + Text(WatchNumber.count(exercises.flatMap(\.sets).filter(\.completed).count, "set")).foregroundColor(IronTheme.metricSets)
            + Text(" · ").foregroundColor(IronTheme.secondaryText)
            + WatchCompletedSetTotals(exercises: exercises).text(unit: unit)
        } else {
            Text(WatchNumber.count(exercises.flatMap(\.sets).count, "set")).foregroundStyle(IronTheme.metricSets)
            Text("· " + WatchNumber.count(exercises.count, "exercise")).foregroundStyle(IronTheme.secondaryText)
        }
    }
}

/// Keep each completed set paired with its exercise so assistance and stale
/// measurements never become lifting volume or unrelated distance/time totals.
private struct WatchCompletedSetTotals {
    var volume = 0.0
    private var distance = 0.0
    private var duration: TimeInterval = 0
    private var reps = 0
    private var hasDistance = false
    private var hasDuration = false
    private var hasReps = false

    init(exercises: [WatchWorkoutExercise]) {
        for exercise in exercises {
            for set in exercise.sets where set.completed {
                let type = exercise.effectiveTrackingType(for: set)
                volume += type.volume(weight: set.weight ?? 0, reps: set.reps ?? 0)
                if type.usesDistance {
                    hasDistance = true
                    if let value = set.distance, value.isFinite, value > 0 { distance += value }
                }
                if type.usesDuration {
                    hasDuration = true
                    if let value = set.duration, value.isFinite, value > 0 { duration += value }
                }
                if type.usesReps {
                    hasReps = true
                    reps += max(0, set.reps ?? 0)
                }
            }
        }
    }

    func text(unit: WatchWorkoutWeightUnit) -> Text {
        if volume > 0 || (!hasDistance && !hasDuration && !hasReps) {
            return Text(WatchNumber.compact(volume)).foregroundColor(IronTheme.metricVolume)
                + Text(" " + unit.symbol).font(.footnote).foregroundColor(IronTheme.secondaryText)
        }
        let time = Text(SetTrackingType.durationText(duration)).foregroundColor(IronTheme.metricTime)
            + Text(" set time").font(.footnote).foregroundColor(IronTheme.secondaryText)
        if hasDistance {
            let (value, symbol) = WatchNumber.distance(meters: distance, unit: unit)
            let distanceText = Text(value).foregroundColor(IronTheme.metricTime)
                + Text(" " + symbol).font(.footnote).foregroundColor(IronTheme.secondaryText)
            return hasDuration ? distanceText + Text(" · ").foregroundColor(IronTheme.secondaryText) + time : distanceText
        }
        if hasDuration { return time }
        return Text("\(reps)").foregroundColor(IronTheme.metricSets)
            + Text(" " + WatchNumber.noun(reps, "rep")).font(.footnote).foregroundColor(IronTheme.secondaryText)
    }
}

// watchOS draws a green bar beside the Digital Crown for every non-continuous rotation, and
// digitalCrownAccessory(.hidden) doesn't affect it. Continuous rotation has no bar but wraps at
// its ends, and may treat both ends as one position, so these pad the crown's range past the
// real limits and hold the value there.
extension View {
    func watchCrownRotation(_ value: Binding<Double>, in range: ClosedRange<Double>, by step: Double,
                            sensitivity: DigitalCrownRotationalSensitivity, haptics: Bool) -> some View {
        digitalCrownRotation(value.heldAtLimits(of: range), from: range.lowerBound - 2 * step,
                             through: range.upperBound + 2 * step, by: step, sensitivity: sensitivity,
                             isContinuous: true, isHapticFeedbackEnabled: haptics)
    }

    func watchCrownRotation(detent value: Binding<Double>, in range: ClosedRange<Double>, by step: Double,
                            sensitivity: DigitalCrownRotationalSensitivity, haptics: Bool,
                            onChange: @escaping (DigitalCrownEvent) -> Void = { _ in }) -> some View {
        digitalCrownRotation(detent: value.heldAtLimits(of: range), from: range.lowerBound - 2 * step,
                             through: range.upperBound + 2 * step, by: step, sensitivity: sensitivity,
                             isContinuous: true, isHapticFeedbackEnabled: haptics, onChange: onChange)
    }
}

private extension Binding<Double> {
    func heldAtLimits(of range: ClosedRange<Double>) -> Binding<Double> {
        // A step across most of the range can only be the crown wrapping past an end.
        let wrapDistance = (range.upperBound - range.lowerBound) * 0.75
        return Binding(get: { wrappedValue }, set: { newValue in
            guard abs(newValue - wrappedValue) < wrapDistance else { return }
            wrappedValue = Swift.min(Swift.max(newValue, range.lowerBound), range.upperBound)
        })
    }
}

// Hands the Digital Crown back to a ScrollView when a field inside it stops editing. watchOS
// only gives a ScrollView the crown when it appears or is touched; moving focus to it, directly
// or with resetFocus, leaves the crown dead. So the ScrollView is rebuilt, which also returns it
// to the top. Apply this directly to the ScrollView. It never rebuilds off screen: opening a
// NavigationLink ends editing, and rebuilding the view that holds the link locks up layout.
private struct WatchCrownReturn: ViewModifier {
    let isEditing: Bool
    @State private var generation = 0
    @State private var isOnScreen = false

    func body(content: Content) -> some View {
        content
            .id(generation)
            // Outside the id, so a rebuild doesn't count as leaving the screen.
            .background {
                Color.clear
                    .onAppear { isOnScreen = true }
                    .onDisappear { isOnScreen = false }
            }
            .onChange(of: isEditing) {
                if !isEditing && isOnScreen { generation += 1 }
            }
    }
}

extension View {
    func watchReturnsCrown(afterEditing isEditing: Bool) -> some View {
        modifier(WatchCrownReturn(isEditing: isEditing))
    }
}

// Used for optional measurements, saved-workout targets and plate weights. The active set's
// weight/reps Crown is inline in ActiveSetEditor, not a second navigation stack.
struct WatchNumericEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let unit: String
    let range: ClosedRange<Double>
    let step: Double
    let initialValue: Double
    let allowsEmpty: Bool
    let onCommit: (Double?) -> Void
    @State private var draft = 0.0
    @State private var isEmpty = false
    @FocusState private var crownFocused: Bool
    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 4) {
                Text(title).font(.headline)
                    .lineLimit(1).minimumScaleFactor(0.6)
                GeometryReader { hero in
                    Text(isEmpty ? "—" : WatchNumber.format(snapped(draft)))
                        .font(.ironMetric(size: max(1, hero.size.height * 0.8)))
                        .lineLimit(1).minimumScaleFactor(0.35)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .frame(width: hero.size.width, height: hero.size.height)
                        .contentShape(Rectangle())
                        .focusable().focused($crownFocused).focusEffectDisabled()
                        .watchCrownRotation($draft, in: (allowsEmpty ? range.lowerBound - step : range.lowerBound)...range.upperBound,
                                            by: step, sensitivity: .low, haptics: WatchFeedback.hapticsEnabled)
                        .onTapGesture { crownFocused = true }
                }
                Text(unit).font(.footnote).foregroundStyle(IronTheme.secondaryText)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .scenePadding(.horizontal)
        .navigationTitle("").watchVitalsInset(showsTrailingButton: true)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { onCommit(isEmpty ? nil : snapped(draft)); dismiss() } label: { Image(systemName: "checkmark") }
                    .accessibilityLabel("Save " + title)
            }
        }
        .onAppear {
            isEmpty = allowsEmpty && initialValue <= range.lowerBound
            draft = isEmpty ? range.lowerBound - step : snapped(initialValue)
            crownFocused = true
        }
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            crownFocused = true
        }
        .onChange(of: draft) { isEmpty = allowsEmpty && draft < range.lowerBound }
        .accessibilityValue(isEmpty ? "Not set" : "\(WatchNumber.format(snapped(draft))) \(unit)")
        .accessibilityHint(allowsEmpty ? "Turn below the minimum to clear. Use the checkmark to save." : "Use the checkmark to save.")
        .accessibilityAdjustableAction { direction in
            switch direction { case .increment: adjust(step); case .decrement: adjust(-step); @unknown default: break }
        }
    }
    private func snapped(_ value: Double) -> Double {
        min(max((value / step).rounded() * step, range.lowerBound), range.upperBound)
    }
    private func adjust(_ delta: Double) {
        draft = min(range.upperBound, max(allowsEmpty ? range.lowerBound - step : range.lowerBound, draft + delta))
        isEmpty = allowsEmpty && draft < range.lowerBound
        WatchFeedback.play(.click)
    }
}

enum WatchNumber {
    /// "1 set", "3 sets".
    static func count(_ value: Int, _ singular: String) -> String {
        "\(value) " + noun(value, singular)
    }
    static func noun(_ value: Int, _ singular: String) -> String { value == 1 ? singular : singular + "s" }
    /// Joins parts with " · " so a wrapped line never starts with the dot; the
    /// parts at `keepingTogether` never break internally.
    static func joinedForWrapping(_ parts: [String], keepingTogether: Set<Int> = []) -> String {
        parts.enumerated().filter { !$0.element.isEmpty }.map { index, part in
            keepingTogether.contains(index) ? part.replacingOccurrences(of: " ", with: "\u{00A0}") : part
        }.joined(separator: "\u{00A0}· ")
    }
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "--" }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }
    static func whole(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "--" }
        return value.formatted(.number.precision(.fractionLength(0)))
    }
    static func compact(_ value: Double) -> String {
        value >= 10_000 ? (value / 1_000).formatted(.number.precision(.fractionLength(1))) + "k" : whole(value)
    }
    static func clock(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded(.up)))
        if value >= 3_600 { return String(format: "%d:%02d:%02d", value / 3_600, value / 60 % 60, value % 60) }
        return String(format: "%d:%02d", value / 60, value % 60)
    }
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 60 else { return "<1m" }
        let minutes = max(0, Int(seconds) / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
    static func elapsed(_ snapshot: WatchWorkoutSnapshot, at date: Date, reduced: Bool) -> String {
        let seconds = max(0, (snapshot.endDate ?? date).timeIntervalSince(snapshot.startDate))
        if snapshot.isFinishedRecord { return duration(seconds) }
        return reduced ? "\(Int(seconds) / 60) min" : clock(seconds.rounded(.down))
    }
    static func dateAndTime(_ date: Date) -> String {
        let calendar = Calendar.current
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        let dated = sameYear ? date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) : date.formatted(.dateTime.month(.abbreviated).day().year())
        let day = calendar.isDateInToday(date) ? "Today" : (calendar.isDateInYesterday(date) ? "Yesterday" : dated)
        return day + " · " + date.formatted(.dateTime.hour().minute())
    }
    static func distance(meters: Double, unit: WatchWorkoutWeightUnit) -> (String, String) {
        unit == .pound ? (format(meters / 1_609.344), "mi") : (format(meters / 1_000), "km")
    }
    static func meters(displayValue: Double, unit: WatchWorkoutWeightUnit) -> Double {
        unit == .pound ? displayValue * 1_609.344 : displayValue * 1_000
    }
    static func effortName(_ value: Int) -> String {
        switch value { case 1...3: return "Easy"; case 4...6: return "Moderate"; case 7...8: return "Hard"; case 9...10: return "All Out"; default: return "Not rated" }
    }
}

enum WatchWorkoutSummary {
    static func muscles(_ exercises: [WatchWorkoutExercise]) -> String {
        var counts: [String: Int] = [:]
        for exercise in exercises {
            guard let muscle = exercise.muscleGroup?.trimmingCharacters(in: .whitespacesAndNewlines), !muscle.isEmpty else { continue }
            counts[muscle.localizedCapitalized, default: 0] += max(1, exercise.sets.count)
        }
        return counts.keys.sorted {
            counts[$0] == counts[$1] ? $0.localizedCaseInsensitiveCompare($1) == .orderedAscending : counts[$0, default: 0] > counts[$1, default: 0]
        }.prefix(3).joined(separator: ", ")
    }

    static func equipment(_ name: String) -> String? {
        let parts = name.split(separator: ":", maxSplits: 1)
        return parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
    static func meta(name: String, muscle: String?) -> String {
        [equipment(name), muscle?.localizedCapitalized].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    static func shortName(_ name: String) -> String { String(name.split(separator: ":", maxSplits: 1).first ?? Substring(name)) }

    // Same Pareto rule as WorkoutSet.isPersonalRecord. History is the existing
    // cached library; this never writes or exports a historical/imported record.
    static func recordSetIDs(in workout: WatchWorkoutSnapshot, history: [WatchWorkoutSnapshot]) -> Set<UUID> {
        let unit = workout.weightUnit ?? .kilogram
        let prior = history.filter { $0.workoutID != workout.workoutID && $0.startDate < workout.startDate }
            .map { WatchWorkoutEditing.converting($0, to: unit) }
        var result = Set<UUID>()
        for exercise in workout.exercises {
            guard let catalogID = exercise.exerciseUuid else { continue }
            let previous = prior.flatMap(\.exercises).filter { $0.exerciseUuid == catalogID }.flatMap(\.sets).filter(\.completed)
            guard !previous.isEmpty else { continue }
            var earlier: [WatchWorkoutSet] = []
            for set in exercise.sets {
                if set.completed, let weight = set.weight, let reps = set.reps, reps > 0,
                   !previous.contains(where: { ($0.weight ?? -1) >= weight && ($0.reps ?? 0) >= reps }),
                   !earlier.contains(where: { ($0.weight ?? 0) >= weight && ($0.reps ?? 0) >= reps }) { result.insert(set.id) }
                earlier.append(set)
            }
        }
        return result
    }
}

extension WatchWorkoutSnapshot {
    var recordedDuration: TimeInterval { max(0, (endDate ?? startDate).timeIntervalSince(startDate)) }
    var allSets: [WatchWorkoutSet] { exercises.flatMap(\.sets) }
    var completedSets: [WatchWorkoutSet] { allSets.filter(\.completed) }
    var volume: Double { WatchCompletedSetTotals(exercises: exercises).volume }
    var nextSet: (exercise: WatchWorkoutExercise, set: WatchWorkoutSet)? {
        guard let id = WatchWorkoutEditing.nextSet(in: self) else { return nil }
        for exercise in exercises { if let set = exercise.sets.first(where: { $0.id == id }) { return (exercise, set) } }
        return nil
    }
}
