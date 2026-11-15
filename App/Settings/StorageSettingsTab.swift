// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesStorage
import SwiftUI

struct StorageSettingsTab: View {
    private let store = LibraryStore.shared

    @State private var usage: LibraryDiskUsage?

    var body: some View {
        Form {
            Section {
                LabeledContent("Location") {
                    Text(store.library.root.path(percentEncoded: false))
                        .textSelection(.enabled)
                        .truncationMode(.middle)
                        .lineLimit(1)
                }
                HStack {
                    Spacer()
                    Button("Reveal in Finder") {
                        store.revealLibrary()
                    }
                    .disabled(store.missingLocation != nil)
                    Button("Move…") {
                        Task {
                            await store.moveLibrary()
                        }
                    }
                    .disabled(store.isMovingLibrary || store.missingLocation != nil)
                    .accessibilityIdentifier("moveLibrary")
                }
                if store.isMovingLibrary {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Moving your library…")
                    }
                }
            } footer: {
                Text("Meetings stay on this Mac as plain files you can open without Minutes.")
            }

            SearchIndexSection()

            Section("Disk Used") {
                if let usage {
                    row("Audio", usage.audio)
                    row("Transcripts, Notes and Summaries", usage.meetingText)
                    row("Models", usage.models)
                    row("Search Index and Logs", usage.index)
                    row("Other", usage.other)
                    row("Total", usage.total)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: store.library.root) {
            let library = store.library
            usage = await Task.detached { LibraryDiskUsage(library: library) }.value
        }
    }

    private func row(_ title: String, _ bytes: Int64) -> some View {
        LabeledContent(title, value: bytes.formatted(.byteCount(style: .file)))
    }
}

/// How much of the library search has indexed, and rebuilding it.
private struct SearchIndexSection: View {
    private var search: SearchCenter {
        .shared
    }

    private var summary: String {
        guard let status = search.status else {
            return "Not built yet"
        }
        var text = status.meetings == 1 ? "1 meeting" : "\(status.meetings) meetings"
        if search.hasSearchModel {
            text += status.embedded < status.chunks
                ? " · Search by meaning: \(status.embedded) of \(status.chunks) passages"
                : " · Search by meaning on"
        } else {
            text += " · Searching by words only"
        }
        return text
    }

    var body: some View {
        Section {
            LabeledContent("Search index") {
                HStack(spacing: 8) {
                    if search.isUpdating {
                        ProgressView().controlSize(.small)
                    }
                    Text(summary)
                        .accessibilityIdentifier("searchIndexStatus")
                }
            }
            HStack {
                Spacer()
                Button("Rebuild Index") {
                    Task {
                        await search.rebuild()
                    }
                }
                .accessibilityIdentifier("rebuildIndex")
            }
        } footer: {
            Text("The index is built from your meeting files and kept in the library's hidden .minutes folder.")
        }
    }
}
