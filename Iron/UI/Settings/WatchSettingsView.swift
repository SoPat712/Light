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
    /// Values shown while a refresh runs. WatchConnectivity reports in several quick steps
    /// (reachability especially flaps), so the page holds still and shows only the result.
    @State private var frozenStatus: WatchStatus?
    @State private var refreshToken = 0

    @ObservedObject private var connection = WatchConnectionManager.shared

    private struct WatchStatus: Equatable {
        let isPaired: Bool
        let isInstalled: Bool
        let isReachable: Bool
    }

    private var liveStatus: WatchStatus {
        WatchStatus(isPaired: connection.isPaired, isInstalled: connection.isWatchAppInstalled,
                    isReachable: connection.isReachable)
    }

    private var shownStatus: WatchStatus { frozenStatus ?? liveStatus }

    private enum ConnectionState {
        case unavailable
        case installRequired
        case ready

        var needsSetup: Bool { self != .ready }
    }

    /// Paired and installed decide readiness. Reachability only says whether the watch app
    /// is awake right now, so it stays in the Connection row instead of flipping the badge.
    private var connectionState: ConnectionState {
        guard shownStatus.isPaired else { return .unavailable }
        guard shownStatus.isInstalled else { return .installRequired }
        return .ready
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
            Section {
                SettingsConnectionHeader(title: "Apple Watch", systemImage: "applewatch", tint: IronTheme.mediaBackdrop,
                                         status: statusTitle, isGood: !connectionState.needsSetup) {
                    if connectionState.needsSetup {
                        Button(action: openWatchSetup) {
                            Label(shownStatus.isPaired ? "Install Light on Watch" : "Pair in Watch App",
                                  systemImage: "arrow.up.forward.app")
                                .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint("Opens the Watch app on this iPhone")
                    }
                }
            } footer: {
                Text(connectionState.needsSetup
                     ? "Pair your watch and install Light using the Watch app on iPhone."
                     : "Light on your watch is ready for workouts.")
            }

            Section {
                LabeledContent {
                    Text(shownStatus.isPaired ? "Yes" : "No")
                } label: {
                    SettingsRowLabel("Paired", systemImage: "applewatch.radiowaves.left.and.right", tint: IronTheme.accent)
                }
                LabeledContent {
                    Text(shownStatus.isInstalled ? "Yes" : "No")
                } label: {
                    SettingsRowLabel("Light Installed", systemImage: "app.badge.checkmark", tint: IronTheme.metricVolume)
                }
                LabeledContent {
                    Text(shownStatus.isReachable ? "Live" : "Standby")
                        .foregroundStyle(shownStatus.isReachable ? IronTheme.success : IronTheme.secondaryText)
                } label: {
                    SettingsRowLabel("Connection", systemImage: "dot.radiowaves.left.and.right", tint: IronTheme.metricTime)
                }
                Button { refreshConnectionStatus(announce: true) } label: {
                    SettingsActionLabel("Refresh Status", systemImage: "arrow.clockwise", tint: IronTheme.accent,
                                        trailingSymbol: "arrow.clockwise.circle", isPreparing: isRefreshing)
                }
                .accessibilityLabel(isRefreshing ? "Checking watch status" : "Refresh Status")
                .disabled(isRefreshing)
            } header: {
                Text("Details")
            }

            Section {
                SettingsToggle("Start with iPhone Workouts", systemImage: "figure.strengthtraining.traditional",
                               tint: IronTheme.accent, isOn: watchCompanionBinding)
                    .toggleStyle(.switch)
                    .tint(IronTheme.accent)
                    .disabled(!isCompanionAvailable)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Start with iPhone Workouts")
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
        }
        .labeledContentStyle(SettingsValueStyle())
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: IronTheme.floatingWorkoutBottomClearance - 36)
        }
        .navigationTitle("Apple Watch")
        .navigationBarTitleDisplayMode(.inline)
        .ironScreen()
        .onAppear { refreshConnectionStatus(announce: false) }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            refreshConnectionStatus(announce: false)
        }
        .onChange(of: connection.connectionRevision) { _, _ in
            // Each report restarts a short settle window; the page updates once it's quiet.
            guard isRefreshing else { return }
            scheduleFinish(after: 1.0)
        }
        .alert("Could not open the Watch app", isPresented: $watchAppUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Open the Watch app from your iPhone Home Screen to pair your watch or install Light.")
        }
    }

    private var statusTitle: String {
        switch connectionState {
        case .unavailable: return "Not Paired"
        case .installRequired: return "Light Not Installed"
        case .ready: return "Ready"
        }
    }

    private var companionDetail: String {
        #if DEBUG
        if settingsStore.healthTestMode {
            return "In test mode, Watch workouts skip heart rate, calories, and Apple Health."
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

    @State private var announcesRefresh = false

    private func refreshConnectionStatus(announce: Bool) {
        guard !isRefreshing else { return }
        frozenStatus = liveStatus
        announcesRefresh = announce
        isRefreshing = true
        connection.refreshConnectionStatus()
        scheduleFinish(after: 1.0)
        // An escape hatch for a broken or suspended WatchConnectivity service, so the
        // row can never stay busy forever.
        let token = refreshToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            guard isRefreshing, refreshToken == token else { return }
            finishRefresh()
        }
    }

    private func scheduleFinish(after delay: TimeInterval) {
        refreshToken += 1
        let token = refreshToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard isRefreshing, refreshToken == token else { return }
            finishRefresh()
        }
    }

    private func finishRefresh() {
        withAnimation(IronMotion.preferred(IronMotion.fade, reduceMotion: UIAccessibility.isReduceMotionEnabled)) {
            frozenStatus = nil
            isRefreshing = false
        }
        guard announcesRefresh else { return }
        let status = liveStatus
        let toast: LightToast
        if !status.isPaired {
            toast = LightToast(title: "Watch Not Paired", subtitle: "Pair it in the Watch app",
                               systemImage: "applewatch.slash", style: .warning)
        } else if !status.isInstalled {
            toast = LightToast(title: "Light Not on Watch", subtitle: "Install it from the Watch app",
                               systemImage: "exclamationmark.applewatch", style: .warning)
        } else {
            toast = LightToast(title: "Apple Watch Ready",
                               subtitle: status.isReachable ? "Connection: Live" : "Connection: Standby",
                               systemImage: "checkmark.applewatch", style: .success)
        }
        LightToastCenter.shared.show(toast)
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
