//
//  Shortcuts.swift
//  Iron
//
//  Created by Karim Abou Zeid on 08.12.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import Foundation
import Intents
import WorkoutDataKit
import os.log

enum Shortcuts {
    /// The IronIntents and IronIntentsUI extensions are shelved until a real release, so nothing can run these shortcuts.
    /// Set to true when they're embedded again (see docs/HANDOFF.md).
    private static let isAvailable = true

    static func setShortcutSuggestions() {
        guard isAvailable else {
            // clear what earlier builds published, it would only fail now
            INVoiceShortcutCenter.shared.setShortcutSuggestions([])
            INInteraction.deleteAll()
            return
        }

        let exercises = ExerciseStore.shared.shownExercises.filter { exercise in
            // Catalog source names, so display renaming can't widen the suggestion set.
            ["Bench Press: Barbell", "Squat: Barbell", "Deadlift: Barbell"].contains(exercise.originalTitle)
        }
        
        let prShortcuts = exercises.compactMap { exercise -> INShortcut? in
            let intent = ViewPersonalRecordsIntent()
            intent.exercise = exercise.intentExercise
            return INShortcut(intent: intent)
        }
        
        let oneRepMaxShortcuts = exercises.compactMap { exercise -> INShortcut? in
            let intent = ViewOneRepMaxIntent()
            intent.exercise = exercise.intentExercise
            return INShortcut(intent: intent)
        }
        
        let workoutShortcuts = [INStartWorkoutIntent(), INEndWorkoutIntent(), INCancelWorkoutIntent()]
            .map { INShortcut(intent: $0) }
            .compactMap { $0 }
        
        INVoiceShortcutCenter.shared.setShortcutSuggestions(prShortcuts + oneRepMaxShortcuts + workoutShortcuts)
    }
    
    /// Used for the Siri Watch face on the Apple Watch
    // This doesn't work (iOS 13.4), the watch shows the suggestion but gets an error when executed
//    static func setRelevantShortcuts() {
//        guard let shortcut = INShortcut(intent: INStartWorkoutIntent()) else { return }
//        let relevantShortcut = INRelevantShortcut(shortcut: shortcut)
//        relevantShortcut.relevanceProviders = [INDailyRoutineRelevanceProvider(situation: .gym)]
//
//        os_log("Setting relevant shortcuts", log: .siri)
//        INRelevantShortcutStore.default.setRelevantShortcuts([relevantShortcut]) { (error) in
//            if let error = error {
//                os_log("Setting relevant shortcuts failed %@", log: .siri, type: .error, error.localizedDescription)
//            } else {
//                os_log("Successfully set relevant shortcuts", log: .siri, type: .info)
//            }
//        }
//    }
    
    /// Should be called when a new *empty* workout is created by the user
    static func donateStartWorkoutInteraction(for workout: Workout) {
        guard isAvailable, let uuid = workout.uuid else { return }
        let intent = INStartWorkoutIntent()
        intent.suggestedInvocationPhrase = "Weight lifting time"
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.groupIdentifier = "start_workout"
        interaction.identifier = uuid.uuidString
        
        os_log("Donating start workout interaction with uuid=%@", log: .siri, uuid as NSUUID)
        interaction.donate { (error) in
            if let error = error {
                os_log("Donating interaction failed: %@", log: .siri, type: .error, error.localizedDescription)
            } else {
                os_log("Successfully donated interaction with uuid=%@", log: .siri, type: .info, uuid as NSUUID)
            }
        }
    }
    
    static func deleteStartWorkoutInteractionDonation(for workout: Workout) {
        guard let uuid = workout.uuid else { return }
        deleteStartWorkoutInteractionDonation(uuid: uuid)
    }

    static func deleteStartWorkoutInteractionDonation(uuid: UUID) {
        os_log("Deleting start workout interaction with uuid=%@", log: .siri, uuid as NSUUID)
        INInteraction.delete(with: [uuid.uuidString]) { error in
            if let error = error {
                os_log("Deleting interaction failed: %@", log: .siri, type: .error, error.localizedDescription)
            } else {
                os_log("Successfully deleted interaction with uuid=%@", log: .siri, type: .info, uuid as NSUUID)
            }
        }
    }
}
