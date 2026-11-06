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
