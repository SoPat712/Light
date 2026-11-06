import SwiftUI

/// One sleeve or a bare plate stack, using the calculator's per-side load,
/// drawn with the calculator diagram's plate colors and proportions.
struct PlateBarView: View {
    let platesPerSide: [PlateLoadSolution.Plate]
    let unit: WeightUnit
    let height: CGFloat
    var showsSleeve = true

    private var plates: [PlateLoadSolution.Plate] {
        platesPerSide.filter { $0.weight.isFinite && $0.weight > 0 && $0.count > 0 }
            .sorted { $0.weight > $1.weight }
    }

    private var plateWidthScale: CGFloat {
        min(1, max(0.6, height / 48))
    }

    private var idealWidth: CGFloat {
        let width = plates.reduce(CGFloat(showsSleeve ? 20 : 0)) { width, plate in
            let count = plate.count > 4 ? 3 : plate.count
            return width + CGFloat(count) * (PlateAppearance.width(for: plate.weight, unit: unit) * plateWidthScale + 2)
        }
        return min(width, 96)
    }

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            let groups = plates.map { plate in
                let count = plate.count > 4 ? 3 : plate.count
                let width = PlateAppearance.width(for: plate.weight, unit: unit) * plateWidthScale
                let stackWidth = CGFloat(count) * width + CGFloat(count - 1) * 2
                let label = plate.count > 4 ? context.resolve(
                    Text("×\(plate.count)")
                        .font(.ironMetric(.caption2, weight: .bold))
                        .foregroundColor(IronTheme.secondaryText)
                ) : nil
                let labelSize = label?.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)) ?? .zero
                return (plate: plate, count: count, plateWidth: width,
                        width: max(stackWidth, labelSize.width), label: label, labelHeight: labelSize.height)
            }
            let labelHeight = groups.map { $0.labelHeight }.max() ?? 0
            let labelBand = labelHeight > 0 ? labelHeight + 2 : 0
            let stackWidth = groups.reduce(CGFloat.zero) { $0 + $1.width }
            let naturalWidth = showsSleeve
                ? 18 + CGFloat(groups.count + 1) * 2 + stackWidth
                : max(1, CGFloat(max(groups.count - 1, 0)) * 2 + stackWidth)
            let naturalHeight = height + labelBand
            let scale = min(1, size.width / naturalWidth, size.height / naturalHeight)
            context.translateBy(x: (size.width - naturalWidth * scale) / 2,
                                y: (size.height - naturalHeight * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            let midY = labelBand + height / 2
            func fill(_ rect: CGRect, _ color: Color) {
                context.fill(Path(roundedRect: rect, cornerRadius: 2, style: .continuous), with: .color(color))
            }
            if showsSleeve {
                let barHeight = max(2, height * 0.10)
                fill(CGRect(x: 0, y: midY - barHeight / 2, width: naturalWidth, height: barHeight), IronTheme.solidTrack)
                let collarHeight = max(6, height * 0.45)
                fill(CGRect(x: 0, y: midY - collarHeight / 2, width: 6, height: collarHeight), IronTheme.solidTrack)
            }
            var offset: CGFloat = showsSleeve ? 8 : 0
            for group in groups {
                let stackWidth = CGFloat(group.count) * group.plateWidth + CGFloat(group.count - 1) * 2
                let plateHeight = PlateAppearance.height(for: group.plate.weight, unit: unit, maximum: height)
                for index in 0..<group.count {
                    let x = offset + (group.width - stackWidth) / 2 + CGFloat(index) * (group.plateWidth + 2)
                    fill(CGRect(x: x, y: midY - plateHeight / 2, width: group.plateWidth, height: plateHeight),
                         PlateAppearance.color(for: group.plate.weight, unit: unit))
                }
                if let label = group.label {
                    context.draw(label, at: CGPoint(x: offset + group.width / 2, y: midY - plateHeight / 2 - 2), anchor: .bottom)
                }
                offset += group.width + 2
            }
        }
        .frame(minWidth: 0, idealWidth: idealWidth, maxWidth: idealWidth)
        .frame(height: height + (plates.contains { $0.count > 4 } ? 16 : 0))
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
    }

    private var accessibilityTitle: String {
        guard !plates.isEmpty else { return showsSleeve ? "Bar only" : "No plates" }
        let weights = plates.map { plate in
            let weight = unit.numberFormatter.string(from: NSNumber(value: plate.weight)) ?? "0"
            return plate.count == 1 ? weight : "\(plate.count) times \(weight)"
        }.joined(separator: ", ")
        return "\(showsSleeve ? "Each side" : "Plate stack"): \(weights) \(unit == .imperial ? "pounds" : "kilograms")"
    }
}
