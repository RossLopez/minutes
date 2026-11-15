// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import MinutesSearch
import SwiftUI

/// A question, its answer with citations as links, and the sources under it.
struct ChatTurnView: View {
    let turn: ChatTurn
    var isWriting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Not selectable, with Copy in the context menu instead: selectable text in this
            // scroll view crashed the app when VoiceOver read it as an answer arrived (docs/NOTES.md).
            Text(turn.question)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.tint.opacity(0.15), in: .rect(cornerRadius: 12))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .contextMenu {
                    CopyButton(text: turn.question)
                }
                .accessibilityLabel("You: \(turn.question)")
                .accessibilityIdentifier("chatQuestionText")
            if turn.answer.isEmpty, isWriting {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Answering…")
                        .foregroundStyle(.secondary)
                }
            } else {
                MarkdownView(ChatMarkdown.answer(turn), selectable: false)
                    .environment(\.openURL, ChatLinks.openAction)
                    .contextMenu {
                        CopyButton(text: Citations.cleaned(turn.answer, count: turn.sources.count))
                    }
                    .accessibilityIdentifier("chatAnswer")
            }
            if !turn.sources.isEmpty, !isWriting || !turn.answer.isEmpty {
                ChatSourcesView(turn: turn)
            }
        }
    }
}

/// The sources an answer cites, or every source it was given when it cites none.
private struct ChatSourcesView: View {
    let turn: ChatTurn

    @State private var isExpanded = true

    private var shown: [ChatSource] {
        let cited = turn.citedSources
        return cited.isEmpty ? turn.sources : cited
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                Label(shown.count == 1 ? "1 Source" : "\(shown.count) Sources",
                      systemImage: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("chatSourcesToggle")
            if isExpanded {
                ForEach(shown) { source in
                    ChatSourceRow(source: source)
                }
            }
        }
    }
}

private struct ChatSourceRow: View {
    let source: ChatSource

    private var isAvailable: Bool {
        LibraryStore.shared.entry(forMeeting: source.meetingID) != nil
    }

    private var place: String {
        let date = source.meetingDate.formatted(date: .abbreviated, time: .omitted)
        return [source.meetingTitle, date, ChatFile.place(of: source)].joined(separator: " · ")
    }

    private var canPlay: Bool {
        isAvailable && source.start != nil && (source.kind == .transcript || source.kind == .notes)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(source.number)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(minWidth: 18, alignment: .trailing)
                .foregroundStyle(.secondary)
            Button {
                LibraryStore.shared.open(source.link)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isAvailable ? place : "\(place) · Meeting not found")
                        .font(.callout)
                    Text(source.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable)
            .help("Show this in the meeting")
            .accessibilityLabel("Source \(source.number): \(place)")
            .accessibilityHint("Shows this in the meeting")
            .accessibilityIdentifier("chatSource")
            Button("Play", systemImage: "play.circle") {
                LibraryStore.shared.open(source.link, playing: true)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(!canPlay)
            .help("Play from here")
            .accessibilityLabel("Play source \(source.number)")
            .accessibilityIdentifier("chatSourcePlay")
        }
    }
}

/// An answer's Markdown, with each citation made a link to its source's place.
enum ChatMarkdown {
    static func answer(_ turn: ChatTurn) -> String {
        Citations.pieces(of: turn.answer, count: turn.sources.count).map { piece in
            switch piece {
            case let .text(text):
                return text
            case let .source(number):
                guard let source = turn.sources.first(where: { $0.number == number }) else {
                    return ""
                }
                return "[\\[\(number)\\]](\(source.link.url.absoluteString))"
            }
        }
        .joined()
    }
}

/// Opens `minutes://` links inside the app. Other links go to the browser, as a click on any
/// link would.
@MainActor
enum ChatLinks {
    static var openAction: OpenURLAction {
        OpenURLAction { url in
            guard let link = MeetingLink(url: url) else {
                return .systemAction
            }
            LibraryStore.shared.open(link)
            return .handled
        }
    }
}

private struct CopyButton: View {
    let text: String

    var body: some View {
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
