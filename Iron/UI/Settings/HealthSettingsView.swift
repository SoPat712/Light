//
//  HealthSettingsView.swift
//  Iron
//
//  Created by Karim Abou Zeid on 31.10.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import SwiftUI
import UIKit
import WorkoutDataKit

struct HealthSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var exerciseStore: ExerciseStore
    #if DEBUG
    @EnvironmentObject var settingsStore: SettingsStore
    #endif
    @Environment(\.managedObjectContext) var managedObjectContext

    @State private var updating = false
    @State private var authorizing = false
    @State private var accessState = HealthManager.AccessState.notDetermined
    @State private var activeModal: HealthModal?

    private struct HealthModal: Identifiable {
        enum Kind {
            case access(Result<Void, Error>)
            case workoutSync(Result<HealthManager.WorkoutUpdates, Error>)
            case healthAppUnavailable
        }

        let id = UUID()
        let kind: Kind
    }

    private enum HealthAccessSetupError: LocalizedError {
        case needsReview

        var errorDescription: String? {
            "Some Health categories remain off. Review Light's access in Apple Health to enable the categories you want to use."
        }
    }

    @ViewBuilder
    private func workoutSyncResultSheet(_ updateResult: Result<HealthManager.WorkoutUpdates, Error>) -> some View {
        switch updateResult {
        case .success(let updates):
            IronStatusSheet(
                headerTitle: "Apple Health",
                title: "Workout sync complete",
                message: "\(updates.created) created · \(updates.modified) updated · \(updates.deleted) removed",
                systemImage: "heart.circle.fill",
                tint: IronTheme.success
            )
        case .failure(let error):
            IronStatusSheet(
                headerTitle: "Apple Health",
                title: "Could not update workouts",
                message: error.localizedDescription,
                systemImage: "heart.slash.fill",
                tint: IronTheme.danger
            )
        }
    }

    @ViewBuilder
    private func accessResultSheet(_ result: Result<Void, Error>) -> some View {
        switch result {
        case .success:
            IronStatusSheet(
                headerTitle: "Apple Health",
                title: "Health access requested",
                message: "Light can now sync strength workouts and exchange supported body measurements. You can adjust individual categories in the Health app.",
                systemImage: "heart.circle.fill",
                tint: IronTheme.success
            )
        case .failure(let error):
            IronStatusSheet(
                headerTitle: "Apple Health",
                title: error is HealthAccessSetupError ? "Health access needs review" : "Could not connect",
                message: error.localizedDescription,
                systemImage: "heart.slash.fill",
                tint: error is HealthAccessSetupError ? IronTheme.warning : IronTheme.danger
            )
        }
    }

    var body: some View {
        List {
            Section {
                SettingsConnectionHeader(title: "Apple Health", systemImage: "heart.fill", tint: IronTheme.metricEffort,
                                         status: accessState == .ready ? "Connected" : "Not Connected",
                                         isGood: accessState == .ready) {
                    if accessState == .notDetermined {
                        Button(action: requestAccess) {
                            HStack(spacing: 8) {
                                if authorizing { ProgressView().controlSize(.small).tint(IronTheme.onAccent) }
                                Text(authorizing ? "Connecting…" : "Connect Apple Health")
                            }
                            .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel(authorizing ? "Requesting Apple Health access" : "Connect Apple Health")
                        .disabled(authorizing)
                    } else {
                        Button(action: openHealthApp) {
                            Label("Manage in Health", systemImage: "arrow.up.forward.app")
                                .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight)
                        }
                        .buttonStyle(.bordered)
                        .disabled(accessState == .unavailable)
                    }
                }
            } footer: {
                Text("You control access in Apple Health, and Light never shares your health data socially.")
            }

            Section {
                LabeledContent {
                    Text(accessState.permissionStatus)
                } label: {
                    SettingsRowLabel("Write Access", systemImage: "square.and.pencil", tint: IronTheme.accent)
                }
                LabeledContent {
                    Text("Workouts & Body")
                } label: {
                    SettingsRowLabel("Data Types", systemImage: "list.bullet", tint: IronTheme.metricBody)
                }
                Button(action: updateWorkouts) {
                    SettingsActionLabel("Sync Past Workouts", systemImage: "arrow.triangle.2.circlepath",
                                        tint: IronTheme.metricVolume, trailingSymbol: "arrow.clockwise",
                                        isPreparing: updating)
                }
                .accessibilityLabel(updating ? "Syncing workout history" : "Sync Past Workouts")
                .disabled(updating || accessState != .ready)
            } header: {
                Text("Details")
            } footer: {
                Text("Sync Past Workouts adds completed Light workouts without duplicates; imported workouts are never sent to Apple Health.")
            }

            #if DEBUG
            Section {
                SettingsToggle("Don't Record to Apple Health", systemImage: "testtube.2", tint: IronTheme.secondaryText,
                               isOn: $settingsStore.healthTestMode)
                    .toggleStyle(.switch)
                    .tint(IronTheme.accent)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Don't Record to Apple Health")
                    .accessibilityValue(settingsStore.healthTestMode ? "On" : "Off")
            } header: {
                Text("Testing")
            } footer: {
                Text("Test workouts skip heart rate, calories, and Apple Health, so your rings don’t move.")
            }
            #endif
        }
        .labeledContentStyle(SettingsValueStyle())
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: IronTheme.floatingWorkoutBottomClearance - 36)
        }
        .navigationTitle("Apple Health")
        .navigationBarTitleDisplayMode(.inline)
        .ironScreen()
        .onAppear(perform: refreshAccessState)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            refreshAccessState()
        }
        .sheet(item: $activeModal) { modal in
            switch modal.kind {
            case .access(let result):
                accessResultSheet(result)
            case .workoutSync(let result):
                workoutSyncResultSheet(result)
            case .healthAppUnavailable:
                IronStatusSheet(
                    headerTitle: "Apple Health",
                    title: "Could not open Health",
                    message: "Open the Health app manually, tap your profile, then review Apps and Services → Light.",
                    systemImage: "arrow.up.forward.app.fill",
                    tint: IronTheme.warning
                )
            }
        }
    }

    private func openHealthApp() {
        guard let healthURL = URL(string: "x-apple-health://") else { return }
        UIApplication.shared.open(healthURL, options: [:]) { opened in
            guard !opened else { return }
            DispatchQueue.main.async {
                activeModal = HealthModal(kind: .healthAppUnavailable)
            }
        }
    }

    private func refreshAccessState() {
        accessState = HealthManager.shared.accessState
    }

    private func requestAccess() {
        guard !authorizing else { return }
        authorizing = true
        HealthManager.shared.requestWorkoutAndBodyMeasurementPermission { result in
            DispatchQueue.main.async {
                authorizing = false
                refreshAccessState()
                let verifiedResult: Result<Void, Error>
                switch result {
                case .failure:
                    verifiedResult = result
                case .success where accessState == .ready:
                    verifiedResult = .success(())
                case .success:
                    verifiedResult = .failure(HealthAccessSetupError.needsReview)
                }
                activeModal = HealthModal(kind: .access(verifiedResult))
            }
        }
    }

    private func updateWorkouts() {
        updating = true
        HealthManager.shared.updateHealthWorkouts(managedObjectContext: managedObjectContext, exerciseStore: exerciseStore) { result in
            DispatchQueue.main.async {
                refreshAccessState()
                if case .success(let updates) = result {
                    // A finished sync needs no decision: confirm it in the drop-down.
                    LightToastCenter.shared.show(LightToast(
                        title: "Workouts Synced",
                        subtitle: "\(updates.created) added · \(updates.modified) updated · \(updates.deleted) removed",
                        systemImage: "heart.circle.fill"))
                } else {
                    activeModal = HealthModal(kind: .workoutSync(result))
                }
                updating = false
            }
        }
    }
}

private extension HealthManager.AccessState {
    var permissionStatus: String {
        switch self {
        case .unavailable: return "Unavailable"
        case .notDetermined: return "Not Set"
        case .needsReview: return "Needs Review"
        case .ready: return "Ready"
        }
    }
}

import HealthKit
extension HealthSettingsView {
    static var isSupported: Bool {
        HKHealthStore.isHealthDataAvailable()
    }
}

struct HealthSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        HealthSettingsView()
    }
}
