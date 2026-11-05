// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The contents of `meeting.json`. Later milestones add speakers, templates and pipeline state.
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

    public var schemaVersion = 1
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
