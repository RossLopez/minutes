// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One meeting's measurement of a voice.
public struct VoiceSample: Codable, Equatable, Sendable {
    public var meeting: UUID
    /// When that meeting started, so the oldest samples go first.
    public var recordedAt: Date
    /// How much of their speech the embedding was measured from.
    public var seconds: Double
    public var embedding: [Float]

    public init(meeting: UUID, recordedAt: Date, seconds: Double, embedding: [Float]) {
        self.meeting = meeting
        self.recordedAt = recordedAt
        self.seconds = seconds
        self.embedding = embedding
    }
}

/// The contents of one `Speakers/<Name>.json`: a person's name and a few measurements of their
/// voice. This is biometric data about someone else, so it exists only with speaker memory on,
/// stays in the library, and is never logged.
public struct SpeakerProfile: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1
    /// One per meeting, newest kept, so a voice that changes over the years still matches.
    public static let maximumSamples = 10

    public var schemaVersion = SpeakerProfile.currentSchemaVersion
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var samples: [VoiceSample]

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), samples: [VoiceSample] = []) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        updatedAt = createdAt
        self.samples = samples
    }

    public var isNewerThanThisApp: Bool {
        schemaVersion > Self.currentSchemaVersion
    }

    public var lastHeard: Date? {
        samples.map(\.recordedAt).max()
    }
}

/// The `Speakers/` folder. Files are found by the ID inside them, so a file renamed by hand still
/// works. Files that can't be read, or are from a newer version, are left alone.
public struct SpeakerProfileStore: Sendable {
    public enum StoreError: Error, Equatable {
        case newerFileFormat
        case emptyName
    }

    /// Held while changing a profile, so two changes can't overwrite each other.
    private static let lock = NSLock()

    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    /// Every profile that can be read, by name.
    public func profiles() -> [SpeakerProfile] {
        files().map(\.profile).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func profile(withID id: UUID) -> SpeakerProfile? {
        files().first { $0.profile.id == id }?.profile
    }

    /// Adds a meeting's measurement to the profile with this name, making one if there isn't one.
    /// A second sample from the same meeting replaces the first.
    @discardableResult
    public func addSample(_ sample: VoiceSample, toProfileNamed name: String, now: Date = Date()) throws
        -> SpeakerProfile
    {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw StoreError.emptyName
        }
        return try Self.lock.withLock {
            let existing = files().first { $0.profile.name.caseInsensitiveCompare(name) == .orderedSame }
            var profile = existing?.profile ?? SpeakerProfile(name: name, createdAt: now)
            guard !profile.isNewerThanThisApp else {
                throw StoreError.newerFileFormat
            }
            profile.samples.removeAll { $0.meeting == sample.meeting }
            profile.samples.append(sample)
            profile.samples.sort { $0.recordedAt < $1.recordedAt }
            profile.samples = Array(profile.samples.suffix(SpeakerProfile.maximumSamples))
            profile.updatedAt = now
            try write(profile, to: existing?.url ?? newFileURL(for: name))
            return profile
        }
    }

    /// Takes a meeting's sample out of a profile, after the user said the name was wrong. A
    /// profile left with no samples is deleted, since it can't match anyone.
    public func removeSample(fromMeeting meeting: UUID, profile id: UUID) throws {
        try Self.lock.withLock {
            guard let file = files().first(where: { $0.profile.id == id }) else {
                return
            }
            var profile = file.profile
            guard !profile.isNewerThanThisApp else {
                throw StoreError.newerFileFormat
            }
            profile.samples.removeAll { $0.meeting == meeting }
            if profile.samples.isEmpty {
                try FileManager.default.removeItem(at: file.url)
            } else {
                try write(profile, to: file.url)
            }
        }
    }

    public func delete(_ id: UUID) throws {
        try Self.lock.withLock {
            for file in files() where file.profile.id == id {
                try FileManager.default.removeItem(at: file.url)
            }
        }
    }

    /// Deletes every profile this version can read. Anything else in the folder stays.
    public func deleteAll() throws {
        try Self.lock.withLock {
            for file in files() {
                try FileManager.default.removeItem(at: file.url)
            }
        }
    }

    private func files() -> [(url: URL, profile: SpeakerProfile)] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles],
        )) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let profile = try? MeetingMetadata.decoder.decode(SpeakerProfile.self, from: data)
            else {
                return nil
            }
            return (url, profile)
        }
    }

    /// `Dana.json`, or `Dana 2.json` if something else already has that name.
    private func newFileURL(for name: String) throws -> URL {
        let base = MinutesLibrary.safeName(name)
        for attempt in 1 ... 1000 {
            let url = folder.appendingPathComponent(attempt == 1 ? "\(base).json" : "\(base) \(attempt).json")
            if !FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    private func write(_ profile: SpeakerProfile, to url: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try MeetingMetadata.encoder.encode(profile).write(to: url, options: .atomic)
    }
}
