//
//  WeightUnit.swift
//  Sunrise Fit
//
//  Created by Karim Abou Zeid on 16.07.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import Foundation

enum WeightUnit: String, CaseIterable, Hashable {
    case metric
    case imperial
    
    var title: String {
        switch self {
        case .metric:
            return "Metric (kg)"
        case .imperial:
            return "Imperial (lb)"
        }
    }
    
    var unit: UnitMass {
        switch self {
        case .metric:
            return .kilograms
        case .imperial:
            return .pounds
        }
    }
}

extension WeightUnit {
    var minimumFractionDigits: Int { 0 }
    var maximumFractionDigits: Int { 3 }
    var defaultFractionDigits: Int {
        switch self {
        case .metric:
            return 1
        case .imperial:
            return 0
        }
    }
    
    var numberFormatter: NumberFormatter {
        let numberFormatter = NumberFormatter()
        numberFormatter.allowsFloats = true
        numberFormatter.usesGroupingSeparator = false
        numberFormatter.minimumFractionDigits = minimumFractionDigits
        numberFormatter.maximumFractionDigits = maximumFractionDigits
        return numberFormatter
    }
    
    /// Grouped presentation values; numeric editors keep `numberFormatter`.
    var displayNumberFormatter: NumberFormatter {
        let formatter = numberFormatter
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        return formatter
    }

    var formatter: MeasurementFormatter {
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .providedUnit
        formatter.numberFormatter = displayNumberFormatter
        return formatter
    }
}

extension WeightUnit {
    static func sanitizedDecimalInput(
        _ input: String,
        maximumFractionDigits: Int,
        decimalSeparator: String = Locale.current.decimalSeparator ?? ".",
        groupingSeparator: String = Locale.current.groupingSeparator ?? ","
    ) -> String {
        // With comma decimals, distinguish pasted thousands ("1.005") from
        // a period entered on the keypad ("2.5"). A native decimal takes priority.
        let periodGroups = input.filter { $0.wholeNumberValue != nil || $0 == "." }
            .split(separator: ".", omittingEmptySubsequences: false)
        let isGroupedInteger = periodGroups.count > 1
            && (1...3).contains(periodGroups[0].count)
            && periodGroups.dropFirst().allSatisfy { $0.count == 3 }
        let acceptsKeypadDecimal = decimalSeparator == ","
            && !input.contains(decimalSeparator)
            && (groupingSeparator != "." || !isGroupedInteger)
        var result = ""
        var hasDecimalSeparator = false
        var fractionDigitCount = 0

        for character in input {
            if let digit = character.wholeNumberValue {
                if hasDecimalSeparator {
                    guard fractionDigitCount < maximumFractionDigits else { continue }
                    fractionDigitCount += 1
                }
                result.append(contentsOf: String(digit))
            } else if String(character) == decimalSeparator || (character == "." && acceptsKeypadDecimal) {
                guard !hasDecimalSeparator else { continue }
                if result.isEmpty { result = "0" }
                if maximumFractionDigits > 0 { result.append(contentsOf: decimalSeparator) }
                hasDecimalSeparator = true
            }
        }
        return result
    }

    static func convert(weight: Double, from: WeightUnit, to: WeightUnit) -> Double {
        Measurement(value: weight, unit: from.unit).converted(to: to.unit).value
    }
    
    static func format(weight: Double, from: WeightUnit, to: WeightUnit) -> String {
        to.formatter.string(from: Measurement(value: weight, unit: from.unit).converted(to: to.unit))
    }
}

extension WeightUnit {
    var barbellIncrement: Double {
        switch self {
        case .metric:
            return 2.5 // 2x 1.25 kg
        case .imperial:
            return 5 // 2x 2.5 lb
        }
    }

    /// What one +/- press changes in the logger, in either unit. The owner asked
    /// for 2.5 lb rather than a plate pair; suggestions and warm-ups keep barbellIncrement.
    var adjustmentStep: Double { 2.5 }

    var barbellWeight: Double {
        switch self {
        case .metric:
            return 20
        case .imperial:
            return 45
        }
    }
}
