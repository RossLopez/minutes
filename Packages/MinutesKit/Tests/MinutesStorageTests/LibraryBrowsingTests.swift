// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import MinutesStorage
import Testing

private func makeLibrary() throws -> MinutesLibrary {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MinutesTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return MinutesLibrary(root: root)
}

private func date(_ text: String) throws -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return try #require(formatter.date(from: text))
}

@discardableResult
private func addMeeting(
    to library: MinutesLibrary,
    at time: String,
    title: String = "Recording",
    state: MeetingMetadata.State = .complete,
) throws -> MeetingFolder {
    let start = try date(time)
    let folder = try library.createMeetingFolder(startedAt: start, title: title)
    try folder.save(MeetingMetadata(
        title: title,
        startedAt: start,
        state: state,
        audioFormat: "aac",
        voiceProcessing: false,
    ))
    return folder
}

// MARK: - Layout

@Test func `the layout creates every folder and is safe to repeat`() throws {
    let library = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: library.root) }

    try library.prepareLayout()
    try library.prepareLayout()

    for folder in [library.meetingsFolder, library.templatesFolder, library.modelsFolder, library.internalFolder] {
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }
    #expect(FileManager.default.fileExists(atPath: library.internalFolder.appendingPathComponent("logs").path))
}

@Test func `models and the index stay out of backups, and meetings don't`() throws {
    let library = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: library.root) }
    try library.prepareLayout()

    func excluded(_ url: URL) throws -> Bool {
        try #require(url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup)
    }
    #expect(try excluded(library.modelsFolder))
    #expect(try excluded(library.internalFolder))
    #expect(try !excluded(library.meetingsFolder))
    #expect(try !excluded(library.templatesFolder))
}

// MARK: - Listing

@Test func `meetings are listed newest first`() throws {
    let library = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: library.root) }
    try addMeeting(to: library, at: "2026-11-01 09:00", title: "Oldest")
    try addMeeting(to: library, at: "2026-11-05 09:00", title: "Newest")
    try addMeeting(to: library, at: "2026-11-03 09:00", title: "Middle")

    #expect(library.meetings().map(\.title) == ["Newest", "Middle", "Oldest"])
}

@Test func `a broken or missing meeting.json still shows, under its folder name`() throws {
    let library = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: library.root) }
    let broken = library.meetingsFolder.appendingPathComponent("Broken")
    let missing = library.meetingsFolder.appendingPathComponent("Missing")
    try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: broken.appendingPathComponent("meeting.json"))

    let entries = library.meetings()
    #expect(Set(entries.map(\.title)) == ["Broken", "Missing"])
    #expect(entries.allSatisfy { $0.metadata == nil && !$0.canRename })
}

@Test func `an unreadable meeting takes its title and date from the folder name`() throws {
    let library = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: library.root) }
    let name = MinutesLibrary.folderName(startedAt: Date(timeIntervalSince1970: 1_790_000_040), title: "Weekly Sync")
    try FileManager.default.createDirectory(
        at: library.meetingsFolder.appendingPathComponent(name),
        withIntermediateDirectories: true,
    )

    let entry = try #require(library.meetings().first)
    #expect(entry.title == "Weekly Sync")
    #expect(entry.date == Date(timeIntervalSince1970: 1_790_000_040))
}

@Test func `loose files and hidden folders aren't meetings`() throws {
    let library = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: library.root) }
    try FileManager.default.createDirectory(at: library.meetingsFolder, withIntermediateDirectories: true)
    try Data().write(to: library.meetingsFolder.appendingPathComponent(".DS_Store"))
    try Data().write(to: library.meetingsFolder.appendingPathComponent("notes.txt"))
    try FileManager.default.createDirectory(
        at: library.meetingsFolder.appendingPathComponent(".hidden"),
        withIntermediateDirectories: true,
    )

    #expect(library.meetings().isEmpty)
}

@Test func `a copied folder with the same ID is still its own entry`() throws {
    let library = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: library.root) }
    let folder = try addMeeting(to: library, at: "2026-11-05 09:00")
    try FileManager.default.copyItem(
        at: folder.url,
        to: library.meetingsFolder.appendingPathComponent("2026-11-05 0900 Recording copy"),
    )

    let entries = library.meetings()
    #expect(entries.count == 2)
    #expect(Set(entries.map(\.id)).count == 2)
    #expect(entries[0].metadata?.id == entries[1].metadata?.id)
}

@Test(arguments: [
    ("week", true),
    ("WEEKLY", true),
    ("  sync ", true),
    ("", true),
    ("   ", true),
    ("budget", false),
])
func `search matches titles`(search: String, expected: Bool) throws {
    let entry = try MeetingEntry(
        folder: MeetingFolder(url: URL(fileURLWithPath: "/tmp/x")),
        metadata: MeetingMetadata(
            title: "Weekly sync",
            startedAt: date("2026-11-05 09:00"),
            audioFormat: "aac",
            voiceProcessing: false,
        ),
        date: date("2026-11-05 09:00"),
    )
    #expect(entry.matches(search: search) == expected)
}

// MARK: - Rename

@Test func `renaming changes the title and the folder, keeping the date`() throws {
    let library = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: library.root) }
    let folder = try addMeeting(to: library, at: "2026-11-05 09:30")

    let renamed = try library.rename(folder, to: "  Weekly ISCM sync  ")

    #expect(renamed.url.lastPathComponent == "2026-11-05 0930 Weekly ISCM sync")
    #expect(try renamed.loadMetadata().title == "Weekly ISCM sync")
    #expect(!FileManager.default.fileExists(atPath: folder.url.path))
}

@Test func `the title keeps characters the folder name can't`() throws {
    let library = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: library.root) }
    let folder = try addMeeting(to: library, at: "2026-11-05 09:30")

    let renamed = try library.rename(folder, to: "Q3/Q4: plan")

    #expect(renamed.url.lastPathComponent == "2026-11-05 0930 Q3 Q4 plan")
    #expect(try renamed.loadMetadata().title == "Q3/Q4: plan")
}

@Test func `renaming to a taken name adds a number`() throws {
    let library = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: library.root) }
    try addMeeting(to: library, at: "2026-11-05 09:30", title: "Sync")
    let other = try addMeeting(to: library, at: "2026-11-05 09:30", title: "Other")

    let renamed = try library.rename(other, to: "Sync")

    #expect(renamed.url.lastPathComponent == "2026-11-05 0930 Sync 2")
    #expect(try renamed.loadMetadata().title == "Sync")
}

@Test func `changing only the case renames the folder too`() throws {
    let library = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: library.root) }
    let folder = try addMeeting(to: library, at: "2026-11-05 09:30", title: "weekly sync")

    let renamed = try library.rename(folder, to: "Weekly Sync")

    let names = try FileManager.default.contentsOfDirectory(atPath: library.meetingsFolder.path)
    #expect(names == ["2026-11-05 0930 Weekly Sync"])
    #expect(try renamed.loadMetadata().title == "Weekly Sync")
}

@Test func `renaming to the same title changes nothing`() throws {
    let library = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: library.root) }
    let folder = try addMeeting(to: library, at: "2026-11-05 09:30", title: "Sync")

    let renamed = try library.rename(folder, to: "Sync")

    #expect(renamed.url.lastPathComponent == folder.url.lastPathComponent)
    #expect(try FileManager.default.contentsOfDirectory(atPath: library.meetingsFolder.path).count == 1)
}

@Test func `a folder without a date prefix gets one from the meeting`() throws {
    let library = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: library.root) }
    let folder = try addMeeting(to: library, at: "2026-11-05 09:30", title: "Sync")
    let moved = library.meetingsFolder.appendingPathComponent("Renamed in Finder")
    try FileManager.default.moveItem(at: folder.url, to: moved)

    let renamed = try library.rename(MeetingFolder(url: moved), to: "Planning")

    #expect(renamed.url.lastPathComponent == "2026-11-05 0930 Planning")
}

@Test func `a folder keeps its date prefix even if the time zone moved`() throws {
    let library = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: library.root) }
    let folder = try addMeeting(to: library, at: "2026-11-05 09:30", title: "Sync")
    let moved = library.meetingsFolder.appendingPathComponent("2026-11-05 0630 Sync")
    try FileManager.default.moveItem(at: folder.url, to: moved)

    let renamed = try library.rename(MeetingFolder(url: moved), to: "Planning")

    #expect(renamed.url.lastPathComponent == "2026-11-05 0630 Planning")
}

@Test func `an empty title is refused`() throws {
    let library = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: library.root) }
    let folder = try addMeeting(to: library, at: "2026-11-05 09:30")

    #expect(throws: MinutesLibrary.LibraryError.emptyTitle) {
        try library.rename(folder, to: "   ")
    }
}

@Test(arguments: [MeetingMetadata.State.recording, .encoding])
func `meetings still being written can't be renamed`(state: MeetingMetadata.State) throws {
    let library = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: library.root) }
    let folder = try addMeeting(to: library, at: "2026-11-05 09:30", state: state)

    #expect(throws: MinutesLibrary.LibraryError.meetingNotFinished) {
        try library.rename(folder, to: "New")
    }
    #expect(FileManager.default.fileExists(atPath: folder.url.path))
}

@Test func `an unreadable meeting can't be renamed`() throws {
    let library = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: library.root) }
    let folder = MeetingFolder(url: library.meetingsFolder.appendingPathComponent("Broken"))
    try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)

    #expect(throws: MinutesLibrary.LibraryError.unreadableMetadata) {
        try library.rename(folder, to: "New")
    }
}

// MARK: - Newer files

/// A `meeting.json` written by a future version, with a field this version doesn't know.
private func addNewerMeeting(to library: MinutesLibrary, state: String = "complete") throws -> MeetingFolder {
    let folder = try addMeeting(to: library, at: "2026-11-05 09:30")
    var object = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: folder.metadataURL)) as? [String: Any],
    )
    object["schemaVersion"] = MeetingMetadata.currentSchemaVersion + 1
    object["futureField"] = "keep me"
    object["state"] = state
    try JSONSerialization.data(withJSONObject: object).write(to: folder.metadataURL)
    return folder
}

@Test func `a file from a newer version is listed but not rewritten by a rename`() throws {
    let library = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: library.root) }
    let folder = try addNewerMeeting(to: library)
    let before = try Data(contentsOf: folder.metadataURL)

    let entry = try #require(library.meetings().first)
    #expect(entry.metadata != nil)
    #expect(!entry.canRename)
    #expect(throws: MinutesLibrary.LibraryError.newerFileFormat) {
        try library.rename(folder, to: "New")
    }
    #expect(try Data(contentsOf: folder.metadataURL) == before)
}

@Test func `an unfinished meeting from a newer version isn't picked up for recovery`() throws {
    let library = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: library.root) }
    _ = try addNewerMeeting(to: library, state: "encoding")

    #expect(library.unfinishedMeetings().isEmpty)
}

// MARK: - Trash

@Test func `moving to the Trash removes the folder from the library and keeps its files`() throws {
    let library = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: library.root) }
    let folder = try addMeeting(to: library, at: "2026-11-05 09:30")

    let trashed = try #require(try library.moveToTrash(folder))
    defer { try? FileManager.default.removeItem(at: trashed) }

    #expect(library.meetings().isEmpty)
    #expect(FileManager.default.fileExists(atPath: trashed.appendingPathComponent("meeting.json").path))
}

// MARK: - Playback track

@Test func `playback uses the cleaned mic once it exists`() throws {
    let library = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: library.root) }
    let folder = try addMeeting(to: library, at: "2026-11-05 09:30")

    #expect(folder.playbackMicAudio == folder.micAudio)
    try Data().write(to: folder.cleanedMicAudio)
    #expect(folder.playbackMicAudio == folder.cleanedMicAudio)
}
