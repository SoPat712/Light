//
//  WorkoutDetailBannerView.swift
//  Sunrise Fit
//
//  Created by Karim Abou Zeid on 22.06.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import SwiftUI
import WorkoutDataKit

struct WorkoutDetailBannerView : View {
    @EnvironmentObject var settingsStore: SettingsStore
    @ObservedObject var workout: Workout
    
    var body: some View {
        BannerView(entries: bannerViewEntries)
    }
    
    private var bannerViewEntries: [BannerViewEntry] {
        var entries = [BannerViewEntry]()

        entries.append(BannerViewEntry(
            id: 0,
            title: Text("Duration").fontWeight(.semibold).foregroundColor(IronTheme.metricTime),
            text: Text(Workout.durationFormatter.string(from: workout.safeDuration) ?? "")
                .font(.ironMetric(.title2)).foregroundColor(IronTheme.metricTime)
        ))
        entries.append(BannerViewEntry(
            id: 1,
            title: Text("Sets").fontWeight(.semibold).foregroundColor(IronTheme.metricSets),
            text: Text(String(workout.numberOfCompletedSets ?? 0))
                .font(.ironMetric(.title2)).foregroundColor(IronTheme.metricSets)
        ))
        let volume = WeightUnit.convert(
            weight: workout.trackedCompletedVolume, from: .metric, to: settingsStore.weightUnit
        )
        entries.append(BannerViewEntry(
            id: 2,
            title: Text("Volume").fontWeight(.semibold).foregroundColor(IronTheme.metricVolume),
            text: Text(settingsStore.weightUnit.displayNumberFormatter.string(from: volume as NSNumber) ?? "—")
                .font(.ironMetric(.title2)).foregroundColor(IronTheme.metricVolume)
                + Text(" \(settingsStore.weightUnit.unit.symbol)")
                    .font(.caption).foregroundColor(IronTheme.secondaryText)
        ))
        return entries
    }
}

#if DEBUG
struct WorkoutDetailSummaryView_Previews : PreviewProvider {
    static var previews: some View {
        WorkoutDetailBannerView(workout: MockWorkoutData.metricRandom.workout)
            .mockEnvironment(weightUnit: .metric)
            .previewLayout(.sizeThatFits)
    }
}
#endif
