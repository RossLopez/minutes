// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct MeetingFolder: Equatable, Sendable {
    public enum FolderError: Error, Equatable {
        /// Saving through this version's model would drop fields it doesn't know.
        case newerFileFormat
    }

    /// Held while changing an existing `meeting.json`, so one change can't overwrite another.
    static let metadataLock = NSLock()

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

    public var transcriptJSON: URL {
        url.appendingPathComponent("transcript.json")
    }

    public var transcriptMarkdown: URL {
        url.appendingPathComponent("transcript.md")
    }

    /// Work in progress after a recording stops. Hidden, and it moves with the folder on a rename.
    public var processingFolder: URL {
        url.appendingPathComponent(".processing", isDirectory: true)
    }

    public func loadTranscript() throws -> Transcript {
        try MeetingMetadata.decoder.decode(Transcript.self, from: Data(contentsOf: transcriptJSON))
    }

    /// Replaces both transcript files, each in one step, with names from `metadata`.
    /// `transcript.json` goes last, so its presence means the readable file is up to date as well.
    public func save(_ transcript: Transcript, for metadata: MeetingMetadata) throws {
        try saveReadableTranscript(transcript, for: metadata)
        try MeetingMetadata.encoder.encode(transcript).write(to: transcriptJSON, options: .atomic)
    }

    /// Rewrites `transcript.md`, after a change of title or names.
    public func saveReadableTranscript(_ transcript: Transcript, for metadata: MeetingMetadata) throws {
        let readable = transcript.markdown(
            title: metadata.title,
            startedAt: metadata.startedAt,
            name: metadata.displayName(forSpeaker:),
        )
        try Data(readable.utf8).write(to: transcriptMarkdown, options: .atomic)
    }

    /// Loads, changes and saves `meeting.json`. Everything that changes an existing meeting's
    /// metadata from outside the recording goes through here or `MinutesLibrary.rename`.
    @discardableResult
    public func updateMetadata(_ change: (inout MeetingMetadata) -> Void) throws -> MeetingMetadata {
        try Self.metadataLock.withLock {
            var metadata = try loadMetadata()
            guard !metadata.isNewerThanThisApp else {
                throw FolderError.newerFileFormat
            }
            change(&metadata)
            try save(metadata)
            return metadata
        }
    }

    public func loadMetadata() throws -> MeetingMetadata {
        try MeetingMetadata.decoder.decode(MeetingMetadata.self, from: Data(contentsOf: metadataURL))
    }

    /// Replaces the file in one step, so a crash leaves the old version or the new one.
    /// An older file is written as the current version, since it now holds this version's fields.
    public func save(_ metadata: MeetingMetadata) throws {
        var metadata = metadata
        metadata.schemaVersion = max(metadata.schemaVersion, MeetingMetadata.currentSchemaVersion)
        try MeetingMetadata.encoder.encode(metadata).write(to: metadataURL, options: .atomic)
    }
}
