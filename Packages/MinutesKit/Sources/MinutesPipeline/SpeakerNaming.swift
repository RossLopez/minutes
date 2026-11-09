// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesDiarization
import MinutesStorage
import os

/// Names and merges speakers in a finished meeting, and with speaker memory on, saves the voices
/// of the people named. Names and voices are never logged.
public struct SpeakerNaming: Sendable {
    public enum Outcome: Equatable, Sendable {
        case named
        /// Their voice was saved, so later meetings can name them.
        case remembered
        /// Under `minimumSpeech` seconds, too little to know the voice again.
        case notEnoughSpeech
        /// Speaker memory is on, but the diarizer's model isn't installed.
        case modelMissing
    }

    /// Less speech than this makes a voice profile that matches the wrong people.
    public static let minimumSpeech = 5.0

    private static let logger = Logger(subsystem: "io.github.rosslopez.minutes", category: "speakers")

    private let diarizer: @Sendable () -> (any SpeakerDiarizer)?
    private let profiles: SpeakerProfileStore
    private let remembersVoices: @Sendable () -> Bool

    public init(
        diarizer: @escaping @Sendable () -> (any SpeakerDiarizer)?,
        profiles: SpeakerProfileStore,
        remembersVoices: @escaping @Sendable () -> Bool,
    ) {
        self.diarizer = diarizer
        self.profiles = profiles
        self.remembersVoices = remembersVoices
    }

    /// Names a speaker, or with `nil` clears the name. A corrected name takes this meeting's
    /// sample off the profile it was wrongly saved to.
    @discardableResult
    public func name(_ speaker: String, in folder: MeetingFolder, to name: String?) async throws -> Outcome {
        let metadata = try folder.loadMetadata()
        guard metadata.processing?.status != .queued else {
            throw MeetingFolder.SpeakerEditError.meetingBusy
        }
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let previous = metadata.speakers?[speaker]
        if let profile = previous?.profile, profiles.profile(withID: profile)?.name.caseInsensitiveCompare(name ?? "")
            != .orderedSame
        {
            try profiles.removeSample(fromMeeting: metadata.id, profile: profile)
        }

        var outcome = Outcome.named
        var profileID: UUID?
        if let name, speaker != Transcript.Speaker.me, remembersVoices() {
            (outcome, profileID) = try await remember(speaker, as: name, in: folder, metadata: metadata)
        }
        try folder.nameSpeaker(speaker, name, profile: profileID)
        return outcome
    }

    /// Merges `speaker` into `target`. With memory on and `target` named, their voice is measured
    /// again from all their lines.
    public func merge(_ speaker: String, into target: String, in folder: MeetingFolder) async throws {
        let metadata = try folder.loadMetadata()
        let merged = metadata.speakers?[speaker]
        try folder.mergeSpeaker(speaker, into: target)
        let kept = try folder.loadMetadata().speakers?[target]
        if let profile = merged?.profile, profile != kept?.profile {
            try profiles.removeSample(fromMeeting: metadata.id, profile: profile)
        }
        if let name = kept?.name, remembersVoices() {
            try await self.name(target, in: folder, to: name)
        }
    }

    /// The stretches of a speaker's lines, joined across short pauses. Very short ones are left
    /// out, since a voice can't be measured from a word or two.
    public static func voiceSpans(of speaker: String, in transcript: Transcript) -> [ClosedRange<Double>] {
        var spans: [ClosedRange<Double>] = []
        for segment in transcript.segments.filter({ $0.speaker == speaker }).sorted(by: { $0.start < $1.start }) {
            if let last = spans.last, segment.start - last.upperBound < 0.5 {
                spans[spans.count - 1] = last.lowerBound ... max(last.upperBound, segment.end)
            } else {
                spans.append(segment.start ... max(segment.start, segment.end))
            }
        }
        return spans.filter { $0.upperBound - $0.lowerBound >= 0.5 }
    }

    private func remember(
        _ speaker: String,
        as name: String,
        in folder: MeetingFolder,
        metadata: MeetingMetadata,
    ) async throws -> (Outcome, UUID?) {
        guard let diarizer = diarizer(), await diarizer.modelStatus() == .installed,
              FileManager.default.fileExists(atPath: folder.systemAudio.path)
        else {
            return (.modelMissing, nil)
        }
        let spans = try Self.voiceSpans(of: speaker, in: folder.loadTranscript())
        let seconds = spans.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        guard seconds >= Self.minimumSpeech else {
            return (.notEnoughSpeech, nil)
        }
        // Inside the meeting's folder, so its audio never leaves it.
        let work = folder.url.appendingPathComponent(".voice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let started = ContinuousClock.now
        let embedding = try await diarizer.embedding(audio: folder.systemAudio, spans: spans, workFolder: work)
        let profile = try profiles.addSample(
            VoiceSample(meeting: metadata.id, recordedAt: metadata.startedAt, seconds: seconds, embedding: embedding),
            toProfileNamed: name,
        )
        Self.logger.info("Saved a voice sample in \(started.duration(to: .now), privacy: .public)")
        return (.remembered, profile.id)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
