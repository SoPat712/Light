//
//  ExerciseFilter.swift
//  Iron
//
//  Created by Karim Abou Zeid on 16.09.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import Foundation
import Combine
import WorkoutDataKit

class ExerciseFilter: ObservableObject {
    var filter: String {
        willSet {
            if isEmpty != newValue.isEmpty {
                isEmpty = newValue.isEmpty
            }
            searchSubject.send(newValue)
        }
    }
    
    @Published var exercises: [Exercise]
    @Published var isEmpty: Bool
    
    private var searchSubject = PassthroughSubject<String, Never>()
    private var cancellable: Cancellable?
    
    init(exercises: [Exercise], filter: String = "", exerciseStore: ExerciseStore = .shared) {
        self.exercises = ExerciseStore.filter(exercises: exerciseStore.orderedByRecency(exercises), using: filter,
                                              lastPerformedDates: exerciseStore.lastPerformedDates)
        self.filter = filter
        self.isEmpty = filter.isEmpty
        
        cancellable = searchSubject
            .prepend(filter)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.global(qos: .userInteractive))
            .removeDuplicates()
            .combineLatest(exerciseStore.$lastPerformedDates)
            .map { query, dates in
                ExerciseStore.filter(exercises: ExerciseRecency.ordered(exercises, dates: dates), using: query,
                                     lastPerformedDates: dates)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.exercises = $0 }
    }
}
