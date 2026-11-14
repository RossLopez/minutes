// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesSearch
import MinutesStorage
import SwiftUI

/// Saved chats across meetings, newest first.
struct ChatListView: View {
    @Bindable private var center = ChatCenter.shared

    @State private var renaming: UUID?
    @State private var newTitle = ""

    var body: some View {
        Group {
            if center.chats.isEmpty, center.draft == nil {
                ContentUnavailableView {
                    Label("No Chats", systemImage: SidebarItem.chat.systemImage)
                } description: {
                    Text("Ask about your past meetings, and get answers that link to the moment they came from.")
                } actions: {
                    Button("New Chat") {
                        center.newChat()
                    }
                    .accessibilityIdentifier("newChatEmpty")
                }
            } else {
                list
            }
        }
        .toolbar {
            ToolbarItem {
                Button("New Chat", systemImage: "square.and.pencil") {
                    center.newChat()
                }
                .help("New Chat")
                .accessibilityIdentifier("newChat")
            }
        }
        .task {
            await center.refresh()
        }
        .alert("Rename Chat", isPresented: isRenaming) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                if let renaming {
                    center.rename(renaming, to: newTitle)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var list: some View {
        List(selection: $center.selection) {
            if let draft = center.draft {
                ChatRow(title: "New Chat", date: draft.document.createdAt)
                    .tag(draft.id)
            }
            ForEach(center.chats) { entry in
                ChatRow(title: entry.chat.displayTitle, date: entry.chat.createdAt)
                    .tag(entry.id)
                    .contextMenu {
                        Button("Rename…") {
                            newTitle = entry.chat.displayTitle
                            renaming = entry.id
                        }
                        Divider()
                        Button("Move to Trash") {
                            center.moveToTrash(entry.id)
                        }
                    }
            }
        }
        .accessibilityIdentifier("chatList")
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: {
            if !$0 {
                renaming = nil
            }
        })
    }
}

private struct ChatRow: View {
    let title: String
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .lineLimit(2)
            Text(date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chatRow")
    }
}

/// The open chat, in the detail column.
struct ChatDetailView: View {
    private var center: ChatCenter {
        .shared
    }

    var body: some View {
        if let id = center.selection, let session = center.session(for: id) {
            ChatConversationView(session: session)
                .id(id)
        } else {
            ContentUnavailableView {
                Label("No Chat Selected", systemImage: SidebarItem.chat.systemImage)
            } actions: {
                Button("New Chat") {
                    center.newChat()
                }
            }
        }
    }
}

/// A meeting's fourth tab: a chat about that meeting alone.
struct AskTab: View {
    let entry: MeetingEntry

    @State private var session: ChatSession?

    var body: some View {
        VStack(spacing: 0) {
            if let session {
                ChatConversationView(session: session, showsFilters: false, prompt: "Ask about this meeting")
                    .id(session.id)
            }
        }
        .toolbar {
            ToolbarItem {
                Button("New Chat", systemImage: "square.and.pencil") {
                    ChatCenter.shared.newAskChat(for: entry)
                    session = ChatCenter.shared.askSession(for: entry)
                }
                .help("New chat about this meeting")
                .disabled(session?.isBusy == true || session?.document.turns.isEmpty != false)
                .accessibilityIdentifier("newAskChat")
            }
        }
        .task(id: entry.id) {
            session = ChatCenter.shared.askSession(for: entry)
        }
    }
}
