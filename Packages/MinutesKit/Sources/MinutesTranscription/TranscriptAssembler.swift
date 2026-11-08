// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesStorage

/// Turns each track's words into the lines of one transcript.
public enum TranscriptAssembler {
    /// A silence this long, in seconds, always starts a new line.
    static let pauseBreak = 1.0
    /// A line this long ends at the next sentence end.
    static let sentenceBreakAfter = 6.0
    /// A line never runs longer, so clicking it lands near what you're reading and overlaps stay short.
    static let longestLine = 20.0

    public static func segments(from words: [TranscriptWord], speaker: String) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var current: [TranscriptWord] = []
        for word in words {
            if let first = current.first, let last = current.last,
               startsNewLine(word, after: last, lineStart: first.start)
            {
                segments.append(TranscriptSegment(speaker: speaker, words: current))
                current = []
            }
            current.append(word)
        }
        if !current.isEmpty {
            segments.append(TranscriptSegment(speaker: speaker, words: current))
        }
        return segments
    }

    /// Orders lines from both tracks by when they start. Lines that overlap each stay whole, one
    /// after the other, because splitting someone's sentence around a "yeah" is harder to read.
    public static func merge(_ tracks: [TranscriptSegment]...) -> [TranscriptSegment] {
        // Sorting isn't stable, so the original position settles ties: the first track goes first.
        tracks.joined().enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
    }

    private static func startsNewLine(_ word: TranscriptWord, after last: TranscriptWord, lineStart: Double) -> Bool {
        if word.start - last.end >= pauseBreak || word.end - lineStart > longestLine {
            return true
        }
        return last.end - lineStart >= sentenceBreakAfter && endsSentence(last.text)
    }

    private static func endsSentence(_ text: String) -> Bool {
        text.last.map { ".?!…".contains($0) } ?? false
    }
}
