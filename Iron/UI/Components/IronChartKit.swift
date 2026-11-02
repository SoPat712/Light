//
//  IronChartKit.swift
//  Light
//

import SwiftUI
import Charts

/// One look for every Swift Chart, modeled on the Health app: a caption, a large value and a
/// date range above the plot, values on a trailing axis with hairline gridlines, and small date
/// labels below. Selecting a mark rewrites the header instead of floating a callout over the data.
struct IronChartHeader: View {
    let caption: String
    let value: Text
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption)
                .font(.caption.weight(.semibold))
                .foregroundStyle(IronTheme.secondaryText)
                .textCase(.uppercase)
            value
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(IronTheme.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

enum IronChartText {
    /// The header's large number in its metric color, with the unit small and secondary.
    static func value(_ number: String, unit: String? = nil, tint: Color, style: Font.TextStyle = .title2) -> Text {
        let main = Text(number).font(.ironMetric(style, weight: .bold)).foregroundColor(tint)
        guard let unit, !unit.isEmpty else { return main }
        return main + Text(" " + unit).font(.subheadline.weight(.semibold)).foregroundColor(IronTheme.secondaryText)
    }

    /// "Oct 3 – Nov 2", or a single date when both ends fall on the same day.
    static func range(_ start: Date, _ end: Date) -> String {
        if Calendar.current.isDate(start, inSameDayAs: end) {
            return start.formatted(.dateTime.month(.abbreviated).day().year())
        }
        let sameYear = Calendar.current.isDate(start, equalTo: end, toGranularity: .year)
        let first = sameYear ? start.formatted(.dateTime.month(.abbreviated).day()) : start.formatted(.dateTime.month(.abbreviated).day().year())
        return first + " – " + end.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

/// The vertical rule under the finger while scrubbing.
struct IronChartSelectionRule: ChartContent {
    let date: Date

    var body: some ChartContent {
        RuleMark(x: .value("Selected", date))
            .lineStyle(StrokeStyle(lineWidth: 1))
            .foregroundStyle(IronTheme.secondaryText.opacity(0.45))
    }
}

/// Marks a chart dims when another one is selected.
enum IronChartEmphasis {
    static let dimmed = 0.4
    static func opacity(isSelected: Bool, hasSelection: Bool) -> Double {
        !hasSelection || isSelected ? 1 : dimmed
    }
}

extension View {
    /// Values on the trailing edge with hairline gridlines, as in Health.
    func ironValueAxis(_ values: AxisMarkValues = .automatic(desiredCount: 3), label: @escaping (Double) -> String) -> some View {
        chartYAxis {
            AxisMarks(position: .trailing, values: values) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(IronTheme.outline)
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text(label(raw))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(IronTheme.secondaryText)
                    }
                }
            }
        }
    }

    /// The same axis at explicit tick values, for charts that pick round steps themselves.
    func ironValueAxis(ticks: [Double], label: @escaping (Double) -> String) -> some View {
        chartYAxis {
            AxisMarks(position: .trailing, values: ticks) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(IronTheme.outline)
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text(label(raw))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(IronTheme.secondaryText)
                    }
                }
            }
        }
    }

    /// Small dates under the plot, with a faint guide at each label.
    func ironDateAxis(_ values: AxisMarkValues = .automatic(desiredCount: 4), format: Date.FormatStyle) -> some View {
        chartXAxis {
            AxisMarks(values: values) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(IronTheme.outline)
                AxisValueLabel(anchor: .topLeading) {
                    if let date = value.as(Date.self) {
                        Text(date, format: format)
                            .font(.caption2)
                            .foregroundStyle(IronTheme.secondaryText)
                    }
                }
            }
        }
    }
}
