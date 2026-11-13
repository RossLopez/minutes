// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Rewrites a meeting's notes as tidy Markdown with any model, giving it as much of the
/// transcript as fits for names and shorthand.
public struct NotesCleaner: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// The notes have no text.
        case noNotes
    }

    /// What the model was given besides the notes.
    public enum Context: Equatable, Sendable {
        case wholeTranscript
        /// Parts of the transcript around the notes' times, this many seconds before and after.
        case excerpts(count: Int, before: Double, after: Double)
        case summary
        case namesOnly
    }

    public struct Result: Equatable, Sendable {
        public var text: String
        public var context: Context
    }

    /// What's sent, what context it holds, and the answer's room.
    struct Prompt {
        var messages: [LLMMessage]
        var context: Context
        var maxTokens: Int
    }

    /// A note usually follows what was said, so excerpts reach further back than forward.
    static let excerptBefore: Double = 180
    static let excerptAfter: Double = 60
    /// Excerpts narrow by half until they fit, down to about this much before each note.
    static let narrowestBefore: Double = 20

    public let provider: any LLMProvider

    public init(provider: any LLMProvider) {
        self.provider = provider
    }

    /// - Parameters:
    ///   - names: the names of everyone in the meeting.
    ///   - summary: the meeting's summary, read when the transcript doesn't fit.
    ///   - emit: the cleaned-up notes, a piece at a time.
    public func clean(
        _ notes: [NoteLine],
        transcript: [SummaryLine],
        names: [String],
        summary: String?,
        meeting: String,
        emit: @Sendable (String) -> Void = { _ in },
    ) async throws -> Result {
        let notes = Self.trimmed(notes)
        guard notes.contains(where: { !$0.text.allSatisfy(\.isWhitespace) }) else {
            throw Failure.noNotes
        }
        let prompt = try await prompt(
            notes: notes, transcript: transcript, names: names, summary: summary, meeting: meeting,
        )
        var text = ""
        let options = GenerationOptions(maxTokens: prompt.maxTokens)
        for try await piece in provider.generate(prompt.messages, options: options) {
            text += piece
            emit(piece)
        }
        // A cancelled stream just ends, which would pass for a short answer.
        try Task.checkCancellation()
        return Result(text: text.trimmingCharacters(in: .whitespacesAndNewlines), context: prompt.context)
    }

    /// The prompt with the most context that fits.
    func prompt(
        notes: [NoteLine],
        transcript: [SummaryLine],
        names: [String],
        summary: String?,
        meeting: String,
    ) async throws -> Prompt {
        let limit = try await provider.contextLength()
        let bare = NotesPrompts.cleanup(notes: notes, context: .none, names: names, meeting: meeting)
        let notesText = notes.map(\.promptText).joined(separator: "\n")
        let notesOnly = try await provider.tokenCount([LLMMessage(.user, notesText)])
        let maxTokens = min(4096, max(1024, notesOnly * 3))
        let bareCost = try await provider.tokenCount(bare)
        guard bareCost + maxTokens <= limit else {
            throw LLMError.promptTooLong(tokens: bareCost + maxTokens, limit: limit)
        }
        func fits(_ context: NotesPrompts.Context) async throws -> [LLMMessage]? {
            let messages = NotesPrompts.cleanup(notes: notes, context: context, names: names, meeting: meeting)
            return try await provider.tokenCount(messages) + maxTokens <= limit ? messages : nil
        }

        if !transcript.isEmpty,
           let messages = try await fits(.transcript(transcript.map(\.promptText).joined(separator: "\n")))
        {
            return Prompt(messages: messages, context: .wholeTranscript, maxTokens: maxTokens)
        }
        let times = notes.compactMap(\.seconds)
        if !transcript.isEmpty, !times.isEmpty {
            var before = Self.excerptBefore
            var after = Self.excerptAfter
            while before >= Self.narrowestBefore {
                let excerpts = Self.excerpts(of: transcript, around: times, before: before, after: after)
                if !excerpts.isEmpty, let messages = try await fits(.excerpts(excerpts)) {
                    let context = Context.excerpts(count: excerpts.count, before: before, after: after)
                    return Prompt(messages: messages, context: context, maxTokens: maxTokens)
                }
                before /= 2
                after /= 2
            }
        }
        if let summary, !summary.allSatisfy(\.isWhitespace), let messages = try await fits(.summary(summary)) {
            return Prompt(messages: messages, context: .summary, maxTokens: maxTokens)
        }
        return Prompt(messages: bare, context: .namesOnly, maxTokens: maxTokens)
    }

    /// Transcript lines that started within each note's window, with overlapping windows merged.
    static func excerpts(of transcript: [SummaryLine], around times: [Double], before: Double,
                         after: Double) -> [String]
    {
        var windows: [ClosedRange<Double>] = []
        for time in times.sorted() {
            let window = max(0, time - before) ... time + after
            if let last = windows.last, window.lowerBound <= last.upperBound {
                windows[windows.count - 1] = last.lowerBound ... max(last.upperBound, window.upperBound)
            } else {
                windows.append(window)
            }
        }
        return windows.compactMap { window in
            let lines = transcript.filter { window.contains($0.start) }
            guard !lines.isEmpty else {
                return nil
            }
            let range = "From \(NotesPrompts.time(window.lowerBound)) to \(NotesPrompts.time(window.upperBound)):"
            return ([range] + lines.map(\.promptText)).joined(separator: "\n")
        }
    }

    /// Without blank lines at the start and end.
    private static func trimmed(_ notes: [NoteLine]) -> [NoteLine] {
        let isBlank: (NoteLine) -> Bool = { $0.text.allSatisfy(\.isWhitespace) }
        guard let first = notes.firstIndex(where: { !isBlank($0) }),
              let last = notes.lastIndex(where: { !isBlank($0) })
        else {
            return []
        }
        return Array(notes[first ... last])
    }
}
