// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

/// A meeting's notes as typed, with the time each line was written.
public struct MeetingNotes: Equatable, Sendable {
    public var text: String
    /// One per line of `text`, in seconds since the recording started. Nil for lines written
    /// after the meeting, or changed outside Minutes.
    public var times: [Double?]
    /// Where `notes-cleaned.md` came from, when there is one.
    public var cleaned: NoteTimes.Cleaned?

    public init(text: String = "", times: [Double?]? = nil, cleaned: NoteTimes.Cleaned? = nil) {
        self.text = text
        self.times = times ?? Array(repeating: nil, count: NoteTimeline.lines(of: text).count)
        self.cleaned = cleaned
    }

    public var lines: [String] {
        NoteTimeline.lines(of: text)
    }

    /// Whether there's anything written, not counting blank lines.
    public var hasText: Bool {
        !text.allSatisfy(\.isWhitespace)
    }
}

/// The contents of `notes.json`. It holds a fingerprint of each line rather than its text, so a
/// line deleted from `notes.md` in another editor isn't kept here.
public struct NoteTimes: Codable, Equatable, Sendable {
    public struct Line: Codable, Equatable, Sendable {
        public var seconds: Double?
        public var fingerprint: String
    }

    public struct Cleaned: Codable, Equatable, Sendable {
        /// The model that wrote `notes-cleaned.md`, as a `ModelChoice` storage ID.
        public var model: String
        public var createdAt: Date

        public init(model: String, createdAt: Date) {
            self.model = model
            self.createdAt = createdAt
        }
    }

    public static let currentSchemaVersion = 1

    public var schemaVersion = NoteTimes.currentSchemaVersion
    /// Random for each meeting, so the same line doesn't give the same fingerprint in two meetings.
    public var salt: String
    public var lines: [Line]
    public var cleaned: Cleaned?

    static func fingerprint(_ line: String, salt: String) -> String {
        let digest = SHA256.hash(data: Data((salt + "\n" + line).utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    static func newSalt() -> String {
        Data((0 ..< 12).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
    }
}

public extension MeetingFolder {
    /// The notes as typed. Minutes only writes it when the user types.
    var notesFile: URL {
        url.appendingPathComponent("notes.md")
    }

    /// Line times and where the cleaned-up notes came from.
    var noteTimesFile: URL {
        url.appendingPathComponent("notes.json")
    }

    /// The cleanup the user accepted.
    var cleanedNotesFile: URL {
        url.appendingPathComponent("notes-cleaned.md")
    }

    /// The notes with their times, or empty notes when there are none.
    func loadNotes() -> MeetingNotes {
        let text = (try? String(contentsOf: notesFile, encoding: .utf8)) ?? ""
        let current = NoteTimeline.lines(of: text)
        guard let saved = loadNoteTimes() else {
            return MeetingNotes(text: text)
        }
        let currentPrints = current.map { NoteTimes.fingerprint($0, salt: saved.salt) }
        let times = NoteTimeline.align(
            saved: saved.lines.map(\.fingerprint),
            times: saved.lines.map(\.seconds),
            current: currentPrints,
        )
        return MeetingNotes(text: text, times: times, cleaned: saved.cleaned)
    }

    /// Writes `notes.md`, then `notes.json` when there's a time or a cleanup to keep. Empty notes
    /// don't create a file that isn't there.
    func saveNotes(_ notes: MeetingNotes) throws {
        let exists = FileManager.default.fileExists(atPath: notesFile.path)
        if exists || !notes.text.isEmpty {
            try Data(notes.text.utf8).write(to: notesFile, options: .atomic)
        }
        try saveNoteTimes(for: notes)
    }

    func loadCleanedNotes() -> String? {
        try? String(contentsOf: cleanedNotesFile, encoding: .utf8)
    }

    /// Writes `notes-cleaned.md` and records where it came from. A cleanup it replaces goes to
    /// `discard`, which moves it to the Trash, so edits made to it can be recovered.
    @discardableResult
    func saveCleanedNotes(
        _ text: String,
        model: String,
        at date: Date = Date(),
        discard: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
    ) throws -> MeetingNotes {
        if FileManager.default.fileExists(atPath: cleanedNotesFile.path) {
            try discard(cleanedNotesFile)
        }
        try Data((text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8)
            .write(to: cleanedNotesFile, options: .atomic)
        var notes = loadNotes()
        notes.cleaned = NoteTimes.Cleaned(model: model, createdAt: date)
        try saveNoteTimes(for: notes)
        return notes
    }

    internal func loadNoteTimes() -> NoteTimes? {
        guard let data = try? Data(contentsOf: noteTimesFile),
              let times = try? MeetingMetadata.decoder.decode(NoteTimes.self, from: data),
              times.schemaVersion <= NoteTimes.currentSchemaVersion
        else {
            return nil
        }
        return times
    }

    private func saveNoteTimes(for notes: MeetingNotes) throws {
        struct Version: Decodable {
            var schemaVersion: Int
        }
        // A newer Minutes wrote it, and would lose what this one doesn't know about.
        if let data = try? Data(contentsOf: noteTimesFile),
           let version = try? JSONDecoder().decode(Version.self, from: data),
           version.schemaVersion > NoteTimes.currentSchemaVersion
        {
            return
        }
        let hasTimes = notes.times.contains { $0 != nil }
        guard hasTimes || notes.cleaned != nil else {
            if FileManager.default.fileExists(atPath: noteTimesFile.path) {
                try FileManager.default.removeItem(at: noteTimesFile)
            }
            return
        }
        let salt = loadNoteTimes()?.salt ?? NoteTimes.newSalt()
        let lines = notes.lines.enumerated().map { index, line in
            NoteTimes.Line(
                seconds: index < notes.times.count ? notes.times[index] : nil,
                fingerprint: NoteTimes.fingerprint(line, salt: salt),
            )
        }
        let file = NoteTimes(salt: salt, lines: lines, cleaned: notes.cleaned)
        try MeetingMetadata.encoder.encode(file).write(to: noteTimesFile, options: .atomic)
    }
}
