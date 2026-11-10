// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import MinutesStorage

extension LibraryStore {
    func reveal(_ entry: MeetingEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.id])
    }

    func revealLibrary() {
        NSWorkspace.shared.activateFileViewerSelecting([library.root])
    }

    func openTrash() {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        NSWorkspace.shared.open(trash)
    }
}
