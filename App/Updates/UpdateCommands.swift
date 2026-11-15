// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Check for Updates… after About in the app menu, when this copy updates itself.
struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesButton()
        }
    }
}

struct CheckForUpdatesButton: View {
    private var center: UpdateCenter {
        .shared
    }

    var body: some View {
        if center.availability == .available {
            Button("Check for Updates…") {
                center.checkForUpdates()
            }
            .disabled(!center.canCheck)
        }
    }
}
