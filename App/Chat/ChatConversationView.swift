// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesSearch
import SwiftUI

/// A conversation: its questions and answers, and the field to ask the next one.
struct ChatConversationView: View {
    let session: ChatSession
    /// Off in a meeting's Ask tab, which is about that meeting only.
    var showsFilters = true
    var prompt = "Ask about your meetings"

    @State private var question = ""
    @FocusState private var isFocused: Bool

    private var center: ChatCenter {
        .shared
    }

    var body: some View {
        VStack(spacing: 0) {
            ChatHeader(session: session, showsFilters: showsFilters)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            Divider()
            conversation
            Divider()
            input
                .padding(12)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
                    LibraryStore.shared.chatInputHeights[session.id] = height
                }
        }
        .onChange(of: isFocused) {
            LibraryStore.shared.isEditingChat = isFocused
        }
        .onDisappear {
            LibraryStore.shared.isEditingChat = false
            LibraryStore.shared.chatInputHeights[session.id] = nil
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if session.document.turns.isEmpty, session.pending == nil {
                        ChatEmptyState(showsFilters: showsFilters)
                    }
                    ForEach(session.document.turns) { turn in
                        ChatTurnView(turn: turn)
                    }
                    if let pending = session.pending {
                        ChatTurnView(turn: pending, isWriting: true)
                    }
                    ChatStatusLine(session: session)
                        .id("bottom")
                }
                .padding(20)
            }
            .onChange(of: session.pending?.answer) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: session.document.turns.count) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var input: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(prompt, text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1 ... 6)
                .focused($isFocused)
                .onSubmit(send)
                .padding(8)
                .background(.background.secondary, in: .rect(cornerRadius: 8))
                .accessibilityIdentifier("chatQuestion")
            if session.isBusy {
                Button("Stop", systemImage: "stop.circle.fill") {
                    session.stop()
                }
                .labelStyle(.iconOnly)
                .font(.title2)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("chatStop")
            } else {
                Button("Ask", systemImage: "arrow.up.circle.fill") {
                    send()
                }
                .labelStyle(.iconOnly)
                .font(.title2)
                .buttonStyle(.borderless)
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !center.hasModel)
                .accessibilityIdentifier("chatAsk")
            }
        }
    }

    private func send() {
        guard !session.isBusy, center.hasModel else {
            return
        }
        session.ask(question)
        question = ""
    }
}

/// Which model answers, where, and what the chat looks at.
private struct ChatHeader: View {
    let session: ChatSession
    let showsFilters: Bool

    private var center: ChatCenter {
        .shared
    }

    var body: some View {
        HStack(spacing: 12) {
            if showsFilters {
                ChatFilterBar(session: session)
            }
            Spacer()
            if let model = center.modelDescription {
                HStack(spacing: 4) {
                    if model.isOffNetwork {
                        Image(systemName: "network")
                    }
                    Text(model.name)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(model.isOffNetwork ? "\(model.name), outside your network" : model.name)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.isOffNetwork ? "Answers by \(model.name), outside your network"
                    : "Answers by \(model.name)")
                .accessibilityIdentifier("chatModel")
            } else {
                Button("Choose a Model…") {
                    RecordingController.shared.openSettings(.aiModels)
                }
                .controlSize(.small)
                .accessibilityIdentifier("chatChooseModel")
            }
        }
    }
}

private struct ChatEmptyState: View {
    let showsFilters: Bool

    private var search: SearchCenter {
        .shared
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(showsFilters ? "Ask about your past meetings." : "Ask about this meeting.")
                .font(.title3.weight(.semibold))
            Text("""
            Answers come only from your transcripts, notes and summaries, and say where each part came \
            from. Click a source to go to that moment.
            """)
            .foregroundStyle(.secondary)
            if !search.hasSearchModel {
                let model = SearchCenter.searchModel
                Text("""
                Search by meaning finds passages that use other words for what you ask. It needs \
                \(model.name), about \(SummaryCenter.bytes(model.approximateBytes)). Without it, chat \
                finds passages by their words.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                SearchModelControls()
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}

/// What the chat is doing, or why it couldn't.
private struct ChatStatusLine: View {
    let session: ChatSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch session.phase {
            case let .waiting(message):
                Label(message, systemImage: "hourglass")
            case .searching:
                Label("Looking through your meetings…", systemImage: "magnifyingglass")
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("chatFailure")
            case .idle, .answering:
                EmptyView()
            }
            if let note = session.note {
                Label(note, systemImage: "info.circle")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

/// Getting the search model, from chat or Settings.
struct SearchModelControls: View {
    private var center: SummaryCenter {
        .shared
    }

    var body: some View {
        let model = SearchCenter.searchModel
        switch center.states[model.id] ?? .notInstalled {
        case let .downloading(progress):
            ProgressView(value: progress?.fraction ?? 0) {
                Text("Downloading \(model.name)…")
            }
            .frame(width: 240)
        case .paused:
            Button("Resume Downloading \(model.name)") {
                center.download(model)
            }
        case .notInstalled:
            ModelDownloadButton(model: model, title: "Download \(model.name)")
        case .installed:
            EmptyView()
        }
    }
}
