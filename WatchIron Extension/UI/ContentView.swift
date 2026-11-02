import SwiftUI
import HealthKit
import WidgetKit

enum WatchRoute: Hashable {
    case workout, rest, finish, effort, saved, history, settings, done, discard
    case exercise(UUID), set(UUID, UUID), exerciseSettings(UUID), restTimer(UUID), superset(UUID)
    case setType(UUID, UUID), rpe(UUID, UUID), catalog(UUID?)
    case warmup(UUID)
    case deleteExercise(UUID), deleteSet(UUID, UUID)
    case savedDetail(UUID), editSaved(UUID?), historyDetail(UUID)
}

enum WatchWorkoutPage: Int, Hashable { case controls, now, exercises }

final class WatchNavigation: ObservableObject {
    @Published var path: [WatchRoute] = []
    @Published var workoutPage = WatchWorkoutPage.now
    @Published var opensFirstExercise = false
    @Published private(set) var isLogging = false
    @Published var restTotal: TimeInterval = 120
    @Published var savedWorkout: WatchWorkoutSnapshot?
    @Published var healthSaveSucceeded = false
    struct AutomaticRPE: Identifiable, Hashable {
        let exerciseID: UUID
        let setID: UUID
        var id: UUID { setID }
    }
    @Published private(set) var automaticRPE: AutomaticRPE?
    var automaticRPESetID: UUID? { automaticRPE?.setID }
    @Published private(set) var nextExerciseName: String?
    var expectedHealthSave = false
    private var pendingLog: (workoutID: UUID, exerciseID: UUID, setID: UUID, origin: [WatchRoute], fromEditor: Bool)?
    private struct SetFlow {
        let workoutID: UUID
        let exerciseID: UUID
        let setID: UUID
        var needsRPE: Bool
    }
    @Published private var setFlow: SetFlow?
    private var isShowingFlowRPE: Bool {
        guard let flow = setFlow else { return false }
        return isFlowRPE(exerciseID: flow.exerciseID, setID: flow.setID)
    }
    var restHasRPEBack: Bool {
        guard let flow = setFlow else { return false }
        return path == [.workout, .rpe(flow.exerciseID, flow.setID), .rest]
    }
    func isFlowRPE(exerciseID: UUID, setID: UUID) -> Bool {
        setFlow?.exerciseID == exerciseID && setFlow?.setID == setID &&
            path == [.workout, .rpe(exerciseID, setID)]
    }
    private var flowWorkoutID: UUID?
    private var offeredFinishForSets: Set<UUID>?
    private var nowVisible = false
    private var transitionID = UUID()

    func openWorkout() {
        guard !isShowingFlowRPE else { return }
        workoutPage = .now
        path = [.workout]
    }
    func beginFirstExercise() { opensFirstExercise = true }
    func openStartedWorkout(_ snapshot: WatchWorkoutSnapshot) {
        let needsFirstExercise = opensFirstExercise && snapshot.exercises.isEmpty
        opensFirstExercise = false
        workoutPage = .now
        // Install the whole path together after the empty workout is durable.
        path = needsFirstExercise ? [.workout, .catalog(nil)] : [.workout]
        if !needsFirstExercise { resumeRest(in: snapshot) }
    }
    func resumeRest(in snapshot: WatchWorkoutSnapshot) {
        prepareFlow(for: snapshot)
        let remaining = snapshot.pausedRestRemaining ?? snapshot.restTimerEnd?.timeIntervalSinceNow ?? 0
        guard !snapshot.isFinishedRecord, remaining > 0, path.last != .rest,
              !isShowingFlowRPE else { return }
        let schedule = WatchWorkoutEditing.schedule(in: snapshot)
        let nextIndex = snapshot.nextSet.flatMap { schedule.firstIndex(of: $0.set.id) } ?? schedule.count
        let done = Set(snapshot.completedSets.map(\.id))
        let previous = schedule.prefix(nextIndex).last { done.contains($0) }
        let duration = snapshot.exercises.first { exercise in exercise.sets.contains { $0.id == previous } }?.restTimerDuration
            ?? WatchPreferences.defaultRestDuration
        restTotal = max(duration, remaining.rounded(.up))
        if setFlow == nil, let previous,
           let exercise = snapshot.exercises.first(where: { $0.sets.contains { $0.id == previous } }) {
            setFlow = SetFlow(workoutID: snapshot.workoutID, exerciseID: exercise.id, setID: previous, needsRPE: false)
        }
        workoutPage = .now
        path = [.workout, .rest]
    }
    func logSet(exercise: WatchWorkoutExercise, set: WatchWorkoutSet, store: WorkoutSessionManagerStore, fromEditor: Bool) {
        guard !isLogging, !set.completed, let snapshot = store.workoutSnapshot else { return }
        isLogging = true
        prepareFlow(for: snapshot)
        restTotal = exercise.restTimerDuration ?? WatchPreferences.defaultRestDuration
        pendingLog = (snapshot.workoutID, exercise.id, set.id, path, fromEditor)
        if exercise.restTimerDuration == nil {
            let duration = restTotal
            store.updateCurrent { value in
                guard let index = value.exercises.firstIndex(where: { $0.id == exercise.id }) else { return }
                value.exercises[index].restTimerDuration = duration
            }
        }
        store.completeSet(exerciseID: exercise.id, setID: set.id)
    }
    func resolveLog(_ snapshot: WatchWorkoutSnapshot?) {
        guard let pendingLog, let snapshot, snapshot.workoutID == pendingLog.workoutID,
              let loggedSet = snapshot.allSets.first(where: { $0.id == pendingLog.setID }),
              loggedSet.completed else { return }
        setFlow = SetFlow(workoutID: snapshot.workoutID, exerciseID: pendingLog.exerciseID,
                          setID: pendingLog.setID, needsRPE: WatchPreferences.logRPE && loggedSet.rpe == nil)
        let stillAtLog = path == pendingLog.origin &&
            (pendingLog.fromEditor || (workoutPage == .now && nowVisible))
        cancelPendingLog()
        // A durable log may arrive after the user has opened a deliberate detour.
        if stillAtLog { showLoggedSetFlow() }
    }
    func cancelPendingLog() { pendingLog = nil; isLogging = false }

    func setNowVisible(_ visible: Bool, snapshot: WatchWorkoutSnapshot?) {
        nowVisible = visible
        if visible { advanceFlow(in: snapshot) }
    }

    /// RPE advances only on confirmation; expiry must leave a revisited rating
    /// page in place. Other detours keep their own navigation as well.
    func advanceFlow(in snapshot: WatchWorkoutSnapshot?, completingRPE: Bool = false) {
        guard let snapshot, !snapshot.isFinishedRecord else {
            automaticRPE = nil
            return
        }
        prepareFlow(for: snapshot)
        // Appearance callbacks can precede the root's revision observer. Resolve
        // a durable local log before automatic rest routing changes its origin.
        resolveLog(snapshot)
        if snapshot.nextSet != nil { offeredFinishForSets = nil }
        let onNow = path == [.workout] && workoutPage == .now && nowVisible
        let onRest = path.last == .rest
        let confirmedRPE = completingRPE && isShowingFlowRPE
        guard onNow || onRest || confirmedRPE else { return }
        if onNow, setFlow?.needsRPE == true { showLoggedSetFlow(); return }
        let remaining = snapshot.pausedRestRemaining ?? snapshot.restTimerEnd?.timeIntervalSinceNow ?? 0
        if remaining > 0 {
            if onNow { resumeRest(in: snapshot) }
            return
        }
        let previousExercise = setFlow?.exerciseID
        setFlow = nil
        automaticRPE = nil
        if onRest || confirmedRPE { workoutPage = .now; path = [.workout] }
        if let next = snapshot.nextSet {
            if let previousExercise, previousExercise != next.exercise.id { announceNextExercise(next.exercise.name) }
        } else if !snapshot.completedSets.isEmpty {
            let sets = Set(snapshot.allSets.map(\.id))
            guard offeredFinishForSets != sets else { return }
            // Consume before presenting so Keep Going/back can remain on Now.
            offeredFinishForSets = sets
            path = [.workout, .finish]
        }
    }

    func completeAutomaticRPE(exerciseID: UUID, setID: UUID, in snapshot: WatchWorkoutSnapshot?) {
        guard let snapshot, !snapshot.isFinishedRecord, snapshot.workoutID == setFlow?.workoutID,
              isFlowRPE(exerciseID: exerciseID, setID: setID), var flow = setFlow else { return }
        automaticRPE = nil // The durable rest deadline has continued underneath.
        flow.needsRPE = false
        setFlow = flow
        let remaining = snapshot.pausedRestRemaining ?? snapshot.restTimerEnd?.timeIntervalSinceNow ?? 0
        if remaining > 0 { path.append(.rest) }
        else { advanceFlow(in: snapshot, completingRPE: true) }
    }

    func finishPageAppeared(_ snapshot: WatchWorkoutSnapshot) {
        prepareFlow(for: snapshot)
        if snapshot.nextSet == nil { offeredFinishForSets = Set(snapshot.allSets.map(\.id)) }
    }

    private func prepareFlow(for snapshot: WatchWorkoutSnapshot) {
        guard flowWorkoutID != snapshot.workoutID else { return }
        flowWorkoutID = snapshot.workoutID
        setFlow = nil
        automaticRPE = nil
        offeredFinishForSets = nil
        nextExerciseName = nil
    }

    private func showLoggedSetFlow() {
        guard let flow = setFlow else { return }
        workoutPage = .now
        if flow.needsRPE {
            automaticRPE = AutomaticRPE(exerciseID: flow.exerciseID, setID: flow.setID)
            path = [.workout, .rpe(flow.exerciseID, flow.setID)]
        } else {
            automaticRPE = nil
            path = [.workout, .rest]
        }
    }

    private func announceNextExercise(_ name: String) {
        let id = UUID()
        transitionID = id
        nextExerciseName = name
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--hold-watch-flow") { return }
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.transitionID == id else { return }
            self.nextExerciseName = nil
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    func showFlowDemo(in snapshot: WatchWorkoutSnapshot, after setID: UUID, asksRPE: Bool) {
        guard let exercise = snapshot.exercises.first(where: { $0.sets.contains { $0.id == setID } }) else { return }
        prepareFlow(for: snapshot)
        restTotal = exercise.restTimerDuration ?? WatchPreferences.defaultRestDuration
        setFlow = SetFlow(workoutID: snapshot.workoutID, exerciseID: exercise.id, setID: setID,
                          needsRPE: asksRPE) // Fixtures never depend on synchronized preferences.
        if asksRPE { showLoggedSetFlow() }
        else { setNowVisible(true, snapshot: snapshot) }
    }
    #endif
    func beginFinish(_ snapshot: WatchWorkoutSnapshot, expectsHealth: Bool) {
        savedWorkout = snapshot
        expectedHealthSave = expectsHealth
        healthSaveSucceeded = false
    }
}

enum WatchPreferences {
    // The phone owns this setting. Match its default until its first context
    // arrives, then keep the synchronized value for offline Watch logging.
    static var logRPE: Bool {
        get { UserDefaults.standard.object(forKey: "logRPE") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "logRPE") }
    }
    static var defaultRestDuration: TimeInterval {
        get { UserDefaults.standard.object(forKey: "watch.defaultRestDuration") as? Double ?? 120 }
        set { UserDefaults.standard.set(newValue, forKey: "watch.defaultRestDuration") }
    }
}

struct ContentView: View {
    @ObservedObject private var store = WorkoutSessionManagerStore.shared
    @ObservedObject private var phone = PhoneConnectionManager.shared
    @StateObject private var navigation = WatchNavigation()
    @Environment(\.scenePhase) private var scenePhase
    @State private var restoredNavigation = false

    var body: some View {
        NavigationStack(path: $navigation.path) {
            WatchHomeView()
                .navigationDestination(for: WatchRoute.self) { destination($0) }
        }
        .listStyle(.plain)
        .environmentObject(store).environmentObject(navigation)
        .onAppear {
            guard !restoredNavigation else { return }
            restoredNavigation = true
            if let snapshot = store.workoutSnapshot {
                if snapshot.isFinishedRecord {
                    navigation.savedWorkout = snapshot
                    navigation.path = [.done]
                } else {
                    navigation.openStartedWorkout(snapshot)
                    #if DEBUG && targetEnvironment(simulator)
                    // The covered workout page need not appear when restoring
                    // straight to Rest, so flow fixtures start at the root.
                    WatchFocusDemo.openFlowIfRequested(snapshot: snapshot, navigation: navigation)
                    #endif
                }
            }
            #if DEBUG && targetEnvironment(simulator)
            WatchFocusDemo.openRootRouteIfRequested(library: store.library, navigation: navigation)
            #endif
            refreshActiveRoot()
        }
        .onOpenURL { _ in openWorkout() }
        .onContinueUserActivity(NSUserActivityTypeLiveActivity) { _ in openWorkout() }
        .onReceive(NotificationCenter.default.publisher(for: .lightOpenWorkout)) { _ in openWorkout() }
        .onChange(of: store.workoutSnapshot?.workoutID) { reconcileWorkout() }
        .onChange(of: store.workoutSnapshot?.revision) {
            navigation.resolveLog(store.workoutSnapshot)
            navigation.advanceFlow(in: store.workoutSnapshot)
            if store.workoutSnapshot?.isFinishedRecord == true { reconcileWorkout() }
        }
        .onChange(of: navigation.path) { navigation.advanceFlow(in: store.workoutSnapshot) }
        .onChange(of: navigation.workoutPage) { navigation.advanceFlow(in: store.workoutSnapshot) }
        .onChange(of: scenePhase) {
            if scenePhase == .active { refreshActiveRoot(); navigation.advanceFlow(in: store.workoutSnapshot) }
        }
        .alert("Workout Not Saved", isPresented: Binding(
            get: { store.persistenceFailure != nil },
            set: { if !$0 { store.clearPersistenceFailure() } }
        )) {
            Button("OK", role: .cancel) {
                if store.workoutSnapshot == nil { navigation.opensFirstExercise = false }
                store.clearPersistenceFailure(); navigation.cancelPendingLog()
            }
        } message: { Text(store.persistenceFailure?.message ?? "Please try again.") }
    }

    @ViewBuilder private func destination(_ route: WatchRoute) -> some View {
        switch route {
        case .workout: WorkoutSessionView(workoutSessionManager: store.workoutSessionManager)
        case .exercise(let id): ActiveExerciseView(exerciseID: id)
        case .set(let exercise, let set): ActiveSetEditor(exerciseID: exercise, setID: set)
        case .exerciseSettings(let id): ActiveExerciseSettings(exerciseID: id)
        case .warmup(let id): WatchWarmupPage(exerciseID: id)
        case .restTimer(let id): ActiveRestTimerPicker(exerciseID: id)
        case .superset(let id): ActiveSupersetEditor(anchorID: id)
        case .setType(let exercise, let set): ActiveSetTypePicker(exerciseID: exercise, setID: set)
        case .rpe(let exercise, let set): ActiveSetRPEPage(exerciseID: exercise, setID: set).id(set)
        case .catalog(let id): WatchAddExerciseView(replacingID: id)
        case .rest: WatchRestView()
        case .finish: OptionsView(startInFinish: true)
        case .effort: WatchWorkoutEffortPage()
        case .discard: WatchConfirmView(action: .discard)
        case .deleteExercise(let id): WatchConfirmView(action: .exercise(id))
        case .deleteSet(let exercise, let set): WatchConfirmView(action: .set(exercise, set))
        case .saved: SavedWorkoutsView()
        case .savedDetail(let id): SavedWorkoutDetailView(workoutID: id)
        case .editSaved(let id): SavedWorkoutEditor(workout: savedDraft(id))
        case .history: WatchHistoryView()
        case .historyDetail(let id):
            if let workout = store.library.history.first(where: { $0.workoutID == id }) { WatchHistoryDetail(workout: workout) }
        case .settings: WatchSettingsView()
        case .done: WatchSavedView()
        }
    }
    private func savedDraft(_ id: UUID?) -> WatchSavedWorkout {
        store.library.savedWorkouts.first { $0.id == id } ?? WatchSavedWorkout(id: UUID(), title: "Workout", exercises: [],
            weightUnit: store.preferredWeightUnit, comment: nil, updatedAt: Date())
    }
    private func reconcileWorkout() {
        if let snapshot = store.workoutSnapshot {
            if snapshot.isFinishedRecord {
                navigation.savedWorkout = snapshot
                navigation.path = [.done]
            } else if navigation.opensFirstExercise || navigation.path.first != .workout {
                navigation.savedWorkout = nil
                navigation.openStartedWorkout(snapshot)
            }
        } else if let saved = navigation.savedWorkout,
                  let recorded = store.library.history.first(where: { $0.workoutID == saved.workoutID }) {
            navigation.savedWorkout = recorded
            navigation.healthSaveSucceeded = navigation.expectedHealthSave && store.recordingError == nil
            navigation.path = [.done]
        } else { navigation.path = [] }
    }
    private func openWorkout() {
        if let snapshot = store.workoutSnapshot { navigation.openWorkout(); navigation.resumeRest(in: snapshot) }
        else { navigation.path = [] }
        refreshActiveRoot()
    }
    private func refreshActiveRoot() {
        store.ensureAutomaticRecording()
        phone.requestLibrary()
        phone.requestCurrentSnapshotIfReady()
    }
}

private struct WatchHomeView: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    @EnvironmentObject private var navigation: WatchNavigation
    var body: some View {
        WatchContentList(extraBottomInset: 6) {
            if let current = store.workoutSnapshot {
                Button { navigation.openWorkout(); navigation.resumeRest(in: current) } label: {
                    ResumeWorkoutCard(snapshot: current)
                }.buttonStyle(.plain)
            } else {
                Button { navigation.beginFirstExercise(); store.startBlankWorkout() } label: { WatchActionLabel(title: "New Workout", symbol: "plus") }
                    .watchGlassButton(prominent: true).frame(maxWidth: .infinity)
                    .disabled(navigation.opensFirstExercise)
            }
            Section {
                ForEach(Array(saved.prefix(3))) { workout in
                    NavigationLink(value: WatchRoute.savedDetail(workout.id)) {
                        WatchWorkoutSummaryRow(title: workout.title, exercises: workout.exercises).watchPlatter()
                    }.buttonStyle(.plain)
                }
                Button { navigation.path.append(.saved) } label: { WatchActionLabel(title: "All Saved Workouts") }
                    .foregroundStyle(IronTheme.accentText).watchGlassButton()
            } header: { WatchSectionTitle(title: "Saved Workouts") }
            Section {
                ForEach(Array(store.library.history.prefix(3)), id: \.workoutID) { workout in
                    NavigationLink(value: WatchRoute.historyDetail(workout.workoutID)) {
                        WatchWorkoutSummaryRow(title: workout.title ?? "Workout", exercises: workout.exercises,
                            date: workout.startDate, duration: workout.recordedDuration, unit: workout.weightUnit ?? store.preferredWeightUnit).watchPlatter()
                    }.buttonStyle(.plain)
                }
                Button { navigation.path.append(.history) } label: { WatchActionLabel(title: "All History") }
                    .foregroundStyle(IronTheme.accentText).watchGlassButton()
            } header: { WatchSectionTitle(title: "History") }
            NavigationLink(value: WatchRoute.settings) {
                WatchSettingsLabel(title: "Settings", symbol: "gearshape.fill", color: IronTheme.settingsGray)
            }.buttonStyle(.plain).padding(.top, 8)
        }
        .navigationTitle("").toolbarTitleDisplayMode(.inline).watchVitalsInset(showsBack: false)
    }
    private var saved: [WatchSavedWorkout] {
        store.library.savedWorkouts.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}

private struct ResumeWorkoutCard: View {
    let snapshot: WatchWorkoutSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(IronTheme.accentText).frame(width: 5, height: 5)
                Text("In Progress").font(.footnote.weight(.semibold)).foregroundStyle(IronTheme.accentText)
            }
            Text(snapshot.title ?? "Workout").font(.headline.bold()).foregroundStyle(IronTheme.primaryText)
            WatchSessionMetrics(snapshot: snapshot, includesVolume: false)
            WatchProgressCells(sets: snapshot.allSets, spacing: 1.5).accessibilityHidden(true).padding(.top, 2)
        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(IronTheme.accentWash, in: RoundedRectangle(cornerRadius: IronTheme.upNextCornerRadius, style: .continuous))
            .accessibilityElement(children: .combine)
    }
}

struct SavedWorkoutsView: View {
    @EnvironmentObject private var navigation: WatchNavigation
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    var body: some View {
        WatchContentList {
            Text("Saved Workouts").font(.headline.weight(.bold)).padding(.horizontal, 8)
            Button { navigation.path.append(.editSaved(nil)) } label: { WatchActionLabel(title: "New Saved Workout", symbol: "plus") }
                .watchGlassButton(prominent: true).frame(maxWidth: .infinity)
            if store.library.savedWorkouts.isEmpty {
                Text("Create one here or sync from iPhone.").font(.footnote).foregroundStyle(IronTheme.secondaryText)
            }
            ForEach(store.library.savedWorkouts.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }) { workout in
                NavigationLink(value: WatchRoute.savedDetail(workout.id)) {
                    WatchWorkoutSummaryRow(title: workout.title, exercises: workout.exercises).watchPlatter()
                }.buttonStyle(.plain)
            }
        }.navigationTitle("").watchVitalsInset()
    }
}

private struct SavedWorkoutDetailView: View {
    @EnvironmentObject private var navigation: WatchNavigation
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    @Environment(\.dismiss) private var dismiss
    let workoutID: UUID
    private var workout: WatchSavedWorkout? { store.library.savedWorkouts.first { $0.id == workoutID } }
    var body: some View {
        WatchContentList {
            if let workout {
                Text(workout.title).font(.headline.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 8)
                Button { store.startWorkout(from: workout) } label: { WatchActionLabel(title: "Start Workout", symbol: "play.fill") }
                    .watchGlassButton(prominent: true).frame(maxWidth: .infinity).disabled(store.workoutSnapshot != nil)
                if store.workoutSnapshot != nil { Text("Finish your current workout to start another.").font(.footnote).foregroundStyle(IronTheme.secondaryText) }
                (Text(WatchNumber.count(workout.exercises.flatMap(\.sets).count, "set")).foregroundColor(IronTheme.metricSets)
                 + Text(" · " + WatchNumber.count(workout.exercises.count, "exercise")).foregroundColor(IronTheme.secondaryText))
                    .font(.ironMetric(.footnote, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(WatchNumber.joinedForWrapping([WatchWorkoutSummary.muscles(workout.exercises), lastDone(workout)]))
                    .font(.footnote).foregroundStyle(IronTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                WatchSectionTitle(title: "Exercises")
                ForEach(workout.exercises.sorted { $0.order < $1.order }) { exercise in
                    NavigationLink { RecordedExerciseView(exercise: exercise, unit: workout.weightUnit, isTemplate: true) } label: {
                        RecordedExerciseRow(exercise: exercise, unit: workout.weightUnit, isTemplate: true).watchPlatter()
                    }.buttonStyle(.plain)
                }
                Button { navigation.path.append(.editSaved(workout.id)) } label: { WatchActionLabel(title: "Edit Workout", symbol: "pencil") }
                    .watchGlassButton().padding(.top, 4)
            }
        }.navigationTitle("").watchVitalsInset()
        .onChange(of: workout == nil) { if workout == nil { dismiss() } }
    }
    private func lastDone(_ workout: WatchSavedWorkout) -> String {
        guard let date = store.library.history.first(where: { $0.sourceSavedWorkoutID == workout.id || $0.title == workout.title })?.startDate else { return "Not done yet" }
        return "Last done " + date.formatted(.dateTime.month(.abbreviated).day())
    }
}

private struct SavedWorkoutEditor: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WatchSavedWorkout
    @State private var confirmingDelete = false
    @State private var saving = false
    init(workout: WatchSavedWorkout) {
        var value = workout
        let unit = WorkoutSessionManagerStore.shared.preferredWeightUnit
        let projection = WatchWorkoutSnapshot(workoutID: workout.id, exercises: workout.exercises, weightUnit: workout.weightUnit)
        value.exercises = WatchWorkoutEditing.converting(projection, to: unit).exercises
        value.weightUnit = unit
        _draft = State(initialValue: value)
    }
    var body: some View {
        List {
            Section { saveButton }
            Section("Edit Workout") {
                TextField("Name", text: $draft.title).font(.body.weight(.semibold))
                TextField("Notes", text: optionalText($draft.comment), axis: .vertical)
            }
            Section("Exercises") {
                ForEach(draft.exercises) { item in
                    NavigationLink {
                        SavedExerciseEditor(exercise: exerciseBinding(item), catalog: store.library.exercises, unit: draft.weightUnit,
                            onMove: { move(item.id, by: $0) }, canMoveUp: item.id != draft.exercises.first?.id,
                            canMoveDown: item.id != draft.exercises.last?.id,
                            supersetDestination: { AnyView(SupersetDraftEditor(exercises: $draft.exercises, anchorID: item.id)) },
                            onDelete: { draft.exercises.removeAll { $0.id == item.id }; normalizeDraft() })
                    } label: { RecordedExerciseRow(exercise: item, unit: draft.weightUnit, isTemplate: true) }
                }
                NavigationLink {
                    WatchCatalogPicker(catalog: store.library.exercises) { pick in
                        draft.exercises.append(WatchWorkoutExercise(order: draft.exercises.count + 1, name: pick.name,
                            sets: [WatchWorkoutSet(order: 1, minTargetReps: 8, maxTargetReps: 8)],
                            restTimerDuration: WatchPreferences.defaultRestDuration, muscleGroup: pick.muscle,
                            exerciseUuid: pick.id, imageURL: pick.imageURL))
                    }
                } label: {
                    Label("Add Exercise", systemImage: "plus").font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight, alignment: .leading)
                }
            }
            Section {
                Button(role: .cancel) { dismiss() } label: { WatchActionLabel(title: "Cancel") }
                    .watchGlassButton().listRowBackground(EmptyView())
                if store.library.savedWorkouts.contains(where: { $0.id == draft.id }) {
                    Button("Delete Workout", systemImage: "trash.fill", role: .destructive) { confirmingDelete = true }
                        .font(.body.weight(.semibold))
                }
            }
        }
        .navigationTitle("").watchVitalsInset()
        .confirmationDialog("Delete Saved Workout?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { store.deleteSavedWorkout(id: draft.id) { if $0 { dismiss() } } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Workout history is kept.") }
    }
    private var saveButton: some View {
        Button {
            normalizeDraft(); draft.updatedAt = Date(); saving = true
            store.saveWorkout(draft) { saved in saving = false; if saved { dismiss() } }
        } label: { WatchActionLabel(title: saving ? "Saving…" : "Save Workout", symbol: "checkmark") }
            .watchGlassButton(prominent: true).listRowBackground(EmptyView())
            .disabled(saving || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    private func optionalText(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0.isEmpty ? nil : $0 })
    }
    private func exerciseBinding(_ item: WatchWorkoutExercise) -> Binding<WatchWorkoutExercise> {
        Binding(get: { draft.exercises.first { $0.id == item.id } ?? item }, set: { replacement in
            guard let index = draft.exercises.firstIndex(where: { $0.id == item.id }) else { return }
            draft.exercises[index] = replacement
        })
    }
    private func move(_ id: UUID, by offset: Int) {
        guard let index = draft.exercises.firstIndex(where: { $0.id == id }), draft.exercises.indices.contains(index + offset) else { return }
        draft.exercises.swapAt(index, index + offset); normalizeDraft()
    }
    private func normalizeDraft() {
        var projection = WatchWorkoutSnapshot(workoutID: draft.id, exercises: draft.exercises)
        WatchWorkoutEditing.normalize(&projection); draft.exercises = projection.exercises
    }
}

private struct SavedExerciseEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var exercise: WatchWorkoutExercise
    let catalog: [WatchExercisePick]
    let unit: WatchWorkoutWeightUnit
    let onMove: (Int) -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool
    let supersetDestination: () -> AnyView
    let onDelete: () -> Void
    @State private var confirmingDelete = false
    var body: some View {
        List {
            Section {
                Text(exercise.name).font(.headline.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                Text(WatchWorkoutSummary.meta(name: exercise.name, muscle: exercise.muscleGroup))
                    .font(.footnote).foregroundStyle(IronTheme.secondaryText)
            }.listRowBackground(EmptyView())
            Section("Sets") {
                ForEach(exercise.sets) { item in
                    NavigationLink {
                        SavedSetEditor(set: setBinding(item), unit: unit, canDelete: exercise.sets.count > 1) {
                            exercise.sets.removeAll { $0.id == item.id }
                            for index in exercise.sets.indices { exercise.sets[index].order = index + 1 }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Set \(item.order)").font(.ironMetric(.headline))
                            Text(target(item)).font(.ironMetric(.body, weight: .semibold)).foregroundStyle(IronTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                    }
                }
                Button("Add Set", systemImage: "plus") {
                    let source = exercise.sets.last
                    exercise.sets.append(WatchWorkoutSet(order: exercise.sets.count + 1, weight: source?.weight,
                        reps: source?.minTargetReps != nil || source?.maxTargetReps != nil ? nil : source?.reps,
                        tag: source?.tag, duration: source?.duration, distance: source?.distance,
                        minTargetReps: source?.minTargetReps, maxTargetReps: source?.maxTargetReps))
                }.font(.body.weight(.semibold))
            }
            Section("Exercise Settings") {
                NavigationLink {
                    WatchRestTimerPicker(context: exercise.name, initialValue: exercise.restTimerDuration ?? WatchPreferences.defaultRestDuration) {
                        exercise.restTimerDuration = $0
                    }
                } label: { WatchSettingsLabel(title: "Rest Timer", symbol: "timer", color: IronTheme.settingsCyan,
                    value: WatchNumber.clock(exercise.restTimerDuration ?? WatchPreferences.defaultRestDuration), valueColor: IronTheme.metricTime) }
                NavigationLink { supersetDestination() } label: { WatchSettingsLabel(title: "Superset", symbol: "link", color: IronTheme.accent,
                    value: exercise.supersetID == nil ? "None" : "Linked") }
                NavigationLink {
                    WatchCatalogPicker(catalog: catalog, title: "Replace Exercise") { pick in
                        exercise.name = pick.name; exercise.exerciseUuid = pick.id
                        exercise.muscleGroup = pick.muscle; exercise.imageURL = pick.imageURL; exercise.imageData = nil
                    }
                } label: { WatchSettingsLabel(title: "Replace Exercise", symbol: "arrow.triangle.2.circlepath", color: IronTheme.settingsGray) }
                VStack(spacing: 4) {
                    Button { onMove(-1) } label: { WatchActionLabel(title: "Move Up", symbol: "arrow.up").frame(minHeight: 44) }.disabled(!canMoveUp)
                    Button { onMove(1) } label: { WatchActionLabel(title: "Move Down", symbol: "arrow.down").frame(minHeight: 44) }.disabled(!canMoveDown)
                }.watchGlassButton()
                TextField("Plan Note", text: Binding(get: { exercise.routineNote ?? "" }, set: { exercise.routineNote = $0.isEmpty ? nil : $0 }), axis: .vertical)
                Button(role: .destructive) { confirmingDelete = true } label: {
                    WatchSettingsLabel(title: "Delete Exercise", symbol: "trash.fill", color: IronTheme.danger, destructive: true)
                }
            }.listRowBackground(EmptyView())
        }
        .navigationTitle("").watchVitalsInset()
        .confirmationDialog("Delete Exercise?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { onDelete(); dismiss() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("\(exercise.name) and its " + WatchNumber.count(exercise.sets.count, "set") + " will be removed.") }
    }
    private func setBinding(_ item: WatchWorkoutSet) -> Binding<WatchWorkoutSet> {
        Binding(get: { exercise.sets.first { $0.id == item.id } ?? item }, set: { value in
            guard let index = exercise.sets.firstIndex(where: { $0.id == item.id }) else { return }
            exercise.sets[index] = value
        })
    }
    private func target(_ set: WatchWorkoutSet) -> String {
        var value = set; value.reps = set.maxTargetReps ?? set.minTargetReps ?? set.reps
        return value.displayText(weightUnit: unit, trackingType: exercise.effectiveTrackingType)
    }
}

private struct SavedSetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var set: WatchWorkoutSet
    let unit: WatchWorkoutWeightUnit
    let canDelete: Bool
    let onDelete: () -> Void
    @State private var confirmingDelete = false
    var body: some View {
        List {
            Section("Targets") {
                field(.weight); field(.minimum); field(.maximum); field(.duration); field(.distance)
            }
            Section("Set Settings") {
                Picker("Set Type", selection: Binding(get: { set.tag ?? "working" }, set: { set.tag = $0 == "working" ? nil : $0 })) {
                    Text("Normal").tag("working"); Text("Warm-up").tag("warmUp")
                    Text("Drop Set").tag("dropSet"); Text("Failure").tag("failure")
                }.font(.body.weight(.semibold))
                TextField("Notes", text: Binding(get: { set.comment ?? "" }, set: { set.comment = $0.isEmpty ? nil : $0 }), axis: .vertical)
                Button("Delete Set", systemImage: "trash.fill", role: .destructive) { confirmingDelete = true }
                    .font(.body.weight(.semibold)).disabled(!canDelete)
            }
        }
        .navigationTitle("Set \(set.order)").watchVitalsInset()
        .confirmationDialog("Delete Set?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { onDelete(); dismiss() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This set will be removed from the saved workout. Workout history is kept.") }
    }
    private func field(_ field: SetDraftField) -> some View {
        NavigationLink {
            WatchNumericEditor(title: field.title, unit: field == .weight ? unit.symbol : field.unit, range: field.range,
                step: field.step, initialValue: field.value(in: set), allowsEmpty: true) { field.apply($0, to: &set) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(field.title).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(field.value(in: set) > 0 ? WatchNumber.format(field.value(in: set)) : "--")
                        .font(.ironMetric(.title3)).foregroundStyle(IronTheme.primaryText)
                    Text(field == .weight ? unit.symbol : field.unit)
                        .font(.footnote).foregroundStyle(IronTheme.secondaryText)
                }.fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight, alignment: .leading)
                .accessibilityElement(children: .combine)
        }
    }
}

private enum SetDraftField {
    case weight, minimum, maximum, duration, distance
    var title: String {
        switch self { case .weight: return "Weight"; case .minimum: return "Minimum Reps"; case .maximum: return "Maximum Reps"; case .duration: return "Duration"; case .distance: return "Distance" }
    }
    var unit: String {
        switch self { case .duration: return "seconds"; case .distance: return "meters"; case .weight: return "weight"; case .minimum, .maximum: return "reps" }
    }
    var range: ClosedRange<Double> { self == .duration ? 0...3_600 : (self == .distance ? 0...100_000 : 0...2_000) }
    var step: Double { self == .weight ? 0.5 : (self == .duration ? 5 : 1) }
    func value(in set: WatchWorkoutSet) -> Double {
        switch self { case .weight: return set.weight ?? 0; case .minimum: return Double(set.minTargetReps ?? 0); case .maximum: return Double(set.maxTargetReps ?? 0); case .duration: return set.duration ?? 0; case .distance: return set.distance ?? 0 }
    }
    func apply(_ value: Double?, to set: inout WatchWorkoutSet) {
        switch self { case .weight: set.weight = value; case .minimum: set.minTargetReps = value.map { Int($0.rounded()) }; set.reps = nil
        case .maximum: set.maxTargetReps = value.map { Int($0.rounded()) }; set.reps = nil; case .duration: set.duration = value; case .distance: set.distance = value }
    }
}

private struct SupersetDraftEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var exercises: [WatchWorkoutExercise]
    let anchorID: UUID
    @State private var selected = Set<UUID>()
    var body: some View {
        WatchContentList {
            Text("Alternate sets with " + (exercises.first { $0.id == anchorID }?.name ?? "Exercise"))
                .font(.footnote).foregroundStyle(IronTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
            ForEach(exercises.filter { $0.id != anchorID }) { exercise in
                Button { if !selected.insert(exercise.id).inserted { selected.remove(exercise.id) } } label: {
                    WatchSupersetRow(exercise: exercise, selected: selected.contains(exercise.id))
                }.buttonStyle(.plain)
            }
        }.navigationTitle("Superset").watchVitalsInset()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: saveSuperset) { Image(systemName: "checkmark") }.accessibilityLabel("Save Superset")
            }
        }
        .onAppear {
            guard selected.isEmpty, let group = exercises.first(where: { $0.id == anchorID })?.supersetID else { return }
            selected = Set(exercises.filter { $0.id != anchorID && $0.supersetID == group }.map(\.id))
        }
    }
    private func saveSuperset() {
        var projection = WatchWorkoutSnapshot(workoutID: UUID(), exercises: exercises)
        WatchWorkoutEditing.replaceSuperset(exerciseIDs: selected.union([anchorID]), anchorID: anchorID, in: &projection)
        exercises = projection.exercises; dismiss()
    }
}

struct WatchCatalogPicker: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isLuminanceReduced) private var reducedLuminance
    let catalog: [WatchExercisePick]
    var title = "Add Exercise"
    let onPick: (WatchExercisePick) -> Void
    @State private var query = ""
    @State private var recent: [WatchExercisePick] = []
    @State private var alphabetical: [WatchExercisePick] = []
    @State private var listedAlphabetical: [WatchExercisePick] = []
    /// Search reaches every exercise, listed ones first; the plain list leaves out the rest.
    private var allExercises: [WatchExercisePick] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return listedAlphabetical }
        let matches = filtered(alphabetical)
        return matches.filter { $0.listed != false } + matches.filter { $0.listed == false }
    }
    var body: some View {
        VStack(spacing: 2) {
            if let snapshot = store.workoutSnapshot, !snapshot.isFinishedRecord {
                WatchVitalsRow(manager: store.workoutSessionManager, snapshot: snapshot)
                    .privacySensitive(false).unredacted()
                    .scenePadding(.horizontal)
            }
            List {
                if !filtered(recent).isEmpty {
                    Section("Recent") { ForEach(filtered(recent)) { pick in pickerRow(pick) } }
                }
                Section("All Exercises") { ForEach(allExercises) { pick in pickerRow(pick) } }
            }
            .searchable(text: $query, prompt: "Search or dictate")
            .opacity(reducedLuminance && store.workoutSnapshot?.isFinishedRecord == false ? 0.45 : 1)
        }
        .navigationTitle(title)
        .onAppear(perform: prepareCatalog)
        .onChange(of: store.library.generatedAt) { prepareCatalog() }
    }
    private func filtered(_ values: [WatchExercisePick]) -> [WatchExercisePick] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? values : values.filter { $0.name.localizedCaseInsensitiveContains(text) || ($0.muscle?.localizedCaseInsensitiveContains(text) ?? false) }
    }
    private func pickerRow(_ pick: WatchExercisePick) -> some View {
        Button { onPick(pick); dismiss() } label: {
            HStack(spacing: 6) {
                Text(pick.name).font(.headline).foregroundStyle(IronTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "plus").font(.body.weight(.semibold))
                    .foregroundStyle(IronTheme.accentText).accessibilityHidden(true)
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .accessibilityLabel("Add " + pick.name)
    }
    private func prepareCatalog() {
        alphabetical = catalog.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let listed = alphabetical.filter { $0.listed != false }
        listedAlphabetical = listed.isEmpty ? alphabetical : listed
        var dates: [UUID: Date] = [:]
        for workout in store.library.history where workout.allSets.contains(where: \.completed) {
            for exercise in workout.exercises {
                guard let id = exercise.exerciseUuid else { continue }
                dates[id] = max(dates[id] ?? .distantPast, workout.startDate)
            }
        }
        recent = alphabetical.filter { dates[$0.id] != nil }.sorted {
            let left = dates[$0.id] ?? .distantPast, right = dates[$1.id] ?? .distantPast
            if left != right { return left > right }
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
        }
    }
}

struct WatchHistoryView: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    var body: some View {
        WatchContentList {
            Text("History").font(.headline.weight(.bold)).padding(.horizontal, 8)
            if store.library.history.isEmpty { Text("Completed workouts appear here.").font(.footnote).foregroundStyle(IronTheme.secondaryText) }
            ForEach(store.library.history, id: \.workoutID) { workout in
                NavigationLink(value: WatchRoute.historyDetail(workout.workoutID)) {
                    WatchWorkoutSummaryRow(title: workout.title ?? "Workout", exercises: workout.exercises, date: workout.startDate,
                        duration: workout.recordedDuration, unit: workout.weightUnit ?? store.preferredWeightUnit).watchPlatter()
                }.buttonStyle(.plain)
            }
        }.navigationTitle("").watchVitalsInset()
    }
}

private struct WatchHistoryDetail: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    let workout: WatchWorkoutSnapshot
    @State private var saved = false
    @State private var records = Set<UUID>()
    var body: some View {
        WatchContentList {
            Text(workout.title ?? "Workout").font(.headline.weight(.bold))
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 8)
            Button { store.repeatWorkout(workout) } label: { WatchActionLabel(title: "Repeat Workout", symbol: "arrow.clockwise") }
                .watchGlassButton(prominent: true).frame(maxWidth: .infinity).disabled(store.workoutSnapshot != nil)
            if store.workoutSnapshot != nil { Text("Finish your current workout to repeat this one.").font(.footnote).foregroundStyle(IronTheme.secondaryText) }
            Text(WatchNumber.dateAndTime(workout.startDate)).font(.footnote).foregroundStyle(IronTheme.secondaryText)
            WatchSessionMetrics(snapshot: workout)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { recordingMetrics }
                VStack(alignment: .leading, spacing: 2) { recordingMetrics }
            }.font(.ironMetric(.footnote, weight: .semibold)).accessibilityElement(children: .combine)
            WatchSectionTitle(title: "Exercises")
            ForEach(workout.exercises) { exercise in
                NavigationLink { RecordedExerciseView(exercise: exercise, unit: workout.weightUnit ?? .kilogram) } label: {
                    RecordedExerciseRow(exercise: exercise, unit: workout.weightUnit ?? .kilogram,
                        hasRecord: exercise.sets.contains { records.contains($0.id) }).watchPlatter()
                }.buttonStyle(.plain)
            }
            if let comment = workout.comment, !comment.isEmpty {
                WatchSectionTitle(title: "Notes"); Text(comment).font(.footnote).foregroundStyle(IronTheme.secondaryText)
            }
            Button {
                store.saveAsWorkout(workout) { saved = $0 }
            } label: { WatchActionLabel(title: saved ? "Workout Saved" : "Save as Workout", symbol: saved ? "checkmark" : "bookmark") }
                .watchGlassButton().disabled(saved).padding(.top, 4)
        }.navigationTitle("").watchVitalsInset()
        .onAppear { records = WatchWorkoutSummary.recordSetIDs(in: workout, history: store.library.history) }
    }
    @ViewBuilder private var recordingMetrics: some View {
        HStack(spacing: 4) {
            Image(systemName: "heart.fill").foregroundStyle(IronTheme.metricHeartRate).accessibilityHidden(true)
            WatchMetricValue(value: "--", unit: "avg bpm", color: IronTheme.metricHeartRate)
        }.accessibilityElement(children: .combine)
        HStack(spacing: 4) {
            Image(systemName: "flame.fill").foregroundStyle(IronTheme.metricEnergy).accessibilityHidden(true)
            WatchMetricValue(value: WatchNumber.whole(workout.activeEnergyKilocalories), unit: "kcal", color: IronTheme.metricEnergy)
        }.accessibilityElement(children: .combine)
    }
}

private struct RecordedExerciseRow: View {
    let exercise: WatchWorkoutExercise
    let unit: WatchWorkoutWeightUnit
    var isTemplate = false
    var hasRecord = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(exercise.name).font(.headline).foregroundStyle(IronTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .top, spacing: 6) {
                WatchExerciseThumbnail(imageURL: exercise.imageURL, imageData: exercise.imageData, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(detail).font(.ironMetric(.footnote, weight: .semibold)).foregroundStyle(IronTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if hasRecord {
                        Text("PR").font(.ironMetric(.footnote)).foregroundStyle(IronTheme.metricRecord)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(IronTheme.metricRecord.opacity(0.2), in: Capsule())
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight, alignment: .leading).accessibilityElement(children: .combine)
    }
    private var detail: String {
        let candidates = isTemplate ? exercise.sets : exercise.sets.filter(\.completed)
        // A historical exercise can contain older measurement dimensions. Compare
        // like measurements, using the last listed set's type for its summary.
        let type = isTemplate ? exercise.effectiveTrackingType
            : candidates.last.map { exercise.effectiveTrackingType(for: $0) } ?? exercise.effectiveTrackingType
        let best = candidates.filter { isTemplate || exercise.effectiveTrackingType(for: $0) == type }.max { left, right in
            ranking(left, type: type).lexicographicallyPrecedes(ranking(right, type: type))
        }
        guard var best else { return WatchNumber.count(exercise.sets.count, "set") }
        if isTemplate { best.reps = best.maxTargetReps ?? best.minTargetReps ?? best.reps }
        let set = (isTemplate ? "" : "Best ") + best.displayText(weightUnit: unit, trackingType: type)
        return WatchNumber.joinedForWrapping([WatchNumber.count(candidates.count, "set"), set])
    }
    private func ranking(_ set: WatchWorkoutSet, type: SetTrackingType) -> [Double] {
        func measurement(_ value: Double?) -> Double {
            value.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 0
        }
        let weight = measurement(set.weight)
        let reps = Double(isTemplate ? set.maxTargetReps ?? set.minTargetReps ?? set.reps ?? 0 : set.reps ?? 0)
        let duration = measurement(set.duration)
        let distance = measurement(set.distance)
        switch type {
        case .weightReps, .weightedBodyweight: return [weight, reps]
        case .assistedBodyweight: return [-weight, reps]
        case .bodyweightReps: return [reps]
        case .duration: return [duration]
        case .weightDuration: return [weight, duration]
        case .distanceDuration: return [distance, duration]
        case .weightDistance: return [weight, distance]
        }
    }
}

private struct RecordedExerciseView: View {
    let exercise: WatchWorkoutExercise
    let unit: WatchWorkoutWeightUnit
    var isTemplate = false
    var body: some View {
        List {
            Section {
                Text(exercise.name).font(.headline.weight(.bold)).fixedSize(horizontal: false, vertical: true)
            }.listRowBackground(EmptyView())
            if let comment = exercise.comment, !comment.isEmpty { Section("Notes") { Text(comment) } }
            Section(isTemplate ? "Targets" : "Sets") {
                ForEach(exercise.sets) { set in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Set \(set.order) · \(set.kindTitle)").font(.ironMetric(.headline))
                        Text(result(set)).font(.ironMetric(.body, weight: .semibold))
                        if let rpe = set.rpe { Text("RPE \(WatchNumber.format(rpe))").font(.ironMetric(.footnote)).foregroundStyle(IronTheme.metricEffort) }
                        if let comment = set.comment, !comment.isEmpty { Text(comment).font(.footnote).foregroundStyle(IronTheme.secondaryText) }
                    }.fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading).accessibilityElement(children: .combine)
                }
            }
        }
        .navigationTitle("").watchVitalsInset()
    }
    private func result(_ set: WatchWorkoutSet) -> String {
        var display = set
        if isTemplate { display.reps = set.maxTargetReps ?? set.minTargetReps ?? set.reps }
        let type = isTemplate ? exercise.effectiveTrackingType : exercise.effectiveTrackingType(for: set)
        return display.displayText(weightUnit: unit, trackingType: type)
    }
}

struct WatchSettingsView: View {
    @EnvironmentObject private var store: WorkoutSessionManagerStore
    @ObservedObject private var phone = PhoneConnectionManager.shared
    @State private var defaultRest = WatchPreferences.defaultRestDuration
    @State private var savedCurrent = false
    @AppStorage("workoutHaptics") private var workoutHaptics = true
    @AppStorage("logRPE") private var logRPE = true
    var body: some View {
        List {
            Section("Connection") {
                WatchSettingsLabel(title: phone.isReachable ? "iPhone Connected" : "Not Connected", symbol: "iphone",
                    color: phone.isReachable ? IronTheme.success : IronTheme.warning, value: syncCaption, metricValue: false)
                Button { phone.requestLibrary(); phone.requestCurrentSnapshot(); phone.flushEventOutbox() } label: {
                    WatchActionLabel(title: "Sync Now", symbol: "arrow.triangle.2.circlepath")
                }.watchGlassButton()
            }
            Section("Workout") {
                Picker("Weight Unit", selection: Binding(get: { store.preferredWeightUnit }, set: { store.setPreferredWeightUnit($0) })) {
                    Text("Pounds · lb").tag(WatchWorkoutWeightUnit.pound)
                    Text("Kilograms · kg").tag(WatchWorkoutWeightUnit.kilogram)
                }
                NavigationLink {
                    WatchRestTimerPicker(context: "Default Rest", initialValue: defaultRest) {
                        defaultRest = $0; WatchPreferences.defaultRestDuration = $0
                    }
                } label: {
                    WatchSettingsLabel(title: "Default Rest", symbol: "timer", color: IronTheme.metricTime,
                        value: WatchNumber.clock(defaultRest), valueColor: IronTheme.metricTime)
                }
                WatchSettingsLabel(title: "Log RPE", symbol: "chart.bar.fill", color: IronTheme.metricEffort,
                    value: logRPE ? "On · Set on iPhone" : "Off · Set on iPhone", metricValue: false)
            }
            Section {
                WatchSettingsLabel(title: "Health Recording", symbol: "heart.fill", color: IronTheme.metricHeartRate,
                    value: "Heart rate and calories record during every workout", metricValue: false)
                WatchRecordingFailureRow()
            }
            Section {
                Toggle("Haptics", isOn: $workoutHaptics)
                    .onChange(of: workoutHaptics) {
                        NotificationManager.shared.syncRestNotification(store.workoutSnapshot, force: true)
                    }
                WatchSettingsLabel(title: "Sound Effects", symbol: "speaker.wave.2.fill", color: IronTheme.secondaryText,
                    value: "Controlled by Watch Silent Mode", metricValue: false)
            } header: { Text("Feedback") } footer: {
                Text("System taps and tones follow your Watch settings. Use Silent Mode in Control Center to mute tones. Feedback preferences apply to this Watch.")
            }
            if let snapshot = store.workoutSnapshot, !snapshot.isFinishedRecord {
                Section { sessionSettings }
            }
            Section { Text(version).font(.footnote).foregroundStyle(IronTheme.secondaryText) }
        }
        .navigationTitle("Settings").watchVitalsInset()
    }
    private var sessionSettings: some View {
        VStack(alignment: .leading, spacing: 4) {
            WatchSectionTitle(title: "Current Workout")
            TextField("Workout Name", text: Binding(get: { store.workoutSnapshot?.title ?? "" }, set: { name in
                store.updateCurrent { $0.title = name.isEmpty ? nil : name }
            })).watchPlatter()
            TextField("Workout Notes", text: Binding(get: { store.workoutSnapshot?.comment ?? "" }, set: { note in
                store.updateCurrent { $0.comment = note.isEmpty ? nil : note }
            }), axis: .vertical).watchPlatter()
            if let manager = store.workoutSessionManager, manager.state == .running || manager.state == .paused {
                Button { store.toggleWorkoutPause() } label: {
                    WatchActionLabel(title: manager.state == .paused ? "Resume Workout" : "Pause Workout",
                        symbol: manager.state == .paused ? "play.fill" : "pause.fill")
                }.watchGlassButton()
            }
            Button { store.saveCurrentAsWorkout { savedCurrent = $0 } } label: {
                WatchActionLabel(title: savedCurrent ? "Workout Saved" : "Save as Workout", symbol: savedCurrent ? "checkmark" : "bookmark")
            }.watchGlassButton().disabled(savedCurrent)
        }
    }
    private var syncCaption: String {
        let count = WatchWorkoutStore.shared.pendingEvents().count
        if count > 0 { return "\(count) edits queued" }
        guard store.library.generatedAt.timeIntervalSince1970 > 0 else { return "Sync with iPhone" }
        let formatter = RelativeDateTimeFormatter(); formatter.unitsStyle = .short
        return "Synced " + formatter.localizedString(for: store.library.generatedAt, relativeTo: Date())
    }
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "Light \(info["CFBundleShortVersionString"] as? String ?? "1.0") (\(info["CFBundleVersion"] as? String ?? ""))"
    }
}

// Keep the existing entry points for callers outside this lane.
struct WatchSyncView: View { var body: some View { WatchSettingsView() } }
struct WatchUnitsView: View { var body: some View { WatchSettingsView() } }

#if DEBUG
struct ContentView_Previews: PreviewProvider { static var previews: some View { ContentView() } }
#endif
