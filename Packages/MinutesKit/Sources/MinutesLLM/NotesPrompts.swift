// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One line of the notes the user typed.
public struct NoteLine: Equatable, Sendable {
    public var text: String
    /// Seconds since the recording started, for lines typed while recording.
    public var seconds: Double?

    public init(_ text: String, seconds: Double? = nil) {
        self.text = text
        self.seconds = seconds
    }

    /// `[3:15] remote: rubber?`, or the text alone without a time.
    var promptText: String {
        seconds.map { "[\(NotesPrompts.time($0))] \(text)" } ?? text
    }
}

/// The words Minutes sends a model when it cleans up notes.
enum NotesPrompts {
    static let system = """
    You tidy up notes that a person typed during a meeting they recorded. Rewrite them as clear, \
    well organized Markdown: `## ` headings for topics, with bullet points under them.

    Rules:
    - Every note becomes a bullet, in the order of its topic, with its meaning unchanged. Never \
    drop a note, merge away its details, or turn its meaning around. Question marks in a note mean \
    an open question or a doubt, so keep them as one.
    - Keep who said, suggested or asked each thing when the note says, writing the person's full \
    name in place of an initial.
    - Don't add points the notes don't make. Keep each bullet about as short as its note, adding only \
    what's needed to spell out shorthand.
    - Use the transcript, when there is one, only to correct names and misspellings, to say who a \
    name's initial stands for, and to spell out shorthand and abbreviations. Never take facts, \
    numbers, examples, decisions or tasks from the transcript that the notes don't mention.
    - Only when the notes mention tasks, end with an action items checklist: one task per line, \
    starting with `- [ ] ` and then the owner's name in bold followed by a colon, or \
    **Owner not stated:** when nobody is named. Otherwise leave the section out.
    - Times in square brackets show when a note was typed. Leave them out.

    "Me" is the person who took the notes. Write in the language of the notes, and start directly \
    with the first heading.
    """

    /// What the model reads besides the notes.
    enum Context: Equatable {
        case transcript(String)
        /// Parts of the transcript, each with its time range.
        case excerpts([String])
        case summary(String)
        case none
    }

    static func cleanup(
        notes: [NoteLine],
        context: Context,
        names: [String],
        meeting: String,
    ) -> [LLMMessage] {
        var parts = ["Meeting: \(meeting)"]
        if !names.isEmpty {
            parts.append("People in the meeting: \(names.joined(separator: ", "))")
        }
        switch context {
        case let .transcript(text):
            parts.append("Transcript, one line per turn with the time it started:\n\(text)")
        case let .excerpts(excerpts):
            parts.append("""
            Parts of the transcript from around the times the notes were typed, one line per turn:
            \(excerpts.joined(separator: "\n\n"))
            """)
        case let .summary(text):
            parts.append("A summary of the meeting, for names and context:\n\(text)")
        case .none:
            break
        }
        parts.append("""
        The notes to tidy up:
        \(notes.map(\.promptText).joined(separator: "\n"))
        """)
        return [LLMMessage(.system, system), LLMMessage(.user, parts.joined(separator: "\n\n"))]
    }

    /// `3:15`, or `1:02:04` past an hour, as `SummaryLine` writes times.
    static func time(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}
