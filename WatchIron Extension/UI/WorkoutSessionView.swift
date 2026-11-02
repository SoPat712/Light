import SwiftUI
import WatchKit
import HealthKit
import ImageIO
import CryptoKit

struct WorkoutSessionView: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    @EnvironmentObject private var navigation: WatchNavigation
    let workoutSessionManager: WorkoutSessionManager?
    @State private var editingValue = false
    #if DEBUG && targetEnvironment(simulator)
    @State private var openedDemoRoute = false
    @State private var demoLocalRoute: WatchFocusDemo.LocalRoute?
    #endif

    var body: some View {
        Group {
            if let snapshot = store.workoutSnapshot {
                if snapshot.isFinishedRecord { WatchSavedView() }
                else { pages(snapshot) }
            } else { ContentUnavailableView("No Workout", systemImage: "dumbbell") }
        }
        .navigationTitle("")
        .navigationBarBackButtonHidden(true)
        .watchVitalsInset(showsBack: false, showsVitals: navigation.workoutPage != .controls)
        .toolbar {
            if navigation.workoutPage == .controls, let snapshot = store.workoutSnapshot, !snapshot.isFinishedRecord {
                ToolbarItem(placement: .topBarLeading) { WatchControlsToolbar(snapshot: snapshot) }
            }
        }
        .onChange(of: store.persistenceFailure?.id) {
            if store.persistenceFailure != nil { WatchFeedback.play(.failure) }
        }
        #if DEBUG && targetEnvironment(simulator)
        .task {
            guard !openedDemoRoute, let snapshot = store.workoutSnapshot else { return }
            openedDemoRoute = true
            await Task.yield()
            guard !Task.isCancelled else { return }
            demoLocalRoute = WatchFocusDemo.openRouteIfRequested(snapshot: snapshot, navigation: navigation)
        }
        .navigationDestination(item: $demoLocalRoute) { route in
            switch route {
            case .notes(let exerciseID):
                WatchExerciseNotePage(exerciseID: exerciseID, kind: .exercise)
            case .plates(let exerciseID):
                if let exercise = store.workoutSnapshot?.exercises.first(where: { $0.id == exerciseID }) {
                    WatchPlateCalculatorView(targetWeight: exercise.sets.compactMap(\.weight).first ?? 0,
                        unit: store.workoutSnapshot?.weightUnit ?? store.preferredWeightUnit,
                        exerciseKey: exercise.exerciseUuid?.uuidString ?? exercise.name)
                }
            case .trackingType(let exerciseID): WatchExerciseTrackingTypePicker(exerciseID: exerciseID)
            }
        }
        #endif
    }

    private func pages(_ snapshot: WatchWorkoutSnapshot) -> some View {
        TabView(selection: $navigation.workoutPage) {
            WatchWorkoutControls(snapshot: snapshot)
                .tag(WatchWorkoutPage.controls)
            WatchNowPage(snapshot: snapshot, editingValue: $editingValue)
                .tag(WatchWorkoutPage.now)
            WatchWorkoutExercises(snapshot: snapshot)
                .tag(WatchWorkoutPage.exercises)
        }
        .tabViewStyle(.page(indexDisplayMode: editingValue ? .never : .always))
        .onChange(of: navigation.workoutPage) { editingValue = false }
    }
}

struct OfflineWorkoutView: View { var body: some View { WorkoutSessionView(workoutSessionManager: nil) } }

private struct WatchNowPage: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    @EnvironmentObject private var navigation: WatchNavigation
    let snapshot: WatchWorkoutSnapshot
    @Binding var editingValue: Bool

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 4) {
                if store.recordingError != nil { WatchRecordingFailureRow() }
                if let next = snapshot.nextSet {
                    WatchNowSet(exercise: next.exercise, set: next.set,
                                unit: snapshot.weightUnit ?? store.preferredWeightUnit,
                                editingValue: $editingValue)
                        .id(next.set.id)
                } else {
                    Spacer(minLength: 0)
                    if snapshot.exercises.isEmpty { emptyWorkout }
                    else { completedWorkout }
                    Spacer(minLength: 0)
                }
            }
            // The viewport reaches under the dots; only the first screen and
            // the final content margin reserve their clearance.
            .frame(width: max(0, proxy.size.width - 2 * IronTheme.workoutGutter), height: proxy.size.height)
            .padding(.horizontal, IronTheme.workoutGutter)
        }
        // Measure the whole page before entering the ScrollView. The dots may
        // disappear during editing, but neither the viewport nor its budget moves.
        .ignoresSafeArea(.container, edges: .bottom)
        .onAppear { navigation.setNowVisible(true, snapshot: store.workoutSnapshot) }
        .onDisappear { navigation.setNowVisible(false, snapshot: nil) }
    }

    private var emptyWorkout: some View {
        VStack(spacing: 10) {
            Text("Add your first exercise to start logging.")
                .font(.body).foregroundStyle(IronTheme.secondaryText)
                .multilineTextAlignment(.center)
            NavigationLink(value: WatchRoute.catalog(nil)) {
                WatchActionLabel(title: "Add Exercise", symbol: "plus")
            }.watchGlassButton(prominent: true)
        }.frame(maxWidth: .infinity)
    }

    private var completedWorkout: some View {
        VStack(spacing: 10) {
            Text("Every set is logged").font(.headline).multilineTextAlignment(.center)
            NavigationLink(value: WatchRoute.finish) {
                WatchActionLabel(title: "Finish", symbol: "flag.checkered")
            }.watchGlassButton(prominent: true)
        }.frame(maxWidth: .infinity)
    }
}

private struct WatchNowSet: View {
    @AppStorage("workoutHaptics") private var workoutHaptics = true
    @AppStorage(ExerciseNotes.storageKey) private var exerciseNotesData: Data?
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    @EnvironmentObject private var navigation: WatchNavigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var reducedLuminance
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var valueSize: CGFloat = 52
    @ScaledMetric(relativeTo: .caption2) private var labelLineHeight: CGFloat = 14
    let exercise: WatchWorkoutExercise
    let set: WatchWorkoutSet
    let unit: WatchWorkoutWeightUnit
    @Binding var editingValue: Bool
    @State private var focus: SetValueField?
    @State private var crown = 0.0
    @State private var crownOrigin = 0.0
    @FocusState private var crownFocused: Bool

    private var trackingType: SetTrackingType { exercise.effectiveTrackingType(for: set) }
    private var firstField: SetValueField { trackingType.watchFields[0] }
    private var secondField: SetValueField? { trackingType.watchFields.dropFirst().first }
    private var previous: String? {
        store.previousSetText(set: set, exercise: exercise, snapshot: store.workoutSnapshot, includesRPE: false)
    }

    var body: some View {
        GeometryReader { proxy in
            // This finite proposal comes from the page, including its bottom
            // safe area. Reserve the dots once, rather than subtracting that
            // safe area a second time from the tiles.
            let viewportHeight = proxy.size.height
            let bottomClearance = proxy.size.width < 180 ? 8 : IronTheme.pageIndicatorClearance
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    firstScreen(width: proxy.size.width, viewportHeight: viewportHeight, bottomClearance: bottomClearance)
                    setOptions.padding(.top, 12).padding(.bottom, bottomClearance + 8)
                }
                .frame(width: proxy.size.width, alignment: .leading)
            }
            // Large text keeps touch scrolling available so the action row stays
            // reachable while the selected tile continues to own the Crown.
            .scrollDisabled(focus != nil && !typeSize.isAccessibilitySize)
            .watchReturnsCrown(afterEditing: focus != nil)
            .digitalCrownAccessory(.hidden)
        }
        .onChange(of: crown) { persistCrown() }
        .onChange(of: editingValue) { if !editingValue { endEditing() } }
        .onChange(of: reducedLuminance) { if reducedLuminance { endEditing() } }
        .onChange(of: trackingType) {
            // The old Crown origin belongs to a different measurement. Do not
            // flush it after the phone or Exercise Options changes the type.
            crownFocused = false; focus = nil; editingValue = false
        }
        .onChange(of: unit) {
            // Already-saved values have been converted by the store. A Crown
            // origin in the old unit must not be written into the new unit.
            crownFocused = false; focus = nil; editingValue = false
        }
        .onDisappear { endEditing() }
    }

    @ViewBuilder private func firstScreen(width: CGFloat, viewportHeight: CGFloat, bottomClearance: CGFloat) -> some View {
        let actionHeight: CGFloat = width < 180 ? IronTheme.controlHeight : 50
        if typeSize.isAccessibilitySize {
            // Only accessibility sizes reflow. Each field keeps a full-size
            // number, and touch scrolling remains available during Crown edits.
            let fieldCount: CGFloat = secondField == nil ? 1 : 2
            let tileHeight = (valueSize * 1.3 + 32) * fieldCount + (fieldCount - 1) * 4
            VStack(alignment: .leading, spacing: 6) {
                setHeader
                crownTiles(width: width, height: tileHeight)
                    .frame(height: tileHeight)
                actionRow(height: max(actionHeight, valueSize), compact: width < 180)
            }
            .frame(width: width, alignment: .leading)
            .frame(minHeight: max(0, viewportHeight - bottomClearance), alignment: .top)
            .padding(.bottom, bottomClearance)
        } else {
            // Native button styles have an intrinsic capsule height. It must not
            // consume the metric budget: only the header is measured intrinsically.
            WatchNowFirstScreenLayout(viewportHeight: viewportHeight, bottomClearance: bottomClearance,
                                      actionHeight: actionHeight, actionSpacing: width < 180 ? 4 : 12,
                                      headerSpacing: width < 180 ? 2 : 4) {
                setHeader
                GeometryReader { tile in
                    crownTiles(width: tile.size.width, height: tile.size.height)
                        .frame(width: tile.size.width, height: tile.size.height)
                }
                actionRow(height: actionHeight, compact: width < 180)
            }
            .frame(width: width)
        }
    }

    private func crownTiles(width: CGFloat, height: CGFloat) -> some View {
        valueTiles(height: height, compact: width < 180)
            .focusable(focus != nil).focused($crownFocused)
            .focusEffectDisabled()
            .watchCrownRotation($crown, in: -crownMaximum...crownMaximum, by: 1, sensitivity: .medium, haptics: workoutHaptics)
    }

    private var setOptions: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let note = WatchExerciseNoteKind.exercise.text(for: exercise, preferencesData: exerciseNotesData) {
                WatchPinnedNoteRow(exerciseID: exercise.id, kind: .exercise, text: note)
            }
            if let note = WatchExerciseNoteKind.plan.text(for: exercise, preferencesData: exerciseNotesData) {
                WatchPinnedNoteRow(exerciseID: exercise.id, kind: .plan, text: note)
            }
            WatchSectionTitle(title: "Set Options")
            WatchSetOptionRows(exerciseID: exercise.id, setID: set.id)
            NavigationLink(value: WatchRoute.exerciseSettings(exercise.id)) {
                WatchSettingsLabel(title: "Exercise Options", symbol: "gearshape.fill", color: IronTheme.settingsGray)
            }.buttonStyle(.plain)
        }
    }

    private var crownMaximum: Double {
        guard let focus else { return 1 }
        return focus.maximum / focus.step
    }

    private var setHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            if typeSize.isAccessibilitySize {
                exerciseTitle.font(.headline).fixedSize(horizontal: false, vertical: true)
            } else {
                exerciseTitle.font(.headline.weight(.bold))
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            if let previous {
                ViewThatFits(in: .horizontal) {
                    setHistory(previous).fixedSize()
                    setHistory(previous.replacingOccurrences(of: " " + unit.symbol, with: "")).fixedSize()
                    setHistory(previous.replacingOccurrences(of: " " + unit.symbol, with: ""))
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
            } else { setPosition }
        }
        .foregroundStyle(IronTheme.primaryText)
        .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(exercise.name + ", set \(set.order) of \(exercise.sets.count)" + (previous.map { ", last " + $0 } ?? ""))
        .accessibilityAction(named: "Edit Set") { navigation.path.append(.set(exercise.id, set.id)) }
    }

    private func setHistory(_ previous: String) -> some View {
        (Text("Set \(set.order)/\(exercise.sets.count)").foregroundColor(IronTheme.accentText)
         + Text(" · Last " + previous).foregroundColor(IronTheme.secondaryText))
            .font(.ironMetric(.footnote, weight: .semibold))
    }

    private var exerciseTitle: some View {
        // Reuse the existing title line so the transition never covers content
        // or changes the measured header, tiles or action-row budget.
        let isNext = navigation.nextExerciseName == exercise.name
        return Text(exercise.name)
            .foregroundStyle(isNext ? IronTheme.accentText : IronTheme.primaryText)
            .contentTransition(.opacity)
            .animation(IronMotion.preferred(IronMotion.fade, reduceMotion: reduceMotion), value: isNext)
    }

    private var setPosition: some View {
        Text("Set \(set.order)/\(exercise.sets.count)")
            .font(.ironMetric(.footnote, weight: .semibold)).foregroundStyle(IronTheme.accentText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func valueTiles(height: CGFloat, compact: Bool) -> some View {
        // Budget for the label AND the metric's line height. The old calculation
        // left less room than those two lines needed, so Text shrank vertically
        // to body size even before fitting a long value horizontally.
        let fittingSize = max(20, (height - labelLineHeight - 4) / 1.15)
        return WatchSetValueTiles(exerciseName: exercise.name, set: set, unit: unit, trackingType: trackingType,
            firstField: firstField, secondField: secondField, focus: focus,
            metricSize: typeSize.isAccessibilitySize ? valueSize : fittingSize, compact: compact,
            verticalPadding: 2, allowsDeselection: true, stacksFields: typeSize.isAccessibilitySize,
            fillsPage: true,
            onSelect: select, onAdjust: { field, direction in
                let changedFocus = focus != field
                if changedFocus { select(field) }
                adjust(direction * buttonDetents, feedback: !changedFocus)
            })
    }

    private func actionRow(height: CGFloat, compact: Bool) -> some View {
        logButton(height: height, compact: compact).frame(height: height)
    }

    /// Buttons jump a plate pair (5 lb / 2.5 kg); the Crown keeps fine 0.5 steps.
    private var buttonDetents: Double { focus?.buttonDetents(unit: unit) ?? 1 }

    @ViewBuilder private func logButton(height: CGFloat, compact: Bool) -> some View {
        let button = Button {
            // Edits are already durably queued by updateCurrent, before completeSet.
            endEditing()
            navigation.logSet(exercise: exercise, set: set, store: store, fromEditor: false)
        } label: {
            WatchActionLabel(title: "Log Set", symbol: "checkmark")
                .frame(maxHeight: .infinity)
        }
        button.watchGlassButton(prominent: true).frame(height: height).disabled(navigation.isLogging)
    }

    private func select(_ field: SetValueField) {
        if focus == field { endEditing(); return }
        crownFocused = false
        crownOrigin = field.value(set, unit: unit)
        crown = 0
        focus = field
        editingValue = true
        crownFocused = true
        WatchFeedback.play(.click)
    }
    private func endEditing() {
        persistCrown()
        crownFocused = false; focus = nil; editingValue = false
    }
    private func adjust(_ direction: Double, feedback: Bool = true) {
        guard let focus else { return }
        let step = focus.step
        crown = max((-crownOrigin / step).rounded(.down), min(((focus.maximum - crownOrigin) / step).rounded(.up), crown.rounded() + direction))
        persistCrown()
        if feedback { WatchFeedback.play(.click) }
    }
    private func persistCrown() {
        guard let focus, crownFocused, trackingType.watchFields.contains(focus) else { return }
        let step = focus.step
        let value = min(focus.maximum, max(0, crownOrigin + crown.rounded() * step))
        let exerciseID = exercise.id, setID = set.id, selectedUnit = unit, selectedType = trackingType
        store.updateCurrent { snapshot in
            guard let exerciseIndex = snapshot.exercises.firstIndex(where: { $0.id == exerciseID }),
                  let setIndex = snapshot.exercises[exerciseIndex].sets.firstIndex(where: { $0.id == setID }),
                  snapshot.exercises[exerciseIndex].effectiveTrackingType(for: snapshot.exercises[exerciseIndex].sets[setIndex]) == selectedType,
                  (snapshot.weightUnit ?? store.preferredWeightUnit) == selectedUnit else { return }
            focus.apply(value, unit: selectedUnit, to: &snapshot.exercises[exerciseIndex].sets[setIndex])
        }
    }
}

private struct WatchNowFirstScreenLayout: Layout {
    let viewportHeight: CGFloat
    let bottomClearance: CGFloat
    let actionHeight: CGFloat
    let actionSpacing: CGFloat
    let headerSpacing: CGFloat

    private func rowHeights(width: CGFloat, subviews: Subviews) -> (header: CGFloat, tiles: CGFloat, actions: CGFloat) {
        let proposal = ProposedViewSize(width: width, height: nil)
        let header = max(IronTheme.controlHeight, subviews[0].sizeThatFits(proposal).height)
        let tiles = max(IronTheme.controlHeight, viewportHeight - bottomClearance - header - actionHeight - headerSpacing - actionSpacing)
        return (header, tiles, actionHeight)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 180
        let heights = rowHeights(width: width, subviews: subviews)
        return CGSize(width: width, height: heights.header + heights.tiles + heights.actions + headerSpacing + actionSpacing + bottomClearance)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let heights = rowHeights(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (index, height) in [heights.header, heights.tiles, heights.actions].enumerated() {
            let subview = subviews[index]
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height + (index == 0 ? headerSpacing : actionSpacing)
        }
    }
}

private struct WatchWorkoutControls: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    @EnvironmentObject private var navigation: WatchNavigation
    @Environment(\.dynamicTypeSize) private var typeSize
    let snapshot: WatchWorkoutSnapshot

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height - IronTheme.pageIndicatorClearance
            let width = proxy.size.width - 2 * IronTheme.workoutGutter
            if typeSize.isAccessibilitySize {
                ScrollView {
                    content.frame(width: width)
                        .frame(minHeight: max(0, height), alignment: .top)
                        .padding(.horizontal, IronTheme.workoutGutter)
                        .padding(.bottom, IronTheme.pageIndicatorClearance)
                }
            } else {
                content
                    .frame(width: width, height: height, alignment: .top)
                    .padding(.horizontal, IronTheme.workoutGutter)
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let manager = store.workoutSessionManager, manager.uuid == snapshot.workoutID {
                WatchLiveControlsMetrics(snapshot: snapshot, manager: manager)
            } else { WatchControlsMetrics(snapshot: snapshot, heartRate: "--", energy: snapshot.activeEnergyKilocalories) }
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    if let manager = store.workoutSessionManager,
                       manager.uuid == snapshot.workoutID, manager.state == .running || manager.state == .paused {
                        WatchPauseControl(manager: manager)
                    } else {
                        Button {} label: {
                            WatchWorkoutControlLabel(title: "Pause", symbol: "pause.fill",
                                                     tint: IronTheme.secondaryText, fill: IronTheme.platter)
                        }
                            .buttonStyle(.plain)
                            .disabled(true).accessibilityLabel("Pause unavailable without a recording")
                    }
                    NavigationLink(value: WatchRoute.catalog(nil)) {
                        WatchWorkoutControlLabel(title: "Exercise", symbol: "plus",
                                                 tint: IronTheme.primaryText, fill: IronTheme.platterRaised)
                    }.buttonStyle(.plain)
                }
                .frame(maxHeight: .infinity)
                HStack(spacing: 4) {
                    Button(role: .destructive) { navigation.path.append(.discard) } label: {
                        WatchWorkoutControlLabel(title: "Discard", symbol: "xmark",
                                                 tint: IronTheme.destructiveText, fill: IronTheme.destructiveWash)
                    }.buttonStyle(.plain)
                    NavigationLink(value: WatchRoute.finish) {
                        WatchWorkoutControlLabel(title: "Finish", symbol: "flag.checkered",
                                                 tint: IronTheme.accentText, fill: IronTheme.accentWash)
                    }.buttonStyle(.plain)
                }
                .frame(maxHeight: .infinity)
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct WatchControlsToolbar: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isLuminanceReduced) private var reducedLuminance
    let snapshot: WatchWorkoutSnapshot
    var body: some View {
        HStack(spacing: 4) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.backward").font(.body.weight(.semibold))
                    .frame(width: IronTheme.controlHeight, height: IronTheme.controlHeight)
            }.buttonStyle(.plain).accessibilityLabel("Back")
            TimelineView(.periodic(from: Date(), by: reducedLuminance ? 60 : 1)) { context in
                Text(WatchNumber.elapsed(snapshot, at: context.date, reduced: reducedLuminance))
                    .font(.ironMetric(.headline)).foregroundStyle(IronTheme.metricTime)
            }
        }
    }
}

private struct WatchWorkoutControlLabel: View {
    let title: String
    let symbol: String
    let tint: Color
    let fill: Color
    var body: some View {
        // Short tiles (40 mm) step down to a smaller icon instead of clipping.
        ViewThatFits(in: .vertical) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title2.weight(.semibold)).accessibilityHidden(true)
                Text(title).font(.body.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85)
            }
            VStack(spacing: 1) {
                Image(systemName: symbol).font(.body.weight(.semibold)).accessibilityHidden(true)
                Text(title).font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85)
            }
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: .infinity)
        .background(fill, in: RoundedRectangle(cornerRadius: IronTheme.upNextCornerRadius, style: .continuous))
    }
}

private struct WatchPauseControl: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    @ObservedObject var manager: WorkoutSessionManager
    var body: some View {
        Button { store.toggleWorkoutPause() } label: {
            WatchWorkoutControlLabel(title: manager.state == .paused ? "Resume" : "Pause",
                                     symbol: manager.state == .paused ? "play.fill" : "pause.fill",
                                     tint: IronTheme.warning, fill: IronTheme.warning.opacity(0.18))
        }.buttonStyle(.plain)
    }
}

private struct WatchLiveControlsMetrics: View {
    let snapshot: WatchWorkoutSnapshot
    @ObservedObject var manager: WorkoutSessionManager
    @Environment(\.isLuminanceReduced) private var reducedLuminance
    var body: some View {
        TimelineView(.periodic(from: Date(), by: reducedLuminance ? 60 : 5)) { context in
            WatchControlsMetrics(snapshot: snapshot, heartRate: WatchHeartRate.text(manager, at: context.date),
                                 energy: manager.burnedCalories)
        }
    }
}

/// Heart rate and calories lead the page in large type; logged work follows.
private struct WatchControlsMetrics: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    let snapshot: WatchWorkoutSnapshot
    let heartRate: String
    let energy: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            vitals
            // One line wherever it fits, so the control grid keeps its height.
            ViewThatFits(in: .horizontal) {
                workload.lineLimit(1).fixedSize()
                workload.font(.ironMetric(.footnote, weight: .semibold)).lineLimit(1).fixedSize()
                workload.font(.ironMetric(.footnote, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.ironMetric(.body, weight: .semibold))
            .foregroundStyle(IronTheme.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }
    @ViewBuilder private var vitals: some View {
        #if DEBUG
        // Test workouts run without a Health session, so there are no readings to show.
        if store.isHealthTestWorkout { vitalsLine(heartRate: "--", energy: "--", testMode: true) }
        else { vitalsLine(heartRate: heartRate, energy: WatchNumber.whole(energy)) }
        #else
        vitalsLine(heartRate: heartRate, energy: WatchNumber.whole(energy))
        #endif
    }
    private func vitalsLine(heartRate: String, energy: String, testMode: Bool = false) -> some View {
        // Drop the unit captions before the numbers ever truncate.
        ViewThatFits(in: .horizontal) {
            vitalsRow(heartRate: heartRate, energy: energy, units: true, testMode: testMode).fixedSize()
            vitalsRow(heartRate: heartRate, energy: energy, units: false, testMode: testMode)
        }
        .lineLimit(1).minimumScaleFactor(0.7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(testMode ? "Test mode, heart rate and calories are not recorded"
                            : "Heart rate \(heartRate) beats per minute, \(energy) active calories")
    }
    private func vitalsRow(heartRate: String, energy: String, units: Bool, testMode: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            vital(heartRate, unit: units ? "BPM" : nil, symbol: "heart.fill", color: IronTheme.metricHeartRate)
            vital(energy, unit: units ? "KCAL" : nil, symbol: "flame.fill", color: IronTheme.metricEnergy)
        }
    }
    private func vital(_ value: String, unit: String?, symbol: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(color)
            Text(value).font(.ironMetric(.title3, weight: .semibold)).foregroundStyle(color)
            if let unit { Text(unit).font(.footnote.bold()).foregroundStyle(IronTheme.secondaryText) }
        }
    }
    private var workload: Text {
        let unit = snapshot.weightUnit ?? store.preferredWeightUnit
        let tint = snapshot.trackingMetricTitle == "Volume" ? IronTheme.metricVolume
            : (snapshot.trackingMetricTitle == "Reps" ? IronTheme.metricSets : IronTheme.metricTime)
        let metricUnit = snapshot.trackingMetricUnit(unit: unit)
        return Text("\(snapshot.completedSets.count)").foregroundColor(IronTheme.metricSets)
            + Text("/" + WatchNumber.count(snapshot.allSets.count, "set") + " · ")
            + Text(snapshot.trackingMetricValue(unit: unit)).foregroundColor(tint)
            + Text(metricUnit.isEmpty ? " set time" : " " + metricUnit)
    }
}

private struct WatchWorkoutExercises: View {
    @EnvironmentObject private var navigation: WatchNavigation
    let snapshot: WatchWorkoutSnapshot
    private var groups: [[WatchWorkoutExercise]] {
        var result: [[WatchWorkoutExercise]] = []
        for exercise in snapshot.exercises {
            if let group = exercise.supersetID, result.last?.last?.supersetID == group {
                result[result.count - 1].append(exercise)
            } else { result.append([exercise]) }
        }
        return result
    }
    var body: some View {
        WatchContentList(clearsPageDots: true) {
            Text(snapshot.title ?? "Workout").font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                HStack(spacing: 4) {
                    if group.first?.supersetID != nil {
                        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(IronTheme.accent).frame(width: 3)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        if group.first?.supersetID != nil {
                            Text("SUPERSET").font(.footnote.bold()).foregroundStyle(IronTheme.accentText)
                        }
                        ForEach(group) { exercise in
                            NavigationLink(value: WatchRoute.exercise(exercise.id)) {
                                ExerciseOverviewRow(exercise: exercise, isCurrent: snapshot.nextSet?.exercise.id == exercise.id)
                            }.buttonStyle(.plain)
                        }
                    }
                }.fixedSize(horizontal: false, vertical: true)
            }
            Button { navigation.path.append(.catalog(nil)) } label: {
                WatchActionLabel(title: "Add Exercise", symbol: "plus")
            }.watchGlassButton().padding(.top, 4)
        }
    }
}

private struct ExerciseOverviewRow: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    let exercise: WatchWorkoutExercise
    let isCurrent: Bool
    private var completed: Int { exercise.sets.filter(\.completed).count }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(exercise.name).font(.headline).foregroundStyle(IronTheme.primaryText)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if let set = exercise.sets.first(where: { !$0.completed }) ?? exercise.sets.last {
                Text(set.displayText(weightUnit: store.workoutSnapshot?.weightUnit ?? store.preferredWeightUnit,
                                     trackingType: exercise.effectiveTrackingType(for: set)))
                    .font(.ironMetric(.footnote, weight: .semibold)).foregroundStyle(IronTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            WatchProgressCells(sets: exercise.sets).accessibilityHidden(true)
            Text("\(completed) of " + WatchNumber.count(exercise.sets.count, "set") + (isCurrent ? " · up next" : ""))
                .font(.ironMetric(.footnote, weight: .semibold)).foregroundStyle(IronTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(isCurrent ? IronTheme.currentExerciseWash : IronTheme.platter,
                    in: RoundedRectangle(cornerRadius: IronTheme.compactCornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct ActiveExerciseView: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    @EnvironmentObject private var navigation: WatchNavigation
    let exerciseID: UUID
    private var exercise: WatchWorkoutExercise? { store.workoutSnapshot?.exercises.first { $0.id == exerciseID } }
    var body: some View {
        WatchContentList {
            if let exercise {
                header(exercise).padding(.horizontal, 8)
                ForEach(exercise.sets) { set in
                    NavigationLink(value: WatchRoute.set(exerciseID, set.id)) {
                        WatchSetRow(set: set, trackingType: exercise.effectiveTrackingType(for: set), number: setNumber(set, in: exercise),
                                    isCurrent: store.workoutSnapshot?.nextSet?.set.id == set.id,
                                    unit: store.workoutSnapshot?.weightUnit ?? store.preferredWeightUnit)
                    }.buttonStyle(.plain)
                }
                Button { addSet(exercise) } label: { WatchActionLabel(title: "Add Set", symbol: "plus") }
                    .watchGlassButton().padding(.top, 4)
            } else { ContentUnavailableView("Exercise Removed", systemImage: "dumbbell") }
        }.navigationTitle("").watchVitalsInset()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { navigation.path.append(.exerciseSettings(exerciseID)) } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("Exercise Settings")
            }
        }
    }
    private func header(_ exercise: WatchWorkoutExercise) -> some View {
        HStack(alignment: .top, spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
                (Text("Rest " + WatchNumber.clock(exercise.restTimerDuration ?? WatchPreferences.defaultRestDuration))
                    .foregroundColor(IronTheme.metricTime)
                 + Text(exercise.supersetID.map { " · + " + partners($0) } ?? "").foregroundColor(IronTheme.accentText))
                .font(.ironMetric(.footnote, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.bottom, 4)
    }
    private func partners(_ group: UUID) -> String {
        store.workoutSnapshot?.exercises.filter { $0.id != exerciseID && $0.supersetID == group }
            .map { WatchWorkoutSummary.shortName($0.name) }.joined(separator: ", ") ?? "Superset"
    }
    private func setNumber(_ set: WatchWorkoutSet, in exercise: WatchWorkoutExercise) -> Int {
        guard let index = exercise.sets.firstIndex(where: { $0.id == set.id }) else { return set.order }
        return exercise.sets.prefix(index + 1).filter { $0.tag != "warmUp" }.count
    }
    private func addSet(_ exercise: WatchWorkoutExercise) {
        store.updateCurrent { snapshot in
            guard let index = snapshot.exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
            let source = snapshot.exercises[index].sets.last
            snapshot.exercises[index].sets.append(WatchWorkoutSet(order: snapshot.exercises[index].sets.count + 1,
                weight: source?.weight, reps: source?.reps ?? source?.maxTargetReps ?? source?.minTargetReps ?? 8,
                duration: source?.duration, distance: source?.distance,
                minTargetReps: source?.minTargetReps, maxTargetReps: source?.maxTargetReps))
            let last = snapshot.exercises[index].sets.count - 1
            let type = snapshot.exercises[index].effectiveTrackingType
            snapshot.exercises[index].sets[last].prepareForTracking(type)
        }
    }
}

private struct WatchSetRow: View {
    let set: WatchWorkoutSet
    let trackingType: SetTrackingType
    let number: Int
    let isCurrent: Bool
    let unit: WatchWorkoutWeightUnit
    var body: some View {
        HStack(spacing: 6) {
            WatchSetBadge(tag: set.tag, number: number, completed: set.completed)
            WatchSetResult(set: set, unit: unit, trackingType: trackingType).frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: set.completed ? "checkmark.circle.fill" : "circle")
                .font(.title3.weight(.semibold))
                .foregroundStyle(set.completed ? IronTheme.accent : IronTheme.outline).accessibilityHidden(true)
        }
        .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(set.completed ? IronTheme.setFill(set.tag) : IronTheme.platter,
                    in: RoundedRectangle(cornerRadius: IronTheme.compactCornerRadius, style: .continuous))
        .overlay {
            if isCurrent && !set.completed {
                RoundedRectangle(cornerRadius: IronTheme.compactCornerRadius, style: .continuous).strokeBorder(IronTheme.accent, lineWidth: 1.5)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue((set.completed ? "Done" : (isCurrent ? "Next" : "Not done")) + (set.rpe.map { ", RPE " + WatchNumber.format($0) } ?? ""))
    }
}

struct WatchSetBadge: View {
    let tag: String?
    var number = 1
    var completed = false
    var body: some View {
        Text(label).font(.ironMetric(.footnote)).foregroundStyle(IronTheme.setTint(tag))
            .frame(width: 22, height: 22).background(IronTheme.setBadge(tag, completed: completed), in: Circle())
            .accessibilityLabel(tag == nil ? "Set \(number)" : kind)
    }
    private var label: String {
        switch tag { case "warmUp": return "W"; case "dropSet": return "D"; case "failure": return "F"; default: return String(number) }
    }
    private var kind: String {
        switch tag { case "warmUp": return "Warm-up"; case "dropSet": return "Drop Set"; case "failure": return "Failure"; default: return "Normal" }
    }
}

private struct WatchSetResult: View {
    let set: WatchWorkoutSet
    let unit: WatchWorkoutWeightUnit
    let trackingType: SetTrackingType
    private func metric(_ value: String, unit: String) -> Text {
        Text(value) + Text(" " + unit).font(.footnote.weight(.semibold)).foregroundColor(IronTheme.secondaryText)
    }
    private var result: Text {
        var parts: [Text] = []
        if trackingType.usesWeight {
            parts.append(metric(trackingType.weightPrefix + WatchNumber.format(max(0, set.weight ?? 0)), unit: unit.symbol))
        }
        if trackingType.usesReps {
            let reps = set.reps ?? (set.completed ? nil : set.maxTargetReps ?? set.minTargetReps) ?? 0
            if trackingType.usesWeight, let weight = parts.first { return weight + Text(" × \(reps)") }
            parts.append(metric(String(reps), unit: WatchNumber.noun(reps, "rep")))
        }
        if trackingType.usesDistance, let distance = set.distance, distance.isFinite, distance >= 0 {
            let value = distance / (unit == .pound ? 1_609.344 : 1_000)
            parts.append(metric(value.formatted(.number.precision(.fractionLength(2))), unit: unit == .pound ? "mi" : "km"))
        }
        if trackingType.usesDuration, let duration = set.duration { parts.append(Text(SetTrackingType.durationText(duration))) }
        return parts.dropFirst().reduce(parts.first ?? Text("—")) { $0 + Text(" · ").foregroundColor(IronTheme.secondaryText) + $1 }
    }
    var body: some View {
        result.font(.ironMetric(.title3)).foregroundStyle(IronTheme.primaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private enum WatchPreviousSet {
    static func text(set: WatchWorkoutSet, exercise: WatchWorkoutExercise, snapshot: WatchWorkoutSnapshot?, history: [WatchWorkoutSnapshot], includesRPE: Bool = true) -> String? {
        guard let snapshot else { return nil }
        let previousWorkout = history.filter { $0.startDate < snapshot.startDate && $0.workoutID != snapshot.workoutID }
            .sorted { $0.startDate > $1.startDate }.first { workout in
                workout.exercises.contains { $0.exerciseUuid != nil && $0.exerciseUuid == exercise.exerciseUuid }
            }
        let converted = previousWorkout.map { WatchWorkoutEditing.converting($0, to: snapshot.weightUnit ?? .kilogram) }
        let previousExercise = converted?.exercises.first { $0.exerciseUuid == exercise.exerciseUuid }
        let previousSet = previousExercise?.sets.first { $0.order == set.order && $0.completed }
        let weight = set.previousWeight ?? previousSet?.weight
        let reps = set.previousReps ?? previousSet?.reps
        guard weight != nil || reps != nil || previousSet?.duration != nil || previousSet?.distance != nil else { return nil }
        let prior = WatchWorkoutSet(order: 1, weight: weight, reps: reps, completed: true,
                                    duration: previousSet?.duration, distance: previousSet?.distance)
        let type = previousSet.flatMap { previousExercise?.effectiveTrackingType(for: $0) } ?? exercise.effectiveTrackingType
        var result = prior.displayText(weightUnit: snapshot.weightUnit ?? .kilogram, trackingType: type)
        guard result != "—" else { return nil }
        if includesRPE, let previousSet, let rpe = previousSet.rpe,
           previousSet.weight == weight, previousSet.reps == reps { result += " · RPE " + WatchNumber.format(rpe) }
        return result
    }
}

struct WatchAddExerciseView: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    @EnvironmentObject private var navigation: WatchNavigation
    var replacingID: UUID? = nil
    var body: some View {
        WatchCatalogPicker(catalog: store.library.exercises, title: replacingID == nil ? (store.workoutSnapshot?.exercises.isEmpty == true ? "First exercise" : "Add Exercise") : "Replace Exercise") { pick in
            if let replacingID {
                store.updateCurrent { snapshot in
                    guard let index = snapshot.exercises.firstIndex(where: { $0.id == replacingID }) else { return }
                    snapshot.exercises[index].name = pick.name; snapshot.exercises[index].exerciseUuid = pick.id
                    snapshot.exercises[index].muscleGroup = pick.muscle; snapshot.exercises[index].imageURL = pick.imageURL
                    snapshot.exercises[index].imageData = nil
                    snapshot.exercises[index].trackingType = nil
                    let type = SetTrackingPreferences.override(for: pick.id)
                        ?? SetTrackingType.defaultType(name: pick.name, equipment: WatchWorkoutSummary.equipment(pick.name).map { [$0] } ?? [])
                    snapshot.exercises[index].trackingType = type.rawValue
                    for set in snapshot.exercises[index].sets.indices where !snapshot.exercises[index].sets[set].completed {
                        snapshot.exercises[index].sets[set].prepareForTracking(type)
                    }
                }
            } else {
                navigation.workoutPage = .now
                store.addExercise(pick)
                let duration = WatchPreferences.defaultRestDuration
                store.updateCurrent { snapshot in
                    guard let index = snapshot.exercises.indices.last else { return }
                    snapshot.exercises[index].restTimerDuration = duration
                }
            }
        }
    }
}

struct ActiveExerciseSettings: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    @EnvironmentObject private var navigation: WatchNavigation
    @AppStorage(ExerciseNotes.storageKey) private var exerciseNotesData: Data?
    let exerciseID: UUID
    private var exercise: WatchWorkoutExercise? { store.workoutSnapshot?.exercises.first { $0.id == exerciseID } }
    var body: some View {
        WatchContentList {
            if let exercise {
                trackingTypeRow(exercise)
                restTimerRow(exercise)
                supersetRow(exercise)
                if exercise.effectiveTrackingType.usesWeight { plateCalculatorRow(exercise) }
                if WatchWarmupPage.canOffer(for: exercise) {
                    NavigationLink(value: WatchRoute.warmup(exerciseID)) {
                        WatchSettingsLabel(title: "Warm-up Sets", symbol: "flame", color: IronTheme.metricSets)
                    }.buttonStyle(.plain)
                }
                notesSection(exercise)
                moveButton(-1, title: "Move Up", symbol: "arrow.up")
                moveButton(1, title: "Move Down", symbol: "arrow.down")
                NavigationLink(value: WatchRoute.catalog(exerciseID)) {
                    WatchSettingsLabel(title: "Replace Exercise", symbol: "arrow.triangle.2.circlepath", color: IronTheme.settingsGray)
                }.buttonStyle(.plain)
                Button(role: .destructive) { navigation.path.append(.deleteExercise(exerciseID)) } label: {
                    WatchSettingsLabel(title: "Remove Exercise", symbol: "trash.fill", color: IronTheme.danger, destructive: true)
                }.buttonStyle(.plain)
            }
        }.navigationTitle("").watchVitalsInset()
    }
    private func trackingTypeRow(_ exercise: WatchWorkoutExercise) -> some View {
        NavigationLink {
            WatchExerciseTrackingTypePicker(exerciseID: exerciseID)
        } label: {
            WatchSettingsLabel(title: "Set Type", symbol: "slider.horizontal.3", color: IronTheme.settingsGray,
                               value: exercise.effectiveTrackingType.title)
        }.buttonStyle(.plain)
    }
    private func restTimerRow(_ exercise: WatchWorkoutExercise) -> some View {
        NavigationLink(value: WatchRoute.restTimer(exerciseID)) {
            WatchSettingsLabel(title: "Rest Timer", symbol: "timer", color: IronTheme.metricTimeContainer,
                value: WatchNumber.clock(exercise.restTimerDuration ?? WatchPreferences.defaultRestDuration),
                valueColor: IronTheme.metricTime, symbolColor: IronTheme.metricTime)
        }.buttonStyle(.plain)
    }
    private func supersetRow(_ exercise: WatchWorkoutExercise) -> some View {
        NavigationLink(value: WatchRoute.superset(exerciseID)) {
            WatchSettingsLabel(title: "Superset", symbol: "link", color: IronTheme.accentWash,
                value: partnerNames(exercise), valueColor: IronTheme.accentText, symbolColor: IronTheme.accentText, metricValue: false)
        }.buttonStyle(.plain)
    }
    private func plateCalculatorRow(_ exercise: WatchWorkoutExercise) -> some View {
        NavigationLink {
            WatchPlateCalculatorView(targetWeight: exercise.sets.compactMap(\.weight).first ?? 0,
                                     unit: store.workoutSnapshot?.weightUnit ?? store.preferredWeightUnit,
                                     exerciseKey: exercise.exerciseUuid?.uuidString ?? exercise.name)
        } label: {
            WatchSettingsLabel(title: "Plate Calculator", symbol: "plusminus", color: IronTheme.platterRaised)
        }.buttonStyle(.plain)
    }
    private func notesSection(_ exercise: WatchWorkoutExercise) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            WatchSectionTitle(title: "Notes")
            ForEach(WatchExerciseNoteKind.allCases) { kind in
                let note = kind.text(for: exercise, preferencesData: exerciseNotesData)
                // A plan note is only written on iPhone, so an empty one has nothing to open here.
                if note != nil || kind != .plan {
                    NavigationLink {
                        WatchExerciseNotePage(exerciseID: exerciseID, kind: kind)
                    } label: {
                        WatchNoteLabel(title: kind.title, symbol: kind.symbol, note: note,
                                       canEdit: kind.isEditable(for: exercise))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    private func partnerNames(_ exercise: WatchWorkoutExercise) -> String {
        guard let group = exercise.supersetID else { return "None" }
        let names = store.workoutSnapshot?.exercises.filter { $0.id != exerciseID && $0.supersetID == group }
            .map(\.name).joined(separator: ", ") ?? ""
        return names.isEmpty ? "None" : "with " + names
    }
    private func moveButton(_ offset: Int, title: String, symbol: String) -> some View {
        let ids = store.workoutSnapshot?.exercises.map(\.id) ?? []
        let index = ids.firstIndex(of: exerciseID) ?? -1
        let enabled = index >= 0 && ids.indices.contains(index + offset)
        return Button {
            store.updateCurrent { snapshot in
                var order = snapshot.exercises.map(\.id)
                guard let index = order.firstIndex(of: exerciseID), order.indices.contains(index + offset) else { return }
                order.swapAt(index, index + offset)
                WatchWorkoutEditing.reorder(exerciseIDs: order, in: &snapshot)
            }
        } label: {
            WatchSettingsLabel(title: title, symbol: symbol, color: IronTheme.settingsGray)
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
            .accessibilityLabel("Move " + (exercise?.name ?? "exercise") + (offset < 0 ? " up" : " down"))
    }
}

private struct WatchExerciseTrackingTypePicker: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    @Environment(\.dismiss) private var dismiss
    let exerciseID: UUID
    private var exercise: WatchWorkoutExercise? { store.workoutSnapshot?.exercises.first { $0.id == exerciseID } }
    var body: some View {
        List {
            Section {
                ForEach(SetTrackingType.allCases) { type in
                    Button {
                        store.setTrackingType(type, exerciseID: exerciseID)
                        WatchFeedback.play(.click)
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            Text(type.title).font(.body).foregroundStyle(IronTheme.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if exercise?.effectiveTrackingType == type {
                                Image(systemName: "checkmark").foregroundStyle(IronTheme.accentText).accessibilityHidden(true)
                            }
                        }.frame(minHeight: IronTheme.controlHeight)
                    }
                    .accessibilityValue(exercise?.effectiveTrackingType == type ? "Selected" : "")
                    .accessibilityAddTraits(exercise?.effectiveTrackingType == type ? .isSelected : [])
                }
            } footer: { Text("Applies to unfinished sets. Completed results are kept.") }
        }.navigationTitle("Set Type").watchVitalsInset()
    }
}

struct ActiveRestTimerPicker: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    let exerciseID: UUID
    var body: some View {
        let exercise = store.workoutSnapshot?.exercises.first { $0.id == exerciseID }
        WatchRestTimerPicker(context: exercise?.name ?? "Exercise", initialValue: exercise?.restTimerDuration ?? WatchPreferences.defaultRestDuration) { value in
            store.updateCurrent { snapshot in
                guard let index = snapshot.exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
                snapshot.exercises[index].restTimerDuration = value
            }
        }
    }
}

private struct WatchPickerFirstScreenBudget {
    let size: CGSize
    let headerHeight: CGFloat
    let spacing: CGFloat = 4
    var compact: Bool { size.width < 180 }
    var bottomClearance: CGFloat { compact ? 6 : 10 }
    var buttonHeight: CGFloat { compact ? IronTheme.controlHeight : 52 }
    var contentHeight: CGFloat { max(0, size.height - bottomClearance) }
    var heroHeight: CGFloat {
        max(IronTheme.controlHeight, contentHeight - headerHeight - buttonHeight - spacing * 2)
    }
}

struct WatchRestTimerPicker: View {
    @AppStorage("workoutHaptics") private var workoutHaptics = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    let context: String
    let initialValue: TimeInterval
    let onCommit: (TimeInterval) -> Void
    @State private var draft = 120.0
    @FocusState private var crownFocused: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var timeSize: CGFloat = 52
    @ScaledMetric(relativeTo: .footnote) private var headerSize: CGFloat = 13
    private var seconds: TimeInterval { min(900, max(0, (draft / 15).rounded() * 15)) }
    var body: some View {
        GeometryReader { proxy in
            let budget = WatchPickerFirstScreenBudget(size: proxy.size, headerHeight: headerSize * 1.35)
            let page = firstScreen(budget: budget)
                .frame(width: max(0, proxy.size.width - 2 * IronTheme.workoutGutter), alignment: .leading)
                .padding(.horizontal, IronTheme.workoutGutter)
            // One screen: Crown and Done. Only accessibility sizes can outgrow it.
            if typeSize.isAccessibilitySize { ScrollView(.vertical) { page } } else { page }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .navigationTitle("").watchVitalsInset()
        .onAppear { draft = initialValue; crownFocused = true }
        .task {
            // Reassert after navigation installs the page's focus scope.
            await Task.yield()
            guard !Task.isCancelled else { return }
            crownFocused = true
        }
    }
    private func firstScreen(budget: WatchPickerFirstScreenBudget) -> some View {
        let readoutHeight = typeSize.isAccessibilitySize ? max(budget.heroHeight, timeSize * 1.3) : budget.heroHeight
        let buttonHeight = typeSize.isAccessibilitySize ? max(budget.buttonHeight, timeSize) : budget.buttonHeight
        return VStack(alignment: .leading, spacing: budget.spacing) {
            (Text("Rest Timer").bold().foregroundColor(IronTheme.primaryText)
             + Text(context.isEmpty ? "" : " · " + context).foregroundColor(IronTheme.secondaryText))
                .font(.system(size: headerSize))
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1).truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: typeSize.isAccessibilitySize ? nil : budget.headerHeight)
            readout(height: readoutHeight)
                // The Crown edits time.
                .focusable().focused($crownFocused).focusEffectDisabled()
                .watchCrownRotation($draft, in: 0...900, by: 15, sensitivity: .medium, haptics: workoutHaptics)
                .onTapGesture { crownFocused = true }
                .accessibilityLabel("Rest Timer")
                .accessibilityValue(seconds == 0 ? "Off" : WatchNumber.clock(seconds))
                .accessibilityHint("Turn the Digital Crown to adjust in 15 second steps")
                .accessibilityAdjustableAction { direction in
                    switch direction { case .increment: set(seconds + 15); case .decrement: set(seconds - 15); @unknown default: break }
                }
            Button { onCommit(seconds); dismiss() } label: {
                WatchActionLabel(title: "Done")
                    .frame(height: buttonHeight)
                    .foregroundStyle(IronTheme.onAccent)
                    .watchPrimaryCapsule()
            }.buttonStyle(.plain)
        }
        .frame(minHeight: budget.contentHeight, alignment: .top)
        .padding(.bottom, budget.bottomClearance)
    }
    private func readout(height: CGFloat) -> some View {
        Text(seconds == 0 ? "Off" : WatchNumber.clock(seconds))
            .font(.ironMetric(size: typeSize.isAccessibilitySize ? timeSize : height * 0.95))
            .foregroundStyle(IronTheme.metricTime)
            .lineLimit(1).minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity).frame(height: height)
            .contentShape(Rectangle())
            .contentTransition(reduceMotion ? .identity : .numericText())
    }
    private func set(_ value: Double) {
        withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) { draft = max(0, min(900, value)) }
        WatchFeedback.play(.click)
    }
}

/// Two side-by-side fields, the first wider, both as tall as the taller one.
struct WatchSplitRow: Layout {
    var leadingShare: CGFloat = 0.58
    var spacing: CGFloat = 4
    private func widths(_ total: CGFloat) -> (CGFloat, CGFloat) {
        let first = ((total - spacing) * leadingShare).rounded()
        return (first, max(0, total - spacing - first))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 180
        if let height = proposal.height, height.isFinite { return CGSize(width: total, height: height) }
        let (a, b) = widths(total)
        let heights = zip(subviews, [a, b]).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
        return CGSize(width: total, height: heights.max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (a, b) = widths(bounds.width)
        var x = bounds.minX
        for (subview, width) in zip(subviews, [a, b]) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

struct WatchStableValue: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String
    var body: some View {
        Text(text).font(.ironMetric(.largeTitle)).foregroundStyle(IronTheme.primaryText)
            .contentTransition(reduceMotion ? .identity : .numericText())
            .lineLimit(1).minimumScaleFactor(0.85)
    }
}

struct WatchSupersetRow: View {
    let exercise: WatchWorkoutExercise
    let selected: Bool
    var body: some View {
        HStack(spacing: 7) {
            WatchExerciseThumbnail(imageURL: exercise.imageURL, imageData: exercise.imageData, size: 26)
            Text(exercise.name).font(.body.weight(.semibold)).foregroundStyle(IronTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 18, weight: .semibold))
                .foregroundStyle(selected ? IronTheme.accent : IronTheme.outline)
                .accessibilityHidden(true)
        }.padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight, alignment: .leading)
            .background(selected ? IronTheme.accentWash : IronTheme.platter,
                        in: RoundedRectangle(cornerRadius: IronTheme.compactCornerRadius, style: .continuous))
            .accessibilityElement(children: .combine).accessibilityValue(selected ? "Selected" : "Not selected")
    }
}

struct ActiveSupersetEditor: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    @Environment(\.dismiss) private var dismiss
    let anchorID: UUID
    private var exercises: [WatchWorkoutExercise] { store.workoutSnapshot?.exercises ?? [] }
    private var anchor: WatchWorkoutExercise? { exercises.first { $0.id == anchorID } }
    var body: some View {
        WatchContentList {
            Text("Alternate sets with " + (anchor?.name ?? "Exercise"))
                .font(.footnote).foregroundStyle(IronTheme.secondaryText).padding(.bottom, 4)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 8)
            ForEach(exercises.filter { $0.id != anchorID }) { exercise in
                Button { toggle(exercise.id) } label: {
                    WatchSupersetRow(exercise: exercise, selected: anchor?.supersetID != nil && exercise.supersetID == anchor?.supersetID)
                }.buttonStyle(.plain)
            }
            if anchor?.supersetID != nil {
                Button(role: .destructive, action: removeFromSuperset) {
                    WatchSettingsLabel(title: "Remove from Superset", symbol: "link",
                                       color: IronTheme.destructiveWash, destructive: true,
                                       symbolColor: IronTheme.destructiveText)
                }.buttonStyle(.plain)
            }
        }.navigationTitle("Superset").watchVitalsInset()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { dismiss() } label: { Image(systemName: "checkmark") }.accessibilityLabel("Done")
            }
        }
    }
    private func toggle(_ id: UUID) {
        store.updateCurrent { snapshot in
            guard let anchor = snapshot.exercises.first(where: { $0.id == anchorID }) else { return }
            var selected = Set(snapshot.exercises.filter { $0.id == anchorID || (anchor.supersetID != nil && $0.supersetID == anchor.supersetID) }.map(\.id))
            if !selected.insert(id).inserted { selected.remove(id) }
            WatchWorkoutEditing.replaceSuperset(exerciseIDs: selected, anchorID: anchorID, in: &snapshot)
        }
        WatchFeedback.play(.click)
    }
    private func removeFromSuperset() {
        store.updateCurrent { snapshot in
            guard let index = snapshot.exercises.firstIndex(where: { $0.id == anchorID }) else { return }
            // Detach only this exercise; updateCurrent normalizes a leftover singleton.
            snapshot.exercises[index].supersetID = nil
        }
        WatchFeedback.play(.click)
    }
}

private extension SetTrackingType {
    var watchFields: [SetValueField] { columns.compactMap { SetValueField(rawValue: $0.rawValue) } }
}

private enum SetValueField: String {
    case weight, reps, duration, distance
    var title: String { rawValue.capitalized }
    var step: Double { switch self { case .weight: return 0.5; case .reps: return 1; case .duration: return 5; case .distance: return 0.1 } }
    var maximum: Double { switch self { case .weight: return 2_000; case .reps: return 1_000; case .duration: return 3_600; case .distance: return 1_000 } }
    func title(trackingType: SetTrackingType) -> String {
        guard self == .weight else { return title }
        return trackingType == .assistedBodyweight ? "Assistance" : (trackingType == .weightedBodyweight ? "Added Weight" : "Weight")
    }
    func tileLabel(unit: WatchWorkoutWeightUnit, trackingType: SetTrackingType) -> String {
        switch self { case .weight: return trackingType.weightPrefix + unit.symbol.uppercased(); case .reps: return "REPS"; case .duration: return "TIME"; case .distance: return unit == .pound ? "MI" : "KM" }
    }
    func stepUnit(unit: WatchWorkoutWeightUnit) -> String {
        switch self { case .weight: return unit.symbol; case .reps: return "rep"; case .duration: return "sec"; case .distance: return unit == .pound ? "mi" : "km" }
    }
    func buttonDetents(unit: WatchWorkoutWeightUnit) -> Double {
        self == .weight ? (unit == .pound ? 10 : 5) : 1
    }
    func value(_ set: WatchWorkoutSet, unit: WatchWorkoutWeightUnit) -> Double {
        switch self { case .weight: return set.weight ?? 0; case .reps: return Double(set.reps ?? set.maxTargetReps ?? set.minTargetReps ?? 0)
        case .duration: return set.duration ?? 0; case .distance: return (set.distance ?? 0) / (unit == .pound ? 1_609.344 : 1_000) }
    }
    func apply(_ value: Double?, unit: WatchWorkoutWeightUnit, to set: inout WatchWorkoutSet) {
        switch self { case .weight: set.weight = value; case .reps: set.reps = value.map { Int($0.rounded()) }; case .duration: set.duration = value
        case .distance: set.distance = value.map { WatchNumber.meters(displayValue: $0, unit: unit) } }
    }
}

/// Shared by Now and the full editor; selection and persistence stay with their
/// existing owners so paging and log/rest navigation keep the same behavior.
private struct WatchSetValueTiles: View {
    let exerciseName: String
    let set: WatchWorkoutSet
    let unit: WatchWorkoutWeightUnit
    let trackingType: SetTrackingType
    let firstField: SetValueField
    let secondField: SetValueField?
    let focus: SetValueField?
    let metricSize: CGFloat
    var compact = false
    var verticalPadding: CGFloat = 2
    var allowsDeselection = false
    var stacksFields = false
    var fillsPage = false
    let onSelect: (SetValueField) -> Void
    let onAdjust: (SetValueField, Double) -> Void

    var body: some View {
        Group {
            if let secondField {
                if stacksFields {
                    VStack(spacing: 4) { tile(firstField, size: metricSize); tile(secondField, size: metricSize) }
                } else {
                    // One fixed size per row, chosen so the widest ordinary value
                    // fits: turning the Crown never changes the font size.
                    GeometryReader { proxy in
                        let size = min(metricSize, FieldPairLayout(first: firstField, second: secondField)
                            .steadyMetricSize(rowWidth: proxy.size.width))
                        FieldPairLayout(first: firstField, second: secondField) {
                            tile(firstField, size: size); tile(secondField, size: size)
                        }
                    }
                }
            } else { tile(firstField, size: metricSize) }
        }
    }

    /// Shares depend on field types and device size, never the current number.
    /// Weight/Reps gives weight ten percentage points less than the old split.
    private struct FieldPairLayout: Layout {
        let first: SetValueField
        let second: SetValueField
        private let spacing: CGFloat = 4

        private func widths(_ total: CGFloat) -> (CGFloat, CGFloat) {
            func length(_ field: SetValueField) -> CGFloat {
                switch field { case .weight, .duration: return 7; case .distance: return 6; case .reps: return 4 }
            }
            let regularShare = length(first) / (length(first) + length(second))
            let share: CGFloat
            if first == .weight && second == .reps {
                share = total < 180 ? 0.5 : regularShare - 0.1
            } else {
                share = total < 180 && second == .reps ? min(0.6, regularShare) : regularShare
            }
            let available = max(0, total - spacing)
            let leading = (available * share).rounded()
            return (leading, available - leading)
        }

        /// Fits "188.5" (or "88:88", "88.88") in the leading tile; measured on the
        /// Watch, that string is about 2.6 em in bold fixed-width digits.
        func steadyMetricSize(rowWidth: CGFloat) -> CGFloat {
            max(1, (widths(rowWidth).0 - WatchSetValueTile.horizontalPadding * 2) / 2.65)
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let width = proposal.width ?? 180
            if let height = proposal.height, height.isFinite { return CGSize(width: width, height: height) }
            let (a, b) = widths(width)
            let heights = zip(subviews, [a, b]).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
            return CGSize(width: width, height: heights.max() ?? 0)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let (a, b) = widths(bounds.width)
            var x = bounds.minX
            for (subview, width) in zip(subviews, [a, b]) {
                subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: width, height: bounds.height))
                x += width + spacing
            }
        }
    }

    private func tile(_ field: SetValueField, size: CGFloat) -> some View {
        WatchSetValueTile(exerciseName: exerciseName, field: field, value: field.value(set, unit: unit), unit: unit, trackingType: trackingType,
            selected: focus == field, metricSize: size, compact: compact,
            verticalPadding: verticalPadding, allowsDeselection: allowsDeselection,
            fillsPage: fillsPage,
            onSelect: { onSelect(field) }, onAdjust: { onAdjust(field, $0) })
    }
}

private struct WatchSetValueTile: View {
    static let horizontalPadding: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var reducedLuminance
    let exerciseName: String
    let field: SetValueField
    let value: Double
    let unit: WatchWorkoutWeightUnit
    let trackingType: SetTrackingType
    let selected: Bool
    let metricSize: CGFloat
    let compact: Bool
    let verticalPadding: CGFloat
    let allowsDeselection: Bool
    var fillsPage = false
    let onSelect: () -> Void
    let onAdjust: (Double) -> Void
    private var text: String { field == .duration ? SetTrackingType.durationText(value) : WatchNumber.format(value) }
    private var spokenValue: String {
        switch field {
        case .duration:
            let seconds = Int(min(max(value.isFinite ? value : 0, 0), field.maximum))
            return "\(seconds / 60) minutes, \(seconds % 60) seconds"
        case .reps: return WatchNumber.count(Int(min(max(value.isFinite ? value : 0, 0), field.maximum)), "rep")
        case .weight: return text + (unit == .pound ? " pounds" : " kilograms")
        case .distance: return text + (unit == .pound ? " miles" : " kilometers")
        }
    }
    private var hint: String {
        guard selected else { return "Tap, then turn the Digital Crown" }
        return "Turn the Digital Crown." + (allowsDeselection ? " Tap again to finish editing." : "")
    }

    var body: some View {
        Button(action: onSelect) { tileContents }
        .buttonStyle(.plain)
        .accessibilityLabel(exerciseName + ", " + field.title(trackingType: trackingType))
        .accessibilityValue(spokenValue)
        .accessibilityHint(hint)
        .accessibilityAdjustableAction { direction in
            switch direction { case .increment: onAdjust(1); case .decrement: onAdjust(-1); @unknown default: break }
        }
    }

    private var tileContents: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(field.tileLabel(unit: unit, trackingType: trackingType)).font(compact || fillsPage ? .caption2.bold() : .footnote.bold())
                .foregroundStyle(selected ? IronTheme.accentText : IronTheme.secondaryText)
                .lineLimit(1).minimumScaleFactor(0.8)
                .layoutPriority(1)
            Spacer(minLength: 0)
            valueText
        }
        .padding(.horizontal, Self.horizontalPadding).padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight, maxHeight: .infinity, alignment: .leading)
        .background(selected ? IronTheme.accentWash : IronTheme.platter,
                    in: RoundedRectangle(cornerRadius: IronTheme.upNextCornerRadius, style: .continuous))
        .overlay { selectionOutline }
    }

    private var valueText: some View {
        Text(text).font(.ironMetric(size: metricSize))
            .foregroundStyle(IronTheme.primaryText)
            // Digits roll up when the value rises and down when it falls.
            .contentTransition(reduceMotion || reducedLuminance ? .identity : .numericText(value: value))
            .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: value)
            .lineLimit(1).minimumScaleFactor(fillsPage ? 0.4 : 0.55)
    }

    @ViewBuilder private var selectionOutline: some View {
        if selected {
            RoundedRectangle(cornerRadius: IronTheme.upNextCornerRadius, style: .continuous)
                .strokeBorder(IronTheme.accent, lineWidth: 2)
        }
    }
}

/// The Now page and full editor share navigation and mutations for set options.
private struct WatchSetAdjustments: View {
    let title: String
    var height: CGFloat = IronTheme.controlHeight
    var onDone: (() -> Void)? = nil
    let onAdjust: (Double) -> Void
    var body: some View {
        HStack(spacing: 4) {
            adjustment(-1)
            if let onDone {
                Button(action: onDone) {
                    WatchStepGlyph(symbol: "checkmark")
                        .foregroundStyle(IronTheme.accentText)
                        .frame(height: height)
                        .background(IronTheme.accentWash, in: Capsule())
                }.buttonStyle(.plain).accessibilityLabel("Done Editing")
            }
            adjustment(1)
        }
    }
    private func adjustment(_ direction: Double) -> some View {
        Button { onAdjust(direction) } label: {
            WatchStepGlyph(symbol: direction < 0 ? "minus" : "plus")
                .frame(height: height)
                .background(IronTheme.platterRaised, in: Capsule())
        }.buttonStyle(.plain)
            .accessibilityLabel((direction < 0 ? "Decrease " : "Increase ") + title.lowercased())
    }
}

private struct WatchSetOptionRows: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    @EnvironmentObject private var navigation: WatchNavigation
    let exerciseID: UUID
    let setID: UUID
    var showsCompletion = false
    private var exercise: WatchWorkoutExercise? { store.workoutSnapshot?.exercises.first { $0.id == exerciseID } }
    private var unit: WatchWorkoutWeightUnit { store.workoutSnapshot?.weightUnit ?? store.preferredWeightUnit }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let exercise, let set = exercise.sets.first(where: { $0.id == setID }) {
                ratingRow(set)
                typeRow(set)
                if showsCompletion { completionRow(set, exercise: exercise) }
                notesRow(set)
                restTimerRow(exercise)
                measurementRows(set, type: exercise.effectiveTrackingType(for: set))
                if exercise.effectiveTrackingType(for: set).usesWeight { plateCalculatorRow(set) }
                deleteRow
            }
        }
    }

    private func ratingRow(_ set: WatchWorkoutSet) -> some View {
        NavigationLink(value: WatchRoute.rpe(exerciseID, setID)) {
            WatchSettingsLabel(title: "RPE", symbol: "chart.bar.fill", color: IronTheme.metricEffort,
                value: set.rpe.map(WatchNumber.format) ?? "Add", valueColor: set.rpe == nil ? IronTheme.accentText : IronTheme.metricEffort,
                metricValue: true)
        }.buttonStyle(.plain)
    }
    private func typeRow(_ set: WatchWorkoutSet) -> some View {
        NavigationLink(value: WatchRoute.setType(exerciseID, setID)) {
            WatchSettingsLabel(title: "Set Type", symbol: "tag.fill", color: IronTheme.setBadge(set.tag),
                value: set.kindTitle, valueColor: IronTheme.setTint(set.tag), symbolColor: IronTheme.setTint(set.tag))
        }.buttonStyle(.plain)
    }
    private func completionRow(_ set: WatchWorkoutSet, exercise: WatchWorkoutExercise) -> some View {
        Button {
            if set.completed { store.completeSet(exerciseID: exerciseID, setID: setID) }
            else { navigation.logSet(exercise: exercise, set: set, store: store, fromEditor: true) }
        } label: {
            WatchSettingsLabel(title: set.completed ? "Mark as Not Done" : "Mark as Done",
                symbol: set.completed ? "arrow.uturn.backward" : "checkmark", color: IronTheme.settingsGray)
        }.buttonStyle(.plain).disabled(navigation.isLogging)
    }
    private func notesRow(_ set: WatchWorkoutSet) -> some View {
        NavigationLink {
            WatchTextDraftEditor(title: "Set Note", exerciseName: exercise?.name ?? "Exercise",
                                 scope: "Only for this set in this workout.", initialText: set.comment ?? "") { value in
                mutate { $0.comment = value.isEmpty ? nil : value }
            }
        } label: {
            WatchNoteLabel(title: "Set Note", symbol: "note.text",
                           note: set.comment.flatMap { $0.isEmpty ? nil : $0 }, canEdit: true)
        }.buttonStyle(.plain)
    }
    private func restTimerRow(_ exercise: WatchWorkoutExercise) -> some View {
        NavigationLink(value: WatchRoute.restTimer(exerciseID)) {
            WatchSettingsLabel(title: "Rest Timer", symbol: "timer", color: IronTheme.metricTimeContainer,
                value: WatchNumber.clock(exercise.restTimerDuration ?? WatchPreferences.defaultRestDuration),
                valueColor: IronTheme.metricTime, symbolColor: IronTheme.metricTime)
        }.buttonStyle(.plain)
    }
    private func measurementRows(_ set: WatchWorkoutSet, type: SetTrackingType) -> some View {
        // Weight and reps already have Crown-editable hero tiles above.
        ForEach(type.watchFields.filter { $0 != .weight && $0 != .reps }, id: \.self) { field in
            measurement(field, set: set, type: type)
        }
    }
    private func measurement(_ field: SetValueField, set: WatchWorkoutSet, type: SetTrackingType) -> some View {
        NavigationLink {
            WatchNumericEditor(title: field.title(trackingType: type), unit: measurementUnit(field),
                range: 0...field.maximum, step: field.step, initialValue: field.value(set, unit: unit), allowsEmpty: true) { value in
                let selectedUnit = unit; mutate { field.apply(value, unit: selectedUnit, to: &$0) }
            }
        } label: {
            WatchSettingsLabel(title: field.title(trackingType: type), symbol: measurementSymbol(field), color: IronTheme.settingsGray,
                value: measurementValue(field, set: set, type: type), metricValue: true)
        }.buttonStyle(.plain)
    }
    private func measurementSymbol(_ field: SetValueField) -> String {
        switch field { case .duration: return "stopwatch"; case .distance: return "figure.walk"; case .weight: return "scalemass.fill"; case .reps: return "repeat" }
    }
    private func measurementUnit(_ field: SetValueField) -> String {
        switch field { case .duration: return "seconds"; case .reps: return "reps"; default: return field.stepUnit(unit: unit) }
    }
    private func measurementValue(_ field: SetValueField, set: WatchWorkoutSet, type: SetTrackingType) -> String {
        let value = field.value(set, unit: unit)
        guard value > 0 else { return "Add" }
        if field == .duration { return WatchNumber.clock(value) }
        if field == .reps { return WatchNumber.count(Int(value), "rep") }
        return (field == .weight ? type.weightPrefix : "") + WatchNumber.format(value) + " " + field.stepUnit(unit: unit)
    }
    private func plateCalculatorRow(_ set: WatchWorkoutSet) -> some View {
        NavigationLink {
            WatchPlateCalculatorView(targetWeight: set.weight ?? 0, unit: unit,
                exerciseKey: exercise?.exerciseUuid?.uuidString ?? exercise?.name) { value in
                    mutate { $0.weight = value }
                }
        } label: {
            WatchSettingsLabel(title: "Plate Calculator", symbol: "plusminus", color: IronTheme.settingsGray)
        }.buttonStyle(.plain)
    }
    private var deleteRow: some View {
        Button(role: .destructive) { navigation.path.append(.deleteSet(exerciseID, setID)) } label: {
            WatchSettingsLabel(title: "Delete Set", symbol: "trash.fill", color: IronTheme.danger, destructive: true)
        }.buttonStyle(.plain)
    }
    private func mutate(_ body: @escaping (inout WatchWorkoutSet) -> Void) {
        store.updateCurrent { snapshot in
            guard let exercise = snapshot.exercises.firstIndex(where: { $0.id == exerciseID }),
                  let set = snapshot.exercises[exercise].sets.firstIndex(where: { $0.id == setID }) else { return }
            body(&snapshot.exercises[exercise].sets[set])
        }
    }
}

struct ActiveSetEditor: View {
    @AppStorage("workoutHaptics") private var workoutHaptics = true
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    @EnvironmentObject private var navigation: WatchNavigation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    let exerciseID: UUID
    let setID: UUID
    @State private var focus = SetValueField.weight
    @State private var crown = 0.0
    @State private var initialized = false
    @State private var crownOrigin = 0.0
    @FocusState private var crownFocused: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var valueSize: CGFloat = 52
    @ScaledMetric(relativeTo: .caption2) private var labelLineHeight: CGFloat = 14
    @ScaledMetric(relativeTo: .footnote) private var headerSize: CGFloat = 13
    private var exercise: WatchWorkoutExercise? { store.workoutSnapshot?.exercises.first { $0.id == exerciseID } }
    private var set: WatchWorkoutSet? { exercise?.sets.first { $0.id == setID } }
    private var trackingType: SetTrackingType { self.set.flatMap { exercise?.effectiveTrackingType(for: $0) } ?? .weightReps }
    private var unit: WatchWorkoutWeightUnit { store.workoutSnapshot?.weightUnit ?? store.preferredWeightUnit }
    var body: some View {
        GeometryReader { proxy in
            let budget = WatchPickerFirstScreenBudget(size: proxy.size, headerHeight: headerSize * 1.35 + 2 + labelLineHeight * 1.35)
            ScrollView(.vertical) {
                if let exercise, let set {
                    VStack(alignment: .leading, spacing: 0) {
                        firstScreen(exercise: exercise, set: set, budget: budget)
                        setSettings
                            .padding(.top, 12).padding(.bottom, budget.bottomClearance + 8)
                    }
                    .frame(width: max(0, proxy.size.width - 2 * IronTheme.workoutGutter), alignment: .leading)
                    .padding(.horizontal, IronTheme.workoutGutter)
                } else { ContentUnavailableView("Set Removed", systemImage: "checklist") }
            }
            .digitalCrownAccessory(.hidden)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .navigationTitle("").watchVitalsInset()
        .onAppear {
            if !initialized {
                initialized = true
                focus = trackingType.watchFields[0]
            }
            syncCrown(); crownFocused = true
        }
        .task {
            // Navigation can install its focus scope after onAppear.
            await Task.yield()
            guard !Task.isCancelled else { return }
            crownFocused = true
        }
        .onChange(of: crown) { persistCrown() }
        .onChange(of: unit) { syncCrown() }
        .onChange(of: trackingType) { focus = trackingType.watchFields[0]; syncCrown() }
        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: crown.rounded())
        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: focus)
    }
    private func firstScreen(exercise: WatchWorkoutExercise, set: WatchWorkoutSet, budget: WatchPickerFirstScreenBudget) -> some View {
        let fieldCount = CGFloat(trackingType.watchFields.count)
        let tileHeight = typeSize.isAccessibilitySize
            ? (valueSize * 1.3 + 32) * fieldCount + (fieldCount - 1) * 4
            : budget.heroHeight
        let buttonHeight = typeSize.isAccessibilitySize ? max(budget.buttonHeight, valueSize) : budget.buttonHeight
        return VStack(alignment: .leading, spacing: budget.spacing) {
            VStack(alignment: .leading, spacing: 2) {
                // The name truncates first; the set position always stays visible.
                HStack(spacing: 0) {
                    Text(exercise.name).foregroundStyle(IronTheme.primaryText)
                        .lineLimit(1).truncationMode(.tail)
                    Text(" · Set \(set.order)/\(exercise.sets.count)").foregroundStyle(IronTheme.accentText)
                        .lineLimit(1).fixedSize().layoutPriority(1)
                }
                .accessibilityElement(children: .combine)
                .font(.ironMetric(size: headerSize, weight: .semibold))
                Text(previous(set, exercise: exercise))
                    .font(.footnote).foregroundStyle(IronTheme.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: typeSize.isAccessibilitySize ? nil : budget.headerHeight)
            fields(set, exerciseName: exercise.name, height: tileHeight, compact: budget.compact)
                .frame(height: tileHeight)
                // The Crown edits the focused field; touch still scrolls the page.
                .focusable().focused($crownFocused).focusEffectDisabled()
                .watchCrownRotation($crown, in: (-focus.maximum / focus.step)...(focus.maximum / focus.step), by: 1,
                                    sensitivity: .medium, haptics: workoutHaptics)
            saveButton(exercise: exercise, set: set, height: buttonHeight)
        }
        .frame(minHeight: budget.contentHeight, alignment: .top)
        .padding(.bottom, budget.bottomClearance)
    }
    private func saveButton(exercise: WatchWorkoutExercise, set: WatchWorkoutSet, height: CGFloat) -> some View {
        Button {
            if set.completed { dismiss() }
            else { navigation.logSet(exercise: exercise, set: set, store: store, fromEditor: true) }
        } label: {
            WatchActionLabel(title: set.completed ? "Save" : "Log Set", symbol: "checkmark")
                .frame(height: height)
                .foregroundStyle(IronTheme.onAccent)
                .watchPrimaryCapsule()
        }
            // Own the exact target height; styled capsules add their own insets.
            .buttonStyle(.plain)
            .opacity(navigation.isLogging ? 0.4 : 1)
            .disabled(navigation.isLogging)
            .accessibilityLabel(set.completed ? "Save Changes" : "Log Set")
    }
    private func fields(_ set: WatchWorkoutSet, exerciseName: String, height: CGFloat, compact: Bool) -> some View {
        let first = trackingType.watchFields[0]
        let second = trackingType.watchFields.dropFirst().first
        // Match Now's label + number line-height budget, without a fixed font cap.
        let size = typeSize.isAccessibilitySize ? valueSize : max(20, (height - labelLineHeight - 4) / 1.15)
        return WatchSetValueTiles(exerciseName: exerciseName, set: set, unit: unit, trackingType: trackingType,
            firstField: first, secondField: second, focus: focus, metricSize: size,
            compact: compact, stacksFields: typeSize.isAccessibilitySize, fillsPage: true,
            onSelect: selectField, onAdjust: { field, direction in
                selectField(field)
                step(field, by: direction * field.buttonDetents(unit: unit))
            })
    }
    private var setSettings: some View {
        VStack(alignment: .leading, spacing: 3) {
            WatchSectionTitle(title: "Set Settings")
            WatchSetOptionRows(exerciseID: exerciseID, setID: setID, showsCompletion: true)
        }
    }
    private func previous(_ set: WatchWorkoutSet, exercise: WatchWorkoutExercise) -> String {
        store.previousSetText(set: set, exercise: exercise, snapshot: store.workoutSnapshot).map { "Last " + $0 } ?? "No previous set"
    }
    private func syncCrown() { if let set { crownOrigin = focus.value(set, unit: unit); crown = 0 } }
    private func selectField(_ field: SetValueField) {
        focus = field
        syncCrown()
        crownFocused = true
    }
    private func step(_ field: SetValueField, by direction: Double) {
        guard set != nil else { return }
        let step = field.step
        crown = max((-crownOrigin / step).rounded(.down), min(((field.maximum - crownOrigin) / step).rounded(.up), crown.rounded() + direction))
        persistCrown()
        WatchFeedback.play(.click)
    }
    private func persistCrown() {
        let value = min(focus.maximum, max(0, crownOrigin + crown.rounded() * focus.step))
        guard trackingType.watchFields.contains(focus), let set, abs(focus.value(set, unit: unit) - value) > 0.00001 else { return }
        let selected = focus, selectedUnit = unit, selectedType = trackingType
        store.updateCurrent { snapshot in
            guard let exercise = snapshot.exercises.firstIndex(where: { $0.id == exerciseID }),
                  let set = snapshot.exercises[exercise].sets.firstIndex(where: { $0.id == setID }),
                  snapshot.exercises[exercise].effectiveTrackingType(for: snapshot.exercises[exercise].sets[set]) == selectedType,
                  (snapshot.weightUnit ?? store.preferredWeightUnit) == selectedUnit else { return }
            selected.apply(value, unit: selectedUnit, to: &snapshot.exercises[exercise].sets[set])
        }
    }
}

struct ActiveSetRPEPage: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    @EnvironmentObject private var navigation: WatchNavigation
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    let exerciseID: UUID
    let setID: UUID
    @State private var interaction = 0
    @State private var selection: Double? = 8
    @State private var initialized = false
    @State private var touched = false
    var body: some View {
        Group {
            if let snapshot = store.workoutSnapshot,
               let exercise = snapshot.exercises.first(where: { $0.id == exerciseID }),
               let set = exercise.sets.first(where: { $0.id == setID }) {
                ratingPage(snapshot: snapshot, exercise: exercise, set: set)
            } else {
                // Never manufacture an exercise, zero-valued set or kg context
                // when a stale route no longer resolves in the active workout.
                ContentUnavailableView("Set Unavailable", systemImage: "dumbbell")
                    .navigationTitle("").watchVitalsInset()
            }
        }
        .task(id: interaction) {
            guard navigation.automaticRPESetID == setID,
                  navigation.isFlowRPE(exerciseID: exerciseID, setID: setID),
                  scenePhase == .active, store.persistenceFailure == nil else { return }
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--hold-watch-flow") { return }
            #endif
            do { try await Task.sleep(nanoseconds: 5_000_000_000) }
            catch { return }
            guard !Task.isCancelled, navigation.automaticRPESetID == setID,
                  navigation.isFlowRPE(exerciseID: exerciseID, setID: setID),
                  scenePhase == .active, store.persistenceFailure == nil else { return }
            WatchFeedback.play(.success)
            navigation.completeAutomaticRPE(exerciseID: exerciseID, setID: setID, in: store.workoutSnapshot)
        }
        .onChange(of: scenePhase) { if scenePhase == .active { interaction += 1 } }
        .onChange(of: store.persistenceFailure?.id) { if store.persistenceFailure == nil { interaction += 1 } }
    }

    private func ratingPage(snapshot: WatchWorkoutSnapshot, exercise: WatchWorkoutExercise, set: WatchWorkoutSet) -> some View {
        let initial = initialized ? selection : initialRPE(snapshot: snapshot, exercise: exercise, set: set)
        return WatchRPEPage(value: Binding(get: { initialized ? selection : initial }, set: { value in
            // Keep Crown input immediate while the durable update is queued.
            interaction += 1
            selection = WatchSetRPEScale.normalized(value)
            initialized = true
            touched = true
            saveRPE(selection, workoutID: snapshot.workoutID)
        }), context: WatchNumber.joinedForWrapping([
            exercise.name, "Set \(set.order)",
            set.displayText(weightUnit: snapshot.weightUnit ?? store.preferredWeightUnit,
                            trackingType: exercise.effectiveTrackingType(for: set))
        ], keepingTogether: [1, 2]), onInteraction: { interaction += 1 },
        automaticallyAccepts: navigation.automaticRPESetID == setID,
        isSuggestion: initialized ? !touched : set.rpe == nil,
        onConfirm: {
            if !touched {
                saveRPE(initialized ? selection : initial, workoutID: snapshot.workoutID)
                touched = true
            }
            if navigation.isFlowRPE(exerciseID: exerciseID, setID: setID) {
                navigation.completeAutomaticRPE(exerciseID: exerciseID, setID: setID, in: store.workoutSnapshot)
            } else { dismiss() }
        })
        .onAppear {
            guard !initialized else { return }
            selection = initial
            initialized = true
            touched = set.rpe != nil
        }
    }

    private func saveRPE(_ value: Double?, workoutID: UUID) {
        store.updateCurrent { snapshot in
            guard snapshot.workoutID == workoutID,
                  let exercise = snapshot.exercises.firstIndex(where: { $0.id == exerciseID }),
                  let set = snapshot.exercises[exercise].sets.firstIndex(where: { $0.id == setID }) else { return }
            snapshot.exercises[exercise].sets[set].rpe = WatchSetRPEScale.normalized(value)
        }
    }

    private func initialRPE(snapshot: WatchWorkoutSnapshot, exercise: WatchWorkoutExercise, set: WatchWorkoutSet) -> Double {
        func valid(_ value: Double?) -> Double? {
            WatchSetRPEScale.normalized(value)
        }
        if let existing = valid(set.rpe) { return existing }
        if let previous = exercise.sets.filter({ $0.completed && $0.id != set.id })
            .sorted(by: { $0.order > $1.order }).compactMap({ valid($0.rpe) }).first { return previous }
        for workout in store.library.history.sorted(by: { $0.startDate > $1.startDate })
            where workout.workoutID != snapshot.workoutID && workout.startDate < snapshot.startDate {
            if let previousExercise = workout.exercises.first(where: {
                if let catalogID = exercise.exerciseUuid { return $0.exerciseUuid == catalogID }
                return $0.name.localizedCaseInsensitiveCompare(exercise.name) == .orderedSame
            }), let previous = previousExercise.sets.filter(\.completed).sorted(by: { $0.order > $1.order })
                .compactMap({ valid($0.rpe) }).first { return previous }
        }
        return 8
    }
}

/// Recommendations scroll only when necessary; the action always owns the bottom.
struct WatchWarmupPage: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject private var loadoutsCache = PlateCalculatorStorageKeys.loadoutsCache
    @ObservedObject private var inventoryCache = PlateCalculatorStorageKeys.inventoryCache
    @FocusState private var crownFocused: Bool
    @State private var isAdding = false
    @ScaledMetric(relativeTo: .footnote) private var headerSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var rowSize: CGFloat = 17
    let exerciseID: UUID

    private var exercise: WatchWorkoutExercise? {
        store.workoutSnapshot?.exercises.first { $0.id == exerciseID }
    }

    static func canOffer(for exercise: WatchWorkoutExercise) -> Bool {
        // The phone's showWarmUpCalculator preference is not part of Watch sync.
        exercise.effectiveTrackingType.usesWeight &&
            !exercise.sets.contains { $0.tag == "warmUp" } &&
            exercise.sets.contains { $0.tag != "warmUp" && ($0.weight ?? 0) > 0 }
    }

    private static func recommendations(for exercise: WatchWorkoutExercise, unit: WatchWorkoutWeightUnit) -> [WarmupPlan.Recommendation] {
        guard canOffer(for: exercise),
              let working = exercise.sets.first(where: { $0.tag != "warmUp" && ($0.weight ?? 0) > 0 }),
              let weight = working.weight else { return [] }
        let key = exercise.exerciseUuid?.uuidString ?? exercise.name
        return WarmupPlan.recommendations(workingWeight: weight, unit: unit,
                                          loadout: PlateLoadout.loadAll()[key], inventory: PlateInventory.load())
    }

    var body: some View {
        let unit = store.workoutSnapshot?.weightUnit ?? store.preferredWeightUnit
        let rows = exercise.map { Self.recommendations(for: $0, unit: unit) } ?? []
        GeometryReader { proxy in
            // Page geometry is below the real device toolbar, not a screenshot's
            // assumed top inset. Only the bottom rounded corners are reserved.
            let compact = proxy.size.width < 180
            let buttonHeight: CGFloat = compact ? 44 : 52
            let clearance: CGFloat = compact ? 6 : 10
            let headerHeight = headerSize * (typeSize.isAccessibilitySize ? 2.8 : 1.4)
            let listHeight = max(0, proxy.size.height - headerHeight - 4 - buttonHeight - clearance - 4)
            let minimumRow = typeSize.isAccessibilitySize ? rowSize * 2.4 + 4 : rowSize * 1.3
            let rowHeight = max(minimumRow, (listHeight - CGFloat(max(0, rows.count - 1)) * 2) / CGFloat(max(1, rows.count)))
            VStack(alignment: .leading, spacing: 4) {
                (Text("Warm-up").bold().foregroundColor(IronTheme.primaryText)
                 + Text(" · " + (exercise?.name ?? "Exercise")).foregroundColor(IronTheme.secondaryText))
                    .font(.system(size: headerSize))
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: headerHeight, alignment: .topLeading)
                    .accessibilityAddTraits(.isHeader)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if rows.isEmpty {
                            Text("No lighter warm-up sets for this working weight.")
                                .font(.body).foregroundStyle(IronTheme.secondaryText)
                                .frame(maxWidth: .infinity, minHeight: listHeight, alignment: .center)
                        }
                        ForEach(rows) { row in
                            recommendationRow(row, unit: unit)
                                .frame(minHeight: rowHeight)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .focusable().focused($crownFocused).focusEffectDisabled()
                .digitalCrownAccessory(.hidden)
                // watchOS scroll content isn't clipped by default; keep rows
                // from drawing behind the pinned button.
                .frame(height: listHeight).clipped()
                Button {
                    if rows.isEmpty { dismiss() } else { addSets() }
                } label: {
                    Text(rows.isEmpty ? "Done" : "Add \(rows.count) \(rows.count == 1 ? "Set" : "Sets")")
                        .font(.ironMetric(.body, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity).frame(height: buttonHeight)
                        .foregroundStyle(IronTheme.onAccent)
                        .watchPrimaryCapsule()
                }
                .buttonStyle(.plain).disabled(isAdding)
                .padding(.bottom, clearance)
            }
            .frame(height: proxy.size.height, alignment: .top)
            .padding(.horizontal, IronTheme.workoutGutter)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .navigationTitle("").watchVitalsInset()
        .onAppear { crownFocused = true }
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            crownFocused = true
        }
        .onChange(of: store.persistenceFailure?.id) {
            if store.persistenceFailure != nil { isAdding = false }
        }
    }

    private func recommendationRow(_ row: WarmupPlan.Recommendation, unit: WatchWorkoutWeightUnit) -> some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    percentage(row)
                    weightAndReps(row, unit: unit)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    percentage(row).frame(minWidth: rowSize * 2.3, alignment: .leading)
                    weightAndReps(row, unit: unit)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int(row.percentage * 100)) percent, \(WatchPlateMath.format(row.weight)) \(unit.symbol), \(row.repetitions) reps")
    }

    private func percentage(_ row: WarmupPlan.Recommendation) -> some View {
        Text("\(Int(row.percentage * 100))%")
            .font(.ironMetric(size: rowSize, weight: .semibold))
            .foregroundStyle(IronTheme.metricSets)
            .lineLimit(1).fixedSize()
    }

    private func weightAndReps(_ row: WarmupPlan.Recommendation, unit: WatchWorkoutWeightUnit) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(WatchPlateMath.format(row.weight)).font(.ironMetric(size: rowSize))
            Text(unit.symbol).font(.system(size: rowSize * 0.75, weight: .semibold))
                .foregroundStyle(IronTheme.secondaryText)
            Spacer(minLength: 2)
            Text("×").font(.system(size: rowSize * 0.75)).foregroundStyle(IronTheme.secondaryText)
            Text("\(row.repetitions)").font(.ironMetric(size: rowSize))
        }
        .foregroundStyle(IronTheme.primaryText)
    }

    private func addSets() {
        guard !isAdding else { return }
        isAdding = true
        store.updateCurrent(persistenceCompletion: { success in
            isAdding = false
            if success { dismiss() }
        }) { snapshot in
            guard let index = snapshot.exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
            let rows = Self.recommendations(for: snapshot.exercises[index], unit: snapshot.weightUnit ?? store.preferredWeightUnit)
            guard !rows.isEmpty else { return }
            let insertion = snapshot.exercises[index].sets.firstIndex { $0.tag != "warmUp" } ?? 0
            let sets = rows.map { WatchWorkoutSet(order: 0, weight: $0.weight, reps: $0.repetitions, completed: false, tag: "warmUp") }
            snapshot.exercises[index].sets.insert(contentsOf: sets, at: insertion)
            snapshot.selectedSetID = WatchWorkoutEditing.nextSet(in: snapshot)
            // The persistence completion runs only after this structure event
            // and its projection have been saved together.
        }
    }
}

struct ActiveSetTypePicker: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    @Environment(\.dismiss) private var dismiss
    let exerciseID: UUID
    let setID: UUID
    private var selected: String? { store.workoutSnapshot?.exercises.first { $0.id == exerciseID }?.sets.first { $0.id == setID }?.tag }
    private let tags = ["working", "warmUp", "dropSet", "failure"]
    var body: some View {
        WatchContentList {
            Text("Set Type").font(.headline.weight(.bold)).padding(.bottom, 4).padding(.horizontal, 8)
            ForEach(tags, id: \.self) { tag in
                Button {
                    guard let id = store.workoutSnapshot?.workoutID else { return }
                    store.updateSetTag(workoutID: id, exerciseID: exerciseID, setID: setID, tag: tag == "working" ? nil : tag)
                    WatchFeedback.play(.click)
                    dismiss()
                } label: { typeLabel(tag) }
                    .buttonStyle(.plain).accessibilityValue((selected ?? "working") == tag ? "Selected" : "")
                    .accessibilityAddTraits((selected ?? "working") == tag ? .isSelected : [])
            }
        }.navigationTitle("").watchVitalsInset()
    }
    private func title(_ tag: String) -> String {
        switch tag { case "warmUp": return "Warm-up"; case "dropSet": return "Drop Set"; case "failure": return "Failure"; default: return "Normal" }
    }
    private func typeLabel(_ tag: String) -> some View {
        let value: String? = tag == "working" ? nil : tag
        return HStack(spacing: 8) {
            Image(systemName: symbol(tag)).font(.body.weight(.semibold))
                .foregroundStyle(IronTheme.setTint(value))
                .frame(width: 28, height: 28).background(IronTheme.setBadge(value), in: Circle())
                .accessibilityHidden(true)
            Text(title(tag)).font(.body.weight(.semibold)).foregroundStyle(IronTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            if (selected ?? "working") == tag {
                Image(systemName: "checkmark").foregroundStyle(IronTheme.accentText).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .background(IronTheme.platter, in: RoundedRectangle(cornerRadius: IronTheme.compactCornerRadius, style: .continuous))
        .contentShape(Rectangle())
    }
    private func symbol(_ tag: String) -> String {
        switch tag { case "warmUp": return "flame"; case "dropSet": return "arrow.down.right"; case "failure": return "bolt.fill"; default: return "number" }
    }
}

struct WatchRestView: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    @EnvironmentObject private var navigation: WatchNavigation
    @Environment(\.isLuminanceReduced) private var reducedLuminance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var timeSize: CGFloat = 48
    @State private var closed = false
    private var snapshot: WatchWorkoutSnapshot? { store.workoutSnapshot }

    var body: some View {
        TimelineView(.periodic(from: Date(), by: reducedLuminance ? 60 : 1)) { context in
            GeometryReader { proxy in
                let compact = proxy.size.width < 180
                let buttonHeight: CGFloat = compact ? 44 : 52
                let clearance: CGFloat = compact ? 6 : 10
                let gap: CGFloat = 8
                let ringSpace = max(0, proxy.size.height - buttonHeight - clearance - gap)
                Group {
                    if typeSize.isAccessibilitySize {
                        VStack(spacing: gap) {
                            accessibleReadout(at: context.date, height: ringSpace)
                                .frame(maxWidth: .infinity)
                                .frame(height: ringSpace)
                            controls.frame(height: buttonHeight)
                        }
                    } else {
                        VStack(spacing: gap) {
                            HStack(spacing: gap) {
                                if buttonsLead { sideControls(compact: compact) }
                                GeometryReader { space in
                                    ring(at: context.date, diameter: min(space.size.width, space.size.height))
                                        .frame(width: space.size.width, height: space.size.height)
                                }
                                if !buttonsLead { sideControls(compact: compact) }
                            }
                            nextDetail
                        }
                    }
                }
                .padding(.horizontal, IronTheme.workoutGutter)
                .padding(.bottom, clearance)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .onChange(of: context.date) { if remaining(at: context.date) <= 0 { close(stop: false) } }
        }
        .navigationTitle("").watchVitalsInset(showsBack: navigation.restHasRPEBack)
        .onAppear { navigation.advanceFlow(in: snapshot) }
        .onChange(of: snapshot?.restTimerEnd) {
            let left = remaining(at: Date())
            if left <= 0 { close(stop: false) }
            else { navigation.restTotal = max(navigation.restTotal, left.rounded(.up)) }
        }
        .onChange(of: snapshot?.pausedRestRemaining) { if remaining(at: Date()) <= 0 { close(stop: false) } }
        .onChange(of: store.persistenceFailure?.id) { if store.persistenceFailure != nil { closed = false } }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            restButton("−15") { store.adjustRest(by: -15) }
                .accessibilityLabel("Subtract 15 seconds")
            restButton("Skip") { close(stop: true) }
                .accessibilityLabel("Skip Rest")
            restButton("+15") { store.adjustRest(by: 15) }
                .accessibilityLabel("Add 15 seconds")
        }
    }

    private func sideControls(compact: Bool) -> some View {
        VStack(spacing: 4) {
            restButton("+15") { store.adjustRest(by: 15) }
                .accessibilityLabel("Add 15 seconds")
            restButton("Skip") { close(stop: true) }
                .accessibilityLabel("Skip Rest")
            restButton("−15") { store.adjustRest(by: -15) }
                .accessibilityLabel("Subtract 15 seconds")
        }
        .frame(width: compact ? 50 : 60)
    }

    /// The buttons sit on the side the other hand reaches from, so they flip for the right wrist.
    private var buttonsLead: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--light-right-wrist") { return true }
        #endif
        return WKInterfaceDevice.current().wristLocation == .right
    }

    /// One line when it fits; otherwise the set drops under the full name.
    @ViewBuilder private var nextDetail: some View {
        if let next = snapshot?.nextSet {
            let name = next.exercise.name
            let set = next.set.displayText(weightUnit: snapshot?.weightUnit ?? store.preferredWeightUnit,
                                           trackingType: next.exercise.effectiveTrackingType(for: next.set))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    Text(name).foregroundStyle(IronTheme.primaryText)
                    Text(set).foregroundStyle(IronTheme.secondaryText)
                }
                .fixedSize()
                VStack(spacing: 0) {
                    Text(name).foregroundStyle(IronTheme.primaryText)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(set).foregroundStyle(IronTheme.secondaryText)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .font(.footnote.weight(.semibold))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Next")
            .accessibilityValue(nextText)
        } else {
            Text("Finish your workout")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(IronTheme.secondaryText)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private func restButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.ironMetric(.body, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(IronTheme.primaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .watchNeutralCapsule()
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
    }

    private func accessibleReadout(at date: Date, height: CGFloat) -> some View {
        let time = WatchNumber.clock(remaining(at: date))
        return VStack(spacing: 4) {
            Text("REST").font(.system(size: height * 0.14, weight: .bold)).foregroundStyle(IronTheme.metricTime)
                .frame(height: height * 0.18)
            Text(time).font(.ironMetric(size: height * 0.4)).foregroundStyle(IronTheme.metricTime)
                .lineLimit(1).minimumScaleFactor(0.4)
                .frame(height: height * 0.5)
                .contentTransition(reduceMotion || reducedLuminance ? .identity : .numericText(countsDown: true))
            Text("Next · " + nextText).font(.system(size: height * 0.12, weight: .semibold))
                .foregroundStyle(IronTheme.secondaryText).lineLimit(1).minimumScaleFactor(0.6)
                .frame(height: max(0, height * 0.32 - 8))
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .ignore).accessibilityLabel("Rest remaining")
        .accessibilityValue(time + " of " + WatchNumber.clock(navigation.restTotal) + ", next " + nextText)
    }

    private func ring(at date: Date, diameter: CGFloat) -> some View {
        let left = remaining(at: date)
        let progress = max(0, min(1, left / max(1, navigation.restTotal)))
        let time = WatchNumber.clock(left)
        let lengthScale = min(1, 4 / CGFloat(max(4, time.count)))
        let stroke = max(6, diameter * 0.07)
        return ZStack {
            Circle().strokeBorder(IronTheme.metricTimeContainer, lineWidth: stroke)
            Circle().inset(by: stroke / 2).trim(from: 0, to: progress)
                .stroke(IronTheme.metricTime, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(-90)).accessibilityHidden(true)
            VStack(spacing: 0) {
                Text("REST").font(.footnote.bold()).foregroundStyle(IronTheme.metricTime)
                Text(time).font(.ironMetric(size: timeSize * diameter / 146 * lengthScale))
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .contentTransition(reduceMotion || reducedLuminance ? .identity : .numericText(countsDown: true))
            }
            .frame(width: max(0, diameter - stroke * 3))
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore).accessibilityLabel("Rest remaining")
        .accessibilityValue(time + " of " + WatchNumber.clock(navigation.restTotal))
    }
    private func remaining(at date: Date) -> TimeInterval {
        snapshot?.pausedRestRemaining ?? max(0, snapshot?.restTimerEnd?.timeIntervalSince(date) ?? 0)
    }
    private var nextName: String {
        snapshot?.nextSet.map { WatchWorkoutSummary.shortName($0.exercise.name) } ?? "Finish"
    }
    private var nextText: String {
        guard let next = snapshot?.nextSet else { return "Finish your workout" }
        return nextName + " " + next.set.displayText(weightUnit: snapshot?.weightUnit ?? store.preferredWeightUnit,
                                                    trackingType: next.exercise.effectiveTrackingType(for: next.set))
    }
    private func close(stop: Bool) {
        guard !closed, navigation.path.last == .rest else { return }
        if stop {
            // Advance only after the durable skip arrives. Its preference-gated
            // click and natural expiry's notification cue are owned by the store.
            closed = true
            store.skipRest()
        } else {
            navigation.advanceFlow(in: snapshot)
        }
    }
}

struct WatchVitalsRow: View {
    let manager: WorkoutSessionManager?
    let snapshot: WatchWorkoutSnapshot
    @ViewBuilder var body: some View {
        #if DEBUG
        if snapshot.isHealthTestWorkout || manager?.healthTestMode == true {
            WatchVitalsLine(heartRate: "--", energy: "--")
        } else {
            vitals
        }
        #else
        vitals
        #endif
    }
    @ViewBuilder private var vitals: some View {
        if let manager, manager.uuid == snapshot.workoutID { LiveWatchVitals(manager: manager) }
        else { WatchVitalsLine(heartRate: "--", energy: WatchNumber.whole(snapshot.activeEnergyKilocalories)) }
    }
}

private struct WatchVitalsLine: View {
    let heartRate: String
    let energy: String
    var body: some View {
        // Always one line beside the clock: shrink first, then keep only heart rate.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) { heart(.headline); calories(.headline) }
            HStack(spacing: 4) { heart(.subheadline); calories(.subheadline) }
            heart(.headline)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("Heart rate \(heartRate) beats per minute, \(energy) active calories")
    }
    private func heart(_ style: Font.TextStyle) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "heart.fill").font(.system(size: 13, weight: .semibold))
            Text(heartRate).font(.ironMetric(style, weight: .semibold))
        }.foregroundStyle(IronTheme.metricHeartRate)
    }
    private func calories(_ style: Font.TextStyle) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Image(systemName: "flame.fill").font(.system(size: 13, weight: .semibold))
            Text(energy).font(.ironMetric(style, weight: .semibold))
        }.foregroundStyle(IronTheme.metricEnergy)
    }
}

private struct LiveWatchVitals: View {
    @ObservedObject var manager: WorkoutSessionManager
    @Environment(\.isLuminanceReduced) private var reducedLuminance
    var body: some View {
        TimelineView(.periodic(from: Date(), by: reducedLuminance ? 60 : 5)) { context in
            WatchVitalsLine(heartRate: WatchHeartRate.text(manager, at: context.date), energy: WatchNumber.whole(manager.burnedCalories))
        }
    }
}

private enum WatchHeartRate {
    /// A reading older than 30 seconds shows as unknown rather than stale.
    static func text(_ manager: WorkoutSessionManager, at date: Date) -> String {
        guard let value = manager.mostRecentHeartRate, value.isFinite, value > 0,
              let sampleDate = manager.mostRecentHeartRateDate,
              (-5...30).contains(date.timeIntervalSince(sampleDate)) else { return "--" }
        return WatchNumber.whole(value)
    }
}

struct WatchRecordingFailureRow: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    var body: some View {
        if let error = store.recordingError {
            VStack(alignment: .leading, spacing: 4) {
                Label(error, systemImage: "heart.slash.fill").font(.footnote).foregroundStyle(IronTheme.destructiveText)
                if store.workoutSnapshot?.isFinishedRecord == false {
                    Button { store.startRecording() } label: { Text("Retry Recording").font(.footnote.weight(.semibold)).frame(minHeight: 44) }
                        .watchGlassButton().disabled(store.isStartingRecording || store.isRecoveringRecording)
                } else {
                    Button { store.clearRecordingError() } label: { Text("Dismiss").font(.footnote.weight(.semibold)) }.watchGlassButton()
                }
            }.watchPlatter(IronTheme.destructiveWash)
        }
    }
}

private enum WatchExerciseNoteKind: String, CaseIterable, Identifiable {
    case exercise, plan, workout
    var id: Self { self }
    var title: String {
        switch self {
        case .exercise: return "Exercise Note"
        case .plan: return "Plan Note"
        case .workout: return "Workout Note"
        }
    }
    var symbol: String {
        switch self {
        case .exercise: return "pin"
        case .plan: return "list.bullet"
        case .workout: return "note.text"
        }
    }
    var scope: String {
        switch self {
        case .exercise: return "Shown in every workout with this exercise. Syncs with iPhone."
        case .plan: return "Shown whenever you start this saved workout. Edit on iPhone."
        case .workout: return "Only for this exercise in this workout."
        }
    }
    func isEditable(for exercise: WatchWorkoutExercise) -> Bool {
        switch self {
        case .exercise: return exercise.exerciseUuid != nil
        case .plan: return false
        case .workout: return true
        }
    }
    func text(for exercise: WatchWorkoutExercise, preferencesData: Data?) -> String? {
        let value: String?
        switch self {
        case .exercise:
            if let id = exercise.exerciseUuid, let data = preferencesData,
               let preferences = try? JSONDecoder().decode(ExerciseNotes.self, from: data), preferences.isValid,
               let entry = preferences.entries[id.uuidString] {
                // A local deletion must win over a stale projection's pinned cue.
                value = entry.text
            } else { value = exercise.exerciseNote }
        case .plan: value = exercise.routineNote
        case .workout: value = exercise.comment
        }
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

private struct WatchNoteLabel: View {
    let title: String
    let symbol: String
    let note: String?
    let canEdit: Bool
    var body: some View {
        WatchSettingsLabel(title: title, symbol: symbol, color: IronTheme.metricRecord,
            value: note ?? (canEdit ? "Add Note" : "None"),
            valueColor: note == nil && canEdit ? IronTheme.accentText : IronTheme.secondaryText,
            symbolColor: IronTheme.background, metricValue: false, valueLineLimit: 2)
    }
}

private struct WatchPinnedNoteRow: View {
    let exerciseID: UUID
    let kind: WatchExerciseNoteKind
    let text: String
    var body: some View {
        NavigationLink {
            WatchExerciseNotePage(exerciseID: exerciseID, kind: kind)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: kind.symbol).font(.footnote.weight(.semibold))
                    .foregroundStyle(IronTheme.secondaryText).accessibilityHidden(true)
                Text(text).font(.footnote).foregroundStyle(IronTheme.primaryText)
                    .lineLimit(3).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: IronTheme.controlHeight, alignment: .leading)
            .watchPlatter()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.title + ": " + text)
        .accessibilityHint("Read the full note")
    }
}

private struct WatchExerciseNotePage: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    @AppStorage(ExerciseNotes.storageKey) private var exerciseNotesData: Data?
    let exerciseID: UUID
    let kind: WatchExerciseNoteKind
    var body: some View {
        if let exercise = store.workoutSnapshot?.exercises.first(where: { $0.id == exerciseID }) {
            WatchTextDraftEditor(title: kind.title, exerciseName: exercise.name,
                scope: kind == .exercise && exercise.exerciseUuid == nil
                    ? "This exercise needs an iPhone library identity before its note can be edited." : kind.scope,
                initialText: kind.text(for: exercise, preferencesData: exerciseNotesData) ?? "",
                onCommit: !kind.isEditable(for: exercise) ? nil : { text in
                    if kind == .exercise, let catalogID = exercise.exerciseUuid {
                        if text.isEmpty, ExerciseNotes.load().entries[catalogID.uuidString] == nil,
                           let projectedNote = exercise.exerciseNote {
                            // setNote needs a prior value to record a deletion.
                            // Hydrate an unsynced projection at the oldest timestamp,
                            // then publish the clear through normal preference sync.
                            ExerciseNotes.setNote(projectedNote, for: catalogID,
                                                  updatedAt: Date(timeIntervalSince1970: 0), notify: false)
                        }
                        ExerciseNotes.setNote(text, for: catalogID)
                    } else if kind == .workout {
                        store.updateCurrent { snapshot in
                            guard let index = snapshot.exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
                            snapshot.exercises[index].comment = text.isEmpty ? nil : text
                        }
                    }
                })
        } else {
            ContentUnavailableView("Exercise Unavailable", systemImage: "note.text")
                .watchVitalsInset()
        }
    }
}

private struct WatchTextDraftEditor: View {
    let title: String
    let exerciseName: String
    let scope: String
    let initialText: String
    let onCommit: ((String) -> Void)?
    @State private var draft: String
    @State private var saved: String
    @State private var confirmingClear = false

    init(title: String, exerciseName: String, scope: String, initialText: String,
         onCommit: ((String) -> Void)? = nil) {
        self.title = title
        self.exerciseName = exerciseName
        self.scope = scope
        self.initialText = initialText
        self.onCommit = onCommit
        _draft = State(initialValue: initialText)
        _saved = State(initialValue: initialText)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline.weight(.bold)).accessibilityAddTraits(.isHeader)
                    Text(exerciseName).font(.subheadline).foregroundStyle(IronTheme.secondaryText)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

                if onCommit != nil {
                    // A Watch TextField shows one truncated line in its own box, so the whole note
                    // is drawn on top and tapping it reaches the field behind. The field opens the
                    // system's text input, with dictation and the keyboard or Scribble, and that
                    // input's Done is the save.
                    HStack(alignment: .top, spacing: 6) {
                        Text(draft.isEmpty ? "Add a note" : draft)
                            .font(.body)
                            .foregroundStyle(draft.isEmpty ? IronTheme.accentText : IronTheme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "pencil").font(.footnote.weight(.semibold))
                            .foregroundStyle(IronTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight, alignment: .topLeading)
                    .watchPlatter()
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                    .background {
                        TextField("Add a note", text: $draft, axis: .vertical)
                            .accessibilityLabel(title + " for " + exerciseName)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    Text(draft.isEmpty ? "No note yet." : draft)
                        .font(.body)
                        .foregroundStyle(draft.isEmpty ? IronTheme.tertiaryText : IronTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight, alignment: .topLeading)
                        .watchPlatter()
                }

                Text(scope).font(.footnote).foregroundStyle(IronTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if onCommit != nil, !draft.isEmpty {
                    Button(role: .destructive) { confirmingClear = true } label: {
                        WatchActionLabel(title: "Clear", symbol: "trash")
                            .foregroundStyle(IronTheme.destructiveText)
                    }.watchGlassButton()
                }
            }
            .scenePadding(.horizontal)
            .padding(.top, 8).padding(.bottom, 20)
        }
        .navigationTitle("").watchVitalsInset()
        .onChange(of: draft) { commitDraft() }
        .onChange(of: initialText) { saved = initialText; draft = initialText }
        .confirmationDialog("Clear \(title)?", isPresented: $confirmingClear) {
            Button("Clear", role: .destructive) { draft = "" }
            Button("Cancel", role: .cancel) { }
        } message: { Text(scope) }
    }

    private func commitDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = text
        guard text != saved else { return }
        saved = text
        onCommit?(text)
    }
}

extension WatchWorkoutSet {
    var kindTitle: String {
        switch tag { case "warmUp": return "Warm-up"; case "dropSet": return "Drop Set"; case "failure": return "Failure"; default: return "Normal" }
    }
}

struct WatchExerciseThumbnail: View {
    let imageURL: String?
    let imageData: Data?
    var size: CGFloat = 36
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Circle().fill(IronTheme.diagramCanvas)
            Image(systemName: "dumbbell.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(IronTheme.diagramGlyph).opacity(image == nil ? 1 : 0)
            if let image { Image(uiImage: image).resizable().scaledToFit().padding(size * 0.14) }
        }
        .frame(width: size, height: size).clipShape(Circle())
        .task(id: imageURL) { await load() }
        .onChange(of: imageData) { image = imageData.flatMap(UIImage.init(data:)) }
        .accessibilityHidden(true)
    }

    private func load() async {
        image = imageData.flatMap(UIImage.init(data:))
        guard let imageURL, let url = URL(string: imageURL) else { return }
        let target = size * WKInterfaceDevice.current().screenScale
        let loaded = await WatchExerciseStillStore.shared.image(for: url, targetPixelSize: target)
        guard !Task.isCancelled else { return }
        if let loaded { image = loaded }
    }

}

private actor WatchExerciseStillStore {
    static let shared = WatchExerciseStillStore()
    private let memory = NSCache<NSString, UIImage>()
    private init() { memory.countLimit = 80; memory.totalCostLimit = 8 * 1_024 * 1_024 }
    private let fileManager = FileManager.default
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: configuration)
    }()
    private var directoryURL: URL {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ExerciseMedia", isDirectory: true)
    }
    func image(for remoteURL: URL, targetPixelSize: CGFloat) async -> UIImage? {
        let key = "\(remoteURL.absoluteString)|\(Int(targetPixelSize.rounded(.up)))" as NSString
        if let cached = memory.object(forKey: key) { return cached }
        let data: Data?
        if let disk = try? Data(contentsOf: fileURL(for: remoteURL)) {
            data = disk
        } else {
            data = await download(remoteURL)
        }
        guard let data, let image = stillFrame(from: data, targetPixelSize: targetPixelSize) else { return nil }
        memory.setObject(image, forKey: key, cost: Int(targetPixelSize * targetPixelSize * 4)); return image
    }
    private func download(_ url: URL) async -> Data? {
        var request = URLRequest(url: url); request.setValue("image/gif,image/*;q=0.8", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), !data.isEmpty else { return nil }
        let destination = fileURL(for: url); try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? data.write(to: destination, options: .atomic); return data
    }
    private func fileURL(for url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent(hash)
    }
    private func stillFrame(from data: Data, targetPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let frame = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, Int(targetPixelSize)),
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: frame)
    }
}

private enum WatchPlateMath {
    static func format(_ value: Double) -> String { WatchNumber.format(value) }
}

private enum WatchPlateMode: String, CaseIterable, Identifiable {
    case bar, noBar, machine
    var id: Self { self }
    var title: String {
        switch self { case .bar: return "Bar"; case .noBar: return "No Bar"; case .machine: return "Machine" }
    }
}

private struct WatchPlateWeightEditor: View {
    @AppStorage("workoutHaptics") private var workoutHaptics = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var reducedLuminance
    @ScaledMetric(relativeTo: .largeTitle) private var valueSize: CGFloat = 52
    @ScaledMetric(relativeTo: .footnote) private var adjustmentHeight: CGFloat = IronTheme.controlHeight
    let title: String
    let unit: WatchWorkoutWeightUnit
    @Binding var value: Double
    @Binding var editing: Bool
    var presets: [Double] = []
    @State private var crown = 0.0
    @State private var crownOrigin = 0.0
    @FocusState private var crownFocused: Bool
    private let field = SetValueField.weight

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(IronTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            WatchSetValueTile(exerciseName: title, field: field, value: value, unit: unit, trackingType: .weightReps,
                selected: editing, metricSize: valueSize, compact: false, verticalPadding: 4,
                allowsDeselection: true, onSelect: select, onAdjust: { direction in
                    let changedFocus = !editing
                    if changedFocus { select() }
                    adjust(direction * field.buttonDetents(unit: unit), feedback: !changedFocus)
                })
                // Selection only recolors the tile. Controls have their own reserved frame.
                .frame(height: max(88, valueSize * 1.25 + 20))
                .accessibilityLabel(title == "Target" ? "Target weight" : title)
                .focusable(editing).focused($crownFocused).focusEffectDisabled()
                .watchCrownRotation($crown, in: (-field.maximum / field.step)...(field.maximum / field.step), by: 1,
                                    sensitivity: .medium, haptics: workoutHaptics)
            Group {
                if editing {
                    WatchSetAdjustments(title: title, height: adjustmentHeight, onDone: endEditing) {
                        adjust($0 * field.buttonDetents(unit: unit))
                    }
                } else {
                    Text("Tap weight to edit").font(.footnote).foregroundStyle(IronTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: adjustmentHeight)
                }
            }.frame(height: adjustmentHeight)
            if !presets.isEmpty {
                WatchSectionTitle(title: "Quick Presets")
                // Two columns retain 44-point targets and room for units on a 40 mm Watch.
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                    ForEach(presets, id: \.self) { preset in
                        Button {
                            endEditing()
                            value = preset
                            WatchFeedback.play(.click)
                        } label: {
                            (Text(WatchPlateMath.format(preset)).font(.ironMetric(.body, weight: .semibold))
                             + Text(" \(unit.symbol)").font(.footnote).foregroundColor(IronTheme.secondaryText))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight)
                                .background(value == preset ? IronTheme.accentWash : IronTheme.platter,
                                            in: RoundedRectangle(cornerRadius: IronTheme.compactCornerRadius, style: .continuous))
                        }.buttonStyle(.plain)
                            .foregroundStyle(value == preset ? IronTheme.accentText : IronTheme.primaryText)
                            .accessibilityLabel("Set \(title.lowercased()) to \(WatchPlateMath.format(preset)) \(unit.symbol)")
                    }
                }
            }
        }
        .onChange(of: crown) { persistCrown() }
        .onChange(of: editing) { if !editing { endEditing() } }
        .onChange(of: reducedLuminance) { if reducedLuminance { endEditing() } }
        .onChange(of: unit) { crownFocused = false; editing = false }
        .onDisappear { endEditing() }
        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion || reducedLuminance), value: value)
    }

    private func select() {
        if editing { endEditing(); return }
        crownFocused = false
        crownOrigin = value
        crown = 0
        editing = true
        crownFocused = true
        WatchFeedback.play(.click)
    }
    private func endEditing() {
        persistCrown()
        crownFocused = false
        editing = false
    }
    private func adjust(_ detents: Double, feedback: Bool = true) {
        crown = max((-crownOrigin / field.step).rounded(.down),
                    min(((field.maximum - crownOrigin) / field.step).rounded(.up), crown.rounded() + detents))
        persistCrown()
        if feedback { WatchFeedback.play(.click) }
    }
    private func persistCrown() {
        guard editing, crownFocused else { return }
        value = min(field.maximum, max(0, crownOrigin + crown.rounded() * field.step))
    }
}

// Owns its editing state: a NavigationLink destination doesn't see its parent's @State change,
// so `watchReturnsCrown` would never learn that editing ended.
private struct WatchPlateBaseWeightPage: View {
    let title: String
    let unit: WatchWorkoutWeightUnit
    @Binding var value: Double
    let presets: [Double]
    let footnote: String
    @State private var editing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                WatchPlateWeightEditor(title: title, unit: unit, value: $value, editing: $editing, presets: presets)
                Text(footnote).font(.footnote).foregroundStyle(IronTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, IronTheme.workoutGutter)
        }.watchReturnsCrown(afterEditing: editing).navigationTitle("").watchVitalsInset()
    }
}

private struct WatchPlateChoicePicker<Choice: Hashable>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let choices: [Choice]
    @Binding var selection: Choice
    let label: (Choice) -> String

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(choices, id: \.self) { choice in
                    Button {
                        selection = choice
                        dismiss()
                    } label: {
                        WatchSettingsLabel(title: label(choice), symbol: choice == selection ? "checkmark" : "circle",
                                           color: choice == selection ? IronTheme.accent : IronTheme.settingsGray,
                                           metricValue: false)
                    }.buttonStyle(.plain)
                        .accessibilityValue(choice == selection ? "Selected" : "")
                        .accessibilityAddTraits(choice == selection ? .isSelected : [])
                }
            }.padding(.horizontal, IronTheme.workoutGutter)
        }.navigationTitle(title).watchVitalsInset()
    }
}

private struct WatchPlateToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(configuration.isOn ? IronTheme.accentText : IronTheme.secondaryText)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: IronTheme.controlHeight)
            .watchPlatter()
        }.buttonStyle(.plain)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

private struct WatchPlateCalculatorView: View {
    fileprivate struct PlateLoad: Identifiable {
        let weight: Double
        let count: Int
        var id: Double { weight }
    }
    @Environment(\.dismiss) private var dismiss
    let unit: WatchWorkoutWeightUnit
    let exerciseKey: String?
    let onApply: ((Double) -> Void)?
    @State private var targetWeight: Double
    @State private var loadout: PlateLoadout
    @State private var inventory: PlateInventory
    @State private var editingTarget = false

    init(targetWeight: Double, unit: WatchWorkoutWeightUnit, exerciseKey: String? = nil, onApply: ((Double) -> Void)? = nil) {
        self.unit = unit
        self.exerciseKey = exerciseKey
        self.onApply = onApply
        _targetWeight = State(initialValue: targetWeight.isFinite ? min(max(targetWeight, 0), SetValueField.weight.maximum) : 0)
        _loadout = State(initialValue: PlateLoadout.load(exerciseKey: exerciseKey, unit: unit))
        _inventory = State(initialValue: PlateInventory.load())
    }

    private var solution: PlateLoadSolution { PlateLoadSolver.solve(target: targetWeight, loadout: loadout, inventory: inventory) }
    private var platesPerSide: [PlateLoad] { solution.platesPerSide.map { PlateLoad(weight: $0.weight, count: $0.count) } }
    private var sideTitle: String { loadout.loadedSides == .both ? "Each Side" : "One Side" }
    private var baseTitle: String { mode == .bar ? "Bar Weight" : "Starting Weight" }
    private var mode: WatchPlateMode {
        switch loadout.mode { case .barbell: return .bar; case .noBar: return .noBar; case .machine: return .machine }
    }
    private var modeBinding: Binding<WatchPlateMode> {
        Binding(get: { mode }, set: { mode in
            switch mode {
            case .bar: loadout.mode = .barbell(unit == .kilogram ? 20 : 45)
            case .noBar: loadout.mode = .noBar
            case .machine: loadout.mode = .machine(0)
            }
        })
    }
    private var baseBinding: Binding<Double> {
        Binding(get: { loadout.baseWeight }, set: { value in
            switch loadout.mode {
            case .barbell: loadout.mode = .barbell(value)
            case .machine: loadout.mode = .machine(value)
            case .noBar: break
            }
        })
    }
    private var emptyTitle: String {
        switch loadout.mode { case .barbell: return "Empty bar."; case .noBar: return "No plates."; case .machine: return "Starting weight only." }
    }
    private var loadSummary: String {
        let difference = solution.loadedTotal - targetWeight
        if abs(difference) > 0.001 {
            return "Loads \(WatchPlateMath.format(solution.loadedTotal)) \(unit.symbol) · \(WatchPlateMath.format(abs(difference))) \(unit.symbol) \(difference < 0 ? "short" : "over")"
        }
        return "\(WatchPlateMath.format(solution.plateWeightPerSide)) \(unit.symbol) \(loadout.loadedSides == .both ? "per side" : "on one side")"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                WatchPlateWeightEditor(title: "Target", unit: unit, value: $targetWeight, editing: $editingTarget)
                note(loadSummary).padding(.vertical, 4)
                    .accessibilityLabel("Loaded weight, " + loadSummary)
                WatchBarbellDiagram(plates: platesPerSide, unit: unit, loadout: loadout)
                    .frame(height: 62).padding(.vertical, 4)
                    .accessibilityElement(children: .ignore).accessibilityLabel(diagramDescription)
                if let onApply {
                    Button {
                        onApply(solution.loadedTotal)
                        dismiss()
                    } label: {
                        Text("Use \(WatchPlateMath.format(solution.loadedTotal)) \(unit.symbol)")
                            .font(.ironMetric(.body, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight)
                    }.watchGlassButton(prominent: true)
                        .accessibilityHint("Apply the loaded weight to this set")
                }
                if platesPerSide.isEmpty { note(emptyTitle) }
                if targetWeight < loadout.baseWeight {
                    note(mode == .machine ? "Target is lighter than the machine’s starting weight." : "Target is lighter than the bar.")
                }
                if !platesPerSide.isEmpty {
                    WatchSectionTitle(title: sideTitle)
                    ForEach(platesPerSide) { plateRow($0).watchPlatter() }
                }
                setup
                WatchSectionTitle(title: "Available Plates")
                ForEach(PlateInventory.availablePlates(for: unit), id: \.self) { weight in
                    Toggle(isOn: Binding(
                        get: { inventory.isEnabled(weight, unit: unit) },
                        set: { inventory.setEnabled($0, weight: weight, unit: unit) }
                    )) {
                        HStack(spacing: 8) {
                            plateSwatch(weight)
                            weightReadout(weight, style: .body)
                        }
                    }.toggleStyle(WatchPlateToggleStyle())
                        .accessibilityLabel("\(WatchPlateMath.format(weight)) \(unit.symbol) plates")
                }
                note("Used for every exercise on this device. Plate counts are unlimited.")
                if inventory.enabledPlates(for: unit).isEmpty {
                    note("No plates enabled. Only the starting weight can be loaded.")
                }
            }.padding(.horizontal, IronTheme.workoutGutter).padding(.bottom, 8)
        }
        // As in the full set editor, focus owns the Crown while touch scrolling
        // keeps Done and the presets reachable on small watches or at large text sizes.
        .watchReturnsCrown(afterEditing: editingTarget)
        .navigationTitle("").watchVitalsInset()
        .onAppear { inventory = .load() }
        .onChange(of: loadout) { loadout.save(exerciseKey: exerciseKey) }
        .onChange(of: inventory) { inventory.save() }
        .sensoryFeedback(.selection, trigger: loadout) { _, _ in WatchFeedback.hapticsEnabled }
        .sensoryFeedback(.selection, trigger: inventory) { _, _ in WatchFeedback.hapticsEnabled }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 4) {
            WatchSectionTitle(title: "Setup")
            NavigationLink {
                WatchPlateChoicePicker(title: "Equipment", choices: WatchPlateMode.allCases, selection: modeBinding, label: { $0.title })
            } label: {
                WatchSettingsLabel(title: "Equipment", symbol: "dumbbell.fill", color: IronTheme.settingsGray,
                                   value: mode.title, metricValue: false)
            }.buttonStyle(.plain)
            if mode != .noBar {
                NavigationLink {
                    WatchPlateBaseWeightPage(title: baseTitle, unit: unit, value: baseBinding,
                                             presets: mode == .bar ? (unit == .pound ? [45, 35, 25, 15] : [20, 15, 10]) : [],
                                             footnote: mode == .bar ? "Includes the bar before any plates." : "Includes the leg-press sled or carriage before any plates.")
                } label: {
                    WatchSettingsLabel(title: baseTitle, symbol: "scalemass.fill", color: IronTheme.settingsGray,
                                       value: "\(WatchPlateMath.format(loadout.baseWeight)) \(unit.symbol)", valueColor: IronTheme.accentText)
                }.buttonStyle(.plain)
                    .accessibilityHint("Open the weight editor")
            }
            NavigationLink {
                WatchPlateChoicePicker(title: "Sides", choices: PlateLoadout.LoadedSides.allCases, selection: $loadout.loadedSides,
                                       label: { $0 == .both ? "Both" : "One" })
            } label: {
                WatchSettingsLabel(title: "Sides", symbol: "arrow.left.and.right", color: IronTheme.settingsGray,
                                   value: loadout.loadedSides == .both ? "Both" : "One", metricValue: false)
            }.buttonStyle(.plain)
                .accessibilityLabel("Loaded sides")
                .accessibilityValue(loadout.loadedSides == .both ? "Both sides" : "One side")
            note("Machine weight includes the sled or carriage. One Side suits landmines and single-side T-bars.\(exerciseKey == nil ? "" : " Saved for this exercise.")")
        }
    }

    private func weightReadout(_ value: Double, style: Font.TextStyle) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(WatchPlateMath.format(value)).font(.ironMetric(style, weight: .semibold))
                Text(unit.symbol).font(.footnote).foregroundStyle(IronTheme.secondaryText)
            }.fixedSize()
            VStack(alignment: .leading, spacing: 2) {
                Text(WatchPlateMath.format(value)).font(.ironMetric(.body, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(unit.symbol).font(.footnote).foregroundStyle(IronTheme.secondaryText)
            }
        }.foregroundStyle(IronTheme.primaryText)
    }
    private func plateSwatch(_ weight: Double) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(WatchPlateStyle.color(weight, unit: unit))
            .frame(width: 8, height: 26 * WatchPlateStyle.height(weight, unit: unit))
            .frame(width: 12, height: 26).accessibilityHidden(true)
    }
    private func plateRow(_ plate: PlateLoad) -> some View {
        HStack(spacing: 8) {
            plateSwatch(plate.weight)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    weightReadout(plate.weight, style: .body)
                    Spacer(minLength: 4)
                    Text("×\(plate.count)").font(.ironMetric(.title3, weight: .semibold)).fixedSize()
                }
                VStack(alignment: .leading, spacing: 2) {
                    weightReadout(plate.weight, style: .body)
                    Text("×\(plate.count)").font(.ironMetric(.body, weight: .semibold))
                }
            }
        }
        .frame(minHeight: IronTheme.controlHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(plate.count) times \(WatchPlateMath.format(plate.weight)) \(unit.symbol) \(loadout.loadedSides == .both ? "per side" : "on one side")")
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(IronTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
    private var diagramDescription: String {
        let equipment: String
        switch loadout.mode { case .barbell: equipment = "Barbell"; case .noBar: equipment = "Plate stacks, no bar"; case .machine: equipment = "Front view of a plate-loaded machine with backrest, footplate and left and right plate horns" }
        return equipment + ", " + sideTitle + ": " + (platesPerSide.isEmpty ? emptyTitle : platesPerSide.map { "\($0.count) times \(WatchPlateMath.format($0.weight)) \(unit.symbol)" }.joined(separator: ", "))
    }
}

private enum WatchPlateStyle {
    static func height(_ weight: Double, unit: WatchWorkoutWeightUnit) -> CGFloat {
        PlateProportions.height(for: weight, unit: unit)
    }
    static func width(_ weight: Double, unit: WatchWorkoutWeightUnit) -> CGFloat {
        let largest: Double = unit == .kilogram ? 25 : 45
        return 0.36 + 0.64 * min(max(weight / largest, 0), 1)
    }
    static func color(_ weight: Double, unit: WatchWorkoutWeightUnit) -> Color {
        switch (unit, weight) {
        case (.kilogram, 25), (.kilogram, 2.5), (.pound, 55), (.pound, 5): return IronTheme.plateRed
        case (.kilogram, 20), (.pound, 45): return IronTheme.plateBlue
        case (.kilogram, 15), (.pound, 35): return IronTheme.plateYellow
        case (.kilogram, 10), (.pound, 25): return IronTheme.plateGreen
        case (.kilogram, 5), (.pound, 10): return IronTheme.plateWhite
        default: return IronTheme.plateSteel
        }
    }
}

/// Barbell sleeves, loading-pin stacks, or a front view of a plate-loaded machine.
private struct WatchBarbellDiagram: View {
    let plates: [WatchPlateCalculatorView.PlateLoad]
    let unit: WatchWorkoutWeightUnit
    let loadout: PlateLoadout

    var body: some View {
        Canvas { context, size in
            // Bound drawing cost; the list and VoiceOver retain every plate count.
            let stack = Array(plates.flatMap { Array(repeating: $0.weight, count: min($0.count, 24)) }.prefix(24))
            switch loadout.mode {
            case .noBar: drawStacks(context: context, size: size, stack: stack)
            case .barbell, .machine: drawBarbell(context: context, size: size, stack: stack)
            }
        }
    }

    private func drawBarbell(context: GraphicsContext, size: CGSize, stack: [Double]) {
        let midY = size.height / 2
        let grip = max(size.width * 0.2, 24)
        let collar: CGFloat = 4, gap: CGFloat = 1.5
        let sleeveLength = (size.width - grip) / 2
        let room = max(sleeveLength - collar - 5, 0)
        let natural = stack.reduce(CGFloat.zero) { $0 + 11 * WatchPlateStyle.width($1, unit: unit) + gap }
        let scale = natural > room ? room / natural : 1
        if case .machine = loadout.mode {
            drawMachine(context: context, size: size, width: grip)
        } else {
            fill(context, CGRect(x: 0, y: midY - 2, width: size.width, height: 4), IronTheme.barSteel, radius: 2)
        }
        let sides: [CGFloat] = [-1, 1]
        for side in sides {
            let inner = size.width / 2 + side * grip / 2
            fill(context, CGRect(x: side > 0 ? inner : inner - sleeveLength, y: midY - 3.5, width: sleeveLength, height: 7), IronTheme.barSteel)
            fill(context, CGRect(x: side > 0 ? inner : inner - collar, y: midY - 8, width: collar, height: 16), IronTheme.barSteel)
            guard side > 0 || loadout.loadedSides == .both else { continue }
            var offset = inner + side * collar
            for weight in stack {
                let width = 11 * WatchPlateStyle.width(weight, unit: unit) * scale
                let height = size.height * WatchPlateStyle.height(weight, unit: unit)
                let x = side > 0 ? offset + gap * scale : offset - gap * scale - width
                fill(context, CGRect(x: x, y: midY - height / 2, width: width, height: height),
                     WatchPlateStyle.color(weight, unit: unit), radius: min(2, width / 3))
                offset += side * (width + gap * scale)
            }
        }
    }

    private func drawStacks(context: GraphicsContext, size: CGSize, stack: [Double]) {
        let centers: [CGFloat] = loadout.loadedSides == .both ? [size.width * 0.27, size.width * 0.73] : [size.width / 2]
        let maximumWidth = size.width * (loadout.loadedSides == .both ? 0.4 : 0.66)
        let room = max(0, size.height - 12)
        let natural = stack.reduce(CGFloat.zero) { $0 + 8 * WatchPlateStyle.width($1, unit: unit) + 1.5 }
        let scale = natural > room ? room / natural : 1
        for center in centers {
            fill(context, CGRect(x: center - 1.5, y: 2, width: 3, height: size.height - 6), IronTheme.barSteel)
            fill(context, CGRect(x: center - maximumWidth / 2, y: size.height - 4, width: maximumWidth, height: 4), IronTheme.barSteel)
            var y = size.height - 5
            for weight in stack {
                let thickness = 8 * WatchPlateStyle.width(weight, unit: unit) * scale
                let width = maximumWidth * WatchPlateStyle.height(weight, unit: unit)
                y -= thickness + 1.5 * scale
                fill(context, CGRect(x: center - width / 2, y: y, width: width, height: thickness),
                     WatchPlateStyle.color(weight, unit: unit), radius: min(2, thickness / 3))
            }
        }
    }

    private func drawMachine(context: GraphicsContext, size: CGSize, width: CGFloat) {
        // Only the center changes: horns and plates use the barbell's fitting math,
        // including at 40 mm and with the maximum drawn stack of 24 plates per side.
        let bounds = CGRect(x: (size.width - width) / 2, y: 4, width: width, height: size.height - 8)
        func panel(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: Color) {
            let rect = CGRect(x: bounds.minX + x * bounds.width, y: bounds.minY + y * bounds.height,
                              width: w * bounds.width, height: h * bounds.height)
            fill(context, rect, color, radius: 2)
        }
        panel(0.09, 0.04, 0.06, 0.90, IronTheme.machineRail)
        panel(0.85, 0.04, 0.06, 0.90, IronTheme.machineRail)
        panel(0.09, 0.04, 0.82, 0.04, IronTheme.machineFrame)
        panel(0, 0.92, 1, 0.04, IronTheme.machineFrame)
        panel(0, 0.42, 1, 0.16, IronTheme.machineCarriage)
        panel(0.27, 0.15, 0.46, 0.40, IronTheme.machineSeat)
        panel(0.21, 0.57, 0.58, 0.08, IronTheme.machineSeat)
        panel(0.14, 0.72, 0.72, 0.14, IronTheme.machineFootplate)
    }
    private func fill(_ context: GraphicsContext, _ rect: CGRect, _ color: Color, radius: CGFloat = 1.5) {
        context.fill(Path(roundedRect: rect, cornerRadius: radius, style: .continuous), with: .color(color))
    }
}
