// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import MinutesStorage
import SwiftUI

/// An older summary in a meeting's `summaries/` folder, named `<yyyy-MM-dd HHmmss> <template>.md`.
struct PreviousSummary: Identifiable, Hashable {
    let url: URL

    var id: URL {
        url
    }

    private var parts: (date: Date?, template: String) {
        let name = url.deletingPathExtension().lastPathComponent
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let stamp = String(name.prefix(17))
        guard let date = formatter.date(from: stamp) else {
            return (nil, name)
        }
        return (date, String(name.dropFirst(18)))
    }

    var title: String {
        let (date, template) = parts
        guard let date else {
            return template
        }
        return "\(date.formatted(date: .abbreviated, time: .shortened)) · \(template)"
    }
}

/// Lists a meeting's older summaries, newest first.
struct PreviousVersionsMenu: View {
    let folder: MeetingFolder
    @Binding var selection: PreviousSummary?

    var body: some View {
        let versions = folder.previousSummaries().map(PreviousSummary.init)
        Menu("Previous Versions", systemImage: "clock.arrow.circlepath") {
            ForEach(versions) { version in
                Button(version.title) {
                    selection = version
                }
            }
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(versions.isEmpty)
        .help(versions.isEmpty ? "No previous versions" : "Previous Versions")
        .accessibilityIdentifier("summaryPreviousVersions")
    }
}

/// Shows an older summary, read only.
struct PreviousSummarySheet: View {
    let version: PreviousSummary

    @Environment(\.dismiss) private var dismiss
    @State private var text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(version.title)
                .font(.headline)
            ScrollView {
                if let text {
                    MarkdownView(text)
                        .accessibilityIdentifier("previousSummaryText")
                } else {
                    Text("Minutes can't read this file.")
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([version.url])
                }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text ?? "", forType: .string)
                }
                .disabled(text == nil)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
        .task {
            text = try? String(contentsOf: version.url, encoding: .utf8)
        }
    }
}
