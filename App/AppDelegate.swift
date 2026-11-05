// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// A recording must keep going after the main window closes, and the menu bar item must stay available.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }
}
