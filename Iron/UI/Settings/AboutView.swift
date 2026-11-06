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
                LabeledContent("Version") {
                    Text(versionString)
                        .font(.ironMetric(.body, weight: .semibold))
                }
            } footer: {
                Text("Light · Private strength training")
            }

            Section {
                Link("Source Code", destination: URL(string: "https://github.com/SoPat712/Light")!)
                    .accessibilityHint("Opens in your browser")
                Link("Built on Iron", destination: URL(string: "https://github.com/karimknaebel/Iron")!)
                    .accessibilityHint("Opens in your browser")
            } header: {
                Text("Source Code")
            } footer: {
                Text("Original app by Karim Abou Zeid · GPL v3")
            }

            Section("Privacy") {
                Text("Private by design. Light has no social feed or public profile. Your workout and body data remain under your control.")
                    .font(.subheadline)
                    .foregroundStyle(IronTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                NavigationLink("Licenses & Attributions", destination: LicensesAttributionsView())
            }
        }
        .labeledContentStyle(SettingsValueStyle())
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: IronTheme.floatingWorkoutBottomClearance - 36)
        }
        .navigationTitle("About Light")
        .navigationBarTitleDisplayMode(.inline)
        .ironScreen()
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
