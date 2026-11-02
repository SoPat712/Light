//
//  ExerciseStore.swift
//  Iron
//
//  Created by Karim Abou Zeid on 17.09.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import Foundation
import CoreData
import Combine
import os.log

public class ExerciseStore: ObservableObject {
    public static var defaultBuiltInExercisesResourceURL: URL {
        Bundle(for: Self.self).bundleURL.appendingPathComponent("everkinetic-data")
    }
    
    public static var defaultBuiltInExercisesURL: URL {
        defaultBuiltInExercisesResourceURL.appendingPathComponent("exercises.json")
    }
    
    public let builtInExercises: [Exercise]
    private let catalogMetadata: ExerciseCatalogMetadata
    private let catalogSecondaryIDs: Set<UUID>
    
    @Published private(set) public var customExercises: [Exercise] {
        didSet { rebuildExerciseLookup() }
    }
    public private(set) var exercisesByUUID: [UUID: Exercise] = [:]

    private func rebuildExerciseLookup() {
        exercisesByUUID = (builtInExercises + customExercises).reduce(into: [:]) { $0[$1.uuid] = $1 }
    }

    /// Shared history snapshot. Searching and rendering only read this cache.
    @Published private(set) public var lastPerformedDates: [UUID: Date] = [:]
    /// Every exercise in any workout or saved workout, logged or not.
    @Published private(set) public var workoutReferencedExerciseIDs: Set<UUID> = []
    private var recencyContext: NSManagedObjectContext?
    private var recencyObserver: AnyCancellable?
    private var recencyRefreshRunning = false
    private var recencyRefreshPending = false
    
    public var exercises: [Exercise] {
        builtInExercises + customExercises
    }
    
    public var shownExercises: [Exercise] {
        let hidden = Set(userDefaults.refreshedHiddenExerciseUuids())
        return orderedByRecency(exercises.filter { !hidden.contains($0.uuid) })
    }
    
    public var hiddenExercises: [Exercise] {
        let hidden = Set(userDefaults.refreshedHiddenExerciseUuids())
        return exercises.filter { hidden.contains($0.uuid) }
    }

    /// Whether a list shows this exercise before searching or asking for more.
    /// Anything the person has used always stays, and custom exercises are never secondary.
    public func isBrowsable(_ exercise: Exercise) -> Bool {
        !catalogSecondaryIDs.contains(exercise.uuid)
            || lastPerformedDates[exercise.uuid] != nil
            || workoutReferencedExerciseIDs.contains(exercise.uuid)
    }

    /// What a list shows for these matches. Searching or asking for more reaches everything,
    /// browsable exercises first, and a filter never comes up empty because of the cleanup.
    public func listed(_ matches: [Exercise], showingAll: Bool) -> [Exercise] {
        let browsable = matches.filter(isBrowsable)
        guard showingAll else { return browsable.isEmpty ? matches : browsable }
        return browsable + matches.filter { !isBrowsable($0) }
    }
    
    private let customExercisesURL: URL?
    
    private let userDefaults: UserDefaults
    private var hiddenExercisesObserver: AnyCancellable?
    
    public init(builtInExercisesURL: URL = ExerciseStore.defaultBuiltInExercisesURL, customExercisesURL: URL?, userDefaults: UserDefaults = UserDefaults.standard) {
        self.userDefaults = userDefaults
        self.customExercisesURL = customExercisesURL
        let catalog = Self.loadBuiltInExercises(builtInExercisesURL: builtInExercisesURL)
        builtInExercises = catalog
        catalogSecondaryIDs = ExerciseCatalogMetadata.secondaryIDs(
            in: catalog, duplicates: Self.loadCatalogDuplicates(builtInExercisesURL: builtInExercisesURL)
        )
        let preferredAliases = Self.loadPreferredAliases(builtInExercisesURL: builtInExercisesURL)
        let metadata = ExerciseCatalogMetadata(exercises: catalog, preferredAliases: preferredAliases)
        catalogMetadata = metadata
        customExercises = Self.loadCustomExercises(customExercisesURL: customExercisesURL).map(metadata.enriching)
        assert(!customExercises.contains { !$0.isCustom }, "Decoded custom exercise that is not custom.")
        rebuildExerciseLookup()
        hiddenExercisesObserver = NotificationCenter.default.publisher(
            for: UserDefaults.hiddenExercisesDidChangeNotification, object: userDefaults)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }
    
    private static func loadBuiltInExercises(builtInExercisesURL: URL?) -> [Exercise] {
        guard let builtInExercisesURL = builtInExercisesURL else { fatalError("Built in exercises URL invalid") }
        do {
            let legacy = try JSONDecoder().decode([Exercise].self, from: Data(contentsOf: builtInExercisesURL))
            let exercises = ExerciseCatalogMetadata.updatingCatalog(
                legacy, with: loadMetadataTemplates(builtInExercisesURL: builtInExercisesURL)
            )
            let illustrated = ExerciseCatalogMetadata.addingLegacyArt(
                loadLegacyArt(builtInExercisesURL: builtInExercisesURL), to: exercises
            )
            let aliases = loadPreferredAliases(builtInExercisesURL: builtInExercisesURL)
            return ExerciseCatalogMetadata.addingAliases(aliases, to: illustrated)
        } catch {
            fatalError("Error decoding built in exercises: \(error.localizedDescription)")
        }
    }
    
    private static func loadCustomExercises(customExercisesURL: URL?) -> [Exercise] {
        guard let url = customExercisesURL else { return [] }
        do {
            return try JSONDecoder().decode([Exercise].self, from: Data(contentsOf: url))
        } catch {
            // try to migrate the exercises to the new UUID format
            let success = Self.migrateCustomExercises(customExercisesURL: url)
            guard success else { return [] }
            os_log("Successfully migrated custom exercises", log: .migration, type: .info)
            return (try? JSONDecoder().decode([Exercise].self, from: Data(contentsOf: url))) ?? []
        }
    }

    /// OpenGym text updates the main library while retained legacy definitions
    /// and the converter's stable UUIDs preserve all workout relationships.
    private static func loadMetadataTemplates(builtInExercisesURL: URL?) -> [Exercise] {
        guard let url = builtInExercisesURL?.deletingLastPathComponent()
            .appendingPathComponent("opengym-text-templates.json"),
              let data = try? Data(contentsOf: url),
              let templates = try? JSONDecoder().decode([Exercise].self, from: data) else { return [] }
        return templates
    }

    private static func loadLegacyArt(builtInExercisesURL: URL?) -> [ExerciseCatalogMetadata.LegacyArt] {
        guard let url = builtInExercisesURL?.deletingLastPathComponent()
            .appendingPathComponent("legacy-art.json"),
              let data = try? Data(contentsOf: url),
              let art = try? JSONDecoder().decode([ExerciseCatalogMetadata.LegacyArt].self, from: data) else { return [] }
        return art
    }

    private static func loadCatalogDuplicates(builtInExercisesURL: URL?) -> [ExerciseCatalogMetadata.CatalogDuplicate] {
        guard let url = builtInExercisesURL?.deletingLastPathComponent()
            .appendingPathComponent("catalog-duplicates.json"),
              let data = try? Data(contentsOf: url),
              let duplicates = try? JSONDecoder().decode([ExerciseCatalogMetadata.CatalogDuplicate].self, from: data) else { return [] }
        return duplicates
    }

    private static func loadPreferredAliases(builtInExercisesURL: URL?) -> [String: UUID] {
        guard let root = builtInExercisesURL?.deletingLastPathComponent() else { return [:] }
        var result: [String: UUID] = [:]
        for name in ["hevy-template-aliases.json", "hevy-aliases.json"] {
            guard let data = try? Data(contentsOf: root.appendingPathComponent(name)),
                  let aliases = try? JSONDecoder().decode([String: UUID].self, from: data) else { continue }
            result.merge(aliases) { _, reviewedExisting in reviewedExisting }
        }
        return result
    }
}

// MARK: - Exercise recency
extension ExerciseStore {
    /// Call on the main queue once the history store is loaded. Repeated calls
    /// with the same store are cheap, including when presenting a picker.
    public func observeWorkoutHistory(in context: NSManagedObjectContext) {
        precondition(Thread.isMainThread)
        guard let coordinator = context.persistentStoreCoordinator,
              recencyContext?.persistentStoreCoordinator !== coordinator else { return }

        let reader = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        reader.persistentStoreCoordinator = coordinator
        reader.undoManager = nil
        recencyContext = reader
        recencyRefreshRunning = false
        recencyRefreshPending = false

        recencyObserver = NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)
            .filter { notification in
                // Inspect managed objects on the saving context's queue, before
                // hopping to main. Imports may save from a background context.
                guard let savedContext = notification.object as? NSManagedObjectContext,
                      savedContext.persistentStoreCoordinator === coordinator else { return false }
                return [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey].contains { key in
                    (notification.userInfo?[key] as? Set<NSManagedObject>)?.contains {
                        $0 is Workout || $0 is WorkoutExercise || $0 is WorkoutSet || $0 is WorkoutRoutineExercise
                    } == true
                }
            }
            .map { _ in () }
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.refreshExerciseRecency() }
        refreshExerciseRecency()
    }

    private func refreshExerciseRecency() {
        guard let context = recencyContext else { return }
        guard !recencyRefreshRunning else {
            recencyRefreshPending = true
            return
        }
        recencyRefreshRunning = true
        context.perform { [weak self] in
            context.reset()
            let result = Result {
                (dates: try ExerciseRecency.latestDates(in: context),
                 referenced: try ExerciseRecency.workoutReferencedIDs(in: context))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.recencyContext === context else { return }
                self.recencyRefreshRunning = false
                switch result {
                case .success(let snapshot):
                    if self.lastPerformedDates != snapshot.dates { self.lastPerformedDates = snapshot.dates }
                    if self.workoutReferencedExerciseIDs != snapshot.referenced {
                        self.workoutReferencedExerciseIDs = snapshot.referenced
                    }
                case .failure(let error):
                    // Keep the previous snapshot if the store is temporarily unavailable.
                    os_log("Could not refresh exercise recency: %{public}@", type: .error, error.localizedDescription)
                }
                if self.recencyRefreshPending {
                    self.recencyRefreshPending = false
                    self.refreshExerciseRecency()
                }
            }
        }
    }

    public func orderedByRecency(_ exercises: [Exercise]) -> [Exercise] {
        ExerciseRecency.ordered(exercises, dates: lastPerformedDates)
    }
}

public enum ExerciseRecency {
    /// One scalar fetch for the entire history, with no managed-object faults or
    /// per-exercise queries. A qualifying workout has at least one completed set;
    /// every exercise appearing in it counts, including an entry with no sets.
    /// importSource is deliberately unrestricted (Hevy and Iron use the same rule).
    public static func latestDates(in context: NSManagedObjectContext) throws -> [UUID: Date] {
        let request = NSFetchRequest<NSDictionary>(entityName: "WorkoutExercise")
        request.resultType = .dictionaryResultType
        request.includesPendingChanges = false
        request.predicate = NSPredicate(format: """
            workout.isCurrentWorkout == NO AND
            SUBQUERY(workout.workoutExercises, $entry, ANY $entry.workoutSets.isCompleted == YES).@count > 0
            """)
        let start = NSExpressionDescription()
        start.name = "start"
        start.expression = NSExpression(forKeyPath: "workout.start")
        start.expressionResultType = .dateAttributeType
        let end = NSExpressionDescription()
        end.name = "end"
        end.expression = NSExpression(forKeyPath: "workout.end")
        end.expressionResultType = .dateAttributeType
        request.propertiesToFetch = ["exerciseUuid", start, end]

        var dates: [UUID: Date] = [:]
        for row in try context.fetch(request) {
            guard let uuid = row["exerciseUuid"] as? UUID,
                  let date = (row["start"] as? Date) ?? (row["end"] as? Date) else { continue }
            dates[uuid] = max(dates[uuid] ?? date, date)
        }
        return dates
    }

    /// Scalar fetches of every exercise in any workout or saved workout, so the
    /// catalog cleanup can never take one of them out of a default list.
    public static func workoutReferencedIDs(in context: NSManagedObjectContext) throws -> Set<UUID> {
        var ids = Set<UUID>()
        for entity in ["WorkoutExercise", "WorkoutRoutineExercise"] {
            let request = NSFetchRequest<NSDictionary>(entityName: entity)
            request.resultType = .dictionaryResultType
            request.includesPendingChanges = false
            request.returnsDistinctResults = true
            request.propertiesToFetch = ["exerciseUuid"]
            for row in try context.fetch(request) {
                if let uuid = row["exerciseUuid"] as? UUID { ids.insert(uuid) }
            }
        }
        return ids
    }

    /// Keep the caller's existing order (including search relevance) for unseen
    /// exercises. Recency is always primary; equal dates are ordered by title.
    public static func ordered(_ exercises: [Exercise], dates: [UUID: Date]) -> [Exercise] {
        exercises.enumerated().sorted { lhs, rhs in
            switch (dates[lhs.element.uuid], dates[rhs.element.uuid]) {
            case let (left?, right?):
                if left != right { return left > right }
                let comparison = lhs.element.title.localizedCaseInsensitiveCompare(rhs.element.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.element.uuid.uuidString < rhs.element.uuid.uuidString
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}

// MARK: - Hidden Exercises
extension ExerciseStore {
    public func show(exercise: Exercise) {
        assert(!exercise.isCustom, "Makes no sense to show custom exercise.")
        self.objectWillChange.send()
        userDefaults.hiddenExerciseUuids.removeAll { $0 == exercise.uuid }
    }
    
    public func hide(exercise: Exercise) {
        assert(!exercise.isCustom, "Makes no sense to hide custom exercise.")
        guard !isHidden(exercise: exercise) else { return }
        self.objectWillChange.send()
        userDefaults.hiddenExerciseUuids.append(exercise.uuid)
    }
    
    public func isHidden(exercise: Exercise) -> Bool {
        userDefaults.hiddenExerciseUuids.contains(exercise.uuid)
    }
}

// MARK: - Split
extension ExerciseStore {
    public static func splitIntoMuscleGroups(exercises: [Exercise]) -> [ExerciseGroup] {
        var groups = [ExerciseGroup]()
        var nextIndex = 0
        let exercises = exercises.sorted { (a, b) -> Bool in
            a.muscleGroup < b.muscleGroup
        }
        while (exercises.count > nextIndex) {
            let groupName = exercises[nextIndex].muscleGroup
            var muscleGroup = exercises.filter({ (exercise) -> Bool in
                exercise.muscleGroup == groupName
            })
            
            nextIndex = exercises.firstIndex(where: { (exercise) -> Bool in
                exercise.uuid == muscleGroup.last!.uuid
            })! + 1
            
            // do this after nextIndex is set
            muscleGroup = muscleGroup.sorted(by: { (a, b) -> Bool in
                a.title < b.title
            })
            groups.append(ExerciseGroup(title: groupName, exercises: muscleGroup))
        }
        return groups
    }
}

// MARK: - Find
extension ExerciseStore {
    public func find(with uuid: UUID) -> Exercise? {
        Self.find(in: exercises, with: uuid)
    }
    
    public static func find(in exercises: [Exercise], with uuid: UUID?) -> Exercise? {
        guard let uuid = uuid else { return nil }
        return exercises.first { $0.uuid == uuid }
    }
}

// MARK: - Filter
extension ExerciseStore {
    private static func titleMatchesFilter(title: String, filter: String) -> Bool {
        for s in filter.split(separator: " ") {
            if !title.lowercased().contains(s) {
                return false
            }
        }
        return true
    }

    public static func filter(exercises: [Exercise], using filter: String) -> [Exercise] {
        let filter = filter.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !filter.isEmpty else { return exercises }
        
        return exercises.filter { exercise in
            for title in [exercise.title] + exercise.alias {
                if titleMatchesFilter(title: title, filter: filter) {
                    return true
                }
            }
            return false
        }
    }
    
    public static func filter(exerciseGroups: [ExerciseGroup], using filter: String) -> [ExerciseGroup] {
        exerciseGroups
            .map { ExerciseGroup(title: $0.title, exercises: Self.filter(exercises: $0.exercises, using: filter)) }
            .filter { !$0.exercises.isEmpty }
    }
}

// MARK: - Custom Exercises
extension ExerciseStore {
    public struct CustomExerciseDefinition {
        public let title: String
        public let type: Exercise.ExerciseType

        public init(title: String, type: Exercise.ExerciseType) {
            self.title = title
            self.type = type
        }
    }

    public struct StagedCustomExerciseReplacement {
        fileprivate let previousData: Data?
        fileprivate let replacementData: Data
        fileprivate let replacementExercises: [Exercise]

        public var exercises: [Exercise] { replacementExercises }
    }

    public enum CustomExerciseMutationError: LocalizedError {
        case invalidTitle
        case duplicateTitle(String)
        case storageUnavailable
        case exerciseNotFound
        case couldNotRead(Error)
        case couldNotWrite(Error)

        public var errorDescription: String? {
            switch self {
            case .invalidTitle:
                return "Enter a name for the exercise."
            case .duplicateTitle(let title):
                return "An exercise named \(title) already exists."
            case .storageUnavailable:
                return "Iron could not access custom-exercise storage."
            case .exerciseNotFound:
                return "This custom exercise no longer exists."
            case .couldNotRead(let error):
                return "Iron could not read your custom exercises: \(error.localizedDescription)"
            case .couldNotWrite(let error):
                return "Iron could not save the custom exercise: \(error.localizedDescription)"
            }
        }
    }

    /// Prepares a single replacement without touching disk or publishing it.
    /// Reading the original bytes first ensures corrupt existing storage fails
    /// closed and can never be overwritten by an import.
    public func stageCreatingCustomExercises(
        _ definitions: [CustomExerciseDefinition]
    ) throws -> StagedCustomExerciseReplacement? {
        guard !definitions.isEmpty else { return nil }
        guard let url = customExercisesURL else {
            throw CustomExerciseMutationError.storageUnavailable
        }

        let previousData: Data?
        let existingCustomExercises: [Exercise]
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                previousData = try Data(contentsOf: url)
                existingCustomExercises = try JSONDecoder().decode([Exercise].self, from: previousData!)
            } catch {
                throw CustomExerciseMutationError.couldNotRead(error)
            }
        } else {
            previousData = nil
            existingCustomExercises = []
        }

        var allExercises = builtInExercises + existingCustomExercises
        var replacements = existingCustomExercises
        for definition in definitions {
            let title = definition.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw CustomExerciseMutationError.invalidTitle }
            guard !allExercises.contains(where: {
                $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare(title) == .orderedSame
            }) else {
                throw CustomExerciseMutationError.duplicateTitle(title)
            }
            let exercise = Exercise(
                uuid: UUID(),
                everkineticId: Exercise.customEverkineticId,
                title: title,
                alias: [],
                description: nil,
                primaryMuscle: [],
                secondaryMuscle: [],
                equipment: definition.type.equipment.map { [$0] } ?? [],
                steps: [],
                tips: [],
                references: [],
                pdfPaths: []
            )
            replacements.append(exercise)
            allExercises.append(exercise)
        }

        do {
            return StagedCustomExerciseReplacement(
                previousData: previousData,
                replacementData: try JSONEncoder().encode(replacements),
                replacementExercises: replacements
            )
        } catch {
            throw CustomExerciseMutationError.couldNotWrite(error)
        }
    }

    public func write(_ replacement: StagedCustomExerciseReplacement) throws {
        guard let url = customExercisesURL else {
            throw CustomExerciseMutationError.storageUnavailable
        }
        do {
            try replacement.replacementData.write(to: url, options: .atomic)
        } catch {
            throw CustomExerciseMutationError.couldNotWrite(error)
        }
    }

    public func publish(_ replacement: StagedCustomExerciseReplacement) {
        customExercises = replacement.replacementExercises.map(catalogMetadata.enriching)
    }

    public func rollback(_ replacement: StagedCustomExerciseReplacement) throws {
        guard let url = customExercisesURL else {
            throw CustomExerciseMutationError.storageUnavailable
        }
        do {
            if let previousData = replacement.previousData {
                try previousData.write(to: url, options: .atomic)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            throw CustomExerciseMutationError.couldNotWrite(error)
        }
    }

    @discardableResult
    public func createCustomExercise(
        title: String,
        description: String?,
        primaryMuscle: [String],
        secondaryMuscle: [String],
        type: Exercise.ExerciseType,
        steps: [String] = [],
        tips: [String] = []
    ) throws -> Exercise {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CustomExerciseMutationError.invalidTitle }
        guard !exercises.contains(where: {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(title) == .orderedSame
        }) else {
            throw CustomExerciseMutationError.duplicateTitle(title)
        }
        
        var description = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = description, d.isEmpty {
            description = nil
        }
        
        var customExercises = try loadCustomExercisesForMutation()
        let createdExercise = Exercise(
            uuid: UUID(),
            everkineticId: Exercise.customEverkineticId,
            title: title,
            alias: [],
            description: description,
            primaryMuscle: primaryMuscle,
            secondaryMuscle: secondaryMuscle,
            equipment: type.equipment.map { [$0] } ?? [],
            steps: sanitizedInstructionItems(steps),
            tips: sanitizedInstructionItems(tips),
            references: [],
            pdfPaths: []
        )
        customExercises.append(createdExercise)
        try persistCustomExercises(customExercises)
        return createdExercise
    }

    @discardableResult
    public func updateCustomExercise(
        with uuid: UUID,
        title: String,
        description: String?,
        primaryMuscle: [String],
        secondaryMuscle: [String],
        type: Exercise.ExerciseType,
        steps: [String] = [],
        tips: [String] = []
    ) throws -> Exercise {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CustomExerciseMutationError.invalidTitle }
        guard !exercises.contains(where: {
            $0.uuid != uuid &&
                $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(title) == .orderedSame
        }) else {
            throw CustomExerciseMutationError.duplicateTitle(title)
        }
        
        var description = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = description, d.isEmpty {
            description = nil
        }
        
        var customExercises = try loadCustomExercisesForMutation()
        guard let index = customExercises.firstIndex(where: { $0.uuid == uuid }) else {
            throw CustomExerciseMutationError.exerciseNotFound
        }
        let existingExercise = customExercises[index]
        let updatedExercise = Exercise(
            uuid: uuid,
            everkineticId: existingExercise.everkineticId,
            title: title,
            alias: existingExercise.alias,
            description: description,
            primaryMuscle: primaryMuscle,
            secondaryMuscle: secondaryMuscle,
            equipment: type.equipment.map { [$0] } ?? [],
            steps: sanitizedInstructionItems(steps),
            tips: sanitizedInstructionItems(tips),
            references: existingExercise.references,
            pdfPaths: existingExercise.pdfPaths,
            imageFilename: existingExercise.imageFilename,
            animationFilename: existingExercise.animationFilename
        )
        customExercises[index] = updatedExercise
        try persistCustomExercises(customExercises)
        return updatedExercise
    }

    private func loadCustomExercisesForMutation() throws -> [Exercise] {
        guard let url = customExercisesURL else {
            throw CustomExerciseMutationError.storageUnavailable
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            return try JSONDecoder().decode([Exercise].self, from: Data(contentsOf: url))
        } catch {
            throw CustomExerciseMutationError.couldNotRead(error)
        }
    }

    private func persistCustomExercises(_ exercises: [Exercise]) throws {
        guard let url = customExercisesURL else {
            throw CustomExerciseMutationError.storageUnavailable
        }
        do {
            try JSONEncoder().encode(exercises).write(to: url, options: .atomic)
            customExercises = try JSONDecoder().decode([Exercise].self, from: Data(contentsOf: url)).map(catalogMetadata.enriching)
        } catch {
            throw CustomExerciseMutationError.couldNotWrite(error)
        }
    }

    private func sanitizedInstructionItems(_ items: [String]) -> [String] {
        items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    
    @discardableResult
    public func deleteCustomExercise(with uuid: UUID) throws -> Exercise {
        var customExercises = try loadCustomExercisesForMutation()
        guard let index = customExercises.firstIndex(where: { $0.uuid == uuid }) else {
            throw CustomExerciseMutationError.exerciseNotFound
        }
        let deletedExercise = customExercises.remove(at: index)
        try persistCustomExercises(customExercises)
        return deletedExercise
    }
}

// MARK: - Custom Exercise Migration
extension ExerciseStore {
    private static func migrateCustomExercises(customExercisesURL: URL) -> Bool { // returns true if a migration was made successfully
        do { _ = try JSONDecoder().decode([Exercise].self, from: Data(contentsOf: customExercisesURL)) } catch {
            let oldExercises: [ExerciseWithOldId]
            do { oldExercises = try JSONDecoder().decode([ExerciseWithOldId].self, from: Data(contentsOf: customExercisesURL)) } catch { return false }
            let newExercises = oldExercises
                .map {
                    // NOTE: don't overwrite id here, because we still need it in the Core Data migration
                    Exercise(uuid: UUID(), everkineticId: $0.id, title: $0.title, alias: [], description: $0.primer, primaryMuscle: $0.primary, secondaryMuscle: $0.secondary, equipment: $0.equipment, steps: [], tips: [], references: [], pdfPaths: [])
                }
            do { try JSONEncoder().encode(newExercises).write(to: customExercisesURL, options: .atomic) } catch { return false }
            return true
        }
        // no migration needed
        return false
    }
    
    struct ExerciseWithOldId: Codable {
        let id: Int // the old id (before we switched to UUID)
        let title: String
        let primer: String?
        let primary: [String]
        let secondary: [String]
        let equipment: [String]
    }
}

// MARK: - Custom Exercise Restore
extension ExerciseStore {
    enum RestoreError: Error {
        case customExerciseURLIsNil
    }
    public func replaceCustomExercises(with customExercises: [Exercise]) throws {
        guard let url = customExercisesURL else { throw RestoreError.customExerciseURLIsNil }
        try JSONEncoder().encode(customExercises).write(to: url, options: .atomic)
        self.customExercises = try JSONDecoder().decode([Exercise].self, from: Data(contentsOf: url)).map(catalogMetadata.enriching)
    }
}
