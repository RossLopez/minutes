// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Meeting actions in the File menu, acting on the selected meeting.
struct MeetingCommands: Commands {
    private let store = LibraryStore.shared

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find") {
                store.requestSearch()
            }
            .keyboardShortcut("f")
        }

        CommandGroup(after: .newItem) {
            Button("Rename Meeting") {
                if let entry = store.selectedEntry {
                    store.requestRename(of: entry)
                }
            }
            .disabled(!store.canActOnSelection || store.selectedEntry?.canRename != true)

            Button("Reveal in Finder") {
                if let entry = store.selectedEntry {
                    store.reveal(entry)
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(store.selectedEntry == nil)

            Button("Move to Trash") {
                if let entry = store.selectedEntry {
                    Task {
                        await store.moveToTrash(entry)
                    }
                }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            // While typing, ⌘⌫ deletes text instead.
            .disabled(!store.canActOnSelection || store.isEditingText)
        }
    }
}
