// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesStorage
import SwiftUI

/// Meeting actions in the File menu, acting on the selected meeting.
struct MeetingCommands: Commands {
    private let store = LibraryStore.shared
    private let center = TranscriptionCenter.shared

    /// The selected meeting, if it's a finished one with audio to transcribe.
    private var transcribeEntry: MeetingEntry? {
        guard let entry = store.selectedEntry, MeetingDisplayState(entry: entry) == .ready else {
            return nil
        }
        return entry
    }

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

            Button(transcribeEntry.flatMap(center.transcribeTitle) ?? "Transcribe") {
                if let transcribeEntry {
                    center.transcribe(transcribeEntry)
                }
            }
            .disabled(transcribeEntry.flatMap(center.transcribeTitle) == nil)

            Button("Identify Speakers") {
                if let transcribeEntry {
                    SpeakerCenter.shared.identifySpeakers(in: transcribeEntry)
                }
            }
            .disabled(transcribeEntry.map(SpeakerCenter.shared.canIdentifySpeakers) != true)

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
