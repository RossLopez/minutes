// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension LibraryStore {
    /// Keeps ⌘⌫ and Space away from the meeting and player while someone is typing.
    var isEditingText: Bool {
        isEditingTitle || isEditingSearch || isEditingNotes
    }

    /// Moves a file Minutes replaced to the Trash, or the UI tests' stand-in for it.
    func discard(_ file: URL) throws {
        if let trashFolderForTests {
            try FileManager.default.createDirectory(at: trashFolderForTests, withIntermediateDirectories: true)
            let name = "\(UUID().uuidString) \(file.lastPathComponent)"
            try FileManager.default.moveItem(at: file, to: trashFolderForTests.appendingPathComponent(name))
        } else {
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        }
    }

    /// Shows the meeting being recorded, with its notes.
    func showRecording() {
        guard let folder = RecordingController.shared.activeFolder else {
            return
        }
        sidebarItem = .allMeetings
        searchText = ""
        select(folder)
    }
}
