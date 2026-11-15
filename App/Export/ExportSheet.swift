// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import MinutesStorage
import os
import SwiftUI
import UniformTypeIdentifiers

/// Chooses what of a meeting to export and how, then copies it or saves it as a file.
struct ExportSheet: View {
    let entry: MeetingEntry

    @Environment(\.dismiss) private var dismiss
    @AppStorage("export.summary") private var includesSummary = true
    @AppStorage("export.notes") private var includesNotes = true
    @AppStorage("export.typedNotes") private var includesTypedNotes = false
    @AppStorage("export.transcript") private var includesTranscript = true
    @AppStorage("export.format") private var format = MeetingExporter.Format.markdown

    @State private var source: MeetingExporter.Source?
    @State private var problem: String?
    @State private var copied = false

    private static let logger = Logger(subsystem: "io.github.rosslopez.minutes", category: "export")

    private var contents: MeetingExporter.Contents {
        var contents: MeetingExporter.Contents = []
        if includesSummary {
            contents.insert(.summary)
        }
        if includesNotes {
            contents.insert(.notes)
        }
        if includesNotes, includesTypedNotes {
            contents.insert(.typedNotes)
        }
        if includesTranscript {
            contents.insert(.transcript)
        }
        return contents
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export “\(entry.title)”")
                .font(.headline)
            Form {
                Section("Include") {
                    Toggle("Summary", isOn: $includesSummary)
                        .disabled(source?.summary == nil)
                        .accessibilityIdentifier("exportSummary")
                    Toggle("Notes", isOn: $includesNotes)
                        .disabled(source?.notes == nil && source?.cleanedNotes == nil)
                        .accessibilityIdentifier("exportNotes")
                    if source?.cleanedNotes != nil, source?.notes != nil {
                        Toggle("Also include notes as typed", isOn: $includesTypedNotes)
                            .disabled(!includesNotes)
                            .padding(.leading, 20)
                    }
                    Toggle("Transcript", isOn: $includesTranscript)
                        .disabled(source?.transcript == nil)
                        .accessibilityIdentifier("exportTranscript")
                }
                Picker("Format", selection: $format) {
                    Text("Markdown").tag(MeetingExporter.Format.markdown)
                    Text("Plain Text").tag(MeetingExporter.Format.plainText)
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("exportFormat")
            }
            .formStyle(.grouped)
            .toggleStyle(.checkbox)
            .scrollDisabled(true)
            if let problem {
                Text(problem)
                    .foregroundStyle(.red)
            }
            HStack {
                if copied {
                    Label("Copied", systemImage: "checkmark")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("exportCopied")
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Copy") {
                    copy()
                }
                .disabled(source == nil)
                .accessibilityIdentifier("exportCopy")
                Button("Save…") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(source == nil)
                .accessibilityIdentifier("exportSave")
            }
        }
        .padding(20)
        .frame(width: 420)
        .task {
            let folder = entry.folder
            do {
                source = try await Task.detached { try MeetingExporter.Source(folder: folder) }.value
            } catch {
                problem = "Minutes couldn't read this meeting."
                Self.logger.error("Export read failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func text() -> String? {
        source.map { MeetingExporter.export($0, contents: contents, format: format) }
    }

    private func copy() {
        guard let text = text() else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }

    private func save() {
        guard let text = text() else {
            return
        }
        let name = entry.folder.url.lastPathComponent + "." + format.fileExtension
        #if DEBUG
            // UI tests can't drive the save panel, which runs in another process.
            if let folder = ProcessInfo.processInfo.environment["MINUTES_TEST_EXPORT"] {
                write(text, to: URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent(name))
                return
            }
        #endif
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        let markdown = UTType(filenameExtension: "md") ?? .plainText
        panel.allowedContentTypes = [format == .markdown ? markdown : .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        write(text, to: url)
    }

    private func write(_ text: String, to url: URL) {
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            dismiss()
        } catch {
            problem = "Minutes couldn't save the file. \(error.localizedDescription)"
        }
    }
}
