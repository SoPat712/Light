//
//  WorkoutDataStorage+shared.swift
//  Iron
//
//  Created by Karim Abou Zeid on 05.12.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import Foundation
import WorkoutDataKit
import CoreData
import Combine
import WidgetKit
import os.log

extension WorkoutDataStorage {
    private static var cancellables = Set<AnyCancellable>()
    
    private static var workoutsChangedSubject = PassthroughSubject<Void, Never>()
    private static var watchWorkoutChangedSubject = PassthroughSubject<Void, Never>()
    
    private static var startChangedSubject = PassthroughSubject<(Date, UUID), Never>()
    private static var endChangedSubject = PassthroughSubject<(Date?, UUID), Never>()
    
    static let shared: WorkoutDataStorage = {
        let workoutDataStorage = WorkoutDataStorage(storeDescription: .init(url: groupStoreURL))
        workoutDataStorage.persistentContainer.viewContext.publisher
            .drop { _ in IronBackup.restoringBackupData } // better to ignore the spam while we are restoring
            .sink { changes in
                WorkoutDataStorage.sendObjectsWillChange(changes: changes)
            }
            .store(in: &cancellables)
        
        if #available(iOS 14.0, *) {
            workoutDataStorage.persistentContainer.viewContext.publisher
                .drop { _ in IronBackup.restoringBackupData }
                .sink { changes in
                    if changes.inserted.union(changes.deleted).contains(where: { $0 is Workout }) {
                        workoutsChangedSubject.send()
                    } else {
                        let hasUpdatedWorkout = changes.updated.contains {
                            guard let workout = $0 as? Workout else { return false }
                            guard !workout.isFault else { return false }
                            guard !workout.isCurrentWorkout else { return false }
                            return true
                        }
                        if hasUpdatedWorkout {
                            workoutsChangedSubject.send()
                        }
                    }
                }
                .store(in: &cancellables)
            
            workoutsChangedSubject
                .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
                .sink {
                    WidgetKind.lastWorkout.reloadTimelines()
                    WidgetKind.thisWeek.reloadTimelines()
                }
                .store(in: &cancellables)
        }

        // Reuse Home's saved-history projection, including its completed-set and
        // tracking-type rules. Its save observer also covers set/exercise edits,
        // deletions, imports and the initial app launch, before Home is opened.
        Task { @MainActor in
            let history = TrainingHistoryStore.shared
            history.$snapshot
                .dropFirst(history.snapshot.sessions.isEmpty ? 1 : 0)
                .map { snapshot in
                    ThisWeekWidgetHistory(sessions: snapshot.sessions.map {
                        .init(date: $0.date, sets: $0.setCount, volume: $0.volume)
                    })
                }
                .removeDuplicates()
                .sink { value in
                    do {
                        try ThisWeekWidgetCache.save(value)
                        WidgetKind.thisWeek.reloadTimelines()
                    } catch {
                        os_log("Could not update This Week widget: %{public}@", log: .widgets,
                               type: .error, error.localizedDescription)
                    }
                }
                .store(in: &cancellables)
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: UserDefaults.appGroup)
                .map { _ in UserDefaults.appGroup.string(forKey: "weightUnit") }
                .prepend(UserDefaults.appGroup.string(forKey: "weightUnit"))
                .removeDuplicates()
                .dropFirst()
                .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
                .sink { _ in WidgetKind.thisWeek.reloadTimelines() }
                .store(in: &cancellables)
            history.observe(in: workoutDataStorage.persistentContainer.viewContext)
        }
        
        workoutDataStorage.persistentContainer.viewContext.publisher
            .drop { _ in IronBackup.restoringBackupData }
            .sink { changes in
                // NOTE: cannot use background queue here because of the MOC
                if WatchConnectionManager.shared.currentWatchWorkoutUuid != nil,
                   changes.inserted.union(changes.updated).union(changes.deleted).contains(where: {
                       $0 is Workout || $0 is WorkoutExercise || $0 is WorkoutSet
                   }) {
                    watchWorkoutChangedSubject.send()
                }
                for changedObject in changes.updated {
                    if let workout = changedObject as? Workout, !workout.isFault, let uuid = workout.uuid {
                        // TODO: update stored health workout if not current workout
                        if workout.isCurrentWorkout {
                            if uuid == WatchConnectionManager.shared.currentWatchWorkoutUuid {
                                if changedObject.changedValuesForCurrentEvent()["start"] != nil, let start = workout.start {
                                    startChangedSubject.send((start, uuid))
                                }
                                if changedObject.changedValuesForCurrentEvent()["end"] != nil {
                                    endChangedSubject.send((workout.end, uuid))
                                }
                            }
                        }
                    }
                }
            }
            .store(in: &cancellables)

        watchWorkoutChangedSubject
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { WatchConnectionManager.shared.syncCurrentWorkoutSnapshot() }
            .store(in: &cancellables)
                
        startChangedSubject
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink {
                WatchConnectionManager.shared.updateWatchWorkoutStart(start: $0.0, uuid: $0.1)
            }
            .store(in: &cancellables)
        
        endChangedSubject
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink {
                WatchConnectionManager.shared.updateWatchWorkoutEnd(end: $0.0, uuid: $0.1)
            }
            .store(in: &cancellables)
        
        return workoutDataStorage
    }()
}
