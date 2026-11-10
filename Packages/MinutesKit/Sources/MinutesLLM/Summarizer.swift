// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One line of a transcript, as the summary prompt shows it.
public struct SummaryLine: Equatable, Sendable {
    public var start: Double
    /// The name the meeting uses, like "Dana" or "Speaker 2".
    public var speaker: String
    public var text: String

    public init(start: Double, speaker: String, text: String) {
        self.start = start
        self.speaker = speaker
        self.text = text
    }

    /// `[12:04] Dana: Let's ship it.`, or `[1:02:04]` past an hour.
    public var promptText: String {
        let total = Int(start.rounded(.down))
        let (hours, minutes, seconds) = (total / 3600, total / 60 % 60, total % 60)
        let time = hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
        return "[\(time)] \(speaker): \(text)"
    }
}

/// Writes a summary with any model, splitting transcripts that don't fit its context.
public struct Summarizer: Sendable {
    public enum Stage: Equatable, Sendable {
        /// Taking notes on part `part` of `total`, for a transcript too long to read at once.
        case readingPart(Int, total: Int)
        /// Folding notes together when even they don't fit.
        case combiningNotes
        /// The summary itself, which streams.
        case writing
    }

    public enum Failure: Error, Equatable, Sendable {
        /// Fewer than `minimumWords` words were said.
        case tooLittleSaid
    }

    public static let minimumWords = 20

    public let provider: any LLMProvider
    public var summaryTokens = 2048
    public var notesTokens = 1024

    public init(provider: any LLMProvider) {
        self.provider = provider
    }

    /// - Parameters:
    ///   - instructions: the template's prompt.
    ///   - stage: where it's got to. Only `.writing` is followed by text.
    ///   - emit: the summary, a piece at a time.
    /// - Returns: the whole summary.
    public func summarize(
        _ lines: [SummaryLine],
        about meeting: String,
        instructions: String,
        stage: @Sendable (Stage) -> Void = { _ in },
        emit: @Sendable (String) -> Void = { _ in },
    ) async throws -> String {
        let words = lines.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        guard words >= Self.minimumWords else {
            throw Failure.tooLittleSaid
        }
        let transcript = lines.map(\.promptText).joined(separator: "\n")
        let whole = SummaryPrompts.summary(of: transcript, meeting: meeting, instructions: instructions)
        let limit = try await provider.contextLength()
        if try await provider.tokenCount(whole) + summaryTokens <= limit {
            stage(.writing)
            return try await write(whole, maxTokens: summaryTokens, emit: emit)
        }

        let parts = try await split(lines, meeting: meeting, limit: limit)
        var notes: [String] = []
        for (index, part) in parts.enumerated() {
            stage(.readingPart(index + 1, total: parts.count))
            let prompt = SummaryPrompts.notes(on: part, part: index + 1, of: parts.count, meeting: meeting)
            try await notes.append(write(prompt, maxTokens: notesTokens))
        }
        var combined = SummaryPrompts.summary(fromNotes: notes, meeting: meeting, instructions: instructions)
        while try await provider.tokenCount(combined) + summaryTokens > limit, notes.count > 1 {
            stage(.combiningNotes)
            notes = try await combine(notes, meeting: meeting, limit: limit)
            combined = SummaryPrompts.summary(fromNotes: notes, meeting: meeting, instructions: instructions)
        }
        stage(.writing)
        return try await write(combined, maxTokens: summaryTokens, emit: emit)
    }

    // MARK: - Splitting

    /// Lines grouped into parts whose notes prompt fits, never splitting a line.
    func split(_ lines: [SummaryLine], meeting: String, limit: Int) async throws -> [String] {
        let budget = limit - notesTokens
        let texts = lines.map(\.promptText)
        let empty = try await provider.tokenCount(SummaryPrompts.notes(on: "", part: 1, of: 1, meeting: meeting))
        let all = texts.joined(separator: "\n")
        let allTokens = try await provider.tokenCount(SummaryPrompts.notes(on: all, part: 1, of: 1, meeting: meeting))
        // Aim under the budget using the transcript's own characters per token, then check each part.
        let perToken = Double(all.count) / Double(max(1, allTokens - empty))
        let target = Int(Double(budget - empty) * 0.85 * perToken)
        guard target > 0 else {
            throw LLMError.promptTooLong(tokens: empty + notesTokens, limit: limit)
        }
        var parts: [[String]] = []
        var current: [String] = []
        var length = 0
        for text in texts {
            if !current.isEmpty, length + text.count + 1 > target {
                parts.append(current)
                current = []
                length = 0
            }
            current.append(text)
            length += text.count + 1
        }
        if !current.isEmpty {
            parts.append(current)
        }
        return try await fitted(parts, meeting: meeting, budget: budget)
    }

    /// Halves any part that still came out too long.
    private func fitted(_ parts: [[String]], meeting: String, budget: Int) async throws -> [String] {
        var result: [String] = []
        var queue = parts[...]
        while let part = queue.popFirst() {
            let text = part.joined(separator: "\n")
            let cost = try await provider.tokenCount(SummaryPrompts.notes(on: text, part: 1, of: 1, meeting: meeting))
            if cost <= budget {
                result.append(text)
            } else if part.count > 1 {
                let middle = part.count / 2
                queue = [Array(part[..<middle]), Array(part[middle...])] + queue
            } else {
                throw LLMError.promptTooLong(tokens: cost + notesTokens, limit: budget + notesTokens)
            }
        }
        return result
    }

    /// One round of folding neighbouring notes together, two or more at a time.
    private func combine(_ notes: [String], meeting: String, limit: Int) async throws -> [String] {
        var groups: [[String]] = []
        var current: [String] = []
        for note in notes {
            let candidate = current + [note]
            let cost = try await provider.tokenCount(SummaryPrompts.combining(candidate, meeting: meeting))
            if current.count >= 2, cost + notesTokens > limit {
                groups.append(current)
                current = [note]
            } else {
                current = candidate
            }
        }
        groups.append(current)
        if groups.count == notes.count {
            // Each note is too long to pair with its neighbour; merge them two by two regardless.
            groups = stride(from: 0, to: notes.count, by: 2).map { Array(notes[$0 ..< min($0 + 2, notes.count)]) }
        }
        var combined: [String] = []
        for group in groups {
            try await combined.append(write(SummaryPrompts.combining(group, meeting: meeting), maxTokens: notesTokens))
        }
        return combined
    }

    private func write(
        _ messages: [LLMMessage],
        maxTokens: Int,
        emit: @Sendable (String) -> Void = { _ in },
    ) async throws -> String {
        var text = ""
        let options = GenerationOptions(maxTokens: maxTokens)
        for try await piece in provider.generate(messages, options: options) {
            text += piece
            emit(piece)
        }
        // A cancelled stream just ends, which would pass for a short answer.
        try Task.checkCancellation()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
