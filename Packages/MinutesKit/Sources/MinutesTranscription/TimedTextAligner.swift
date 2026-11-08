// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesStorage

/// Carries word timings over to a rewritten text, for engines whose vocabulary step returns only
/// text. Unchanged words keep their times, and rewritten words share the time of those they replaced.
public enum TimedTextAligner {
    public static func retime(_ words: [TranscriptWord], toMatch text: String) -> [TranscriptWord] {
        let rewritten = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let difference = rewritten.difference(from: words.map(\.text))
        guard !difference.isEmpty else {
            return words
        }
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }

        var result: [TranscriptWord] = []
        result.reserveCapacity(rewritten.count)
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < words.count || newIndex < rewritten.count {
            let oldStart = oldIndex
            let newStart = newIndex
            while removed.contains(oldIndex) {
                oldIndex += 1
            }
            while inserted.contains(newIndex) {
                newIndex += 1
            }
            if oldIndex == oldStart, newIndex == newStart {
                result.append(words[oldIndex])
                oldIndex += 1
                newIndex += 1
            } else if newIndex > newStart {
                let span = timeSpan(of: words[oldStart ..< oldIndex], after: result.last, before: oldIndex, in: words)
                result += share(span, among: rewritten[newStart ..< newIndex])
            }
        }
        return result
    }

    /// The time the replaced words took. Words with nothing to replace get an instant next to their neighbors.
    private static func timeSpan(
        of replaced: ArraySlice<TranscriptWord>,
        after previous: TranscriptWord?,
        before nextIndex: Int,
        in words: [TranscriptWord],
    ) -> ClosedRange<Double> {
        if let first = replaced.first, let last = replaced.last {
            return first.start ... max(first.start, last.end)
        }
        let moment = previous?.end ?? (nextIndex < words.count ? words[nextIndex].start : 0)
        return moment ... moment
    }

    private static func share(_ span: ClosedRange<Double>, among texts: ArraySlice<String>) -> [TranscriptWord] {
        let totalLength = texts.reduce(0) { $0 + $1.count }
        var start = span.lowerBound
        return texts.map { text in
            let share = Double(text.count) / Double(max(totalLength, 1))
            let end = start + (span.upperBound - span.lowerBound) * share
            defer { start = end }
            return TranscriptWord(text: text, start: start, end: end)
        }
    }
}
