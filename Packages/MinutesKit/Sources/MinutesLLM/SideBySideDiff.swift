// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Two versions of a text lined up for reading side by side: unchanged lines level with each
/// other, and the words that differ marked inside lines that were edited.
public struct SideBySideDiff: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case unchanged
        /// Only on the left.
        case removed
        /// Only on the right.
        case added
        /// A line on each side that took the other's place.
        case changed
    }

    /// A run of a line's text that's the same on both sides, or isn't.
    public struct Segment: Equatable, Sendable {
        public var text: String
        public var isChanged: Bool

        public init(_ text: String, isChanged: Bool) {
            self.text = text
            self.isChanged = isChanged
        }
    }

    public struct Row: Equatable, Sendable {
        public var kind: Kind
        public var left: [Segment]?
        public var right: [Segment]?
    }

    /// Lines sharing less than this share of their words are shown as replaced whole, since
    /// marking a few common words in a rewritten line only adds noise.
    static let similarEnough = 0.4

    public let rows: [Row]

    public init(old: String, new: String) {
        let oldLines = Self.lines(of: old)
        let newLines = Self.lines(of: new)
        var rows: [Row] = []
        Self.walk(old: oldLines, new: newLines) { removed, inserted, unchanged in
            for index in 0 ..< max(removed.count, inserted.count) {
                switch (index < removed.count ? removed[index] : nil, index < inserted.count ? inserted[index] : nil) {
                case let (left?, right?):
                    let (leftSegments, rightSegments) = Self.words(oldLines[left], newLines[right])
                    rows.append(Row(kind: .changed, left: leftSegments, right: rightSegments))
                case let (left?, nil):
                    rows.append(Row(kind: .removed, left: [Segment(oldLines[left], isChanged: true)], right: nil))
                case let (nil, right?):
                    rows.append(Row(kind: .added, left: nil, right: [Segment(newLines[right], isChanged: true)]))
                case (nil, nil):
                    break
                }
            }
            if let line = unchanged {
                let segments = [Segment(line, isChanged: false)]
                rows.append(Row(kind: .unchanged, left: segments, right: segments))
            }
        }
        self.rows = rows
    }

    public var hasChanges: Bool {
        rows.contains { $0.kind != .unchanged }
    }

    static func lines(of text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : trimmed.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
    }

    /// Calls `visit` with each stretch of removed and inserted lines before an unchanged line, and
    /// once more for a stretch at the end.
    private static func walk(old: [String], new: [String], visit: ([Int], [Int], String?) -> Void) {
        var removals = Set<Int>()
        var insertions = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case let .remove(offset, _, _): removals.insert(offset)
            case let .insert(offset, _, _): insertions.insert(offset)
            }
        }
        var oldIndex = 0
        var newIndex = 0
        var removed: [Int] = []
        var inserted: [Int] = []
        while oldIndex < old.count || newIndex < new.count {
            if oldIndex < old.count, removals.contains(oldIndex) {
                removed.append(oldIndex)
                oldIndex += 1
            } else if newIndex < new.count, insertions.contains(newIndex) {
                inserted.append(newIndex)
                newIndex += 1
            } else if oldIndex < old.count, newIndex < new.count {
                visit(removed, inserted, new[newIndex])
                removed = []
                inserted = []
                oldIndex += 1
                newIndex += 1
            } else {
                break
            }
        }
        if !removed.isEmpty || !inserted.isEmpty {
            visit(removed, inserted, nil)
        }
    }

    /// Both lines in segments, with the words only one side has marked.
    static func words(_ old: String, _ new: String) -> ([Segment], [Segment]) {
        let oldTokens = tokens(of: old)
        let newTokens = tokens(of: new)
        let difference = newTokens.difference(from: oldTokens)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        let oldWords = oldTokens.count { !$0.allSatisfy(\.isWhitespace) }
        let newWords = newTokens.count { !$0.allSatisfy(\.isWhitespace) }
        let shared = oldTokens.indices.count { !removed.contains($0) && !oldTokens[$0].allSatisfy(\.isWhitespace) }
        guard Double(shared) / Double(max(1, max(oldWords, newWords))) >= similarEnough else {
            return ([Segment(old, isChanged: true)], [Segment(new, isChanged: true)])
        }
        return (segments(oldTokens, marked: removed), segments(newTokens, marked: inserted))
    }

    /// Words and the spaces between them, so a line can be put back together exactly.
    private static func tokens(of line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var isSpace: Bool?
        for character in line {
            let space = character.isWhitespace
            if space != isSpace, !current.isEmpty {
                tokens.append(current)
                current = ""
            }
            current.append(character)
            isSpace = space
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    /// Joins neighbouring tokens that are marked the same. Spaces take the mark of the words on
    /// both sides of them, so a run of changed words reads as one.
    private static func segments(_ tokens: [String], marked: Set<Int>) -> [Segment] {
        var result: [Segment] = []
        for (index, token) in tokens.enumerated() {
            var changed = marked.contains(index)
            if token.allSatisfy(\.isWhitespace) {
                changed = index > 0 && index < tokens.count - 1
                    && marked.contains(index - 1) && marked.contains(index + 1)
            }
            if let last = result.last, last.isChanged == changed {
                result[result.count - 1].text += token
            } else {
                result.append(Segment(token, isChanged: changed))
            }
        }
        return result
    }
}
