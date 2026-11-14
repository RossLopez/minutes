// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesLLM
import MinutesSearch
import MinutesStorage
import Observation
import os

/// Saved chats and the open conversations: across meetings in `Chats/`, and each meeting's own
/// in its `chats/` folder, so they move and go to the Trash with it.
@MainActor @Observable
final class ChatCenter {
    static let shared = ChatCenter()

    nonisolated static let logger = Logger(subsystem: "io.github.rosslopez.minutes", category: "chat")

    /// An error's domain and code, without its message, which can hold a chat's file name.
    nonisolated static func kind(of error: any Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }

    /// Chats across meetings, newest first.
    private(set) var chats: [ChatFiles.Entry] = []
    var selection: UUID?
    /// A new chat, not saved until it has an answer.
    private(set) var draft: ChatSession?

    @ObservationIgnored private var sessions: [UUID: ChatSession] = [:]
    /// Each meeting's Ask tab, by meeting ID.
    @ObservationIgnored private var askSessions: [UUID: ChatSession] = [:]

    private init() {}

    var chatsFolder: URL {
        LibraryStore.shared.library.root.appendingPathComponent("Chats", isDirectory: true)
    }

    /// Reads `Chats/` again, keeping open conversations.
    func refresh() async {
        let folder = chatsFolder
        chats = await Task.detached { ChatFiles.list(in: folder) }.value
    }

    // MARK: - The model

    var chatChoice: ModelChoice? {
        AIModelCenter.shared.resolvedChoice(for: .chat, installed: SummaryCenter.shared.installedModels)
    }

    var hasModel: Bool {
        SummaryCenter.shared.fakeProvider != nil || chatChoice != nil
    }

    /// The name of the model chat uses now, and whether it's outside the user's network.
    var modelDescription: (name: String, isOffNetwork: Bool)? {
        if let fake = SummaryCenter.shared.fakeProvider {
            return (fake.id, false)
        }
        return chatChoice.map { (AIModelCenter.shared.name(of: $0), AIModelCenter.shared.isOffNetwork($0)) }
    }

    func provider() -> (any LLMProvider)? {
        if let fake = SummaryCenter.shared.fakeProvider {
            return fake
        }
        switch chatChoice {
        case nil:
            return nil
        case let .builtIn(id)?:
            return BuiltInModels.shared.provider(for: id)
        case let choice?:
            return AIModelCenter.shared.provider(for: choice)
        }
    }

    /// Whether a chat is answering with this built-in model, so it can't be deleted.
    func isUsing(builtIn id: String) -> Bool {
        chatChoice == .builtIn(id) && (Array(sessions.values) + Array(askSessions.values) + [draft].compactMap(\.self))
            .contains(where: \.isBusy)
    }

    // MARK: - Chats across meetings

    func session(for id: UUID) -> ChatSession? {
        if draft?.id == id {
            return draft
        }
        if let session = sessions[id] {
            return session
        }
        guard let entry = chats.first(where: { $0.id == id }) else {
            return nil
        }
        let session = ChatSession(document: entry.chat, fileURL: entry.url) { [weak self] in self?.chatsFolder }
        sessions[id] = session
        return session
    }

    func newChat() {
        if let draft, draft.document.turns.isEmpty, !draft.isBusy {
            selection = draft.id
            return
        }
        let session = ChatSession(document: ChatDocument(), fileURL: nil) { [weak self] in self?.chatsFolder }
        draft = session
        selection = session.id
        LibraryStore.shared.sidebarItem = .chat
    }

    /// A chat was saved: a draft becomes a saved chat, and the list catches up.
    func saved(_ session: ChatSession) {
        guard case .library = session.document.scope else {
            return
        }
        if draft === session {
            draft = nil
            sessions[session.id] = session
        }
        guard let url = session.fileURL else {
            return
        }
        chats.removeAll { $0.id == session.id }
        chats.insert(ChatFiles.Entry(url: url, chat: session.document), at: 0)
        chats.sort { $0.chat.createdAt > $1.chat.createdAt }
    }

    func rename(_ id: UUID, to title: String) {
        session(for: id)?.rename(to: title)
    }

    /// Moves a saved chat to the Trash.
    func moveToTrash(_ id: UUID) {
        if draft?.id == id {
            draft = nil
        } else if let entry = chats.first(where: { $0.id == id }) {
            sessions[id]?.stop()
            do {
                try LibraryStore.shared.discard(entry.url)
            } catch {
                // The file's name is the chat's title, which comes from its first question.
                Self.logger.error("Moving a chat to the Trash failed: \(Self.kind(of: error), privacy: .public)")
                return
            }
            sessions[id] = nil
            chats.removeAll { $0.id == id }
        }
        if selection == id {
            selection = chats.first?.id
        }
    }

    // MARK: - A meeting's Ask tab

    /// The meeting's latest chat, or a new one.
    func askSession(for entry: MeetingEntry) -> ChatSession? {
        guard let meetingID = entry.metadata?.id else {
            return nil
        }
        if let session = askSessions[meetingID] {
            return session
        }
        let folder = Self.chatsFolder(of: entry.folder)
        let latest = ChatFiles.list(in: folder).first
        let session = ChatSession(
            document: latest?.chat ?? ChatDocument(scope: .meeting(meetingID)),
            fileURL: latest?.url,
            folder: { Self.askFolder(forMeeting: meetingID) },
        )
        askSessions[meetingID] = session
        return session
    }

    func newAskChat(for entry: MeetingEntry) {
        guard let meetingID = entry.metadata?.id else {
            return
        }
        askSessions[meetingID]?.stop()
        askSessions[meetingID] = ChatSession(
            document: ChatDocument(scope: .meeting(meetingID)),
            fileURL: nil,
            folder: { Self.askFolder(forMeeting: meetingID) },
        )
    }

    private static func askFolder(forMeeting id: UUID) -> URL? {
        LibraryStore.shared.entry(forMeeting: id).map { chatsFolder(of: $0.folder) }
    }

    static func chatsFolder(of folder: MeetingFolder) -> URL {
        folder.url.appendingPathComponent("chats", isDirectory: true)
    }

    /// The library moved or another was chosen.
    func libraryChanged() {
        for session in Array(sessions.values) + Array(askSessions.values) {
            session.stop()
        }
        sessions = [:]
        askSessions = [:]
        draft = nil
        selection = nil
        Task {
            await refresh()
        }
    }
}
