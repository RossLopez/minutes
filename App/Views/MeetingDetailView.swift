// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesStorage
import SwiftUI

/// One meeting: its title and details, tabs, and the player.
struct MeetingDetailView: View {
    let store: LibraryStore
    let entry: MeetingEntry

    /// Summaries don't exist until Milestone 5, so the transcript is the first useful thing to show.
    @State private var tab = MeetingTab.transcript

    private var state: MeetingDisplayState {
        MeetingDisplayState(entry: entry)
    }

    var body: some View {
        switch state {
        case .ready:
            ready
        case .recording:
            ContentUnavailableView(
                "Recording in Progress",
                systemImage: "record.circle",
                description: Text("You can listen to this meeting after you stop recording."),
            )
        case .saving:
            ContentUnavailableView("Saving…", systemImage: "arrow.down.circle")
        case .notFinished:
            notFinished
        case .unreadable:
            unreadable
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 0) {
            MeetingHeader(store: store, entry: entry)
                .padding([.horizontal, .top], 20)
            Picker("Section", selection: $tab) {
                ForEach(MeetingTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(20)
            if tab == .transcript {
                TranscriptTab(store: store, entry: entry)
            } else {
                ContentUnavailableView(
                    tab.title,
                    systemImage: tab.systemImage,
                    description: Text(tab.emptyDescription),
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar(player: store.player, isEditingText: store.isEditingText)
        }
    }

    private var notFinished: some View {
        ContentUnavailableView {
            Label("This Recording Didn't Finish", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Minutes can try to save the audio it captured.")
        } actions: {
            Button("Recover…") {
                Task {
                    await RecordingController.shared.recover(entry)
                }
            }
            .disabled(RecordingController.shared.phase != .idle)
            Button("Reveal in Finder") {
                store.reveal(entry)
            }
        }
    }

    private var unreadable: some View {
        ContentUnavailableView {
            Label("Minutes Can't Read This Meeting", systemImage: "questionmark.folder")
        } description: {
            Text("Its meeting.json is missing or damaged. Any audio is still in the folder.")
        } actions: {
            Button("Reveal in Finder") {
                store.reveal(entry)
            }
        }
    }
}

private struct MeetingHeader: View {
    let store: LibraryStore
    let entry: MeetingEntry

    @State private var draft = ""
    @FocusState private var isTitleFocused: Bool

    private var details: String {
        var parts = [entry.date.formatted(date: .long, time: .shortened)]
        if let duration = MeetingFormatting.duration(entry.metadata?.durationSeconds) {
            parts.append(duration)
        }
        return parts.joined(separator: " · ")
    }

    private var devices: String? {
        let names = [entry.metadata?.inputDeviceName, entry.metadata?.outputDeviceName].compactMap(\.self)
        return names.isEmpty ? nil : Set(names).sorted().joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Title", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .focused($isTitleFocused)
                    .disabled(!entry.canRename)
                    .onSubmit {
                        isTitleFocused = false
                    }
                    .onExitCommand {
                        draft = entry.title
                        isTitleFocused = false
                    }
                    .accessibilityLabel("Meeting title")
                    .accessibilityIdentifier("meetingTitleField")
                Menu("Actions", systemImage: "ellipsis.circle") {
                    MeetingActions(store: store, entry: entry)
                }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Text(details)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let devices {
                Text(devices)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(MeetingHeader.notes(for: entry.metadata), id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            draft = entry.title
        }
        .onChange(of: entry.title) {
            draft = entry.title
        }
        .onChange(of: isTitleFocused) {
            store.isEditingTitle = isTitleFocused
            if !isTitleFocused {
                commit()
            }
        }
        .onDisappear {
            // Choosing another meeting removes this view before its focus can change.
            store.isEditingTitle = false
            commit()
        }
        .onChange(of: store.renameRequests) {
            isTitleFocused = true
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != entry.title else {
            draft = entry.title
            return
        }
        Task {
            await store.rename(entry, to: trimmed)
        }
    }

    /// Things worth knowing about how the recording went.
    private static func notes(for metadata: MeetingMetadata?) -> [String] {
        guard let metadata else {
            return []
        }
        var notes: [String] = []
        for (name, track) in [("Me", metadata.mic), ("Others", metadata.system)] {
            if track.failure != nil {
                notes.append("\(name): this track couldn't be recorded in full.")
            }
            if !track.gaps.isEmpty {
                let seconds = track.gaps.reduce(0) { $0 + $1.durationSeconds }
                let total = seconds.formatted(.number.precision(.fractionLength(1)))
                let count = track.gaps.count == 1 ? "1 gap" : "\(track.gaps.count) gaps"
                notes.append("\(name): \(count), \(total) seconds in total, usually from a device change.")
            }
        }
        if metadata.isNewerThanThisApp {
            notes.append("Made by a newer version of Minutes, so it can't be renamed here.")
        }
        return notes
    }
}

private enum MeetingTab: String, CaseIterable, Identifiable {
    case summary
    case transcript
    case notes

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .summary: "Summary"
        case .transcript: "Transcript"
        case .notes: "Notes"
        }
    }

    var systemImage: String {
        switch self {
        case .summary: "text.alignleft"
        case .transcript: "text.quote"
        case .notes: "note.text"
        }
    }

    var emptyDescription: String {
        switch self {
        case .summary: "Summaries arrive in Milestone 5."
        case .transcript: ""
        case .notes: "Notes arrive in Milestone 7."
        }
    }
}
