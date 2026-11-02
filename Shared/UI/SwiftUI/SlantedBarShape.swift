import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The quadratic-corner recipe from phone-effort-rpe.dc.html's slantPath.
struct SlantedBarShape: Shape {
    var leftHeight: CGFloat
    var rightHeight: CGFloat
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }
        let x0 = rect.minX
        let x1 = rect.maxX
        let bottom = rect.maxY
        let left = bottom - leftHeight * rect.height
        let right = bottom - rightHeight * rect.height
        let slope = (left - right) / rect.width
        let radius = cornerRadius

        var path = Path()
        path.move(to: CGPoint(x: x0, y: bottom - radius))
        path.addLine(to: CGPoint(x: x0, y: left + radius))
        path.addQuadCurve(to: CGPoint(x: x0 + radius, y: left - slope * radius),
                          control: CGPoint(x: x0, y: left))
        path.addLine(to: CGPoint(x: x1 - radius, y: right + slope * radius))
        path.addQuadCurve(to: CGPoint(x: x1, y: right + radius),
                          control: CGPoint(x: x1, y: right))
        path.addLine(to: CGPoint(x: x1, y: bottom - radius))
        path.addQuadCurve(to: CGPoint(x: x1 - radius, y: bottom),
                          control: CGPoint(x: x1, y: bottom))
        path.addLine(to: CGPoint(x: x0 + radius, y: bottom))
        path.addQuadCurve(to: CGPoint(x: x0, y: bottom - radius),
                          control: CGPoint(x: x0, y: bottom))
        path.closeSubpath()
        return path
    }
}

/// Session effort has four Apple Fitness tiers; set RPE retains its pink role.
enum EffortTierPalette: Int, CaseIterable {
    case easy, moderate, hard, allOut

    var levels: ClosedRange<Int> {
        switch self {
        case .easy: return 1...3
        case .moderate: return 4...6
        case .hard: return 7...8
        case .allOut: return 9...10
        }
    }

    var title: String {
        switch self {
        case .easy: return "Easy"
        case .moderate: return "Moderate"
        case .hard: return "Hard"
        case .allOut: return "All Out"
        }
    }

    var color: Color {
        #if os(iOS)
        switch self {
        case .easy: return Color(uiColor: .systemGreen)
        case .moderate: return Color(uiColor: .systemYellow)
        case .hard: return Color(uiColor: .systemOrange)
        case .allOut: return Color(uiColor: .systemRed)
        }
        #else
        switch self {
        case .easy: return .green
        case .moderate: return .yellow
        case .hard: return .orange
        case .allOut: return .red
        }
        #endif
    }

    func textColor(in scheme: ColorScheme) -> Color {
        #if os(iOS)
        guard scheme == .light else { return color }
        let hex: UInt32
        switch self {
        case .easy: hex = 0x248A3D
        case .moderate: hex = 0xB25000
        case .hard: hex = 0xC93400
        case .allOut: hex = 0xD70015
        }
        return Color(uiColor: UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                                      green: CGFloat((hex >> 8) & 0xFF) / 255,
                                      blue: CGFloat(hex & 0xFF) / 255, alpha: 1))
        #else
        return color
        #endif
    }

    static func tier(for rating: Int) -> Self {
        switch rating {
        case ...3: return .easy
        case 4...6: return .moderate
        case 7...8: return .hard
        default: return .allOut
        }
    }
}

/// Where each of the ten effort levels sits, with wider gaps between tiers.
struct EffortLevelLayout {
    static let levels = 1...10

    let width: CGFloat
    let levelGap: CGFloat
    let tierGap: CGFloat

    var barWidth: CGFloat {
        let gaps = Self.levels.dropLast().reduce(CGFloat.zero) { $0 + gap(after: $1) }
        return max(0, (width - gaps) / CGFloat(Self.levels.count))
    }

    func gap(after level: Int) -> CGFloat {
        guard level < Self.levels.upperBound else { return 0 }
        return EffortTierPalette.tier(for: level) == EffortTierPalette.tier(for: level + 1) ? levelGap : tierGap
    }

    func minX(of level: Int) -> CGFloat {
        (Self.levels.lowerBound..<level).reduce(CGFloat.zero) { $0 + barWidth + gap(after: $1) }
    }

    /// A touch in a gap belongs to the bar on its left.
    func level(at x: CGFloat) -> Int {
        Self.levels.first { x < minX(of: $0) + barWidth + gap(after: $0) } ?? Self.levels.upperBound
    }
}

/// One slanted bar per level, forming a single ramp. A level is either lit or not,
/// so a rating never cuts through a bar.
struct EffortLevelBars: View {
    let rating: Int
    let levelGap: CGFloat
    let tierGap: CGFloat
    let cornerRadius: CGFloat
    let inactiveColor: Color

    private func height(_ step: Int) -> CGFloat {
        0.22 + 0.78 * CGFloat(step) / CGFloat(EffortLevelLayout.levels.count)
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = EffortLevelLayout(width: proxy.size.width, levelGap: levelGap, tierGap: tierGap)
            HStack(spacing: 0) {
                ForEach(EffortLevelLayout.levels, id: \.self) { level in
                    SlantedBarShape(leftHeight: height(level - 1), rightHeight: height(level),
                                    cornerRadius: min(cornerRadius, layout.barWidth / 3))
                        .fill(level <= rating ? EffortTierPalette.tier(for: level).color : inactiveColor)
                        .frame(width: layout.barWidth)
                        .padding(.trailing, layout.gap(after: level))
                }
            }
        }
    }
}
