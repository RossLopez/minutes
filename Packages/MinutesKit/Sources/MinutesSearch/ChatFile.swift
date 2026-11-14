// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesStorage

/// A chat as Markdown, readable in any editor: a few settings at the top, then each question and
/// answer under `## You` and `## Minutes`, with the answer's sources as links into the meetings.
///
/// Reading is lenient, since the file may have been edited by hand: anything it can't place is
/// kept as text.
public enum ChatFile {
    public static func markdown(_ chat: ChatDocument) -> String {
        var front = [
            "id: \(chat.id.uuidString)",
            "created: \(chat.createdAt.formatted(iso))",
        ]
        if let model = chat.model {
            front.append("model: \(model)")
        }
        switch chat.scope {
        case .library:
            front.append("scope: library")
        case let .meeting(id):
            front.append("scope: meeting \(id.uuidString)")
        }
        if let dates = chat.filter.dates {
            front.append("from: \(dates.lowerBound.formatted(iso))")
            front.append("to: \(dates.upperBound.formatted(iso))")
        }
        if let meetings = chat.filter.meetings {
            front.append("meetings: " + meetings.map(\.uuidString).sorted().joined(separator: ", "))
        }
        var parts = ["---\n" + front.joined(separator: "\n") + "\n---", "# \(chat.displayTitle)"]
        for turn in chat.turns {
            parts.append("## You\n\n" + turn.question.trimmingCharacters(in: .whitespacesAndNewlines))
            var answer = "## Minutes\n\n" + turn.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !turn.sources.isEmpty {
                answer += "\n\nSources:\n\n" + turn.sources.map(sourceLine).joined(separator: "\n")
            }
            parts.append(answer)
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    public static func read(_ text: String) -> ChatDocument {
        var chat = ChatDocument()
        var body = text[...]
        if let front = text.firstMatch(of: /\A---\n([\s\S]*?)\n---\n?/) {
            applyFrontMatter(String(front.output.1), to: &chat)
            body = text[front.range.upperBound...]
        }
        var lines = body.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { $0.hasPrefix("# ") }) {
            chat.title = String(lines[index].dropFirst(2)).trimmingCharacters(in: .whitespaces)
            lines.removeSubrange(...index)
        }
        chat.turns = turns(in: lines)
        return chat
    }

    // MARK: - Writing

    private static func sourceLine(_ source: ChatSource) -> String {
        let label = [
            source.meetingTitle.replacingOccurrences(of: "]", with: ")"),
            source.meetingDate.formatted(day),
            place(of: source),
        ].joined(separator: " · ")
        let quote = String(source.text.replacingOccurrences(of: "\n", with: " ").prefix(240))
        return "\(source.number). [\(label)](\(source.link.url.absoluteString))\n   > \(quote)"
    }

    /// Where in the meeting the source is, as said to the user.
    public static func place(of source: ChatSource) -> String {
        let time = source.start.map(clock)
        return switch source.kind {
        case .transcript: time ?? "Transcript"
        case .summary: "Summary"
        case .notes: time.map { "Notes \($0)" } ?? "Notes"
        case .cleanedNotes: "Cleaned-Up Notes"
        }
    }

    public static func clock(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        let (hours, minutes, rest) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    // MARK: - Reading

    private static func applyFrontMatter(_ text: String, to chat: inout ChatDocument) {
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                values[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        func date(_ key: String) -> Date? {
            values[key].flatMap { try? Date($0, strategy: iso) }
        }
        chat.id = values["id"].flatMap(UUID.init) ?? chat.id
        chat.createdAt = date("created") ?? chat.createdAt
        chat.model = values["model"].flatMap { $0.isEmpty ? nil : $0 }
        if let scope = values["scope"], scope.hasPrefix("meeting "),
           let id = UUID(uuidString: String(scope.dropFirst(8)))
        {
            chat.scope = .meeting(id)
        }
        if let from = date("from"), let until = date("to"), from < until {
            chat.filter.dates = from ..< until
        }
        chat.filter.meetings = values["meetings"].map { list in
            Set(list.split(separator: ",").compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespaces)) })
        }
    }

    private static func turns(in lines: [String]) -> [ChatTurn] {
        var turns: [ChatTurn] = []
        var section: String?
        var buffer: [String] = []
        func flush() {
            let text = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = []
            switch section {
            case "You":
                turns.append(ChatTurn(question: text))
            case "Minutes":
                let (answer, sources) = splitSources(text)
                if turns.isEmpty || !turns[turns.count - 1].answer.isEmpty {
                    turns.append(ChatTurn(question: ""))
                }
                turns[turns.count - 1].answer = answer
                turns[turns.count - 1].sources = sources
            default:
                // Text before the first heading, written by hand, is kept as a question.
                if !text.isEmpty {
                    turns.append(ChatTurn(question: text))
                }
            }
        }
        for line in lines {
            if line == "## You" || line == "## Minutes" {
                flush()
                section = String(line.dropFirst(3))
            } else {
                buffer.append(line)
            }
        }
        flush()
        return turns
    }

    /// The answer, and the sources listed after its last `Sources:` line.
    private static func splitSources(_ text: String) -> (String, [ChatSource]) {
        guard let range = text.range(of: "\n\nSources:\n", options: .backwards) else {
            return (text, [])
        }
        var sources: [ChatSource] = []
        for line in text[range.upperBound...].split(separator: "\n") {
            if let source = source(from: line) {
                sources.append(source)
            } else if line.hasPrefix("   > "), !sources.isEmpty {
                sources[sources.count - 1].text = String(line.dropFirst(5))
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                // Not a list of sources after all.
                return (text, [])
            }
        }
        return (String(text[..<range.lowerBound]), sources)
    }

    private static func source(from line: Substring) -> ChatSource? {
        guard let match = line.wholeMatch(of: /(\d+)\. \[(.*)\]\((minutes:[^)]+)\)/),
              let number = Int(match.output.1), let url = URL(string: String(match.output.3)),
              let link = MeetingLink(url: url)
        else {
            return nil
        }
        let label = match.output.2.components(separatedBy: " · ")
        let date = label.count >= 3 ? try? Date(label[label.count - 2], strategy: day) : nil
        let title = label.count >= 3 ? label.dropLast(2).joined(separator: " · ") : String(match.output.2)
        return ChatSource(number: number, meetingID: link.meetingID, meetingTitle: title,
                          meetingDate: date ?? .distantPast, kind: link.kind, start: link.seconds, text: "")
    }

    private static var iso: Date.ISO8601FormatStyle {
        .iso8601
    }

    /// Dates of meetings are written the same way everywhere, so a file reads the same on any Mac.
    private static var day: Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
    }
}

/// Saved chats in a folder, newest first.
public enum ChatFiles {
    public struct Entry: Identifiable, Equatable, Sendable {
        public var url: URL
        public var chat: ChatDocument

        public init(url: URL, chat: ChatDocument) {
            self.url = url
            self.chat = chat
        }

        public var id: UUID {
            chat.id
        }
    }

    public static func list(in folder: URL) -> [Entry] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles],
        )) ?? []
        return urls.filter { $0.pathExtension == "md" }
            .compactMap { url in
                (try? String(contentsOf: url, encoding: .utf8)).map { Entry(url: url, chat: ChatFile.read($0)) }
            }
            .sorted { $0.chat.createdAt > $1.chat.createdAt }
    }

    /// Writes the chat, under a name from its date and title. A file it was saved as before, under
    /// another name, is moved, so renaming a chat renames its file.
    @discardableResult
    public static func save(_ chat: ChatDocument, in folder: URL, replacing previous: URL?) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = MinutesLibrary.folderName(startedAt: chat.createdAt, title: chat.displayTitle)
        var url = previous ?? folder.appendingPathComponent(base + ".md")
        if previous?.deletingPathExtension().lastPathComponent.hasPrefix(base) != true {
            url = available(base, in: folder)
            if let previous, FileManager.default.fileExists(atPath: previous.path) {
                try FileManager.default.moveItem(at: previous, to: url)
            }
        }
        try Data(ChatFile.markdown(chat).utf8).write(to: url, options: .atomic)
        return url
    }

    private static func available(_ base: String, in folder: URL) -> URL {
        var url = folder.appendingPathComponent(base + ".md")
        var attempt = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(attempt).md")
            attempt += 1
        }
        return url
    }
}
