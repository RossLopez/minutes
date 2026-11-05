// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Start Recording") {}
            .disabled(true)

        Divider()

        Button("Open Minutes") {
            NSApplication.shared.activate()
            openWindow(id: SceneID.mainWindow)
        }

        Button("Settings…") {
            NSApplication.shared.activate()
            openSettings()
        }

        Divider()

        Button("Quit Minutes") {
            NSApplication.shared.terminate(nil)
        }
    }
}
