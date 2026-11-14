// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A passage given to the model with a question, which its answer can cite by number.
public struct ChatSource: Identifiable, Equatable, Sendable {
    /// Its number in the answer's citations, from 1.
    public var number: Int
    public var meetingID: UUID
    public var meetingTitle: String
    public var meetingDate: Date
    public var kind: SearchChunk.Kind
    public var start: Double?
    /// The passage, or after reading a saved chat, the start of it.
    public var text: String

    public var id: Int {
        number
    }

    public init(
        number: Int,
        meetingID: UUID,
        meetingTitle: String,
        meetingDate: Date,
        kind: SearchChunk.Kind,
        start: Double?,
        text: String,
    ) {
        self.number = number
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.meetingDate = meetingDate
        self.kind = kind
        self.start = start
        self.text = text
    }

    public init(number: Int, hit: SearchHit) {
        self.init(number: number, meetingID: hit.meetingID, meetingTitle: hit.meetingTitle,
                  meetingDate: hit.meetingDate, kind: hit.chunk.kind, start: hit.chunk.start, text: hit.chunk.text)
    }

    /// Where a click on it goes.
    public var link: MeetingLink {
        MeetingLink(meetingID: meetingID, seconds: start, kind: kind)
    }
}

/// One question and its answer.
public struct ChatTurn: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var question: String
    public var answer: String
    /// What the answer was given, all of them, cited or not.
    public var sources: [ChatSource]

    public init(question: String, answer: String = "", sources: [ChatSource] = []) {
        self.question = question
        self.answer = answer
        self.sources = sources
    }

    /// The sources the answer cites, in the order it first cites them.
    public var citedSources: [ChatSource] {
        Citations.cited(in: answer, count: sources.count).compactMap { number in
            sources.first { $0.number == number }
        }
    }
}

/// Which meetings a chat asks about.
public enum ChatScope: Equatable, Sendable {
    /// All of them, narrowed by the chat's filter.
    case library
    /// One meeting, from its Ask tab.
    case meeting(UUID)
}

/// A saved conversation: a Markdown file in `Chats/`, or in a meeting's `chats/` folder.
public struct ChatDocument: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    /// The model that wrote the latest answer.
    public var model: String?
    public var scope: ChatScope
    public var filter: SearchFilter
    public var turns: [ChatTurn]

    public init(
        id: UUID = UUID(),
        title: String = "",
        createdAt: Date = Date(),
        model: String? = nil,
        scope: ChatScope = .library,
        filter: SearchFilter = .everything,
        turns: [ChatTurn] = [],
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.model = model
        self.scope = scope
        self.filter = filter
        self.turns = turns
    }

    /// The first question, cut to fit a list, when there's no title yet.
    public var displayTitle: String {
        if !title.isEmpty {
            return title
        }
        return Self.title(from: turns.first?.question ?? "")
    }

    public static func title(from question: String) -> String {
        let line = question.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 60 else {
            return trimmed.isEmpty ? "New Chat" : trimmed
        }
        let cut = trimmed.prefix(60)
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return word.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }
}

/// `minutes://meeting/<id>?t=754&kind=transcript`: a place in a meeting. Opening one only shows
/// the meeting there. It never plays or changes anything.
public struct MeetingLink: Equatable, Sendable {
    public static let scheme = "minutes"

    public var meetingID: UUID
    public var seconds: Double?
    public var kind: SearchChunk.Kind

    public init(meetingID: UUID, seconds: Double? = nil, kind: SearchChunk.Kind = .transcript) {
        self.meetingID = meetingID
        self.seconds = seconds
        self.kind = kind
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == "meeting",
              let id = UUID(uuidString: url.lastPathComponent)
        else {
            return nil
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        meetingID = id
        seconds = items.first { $0.name == "t" }?.value.flatMap(Double.init).map { max(0, $0) }
        kind = items.first { $0.name == "kind" }?.value.flatMap(SearchChunk.Kind.init) ?? .transcript
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "meeting"
        components.path = "/" + meetingID.uuidString
        var items: [URLQueryItem] = []
        if let seconds {
            items.append(URLQueryItem(name: "t", value: String(Int(seconds.rounded(.down)))))
        }
        if kind != .transcript {
            items.append(URLQueryItem(name: "kind", value: kind.rawValue))
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.url ?? URL(string: "minutes://meeting/\(meetingID.uuidString)")!
    }
}
