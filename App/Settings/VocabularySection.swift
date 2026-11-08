// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import MinutesStorage
import Observation
import os
import SwiftUI
import UniformTypeIdentifiers

/// The list behind the editor. `Vocabulary.txt` stays the source of truth, so the list reloads
/// whenever the app comes back, in case it was edited by hand. It's never written over if it can't be read.
@MainActor @Observable
private final class VocabularyEditor {
    struct Row: Identifiable, Equatable {
        let id = UUID()
        var term: String
        var variants: String

        init(term: String = "", variants: String = "") {
            self.term = term
            self.variants = variants
        }

        var entry: VocabularyEntry {
            VocabularyEntry(term: term, variants: variants.split(separator: ",").map(String.init))
        }
    }

    private static let logger = Logger(subsystem: "io.github.rosslopez.minutes", category: "vocabulary")
    private static let saveDelay = Duration.milliseconds(500)

    var rows: [Row] = [] {
        didSet {
            scheduleSave()
        }
    }

    private(set) var isUnreadable = false
    private(set) var saveFailed = false

    @ObservationIgnored private var saved: [VocabularyEntry] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private var library: MinutesLibrary {
        LibraryStore.shared.library
    }

    func reload() {
        saveNow()
        do {
            let entries = try library.loadVocabulary()
            isUnreadable = false
            saved = entries
            rows = entries.map { Row(term: $0.term, variants: $0.variants.joined(separator: ", ")) }
        } catch {
            Self.logger.error("Vocabulary unreadable: \(String(describing: type(of: error)), privacy: .public)")
            isUnreadable = true
            rows = []
        }
    }

    /// Rewrites the file only if the list really changed, because that drops any comments in it.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        let entries = Vocabulary.normalized(rows.map(\.entry))
        guard !isUnreadable, entries != saved else {
            return
        }
        do {
            try library.saveVocabulary(entries)
            saved = entries
            saveFailed = false
        } catch {
            Self.logger.error("Saving vocabulary failed: \(String(describing: type(of: error)), privacy: .public)")
            saveFailed = true
        }
    }

    func revealFile() {
        NSWorkspace.shared.activateFileViewerSelecting([library.vocabularyFile])
    }

    func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .commaSeparatedText]
        panel.prompt = "Import"
        panel.message = "Choose a text or CSV file. Its terms are added to your list."
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let imported = url.pathExtension.lowercased() == "csv" ? Vocabulary.parseCSV(text) : Vocabulary.parse(text)
            let merged = Vocabulary.merging(rows.map(\.entry), with: imported)
            rows = merged.map { Row(term: $0.term, variants: $0.variants.joined(separator: ", ")) }
            saveNow()
        } catch {
            RecordingAlerts.show(
                title: "Minutes Couldn't Read That File",
                message: "It needs to be a plain text or CSV file in UTF-8. Your list hasn't changed.",
            )
        }
    }

    func exportFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText, .commaSeparatedText]
        panel.nameFieldStringValue = "Vocabulary.txt"
        panel.message = "End the name in .csv to save a CSV file."
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        let entries = rows.map(\.entry)
        let text = url.pathExtension.lowercased() == "csv" ? Vocabulary.renderCSV(entries) : Vocabulary.render(entries)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            RecordingAlerts.show(
                title: "Minutes Couldn't Save That File",
                message: "Check that the folder is available, then try again.",
            )
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: Self.saveDelay)
            if !Task.isCancelled {
                saveNow()
            }
        }
    }
}

/// Terms to get right, and what speech recognition tends to hear instead.
struct VocabularySection: View {
    @State private var editor = VocabularyEditor()

    var body: some View {
        Section {
            if editor.isUnreadable {
                unreadable
            } else {
                ForEach($editor.rows) { $row in
                    HStack {
                        TextField("Term", text: $row.term, prompt: Text("Term"))
                            .labelsHidden()
                            .accessibilityLabel("Term")
                        TextField("Heard as", text: $row.variants, prompt: Text("Often heard as, split by commas"))
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .accessibilityLabel("Often heard as")
                        Button("Remove", systemImage: "minus.circle") {
                            editor.rows.removeAll { $0.id == row.id }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(row.term)")
                    }
                }
                actions
            }
        } header: {
            Text("Custom Vocabulary")
        } footer: {
            Text(
                """
                Apple Speech can't listen for your terms, so it only replaces what you list under “often heard as”. \
                Parakeet does both. A new list applies to new transcripts, or use Transcribe Again on a meeting.
                """,
            )
        }
        .onAppear {
            editor.reload()
        }
        .onDisappear {
            editor.saveNow()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            editor.reload()
        }
    }

    private var actions: some View {
        HStack {
            Button("Add Term", systemImage: "plus") {
                editor.rows.append(VocabularyEditor.Row())
            }
            .accessibilityIdentifier("vocabularyAdd")
            Spacer()
            if editor.saveFailed {
                Text("Couldn't save your list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Import…") {
                editor.importFile()
            }
            Button("Export…") {
                editor.saveNow()
                editor.exportFile()
            }
        }
    }

    private var unreadable: some View {
        HStack {
            Label(
                "Vocabulary.txt isn't a text file, so Minutes left it alone.",
                systemImage: "exclamationmark.triangle",
            )
            Spacer()
            Button("Reveal in Finder") {
                editor.revealFile()
            }
        }
    }
}
