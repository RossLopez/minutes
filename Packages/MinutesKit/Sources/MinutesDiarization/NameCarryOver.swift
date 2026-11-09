// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesStorage

/// Keeps names when a meeting is transcribed again. The new speakers usually line up with the
/// old ones in time, so this needs no stored voices.
public enum NameCarryOver {
    /// Each old speaker's entry goes to the new speaker that overlaps it most in time, if that
    /// covers more than half of the new speaker's speech. `me` keeps its entry.
    public static func carry(
        from old: [TranscriptSegment],
        names: [String: MeetingMetadata.Speaker],
        to new: [TranscriptSegment],
    ) -> [String: MeetingMetadata.Speaker] {
        var carried: [String: MeetingMetadata.Speaker] = [:]
        if let mine = names[Transcript.Speaker.me] {
            carried[Transcript.Speaker.me] = mine
        }
        let oldBySpeaker = Dictionary(grouping: old.filter { names[$0.speaker] != nil }, by: \.speaker)
        let newBySpeaker = Dictionary(grouping: new, by: \.speaker)

        struct Candidate {
            let old: String
            let new: String
            let overlap: Double
        }
        var candidates: [Candidate] = []
        for (newSpeaker, lines) in newBySpeaker where newSpeaker != Transcript.Speaker.me {
            let spoken = lines.reduce(0) { $0 + ($1.end - $1.start) }
            guard spoken > 0 else {
                continue
            }
            for (oldSpeaker, oldLines) in oldBySpeaker where oldSpeaker != Transcript.Speaker.me {
                let overlap = Self.overlap(lines, oldLines)
                if overlap > spoken / 2 {
                    candidates.append(Candidate(old: oldSpeaker, new: newSpeaker, overlap: overlap))
                }
            }
        }
        candidates.sort { ($0.overlap, $1.new) > ($1.overlap, $0.new) }
        var usedOld = Set<String>()
        for candidate in candidates where carried[candidate.new] == nil && !usedOld.contains(candidate.old) {
            usedOld.insert(candidate.old)
            carried[candidate.new] = names[candidate.old]
        }
        return carried
    }

    /// Seconds when both sets of lines are under way. Each set is in time order and rarely overlaps itself.
    private static func overlap(_ first: [TranscriptSegment], _ second: [TranscriptSegment]) -> Double {
        let first = first.sorted { $0.start < $1.start }
        let second = second.sorted { $0.start < $1.start }
        var total = 0.0
        var index = 0
        var other = 0
        while index < first.count, other < second.count {
            let start = max(first[index].start, second[other].start)
            let end = min(first[index].end, second[other].end)
            total += max(0, end - start)
            if first[index].end < second[other].end {
                index += 1
            } else {
                other += 1
            }
        }
        return total
    }
}
