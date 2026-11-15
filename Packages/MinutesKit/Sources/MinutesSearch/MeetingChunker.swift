// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesStorage

/// A passage of one meeting, small enough to search and to quote to a model.
public struct SearchChunk: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case transcript
        case summary
        case notes
        case cleanedNotes = "cleaned-notes"
    }

    public var kind: Kind
    /// Seconds into the recording, when the passage has a time.
    public var start: Double?
    public var end: Double?
    /// Display names, in the order they speak.
    public var speakers: [String]
    /// Transcript passages have a line per turn, like `Dana: …`.
    public var text: String

    public init(kind: Kind, start: Double? = nil, end: Double? = nil, speakers: [String] = [], text: String) {
        self.kind = kind
        self.start = start
        self.end = end
        self.speakers = speakers
        self.text = text
    }
}

/// Splits a meeting's transcript, summary and notes into passages. Pure, so it's easy to test.
public enum MeetingChunker {
    /// About how many words a transcript passage holds.
    public static let transcriptWords = 200
    /// Sections of a summary or notes longer than this are split at paragraphs.
    static let sectionWords = 300
    /// Typed notes are grouped up to this many words.
    static let noteWords = 120

    public static func chunks(
        transcript: Transcript?,
        metadata: MeetingMetadata,
        summary: String?,
        notes: MeetingNotes,
        cleanedNotes: String?,
    ) -> [SearchChunk] {
        var chunks: [SearchChunk] = []
        if let transcript {
            chunks += transcriptChunks(transcript, names: metadata.displayName(forSpeaker:))
        }
        if let summary {
            chunks += sections(summary).map { SearchChunk(kind: .summary, text: $0) }
        }
        if let cleanedNotes {
            chunks += sections(cleanedNotes).map { SearchChunk(kind: .cleanedNotes, text: $0) }
        }
        chunks += noteChunks(notes)
        return chunks
    }

    // MARK: - Transcript

    private struct Unit {
        var speaker: String
        var start: Double
        var end: Double
        var text: String
        var words: Int
    }

    /// Whole segments, about `transcriptWords` at a time. Each passage after the first starts with
    /// the last segment of the one before, unless that's long, so a thought split between two
    /// passages is still found.
    static func transcriptChunks(_ transcript: Transcript, names: (String) -> String) -> [SearchChunk] {
        let units = transcript.segments.compactMap { segment -> Unit? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return nil
            }
            return Unit(speaker: names(segment.speaker), start: segment.start, end: segment.end, text: text,
                        words: wordCount(text))
        }
        var chunks: [SearchChunk] = []
        var current: [Unit] = []
        var hasNew = false
        for unit in units {
            current.append(unit)
            hasNew = true
            if current.reduce(0, { $0 + $1.words }) >= transcriptWords {
                chunks.append(passage(current))
                hasNew = false
                current = current.last.map { $0.words < transcriptWords / 2 ? [$0] : [] } ?? []
            }
        }
        if hasNew {
            chunks.append(passage(current))
        }
        return chunks
    }

    private static func passage(_ units: [Unit]) -> SearchChunk {
        var lines: [String] = []
        var speakers: [String] = []
        var lastSpeaker: String?
        for unit in units {
            if unit.speaker == lastSpeaker {
                lines[lines.count - 1] += " " + unit.text
            } else {
                lines.append("\(unit.speaker): \(unit.text)")
                lastSpeaker = unit.speaker
            }
            if !speakers.contains(unit.speaker) {
                speakers.append(unit.speaker)
            }
        }
        return SearchChunk(
            kind: .transcript,
            start: units.first?.start,
            end: units.last?.end,
            speakers: speakers,
            text: lines.joined(separator: "\n"),
        )
    }

    // MARK: - Summary and cleaned notes

    /// Markdown split at headings, keeping each heading with its section. Long sections are split
    /// again at blank lines.
    static func sections(_ markdown: String) -> [String] {
        var sections: [[String]] = [[]]
        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("#"), !(sections.last ?? []).isEmpty {
                sections.append([])
            }
            sections[sections.count - 1].append(line)
        }
        return sections.flatMap { lines in
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.contains(where: { $0.isLetter || $0.isNumber }) else {
                return [String]()
            }
            return wordCount(text) > sectionWords ? paragraphs(text) : [text]
        }
    }

    private static func paragraphs(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n\n") {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            if !current.isEmpty, wordCount(current) + wordCount(trimmed) > sectionWords {
                result.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n\n") + trimmed
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    // MARK: - Typed notes

    /// Lines grouped until a blank line or `noteWords`, each group at its first line's time.
    static func noteChunks(_ notes: MeetingNotes) -> [SearchChunk] {
        var chunks: [SearchChunk] = []
        var lines: [String] = []
        var start: Double?
        func flush() {
            if !lines.isEmpty {
                chunks.append(SearchChunk(kind: .notes, start: start, text: lines.joined(separator: "\n")))
            }
            lines = []
            start = nil
        }
        for (index, line) in notes.lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                flush()
                continue
            }
            if !lines.isEmpty, wordCount(lines.joined(separator: " ")) + wordCount(trimmed) > noteWords {
                flush()
            }
            if lines.isEmpty || start == nil {
                start = index < notes.times.count ? notes.times[index] : nil
            }
            lines.append(trimmed)
        }
        flush()
        return chunks
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
