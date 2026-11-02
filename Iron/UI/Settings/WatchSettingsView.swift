//
//  WatchSettingsView.swift
//  Iron
//
//  Created by Karim Abou Zeid on 12.11.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import SwiftUI
import UIKit
import WatchConnectivity

struct WatchSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var settingsStore: SettingsStore

    @State private var isRefreshing = false
    @State private var watchAppUnavailable = false

    @ObservedObject private var connection = WatchConnectionManager.shared

    private enum ConnectionState {
        case unavailable
        case installRequired
        case connected
        case ready

        var title: String {
            switch self {
            case .unavailable: return "Pair an Apple Watch"
            case .installRequired: return "Install Light on your watch"
            case .connected: return "Connected now"
            case .ready: return "Ready to sync"
            }
        }

        var detail: String {
            switch self {
            case .unavailable:
                return "Pair a watch in the Watch app on your iPhone to use the workout companion."
            case .installRequired:
                return "Open the Watch app on your iPhone and install Light from Available Apps."
            case .connected:
                return "Light can exchange workout changes with your watch right now."
            case .ready:
                return "Your current workout will sync whenever Light is available on both devices."
            }
        }

        var badge: String {
            switch self {
            case .unavailable, .installRequired: return "SETUP"
            case .connected: return "LIVE"
            case .ready: return "READY"
            }
        }

        var tint: Color {
            switch self {
            case .unavailable, .installRequired: return IronTheme.warning
            case .connected: return IronTheme.success
            case .ready: return IronTheme.accent
            }
        }

        var needsSetup: Bool {
            switch self {
            case .unavailable, .installRequired: return true
            case .connected, .ready: return false
            }
        }

        var setupActionTitle: String {
            switch self {
            case .unavailable: return "Pair in the Watch app"
            case .installRequired: return "Install Light on Apple Watch"
            case .connected, .ready: return "Open the Watch app"
            }
        }
    }

    private var connectionState: ConnectionState {
        guard connection.isPaired else { return .unavailable }
        guard connection.isWatchAppInstalled else { return .installRequired }
        return connection.isReachable ? .connected : .ready
    }

    private var isCompanionAvailable: Bool {
        !connectionState.needsSetup
    }

    private var displayedWatchCompanion: Bool {
        settingsStore.watchCompanion
    }

    private var watchCompanionBinding: Binding<Bool> {
        Binding(
            get: { displayedWatchCompanion },
            set: { settingsStore.watchCompanion = $0 }
        )
    }

    var body: some View {
        List {
            Section("Connection") {
                connectionStatusRow
                LabeledContent("Paired", value: connection.isPaired ? "Yes" : "No")
                LabeledContent("Light installed", value: connection.isWatchAppInstalled ? "Yes" : "No")
                LabeledContent("Connection", value: connection.isReachable ? "Live" : "Standby")

                Button(action: openWatchSetup) {
                    SettingsSubpageLabel(connectionState.setupActionTitle, systemImage: "applewatch", tint: IronTheme.mediaBackdrop)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the Watch app on this iPhone")

                Button(action: refreshConnectionStatus) {
                    HStack(spacing: 12) {
                        SettingsSubpageLabel(isRefreshing ? "Checking…" : "Refresh watch status", systemImage: "arrow.clockwise")
                        if isRefreshing { ProgressView() }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
            }

            Section {
                Toggle(isOn: watchCompanionBinding) {
                    SettingsSubpageLabel("Launch with workouts",
                                         detail: "Start the watch workout when logging begins on iPhone.",
                                         systemImage: "applewatch", tint: IronTheme.mediaBackdrop)
                }
                .toggleStyle(.switch)
                .tint(IronTheme.accent)
                .disabled(!isCompanionAvailable)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Launch watch companion with workouts")
                .accessibilityValue(
                    isCompanionAvailable
                        ? (displayedWatchCompanion ? "On" : "Off")
                        : (displayedWatchCompanion ? "On, setup required" : "Off, setup required")
                )
            } header: {
                Text("Workout Companion")
            } footer: {
                Text(companionDetail)
            }

            Section("On Your Wrist") {
                featureRow(
                    icon: "checkmark.circle.fill",
                    title: "Log complete sets",
                    detail: "Edit weight, reps and RPE, then mark sets complete.",
                    tint: IronTheme.accent
                )
                featureRow(
                    icon: "timer",
                    title: "Keep rest time visible",
                    detail: "Rest timers and the selected set stay aligned across devices.",
                    tint: IronTheme.metricTime
                )
                featureRow(
                    icon: "heart.fill",
                    title: "Capture workout metrics",
                    detail: "See live heart rate and estimated active calories.",
                    tint: IronTheme.metricHeartRate
                )
            }

            Section("Offline Continuity") {
                offlineContinuityRow
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: IronTheme.floatingWorkoutBottomClearance - 36)
        }
        .navigationTitle("Apple Watch")
        .navigationBarTitleDisplayMode(.inline)
        .ironScreen()
        .onAppear(perform: refreshConnectionStatus)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            refreshConnectionStatus()
        }
        .onChange(of: connection.connectionRevision) { _, _ in
            isRefreshing = false
        }
        .alert("Could not open the Watch app", isPresented: $watchAppUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Open the Watch app from your iPhone Home Screen to pair your watch or install Iron.")
        }
    }

    private var connectionStatusRow: some View {
        let state = connectionState

        return HStack(spacing: 12) {
            SettingsSubpageIconTile(systemImage: "applewatch.radiowaves.left.and.right", tint: IronTheme.mediaBackdrop)
            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        connectionTitle(state).fixedSize()
                        connectionBadge(state).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        connectionTitle(state)
                        connectionBadge(state)
                    }
                }
                Text(state.detail)
                    .font(.subheadline)
                    .foregroundColor(IronTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func connectionTitle(_ state: ConnectionState) -> some View {
        Text(state.title)
            .font(.headline)
            .foregroundStyle(IronTheme.primaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func connectionBadge(_ state: ConnectionState) -> some View {
        Text(state.badge)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(state.tint)
    }

    private var companionDetail: String {
        #if DEBUG
        if settingsStore.healthTestMode {
            return "Test mode is on. Watch workouts don't record heart rate or calories or save to Apple Health."
        }
        #endif
        if !isCompanionAvailable {
            return "Pair an Apple Watch and install Light before enabling the workout companion."
        }
        if displayedWatchCompanion {
            return "Heart rate and active energy are recorded by Apple Watch and remain available in Apple Health."
        }
        return "You can keep logging on iPhone, but Light will not automatically begin a watch workout."
    }

    private var offlineContinuityRow: some View {
        SettingsSubpageLabel(offlineContinuityTitle, detail: offlineContinuityDetail,
                             systemImage: "arrow.triangle.2.circlepath")
    }

    private var offlineContinuityTitle: String {
        guard isCompanionAvailable else { return "Available after Apple Watch setup" }
        guard displayedWatchCompanion else { return "Your active workout stays on iPhone" }
        return "Your active workout stays on the watch"
    }

    private var offlineContinuityDetail: String {
        guard isCompanionAvailable else {
            return "Pair an Apple Watch and install Light to keep an active workout locally on your wrist when the phone disconnects."
        }
        guard displayedWatchCompanion else {
            return "Turn on Launch with workouts to begin the companion automatically. Until then, your active workout continues locally on iPhone."
        }
        return "If the phone disconnects, Light stores the current workout and queues your edits locally. Changes reconcile automatically when the connection returns."
    }

    private func featureRow(icon: String, title: String, detail: String, tint: Color) -> some View {
        SettingsSubpageLabel(title, detail: detail, systemImage: icon, tint: tint)
    }

    private func refreshConnectionStatus() {
        guard !isRefreshing else { return }
        isRefreshing = true
        connection.refreshConnectionStatus()

        // Delegate callbacks normally end the refresh. Keep a conservative
        // escape hatch for a broken or suspended WatchConnectivity service so
        // the button can never remain disabled forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            guard isRefreshing else { return }
            isRefreshing = false
        }
    }

    private func openWatchSetup() {
        guard let watchURL = URL(string: "itms-watch://") else { return }
        UIApplication.shared.open(watchURL, options: [:]) { opened in
            guard !opened else { return }
            DispatchQueue.main.async {
                watchAppUnavailable = true
            }
        }
    }
}

extension WatchSettingsView {
    static var isSupported: Bool {
        WCSession.isSupported()
    }
}

struct WatchSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            WatchSettingsView()
                .environmentObject(SettingsStore.shared)
        }
    }
}
