// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct MeetingFolder: Equatable, Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var metadataURL: URL {
        url.appendingPathComponent("meeting.json")
    }

    public var audioFolder: URL {
        url.appendingPathComponent("audio", isDirectory: true)
    }

    public var micCAF: URL {
        audioFolder.appendingPathComponent("mic-raw.caf")
    }

    public var systemCAF: URL {
        audioFolder.appendingPathComponent("system.caf")
    }

    public var micAudio: URL {
        audioFolder.appendingPathComponent("mic-raw.m4a")
    }

    public var systemAudio: URL {
        audioFolder.appendingPathComponent("system.m4a")
    }

    /// The echo-cleaned mic track, once Milestone 3's pipeline has made one.
    public var cleanedMicAudio: URL {
        audioFolder.appendingPathComponent("mic.m4a")
    }

    /// The mic track to listen to: the cleaned one if it exists, otherwise the original.
    public var playbackMicAudio: URL {
        FileManager.default.fileExists(atPath: cleanedMicAudio.path) ? cleanedMicAudio : micAudio
    }

    public func loadMetadata() throws -> MeetingMetadata {
        try MeetingMetadata.decoder.decode(MeetingMetadata.self, from: Data(contentsOf: metadataURL))
    }

    /// Replaces the file in one step, so a crash leaves the old version or the new one.
    public func save(_ metadata: MeetingMetadata) throws {
        try MeetingMetadata.encoder.encode(metadata).write(to: metadataURL, options: .atomic)
    }
}
