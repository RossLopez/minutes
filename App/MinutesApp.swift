// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

@main
struct MinutesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Shown while recording even when turned off, so Stop is always in reach. Not `@AppStorage`:
    /// reading that here loops SwiftUI's updates on macOS 27 (docs/NOTES.md).
    private var menuBarInserted: Binding<Bool> {
        Binding(
            get: { MenuBarPreferences.shared.showsIcon || RecordingController.shared.isRecording },
            set: { MenuBarPreferences.shared.showsIcon = $0 },
        )
    }

    var body: some Scene {
        Window("Minutes", id: SceneID.mainWindow) {
            MainWindowView()
        }
        .commands {
            MeetingCommands()
            UpdateCommands()
        }

        Settings {
            SettingsView()
        }

        MenuBarExtra(isInserted: menuBarInserted) {
            MenuBarContent()
        } label: {
            MenuBarLabel()
        }
    }
}

enum SceneID {
    static let mainWindow = "main"
}
