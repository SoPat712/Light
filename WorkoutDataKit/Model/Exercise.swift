//
//  Exercise.swift
//  Rhino Fit
//
//  Created by Karim Abou Zeid on 15.01.18.
//  Copyright © 2018 Karim Abou Zeid Software. All rights reserved.
//

import Foundation

private final class ExerciseMediaBundleToken: NSObject {}

public struct Exercise: Hashable {
    public static let exerciseMediaProvider = "ExerciseDB V1"
    public static let mediaAttribution = "© Gym Visual — gymvisual.com"

    public let uuid: UUID // we use this for actually identifying the exercise
    public let everkineticId: Int // this is the everkinetic exercise id or 10000 if it's a custom exercise
    public let title: String
    /// The source name, retained when the built-in catalog changes its display title.
    /// Custom exercises always keep the title supplied by the person who created them.
    public let originalTitle: String
    public let alias: [String]
    public let description: String? // primer
    public let primaryMuscle: [String] // primary
    public let secondaryMuscle: [String] // secondary
    public let equipment: [String]
    public let steps: [String]
    public let tips: [String]
    public let references: [String]
    public let pdfPaths: [String]
    public let imageFilename: String?
    public let animationFilename: String?

    public init(uuid: UUID,
                everkineticId: Int,
                title: String,
                alias: [String],
                description: String?,
                primaryMuscle: [String],
                secondaryMuscle: [String],
                equipment: [String],
                steps: [String],
                tips: [String],
                references: [String],
                pdfPaths: [String],
                imageFilename: String? = nil,
                animationFilename: String? = nil,
                originalTitle: String? = nil) {
        self.uuid = uuid
        self.everkineticId = everkineticId
        self.title = title
        self.originalTitle = originalTitle ?? title
        self.alias = alias
        self.description = description
        self.primaryMuscle = primaryMuscle
        self.secondaryMuscle = secondaryMuscle
        self.equipment = equipment
        self.steps = steps
        self.tips = tips
        self.references = references
        self.pdfPaths = pdfPaths
        self.imageFilename = imageFilename
        self.animationFilename = animationFilename
    }

    public var imageURL: URL? {
        // A separately licensed bundled still may be supplied without changing
        // exercise identity. Otherwise retain the existing free-provider GIF.
        if let imageFilename,
           imageFilename.hasPrefix("catalogue/still/"),
           !imageFilename.split(separator: "/").contains("..") {
            let url = Bundle(for: ExerciseMediaBundleToken.self).bundleURL
                .appendingPathComponent("everkinetic-data", isDirectory: true)
                .appendingPathComponent(imageFilename)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return Self.mediaURL(filename: animationFilename ?? imageFilename)
    }

    public var animationURL: URL? {
        Self.mediaURL(filename: animationFilename)
    }

    private static func mediaURL(filename: String?) -> URL? {
        guard let filename = filename, !filename.isEmpty else { return nil }
        let basename = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        guard let separator = basename.firstIndex(of: "-") else { return nil }
        let exerciseID = String(basename[basename.index(after: separator)...])
        guard !exerciseID.isEmpty else { return nil }
        return URL(string: "https://static.exercisedb.dev/media/\(exerciseID).gif")
    }
}

// MARK: - Muscle Names
extension Exercise {
    public var primaryMuscleCommonName: [String] {
        primaryMuscle.map { Self.commonMuscleName(for: $0) ?? $0 }.uniqed()
    }
    
    public var secondaryMuscleCommonName: [String] {
        secondaryMuscle.map { Self.commonMuscleName(for: $0) ?? $0 }.uniqed()
    }
    
    public var muscleGroup: String {
        guard let muscle = primaryMuscle.first else { return "other" }
        return Self.muscleGroup(for: muscle) ?? "other"
    }
    
    public static var muscleNames: [String] {
        commonMuscleNames.keys.map { $0 }
    }
    
    public static func commonMuscleName(for muscle: String) -> String? {
        commonMuscleNames[muscle]
    }
    
    public static func muscleGroup(for muscle: String) -> String? {
        muscleGroupNames[muscle]
    }
    
    private static var commonMuscleNames: [String : String] = [
        "abdominals": "abdominals",
        "abs": "abdominals",
        "abductors": "abductors",
        "adductors": "adductors",
        "biceps brachii": "biceps",
        "biceps": "biceps",
        "deltoid": "shoulders",
        "deltoids": "shoulders",
        "delts": "shoulders",
        "erector spinae": "lower back",
        "spine": "lower back",
        "forearms": "forearms",
        "gastrocnemius": "calves",
        "calves": "calves",
        "soleus": "calves",
        "glutaeus maximus": "glutes",
        "glutes": "glutes",
        "ischiocrural muscles": "hamstrings",
        "hamstrings": "hamstrings",
        "latissimus dorsi": "latissimus",
        "lats": "latissimus",
        "levator scapulae": "trapezius",
        "obliques": "obliques",
        "pectoralis major": "chest",
        "pectorals": "chest",
        "quadriceps": "quadriceps",
        "quads": "quadriceps",
        "serratus anterior": "serratus",
        "trapezius": "trapezius",
        "traps": "trapezius",
        "triceps brachii": "triceps",
        "triceps": "triceps",
        "upper back": "upper back",
        "cardiovascular system": "cardio"
    ]
    
    private static var muscleGroupNames: [String : String] = [
        // abs
        "abdominals": "abdominals",
        "abs": "abdominals",
        "obliques": "abdominals",
        // arms
        "biceps brachii": "arms",
        "biceps": "arms",
        "triceps brachii": "arms",
        "triceps": "arms",
        "forearms": "arms",
        // shoulders
        "deltoid": "shoulders",
        "deltoids": "shoulders",
        "delts": "shoulders",
        // back
        "erector spinae": "back",
        "spine": "back",
        "latissimus dorsi": "back",
        "lats": "back",
        "trapezius": "back",
        "traps": "back",
        "upper back": "back",
        "levator scapulae": "back",
        // legs
        "gastrocnemius": "legs",
        "calves": "legs",
        "soleus": "legs",
        "glutaeus maximus": "legs",
        "glutes": "legs",
        "ischiocrural muscles": "legs",
        "hamstrings": "legs",
        "quadriceps": "legs",
        "quads": "legs",
        "abductors": "legs",
        "adductors": "legs",
        // chest
        "pectoralis major": "chest",
        "pectorals": "chest",
        "serratus anterior": "chest",
        "cardiovascular system": "cardio"
    ]
}

// MARK: - Exercise Type
extension Exercise {
    public enum ExerciseType: CaseIterable {
        case barbell
        case dumbbell
        case other
        
        public var title: String {
            switch self {
            case .barbell:
                return "barbell based"
            case .dumbbell:
                return "dumbbell based"
            case .other:
                return "other"
            }
        }
        
        var equipment: String? {
            switch self {
            case .barbell:
                return "barbell"
            case .dumbbell:
                return "dumbbell"
            case .other:
                return nil
            }
        }
    }
    
    public var type: ExerciseType {
        if equipment.contains(where: { $0.contains("barbell") || $0 == "trap bar" || $0 == "ez bar" }) {
            return .barbell
        }
        if equipment.contains(where: { $0.contains("dumbbell") }) {
            return .dumbbell
        }
        return .other
    }
}

// MARK: - Custom Exercise
extension Exercise {
    static let customEverkineticId = 10000
    
    private static func isCustom(everkineticId: Int) -> Bool {
        everkineticId >= Exercise.customEverkineticId
    }
    
    public var isCustom: Bool {
        Self.isCustom(everkineticId: everkineticId)
    }
}

// MARK: - Codable
extension Exercise: Codable {
    private enum CodingKeys: String, CodingKey {
        case uuid
        case id
//        case name
        case title
        case alias
        case primer
//        case type
        case primary
        case secondary
        case equipment
        case steps
        case tips
        case references
        case pdf
        case image
        case animation
    }
    
    // MARK: Decodable
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let uuid = try container.decode(UUID.self, forKey: .uuid)
        let id = try container.decode(Int.self, forKey: .id)
        let title = try container.decode(String.self, forKey: .title)
        let alias = try container.decodeIfPresent([String].self, forKey: .alias) ?? []
        let primer = try container.decodeIfPresent(String.self, forKey: .primer)
        let primary = try container.decode([String].self, forKey: .primary)
        let secondary = try container.decode([String].self, forKey: .secondary)
        let equipment = try container.decode([String].self, forKey: .equipment)
        let steps = try container.decodeIfPresent([String].self, forKey: .steps) ?? []
        let tips = try container.decodeIfPresent([String].self, forKey: .tips) ?? []
        let references = try container.decodeIfPresent([String].self, forKey: .references) ?? []
        let pdf = try container.decodeIfPresent([String].self, forKey: .pdf) ?? []
        let image = try container.decodeIfPresent(String.self, forKey: .image)
        let animation = try container.decodeIfPresent(String.self, forKey: .animation)
        
        self.init(uuid: uuid, everkineticId: id, title: title, alias: alias, description: primer, primaryMuscle: primary, secondaryMuscle: secondary, equipment: equipment, steps: steps, tips: tips, references: references, pdfPaths: pdf, imageFilename: image, animationFilename: animation)
    }
    
    // MARK: Encodalbe
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uuid, forKey: .uuid)
        try container.encode(everkineticId, forKey: .id)
        // Catalog display formatting never changes a serialized exercise name.
        try container.encode(originalTitle, forKey: .title)
        try container.encode(alias, forKey: .alias)
        try container.encodeIfPresent(description, forKey: .primer)
        try container.encode(primaryMuscle, forKey: .primary)
        try container.encode(secondaryMuscle, forKey: .secondary)
        try container.encode(equipment, forKey: .equipment)
        try container.encode(steps, forKey: .steps)
        try container.encode(tips, forKey: .tips)
        try container.encode(references, forKey: .references)
        try container.encode(pdfPaths, forKey: .pdf)
        try container.encodeIfPresent(imageFilename, forKey: .image)
        try container.encodeIfPresent(animationFilename, forKey: .animation)
    }
}
