// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import MinutesStorage
import Testing

private func makeLibrary() throws -> (MinutesLibrary, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MinutesTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (MinutesLibrary(root: root), root)
}

private func date(_ text: String) throws -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return try #require(formatter.date(from: text))
}

@Test func `folder names lead with the date and time`() throws {
    let name = try MinutesLibrary.folderName(startedAt: date("2026-11-05 09:30"), title: "Recording")
    #expect(name == "2026-11-05 0930 Recording")
}

@Test(arguments: [
    ("Q3/Q4: plan", "Q3 Q4 plan"),
    ("  spaced   out  ", "spaced out"),
    ("...hidden", "hidden"),
    ("trailing dots...", "trailing dots"),
    ("a\u{0}b\nc", "a b c"),
    ("/:*?", "Untitled"),
    ("", "Untitled"),
    ("Réunion 会議 🎉", "Réunion 会議 🎉"),
])
func `titles become safe names`(title: String, expected: String) {
    #expect(MinutesLibrary.safeName(title) == expected)
}

@Test func `very long titles are limited`() {
    #expect(MinutesLibrary.safeName(String(repeating: "x", count: 500)).count == 100)
}

@Test func `creating a meeting makes its audio folder`() throws {
    let (library, root) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }

    let folder = try library.createMeetingFolder(startedAt: date("2026-11-05 09:30"), title: "Recording")
    #expect(folder.url.lastPathComponent == "2026-11-05 0930 Recording")
    #expect(FileManager.default.fileExists(atPath: folder.audioFolder.path))
}

@Test func `a second meeting in the same minute gets its own folder`() throws {
    let (library, root) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let start = try date("2026-11-05 09:30")

    let first = try library.createMeetingFolder(startedAt: start, title: "Recording")
    let second = try library.createMeetingFolder(startedAt: start, title: "Recording")
    let third = try library.createMeetingFolder(startedAt: start, title: "Recording")
    #expect(first != second)
    #expect(second.url.lastPathComponent == "2026-11-05 0930 Recording 2")
    #expect(third.url.lastPathComponent == "2026-11-05 0930 Recording 3")
}

@Test func `metadata survives a round trip`() throws {
    let (library, root) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let start = try date("2026-11-05 09:30")
    let folder = try library.createMeetingFolder(startedAt: start, title: "Recording")

    var metadata = MeetingMetadata(
        title: "Recording",
        startedAt: start,
        audioFormat: "aac",
        voiceProcessing: false,
        inputDeviceName: "AirPods",
        outputDeviceName: "AirPods",
    )
    metadata.durationSeconds = 12.5
    metadata.state = .encoding
    metadata.mic = .init(startOffsetSeconds: 0.05, gaps: [.init(startSeconds: 1, durationSeconds: 2)])
    metadata.system = .init(failure: "denied")

    try folder.save(metadata)
    #expect(try folder.loadMetadata() == metadata)
}

@Test func `meeting.json is readable by a person`() throws {
    let (library, root) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try library.createMeetingFolder(startedAt: date("2026-11-05 09:30"), title: "Recording")
    try folder.save(MeetingMetadata(
        title: "Recording",
        startedAt: date("2026-11-05 09:30"),
        audioFormat: "aac",
        voiceProcessing: false,
    ))

    let text = try String(contentsOf: folder.metadataURL, encoding: .utf8)
    #expect(text.contains("\n"))
    #expect(text.contains("\"schemaVersion\" : \(MeetingMetadata.currentSchemaVersion)"))
    #expect(text.contains("\"state\" : \"recording\""))
}

@Test func `saving replaces the file and leaves no temporary behind`() throws {
    let (library, root) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try library.createMeetingFolder(startedAt: date("2026-11-05 09:30"), title: "Recording")
    var metadata = try MeetingMetadata(
        title: "Recording",
        startedAt: date("2026-11-05 09:30"),
        audioFormat: "aac",
        voiceProcessing: false,
    )
    try folder.save(metadata)
    metadata.state = .complete
    try folder.save(metadata)

    #expect(try folder.loadMetadata().state == .complete)
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted()
    #expect(names == ["audio", "meeting.json"])
}

@Test func `unfinished meetings are found, oldest first, and finished ones aren't`() throws {
    let (library, root) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }

    func add(_ time: String, _ state: MeetingMetadata.State) throws {
        let start = try date(time)
        let folder = try library.createMeetingFolder(startedAt: start, title: "Recording")
        try folder.save(MeetingMetadata(
            title: "Recording",
            startedAt: start,
            state: state,
            audioFormat: "aac",
            voiceProcessing: false,
        ))
    }
    try add("2026-11-05 11:00", .recording)
    try add("2026-11-05 09:00", .encoding)
    try add("2026-11-05 10:00", .complete)

    let found = library.unfinishedMeetings()
    #expect(found.map(\.metadata.state) == [.encoding, .recording])
}

@Test func `folders that aren't meetings are ignored`() throws {
    let (library, root) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let stray = library.meetingsFolder.appendingPathComponent("Holiday photos")
    try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: stray.appendingPathComponent("meeting.json"))

    #expect(library.unfinishedMeetings().isEmpty)
}

@Test func `a missing library has nothing unfinished`() {
    let library = MinutesLibrary(root: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"))
    #expect(library.unfinishedMeetings().isEmpty)
}
