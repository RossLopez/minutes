// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesStorage

/// Compares the voices in a meeting with saved profiles. The cutoffs were measured on AMI's
/// ES2004 meetings, where the same person scored 0.78 to 0.97 and different people at most 0.39
/// (docs/NOTES.md, Milestone 4).
public enum VoiceMatcher {
    /// At or above this, and clearly ahead of the next profile, the name is applied.
    public static let applyAt: Float = 0.70
    /// At or above this, the name is offered as a suggestion.
    public static let suggestAt: Float = 0.50
    /// How far ahead of the next profile an applied match has to be.
    public static let margin: Float = 0.15

    public enum Match: Equatable, Sendable {
        case applied(profile: UUID, name: String)
        case suggested(profile: UUID, name: String)
    }

    /// The best match for each speaker that has one. A profile names at most one speaker, the one
    /// it sounds most like. `declined` holds profiles the user said a speaker isn't.
    public static func match(
        _ voices: [String: [Float]],
        against profiles: [SpeakerProfile],
        declined: [String: Set<UUID>] = [:],
    ) -> [String: Match] {
        struct Pair {
            let speaker: String
            let profile: SpeakerProfile
            let similarity: Float
        }
        var pairs: [Pair] = []
        var secondBest: [String: Float] = [:]
        for (speaker, voice) in voices {
            var scores = profiles
                .filter { !(declined[speaker]?.contains($0.id) ?? false) }
                .map { Pair(speaker: speaker, profile: $0, similarity: similarity(voice, $0)) }
            scores.sort { $0.similarity > $1.similarity }
            secondBest[speaker] = scores.count > 1 ? scores[1].similarity : -1
            pairs += scores.filter { $0.similarity >= suggestAt }
        }
        // Strongest first, so a profile goes to the speaker it fits best. Ties break by speaker ID
        // so the result doesn't depend on dictionary order.
        pairs.sort { ($0.similarity, $1.speaker) > ($1.similarity, $0.speaker) }

        var matches: [String: Match] = [:]
        var usedProfiles = Set<UUID>()
        for pair in pairs where matches[pair.speaker] == nil && !usedProfiles.contains(pair.profile.id) {
            usedProfiles.insert(pair.profile.id)
            let clear = pair.similarity - (secondBest[pair.speaker] ?? -1) >= margin
            matches[pair.speaker] = pair.similarity >= applyAt && clear
                ? .applied(profile: pair.profile.id, name: pair.profile.name)
                : .suggested(profile: pair.profile.id, name: pair.profile.name)
        }
        return matches
    }

    /// The closest of the profile's samples, since each is one meeting's measurement.
    public static func similarity(_ voice: [Float], _ profile: SpeakerProfile) -> Float {
        profile.samples.map { cosine(voice, $0.embedding) }.max() ?? -1
    }

    /// -1 for vectors that can't be compared.
    public static func cosine(_ first: [Float], _ second: [Float]) -> Float {
        guard first.count == second.count, !first.isEmpty else {
            return -1
        }
        var dot: Float = 0
        var firstNorm: Float = 0
        var secondNorm: Float = 0
        for index in first.indices {
            dot += first[index] * second[index]
            firstNorm += first[index] * first[index]
            secondNorm += second[index] * second[index]
        }
        let norms = firstNorm.squareRoot() * secondNorm.squareRoot()
        return norms > 0 ? dot / norms : -1
    }
}
