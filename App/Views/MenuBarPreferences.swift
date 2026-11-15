// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Observation

/// Whether Minutes shows its menu bar item. While recording it always does, so Stop stays in reach.
@MainActor @Observable
final class MenuBarPreferences {
    static let shared = MenuBarPreferences()
    static let showsIconKey = "general.showsMenuBarIcon"

    var showsIcon: Bool {
        didSet {
            UserDefaults.standard.set(showsIcon, forKey: Self.showsIconKey)
        }
    }

    private init() {
        // `bool(forKey:)` also understands a launch argument's "NO", a string rather than a Bool.
        showsIcon = UserDefaults.standard.object(forKey: Self.showsIconKey) == nil
            || UserDefaults.standard.bool(forKey: Self.showsIconKey)
    }

    /// Settings opens from a view, and the menu bar label is the one that's always there. When it's
    /// hidden, choose Settings… from the app menu instead.
    static func openSettingsFromAppMenu() {
        guard let menu = NSApplication.shared.mainMenu?.items.first?.submenu,
              let index = menu.items
                  .firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command })
        else {
            return
        }
        NSApplication.shared.activate()
        menu.performActionForItem(at: index)
    }
}
