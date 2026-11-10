// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The contents of `meeting.json`.
public struct MeetingMetadata: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// Audio is being captured, or capture was cut off by a crash.
        case recording
        /// Capture finished, and the CAF files still need encoding.
        case encoding
        case complete
    }

    public struct Track: Codable, Equatable, Sendable {
        /// Where this track's first audio sits, in seconds. Both tracks start at the same moment.
        public var startOffsetSeconds: Double?
        public var gaps: [Gap]
        public var failure: String?

        public init(startOffsetSeconds: Double? = nil, gaps: [Gap] = [], failure: String? = nil) {
            self.startOffsetSeconds = startOffsetSeconds
            self.gaps = gaps
            self.failure = failure
        }
    }

    public struct Gap: Codable, Equatable, Sendable {
        public var startSeconds: Double
        public var durationSeconds: Double

        public init(startSeconds: Double, durationSeconds: Double) {
            self.startSeconds = startSeconds
            self.durationSeconds = durationSeconds
        }
    }

    /// A name for one speaker in this meeting, keyed by the speaker's ID in `transcript.json`.
    public struct Speaker: Codable, Equatable, Sendable {
        public var name: String?
        /// The saved voice profile this speaker's name came from, or that their voice was added to.
        public var profile: UUID?
        /// A profile that sounds like this speaker, but not closely enough to apply its name.
        public var suggestion: Suggestion?
        /// Profiles the user said this speaker isn't, so they aren't suggested again.
        public var declinedProfiles: [UUID]?

        public init(name: String? = nil, profile: UUID? = nil, suggestion: Suggestion? = nil) {
            self.name = name
            self.profile = profile
            self.suggestion = suggestion
        }

        /// Holds nothing worth keeping in the file.
        public var isEmpty: Bool {
            name == nil && profile == nil && suggestion == nil && (declinedProfiles ?? []).isEmpty
        }
    }

    public struct Suggestion: Codable, Equatable, Sendable {
        public var name: String
        public var profile: UUID

        public init(name: String, profile: UUID) {
            self.name = name
            self.profile = profile
        }
    }

    /// 2 added `speakers`, and 3 added `summary`. An older app would drop them when saving, so it
    /// opens these read-only.
    public static let currentSchemaVersion = 3

    public var schemaVersion = MeetingMetadata.currentSchemaVersion
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var durationSeconds: Double?
    public var state: State
    /// `aac` or `alac`.
    public var audioFormat: String
    public var voiceProcessing: Bool
    /// Device names when recording began. Changes during the recording show up as gaps.
    public var inputDeviceName: String?
    public var outputDeviceName: String?
    public var mic: Track
    public var system: Track
    /// What's happened since Stop. `nil` for meetings recorded before there was anything to do.
    public var processing: ProcessingState?
    /// Names for the speakers in `transcript.json`. `nil` for meetings with nobody named.
    public var speakers: [String: Speaker]?
    /// The summary's state and where it came from. `nil` until one is wanted.
    public var summary: Summary?

    public init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date,
        state: State = .recording,
        audioFormat: String,
        voiceProcessing: Bool,
        inputDeviceName: String? = nil,
        outputDeviceName: String? = nil,
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.state = state
        self.audioFormat = audioFormat
        self.voiceProcessing = voiceProcessing
        self.inputDeviceName = inputDeviceName
        self.outputDeviceName = outputDeviceName
        mic = Track()
        system = Track()
    }

    /// Saving a file like this would drop fields this version doesn't know, so it's read-only.
    public var isNewerThanThisApp: Bool {
        schemaVersion > Self.currentSchemaVersion
    }

    /// The name to show: the one given in this meeting, or a label like "Speaker 2".
    public func displayName(forSpeaker speaker: String) -> String {
        speakers?[speaker]?.name ?? Transcript.displayName(forSpeaker: speaker)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
