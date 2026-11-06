//
//  WorkoutExerciseChartDataGenerator.swift
//  Rhino Fit
//
//  Created by Karim Abou Zeid on 16.09.18.
//  Copyright © 2018 Karim Abou Zeid Software. All rights reserved.
//

import CoreData
import DGCharts
import WorkoutDataKit

enum WorkoutExerciseChartData {
    static func xAxisValueFormatter(for measurementType: MeasurementType, weightUnit: WeightUnit) -> AxisValueFormatter {
        WorkoutExerciseChartDataGenerator.DateAxisFormatter()
    }
    
    static func yAxisValueFormatter(for measurementType: MeasurementType, weightUnit: WeightUnit) -> AxisValueFormatter {
        DefaultAxisValueFormatter(decimals: 0)
    }
    
    static func ballonValueFormatter(for measurementType: MeasurementType, weightUnit: WeightUnit) -> BalloonValueFormatter {
        switch measurementType {
        case .oneRM, .totalWeight:
            return WorkoutExerciseChartDataGenerator.DateBalloonValueFormatter(yUnit: weightUnit.unit.symbol)
        case .totalSets, .totalRepetitions:
            return WorkoutExerciseChartDataGenerator.DateBalloonValueFormatter(yUnit: nil)
        }
    }

    static func evaluator(for measurementType: MeasurementType, weightUnit: WeightUnit) -> WorkoutExerciseChartDataGenerator.Evaluator {
        switch measurementType {
        case .oneRM:
            return {
                $0.workoutSets?
                    .compactMap { $0 as? WorkoutSet }
                    .compactMap { $0.estimatedOneRepMax() }
                    .max()
                    .map { WeightUnit.convert(weight: $0, from: .metric, to: weightUnit) }
            }
        case .totalWeight:
            return  { $0.totalCompletedWeight.map { WeightUnit.convert(weight: Double($0), from: .metric, to: weightUnit) } }
        case .totalSets:
            return { $0.numberOfCompletedSets.map { Double($0) } }
        case .totalRepetitions:
            return  { $0.numberOfCompletedRepetitions.map { Double($0) } }
        }
    }
    
    static func workoutExercises(uuid: UUID, timeFrame: TimeFrame, context: NSManagedObjectContext) -> [WorkoutExercise]? {
        try? context.fetch(WorkoutExercise.historyFetchRequest(of: uuid, from: timeFrame.from, until: timeFrame.until))
    }
    
    // MARK: - Enums
    enum MeasurementType: String, CaseIterable {
        case oneRM
        case totalWeight
        case totalSets
        case totalRepetitions

        var title: String {
            switch self {
            case .oneRM:
                return "Estimated 1RM"
            case .totalWeight:
                return "Total Weight"
            case .totalSets:
                return "Total Sets"
            case .totalRepetitions:
                return "Total Repetitions"
            }
        }
    }

    enum TimeFrame: CaseIterable {
        case week
        case month
        case threeMonths
        case sixMonths
        case year
        case all

        static let progressCases: [TimeFrame] = [.month, .threeMonths, .sixMonths, .year, .all]

        var title: String {
            switch self {
            case .week:
                return "Week"
            case .month:
                return "Month"
            case .threeMonths:
                return "3 Months"
            case .sixMonths:
                return "6 Months"
            case .year:
                return "Year"
            case .all:
                return "All"
            }
        }

        var compactTitle: String {
            switch self {
            case .week: return "1W"
            case .month: return "1M"
            case .threeMonths: return "3M"
            case .sixMonths: return "6M"
            case .year: return "1Y"
            case .all: return "All"
            }
        }

        var subtitle: String {
            switch self {
            case .week: return "Completed work from the past week"
            case .month: return "Completed work from the past month"
            case .threeMonths: return "Completed work from the past 3 months"
            case .sixMonths: return "Completed work from the past 6 months"
            case .year: return "Completed work from the past year"
            case .all: return "All recorded history"
            }
        }

        var from: Date? {
            switch self {
            case .week:
                return Calendar.current.date(byAdding: .day, value: -7, to: Date())
            case .month:
                return Calendar.current.date(byAdding: .month, value: -1, to: Date())
            case .threeMonths:
                return Calendar.current.date(byAdding: .month, value: -3, to: Date())
            case .sixMonths:
                return Calendar.current.date(byAdding: .month, value: -6, to: Date())
            case .year:
                return Calendar.current.date(byAdding: .year, value: -1, to: Date())
            case .all:
                return nil
            }
        }

        var until: Date? { nil }

        /// One month of calendar time occupies one viewport. Longer ranges
        /// become horizontally scrollable instead of compressing sparse gaps.
        func plotWidth(viewportWidth: CGFloat, earliestDate: Date?, now: Date = Date()) -> CGFloat {
            let unit = max(viewportWidth, 1)
            let secondsPerMonth: TimeInterval = 30 * 24 * 60 * 60
            let span: TimeInterval
            if let from {
                span = now.timeIntervalSince(from)
            } else if let earliestDate {
                span = max(now.timeIntervalSince(earliestDate), secondsPerMonth)
            } else {
                span = secondsPerMonth
            }
            let months = max(span / secondsPerMonth, 1)
            return unit * CGFloat(min(months, 72))
        }

        func domainStart(earliestDate: Date?, now: Date = Date()) -> Date {
            from ?? earliestDate ?? now
        }
    }
}
