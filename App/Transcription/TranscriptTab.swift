// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesStorage
import SwiftUI

/// What a transcript looks like on screen. Words are left behind, so a long meeting stays small in memory.
private struct TranscriptDocument: Sendable {
    struct Line: Identifiable, Equatable, Sendable {
        /// The segment's place in `transcript.json`.
        let id: Int
        /// The speaker's ID, like `speaker-2`. Names come from `meeting.json`.
        let speaker: String
        let start: Double
        let text: String
    }

    let lines: [Line]
    /// In the order they first speak.
    let speakers: [String]

    init(_ transcript: Transcript) {
        lines = transcript.segments.enumerated().map { index, segment in
            Line(id: index, speaker: segment.speaker, start: segment.start, text: segment.text)
        }
        speakers = transcript.speakers
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

    private var speakers: SpeakerCenter {
        .shared
    }

    /// Reloads when the folder moves, a run ends or speakers change. An old transcript stays up during a new run.
    private var loadKey: String {
        "\(entry.id.path)|\(entry.metadata?.processing?.status.rawValue ?? "")|\(speakers.revisions[entry.id] ?? 0)"
    }

    private var isShowingNotice: Binding<Bool> {
        Binding(
            get: { speakers.notice != nil },
            set: { isShowing in
                if !isShowing {
                    speakers.notice = nil
                }
            },
        )
    }

    var body: some View {
        let status = center.status(for: entry)
        Group {
            if case let .ready(document) = load, !document.lines.isEmpty {
                let editing = SpeakerEditing(
                    entry: entry,
                    labels: SpeakerLabels(speakerIDs: document.speakers, metadata: entry.metadata),
                    isEnabled: speakers.canEdit(entry),
                )
                VStack(spacing: 0) {
                    if status != .idle {
                        TranscriptStatusView(entry: entry, status: status)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                    } else if editing.labels.hasUnidentifiedOthers,
                              [.installed, .notInstalled].contains(speakers.modelStatus)
                    {
                        IdentifySpeakersBanner(entry: entry)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                    }
                    TranscriptReader(player: store.player, document: document, editing: editing)
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
        .task {
            await speakers.refresh()
        }
        .alert("Speakers", isPresented: isShowingNotice) {
            Button("OK") {}
        } message: {
            Text(speakers.notice ?? "")
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
    let editing: SpeakerEditing

    var body: some View {
        TranscriptList(
            lines: document.lines,
            editing: editing,
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
    let editing: SpeakerEditing
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
                    TranscriptRow(line: line, editing: editing) {
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
    let editing: SpeakerEditing
    let onPlay: () -> Void

    @State private var isNaming = false

    private var clock: String {
        MeetingFormatting.clock(line.start)
    }

    private var label: String {
        editing.labels.label(line.speaker)
    }

    private var canChangeSpeaker: Bool {
        editing.isEnabled && line.speaker != Transcript.Speaker.me
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Button(label) {
                    isNaming = true
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
                .disabled(!editing.isEnabled)
                .help("Name this speaker")
                .accessibilityIdentifier("speakerLabel")
                .popover(isPresented: $isNaming, arrowEdge: .bottom) {
                    SpeakerPopover(editing: editing, speakerID: line.speaker) {
                        isNaming = false
                    }
                }
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
        .contextMenu {
            contextMenu
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(MeetingFormatting.spokenTime(line.start))")
        .accessibilityValue(line.text)
        .accessibilityHint("Plays the audio from this moment")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onPlay)
        .accessibilityAction(named: "Name Speaker") {
            if editing.isEnabled {
                isNaming = true
            }
        }
        .accessibilityActions {
            if canChangeSpeaker {
                ForEach(editing.labels.others(than: line.speaker)) { other in
                    Button("Change Speaker to \(other.name)") {
                        move(to: other.id)
                    }
                }
                Button("Change Speaker to New Speaker") {
                    move(to: nil)
                }
            }
        }
        .accessibilityIdentifier("transcriptLine")
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Name Speaker…") {
            isNaming = true
        }
        .disabled(!editing.isEnabled)
        if line.speaker != Transcript.Speaker.me {
            Menu("Change Speaker") {
                ForEach(editing.labels.others(than: line.speaker)) { other in
                    Button(other.name) {
                        move(to: other.id)
                    }
                }
                Divider()
                Button("New Speaker") {
                    move(to: nil)
                }
            }
            .disabled(!canChangeSpeaker)
        }
    }

    private func move(to speaker: String?) {
        let entry = editing.entry
        let index = line.id
        Task {
            await SpeakerCenter.shared.moveLine(at: index, to: speaker, in: entry)
        }
    }
}
