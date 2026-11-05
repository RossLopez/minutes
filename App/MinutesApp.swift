// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

@main
struct MinutesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Minutes", id: SceneID.mainWindow) {
            MainWindowView()
        }

        Settings {
            SettingsView()
        }

        MenuBarExtra {
            MenuBarContent()
        } label: {
            // Without this label VoiceOver reads the symbol's name, "Audio Waveform".
            Image(systemName: "waveform")
                .accessibilityLabel("Minutes")
        }
    }
}

enum SceneID {
    static let mainWindow = "main"
}
