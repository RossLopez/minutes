// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

@main
struct MinutesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Minutes", id: SceneID.mainWindow) {
            MainWindowView()
        }
        .commands {
            MeetingCommands()
        }

        Settings {
            SettingsView()
        }

        MenuBarExtra {
            MenuBarContent()
        } label: {
            MenuBarLabel()
        }
    }
}

enum SceneID {
    static let mainWindow = "main"
}
