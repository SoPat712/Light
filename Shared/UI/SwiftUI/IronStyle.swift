import SwiftUI
import UIKit
import WorkoutDataKit

// MARK: - Cupertino visual system

/// One explicit palette record. Screens consume the semantic aliases in
/// `IronTheme`; palette values only live here so light, dark, and modal
/// surfaces cannot drift into one-off system colors.
struct IronPaletteColors {
    let accent: UIColor
    let accentPressed: UIColor
    let accentContainer: UIColor
    let metricSets: UIColor
    let metricSetsContainer: UIColor
    let metricVolume: UIColor
    let metricVolumeContainer: UIColor
    let metricTime: UIColor
    let metricTimeContainer: UIColor
    let metricEffort: UIColor
    let metricEffortContainer: UIColor
    let metricRecord: UIColor
    let metricRecordContainer: UIColor
    let metricBody: UIColor
    let metricBodyContainer: UIColor
    let metricHeartRate: UIColor
    let metricEnergy: UIColor
    let success: UIColor
    let successContainer: UIColor
    let successControl: UIColor
    let onSuccessContainer: UIColor
    let warning: UIColor
    let danger: UIColor
    let canvas: UIColor
    let modalSurface: UIColor
    let surface: UIColor
    let raisedSurface: UIColor
    let field: UIColor
    let topBar: UIColor
    let outline: UIColor
    let primaryText: UIColor
    let secondaryText: UIColor
    let tertiaryText: UIColor
    let onAccent: UIColor
}

/// Iron uses Apple's adaptive semantic colors instead of maintaining separate
/// hard-coded light and dark palettes. Keeping the roles centralized prevents
/// local screens from guessing at contrast or appearance-specific values.
enum IronPalette {
    static let semantic = IronPaletteColors(
        accent: .systemBlue,
        accentPressed: UIColor.systemBlue.withAlphaComponent(0.72),
        accentContainer: UIColor.systemBlue.withAlphaComponent(0.12),
        metricSets: .systemOrange,
        metricSetsContainer: UIColor.systemOrange.withAlphaComponent(0.18),
        metricVolume: .systemGreen,
        metricVolumeContainer: UIColor.systemGreen.withAlphaComponent(0.18),
        metricTime: .systemCyan,
        metricTimeContainer: UIColor.systemCyan.withAlphaComponent(0.18),
        metricEffort: .systemPink,
        metricEffortContainer: UIColor.systemPink.withAlphaComponent(0.18),
        metricRecord: .systemYellow,
        metricRecordContainer: UIColor.systemYellow.withAlphaComponent(0.18),
        metricBody: .systemPurple,
        metricBodyContainer: UIColor.systemPurple.withAlphaComponent(0.18),
        metricHeartRate: .systemRed,
        metricEnergy: .systemOrange,
        success: .systemGreen,
        successContainer: UIColor.systemGreen.withAlphaComponent(0.14),
        successControl: UIColor.systemGreen.withAlphaComponent(0.22),
        // Legacy success containers remain source-compatible during the refresh.
        // New completed-set treatments use accent, never success.
        onSuccessContainer: .label,
        warning: .systemOrange,
        danger: .systemRed,
        canvas: .systemGroupedBackground,
        modalSurface: .systemGroupedBackground,
        surface: .secondarySystemGroupedBackground,
        raisedSurface: .tertiarySystemGroupedBackground,
        field: .secondarySystemFill,
        topBar: .systemBackground,
        outline: .separator,
        primaryText: .label,
        secondaryText: .secondaryLabel,
        tertiaryText: .tertiaryLabel,
        onAccent: .white
    )

    static func uiColor(_ role: KeyPath<IronPaletteColors, UIColor>) -> UIColor {
        semantic[keyPath: role]
    }

    static func color(_ role: KeyPath<IronPaletteColors, UIColor>) -> Color {
        Color(uiColor(role))
    }
}

/// Iron follows Apple's platform conventions: semantic colors, SF typography,
/// grouped content surfaces, standard control geometry, and restrained tint.
enum IronTheme {
    static let accent = IronPalette.color(\.accent)
    static let accentPressed = IronPalette.color(\.accentPressed)
    static let accentSoft = IronPalette.color(\.accentContainer)
    static let metricSets = IronPalette.color(\.metricSets)
    static let metricSetsContainer = IronPalette.color(\.metricSetsContainer)
    static let metricVolume = IronPalette.color(\.metricVolume)
    static let metricVolumeContainer = IronPalette.color(\.metricVolumeContainer)
    static let metricTime = IronPalette.color(\.metricTime)
    static let metricTimeContainer = IronPalette.color(\.metricTimeContainer)
    static let metricEffort = IronPalette.color(\.metricEffort)
    static let metricEffortContainer = IronPalette.color(\.metricEffortContainer)
    static let metricRecord = IronPalette.color(\.metricRecord)
    static let metricRecordContainer = IronPalette.color(\.metricRecordContainer)
    static let metricBody = IronPalette.color(\.metricBody)
    static let metricBodyContainer = IronPalette.color(\.metricBodyContainer)
    static let metricHeartRate = IronPalette.color(\.metricHeartRate)
    static let metricEnergy = IronPalette.color(\.metricEnergy)
    static let setWarmUpTint = Color(UIColor.systemOrange)
    static let setDropTint = Color(UIColor.systemIndigo)
    static let setFailureTint = Color(UIColor.systemRed)
    static let setWarmUpContainer = setWarmUpTint.opacity(0.18)
    static let setDropContainer = setDropTint.opacity(0.18)
    static let setFailureContainer = setFailureTint.opacity(0.16)

    static func setFill(for tag: WorkoutSetTag?) -> (tint: Color, settled: Double, peak: Double) {
        switch tag {
        case .warmUp: return (setWarmUpTint, 0.14, 0.22)
        case .dropSet: return (setDropTint, 0.14, 0.22)
        case .failure: return (setFailureTint, 0.12, 0.20)
        case nil: return (accent, 0.12, 0.24)
        }
    }

    static let success = IronPalette.color(\.success)
    static let successContainer = IronPalette.color(\.successContainer)
    static let successControl = IronPalette.color(\.successControl)
    static let onSuccessContainer = IronPalette.color(\.onSuccessContainer)
    static let warning = IronPalette.color(\.warning)
    static let danger = IronPalette.color(\.danger)
    static let background = IronPalette.color(\.canvas)
    static let modalSurface = IronPalette.color(\.modalSurface)
    static let surface = IronPalette.color(\.surface)
    static let raisedSurface = IronPalette.color(\.raisedSurface)
    static let field = IronPalette.color(\.field)
    /// Quiet input fills and the rest ring's neutral track.
    static let tertiaryFill = Color(UIColor.tertiarySystemFill)
    /// An unfilled graph bar that stays solid whatever sits behind it.
    static let solidTrack = Color(UIColor.systemGray4)
    static let topBar = IronPalette.color(\.topBar)
    static let outline = IronPalette.color(\.outline)
    static let primaryText = IronPalette.color(\.primaryText)
    static let secondaryText = IronPalette.color(\.secondaryText)
    static let tertiaryText = IronPalette.color(\.tertiaryText)
    static let onAccent = IronPalette.color(\.onAccent)

    // Exercise diagrams and user media intentionally keep a fixed canvas so
    // third-party artwork and photo controls retain predictable contrast in
    // both appearances. Keep those fixed colors semantic and centralized.
    static let diagramCanvas = Color(UIColor.white)
    static let mediaBackdrop = Color(UIColor.black)
    static let onMedia = Color(UIColor.white)
    static let mediaControlSurface = Color(UIColor.white.withAlphaComponent(0.16))
    static let mediaBadgeSurface = Color(UIColor.black.withAlphaComponent(0.56))

    static let cornerRadius: CGFloat = 12
    static let compactCornerRadius: CGFloat = 10
    /// Hero and summary glass clusters use a larger continuous corner so they
    /// read as an Apple Fitness surface rather than a content card.
    static let heroCornerRadius: CGFloat = 22
    static let controlHeight: CGFloat = 44
    static let iconButtonSize: CGFloat = controlHeight
    static let pillCornerRadius: CGFloat = controlHeight / 2
    static let horizontalPadding: CGFloat = 16
    /// The native five-item tab bar occupies almost the full phone width. The
    /// active workout pill is intentionally four points narrower on each side
    /// and sits close enough to read as a companion surface.
    static let activeWorkoutPillHorizontalPadding: CGFloat = 20
    static let activeWorkoutPillBottomOffset: CGFloat = 66
    /// Bottom breathing room for destination content while the global active-
    /// workout glass pill floats above the tab bar. Full-screen editors also
    /// use this value because the pill intentionally remains available there.
    static let floatingWorkoutBottomClearance: CGFloat = 152
}


/// Motion uses springs for state changes and a decelerating curve for travel.
/// Every spatial animation remains defeasible by Reduce Motion.
enum IronMotion {
    /// Direct manipulation and state changes the finger caused: set complete,
    /// header collapse, filter selection.
    static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.82)
    /// Layout changes that move a large surface, such as the logger summary
    /// collapsing into the floating pill.
    static let collapse = Animation.spring(response: 0.42, dampingFraction: 0.86)
    /// Guided travel between exercises: move promptly, then settle without bounce.
    static let focusScroll = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.65)
    /// Non-spatial changes where a spring would look decorative.
    static let fade = Animation.easeInOut(duration: 0.18)

    /// Reduce Motion swaps springs for a short cross-fade rather than removing
    /// feedback entirely, so state changes are still perceivable.
    static func preferred(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : animation
    }
}

