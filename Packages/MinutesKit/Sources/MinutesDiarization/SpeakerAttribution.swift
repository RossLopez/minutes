// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesStorage

/// Gives each word on the system track to whoever the diarizer heard at that moment.
public enum SpeakerAttribution {
    public struct Result: Equatable, Sendable {
        /// One speaker ID per word, like `speaker-2`.
        public var speakers: [String]
        /// The diarizer's IDs mapped to the transcript's. Speakers with no words are left out.
        public var ids: [String: String]
    }

    /// A word goes to the turn its midpoint falls in, or the nearest one if it falls in a gap.
    /// Speakers are numbered by when their first word comes. With no turns at all, every word
    /// goes to `others`.
    public static func attribute(_ words: [TranscriptWord], to diarization: Diarization) -> Result {
        let turns = diarization.turns.sorted { $0.start < $1.start }
        guard !turns.isEmpty else {
            return Result(speakers: words.map { _ in Transcript.Speaker.others }, ids: [:])
        }
        var ids: [String: String] = [:]
        let speakers = words.map { word in
            let engineID = turn(for: word, in: turns).speaker
            if let id = ids[engineID] {
                return id
            }
            let id = "speaker-\(ids.count + 1)"
            ids[engineID] = id
            return id
        }
        return Result(speakers: speakers, ids: ids)
    }

    /// The turn holding the word's midpoint, the longest-overlapping one if several do, or else
    /// the closest.
    private static func turn(for word: TranscriptWord, in turns: [SpeakerTurn]) -> SpeakerTurn {
        let middle = (word.start + word.end) / 2
        let next = firstIndex(startingAfter: middle, in: turns)
        // Turns can overlap a little, so look back past the nearest for any that still hold the middle.
        let earlier = turns[max(0, next - 8) ..< next]
        let holding = earlier.filter { $0.end >= middle }
        if let best = holding.max(by: { overlap($0, word) < overlap($1, word) }) {
            return best
        }
        let before = earlier.max { $0.end < $1.end }
        let after = next < turns.count ? turns[next] : nil
        if let before, let after {
            return middle - before.end <= after.start - middle ? before : after
        }
        return before ?? after ?? turns[0]
    }

    /// The first turn starting after `time`, or the end.
    private static func firstIndex(startingAfter time: Double, in turns: [SpeakerTurn]) -> Int {
        var low = 0
        var high = turns.count
        while low < high {
            let mid = (low + high) / 2
            if turns[mid].start <= time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private static func overlap(_ turn: SpeakerTurn, _ word: TranscriptWord) -> Double {
        min(turn.end, word.end) - max(turn.start, word.start)
    }
}
