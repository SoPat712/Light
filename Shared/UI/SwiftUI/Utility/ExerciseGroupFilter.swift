//
//  ExerciseGroupFilter.swift
//  Iron
//
//  Created by Karim Abou Zeid on 16.09.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import Foundation
import Combine
import WorkoutDataKit

class ExerciseGroupFilter: ObservableObject {
    var filter: String = "" {
        didSet {
            if filter.isEmpty {
                // not necessary, but when the user clears the search this makes it happen immediately
                exerciseGroups = originalExerciseGroups
            }
            searchSubject.send(filter) // send even if filter.isEmpty because otherwise the searchSubject doesn't work correctly
        }
    }
    
    private let originalExerciseGroups: [ExerciseGroup]

    @Published var exerciseGroups: [ExerciseGroup]
    
    private var searchSubject = PassthroughSubject<String, Never>()
    private var cancellable: Cancellable?
    
    init(exerciseGroups: [ExerciseGroup], exerciseStore: ExerciseStore = .shared) {
        originalExerciseGroups = exerciseGroups
        self.exerciseGroups = exerciseGroups
        
        cancellable = searchSubject
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.global(qos: .userInteractive))
            .combineLatest(exerciseStore.$lastPerformedDates)
            .map { query, dates in
                guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return exerciseGroups
                }
                // A single untitled group lets all picker/list consumers show
                // flat search matches, ranked with the shared recency snapshot.
                return [ExerciseGroup(title: "", exercises: ExerciseStore.filter(
                    exercises: exerciseGroups.flatMap(\.exercises), using: query, lastPerformedDates: dates
                ))]
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.exerciseGroups = $0 }
    }
}
