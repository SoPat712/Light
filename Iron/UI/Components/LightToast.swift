import SwiftUI
import UIKit

/// A short, self-dismissing result that drops from the top center as a glass capsule.
/// Use it for outcomes that need no decision (a backup made, a sync done, a status
/// checked). Errors the person has to read or act on keep their sheets and alerts.
struct LightToast: Identifiable, Equatable {
    enum Style { case success, warning, failure, info }

    let id = UUID()
    let title: String
    var subtitle: String?
    var systemImage: String
    var style: Style = .success
    var duration: TimeInterval = 2.4

    static func == (lhs: LightToast, rhs: LightToast) -> Bool { lhs.id == rhs.id }

    fileprivate var tint: Color {
        switch style {
        case .success: return IronTheme.success
        case .warning: return IronTheme.warning
        case .failure: return IronTheme.danger
        case .info: return IronTheme.accent
        }
    }
}

/// Shows one toast at a time in its own pass-through window, so it appears above
/// sheets and full-screen covers and never blocks a touch.
@MainActor
final class LightToastCenter: ObservableObject {
    static let shared = LightToastCenter()

    @Published fileprivate private(set) var current: LightToast?
    private var window: UIWindow?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(_ toast: LightToast) {
        installWindowIfNeeded()
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) {
            current = toast
        }
        if SettingsStore.shared.workoutHaptics {
            let generator = UINotificationFeedbackGenerator()
            switch toast.style {
            case .success, .info: generator.notificationOccurred(.success)
            case .warning: generator.notificationOccurred(.warning)
            case .failure: generator.notificationOccurred(.error)
            }
        }
        UIAccessibility.post(notification: .announcement,
                             argument: [toast.title, toast.subtitle].compactMap { $0 }.joined(separator: ", "))
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(toast.duration))
            guard !Task.isCancelled else { return }
            self?.dismiss(toast)
        }
    }

    private func dismiss(_ toast: LightToast) {
        guard current == toast else { return }
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        withAnimation(IronMotion.preferred(IronMotion.fade, reduceMotion: reduceMotion)) {
            current = nil
        }
    }

    private func installWindowIfNeeded() {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        // Purely informational: touches always reach the app underneath.
        window.isUserInteractionEnabled = false
        let host = UIHostingController(rootView: LightToastOverlay(center: self))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        self.window = window
    }
}

private struct LightToastOverlay: View {
    @ObservedObject var center: LightToastCenter
    @ObservedObject private var settingsStore = SettingsStore.shared

    var body: some View {
        VStack {
            if let toast = center.current {
                HStack(spacing: 10) {
                    Image(systemName: toast.systemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(toast.tint)
                        .symbolEffect(.bounce, value: toast.id)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(toast.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(IronTheme.primaryText)
                        if let subtitle = toast.subtitle {
                            Text(subtitle)
                                .font(.footnote)
                                .foregroundStyle(IronTheme.secondaryText)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                // A frosted layer under the glass keeps text behind it (a nav title, say)
                // from showing through and competing with the message.
                .background(.regularMaterial, in: Capsule(style: .continuous))
                .ironLiquidGlassPill(tint: toast.tint.opacity(0.08))
                .padding(.horizontal, 24)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(toast.id)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity)
        .preferredColorScheme(settingsStore.appearance.colorScheme)
        .accessibilityHidden(true) // Announced through UIAccessibility instead.
    }
}
