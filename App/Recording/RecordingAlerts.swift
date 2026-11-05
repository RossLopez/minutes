// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Alerts the recorder shows. They're `NSAlert`s because recording can start from the menu bar
/// or global shortcut, with no window open to attach a SwiftUI alert to.
@MainActor
enum RecordingAlerts {
    enum MissingPermission {
        case microphone
        case systemAudio
    }

    static func show(title: String, message: String) {
        let alert = makeAlert(title: title, message: message)
        alert.runModal()
    }

    /// Returns whether the user wants the Permissions tab.
    static func askToOpenPermissions(_ permission: MissingPermission) -> Bool {
        let alert = switch permission {
        case .microphone:
            makeAlert(
                title: "Minutes Needs Microphone Access",
                message: "Minutes records your microphone so it can transcribe what you say. Nothing leaves this Mac.",
            )
        case .systemAudio:
            makeAlert(
                title: "Minutes Needs System Audio Access",
                message: "Minutes records what your Mac plays so it can transcribe what other people say. "
                    + "Nothing leaves this Mac.",
            )
        }
        alert.addButton(withTitle: "Open Permissions")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func confirmQuitWhileRecording() -> Bool {
        let alert = makeAlert(
            title: "Stop Recording and Quit?",
            message: "Your recording is kept. Minutes finishes saving it the next time you open the app.",
        )
        alert.addButton(withTitle: "Keep Recording")
        alert.addButton(withTitle: "Stop and Quit")
        return alert.runModal() == .alertSecondButtonReturn
    }

    static func confirmQuitWhileSaving() -> Bool {
        let alert = makeAlert(
            title: "Minutes Is Still Saving",
            message: "If you quit now, Minutes finishes saving the next time you open the app.",
        )
        alert.addButton(withTitle: "Keep Saving")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn
    }

    static func makeAlert(title: String, message: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApplication.shared.activate()
        return alert
    }
}
