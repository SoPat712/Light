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
            #if DEBUG
            Section {
                Toggle(isOn: $settingsStore.healthTestMode) {
                    SettingsSubpageLabel("Don't record to Apple Health", systemImage: "heart.slash.fill",
                                         tint: IronTheme.metricHeartRate)
                }
                .toggleStyle(.switch)
                .tint(IronTheme.accent)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Don't record to Apple Health")
                .accessibilityValue(settingsStore.healthTestMode ? "On" : "Off")
            } header: {
                Text("Testing")
            } footer: {
                Text("Test workouts don't record heart rate or calories and aren't saved to Apple Health, so your rings don't move. Debug builds only.")
            }
            #endif

            Section("Connection") {
                accessStatusRow

                LabeledContent("Write access", value: accessState.permissionStatus)
                LabeledContent("Data types", value: "Workouts + body")
                LabeledContent("Managed in", value: "Apple Health")

                if accessState == .notDetermined {
                    Button(action: requestAccess) {
                        HStack(spacing: 12) {
                            SettingsSubpageLabel(authorizing ? "Requesting access…" : accessState.actionTitle,
                                                 systemImage: "heart.text.square.fill", tint: IronTheme.diagramCanvas,
                                                 glyph: IronTheme.metricEffort)
                            if authorizing { ProgressView() }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(authorizing)
                }

                if accessState == .needsReview || accessState == .ready {
                    Button(action: openHealthApp) {
                        SettingsSubpageLabel("Review access in Health", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Workout History") {
                workoutSyncSummaryRow

                Button(action: updateWorkouts) {
                    HStack(spacing: 12) {
                        SettingsSubpageLabel(updating ? "Syncing workout history…" : "Sync workout history",
                                             systemImage: "arrow.triangle.2.circlepath")
                        if updating { ProgressView() }
                    }
                }
                .buttonStyle(.plain)
                .disabled(updating || accessState != .ready)
            }

            Section("Data Exchanged") {
                healthDataRow(
                    icon: "figure.strengthtraining.traditional",
                    title: "Strength workouts",
                    detail: "Completed Light workouts write their start time, duration, and title to Apple Health. Imported workouts are never exported.",
                    tint: IronTheme.accent
                )
                healthDataRow(
                    icon: "scalemass.fill",
                    title: "Body measurements",
                    detail: "Read and write weight, height, body fat, and waist circumference.",
                    tint: IronTheme.metricBody
                )
                healthDataRow(
                    icon: "applewatch.radiowaves.left.and.right",
                    title: "Watch workout metrics",
                    detail: "Heart rate and active energy stay in Apple Health during a Watch workout.",
                    tint: IronTheme.metricHeartRate
                )
            }

            Section {
                privacyRow
            }
        }
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
                    message: "Open the Health app manually, tap your profile, then review Apps and Services → Iron.",
                    systemImage: "arrow.up.forward.app.fill",
                    tint: IronTheme.warning
                )
            }
        }
    }

    private var accessStatusRow: some View {
        HStack(spacing: 12) {
            SettingsSubpageIconTile(systemImage: accessState.systemImage, tint: IronTheme.diagramCanvas, glyph: accessState.tint)
            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        accessTitle.fixedSize()
                        accessBadge.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        accessTitle
                        accessBadge
                    }
                }
                Text(accessState.detail)
                    .font(.subheadline)
                    .foregroundColor(IronTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var accessTitle: some View {
        Text(accessState.title)
            .font(.headline)
            .foregroundColor(IronTheme.primaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var accessBadge: some View {
        Text(accessState.badge)
            .font(.subheadline.weight(.semibold))
            .foregroundColor(accessState.tint)
    }

    private var workoutSyncSummaryRow: some View {
        SettingsSubpageLabel(
            "Repair or backfill workout history",
            detail: "Sync completed Light sessions with Apple Health. Existing matches are updated without duplicates; imported workouts are never exported.",
            systemImage: "arrow.triangle.2.circlepath.icloud"
        )
    }

    private func healthDataRow(icon: String, title: String, detail: String, tint: Color) -> some View {
        SettingsSubpageLabel(title, detail: detail, systemImage: icon, tint: tint)
    }

    private var privacyRow: some View {
        SettingsSubpageLabel(
            "You stay in control",
            detail: "Change permissions anytime in Apple Health. Light never shares health data socially or with other Light users.",
            systemImage: "hand.raised.fill"
        )
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
                activeModal = HealthModal(kind: .workoutSync(result))
                updating = false
            }
        }
    }
}

private extension HealthManager.AccessState {
    var title: String {
        switch self {
        case .unavailable: return "Apple Health unavailable"
        case .notDetermined: return "Connect Apple Health"
        case .needsReview: return "Review Health access"
        case .ready: return "Apple Health connected"
        }
    }

    var detail: String {
        switch self {
        case .unavailable:
            return "Apple Health is not available on this device. Light will continue storing everything locally."
        case .notDetermined:
            return "Choose the workout and body-measurement categories Light may exchange. Nothing leaves your device without permission."
        case .needsReview:
            return "One or more write categories are unavailable. Review access to keep workouts and supported measurements aligned."
        case .ready:
            return "Workout and supported body-measurement write access is ready; setup also requested read access, whose decisions Apple keeps private. Control each category in Health."
        }
    }

    var permissionStatus: String {
        switch self {
        case .unavailable: return "Unavailable"
        case .notDetermined: return "Not set"
        case .needsReview: return "Review"
        case .ready: return "Write ready"
        }
    }

    var badge: String {
        switch self {
        case .unavailable: return "UNAVAILABLE"
        case .notDetermined: return "NOT CONNECTED"
        case .needsReview: return "REVIEW"
        case .ready: return "CONNECTED"
        }
    }

    var systemImage: String {
        switch self {
        case .unavailable: return "heart.slash.fill"
        case .notDetermined: return "heart.text.square.fill"
        case .needsReview: return "exclamationmark.triangle.fill"
        case .ready: return "heart.fill"
        }
    }

    var tint: Color {
        switch self {
        case .unavailable: return IronTheme.secondaryText
        case .notDetermined: return IronTheme.danger
        case .needsReview: return IronTheme.warning
        case .ready: return IronTheme.success
        }
    }

    var actionTitle: String {
        switch self {
        case .unavailable: return "Apple Health unavailable"
        case .notDetermined: return "Connect Apple Health"
        case .needsReview: return "Request access again"
        case .ready: return "Review requested categories"
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
