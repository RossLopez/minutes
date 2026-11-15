// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A meeting as one Markdown or plain-text document, for copying or saving somewhere else.
public enum MeetingExporter {
    public struct Contents: OptionSet, Hashable, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let summary = Contents(rawValue: 1)
        /// The cleaned-up notes when there are some, otherwise the notes as typed.
        public static let notes = Contents(rawValue: 2)
        /// The notes as typed as well as the cleaned-up ones.
        public static let typedNotes = Contents(rawValue: 4)
        public static let transcript = Contents(rawValue: 8)

        public static let everything: Contents = [.summary, .notes, .transcript]
    }

    public enum Format: String, CaseIterable, Sendable {
        case markdown
        case plainText

        public var fileExtension: String {
            self == .markdown ? "md" : "txt"
        }
    }

    /// What a meeting has to export, read from its folder.
    public struct Source: Sendable {
        public var metadata: MeetingMetadata
        public var transcript: Transcript?
        public var summary: String?
        public var notes: String?
        public var cleanedNotes: String?

        public init(
            metadata: MeetingMetadata,
            transcript: Transcript?,
            summary: String?,
            notes: String?,
            cleanedNotes: String?,
        ) {
            self.metadata = metadata
            self.transcript = transcript
            self.summary = summary
            self.notes = notes
            self.cleanedNotes = cleanedNotes
        }

        public init(folder: MeetingFolder) throws {
            let notes = folder.loadNotes()
            try self.init(
                metadata: folder.loadMetadata(),
                transcript: try? folder.loadTranscript(),
                summary: folder.loadSummary(),
                notes: notes.hasText ? notes.text : nil,
                cleanedNotes: folder.loadCleanedNotes(),
            )
        }
    }

    public static func export(
        _ source: Source,
        contents: Contents,
        format: Format,
        locale: Locale = .current,
        timeZone: TimeZone = .current,
    ) -> String {
        var sections = [header(source, locale: locale, timeZone: timeZone)]
        for (title, body) in bodies(source, contents: contents) {
            sections.append("## \(title)\n\n\(body)")
        }
        let markdown = sections.joined(separator: "\n\n") + "\n"
        return format == .markdown ? markdown : plainText(markdown)
    }

    private static func bodies(_ source: Source, contents: Contents) -> [(String, String)] {
        var bodies: [(String, String)] = []
        if contents.contains(.summary), let summary = trimmed(source.summary) {
            bodies.append(("Summary", demotingHeadings(summary)))
        }
        let typed = trimmed(source.notes)
        let cleaned = trimmed(source.cleanedNotes)
        if contents.contains(.notes), let notes = cleaned ?? typed {
            bodies.append(("Notes", demotingHeadings(notes)))
        }
        if contents.contains(.typedNotes), cleaned != nil, let typed {
            bodies.append(("Notes as Typed", typed))
        }
        if contents.contains(.transcript), let transcript = source.transcript, !transcript.segments.isEmpty {
            bodies.append(("Transcript", turns(transcript, metadata: source.metadata)))
        }
        return bodies
    }

    private static func header(_ source: Source, locale: Locale, timeZone: TimeZone) -> String {
        let metadata = source.metadata
        var style = Date.FormatStyle(date: .long, time: .shortened, locale: locale)
        style.timeZone = timeZone
        var details = [metadata.startedAt.formatted(style)]
        if let duration = metadata.durationSeconds, duration >= 1 {
            details.append(Self.duration(duration))
        }
        var lines = ["# \(metadata.title)", "", details.joined(separator: " · ")]
        let people = speakers(source)
        if !people.isEmpty {
            lines.append("People: " + people.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    private static func speakers(_ source: Source) -> [String] {
        var names: [String] = []
        for segment in source.transcript?.segments ?? [] {
            let name = source.metadata.displayName(forSpeaker: segment.speaker)
            if !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    /// A paragraph a turn, each with its time and speaker.
    private static func turns(_ transcript: Transcript, metadata: MeetingMetadata) -> String {
        struct Turn {
            var start: Double
            var speaker: String
            var text: String
        }
        var turns: [Turn] = []
        for segment in transcript.segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                continue
            }
            if let last = turns.last, last.speaker == segment.speaker {
                turns[turns.count - 1].text += " " + text
            } else {
                turns.append(Turn(start: segment.start, speaker: segment.speaker, text: text))
            }
        }
        return turns.map { turn in
            "**[\(Transcript.clock(turn.start))] \(metadata.displayName(forSpeaker: turn.speaker)):** \(turn.text)"
        }
        .joined(separator: "\n\n")
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) hr \(minutes % 60) min"
    }

    private static func trimmed(_ text: String?) -> String? {
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    /// Headings one level down, so they sit under the section's own heading.
    private static func demotingHeadings(_ markdown: String) -> String {
        markdown.components(separatedBy: "\n").map { line in
            line.hasPrefix("#") && line.count(where: { $0 == "#" }) < 6 ? "#" + line : line
        }
        .joined(separator: "\n")
    }

    /// The same document without Markdown: headings as plain lines, no emphasis or link syntax.
    /// Lists keep their dashes, which read fine as text.
    static func plainText(_ markdown: String) -> String {
        markdown.components(separatedBy: "\n").map { line in
            var line = line
            if let heading = line.firstMatch(of: /^#{1,6}\s+/) {
                line.removeSubrange(heading.range)
            }
            line = line.replacing(/\[([^\]]+)\]\([^)]*\)/) { String($0.output.1) }
            line = line.replacing(/(\*\*|__)(.+?)\1/) { String($0.output.2) }
            return line
        }
        .joined(separator: "\n")
    }
}
