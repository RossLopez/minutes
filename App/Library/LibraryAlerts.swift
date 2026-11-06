// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import MinutesStorage

/// Questions about where the library lives.
@MainActor
enum LibraryAlerts {
    enum MissingLibraryChoice {
        case locate
        case useDefault
        case cancel
    }

    static func askAboutMissingLibrary(at location: URL) -> MissingLibraryChoice {
        let alert = RecordingAlerts.makeAlert(
            title: "Your Minutes Folder Can't Be Found",
            message: "It was at \(location.path). If it's on a drive, connect the drive. "
                + "Nothing can be recorded until Minutes has a folder to save to.",
        )
        alert.addButton(withTitle: "Locate…")
        alert.addButton(withTitle: "Use Default Folder")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .locate
        case .alertSecondButtonReturn: return .useDefault
        default: return .cancel
        }
    }

    static func chooseFolder(prompt: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        NSApplication.shared.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func message(for error: any Error) -> String {
        let unchanged = "Your library is still where it was."
        switch error as? LibraryMover.MoveError {
        case .insideCurrentLibrary:
            return "A library can't move inside itself. \(unchanged)"
        case let .alreadyExists(url):
            return "There's already a folder at \(url.path). \(unchanged)"
        case .syncedFolder:
            return "That folder can sync to iCloud, which would take your meetings off this Mac. \(unchanged)"
        case let .notEnoughSpace(needed, available):
            let neededText = needed.formatted(.byteCount(style: .file))
            let availableText = available.formatted(.byteCount(style: .file))
            return "It needs \(neededText), and that disk has \(availableText) free. \(unchanged)"
        case .verificationFailed:
            return "The copy didn't match the original, so it was removed. \(unchanged)"
        case nil:
            return "Check that you can write to that folder, then try again. \(unchanged)"
        }
    }
}
