// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesLLM
import SwiftUI

/// A cleanup beside the notes it came from: streaming while it's written, then the differences
/// marked, to accept or discard.
struct NotesReview: View {
    let document: NotesDocument
    let run: NotesCleanupRun

    @AccessibilityFocusState private var isResultFocused: Bool
    /// Accepting shows the cleaned-up notes.
    @AppStorage("notes.showsCleaned") private var showsCleaned = false

    private var center: NotesCenter {
        .shared
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .padding(.horizontal, 20)
            Group {
                if run.phase == .finished {
                    DiffColumns(diff: SideBySideDiff(old: run.original, new: run.text))
                } else {
                    streaming
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .onChange(of: run.phase) {
            if run.phase == .finished {
                AccessibilityNotification.Announcement("Cleanup finished. Review it, then accept or discard.").post()
                isResultFocused = true
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Your Notes")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Cleaned Up")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityFocused($isResultFocused)
        }
    }

    private var streaming: some View {
        HStack(alignment: .top, spacing: 16) {
            ScrollView {
                Text(run.original)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch run.phase {
                    case let .waiting(message):
                        ProgressView(message)
                            .controlSize(.small)
                    case let .failed(message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .accessibilityIdentifier("cleanupFailure")
                    case .writing where run.text.isEmpty:
                        ProgressView("Reading the transcript…")
                            .controlSize(.small)
                    case .writing, .finished:
                        Text(run.text)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("cleanupStreaming")
        }
        .padding(.horizontal, 20)
    }

    private var footer: some View {
        HStack {
            if run.phase == .finished, document.text != run.original {
                Label("Your notes changed since this cleanup started.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if run.isRunning {
                Button("Stop", systemImage: "stop.fill") {
                    run.cancel()
                }
                .accessibilityIdentifier("cleanupStop")
            } else if case .failed = run.phase {
                Button("Close") {
                    center.discardCleanup(of: document)
                }
                Button("Try Again") {
                    center.startCleanup(of: document)
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Discard") {
                    center.discardCleanup(of: document)
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("cleanupDiscard")
                Button("Accept") {
                    if center.acceptCleanup(of: document) {
                        showsCleaned = true
                    } else {
                        RecordingAlerts.show(
                            title: "Minutes Couldn't Save the Cleaned-Up Notes",
                            message: "Your notes are unchanged. Check that the meeting's folder is still there.",
                        )
                    }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("cleanupAccept")
            }
        }
    }
}

/// The two versions in rows that line up, with removed and added lines tinted and the words that
/// changed inside edited lines marked.
private struct DiffColumns: View {
    let diff: SideBySideDiff

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(diff.rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 16) {
                        cell(row.left, kind: row.kind, side: .left)
                        cell(row.right, kind: row.kind, side: .right)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .accessibilityIdentifier("cleanupDiff")
    }

    private enum Side {
        case left
        case right
    }

    private func cell(_ segments: [SideBySideDiff.Segment]?, kind: SideBySideDiff.Kind, side: Side) -> some View {
        let tint: Color = side == .left ? .red : .green
        let isTinted = segments != nil && kind != .unchanged
        return Text(attributed(segments ?? [], mark: tint))
            .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(isTinted ? tint.opacity(0.08) : .clear, in: .rect(cornerRadius: 4))
            .textSelection(.enabled)
            .accessibilityLabel(label(segments, kind: kind, side: side))
    }

    private func attributed(_ segments: [SideBySideDiff.Segment], mark: Color) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            var part = AttributedString(segment.text)
            if segment.isChanged {
                part.backgroundColor = mark.opacity(0.22)
            }
            result += part
        }
        return result
    }

    private func label(_ segments: [SideBySideDiff.Segment]?, kind: SideBySideDiff.Kind, side: Side) -> String {
        let text = segments?.map(\.text).joined() ?? ""
        switch (kind, side) {
        case (.unchanged, _): return text
        case (_, .left): return segments == nil ? "" : "Removed: \(text)"
        case (_, .right): return segments == nil ? "" : "Added: \(text)"
        }
    }
}
