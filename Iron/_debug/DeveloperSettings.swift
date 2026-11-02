//
//  DeveloperSettings.swift
//  Iron
//
//  Created by Karim Abou Zeid on 17.03.20.
//  Copyright © 2020 Karim Abou Zeid Software. All rights reserved.
//

#if DEBUG

import SwiftUI
import CoreData
import WorkoutDataKit

struct DeveloperSettings: View {
    @Environment(\.managedObjectContext) private var managedObjectContext
    @State private var activityItems: [Any]?
    @State private var showingPlanConfirmation = false
    @State private var statusMessage: String?
    @State private var showingPPLResult = false
    @State private var pplResultMessage = ""

    var body: some View {
        List {
            if let statusMessage {
                Section {
                    LabeledContent {
                        Button("Dismiss", systemImage: "xmark") { self.statusMessage = nil }
                            .labelStyle(.iconOnly)
                    } label: {
                        Label(statusMessage, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(IronTheme.success)
                    }
                }
            }

            Section {
                Button("Create Sample Workouts", systemImage: "plus") {
                    showingPlanConfirmation = true
                }

                Button("Seed Sample History", systemImage: "clock.arrow.circlepath") {
                    seedSampleHistory()
                }
            } header: {
                Text("Sample Data")
            } footer: {
                Text("Sample workouts adds Workout A and Workout B with ready-to-edit 5×5 sets. Seed history fills completed workouts and body measurements so populated screens can be reviewed.")
            }

            Section {
                Button("Add PPL Program (5 workouts)", systemImage: "plus") {
                    addPPLProgram()
                }
            } header: {
                Text("Sample Programs")
            } footer: {
                Text("Adds the beginner Push/Pull/Legs workouts with rep targets, rest timers, and progression notes. Enter your own weights. Existing workout names are skipped.")
            }

            Section {
                LabeledContent("Database", value: databaseSummary)
                Button("Share Database Snapshot", systemImage: "square.and.arrow.up") {
                    shareFile(url: WorkoutDataStorage.groupStoreURL)
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("These controls are available only in development builds. Exported databases can contain your complete local training history.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Developer")
        .ironActivitySheet(activityItems: $activityItems)
        .alert("PPL Program", isPresented: $showingPPLResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pplResultMessage)
        }
        .sheet(isPresented: $showingPlanConfirmation) {
            IronConfirmationSheet(
                title: "Create sample workouts?",
                message: "This adds two editable sample workouts. Existing saved workouts are not changed.",
                confirmTitle: "Create Sample Workouts",
                systemImage: "square.stack.3d.up.fill",
                secondaryTitle: "Cancel",
                onCancel: { showingPlanConfirmation = false },
                onConfirm: {
                    showingPlanConfirmation = false
                    createDefaultWorkoutPlans()
                    statusMessage = "StrongLifts 5×5 sample workouts were added."
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    private func seedSampleHistory() {
        IronSampleDataSeeder.seed(reset: false)
        statusMessage = "Sample history and measurements were added."
    }

    private var databaseSummary: String {
        let url = WorkoutDataStorage.groupStoreURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return url.lastPathComponent
        }
        return "\(url.lastPathComponent) · \(ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file))"
    }

    private func shareFile(url: URL) {
        self.activityItems = [url]
    }
}

private extension DeveloperSettings {
    func addPPLProgram() {
        do {
            pplResultMessage = try PPLSampleProgram.add(in: managedObjectContext)
        } catch {
            pplResultMessage = "The PPL workouts could not be saved. Try again. \(error.localizedDescription)"
        }
        showingPPLResult = true
    }
}

/// Uses the same factories, ordered relationships, and reversible save boundary
/// as the saved-workout editor. No completed workouts or custom catalog data are created.
private enum PPLSampleProgram {
    private enum Movement {
        case deadlift, pulldown, cableRow, facePull, hammerCurl, dumbbellCurl
        case barbellRow, bench, overheadPress, inclinePress, pushdown, lateralRaise
        case tricepsExtension, squat, romanianDeadlift, legPress, legCurl, calfRaise

        var names: [String] {
            switch self {
            case .deadlift:
                return ["Deadlift (Barbell)", "Barbell Deadlift", "Deadlift: Barbell"]
            case .pulldown:
                return ["Lat Pulldown", "Lat Pulldown (Cable)", "Pulldown (Overhand)", "Cable Pulldown", "Pull-up", "Chin-up"]
            case .cableRow:
                return ["Seated Cable Row", "Seated Row (Cable)", "Cable Low Seated Row", "Cable Straight Back Seated Row", "Chest Supported Row"]
            case .facePull:
                return ["Face Pull", "Face Pulls", "Cable Standing Face Pull"]
            case .hammerCurl:
                return ["Hammer Curl", "Hammer Curl (Dumbbell)", "Dumbbell Hammer Curl"]
            case .dumbbellCurl:
                return ["Dumbbell Curl", "Bicep Curl (Dumbbell)", "Bicep Curl, Dumbbell", "Dumbbell Biceps Curl", "Biceps Curl: Dumbbell"]
            case .barbellRow:
                return ["Barbell Row", "Bent Over Row (Barbell)", "Bent Over Row, Barbell", "Barbell Bent Over Row"]
            case .bench:
                return ["Bench Press (Barbell)", "Barbell Bench Press", "Bench Press: Barbell"]
            case .overheadPress:
                return ["Overhead Press (Barbell)", "Overhead Press: Barbell", "Barbell Overhead Press", "Overhead Press"]
            case .inclinePress:
                return ["Incline Dumbbell Press", "Incline Bench Press (Dumbbell)", "Dumbbell Incline Bench Press", "Bench Press: Dumbbell (Incline)"]
            case .pushdown:
                return ["Triceps Pushdown (Cable)", "Triceps Pushdown: Cable", "Cable Triceps Pushdown"]
            case .lateralRaise:
                return ["Lateral Raise (Dumbbell)", "Dumbbell Lateral Raise", "Side Raise: Dumbbell", "Lateral Raise"]
            case .tricepsExtension:
                return ["Overhead Triceps Extension", "Triceps Extension (Dumbbell)", "Dumbbell Seated Triceps Extension", "Barbell Seated Overhead Triceps Extension"]
            case .squat:
                return ["Squat (Barbell)", "Barbell Back Squat", "Squat: Barbell", "Barbell Squat"]
            case .romanianDeadlift:
                return ["Romanian Deadlift (Barbell)", "Barbell Romanian Deadlift", "Romanian Deadlift"]
            case .legPress:
                return ["Leg Press", "Leg Press (Machine)"]
            case .legCurl:
                return ["Leg Curl (Lying)", "Lying Leg Curl", "Leg Curl (Seated)", "Seated Leg Curl"]
            case .calfRaise:
                return ["Calf Raise: Machine (Standing)", "Standing Calf Raise (Machine)", "Calf Raise: Machine (Seated)", "Seated Calf Raise", "Standing Calf Raise"]
            }
        }
    }

    private struct ExerciseSpec {
        let movement: Movement
        let sets: Int
        var minReps: Int16 = 8
        var maxReps: Int16 = 12
        var isMainLift = false
        var superset: Int? = nil

        var note: String {
            if isMainLift {
                let progression = "Last set AMRAP (5+), good form. Add 5 lb next session (deadlift 10 lb). Fail 3× in a row → deload 10%."
                return sets == 1 ? "One top set. \(progression)" : progression
            }
            return "\(minReps)–\(maxReps) reps. When you hit \(sets)×\(maxReps) with good form, add weight."
        }
    }

    private struct WorkoutSpec {
        let title: String
        let exercises: [ExerciseSpec]
    }

    private static var workouts: [WorkoutSpec] {
        let pullAccessories = [
            ExerciseSpec(movement: .pulldown, sets: 3),
            ExerciseSpec(movement: .cableRow, sets: 3),
            ExerciseSpec(movement: .facePull, sets: 5, minReps: 15, maxReps: 20),
            ExerciseSpec(movement: .hammerCurl, sets: 4),
            ExerciseSpec(movement: .dumbbellCurl, sets: 4)
        ]
        let pushAccessories = [
            ExerciseSpec(movement: .inclinePress, sets: 3),
            ExerciseSpec(movement: .pushdown, sets: 3, superset: 0),
            ExerciseSpec(movement: .lateralRaise, sets: 3, minReps: 15, maxReps: 20, superset: 0),
            ExerciseSpec(movement: .tricepsExtension, sets: 3, superset: 1),
            ExerciseSpec(movement: .lateralRaise, sets: 3, minReps: 15, maxReps: 20, superset: 1)
        ]
        return [
            WorkoutSpec(title: "Pull A (Deadlift)", exercises: [
                ExerciseSpec(movement: .deadlift, sets: 1, minReps: 5, maxReps: 5, isMainLift: true)
            ] + pullAccessories),
            WorkoutSpec(title: "Pull B (Row)", exercises: [
                ExerciseSpec(movement: .barbellRow, sets: 5, minReps: 5, maxReps: 5, isMainLift: true)
            ] + pullAccessories),
            WorkoutSpec(title: "Push A (Bench)", exercises: [
                ExerciseSpec(movement: .bench, sets: 5, minReps: 5, maxReps: 5, isMainLift: true),
                ExerciseSpec(movement: .overheadPress, sets: 3)
            ] + pushAccessories),
            WorkoutSpec(title: "Push B (OHP)", exercises: [
                ExerciseSpec(movement: .overheadPress, sets: 5, minReps: 5, maxReps: 5, isMainLift: true),
                ExerciseSpec(movement: .bench, sets: 3)
            ] + pushAccessories),
            WorkoutSpec(title: "Legs", exercises: [
                ExerciseSpec(movement: .squat, sets: 3, minReps: 5, maxReps: 5, isMainLift: true),
                ExerciseSpec(movement: .romanianDeadlift, sets: 3),
                ExerciseSpec(movement: .legPress, sets: 3),
                ExerciseSpec(movement: .legCurl, sets: 3),
                ExerciseSpec(movement: .calfRaise, sets: 5)
            ])
        ]
    }

    private struct CatalogLookup {
        var titles = [String: Exercise]()
        var aliases = [String: Exercise]()

        init(_ exercises: [Exercise]) {
            // Preserve catalog precedence when multiple entries share a name.
            for exercise in exercises.reversed() {
                titles[ExerciseCatalogMetadata.nameKey(exercise.title)] = exercise
                for alias in exercise.alias {
                    aliases[ExerciseCatalogMetadata.nameKey(alias)] = exercise
                }
            }
        }
    }

    private static func match(_ movement: Movement, in catalog: CatalogLookup) -> Exercise? {
        let names = movement.names.map(ExerciseCatalogMetadata.nameKey)
        // Prefer exact bundled titles, then reviewed catalog aliases. Only reuse
        // a custom exercise if none of the supplied built-in variants exists.
        for name in names {
            if let exercise = catalog.titles[name] { return exercise }
        }
        for name in names {
            if let exercise = catalog.aliases[name] { return exercise }
        }
        return nil
    }

    static func add(in context: NSManagedObjectContext) throws -> String {
        let existing = try context.fetch(WorkoutRoutine.fetchRequest())
        let existingNames = Set(existing.compactMap(\.title).map(ExerciseCatalogMetadata.nameKey))
        let specifications = workouts
        let missing = specifications.filter { !existingNames.contains(ExerciseCatalogMetadata.nameKey($0.title)) }
        let skipped = specifications.filter { existingNames.contains(ExerciseCatalogMetadata.nameKey($0.title)) }
        guard !missing.isEmpty else {
            return "Already added. All five workout names exist in Saved Workouts."
        }

        let store = ExerciseStore.shared
        let builtInCatalog = CatalogLookup(store.builtInExercises)
        let customCatalog = CatalogLookup(store.customExercises)
        var unmatched = [String]()
        let plans = try context.fetch(WorkoutPlan.fetchRequest())
        try context.persistMutation(save: { try context.save() }) {
            let folder = plans.first { ExerciseCatalogMetadata.nameKey($0.title ?? "") == "ppl" }
                ?? WorkoutPlan.create(context: context)
            folder.title = "PPL"
            for specification in missing {
                let routine = WorkoutRoutine.create(context: context)
                routine.title = specification.title
                routine.workoutPlan = folder
                var members = [(ExerciseSpec, WorkoutRoutineExercise)]()
                for spec in specification.exercises {
                    guard let catalogExercise = match(spec.movement, in: builtInCatalog)
                        ?? match(spec.movement, in: customCatalog) else {
                        unmatched.append("\(specification.title): \(spec.movement.names[0])")
                        continue
                    }
                    let exercise = WorkoutRoutineExercise.create(context: context)
                    exercise.exerciseUuid = catalogExercise.uuid
                    exercise.comment = spec.note
                    exercise.restTimerDurationValue = spec.isMainLift ? 180 : 90
                    let sets = (0..<spec.sets).map { index -> WorkoutRoutineSet in
                        let set = WorkoutRoutineSet.create(context: context)
                        let isAMRAP = spec.isMainLift && index == spec.sets - 1
                        set.minRepetitionsValue = spec.minReps
                        set.maxRepetitionsValue = isAMRAP ? nil : spec.maxReps
                        set.weightValue = nil
                        if isAMRAP { set.comment = "AMRAP (5+), good form." }
                        return set
                    }
                    exercise.workoutRoutineSets = NSOrderedSet(array: sets)
                    members.append((spec, exercise))
                }
                for group in Set(members.compactMap { $0.0.superset }) {
                    let partners = members.filter { $0.0.superset == group }
                    guard partners.count > 1 else { continue }
                    let id = UUID()
                    for (_, exercise) in partners {
                        exercise.supersetUuid = id
                        exercise.restTimerDurationValue = 60
                    }
                }
                routine.workoutRoutineExercises = NSOrderedSet(array: members.map { $0.1 })
            }
        }

        var report = ["Added to PPL:\n" + missing.map(\.title).joined(separator: "\n")]
        if !skipped.isEmpty {
            report.append("Already added (skipped):\n" + skipped.map(\.title).joined(separator: "\n"))
        }
        report.append(unmatched.isEmpty
            ? "All exercises matched. Weights are empty."
            : "Exercises not matched (skipped):\n" + unmatched.joined(separator: "\n"))
        return report.joined(separator: "\n\n")
    }
}

func toUuid(_ id: Int) -> UUID? {
    ExerciseStore.shared.exercises.first { $0.everkineticId == id }?.uuid
}

func niceWeight(weight: Double, unit: WeightUnit) -> Double {
    let weightInUnit = WeightUnit.convert(weight: weight, from: .metric, to: unit)
    let nice = weightInUnit - weightInUnit.truncatingRemainder(dividingBy: unit.barbellIncrement)
    return WeightUnit.convert(weight: nice, from: unit, to: .metric)
}

func createDefaultWorkoutPlans() {
    let context = WorkoutDataStorage.shared.persistentContainer.viewContext
    let unit = SettingsStore.shared.weightUnit

    let create5x5 = { (weight: Double) -> [WorkoutRoutineSet] in
        (0..<5).map { _ -> WorkoutRoutineSet in
            let set = WorkoutRoutineSet.create(context: context)
            set.minRepetitionsValue = 5
            set.maxRepetitionsValue = 5
            return set
        }
    }

    let workoutRoutineExerciseSquatA = WorkoutRoutineExercise.create(context: context)
    workoutRoutineExerciseSquatA.exerciseUuid = toUuid(122) // squat
    workoutRoutineExerciseSquatA.workoutRoutineSets = NSOrderedSet(array: create5x5(niceWeight(weight: 120, unit: unit)))

    let workoutRoutineExerciseBenchA = WorkoutRoutineExercise.create(context: context)
    workoutRoutineExerciseBenchA.exerciseUuid = toUuid(42) // bench
    workoutRoutineExerciseBenchA.workoutRoutineSets = NSOrderedSet(array: create5x5(niceWeight(weight: 80, unit: unit)))

    let workoutRoutineExerciseRowA = WorkoutRoutineExercise.create(context: context)
    workoutRoutineExerciseRowA.exerciseUuid = toUuid(298) // row
    workoutRoutineExerciseRowA.workoutRoutineSets = NSOrderedSet(array: create5x5(niceWeight(weight: 60, unit: unit)))

    let workoutRoutineA = WorkoutRoutine.create(context: context)
    workoutRoutineA.title = "Workout A"
    workoutRoutineA.workoutRoutineExercises = NSOrderedSet(arrayLiteral: workoutRoutineExerciseSquatA, workoutRoutineExerciseBenchA, workoutRoutineExerciseRowA)

    let workoutRoutineExerciseSquatB = WorkoutRoutineExercise.create(context: context)
    workoutRoutineExerciseSquatB.exerciseUuid = toUuid(122) // squat
    workoutRoutineExerciseSquatB.workoutRoutineSets = NSOrderedSet(array: create5x5(niceWeight(weight: 120, unit: unit)))

    let workoutRoutineExerciseBenchB = WorkoutRoutineExercise.create(context: context)
    workoutRoutineExerciseBenchB.exerciseUuid = toUuid(9001) // press
    workoutRoutineExerciseBenchB.workoutRoutineSets = NSOrderedSet(array: create5x5(niceWeight(weight: 65, unit: unit)))

    let workoutRoutineExerciseRowB = WorkoutRoutineExercise.create(context: context)
    workoutRoutineExerciseRowB.exerciseUuid = toUuid(99) // deadlift
    workoutRoutineExerciseRowB.workoutRoutineSets = NSOrderedSet(array: create5x5(niceWeight(weight: 140, unit: unit)))

    let workoutRoutineB = WorkoutRoutine.create(context: context)
    workoutRoutineB.title = "Workout B"
    workoutRoutineB.workoutRoutineExercises = NSOrderedSet(arrayLiteral: workoutRoutineExerciseSquatB, workoutRoutineExerciseBenchB, workoutRoutineExerciseRowB)

    let workoutPlan = WorkoutPlan.create(context: context)
    workoutPlan.title = "StrongLifts 5x5"
    workoutPlan.workoutRoutines = NSOrderedSet(arrayLiteral: workoutRoutineA, workoutRoutineB)
    context.saveOrCrash()
}

/// Populates a development build with training history and body measurements so
/// every screen can be reviewed with realistic content.
enum IronSampleDataSeeder {
    static func seed(reset: Bool, includeActiveWorkout: Bool = false) {
        let context = WorkoutDataStorage.shared.persistentContainer.viewContext
        let unit = SettingsStore.shared.weightUnit

        if reset {
            deleteAllWorkouts(in: context)
        }

        MockWorkoutData.seedHistory(
            into: context,
            unit: unit,
            includeActiveWorkout: includeActiveWorkout
        )
        context.saveOrCrash()
        seedBodyMeasurements(reset: reset)
    }

    private static func deleteAllWorkouts(in context: NSManagedObjectContext) {
        let request: NSFetchRequest<Workout> = Workout.fetchRequest()
        for workout in (try? context.fetch(request)) ?? [] {
            context.delete(workout)
        }
        let planRequest: NSFetchRequest<WorkoutPlan> = WorkoutPlan.fetchRequest()
        for plan in (try? context.fetch(planRequest)) ?? [] {
            context.delete(plan)
        }
        context.saveOrCrash()
    }

    private static func seedBodyMeasurements(reset: Bool) {
        let store = BodyMetricsStore.shared
        if reset {
            store.delete(at: IndexSet(store.entries.indices))
        }

        // Weekly entries over three months so the Home panel shows a current
        // value and the dashboard chart has a readable slope.
        for week in 0..<12 {
            guard let date = Calendar.current.date(
                byAdding: .day, value: -week * 7, to: Date()
            ) else { continue }

            let progress = Double(week)
            let entry = BodyMeasurementEntry(
                date: date,
                values: [
                    BodyMeasurementKind.bodyWeight.rawValue: 84 + progress * 0.35,
                    BodyMeasurementKind.bodyFat.rawValue: 16 + progress * 0.2,
                    BodyMeasurementKind.waist.rawValue: 82 + progress * 0.3,
                    BodyMeasurementKind.chest.rawValue: 104 - progress * 0.15,
                    BodyMeasurementKind.leftBicep.rawValue: 37 - progress * 0.08,
                    BodyMeasurementKind.rightBicep.rawValue: 37.2 - progress * 0.08
                ]
            )
            store.save(entry, exportToHealth: false)
        }
    }
}

struct DeveloperSettings_Previews: PreviewProvider {
    static var previews: some View {
        DeveloperSettings()
    }
}

#endif

#if DEBUG
/// Runs the real import/removal services against a disposable in-memory store.
/// This ordinary-app check also works when Xcode's XCTest device service is unavailable.
@MainActor
enum IronImportedDataSmokeCheck {
    private struct CheckFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run() async {
        var checks = [String]()
        var failure: String?
        let suiteName = "IronImportedDataSmoke.\(UUID().uuidString)"
        let exerciseURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(suiteName).json")
        defer { try? FileManager.default.removeItem(at: exerciseURL) }
        do {
            func require(_ condition: Bool, _ label: String) throws {
                guard condition else { throw CheckFailure(message: label) }
                checks.append(label)
            }
            let container = NSPersistentContainer(name: "ImportedDataSmoke", managedObjectModel: WorkoutDataStorage.model)
            let description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
            description.shouldAddStoreAsynchronously = false
            container.persistentStoreDescriptions = [description]
            var loadError: Error?
            container.loadPersistentStores { _, error in loadError = error }
            if let loadError { throw loadError }
            let context = container.viewContext
            func importedWorkout() throws -> Workout {
                guard let workout = try HevyImportedWorkouts.fetch(in: context).first else {
                    throw CheckFailure(message: "Expected an imported workout")
                }
                return workout
            }
            let store = ExerciseStore(customExercisesURL: exerciseURL)
            guard let exercise = store.exercises.first, let defaults = UserDefaults(suiteName: suiteName) else {
                throw CheckFailure(message: "Could not create disposable stores")
            }
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let measurements = BodyMetricsStore(userDefaults: defaults)
            let measurement = BodyMeasurementEntry(values: [BodyMeasurementKind.bodyWeight.rawValue: 82])
            try require(measurements.save(measurement, exportToHealth: false), "Seed isolated measurement")
            func csv(weight: Int = 100, exerciseTitle: String? = nil) -> Data {
                let name = (exerciseTitle ?? exercise.title).replacingOccurrences(of: "\"", with: "\"\"")
                return Data("title,start_time,end_time,exercise_title,set_index,weight_kg,reps\nImported,2026-08-17T08:16:00Z,2026-08-17T08:35:00Z,\"\(name)\",0,\(weight),8\n".utf8)
            }
            let initial = try HevyCSV.importData(csv(), into: context, exerciseStore: store, bodyMetricsStore: measurements)
            try require(initial.importedWorkouts == 1 && initial.importedSets == 1, "Import workout and set")
            let imported = try importedWorkout()
            imported.title = "Renamed in Iron"
            let native = Workout.create(context: context)
            native.title = "Native workout"
            native.start = Date(timeIntervalSince1970: 1_790_000_000)
            native.end = native.start?.addingTimeInterval(60)
            let other = Workout.create(context: context)
            other.importSource = "json"
            other.start = native.start
            other.end = native.end
            try context.save()
            let nativeID = native.objectID
            let otherID = other.objectID
            let duplicate = try HevyCSV.importData(csv(), into: context, exerciseStore: store, bodyMetricsStore: measurements)
            try require(duplicate.importedWorkouts == 0 && duplicate.skippedDuplicateWorkouts == 1,
                        "Renamed Hevy session deduplicates by content")
            native.comment = "Pending native edit"
            let controller = HevyImportController()
            let replacement = try await controller.replace(csv(weight: 105), into: context, exerciseStore: store).result.get()
            try require(replacement.removedWorkouts == 1 && replacement.importedWorkouts == 1,
                        "Background replacement commits removal and import")
            let replaced = try importedWorkout()
            let replacedID = replaced.objectID
            let replacedExercise = replaced.workoutExercises?.firstObject as? WorkoutExercise
            let replacedSet = replacedExercise?.workoutSets?.firstObject as? WorkoutSet
            try require(replacedSet?.weightValue == 105, "Replacement contains edited Hevy set")
            try require(native.objectID == nativeID && other.objectID == otherID && !native.isDeleted && !other.isDeleted,
                        "Native and other-source workouts survive replacement")
            try require(native.comment == "Pending native edit" && context.hasChanges,
                        "Background merge preserves unsaved native edit")
            let failed = try HevyCSV.prepareImport([csv(exerciseTitle: "Unique Smoke Replacement Press")])
            var rejectedSave = false
            do {
                _ = try HevyCSV.importData(failed, into: context, exerciseStore: store, bodyMetricsStore: measurements,
                                          replacingImportedWorkouts: true, save: { throw CheckFailure(message: "Injected save failure") })
            } catch { rejectedSave = true }
            try require(rejectedSave, "Injected replacement save failure is reported")
            try require(try HevyImportedWorkouts.fetch(in: context).map(\.objectID) == [replacedID],
                        "Failed replacement restores original imported workout")
            try require(try context.count(for: WorkoutSet.fetchRequest()) == 1,
                        "Failed replacement restores set graph without orphan inserts")
            try require(store.customExercises.isEmpty && !FileManager.default.fileExists(atPath: exerciseURL.path),
                        "Failed replacement restores custom-exercise file and published store")
            let customReplacement = try await controller.replace(csv(exerciseTitle: "Smoke Custom Press"),
                                                                 into: context, exerciseStore: store).result.get()
            let customExercise = store.customExercises.first { $0.title == "Smoke Custom Press" }
            let customWorkoutExercise = try importedWorkout().workoutExercises?.firstObject as? WorkoutExercise
            try require(customReplacement.createdExercises == 1 && customExercise != nil
                        && customWorkoutExercise?.exerciseUuid == customExercise?.uuid,
                        "Background replacement publishes custom exercise before reporting success")
            let malformed = try HevyCSV.prepareImport([Data((String(decoding: csv(), as: UTF8.self) + "Broken,not-a-date,,Unknown,0,100,8\n").utf8)])
            var rejectedMalformed = false
            do {
                _ = try HevyCSV.importData(malformed, into: context, exerciseStore: store,
                                          bodyMetricsStore: measurements, replacingImportedWorkouts: true)
            } catch { rejectedMalformed = true }
            try require(rejectedMalformed && (try HevyImportedWorkouts.fetch(in: context).count) == 1,
                        "Malformed replacement fails before deletion")
            let removed = try await controller.remove(count: 1, from: context).result.get()
            try require(removed.removedWorkouts == 1 && (try HevyImportedWorkouts.fetch(in: context).isEmpty),
                        "Background removal deletes only Hevy workouts")
            try require(try context.count(for: Workout.fetchRequest()) == 2, "Removal keeps native and JSON workouts")
            try require(try context.count(for: WorkoutExercise.fetchRequest()) == 0 && context.count(for: WorkoutSet.fetchRequest()) == 0,
                        "Removal cascades exercise and set graph")
            try require(native.comment == "Pending native edit" && context.hasChanges, "Removal preserves pending native edit")
            try require(measurements.entries == [measurement], "Measurements remain unchanged")
            try require(controller.phase == nil, "Progress overlay clears after completion")
        } catch {
            failure = error.localizedDescription
        }
        var report: [String: Any] = ["passed": failure == nil, "checks": checks]
        if let failure { report["error"] = failure }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imported-data-smoke.json")
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic) }
        catch { print("Could not write imported-data smoke report: \(error.localizedDescription)") }
    }
}
#endif
