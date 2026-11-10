// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The words Minutes sends a model when it summarizes. Templates supply the part the user edits.
public enum SummaryPrompts {
    /// The default template's prompt, written to `Templates/Default.md` the first time it's needed.
    public static let defaultInstructions = """
    Summarize this meeting in Markdown with exactly these three sections, using these headings.

    ## Overview
    One short paragraph: what the meeting was about and what came of it.

    ## Key points and decisions
    A bulleted list of the main points. Start a bullet with **Decision:** only when the group clearly \
    agreed on or settled something. Ideas, options and open questions are points, not decisions.

    ## Action items
    A checklist with one task per line, each starting with `- [ ] ` and then the name of the person \
    who took the task on, in bold and followed by a colon, then the task and its due date if one was \
    given. If nobody took a task on, put **Owner not stated:** where the name goes. If there are no \
    action items, write "None."
    """

    static let system = """
    You write summaries of recorded meetings for the person who recorded them. Use only what the \
    transcript says, and never add facts, names or dates that aren't in it. Refer to people by the \
    names the transcript uses. "Me" is the person who recorded the meeting. Transcription can garble \
    words, so prefer the meaning that fits the conversation. Write in Markdown, in the language of \
    the meeting, and start directly with the first heading.
    """

    static func summary(of transcript: String, meeting: String, instructions: String) -> [LLMMessage] {
        [
            LLMMessage(.system, system),
            LLMMessage(.user, """
            \(instructions)

            Meeting: \(meeting)

            Transcript, one line per turn with the time it started:
            \(transcript)
            """),
        ]
    }

    static func notes(on transcript: String, part: Int, of parts: Int, meeting: String) -> [LLMMessage] {
        [
            LLMMessage(.system, system),
            LLMMessage(.user, """
            This is part \(part) of \(parts) of a meeting's transcript. Write notes on this part only, \
            in Markdown bullets: the topics discussed, any decisions, and any tasks someone took on, \
            with who took them on, the due date if one was given, and the time. Keep names exactly as \
            the transcript writes them. Don't write an introduction or a conclusion.

            Meeting: \(meeting)

            Transcript, part \(part) of \(parts):
            \(transcript)
            """),
        ]
    }

    static func summary(fromNotes notes: [String], meeting: String, instructions: String) -> [LLMMessage] {
        [
            LLMMessage(.system, system),
            LLMMessage(.user, """
            \(instructions)

            The meeting was too long to read at once, so here are notes on each part, in order. \
            Base the summary on all of them.

            Meeting: \(meeting)

            \(numbered(notes))
            """),
        ]
    }

    static func combining(_ notes: [String], meeting: String) -> [LLMMessage] {
        [
            LLMMessage(.system, system),
            LLMMessage(.user, """
            These are notes on consecutive parts of one meeting. Merge them into one set of notes in \
            Markdown bullets, keeping every decision and every task with its owner, due date and time. \
            Remove repetition but nothing else.

            Meeting: \(meeting)

            \(numbered(notes))
            """),
        ]
    }

    private static func numbered(_ notes: [String]) -> String {
        notes.enumerated()
            .map { "Notes on part \($0.offset + 1) of \(notes.count):\n\($0.element)" }
            .joined(separator: "\n\n")
    }
}
