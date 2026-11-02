//
//  SettingsView.swift
//  Iron
//
//  Created by Karim Abou Zeid on 11.07.19.
//  Rebuilt as Iron's private profile and device hub.
//

import SwiftUI
import MessageUI
import CoreData
import WorkoutDataKit

struct SettingsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.managedObjectContext) private var managedObjectContext
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var workoutCount: Int?
    @State private var firstWorkoutDate: Date?

    private struct ActionAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }
    @State private var actionAlert: ActionAlert?

    private enum FeedbackPresentation: String, Identifiable {
        case composer
        case options

        var id: String { rawValue }
    }
    @State private var feedbackPresentation: FeedbackPresentation?

    var body: some View {
        NavigationStack {
            settingsRoot
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .sheet(item: $actionAlert) { alert in
                IronStatusSheet(
                    headerTitle: "Light",
                    title: alert.title,
                    message: alert.message,
                    systemImage: "info.circle.fill",
                    tint: .accentColor
                )
            }
            .sheet(item: $feedbackPresentation) { presentation in
                switch presentation {
                case .composer:
                    FeedbackMailComposer(
                        recipients: ["iron@ka.codes"],
                        subject: "Light feedback"
                    ) { error in
                        feedbackPresentation = nil
                        guard let error else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            actionAlert = ActionAlert(
                                title: "Could Not Send Feedback",
                                message: error.localizedDescription
                            )
                        }
                    }

                case .options:
                    FeedbackOptionsSheet(emailAddress: "iron@ka.codes")
                }
            }
        }
    }

    private var settingsRoot: some View {
        List {
            Section {
                NavigationLink(destination: AboutView()) {
                    SettingsHeaderCard(workoutCount: workoutCount, firstWorkoutDate: firstWorkoutDate)
                }
            }

            Section {
                settingsLink(
                    "Appearance",
                    detail: settingsStore.appearance.title,
                    icon: "circle.lefthalf.filled",
                    tile: .indigo,
                    destination: AppearanceSettingsView()
                )
            }

            Section {
                settingsLink(
                    "Units",
                    detail: settingsStore.weightUnit.title,
                    icon: "scalemass.fill",
                    tile: .orange,
                    destination: UnitsSettingsView()
                )
                settingsLink("Workout preferences", icon: "slider.horizontal.3", tile: .blue, destination: GeneralSettingsView())
                settingsLink("Sounds & haptics", icon: "speaker.wave.2.fill", tile: .pink, destination: SoundsSettingsView())
                if HealthSettingsView.isSupported {
                    settingsLink("Apple Health", icon: "heart.fill", tile: .health, destination: HealthSettingsView())
                }
                if WatchSettingsView.isSupported {
                    settingsLink("Apple Watch", icon: "applewatch", tile: .watch, destination: WatchSettingsView())
                }
            } header: {
                Text("Training")
            }

            Section("Your Data") {
                settingsLink("Import & export", icon: "arrow.up.arrow.down", tile: .green, destination: BackupAndExportView())
            }

            Section("Support") {
                Button(action: sendFeedback) {
                    settingsRow("Send feedback", icon: "paperplane.fill", tile: .blue)
                }
                .buttonStyle(.plain)

                Button(action: openReview) {
                    settingsRow("Rate Light", icon: "star.fill", tile: .yellow)
                }
                .buttonStyle(.plain)

                settingsLink(
                    "Licenses & attributions",
                    icon: "doc.text.fill",
                    tile: .gray,
                    destination: LicensesAttributionsView()
                )
                settingsLink("About Light", icon: "info.circle.fill", tile: .gray, destination: AboutView())
            }

            #if DEBUG
            Section("Development") {
                settingsLink("Developer settings", icon: "hammer.fill", tile: .darkGray, destination: DeveloperSettings())
            }
            #endif
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: IronTheme.floatingWorkoutBottomClearance - 36)
        }
        .ironScreen()
        .task { loadWorkoutStats() }
    }

    private func loadWorkoutStats() {
        let predicate = NSPredicate(format: "\(#keyPath(Workout.isCurrentWorkout)) != %@", NSNumber(booleanLiteral: true))
        let countRequest: NSFetchRequest<Workout> = Workout.fetchRequest()
        countRequest.predicate = predicate
        workoutCount = try? managedObjectContext.count(for: countRequest)

        let firstRequest: NSFetchRequest<Workout> = Workout.fetchRequest()
        firstRequest.predicate = predicate
        firstRequest.sortDescriptors = [NSSortDescriptor(keyPath: \Workout.start, ascending: true)]
        firstRequest.fetchLimit = 1
        firstWorkoutDate = (try? managedObjectContext.fetch(firstRequest))?.first?.start
    }

    private func settingsLink<Destination: View>(
        _ title: String,
        detail: String? = nil,
        icon: String,
        tile: SettingsIconTile.Style,
        destination: Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            settingsRow(title, detail: detail, icon: icon, tile: tile)
        }
    }

    private func settingsRow(
        _ title: String,
        detail: String? = nil,
        icon: String,
        tile: SettingsIconTile.Style
    ) -> some View {
        HStack(spacing: 14) {
            SettingsIconTile(systemImage: icon, style: tile)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if let detail {
                        Text(detail)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(title)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.body)
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
    }

    private func openReview() {
        guard let url = URL(string: "https://itunes.apple.com/app/id1479893244?action=write-review") else { return }
        UIApplication.shared.open(url, options: [:]) { opened in
            guard !opened else { return }
            DispatchQueue.main.async {
                actionAlert = ActionAlert(
                    title: "Could Not Open the App Store",
                    message: "You can rate Light from its App Store page when the store is available."
                )
            }
        }
    }

    private func sendFeedback() {
        feedbackPresentation = MFMailComposeViewController.canSendMail() ? .composer : .options
    }
}

/// iOS Settings-style glyph tile: a white symbol on a colored rounded square.
private struct SettingsIconTile: View {
    enum Style {
        case indigo, orange, blue, pink, green, yellow, gray, darkGray, health, watch

        var fill: Color {
            switch self {
            case .indigo: return Color(UIColor.systemIndigo)
            case .orange: return Color(UIColor.systemOrange)
            case .blue: return Color(UIColor.systemBlue)
            case .pink: return Color(UIColor.systemPink)
            case .green: return Color(UIColor.systemGreen)
            case .yellow: return Color(UIColor.systemYellow)
            case .gray: return Color(UIColor.systemGray)
            case .darkGray: return Color(UIColor.systemGray2)
            case .health: return IronTheme.diagramCanvas
            case .watch: return Color(UIColor(white: 0.17, alpha: 1))
            }
        }

        var glyph: Color {
            self == .health ? Color(UIColor.systemPink) : IronTheme.onMedia
        }

        /// White and near-black tiles need an edge to separate from the cell.
        var needsEdge: Bool { self == .health || self == .watch }
    }

    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 30
    let systemImage: String
    let style: Style

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(style.fill)
            .overlay {
                if style.needsEdge {
                    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                        .strokeBorder(IronTheme.outline, lineWidth: 1)
                }
            }
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(style.glyph)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct SettingsHeaderCard: View {
    @ScaledMetric(relativeTo: .title3) private var iconSize: CGFloat = 56
    let workoutCount: Int?
    let firstWorkoutDate: Date?

    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (\(build))"
    }

    private var countTitle: String? {
        guard let workoutCount else { return nil }
        return workoutCount == 1 ? "1 workout" : "\(workoutCount.formatted()) workouts"
    }

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: iconSize * 0.25, style: .continuous)
                .fill(LinearGradient(
                    colors: [IronTheme.accent.opacity(0.78), IronTheme.accent],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .overlay {
                    Image(systemName: "dumbbell.fill")
                        .font(.system(size: iconSize * 0.46, weight: .semibold))
                        .foregroundStyle(IronTheme.onAccent)
                }
                .frame(width: iconSize, height: iconSize)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Light")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(IronTheme.primaryText)
                if let countTitle {
                    (Text(countTitle).foregroundColor(IronTheme.accent)
                     + Text(firstWorkoutDate.map { " · since \($0.formatted(.dateTime.month(.abbreviated).year()))" } ?? "")
                        .foregroundColor(IronTheme.secondaryText))
                        .font(.subheadline.weight(.semibold))
                }
                Text(versionString)
                    .font(.footnote)
                    .foregroundStyle(IronTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens About Light")
    }
}

private struct FeedbackMailComposer: UIViewControllerRepresentable {
    let recipients: [String]
    let subject: String
    let onFinish: (Error?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients(recipients)
        controller.setSubject(subject)
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: (Error?) -> Void

        init(onFinish: @escaping (Error?) -> Void) {
            self.onFinish = onFinish
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            onFinish(error)
        }
    }
}

private struct FeedbackOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let emailAddress: String
    @State private var copied = false
    @State private var mailLaunchFailed = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Open Default Mail App", systemImage: "envelope.fill", action: openMailApp)

                    Button(
                        copied ? "Address Copied" : "Copy \(emailAddress)",
                        systemImage: copied ? "checkmark" : "doc.on.doc"
                    ) {
                        UIPasteboard.general.string = emailAddress
                        copied = true
                    }
                } header: {
                    Text("Send Feedback")
                } footer: {
                    if mailLaunchFailed {
                        Label(
                            "No email app could open this message. Copy the address instead.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    } else {
                        Text("Apple Mail isn’t configured on this device. Open another email app or copy our support address.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .sensoryFeedback(.success, trigger: copied)
    }

    private func openMailApp() {
        guard let mailURL else {
            mailLaunchFailed = true
            return
        }

        UIApplication.shared.open(mailURL, options: [:]) { opened in
            DispatchQueue.main.async {
                if opened {
                    dismiss()
                } else {
                    mailLaunchFailed = true
                }
            }
        }
    }

    private var mailURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = emailAddress
        components.queryItems = [URLQueryItem(name: "subject", value: "Light feedback")]
        return components.url
    }
}

private struct AppearanceSettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        List {
            Section {
                ForEach(IronAppearance.allCases) { appearance in
                    Button {
                        settingsStore.appearance = appearance
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        HStack {
                            Label(appearance.title, systemImage: appearance.systemImage)
                                .foregroundStyle(.primary)
                            Spacer()
                            if settingsStore.appearance == appearance {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            } header: {
                Text("Theme")
            } footer: {
                Text(settingsStore.appearance.subtitle)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Appearance")
        .animation(IronMotion.preferred(IronMotion.fade, reduceMotion: reduceMotion), value: settingsStore.appearance)
    }
}

struct LicensesAttributionsView: View {
    private struct AttributionLink {
        let title: String
        let url: URL
    }

    var body: some View {
        List {
            Section {
                attributionSectionContent(
                    message: "Exercise metadata includes OpenGym’s community-written catalog, with AGPL-3.0 descriptions, instructions and corrections. Original ExerciseDB text from Hasan Emir Yıldırım’s dataset retains its MIT notice. These notices and source details are bundled with Light’s catalog.",
                    license: "AGPL-3.0 / MIT",
                    links: [
                        AttributionLink(title: "OpenGym catalog", url: URL(string: "https://github.com/DuarteSantos8/openGym/tree/main/catalogue")!),
                        AttributionLink(title: "Catalog notices", url: URL(string: "https://github.com/DuarteSantos8/openGym/blob/main/NOTICE.md")!),
                        AttributionLink(title: "Dataset source", url: URL(string: "https://github.com/hasaneyldrm/exercises-dataset")!)
                    ]
                )
            } header: {
                Text("Exercise Catalogue")
            }

            Section {
                attributionSectionContent(
                    message: "Light caches ExerciseDB’s Gym Visual media on this device, with still images for lists and animations for demonstrations. Later launches fill missing originals over Wi-Fi. \(Exercise.mediaAttribution). Media rights are separate from catalog text licenses; OpenGym’s separately licensed artwork is not included.",
                    license: "Cached media",
                    links: [
                        AttributionLink(title: "Gym Visual", url: URL(string: "https://gymvisual.com/")!),
                        AttributionLink(title: "ExerciseDB", url: URL(string: "https://exercisedb.dev/")!)
                    ]
                )
            } header: {
                Text("Exercise Images & Animations")
            }

            Section {
                attributionSectionContent(
                    message: "Front and back muscle highlighting uses MuscleMap 1.6.4 by Melih Colpan.",
                    license: "MIT",
                    links: [
                        AttributionLink(title: "MuscleMap source", url: URL(string: "https://github.com/melihcolpan/MuscleMap")!)
                    ]
                )
            } header: {
                Text("Muscle Maps")
            } footer: {
                Text("Full third-party license text ships with Light’s source distribution in THIRD_PARTY_NOTICES.md.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Licenses & Attributions")
    }

    @ViewBuilder
    private func attributionSectionContent(
        message: String,
        license: String,
        links: [AttributionLink]
    ) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(.secondary)

        LabeledContent("License", value: license)

        ForEach(Array(links.enumerated()), id: \.offset) { _, link in
            Link(destination: link.url) {
                LabeledContent(link.title) {
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                }
            }
        }
    }
}

struct WorkoutCalendarView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var exerciseStore: ExerciseStore
    @Environment(\.managedObjectContext) private var context
    @ObservedObject private var history = TrainingHistoryStore.shared

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var dayDiameter: CGFloat = 34
    @State private var selectedDay: TrainingDay?
    @State private var visibleMonth = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    private var weekdays: [String] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard !symbols.isEmpty else { return [] }
        let firstIndex = max(min(calendar.firstWeekday - 1, symbols.count - 1), 0)
        return Array(symbols[firstIndex...]) + Array(symbols[..<firstIndex])
    }

    private var monthTitle: String {
        visibleMonth.formatted(.dateTime.month(.wide).year())
    }

    private var completedWorkouts: [TrainingSessionSnapshot] { history.snapshot.sessions }
    private var monthWorkouts: [TrainingSessionSnapshot] {
        guard let interval = Calendar.current.dateInterval(of: .month, for: visibleMonth) else { return [] }
        return completedWorkouts.filter { interval.contains($0.date) }
    }
    private var trainingStreak: Int { history.snapshot.streak() }

    private var restDayCount: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let lastWorkoutDate = completedWorkouts
            .map(\.date)
            .map({ calendar.startOfDay(for: $0) })
            .filter({ $0 <= today })
            .max() else { return 0 }

        return max(calendar.dateComponents([.day], from: lastWorkoutDate, to: today).day ?? 0, 0)
    }

    private var calendarCells: [Date?] {
        let calendar = Calendar.current
        guard let range = calendar.range(of: .day, in: .month, for: visibleMonth),
              let first = calendar.date(from: calendar.dateComponents([.year, .month], from: visibleMonth)) else { return [] }
        let leading = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading) + range.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: first)
        }
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    HStack {
                        Button("Previous Month", systemImage: "chevron.left") { shiftMonth(-1) }
                            .labelStyle(.iconOnly)

                        Spacer()

                        Text(monthTitle)
                            .font(.headline)

                        Spacer()

                        Button("Next Month", systemImage: "chevron.right") { shiftMonth(1) }
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)

                    if dynamicTypeSize.isAccessibilitySize {
                        ScrollView(.horizontal) { calendarGrid }
                            .scrollIndicators(.hidden)
                    } else {
                        calendarGrid
                    }
                }
                .padding(.vertical, 6)
            } footer: {
                Text("^[\(monthWorkouts.count) workout](inflect: true) in \(monthTitle).")
            }

            Section("Momentum") {
                LabeledContent("Streak") {
                    Text("^[\(trainingStreak) week](inflect: true)")
                        .font(.ironMetric(.body, weight: .semibold))
                }
                LabeledContent("Rest Days") {
                    Text("^[\(restDayCount) day](inflect: true)")
                        .font(.ironMetric(.body, weight: .semibold))
                }
            }

            Section("This Month") {
                if monthWorkouts.isEmpty {
                    Text("Finished sessions in \(monthTitle) will appear here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(monthWorkouts) { workout in
                        NavigationLink(destination: WorkoutDetailView(workout: context.object(with: workout.id) as! Workout)) {
                            CalendarWorkoutRow(workout: context.object(with: workout.id) as! Workout, showsDate: true)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Calendar")
        .task { history.observe(in: context) }
        .navigationDestination(item: $selectedDay) { day in TrainingDayRecapView(date: day.date) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Today") {
                    withAnimation(IronMotion.preferred(IronMotion.collapse, reduceMotion: reduceMotion)) {
                        visibleMonth = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
                    }
                }
            }
        }
    }

    private var calendarGrid: some View {
        VStack(spacing: 6) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, weekday in
                    Text(weekday.uppercased()).font(.caption2.weight(.semibold))
                        .foregroundStyle(IronTheme.secondaryText).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(calendarCells.enumerated()), id: \.offset) { _, date in calendarDay(date) }
            }
        }
        .frame(width: dynamicTypeSize.isAccessibilitySize ? 7 * max(44, dayDiameter + 10) + 36 : nil)
    }

    private func shiftMonth(_ direction: Int) {
        guard let month = Calendar.current.date(byAdding: .month, value: direction, to: visibleMonth) else { return }
        withAnimation(IronMotion.preferred(IronMotion.collapse, reduceMotion: reduceMotion)) { visibleMonth = month }
    }

    @ViewBuilder private func calendarDay(_ date: Date?) -> some View {
        if let date {
            let count = history.snapshot.byDay[Calendar.current.startOfDay(for: date)]?.count ?? 0
            Button { selectedDay = TrainingDay(date: date) } label: {
                calendarDayContent(date, workoutCount: count)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the daily recap")
        } else {
            Color.clear.frame(minHeight: IronTheme.controlHeight)
        }
    }

    private func calendarDayContent(_ date: Date, workoutCount: Int) -> some View {
        let isToday = Calendar.current.isDateInToday(date)

        return ZStack {
            if workoutCount > 0 {
                Circle().fill(IronTheme.accent)
            } else if isToday {
                Circle().strokeBorder(IronTheme.accent, lineWidth: 1.5)
            }

            Text("\(Calendar.current.component(.day, from: date))")
                .font(.ironMetric(.subheadline, weight: workoutCount > 0 || isToday ? .bold : .semibold))
                .foregroundStyle(workoutCount > 0 ? IronTheme.onAccent : (isToday ? IronTheme.accent : IronTheme.primaryText))
        }
        .frame(width: dayDiameter, height: dayDiameter)
        .frame(maxWidth: .infinity, minHeight: max(IronTheme.controlHeight, dayDiameter + 10))
        .contentShape(Rectangle())
        .accessibilityLabel(
            "\(date.formatted(date: .long, time: .omitted)), \(workoutCount) workout\(workoutCount == 1 ? "" : "s")"
        )
    }
}

private struct WorkoutCalendarDayView: View {
    let date: Date
    let workouts: [Workout]

    var body: some View {
        List {
            Section {
                LabeledContent("Sessions") { Text("\(workouts.count)").font(.ironMetric(.body, weight: .semibold)) }
                LabeledContent("Completed Sets") {
                    Text("\(workouts.reduce(0) { $0 + ($1.numberOfCompletedSets ?? 0) })")
                        .font(.ironMetric(.body, weight: .semibold))
                }
                LabeledContent("Time") {
                    Text(Workout.durationFormatter.string(from: workouts.reduce(0) { $0 + ($1.duration ?? 0) }) ?? "0m")
                        .font(.ironMetric(.body, weight: .semibold))
                }
            }

            Section("Workouts") {
                ForEach(workouts) { workout in
                    NavigationLink(destination: WorkoutDetailView(workout: workout)) {
                        CalendarWorkoutRow(workout: workout, showsDate: false)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(date.formatted(date: .abbreviated, time: .omitted))
    }
}

private struct CalendarWorkoutRow: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var exerciseStore: ExerciseStore

    @ObservedObject var workout: Workout
    let showsDate: Bool

    private var durationText: String {
        guard let duration = workout.duration else { return "—" }
        return Workout.durationFormatter.string(from: duration) ?? "—"
    }

    private var volumeText: String {
        WeightUnit.format(
            weight: workout.trackedCompletedVolume,
            from: .metric,
            to: settingsStore.weightUnit
        )
    }

    private var timestampText: String {
        guard let start = workout.start else { return "Unknown date" }
        if showsDate {
            return start.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
        return start.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(workout.displayTitle(in: exerciseStore.exercises))
                .lineLimit(1)
            Text(timestampText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(durationText) · \(workout.numberOfCompletedSets ?? 0) sets · \(volumeText)")
                .font(.ironMetric(.caption, weight: .semibold))
                .foregroundStyle(IronTheme.secondaryText)
        }
    }
}

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .mockEnvironment(weightUnit: .metric)
    }
}
#endif
