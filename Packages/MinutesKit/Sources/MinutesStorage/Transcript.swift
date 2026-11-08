// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct TranscriptWord: Codable, Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = Self.rounded(start)
        self.end = Self.rounded(max(start, end))
    }

    /// Milliseconds are finer than any engine's timing, and keep the file readable.
    private static func rounded(_ seconds: Double) -> Double {
        (seconds * 1000).rounded() / 1000
    }
}

public struct TranscriptSegment: Codable, Equatable, Sendable {
    /// `me` or `others` for now. Telling people apart adds more, like `speaker-1`.
    public var speaker: String
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [TranscriptWord]

    /// Takes its times and text from the words, which must not be empty.
    public init(speaker: String, words: [TranscriptWord]) {
        self.speaker = speaker
        self.words = words
        start = words.first?.start ?? 0
        end = words.last?.end ?? 0
        text = words.map(\.text).joined(separator: " ")
    }
}

/// The contents of `transcript.json`.
public struct Transcript: Codable, Equatable, Sendable {
    public enum Speaker {
        // swiftlint:disable:next identifier_name
        public static let me = "me"
        public static let others = "others"
    }

    public static let currentSchemaVersion = 1

    public var schemaVersion = Transcript.currentSchemaVersion
    /// The engine that wrote it, like `apple` or `parakeet`.
    public var engine: String
    public var model: String
    public var createdAt: Date
    public var segments: [TranscriptSegment]

    public init(engine: String, model: String, createdAt: Date = Date(), segments: [TranscriptSegment]) {
        self.engine = engine
        self.model = model
        self.createdAt = createdAt
        self.segments = segments
    }

    public var isNewerThanThisApp: Bool {
        schemaVersion > Self.currentSchemaVersion
    }

    public static func displayName(forSpeaker speaker: String) -> String {
        switch speaker {
        case Speaker.me: "Me"
        case Speaker.others: "Others"
        default: speaker
        }
    }

    /// The readable version. Minutes regenerates `transcript.md` from this, so edits to that file don't last.
    public func markdown(title: String, startedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var lines = ["# \(title)", "", formatter.string(from: startedAt)]
        var lastSpeaker: String?
        for segment in segments {
            if segment.speaker != lastSpeaker {
                lines += ["", "**\(Self.displayName(forSpeaker: segment.speaker))** \(Self.clock(segment.start))"]
                lastSpeaker = segment.speaker
            }
            lines += ["", segment.text]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        let (hours, minutes, rest) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}
