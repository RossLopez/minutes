// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Who wrote the summary or cleanup, and a mark when it was a server outside the user's network.
struct ModelLabel: View {
    var verb = "Written by"
    let model: String
    let date: Date
    let isOffNetwork: Bool
    var identifier = "summaryModel"

    var body: some View {
        let when = date.formatted(date: .abbreviated, time: .shortened)
        let written = isOffNetwork
            ? "\(verb) \(model), outside your network, \(when)"
            : "\(verb) \(model), \(when)"
        HStack(spacing: 4) {
            if isOffNetwork {
                Image(systemName: "network")
            }
            Text(model)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
        .help(written)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(written)
        .accessibilityIdentifier(identifier)
    }
}
