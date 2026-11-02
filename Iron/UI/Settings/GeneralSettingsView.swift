//
//  GeneralSettingsView.swift
//  Iron
//
//  Created by Karim Abou Zeid on 31.10.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import SwiftUI

struct GeneralSettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject var settingsStore: SettingsStore
    @State private var expandedRest: RestPreference?

    private enum RestPreference {
        case standard, dumbbell, barbell
    }

    var body: some View {
        Form {
            restSection
            loggingSection
            calculatorsSection
            duringWorkoutSection
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: IronTheme.floatingWorkoutBottomClearance - 36)
        }
        .navigationTitle("Workout Preferences")
        .navigationBarTitleDisplayMode(.inline)
        .ironScreen()
    }

    private var restSection: some View {
        Section {
            Toggle(isOn: $settingsStore.autoStartRestTimer) {
                SettingsSubpageLabel("Start Timer After Each Set", systemImage: "timer", tint: IronTheme.metricTime)
            }
            restRow("Default", preference: .standard, selection: $settingsStore.defaultRestTime)
            restRow("Dumbbell Exercises", preference: .dumbbell, selection: $settingsStore.defaultRestTimeDumbbellBased)
            restRow("Barbell Exercises", preference: .barbell, selection: $settingsStore.defaultRestTimeBarbellBased)
            Toggle(isOn: Binding(
                get: { settingsStore.keepRestTimerRunning },
                set: { newValue in
                    settingsStore.keepRestTimerRunning = newValue
                    RestTimerStore.shared.notifyKeepRestTimerRunningChanged()
                }
            )) {
                SettingsSubpageLabel("Count Past Zero", systemImage: "clock.arrow.circlepath", tint: IronTheme.metricTime)
            }
        } header: {
            Text("Rest Timer")
        } footer: {
            Text("Matching equipment uses its own rest length; other exercises use Default. Count Past Zero shows overtime in red.")
        }
    }

    private var loggingSection: some View {
        Section {
            Toggle(isOn: $settingsStore.logRPE) {
                SettingsSubpageLabel("Log RPE", systemImage: "gauge.with.dots.needle.50percent", tint: IronTheme.metricEffort)
            }
            Toggle(isOn: $settingsStore.prefillPreviousValues) {
                SettingsSubpageLabel("Carry Over Last Values", systemImage: "arrow.clockwise", tint: IronTheme.accent)
            }
            Toggle(isOn: $settingsStore.inlineSetTimer) {
                SettingsSubpageLabel("Stopwatch for Timed Sets", systemImage: "stopwatch", tint: IronTheme.metricTime)
            }
        } header: {
            Text("Logging")
        } footer: {
            Text("RPE (rated perceived exertion) adds a column to each set; Carry Over fills new sets with your previous session’s weight and reps. Timed sets use a tap-to-run stopwatch in place of the duration picker.")
        }
    }

    private var calculatorsSection: some View {
        Section {
            Toggle(isOn: $settingsStore.showPlateCalculator) {
                SettingsSubpageLabel("Plate Calculator", systemImage: "plusminus", tint: IronTheme.metricVolume)
            }
            NavigationLink {
                AvailablePlatesSettingsView(unit: settingsStore.weightUnit)
            } label: {
                SettingsSubpageLabel("Available Plates", systemImage: "circle.grid.2x2.fill", tint: IronTheme.metricVolume)
            }
            Toggle(isOn: $settingsStore.showWarmUpCalculator) {
                SettingsSubpageLabel("Warm-up Calculator", systemImage: "flame.fill", tint: IronTheme.metricSets)
            }
        } header: {
            Text("Calculators")
        } footer: {
            Text("Calculate plates for bars, machines or plates-only exercises, and build warm-up sets below your working weight.")
        }
    }

    private var duringWorkoutSection: some View {
        Section {
            Toggle(isOn: $settingsStore.supersetAutoScroll) {
                SettingsSubpageLabel("Advance Through Supersets", systemImage: "link", tint: IronTheme.accent)
            }
            Toggle(isOn: $settingsStore.keepScreenAwakeDuringWorkout) {
                SettingsSubpageLabel("Keep Screen Awake", systemImage: "sun.max.fill", tint: IronTheme.metricRecord)
            }
        } header: {
            Text("During a Workout")
        } footer: {
            Text("Advance to the next superset exercise after each completed set. Keeping iPhone awake during workouts prevents locking and uses more battery.")
        }
    }

    @ViewBuilder
    private func restRow(_ title: String, preference: RestPreference, selection: Binding<TimeInterval>) -> some View {
        Button {
            withAnimation(IronMotion.preferred(IronMotion.collapse, reduceMotion: reduceMotion)) {
                expandedRest = expandedRest == preference ? nil : preference
            }
        } label: {
            HStack(spacing: 12) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        restLabel(title, preference: preference)
                        restValue(selection.wrappedValue)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    restLabel(title, preference: preference)
                    restValue(selection.wrappedValue)
                }
                Image(systemName: expandedRest == preference ? "chevron.up" : "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(IronTheme.secondaryText)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(restTitle(selection.wrappedValue))
        .accessibilityHint(expandedRest == preference ? "Collapse rest length control" : "Expand rest length control")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: selection.wrappedValue = min(600, selection.wrappedValue + 15)
            case .decrement: selection.wrappedValue = max(30, selection.wrappedValue - 15)
            default: break
            }
        }

        if expandedRest == preference {
            // Match the previous picker's full range and persist only committed choices.
            RestLengthRuler(
                value: Binding(get: { selection.wrappedValue }, set: { _ in }),
                range: 30...600,
                step: 15
            ) { selection.wrappedValue = $0 }
            .accessibilityLabel("\(title) rest length")
            .transition(.opacity)
        }
    }

    private func restLabel(_ title: String, preference: RestPreference) -> some View {
        SettingsSubpageLabel(
            title,
            systemImage: preference == .standard ? "timer" : "dumbbell.fill",
            tint: IronTheme.metricTime
        )
    }

    private func restValue(_ duration: TimeInterval) -> some View {
        Text(restTitle(duration))
            .font(.ironMetric(.title3))
            .foregroundStyle(IronTheme.metricTime)
            .fixedSize()
    }

    private func restTitle(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

struct AvailablePlatesSettingsView: View {
    let unit: WeightUnit
    @State private var inventory = PlateInventory.load()

    var body: some View {
        Form {
            Section {
                PlateInventoryRows(unit: unit, inventory: $inventory)
            } header: {
                Text("Available Plates · \(unit.unit.symbol)")
            } footer: {
                Text("Enable the plates at your gym. The calculator uses this inventory for every exercise on this device. Plate counts are unlimited.")
                if inventory.enabledPlates(for: unit.plateLoadUnit).isEmpty {
                    Text("No plates enabled. Only the bar or machine starting weight can be loaded.")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: IronTheme.floatingWorkoutBottomClearance - 36)
        }
        .navigationTitle("Available Plates")
        .navigationBarTitleDisplayMode(.inline)
        .ironScreen()
        .onAppear { inventory = .load() }
        .onChange(of: inventory) { inventory.save() }
    }
}

/// Units affect history, charts, and exports, so they belong beside the other
/// app-wide preferences rather than inside the workout options.
struct UnitsSettingsView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @State private var selectionFeedback = 0

    var body: some View {
        Form {
            Section {
                Picker("Weight", selection: Binding(
                    get: { settingsStore.weightUnit },
                    set: {
                        guard settingsStore.weightUnit != $0 else { return }
                        settingsStore.weightUnit = $0
                        selectionFeedback += 1
                    }
                )) {
                    ForEach(WeightUnit.allCases, id: \.self) { unit in
                        SettingsSubpageLabel(unit.title, systemImage: "scalemass.fill", tint: IronTheme.metricSets)
                            .tag(unit)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Weight")
            } footer: {
                Text(settingsStore.weightUnit == .metric
                     ? "Kilograms, with metric barbell plates and 2.5 kg increments."
                     : "Pounds, with imperial barbell plates and 5 lb increments.")
            }

            Section {
                Picker(selection: Binding(
                    get: { settingsStore.maxRepetitionsOneRepMax },
                    set: {
                        guard settingsStore.maxRepetitionsOneRepMax != $0 else { return }
                        settingsStore.maxRepetitionsOneRepMax = $0
                        selectionFeedback += 1
                    }
                )) {
                    ForEach(Array(maxRepetitionsOneRepMaxValues), id: \.self) { value in
                        Text("^[\(value) rep](inflect: true)")
                            .font(.ironMetric(.body, weight: .semibold))
                            .tag(value)
                    }
                } label: {
                    SettingsSubpageLabel("Max Repetitions", systemImage: "chart.xyaxis.line", tint: IronTheme.accent)
                }
            } header: {
                Text("One Rep Max")
            } footer: {
                Text("Sets above this rep count are ignored when estimating your one rep max. Higher limits are less accurate.")
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: IronTheme.floatingWorkoutBottomClearance - 36)
        }
        .navigationTitle("Units")
        .sensoryFeedback(.selection, trigger: selectionFeedback) { _, _ in settingsStore.workoutHaptics }
        .navigationBarTitleDisplayMode(.inline)
        .ironScreen()
    }
}

struct SoundsSettingsView: View {
    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settingsStore.workoutSounds) {
                    SettingsSubpageLabel("Sound Effects", systemImage: "speaker.wave.2.fill", tint: IronTheme.metricEffort)
                }
                Toggle(isOn: $settingsStore.workoutHaptics) {
                    SettingsSubpageLabel("Haptics", systemImage: "hand.tap.fill", tint: IronTheme.metricEffort)
                }
            } header: {
                Text("Feedback")
            } footer: {
                Text("Feedback for sets, controls, and rest timers. Sound effects follow your ringer switch and mix with your music.")
            }

            Section {
                Toggle(isOn: $settingsStore.personalRecordAlerts) {
                    SettingsSubpageLabel("Personal Record Alerts", systemImage: "trophy.fill", tint: IronTheme.metricRecord)
                }
            } footer: {
                Text("Announce a record in the log as soon as a completed set beats your best for that exercise.")
            }

            Section {
                ForEach(IronSoundPlayer.Sound.allCases) { sound in
                    Button {
                        IronSoundPlayer.shared.play(sound, preview: true)
                    } label: {
                        HStack(spacing: 12) {
                            SettingsSubpageLabel(sound.title, systemImage: "speaker.wave.2.fill", tint: IronTheme.metricEffort)
                            Image(systemName: "play.circle.fill")
                                .font(.title3)
                                .foregroundStyle(IronTheme.accent)
                                .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play \(sound.title) sound")
                    .disabled(!settingsStore.workoutSounds)
                }
            } header: {
                Text("Preview")
            } footer: {
                Text("Turn on Sound Effects and your ringer to preview.")
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: IronTheme.floatingWorkoutBottomClearance - 36)
        }
        .navigationTitle("Sounds & Haptics")
        .navigationBarTitleDisplayMode(.inline)
        .ironScreen()
    }
}

/// Shared by Settings subpages; the approved root keeps its private tile implementation.
struct SettingsSubpageIconTile: View {
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 30
    let systemImage: String
    var tint: Color = IronTheme.accent
    var glyph: Color = IronTheme.onAccent

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(tint)
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(IronTheme.outline, lineWidth: 1)
            }
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(glyph)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct SettingsSubpageLabel: View {
    let title: String
    var detail: String?
    let systemImage: String
    var tint: Color = IronTheme.accent
    var glyph: Color = IronTheme.onAccent

    init(_ title: String, detail: String? = nil, systemImage: String, tint: Color = IronTheme.accent, glyph: Color = IronTheme.onAccent) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.tint = tint
        self.glyph = glyph
    }

    var body: some View {
        HStack(spacing: 12) {
            SettingsSubpageIconTile(systemImage: systemImage, tint: tint, glyph: glyph)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(IronTheme.primaryText)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(IronTheme.secondaryText)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight, alignment: .leading)
        .contentShape(Rectangle())
    }
}

#if DEBUG
struct GeneralSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            GeneralSettingsView()
                .mockEnvironment(weightUnit: .metric)
        }
    }
}
#endif
