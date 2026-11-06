import Foundation

/// Curated name equivalences, never a fuzzy merge of workout history.
public struct ExerciseCatalogMetadata {
    private let uniqueNames: [String: Exercise]

    public init(exercises: [Exercise], preferredAliases: [String: UUID] = [:]) {
        var candidates: [String: [Exercise]] = [:]
        for exercise in exercises {
            for name in [exercise.title, exercise.originalTitle] + exercise.alias {
                let key = Self.nameKey(name)
                guard !key.isEmpty else { continue }
                if !(candidates[key] ?? []).contains(where: { $0.uuid == exercise.uuid }) {
                    candidates[key, default: []].append(exercise)
                }
            }
        }
        var names = candidates.compactMapValues { $0.count == 1 ? $0.first : nil }
        // Reviewed import mappings take precedence over coincidental duplicate
        // catalog names. Templates may improve text while retaining the same UUID.
        let byID = exercises.reduce(into: [UUID: Exercise]()) { $0[$1.uuid] = $1 }
        for (name, id) in preferredAliases {
            if let exercise = byID[id] { names[Self.nameKey(name)] = exercise }
        }
        uniqueNames = names
    }

    public static func addingAliases(_ aliases: [String: UUID], to exercises: [Exercise]) -> [Exercise] {
        let byID = Dictionary(grouping: aliases.keys, by: { aliases[$0]! })
        return exercises.map { exercise in
            guard let names = byID[exercise.uuid] else { return exercise }
            return copy(exercise, aliases: Array(Set(exercise.alias + names)).sorted())
        }
    }

    /// Format only the complete, merged built-in catalog, in memory. Collision
    /// checks include unchanged titles; every member of a collision keeps its name.
    public static func usingDisplayTitles(_ exercises: [Exercise]) -> [Exercise] {
        let proposed = exercises.map { exercise in
            exercise.isCustom ? exercise.title : displayTitle(for: exercise)
        }
        let builtInIndices = exercises.indices.filter { !exercises[$0].isCustom }
        let groups = Dictionary(grouping: builtInIndices) { titleKey(proposed[$0]) }
        let collisions = Set(groups.filter { $0.value.count > 1 }.map(\.key))

        return exercises.enumerated().map { index, exercise in
            let title = proposed[index]
            guard !exercise.isCustom, title != exercise.title,
                  !collisions.contains(titleKey(title)) else { return exercise }
            let aliases = exercise.alias.contains(exercise.originalTitle)
                ? exercise.alias : exercise.alias + [exercise.originalTitle]
            return copy(exercise, title: title, aliases: aliases)
        }
    }

    private static func displayTitle(for exercise: Exercise) -> String {
        var title = exercise.title
        for suffix in [" (male)", " (female)"] where title.lowercased().hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count))
            break
        }
        guard !title.contains(":") else { return title }

        let equipment = Set(exercise.equipment.map { $0.lowercased() })
        for rule in displayEquipmentPrefixes where !equipment.isDisjoint(with: rule.equipment) {
            guard let range = title.range(of: rule.prefix + " ", options: [.anchored, .caseInsensitive],
                                          locale: Locale(identifier: "en_US_POSIX")) else { continue }
            let movement = String(title[range.upperBound...])
            guard !movement.isEmpty else { continue }
            return movement + ": " + rule.suffix
        }
        return title
    }

    // Deliberate allowlist: equipment such as "weighted", "assisted", "roller"
    // and machine/cardio names must never become display-name suffixes.
    // Keep these rules in sync with scripts/generate_watch_catalogue.py.
    private static let displayEquipmentPrefixes: [(prefix: String, suffix: String, equipment: Set<String>)] = {
        let families: [(prefixes: [String], suffix: String, equipment: Set<String>)] = [
            (["Barbell", "Olympic Barbell"], "Barbell", ["barbell", "olympic barbell"]),
            (["EZ Barbell", "EZ Bar", "EZ Curl Bar"], "EZ Bar", ["ez barbell", "ez-curl-bar", "ez bar", "ez curl bar"]),
            (["Dumbbell"], "Dumbbell", ["dumbbell"]),
            (["Cable"], "Cable", ["cable"]),
            (["Kettlebell"], "Kettlebell", ["kettlebell"]),
            (["Resistance Band", "Band"], "Band", ["band", "resistance band", "exercise band"]),
            (["Smith Machine", "Smith"], "Smith Machine", ["smith machine"]),
            (["Trap Bar"], "Trap Bar", ["trap bar"]),
            (["Landmine"], "Landmine", ["landmine"])
        ]
        return families.flatMap { family in
            family.prefixes.map { (prefix: $0, suffix: family.suffix, equipment: family.equipment) }
        }.sorted { $0.prefix.count > $1.prefix.count }
    }()

    private static func titleKey(_ title: String) -> String {
        title.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Update known records in place and append new canonical definitions. Legacy
    /// exercises absent upstream stay available to every existing workout UUID.
    public static func updatingCatalog(_ exercises: [Exercise], with templates: [Exercise]) -> [Exercise] {
        let updates = Dictionary(uniqueKeysWithValues: templates.map { ($0.uuid, $0) })
        let existingIDs = Set(exercises.map(\.uuid))
        return exercises.map { updates[$0.uuid] ?? $0 }
            + templates.filter { !existingIDs.contains($0.uuid) }
    }

    /// The reviewed picture of the same movement, from `legacy-art.json`.
    public struct LegacyArt: Decodable {
        public let uuid: UUID
        public let image: String
        public let animation: String
    }

    /// A reviewed duplicate from `catalog-duplicates.json`, and the entry to list instead.
    public struct CatalogDuplicate: Decodable {
        public let uuid: UUID
        public let keep: UUID
    }

    /// Built-ins the default lists leave out: no picture at all, or a reviewed duplicate
    /// of an entry that still exists. Search and "show more" always reach them.
    public static func secondaryIDs(in catalog: [Exercise], duplicates: [CatalogDuplicate]) -> Set<UUID> {
        let known = Set(catalog.map(\.uuid))
        let withoutPicture = catalog.filter {
            $0.imageFilename == nil && $0.animationFilename == nil && $0.pdfPaths.isEmpty
        }
        return Set(withoutPicture.map(\.uuid))
            .union(duplicates.filter { known.contains($0.uuid) && known.contains($0.keep) }.map(\.uuid))
    }

    /// Legacy exercises keep their identity and history but show the same
    /// illustrated set as the rest of the library. Existing art always wins.
    public static func addingLegacyArt(_ art: [LegacyArt], to exercises: [Exercise]) -> [Exercise] {
        let byID = Dictionary(art.map { ($0.uuid, $0) }) { first, _ in first }
        return exercises.map { exercise in
            guard let art = byID[exercise.uuid],
                  exercise.imageFilename == nil, exercise.animationFilename == nil else { return exercise }
            return Exercise(
                uuid: exercise.uuid, everkineticId: exercise.everkineticId,
                title: exercise.title, alias: exercise.alias, description: exercise.description,
                primaryMuscle: exercise.primaryMuscle, secondaryMuscle: exercise.secondaryMuscle,
                equipment: exercise.equipment, steps: exercise.steps, tips: exercise.tips,
                references: exercise.references, pdfPaths: exercise.pdfPaths,
                imageFilename: art.image, animationFilename: art.animation,
                originalTitle: exercise.originalTitle
            )
        }
    }

    /// Enrich old empty import definitions in memory. Keep the user's UUID/name and
    /// all workout relationships; do not rewrite the custom file or merge histories.
    public func enriching(_ exercise: Exercise) -> Exercise {
        guard exercise.isCustom,
              exercise.primaryMuscle.isEmpty, exercise.secondaryMuscle.isEmpty,
              exercise.pdfPaths.isEmpty,
              exercise.imageFilename == nil, exercise.animationFilename == nil,
              let template = uniqueNames[Self.nameKey(exercise.title)] else { return exercise }

        // Respect a custom equipment choice that contradicts the catalog template.
        let equipment = Set(template.equipment.map(Self.nameKey))
        guard exercise.equipment.allSatisfy({ equipment.contains(Self.nameKey($0)) }) else { return exercise }
        return Exercise(
            uuid: exercise.uuid, everkineticId: exercise.everkineticId,
            title: exercise.title, alias: exercise.alias,
            description: exercise.description ?? template.description,
            primaryMuscle: template.primaryMuscle, secondaryMuscle: template.secondaryMuscle,
            equipment: exercise.equipment.isEmpty ? template.equipment : exercise.equipment,
            steps: exercise.steps.isEmpty ? template.steps : exercise.steps,
            tips: exercise.tips.isEmpty ? template.tips : exercise.tips,
            references: exercise.references.isEmpty ? template.references : exercise.references,
            pdfPaths: template.pdfPaths,
            imageFilename: template.imageFilename, animationFilename: template.animationFilename,
            originalTitle: exercise.originalTitle
        )
    }

    public static func nameKey(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func copy(_ exercise: Exercise, title: String? = nil, aliases: [String]) -> Exercise {
        Exercise(
            uuid: exercise.uuid, everkineticId: exercise.everkineticId,
            title: title ?? exercise.title, alias: aliases, description: exercise.description,
            primaryMuscle: exercise.primaryMuscle, secondaryMuscle: exercise.secondaryMuscle,
            equipment: exercise.equipment, steps: exercise.steps, tips: exercise.tips,
            references: exercise.references, pdfPaths: exercise.pdfPaths,
            imageFilename: exercise.imageFilename, animationFilename: exercise.animationFilename,
            originalTitle: exercise.originalTitle
        )
    }
}
