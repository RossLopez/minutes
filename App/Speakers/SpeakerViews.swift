// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesStorage
import SwiftUI

/// What each speaker in one meeting is called, from its transcript and `meeting.json`.
struct SpeakerLabels: Equatable {
    struct Speaker: Identifiable, Equatable {
        let id: String
        let name: String
        let isNamed: Bool
        let suggestion: String?
    }

    /// In the order they first speak.
    let speakers: [Speaker]

    init(speakerIDs: [String], metadata: MeetingMetadata?) {
        speakers = speakerIDs.map { id in
            Speaker(
                id: id,
                name: metadata?.displayName(forSpeaker: id) ?? Transcript.displayName(forSpeaker: id),
                isNamed: metadata?.speakers?[id]?.name != nil,
                suggestion: metadata?.speakers?[id]?.suggestion?.name,
            )
        }
    }

    func speaker(_ id: String) -> Speaker {
        speakers.first { $0.id == id }
            ?? Speaker(id: id, name: Transcript.displayName(forSpeaker: id), isNamed: false, suggestion: nil)
    }

    /// "Speaker 2 · Sam?" while a name is only suggested.
    func label(_ id: String) -> String {
        let speaker = speaker(id)
        guard let suggestion = speaker.suggestion, !speaker.isNamed else {
            return speaker.name
        }
        return "\(speaker.name) · \(suggestion)?"
    }

    /// Everyone a line from `id` could be moved to or merged with. Me is the mic, so never.
    func others(than id: String) -> [Speaker] {
        speakers.filter { $0.id != id && $0.id != Transcript.Speaker.me }
    }

    /// Whether the other voices still need telling apart.
    var hasUnidentifiedOthers: Bool {
        speakers.contains { $0.id == Transcript.Speaker.others }
    }
}

/// What a transcript line needs to edit its speaker.
struct SpeakerEditing {
    let entry: MeetingEntry
    let labels: SpeakerLabels
    let isEnabled: Bool
}

/// Naming one speaker, taking or turning down a suggestion, or merging them with someone else.
struct SpeakerPopover: View {
    let editing: SpeakerEditing
    let speakerID: String
    let dismiss: () -> Void

    @State private var draft = ""
    @State private var knownNames: [String] = []
    @FocusState private var isFieldFocused: Bool

    private var center: SpeakerCenter {
        .shared
    }

    private var speaker: SpeakerLabels.Speaker {
        editing.labels.speaker(speakerID)
    }

    private var isMe: Bool {
        speakerID == Transcript.Speaker.me
    }

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Another speaker in this meeting already called what's typed: probably the same person.
    private var sameNamed: SpeakerLabels.Speaker? {
        guard !trimmed.isEmpty, !isMe else {
            return nil
        }
        return editing.labels.others(than: speakerID).first {
            $0.isNamed && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    private var matchingNames: [String] {
        let used = Set(editing.labels.speakers.filter(\.isNamed).map { $0.name.lowercased() })
        return knownNames
            .filter { !used.contains($0.lowercased()) }
            .filter { trimmed.isEmpty || $0.localizedStandardRange(of: trimmed)?.lowerBound == $0.startIndex }
            .prefix(5)
            .map(\.self)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let suggestion = speaker.suggestion, !speaker.isNamed {
                suggestionRow(suggestion)
                Divider()
            }
            TextField(isMe ? "Your name" : "Name", text: $draft, prompt: Text(speaker.name))
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .onSubmit(save)
                .accessibilityLabel(isMe ? "Your name in this meeting" : "Name for \(speaker.name)")
                .accessibilityIdentifier("speakerNameField")
            if !matchingNames.isEmpty, !isMe {
                FlowOfNames(names: matchingNames) { name in
                    draft = name
                    save()
                }
            }
            if let sameNamed {
                Label("\(sameNamed.name) is already in this meeting.", systemImage: "person.2")
                    .font(.callout)
                Button("Merge with \(sameNamed.name)") {
                    merge(into: sameNamed.id)
                }
                .accessibilityIdentifier("speakerMergeSameName")
            }
            HStack {
                if !isMe, !editing.labels.others(than: speakerID).isEmpty {
                    Menu("Merge With") {
                        ForEach(editing.labels.others(than: speakerID)) { other in
                            Button(other.name) {
                                merge(into: other.id)
                            }
                        }
                    }
                    .fixedSize()
                    .accessibilityIdentifier("speakerMergeMenu")
                }
                Spacer()
                if speaker.isNamed {
                    Button("Clear Name") {
                        draft = ""
                        save()
                    }
                }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(sameNamed != nil)
                    .accessibilityIdentifier("speakerSave")
            }
        }
        .padding(16)
        .frame(width: 320)
        .disabled(!editing.isEnabled)
        .onAppear {
            draft = speaker.isNamed ? speaker.name : ""
            isFieldFocused = true
        }
        .task {
            let library = LibraryStore.shared.library
            knownNames = await Task.detached { library.knownSpeakerNames() }.value
        }
    }

    private func suggestionRow(_ suggestion: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Sounds like \(suggestion), from a saved voice.", systemImage: "waveform.badge.magnifyingglass")
                .font(.callout)
            HStack {
                Button("Accept") {
                    let entry = editing.entry
                    let speakerID = speakerID
                    dismiss()
                    Task {
                        await center.acceptSuggestion(for: speakerID, in: entry)
                    }
                }
                .accessibilityIdentifier("speakerAcceptSuggestion")
                Button("Not \(suggestion)") {
                    let entry = editing.entry
                    let speakerID = speakerID
                    dismiss()
                    Task {
                        await center.declineSuggestion(for: speakerID, in: entry)
                    }
                }
            }
        }
    }

    private func save() {
        guard sameNamed == nil else {
            return
        }
        let name = trimmed.isEmpty ? nil : trimmed
        let entry = editing.entry
        let speakerID = speakerID
        dismiss()
        guard name != (speaker.isNamed ? speaker.name : nil) else {
            return
        }
        Task {
            await center.name(speakerID, in: entry, to: name)
        }
    }

    private func merge(into target: String) {
        let entry = editing.entry
        let speakerID = speakerID
        dismiss()
        Task {
            await center.merge(speakerID, into: target, in: entry)
        }
    }
}

/// Names used before, as buttons that fill in the field.
private struct FlowOfNames: View {
    let names: [String]
    let choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Used before")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(names, id: \.self) { name in
                Button(name) {
                    choose(name)
                }
                .buttonStyle(.link)
            }
        }
    }
}

/// Over a transcript whose other voices are all Others: tells them apart, after getting the model if needed.
struct IdentifySpeakersBanner: View {
    let entry: MeetingEntry

    private var center: SpeakerCenter {
        .shared
    }

    var body: some View {
        HStack(spacing: 12) {
            Label(text, systemImage: "person.2.wave.2")
                .font(.callout)
            Spacer()
            if center.isInstalling {
                ProgressView(value: center.installProgress)
                    .frame(width: 100)
                    .accessibilityLabel("Downloading the speaker model")
                Button("Cancel") {
                    center.cancelInstall()
                }
            } else if center.modelStatus == .installed {
                Button("Identify Speakers") {
                    center.identifySpeakers(in: entry)
                }
                .disabled(!center.canIdentifySpeakers(in: entry))
                .accessibilityIdentifier("identifySpeakers")
            } else if center.modelStatus == .notInstalled {
                Button("Download (\(center.diarizer.downloadSizeBytes.formatted(.byteCount(style: .file))))") {
                    center.installModel()
                }
                .accessibilityIdentifier("downloadSpeakerModel")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }

    private var text: String {
        if center.installFailed {
            return "The download didn't finish. Check your connection and try again."
        }
        return center.modelStatus == .installed
            ? "Minutes can tell the other voices in this meeting apart."
            : "To tell the other voices apart, Minutes needs to download a speaker model. It runs only on this Mac."
    }
}
