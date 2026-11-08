// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesStorage
import SwiftUI

/// What a transcript looks like on screen. Words are left behind, so a long meeting stays small in memory.
private struct TranscriptDocument: Sendable {
    struct Line: Identifiable, Equatable, Sendable {
        let id: Int
        let speaker: String
        let start: Double
        let text: String
    }

    let lines: [Line]

    init(_ transcript: Transcript) {
        lines = transcript.segments.enumerated().map { index, segment in
            Line(
                id: index,
                speaker: Transcript.displayName(forSpeaker: segment.speaker),
                start: segment.start,
                text: segment.text,
            )
        }
    }

    /// The latest line to start at or before a moment in the audio.
    func lineID(at seconds: Double) -> Int? {
        var low = 0
        var high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].start <= seconds {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low > 0 ? low - 1 : nil
    }
}

private enum TranscriptLoad {
    case loading
    case missing
    case unreadable
    case newerVersion
    case ready(TranscriptDocument)

    static func from(_ folder: MeetingFolder) -> TranscriptLoad {
        guard FileManager.default.fileExists(atPath: folder.transcriptJSON.path) else {
            return .missing
        }
        do {
            let transcript = try folder.loadTranscript()
            return transcript.isNewerThanThisApp ? .newerVersion : .ready(TranscriptDocument(transcript))
        } catch {
            return .unreadable
        }
    }
}

/// The Transcript tab: progress while there's work to do, then the transcript itself.
struct TranscriptTab: View {
    let store: LibraryStore
    let entry: MeetingEntry

    @State private var load = TranscriptLoad.loading

    private var center: TranscriptionCenter {
        .shared
    }

    /// Reloads when the folder moves or a run ends. An old transcript stays up during a new run.
    private var loadKey: String {
        "\(entry.id.path)|\(entry.metadata?.processing?.status.rawValue ?? "")"
    }

    var body: some View {
        let status = center.status(for: entry)
        Group {
            if case let .ready(document) = load, !document.lines.isEmpty {
                VStack(spacing: 0) {
                    if status != .idle {
                        TranscriptStatusView(entry: entry, status: status)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                    }
                    TranscriptReader(player: store.player, document: document)
                }
            } else if status == .newerVersion {
                newerVersion
            } else if status == .idle {
                placeholder
            } else {
                TranscriptStatusView(entry: entry, status: status)
                    .frame(maxWidth: 460)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: loadKey) {
            let folder = entry.folder
            load = await Task.detached { TranscriptLoad.from(folder) }.value
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        switch load {
        case .loading:
            Color.clear
        case .ready:
            ContentUnavailableView(
                "No Speech Found",
                systemImage: "waveform.slash",
                description: Text("Minutes didn't hear any words on either track."),
            )
            .accessibilityIdentifier("transcriptNoSpeech")
        case .missing:
            TranscriptStatusView(entry: entry, status: .notStarted)
                .frame(maxWidth: 460)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unreadable:
            ContentUnavailableView {
                Label("Minutes Can't Read This Transcript", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Its transcript.json is damaged. Transcribing again makes a new one from the audio.")
            } actions: {
                Button("Transcribe Again") {
                    center.transcribe(entry)
                }
                .disabled(center.transcribeTitle(for: entry) == nil)
            }
        case .newerVersion:
            newerVersion
        }
    }

    private var newerVersion: some View {
        ContentUnavailableView(
            "Made by a Newer Version of Minutes",
            systemImage: "arrow.up.circle",
            description: Text("Update Minutes to transcribe this meeting or read its transcript."),
        )
    }
}

/// Follows the player: it's split from the list so that only a change of line redraws the list.
private struct TranscriptReader: View {
    let player: PlayerModel
    let document: TranscriptDocument

    var body: some View {
        TranscriptList(
            lines: document.lines,
            currentLine: document.lineID(at: player.state.currentTime),
            isPlaying: player.state.isPlaying,
            onSelect: { player.seek(to: $0.start) },
            onPlay: { player.play(from: $0.start) },
        )
    }
}

private struct TranscriptList: View {
    /// A reader who scrolled away is left alone for this long before the list follows playback again.
    private static let scrollPause = Duration.seconds(8)

    let lines: [TranscriptDocument.Line]
    let currentLine: Int?
    let isPlaying: Bool
    let onSelect: (TranscriptDocument.Line) -> Void
    let onPlay: (TranscriptDocument.Line) -> Void

    @State private var lastUserScroll: ContinuousClock.Instant?

    var body: some View {
        ScrollViewReader { proxy in
            // Selection is the current line, so arrow keys move through the meeting and VoiceOver can reach every line.
            List(selection: Binding(
                get: { currentLine },
                set: { id in
                    if let id, id != currentLine {
                        onSelect(lines[id])
                    }
                },
            )) {
                ForEach(lines) { line in
                    TranscriptRow(line: line) {
                        onPlay(line)
                    }
                    .tag(line.id)
                }
            }
            .listStyle(.inset)
            .accessibilityIdentifier("transcriptList")
            .onKeyPress(.return) {
                guard let currentLine else {
                    return .ignored
                }
                onPlay(lines[currentLine])
                return .handled
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .decelerating || phase == .tracking {
                    lastUserScroll = .now
                }
            }
            .onChange(of: currentLine) {
                guard isPlaying, let currentLine else {
                    return
                }
                if let lastUserScroll, lastUserScroll.duration(to: .now) < Self.scrollPause {
                    return
                }
                // Centered, because the player bar floats over the bottom of the list.
                proxy.scrollTo(currentLine, anchor: .center)
            }
        }
    }
}

private struct TranscriptRow: View {
    let line: TranscriptDocument.Line
    let onPlay: () -> Void

    private var clock: String {
        MeetingFormatting.clock(line.start)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(line.speaker)
                    .font(.callout.weight(.semibold))
                Text(clock)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(line.text)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        // Simultaneous, so a click also selects the row. It restarts a line that's already current.
        .simultaneousGesture(TapGesture().onEnded(onPlay))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(line.speaker), \(MeetingFormatting.spokenTime(line.start))")
        .accessibilityValue(line.text)
        .accessibilityHint("Plays the audio from this moment")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onPlay)
        .accessibilityIdentifier("transcriptLine")
    }
}
