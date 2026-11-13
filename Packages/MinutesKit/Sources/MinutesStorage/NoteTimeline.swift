// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// When each line of the notes was written, in seconds since the recording started, kept in step
/// with the text as it's edited.
public enum NoteTimeline {
    /// The notes' lines. A trailing newline gives a last, empty line, as an editor shows it.
    /// Windows line endings count once, since Swift reads `\r\n` as one character.
    public static func lines(of text: String) -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    }

    /// The times for `new`, after an edit from `old`.
    ///
    /// Unchanged lines keep their times. Between unchanged lines, removed and inserted lines pair
    /// up in order, so typing inside a line keeps its time. A line that gets text with no time yet
    /// takes `now`, which is nil once the recording has stopped.
    public static func update(old: [String], new: [String], times: [Double?], now: Double?) -> [Double?] {
        var result = [Double?](repeating: nil, count: new.count)
        walk(old: old, new: new) { removed, inserted, unchanged in
            for (pair, newIndex) in inserted.enumerated() {
                let oldTime = pair < removed.count ? time(at: removed[pair], in: times) : nil
                result[newIndex] = oldTime ?? (isBlank(new[newIndex]) ? nil : now)
            }
            if let (oldIndex, newIndex) = unchanged {
                result[newIndex] = time(at: oldIndex, in: times)
            }
        }
        return result
    }

    /// Lines up times saved for the lines `saved` fingerprints stand for with the lines there are
    /// now. Only lines that are still exactly as they were keep their times.
    static func align(saved: [String], times: [Double?], current: [String]) -> [Double?] {
        var result = [Double?](repeating: nil, count: current.count)
        walk(old: saved, new: current) { _, _, unchanged in
            if let (oldIndex, newIndex) = unchanged {
                result[newIndex] = time(at: oldIndex, in: times)
            }
        }
        return result
    }

    /// Calls `visit` once for each stretch of removed and inserted lines before an unchanged line,
    /// with that line's old and new index, and once more for any stretch at the end.
    private static func walk(
        old: [String],
        new: [String],
        visit: (_ removed: [Int], _ inserted: [Int], _ unchanged: (Int, Int)?) -> Void,
    ) {
        let difference = new.difference(from: old)
        var removals = Set<Int>()
        var insertions = Set<Int>()
        for change in difference {
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
                visit(removed, inserted, (oldIndex, newIndex))
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

    private static func time(at index: Int, in times: [Double?]) -> Double? {
        index < times.count ? times[index] : nil
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy(\.isWhitespace)
    }
}
