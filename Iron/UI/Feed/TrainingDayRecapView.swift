import SwiftUI
import CoreData
import WorkoutDataKit

struct TrainingDay: Hashable, Identifiable {
    let date: Date
    var id: Date { date }
}

extension TrainingSessionSnapshot {
    func displayTitle(in store: ExerciseStore) -> String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        let names = exercises.compactMap { $0.uuid.flatMap { store.exercisesByUUID[$0]?.title } }
        return names.isEmpty ? "Workout" : names.prefix(3).joined(separator: ", ")
    }
}

struct TrainingDayRecapView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.calendar) private var calendar
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var exercises: ExerciseStore
    @ObservedObject private var history = TrainingHistoryStore.shared
    @ObservedObject private var measurements = BodyMetricsStore.shared
    let date: Date

    private var sessions: [TrainingSessionSnapshot] { history.snapshot.byDay[calendar.startOfDay(for: date)] ?? [] }
    private var sets: Int { sessions.reduce(0) { $0 + $1.setCount } }
    private var volume: Double { sessions.reduce(0) { $0 + $1.volume } }
    private var duration: String { Workout.durationFormatter.string(from: sessions.reduce(0) { $0 + $1.duration }) ?? "0m" }
    private var muscleSets: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for session in sessions {
            for item in session.exercises {
                guard let id = item.uuid, let exercise = exercises.exercisesByUUID[id] else { continue }
                counts[exercise.muscleGroup, default: 0] += item.setCount
            }
        }
        return counts.map { ($0.key, $0.value) }.sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }
    private var dayMeasurements: [BodyMeasurementEntry] { measurements.entries.filter { calendar.isDate($0.date, inSameDayAs: date) } }

    var body: some View {
        List {
            Section {
                let columns = Array(repeating: GridItem(.flexible(), alignment: .leading), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    metric(sessions.count == 1 ? "Workout" : "Workouts", value: "\(sessions.count)", tint: IronTheme.accent)
                    metric("Completed Sets", value: "\(sets)", tint: IronTheme.metricSets)
                    metric("Training Time", value: duration, tint: IronTheme.metricTime)
                    metric("Volume", value: WeightUnit.convert(weight: volume, from: .metric, to: settings.weightUnit).formatted(.number.precision(.fractionLength(0))), unit: settings.weightUnit.unit.symbol, tint: IronTheme.metricVolume)
                }
                .padding(.vertical, 8)
            } header: {
                Text("Daily Recap")
            } footer: {
                Text(date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
            }

            Section("Workouts") {
                if sessions.isEmpty {
                    ContentUnavailableView("Rest Day", systemImage: "bed.double", description: Text("No completed workouts were logged on this day."))
                } else {
                    ForEach(sessions) { session in
                        NavigationLink {
                            if let workout = try? context.existingObject(with: session.id) as? Workout {
                                WorkoutDetailView(workout: workout)
                            } else {
                                ContentUnavailableView("Workout Unavailable", systemImage: "dumbbell", description: Text("This workout may have been removed."))
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(session.displayTitle(in: exercises)).font(.headline)
                                Text(session.date.formatted(date: .omitted, time: .shortened))
                                    .font(.subheadline).foregroundStyle(IronTheme.secondaryText)
                                IronWorkoutMetricLine(duration: Workout.durationFormatter.string(from: session.duration) ?? "0m",
                                    sets: session.setCount,
                                    volume: WeightUnit.convert(weight: session.volume, from: .metric, to: settings.weightUnit).formatted(.number.precision(.fractionLength(0))), unit: settings.weightUnit.unit.symbol)
                                if let effort = session.effort {
                                    Text("RPE \(effort.formatted(.number.precision(.fractionLength(0...1))))")
                                        .font(.ironMetric(.caption)).foregroundStyle(IronTheme.metricEffort)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            if !muscleSets.isEmpty {
                Section("Muscle Focus") {
                    ForEach(muscleSets, id: \.name) { item in
                        LabeledContent(item.name.capitalized) {
                            IronMetricValue(value: "\(item.count)", unit: "sets", style: .body, tint: IronTheme.metricSets)
                        }
                    }
                }
            }
            if !dayMeasurements.isEmpty {
                Section("Measurements") {
                    ForEach(BodyMeasurementKind.allCases) { kind in
                        if let value = dayMeasurements.sorted(by: { $0.date > $1.date }).compactMap({ $0[kind] }).first {
                            LabeledContent(kind.title) {
                                IronMetricValue(value: kind.displayValue(from: value, weightUnit: settings.weightUnit).formatted(.number.precision(.fractionLength(0...1))), unit: kind.unitLabel(weightUnit: settings.weightUnit), style: .body, tint: IronTheme.metricBody)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.bottom, IronTheme.floatingWorkoutBottomClearance, for: .scrollContent)
        .navigationTitle(date.formatted(.dateTime.month(.abbreviated).day()))
        .navigationBarTitleDisplayMode(.inline)
        .task { history.observe(in: context) }
    }

    private func metric(_ label: String, value: String, unit: String? = nil, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            IronMetricValue(value: value, unit: unit, tint: tint)
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: value)
            Text(label).font(.footnote).foregroundStyle(IronTheme.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }
}
