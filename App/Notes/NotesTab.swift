// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesStorage
import SwiftUI

/// The editor for one meeting's notes, wired to autosave, focus and the player.
struct NotesEditorPane: View {
    let store: LibraryStore
    let document: NotesDocument
    var bottomInset: CGFloat = 0
    var placeholder = "Type notes here."

    private var center: NotesCenter {
        .shared
    }

    var body: some View {
        let isRecording = center.isRecording(document)
        VStack(alignment: .leading, spacing: 6) {
            if let failure = document.saveFailure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }
            NotesTextView(
                text: document.text,
                times: document.times,
                bottomInset: bottomInset,
                canPlay: !isRecording && store.player.loadedFolder == document.folder,
                onChange: { center.edit(document, text: $0) },
                onPlay: { store.player.play(from: $0) },
                onFocus: { store.isEditingNotes = $0 },
            )
            .overlay(alignment: .topLeading) {
                if document.text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        // Past the time margin and the text's own inset.
                        .padding(.leading, 61)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .onDisappear {
            store.isEditingNotes = false
            center.flush(document.folder)
        }
    }
}

/// What the detail shows while a meeting is being recorded: its notes, with the HUD over them.
struct RecordingNotesView: View {
    let store: LibraryStore
    let entry: MeetingEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Recording", systemImage: "record.circle")
                    .font(.title2.weight(.semibold))
                    .symbolRenderingMode(.multicolor)
                Text("Notes save as you type, and each line is timed against the recording.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            if let document = NotesCenter.shared.document(for: entry) {
                NotesEditorPane(store: store, document: document, bottomInset: 150,
                                placeholder: "Type notes about the meeting here.")
            }
        }
    }
}

/// The Notes tab after a meeting: the notes to edit, cleanup, and the cleaned-up version.
struct NotesTab: View {
    let store: LibraryStore
    let entry: MeetingEntry

    @AppStorage("notes.showsCleaned") private var showsCleaned = false

    private var center: NotesCenter {
        .shared
    }

    var body: some View {
        if let document = center.document(for: entry) {
            Group {
                if let run = center.cleanup(for: document) {
                    NotesReview(document: document, run: run)
                } else {
                    content(document)
                }
            }
            .onAppear {
                center.reloadIfChanged(document)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                center.reloadIfChanged(document)
            }
        } else {
            ContentUnavailableView("Minutes Can't Read These Notes", systemImage: "exclamationmark.triangle")
        }
    }

    private func content(_ document: NotesDocument) -> some View {
        let showingCleaned = showsCleaned && document.cleanedText != nil
        return VStack(alignment: .leading, spacing: 12) {
            toolbar(document, showingCleaned: showingCleaned)
                .padding(.horizontal, 20)
            if showingCleaned, let cleaned = document.cleanedText {
                ScrollView {
                    MarkdownView(cleaned)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                        .accessibilityIdentifier("cleanedNotes")
                }
            } else {
                NotesEditorPane(store: store, document: document,
                                placeholder: "You didn't take notes in this meeting. Type here to add some.")
            }
        }
    }

    private func toolbar(_ document: NotesDocument, showingCleaned: Bool) -> some View {
        HStack(spacing: 12) {
            if document.cleanedText != nil {
                Picker("Notes", selection: $showsCleaned) {
                    Text("As Typed").tag(false)
                    Text("Cleaned Up").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("notesVersion")
            }
            if showingCleaned, let cleaned = document.cleaned {
                ModelLabel(
                    verb: "Cleaned up by",
                    model: SummaryCenter.shared.modelName(for: cleaned.model) ?? cleaned.model,
                    date: cleaned.createdAt,
                    isOffNetwork: SummaryCenter.shared.isOffNetwork(cleaned.model),
                    identifier: "cleanedNotesModel",
                )
            }
            Spacer()
            if !center.hasCleanupModel {
                Button("Choose a Model…") {
                    RecordingController.shared.openSettings(.aiModels)
                }
                .buttonStyle(.link)
            }
            let title = document.cleanedText == nil ? "Clean Up Notes" : "Clean Up Again"
            Button(title, systemImage: "wand.and.sparkles") {
                showsCleaned = false
                center.startCleanup(of: document)
            }
            .disabled(!document.hasText || !center.hasCleanupModel || center.isRecording(document))
            .help(cleanupHelp(document))
            .accessibilityIdentifier("cleanUpNotes")
        }
    }

    private func cleanupHelp(_ document: NotesDocument) -> String {
        if !document.hasText {
            "There are no notes to clean up."
        } else if !center.hasCleanupModel {
            "Choose a model for notes cleanup in Settings."
        } else {
            "Tidy the notes with the transcript's help. Your notes as typed are kept."
        }
    }
}
