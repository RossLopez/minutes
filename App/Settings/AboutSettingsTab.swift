// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct AboutSettingsTab: View {
    private static let sourceURL = URL(string: "https://github.com/RossLopez/minutes")!
    private static let licenseURL = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(marketing) (\(build))"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)

            Text("Minutes")
                .font(.title)

            Text(version)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text(
                """
                Copyright © 2026 Ross Lopez. Minutes is free software, licensed under the GNU General \
                Public License, version 3 or any later version. It comes with absolutely no warranty.
                """,
            )
            .multilineTextAlignment(.center)
            .frame(maxWidth: 440)

            HStack(spacing: 16) {
                Link("Source Code", destination: Self.sourceURL)
                Link("GNU GPL v3", destination: Self.licenseURL)
                if let notices = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") {
                    Button("Third-Party Notices") {
                        NSWorkspace.shared.open(notices)
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
