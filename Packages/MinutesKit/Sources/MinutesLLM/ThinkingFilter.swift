// SPDX-License-Identifier: GPL-3.0-or-later

/// Drops the `<think>…</think>` block a reasoning model can start its answer with, when the server
/// leaves it in the text instead of moving it to a reasoning field. Only a block at the very start
/// counts, so a summary that quotes the tag keeps it.
public struct ThinkingFilter: Sendable {
    private static let open = "<think>"
    private static let close = "</think>"

    private enum State {
        /// Not sure yet: everything so far could be the start of `<think>`.
        case deciding(String)
        case thinking(String)
        /// Just past the block, where the blank lines before the answer are dropped.
        case afterThinking
        case answering
    }

    private var state = State.deciding("")

    public init() {}

    /// The text that's now safe to show.
    public mutating func feed(_ piece: String) -> String {
        switch state {
        case let .deciding(held):
            decide(held + piece)
        case let .thinking(held):
            think(held + piece)
        case .afterThinking:
            skipBlank(piece)
        case .answering:
            piece
        }
    }

    /// Whatever was held back. A block that never closed was all thinking, so none of it shows.
    public mutating func finish() -> String {
        defer {
            state = .answering
        }
        if case let .deciding(held) = state {
            return held
        }
        return ""
    }

    private mutating func decide(_ text: String) -> String {
        let start = text.drop { $0.isWhitespace }
        if start.hasPrefix(Self.open) {
            return think(String(start.dropFirst(Self.open.count)))
        }
        if Self.open.hasPrefix(start) {
            state = .deciding(text)
            return ""
        }
        state = .answering
        return text
    }

    private mutating func think(_ text: String) -> String {
        guard let end = text.range(of: Self.close) else {
            // Keep only enough to find a closing tag split across pieces.
            state = .thinking(String(text.suffix(Self.close.count - 1)))
            return ""
        }
        return skipBlank(String(text[end.upperBound...]))
    }

    private mutating func skipBlank(_ text: String) -> String {
        let answer = text.drop { $0.isWhitespace }
        state = answer.isEmpty ? .afterThinking : .answering
        return String(answer)
    }
}
