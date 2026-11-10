// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public extension Transcript {
    /// Everyone who speaks, in the order they first do.
    var speakers: [String] {
        var seen = Set<String>()
        return segments.compactMap { seen.insert($0.speaker).inserted ? $0.speaker : nil }
    }

    /// An ID for a speaker the diarizer didn't find, one past the highest number in use.
    func nextSpeakerID(alsoAvoiding taken: some Sequence<String> = []) -> String {
        let highest = (segments.map(\.speaker) + Array(taken)).compactMap(Self.speakerNumber).max() ?? 0
        return "speaker-\(highest + 1)"
    }

    /// Every line from `speaker` becomes `target`'s.
    func merging(_ speaker: String, into target: String) -> Transcript {
        var merged = self
        for index in merged.segments.indices where merged.segments[index].speaker == speaker {
            merged.segments[index].speaker = target
        }
        return merged
    }

    func reassigning(segmentAt index: Int, to speaker: String) -> Transcript {
        var changed = self
        changed.segments[index].speaker = speaker
        return changed
    }
}

public extension MeetingFolder {
    enum SpeakerEditError: Error, Equatable {
        /// The meeting is being processed, and the pipeline is about to rewrite the transcript.
        case meetingBusy
        case noTranscript
        case noSuchLine
        case noSuchSpeaker
        /// `me` is the mic track, so its lines can't be moved and nobody else can become it.
        case cantChangeMe
    }

    /// Names a speaker, or with `nil` or a blank name, goes back to a label like "Speaker 2".
    /// Accepting or setting a name clears any suggestion.
    @discardableResult
    func nameSpeaker(_ speaker: String, _ name: String?, profile: UUID? = nil) throws -> MeetingMetadata {
        try editSpeakers { transcript, speakers in
            guard transcript.speakers.contains(speaker) || speaker == Transcript.Speaker.me else {
                throw SpeakerEditError.noSuchSpeaker
            }
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var entry = speakers[speaker] ?? MeetingMetadata.Speaker()
            entry.name = trimmed.isEmpty ? nil : trimmed
            entry.profile = trimmed.isEmpty ? nil : profile
            entry.suggestion = nil
            speakers[speaker] = entry
        }.metadata
    }

    /// The user says a suggestion is wrong. It won't be offered for this speaker again.
    func declineSuggestion(for speaker: String) throws {
        try editSpeakers { _, speakers in
            guard var entry = speakers[speaker], let suggestion = entry.suggestion else {
                return
            }
            entry.declinedProfiles = (entry.declinedProfiles ?? []) + [suggestion.profile]
            entry.suggestion = nil
            speakers[speaker] = entry
        }
    }

    /// For when the diarizer split one person in two. `target` keeps its name, or takes
    /// `speaker`'s if it has none.
    func mergeSpeaker(_ speaker: String, into target: String) throws {
        guard speaker != target else {
            return
        }
        try editSpeakers(mergedInto: [speaker: target]) { transcript, speakers in
            guard speaker != Transcript.Speaker.me, target != Transcript.Speaker.me else {
                throw SpeakerEditError.cantChangeMe
            }
            let present = transcript.speakers
            guard present.contains(speaker), present.contains(target) else {
                throw SpeakerEditError.noSuchSpeaker
            }
            transcript = transcript.merging(speaker, into: target)
            if let moved = speakers.removeValue(forKey: speaker), speakers[target]?.name == nil, moved.name != nil {
                speakers[target] = moved
            }
        }
    }

    /// Gives one line to another speaker. Pass `nil` for someone new, and the new ID comes back.
    @discardableResult
    func moveLine(at index: Int, to speaker: String?) throws -> String {
        var target = speaker ?? ""
        try editSpeakers { transcript, speakers in
            guard transcript.segments.indices.contains(index) else {
                throw SpeakerEditError.noSuchLine
            }
            guard transcript.segments[index].speaker != Transcript.Speaker.me, speaker != Transcript.Speaker.me else {
                throw SpeakerEditError.cantChangeMe
            }
            if speaker == nil {
                target = transcript.nextSpeakerID(alsoAvoiding: speakers.keys)
            } else if !transcript.speakers.contains(target) {
                throw SpeakerEditError.noSuchSpeaker
            }
            transcript = transcript.reassigning(segmentAt: index, to: target)
        }
        return target
    }

    /// Changes speaker names outside an edit by the user, such as matching saved voices.
    /// Unlike the edits above, it works while the meeting is being processed.
    @discardableResult
    func updateSpeakers(_ change: (inout [String: MeetingMetadata.Speaker]) -> Void) throws -> MeetingMetadata {
        try updateMetadata { metadata in
            var speakers = metadata.speakers ?? [:]
            change(&speakers)
            speakers = speakers.filter { !$0.value.isEmpty }
            metadata.speakers = speakers.isEmpty ? nil : speakers
        }
    }

    /// Loads the transcript and names, changes them and saves all three files. `transcript.json`
    /// goes before `meeting.json`, since it says who said what: a crash between the two leaves at
    /// worst a name for a speaker with no lines.
    @discardableResult
    private func editSpeakers(
        mergedInto: [String: String] = [:],
        _ change: (inout Transcript, inout [String: MeetingMetadata.Speaker]) throws -> Void,
    ) throws -> (transcript: Transcript, metadata: MeetingMetadata) {
        try Self.metadataLock.withLock {
            var metadata = try loadMetadata()
            guard !metadata.isNewerThanThisApp else {
                throw FolderError.newerFileFormat
            }
            guard metadata.processing?.status != .queued else {
                throw SpeakerEditError.meetingBusy
            }
            guard var transcript = try? loadTranscript() else {
                throw SpeakerEditError.noTranscript
            }
            guard !transcript.isNewerThanThisApp else {
                throw FolderError.newerFileFormat
            }
            let original = transcript
            var speakers = metadata.speakers ?? [:]
            try change(&transcript, &speakers)
            // Names for speakers with no lines left would only confuse a later Identify Speakers.
            let present = Set(transcript.speakers + [Transcript.Speaker.me])
            speakers = speakers.filter { present.contains($0.key) && !$0.value.isEmpty }
            metadata.speakers = speakers.isEmpty ? nil : speakers
            followRenames(in: &metadata, present: present, mergedInto: mergedInto)

            if transcript != original {
                try MeetingMetadata.encoder.encode(transcript).write(to: transcriptJSON, options: .atomic)
            }
            try save(metadata)
            try saveReadableTranscript(transcript, for: metadata)
            return (transcript, metadata)
        }
    }
}
