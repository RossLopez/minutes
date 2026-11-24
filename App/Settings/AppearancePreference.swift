// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Light or dark for Minutes alone, or the Mac's own appearance, in Settings › General.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let key = "general.appearance"

    static var saved: AppearancePreference {
        UserDefaults.standard.string(forKey: key).flatMap(AppearancePreference.init) ?? .system
    }

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Set on the app rather than per scene, so the main window, Settings and the menu bar item all
    /// follow it, and nil gives the Mac's appearance back.
    @MainActor
    func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
