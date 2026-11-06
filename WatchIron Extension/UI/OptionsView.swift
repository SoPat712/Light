import SwiftUI
import HealthKit

struct OptionsView: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    @EnvironmentObject private var navigation: WatchNavigation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isLuminanceReduced) private var reducedLuminance
    @ScaledMetric(relativeTo: .title2) private var metricTileWidth: CGFloat = 88
    @State private var records = Set<UUID>()
    @State private var saving = false
    init(startInFinish: Bool = false) { }

    var body: some View {
        WatchContentList {
            if let snapshot = store.workoutSnapshot {
                Text("Finish Workout").font(.headline.weight(.bold)).padding(.horizontal, 8)
                Text(snapshot.title ?? "Workout").font(.body.weight(.semibold)).foregroundStyle(IronTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 8)
                WatchRecordingFailureRow()
                saveButton(snapshot)
                NavigationLink(value: WatchRoute.effort) {
                    WatchSettingsLabel(title: "Workout Effort", symbol: "chart.bar.fill", color: IronTheme.metricEffort,
                        value: effortText(snapshot.sessionEffort), valueColor: IronTheme.effortColor(effort(snapshot.sessionEffort)))
                }.buttonStyle(.plain)
                recap(snapshot)
                Button { dismiss() } label: { WatchActionLabel(title: "Keep Going") }.watchGlassButton()
                Button(role: .destructive) { navigation.path.append(.discard) } label: {
                    WatchActionLabel(title: "Discard Workout").foregroundStyle(IronTheme.destructiveText)
                }.watchGlassButton()
            }
        }.navigationTitle("").watchVitalsInset()
        .onAppear {
            if let snapshot = store.workoutSnapshot {
                navigation.finishPageAppeared(snapshot)
                records = WatchWorkoutSummary.recordSetIDs(in: snapshot, history: store.library.history)
            }
        }
        .onChange(of: store.persistenceFailure?.id) {
            if store.persistenceFailure != nil {
                saving = false
                WatchFeedback.cancelWorkoutSave()
            }
        }
    }
    private func saveButton(_ snapshot: WatchWorkoutSnapshot) -> some View {
        Button {
            saving = true
            WatchFeedback.expectWorkoutSave(snapshot.workoutID)
            navigation.beginFinish(snapshot, expectsHealth: !store.isHealthTestWorkout && store.workoutSessionManager?.uuid == snapshot.workoutID)
            store.finishWorkout(effort: snapshot.sessionEffort)
        } label: { WatchActionLabel(title: saving ? "Saving…" : "Save Workout", symbol: "checkmark") }
            .watchGlassButton(prominent: true).frame(maxWidth: .infinity).padding(.top, 4)
            .disabled(saving || snapshot.isFinishedRecord || snapshot.completedSets.isEmpty)
    }
    private func recap(_ snapshot: WatchWorkoutSnapshot) -> some View {
        TimelineView(.periodic(from: Date(), by: reducedLuminance ? 60 : 1)) { context in
            let unit = snapshot.weightUnit ?? store.preferredWeightUnit
            // 40 mm and larger text use one wide column instead of smaller values.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: metricTileWidth), spacing: 4)], spacing: 4) {
                tile("Duration", value: WatchNumber.duration(max(0, (snapshot.endDate ?? context.date).timeIntervalSince(snapshot.startDate))), color: IronTheme.metricTime)
                tile(snapshot.trackingMetricTitle, value: snapshot.trackingMetricValue(unit: unit),
                     unit: snapshot.trackingMetricUnit(unit: unit), color: trackingMetricColor(snapshot))
                tile("Sets", value: "\(snapshot.completedSets.count)", unit: "of \(snapshot.allSets.count)", color: IronTheme.metricSets)
                healthMetricTiles(snapshot)
                tile("Records", value: "\(records.count)", unit: records.count == 1 ? "PR" : "PRs", color: IronTheme.metricRecord)
            }
        }
    }
    private func trackingMetricColor(_ snapshot: WatchWorkoutSnapshot) -> Color {
        switch snapshot.trackingMetricTitle {
        case "Volume": return IronTheme.metricVolume
        case "Reps": return IronTheme.metricSets
        default: return IronTheme.metricTime
        }
    }
    @ViewBuilder private func healthMetricTiles(_ snapshot: WatchWorkoutSnapshot) -> some View {
        #if DEBUG
        if store.isHealthTestWorkout {
            tile("Avg Heart Rate", shortTitle: "Avg HR", value: "—", unit: "bpm", color: IronTheme.secondaryText)
            tile("Active Calories", shortTitle: "Calories", value: "--", unit: "kcal", color: IronTheme.metricEnergy)
        } else {
            recordedHealthMetricTiles(snapshot)
        }
        #else
        recordedHealthMetricTiles(snapshot)
        #endif
    }
    @ViewBuilder private func recordedHealthMetricTiles(_ snapshot: WatchWorkoutSnapshot) -> some View {
        // Current BPM is not an average; keep this unknown until supplied.
        tile("Avg Heart Rate", shortTitle: "Avg HR", value: "—", unit: "bpm", color: IronTheme.secondaryText)
        if let manager = store.workoutSessionManager, manager.uuid == snapshot.workoutID {
            WatchLiveEnergyTile(manager: manager)
        } else {
            tile("Active Calories", shortTitle: "Calories", value: WatchNumber.whole(snapshot.activeEnergyKilocalories), unit: "kcal", color: IronTheme.metricEnergy)
        }
    }
    private func tile(_ title: String, shortTitle: String? = nil, value: String, unit: String = "", color: Color) -> some View {
        WatchFinishMetricTile(title: title, shortTitle: shortTitle, value: value, unit: unit, color: color)
    }
    private func effort(_ value: Double?) -> Int { value.map { min(10, max(1, Int($0.rounded()))) } ?? 0 }
    private func effortText(_ value: Double?) -> String {
        let rating = effort(value)
        return rating == 0 ? "Add" : "\(rating) · " + WatchNumber.effortName(rating)
    }
}

private struct WatchFinishMetricTile: View {
    let title: String
    var shortTitle: String? = nil
    let value: String
    var unit: String = ""
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Short labels may wrap at larger text sizes.
            ViewThatFits(in: .horizontal) {
                label(title).fixedSize()
                label(shortTitle ?? title)
            }
            // Keep the number large; move its unit below before scaling.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 2) { number; unitText }
                VStack(alignment: .leading, spacing: 2) { number.minimumScaleFactor(0.85); unitText }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(minHeight: 44).watchPlatter()
            .accessibilityElement(children: .ignore).accessibilityLabel(title).accessibilityValue(value + " " + unit)
    }
    private func label(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(IronTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
    }
    private var number: some View {
        Text(value).font(.ironMetric(.title2, weight: .semibold)).foregroundStyle(color).lineLimit(1)
    }
    @ViewBuilder private var unitText: some View {
        if !unit.isEmpty {
            Text(unit).font(.footnote.weight(.semibold)).foregroundStyle(IronTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WatchLiveEnergyTile: View {
    @ObservedObject var manager: WorkoutSessionManager
    var body: some View {
        WatchFinishMetricTile(title: "Active Calories", shortTitle: "Calories", value: WatchNumber.whole(manager.burnedCalories), unit: "kcal", color: IronTheme.metricEnergy)
    }
}

struct WatchWorkoutEffortPage: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    var body: some View {
        let snapshot = store.workoutSnapshot
        WatchEffortRatingPage(rating: Binding(get: {
            store.workoutSnapshot?.sessionEffort.map { min(10, max(1, Int($0.rounded()))) } ?? 0
        }, set: { rating in
            store.updateCurrent { $0.sessionEffort = rating == 0 ? nil : Double(rating) }
        }), context: WatchNumber.joinedForWrapping([snapshot?.title ?? "Workout",
            snapshot.map { WatchNumber.elapsed($0, at: Date(), reduced: false) } ?? ""]))
    }
}

struct WatchSavedView: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    @EnvironmentObject private var navigation: WatchNavigation
    private var snapshot: WatchWorkoutSnapshot? { navigation.savedWorkout ?? store.workoutSnapshot }
    private var isFinalizing: Bool { store.workoutSnapshot?.workoutID == snapshot?.workoutID && store.workoutSnapshot?.isFinishedRecord == true }
    private var synced: Bool {
        guard let snapshot else { return false }
        return !WatchWorkoutStore.shared.pendingEvents().contains { $0.workoutID == snapshot.workoutID && $0.kind == .workoutFinished }
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 30, weight: .semibold)).foregroundStyle(IronTheme.onAccent)
                    .frame(width: 58, height: 58).background(IronTheme.accent, in: Circle()).accessibilityHidden(true)
                Text("Workout Saved").font(.headline.weight(.bold))
                if let snapshot {
                    Text(snapshot.title ?? "Workout").font(.body.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(WatchNumber.duration(snapshot.recordedDuration)).font(.ironMetric(.title3, weight: .semibold))
                        .foregroundStyle(IronTheme.metricTime)
                }
                Button(action: closeSummary) { WatchActionLabel(title: "Done") }.watchGlassButton(prominent: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 9) { saveDestinations }
                    VStack(spacing: 4) { saveDestinations }
                }
                if isFinalizing { ProgressView("Saving Recording…").font(.footnote) }
                WatchRecordingFailureRow()
            }.multilineTextAlignment(.center).frame(maxWidth: .infinity).scenePadding(.horizontal)
        }.navigationTitle("").navigationBarBackButtonHidden(true)
        .onAppear { if let snapshot { WatchFeedback.workoutSaved(snapshot.workoutID) } }
    }
    private func closeSummary() {
        navigation.savedWorkout = nil
        navigation.healthSaveSucceeded = false
        navigation.expectedHealthSave = false
        navigation.path = []
    }
    @ViewBuilder private var saveDestinations: some View {
        Label(synced ? "On iPhone" : "Waiting for iPhone", systemImage: "iphone")
            .font(.footnote).foregroundStyle(synced ? IronTheme.success : IronTheme.secondaryText)
        if navigation.healthSaveSucceeded {
            Label("In Health", systemImage: "heart.fill").font(.footnote).foregroundStyle(IronTheme.metricHeartRate)
        }
    }
}

struct WatchConfirmView: View {
    enum Action { case discard, exercise(UUID), set(UUID, UUID) }
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    @EnvironmentObject private var navigation: WatchNavigation
    @Environment(\.dismiss) private var dismiss
    let action: Action
    @State private var submitting = false
    var body: some View {
        Group {
            if case .discard = action {
                discardPage
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        Text(title).font(.headline.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                        Text(message).font(.body).foregroundStyle(IronTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
                        Button(role: .destructive, action: confirm) {
                            WatchActionLabel(title: buttonTitle)
                        }.watchGlassButton(destructive: true).disabled(submitting)
                        Button { dismiss() } label: { WatchActionLabel(title: "Cancel") }.watchGlassButton()
                    }.multilineTextAlignment(.center).frame(maxWidth: .infinity).scenePadding(.horizontal)
                }
            }
        }.navigationTitle("").watchVitalsInset()
        .onChange(of: targetExists) {
            guard !targetExists else { return }
            if submitting { WatchFeedback.play(.stop) }
            switch action {
            case .discard: break // Root observes the durable snapshot removal.
            case .exercise: navigation.openWorkout()
            case .set(let id, _):
                if let index = navigation.path.lastIndex(of: .exercise(id)) { navigation.path = Array(navigation.path.prefix(index + 1)) }
                else { navigation.openWorkout() }
            }
        }
        .onChange(of: store.persistenceFailure?.id) { if store.persistenceFailure != nil { submitting = false } }
    }
    private var discardPage: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 180
            let buttonHeight: CGFloat = compact ? 44 : 52
            let clearance: CGFloat = compact ? 6 : 10
            let messageHeight = max(0, proxy.size.height - 22 - buttonHeight * 2 - 12 - clearance)
            VStack(spacing: 4) {
                Text(title).font(.headline.weight(.bold))
                    .lineLimit(1).minimumScaleFactor(0.8).frame(height: 22)
                    .accessibilityAddTraits(.isHeader)
                Text(message).font(.footnote).foregroundStyle(IronTheme.secondaryText)
                    .lineLimit(2).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity).frame(height: messageHeight)
                Button(role: .destructive, action: confirm) {
                    WatchActionLabel(title: buttonTitle).frame(height: buttonHeight - 16)
                }.watchGlassButton(destructive: true).frame(height: buttonHeight).disabled(submitting)
                Button { dismiss() } label: {
                    WatchActionLabel(title: "Cancel").frame(height: buttonHeight - 12)
                }.watchGlassButton().frame(height: buttonHeight)
            }
            .multilineTextAlignment(.center)
            .padding(.bottom, clearance)
            .frame(width: max(0, proxy.size.width - IronTheme.workoutGutter * 2), height: proxy.size.height)
            .padding(.horizontal, IronTheme.workoutGutter)
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }
    private var title: String {
        switch action { case .discard: return "Discard Workout?"; case .exercise: return "Delete Exercise?"; case .set: return "Delete Set?" }
    }
    private var buttonTitle: String { if case .discard = action { return "Discard" }; return "Delete" }
    private var message: String {
        switch action {
        case .discard:
            let count = store.workoutSnapshot?.completedSets.count ?? 0
            return count == 0 ? "Discard this workout?" : "Delete " + WatchNumber.count(count, "logged set") + "?"
        case .exercise(let id):
            let exercise = store.workoutSnapshot?.exercises.first { $0.id == id }
            return "\(exercise?.name ?? "Exercise") and its " + WatchNumber.count(exercise?.sets.count ?? 0, "set") + " will be removed."
        case .set(_, let id):
            let set = store.workoutSnapshot?.allSets.first { $0.id == id }
            return "Set \(set?.order ?? 1) will be deleted. This can’t be undone."
        }
    }
    private var targetExists: Bool {
        switch action {
        case .discard: return store.workoutSnapshot != nil
        case .exercise(let id): return store.workoutSnapshot?.exercises.contains { $0.id == id } ?? false
        case .set(_, let id): return store.workoutSnapshot?.allSets.contains { $0.id == id } ?? false
        }
    }
    private func confirm() {
        submitting = true
        switch action {
        case .discard: store.discardWorkout()
        case .exercise(let id): store.updateCurrent { $0.exercises.removeAll { $0.id == id } }
        case .set(let exerciseID, let id):
            store.updateCurrent { snapshot in
                guard let index = snapshot.exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
                snapshot.exercises[index].sets.removeAll { $0.id == id }
            }
        }
    }
}
