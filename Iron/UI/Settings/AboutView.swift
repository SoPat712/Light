//
//  AboutView.swift
//  Iron
//
//  Created by Karim Abou Zeid on 04.03.20.
//  Copyright © 2020 Karim Abou Zeid Software. All rights reserved.
//

import SwiftUI

struct AboutView: View {
    var body: some View {
        List {
            Section {
                appSummary
            }

            Section("Light") {
                aboutLinkRow(
                    AboutLink(
                        title: "Source code",
                        subtitle: "View the project on GitHub",
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        url: URL(string: "https://github.com/SoPat712/Iron")!
                    )
                )
                aboutLinkRow(
                    AboutLink(
                        title: "Built on Iron",
                        subtitle: "Original app by Karim Abou Zeid · GPL v3",
                        systemImage: "globe",
                        url: URL(string: "https://github.com/karimknaebel/Iron")!
                    )
                )
            }

            Section("Privacy") {
                privacySummary
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: IronTheme.floatingWorkoutBottomClearance - 36)
        }
        .navigationTitle("About Light")
        .navigationBarTitleDisplayMode(.inline)
        .ironScreen()
    }

    private var appSummary: some View {
        HStack(spacing: 16) {
            Image("AppIconRounded")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: IronTheme.compactCornerRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("Light")
                    .font(.title2.weight(.semibold))
                    .foregroundColor(IronTheme.primaryText)
                Text("Private strength training")
                    .font(.subheadline)
                    .foregroundColor(IronTheme.secondaryText)
                Text("Version \(versionString)")
                    .font(.ironMetric(.subheadline, weight: .semibold))
                    .foregroundColor(IronTheme.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
    }

    private func aboutLinkRow(_ row: AboutLink) -> some View {
        Link(destination: row.url) {
            HStack(spacing: 12) {
                SettingsSubpageLabel(row.title, detail: row.subtitle, systemImage: row.systemImage)

                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(IronTheme.tertiaryText)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityHint("Opens in your browser")
    }

    private var privacySummary: some View {
        SettingsSubpageLabel(
            "Private by design",
            detail: "Light has no social feed or public profile. Your workout and body data remain under your control.",
            systemImage: "person.crop.circle.badge.checkmark"
        )
    }

    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        #if DEBUG
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return "\(version ?? "?") (\(build ?? "?"))"
        #else
        return version ?? "?"
        #endif
    }
}

private struct AboutLink: Identifiable {
    let title: String
    let subtitle: String
    let systemImage: String
    let url: URL

    var id: String { title }
}

#if DEBUG
struct AboutView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            AboutView().mockEnvironment(weightUnit: .metric)
        }
        .preferredColorScheme(.dark)
    }
}
#endif
