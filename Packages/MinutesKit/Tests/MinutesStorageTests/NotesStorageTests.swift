// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import MinutesStorage
import Testing

private func makeFolder() throws -> MeetingFolder {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MinutesTests-\(UUID().uuidString)")
    let library = MinutesLibrary(root: root)
    try FileManager.default.createDirectory(at: library.meetingsFolder, withIntermediateDirectories: true)
    return try library.createMeetingFolder(startedAt: Date(timeIntervalSince1970: 1_800_000_000), title: "Sync")
}

// MARK: - Times while typing

@Test func `lines keep a trailing empty line and drop carriage returns`() {
    #expect(NoteTimeline.lines(of: "") == [""])
    #expect(NoteTimeline.lines(of: "a\r\nb\n") == ["a", "b", ""])
}

@Test func `typing inside a line keeps its time`() {
    let times = NoteTimeline.update(old: ["budget", "remote"], new: ["budget friday", "remote"],
                                    times: [10, 20], now: 99)
    #expect(times == [10, 20])
}

@Test func `a new line takes the time it first gets text`() {
    var times = NoteTimeline.update(old: ["budget"], new: ["budget", ""], times: [10], now: 30)
    #expect(times == [10, nil])
    times = NoteTimeline.update(old: ["budget", ""], new: ["budget", "r"], times: times, now: 31)
    #expect(times == [10, 31])
    times = NoteTimeline.update(old: ["budget", "r"], new: ["budget", "remote"], times: times, now: 40)
    #expect(times == [10, 31])
}

@Test func `lines written after the meeting have no time`() {
    let times = NoteTimeline.update(old: ["budget"], new: ["budget", "later"], times: [10], now: nil)
    #expect(times == [10, nil])
}

@Test func `inserting above keeps the times of the lines below`() {
    let times = NoteTimeline.update(old: ["a", "b"], new: ["new", "a", "b"], times: [1, 2], now: 50)
    #expect(times == [50, 1, 2])
}

@Test func `deleting a line drops its time`() {
    let times = NoteTimeline.update(old: ["a", "b", "c"], new: ["a", "c"], times: [1, 2, 3], now: 50)
    #expect(times == [1, 3])
}

@Test func `splitting a line keeps the time on its first half`() {
    let times = NoteTimeline.update(old: ["one two"], new: ["one", "two"], times: [5], now: 9)
    #expect(times == [5, 9])
}

@Test func `pasting several lines times each one`() {
    let times = NoteTimeline.update(old: [""], new: ["a", "", "b"], times: [nil], now: 7)
    #expect(times == [7, nil, 7])
}

// MARK: - Files

@Test func `notes and their times are saved and read back`() throws {
    let folder = try makeFolder()
    try folder.saveNotes(MeetingNotes(text: "budget\n\nremote", times: [12.5, nil, 30]))
    #expect(try String(contentsOf: folder.notesFile, encoding: .utf8) == "budget\n\nremote")
    let loaded = folder.loadNotes()
    #expect(loaded.text == "budget\n\nremote")
    #expect(loaded.times == [12.5, nil, 30])
}

@Test func `notes.json holds fingerprints, not text`() throws {
    let folder = try makeFolder()
    try folder.saveNotes(MeetingNotes(text: "the secret plan", times: [3]))
    let json = try String(contentsOf: folder.noteTimesFile, encoding: .utf8)
    #expect(!json.contains("secret"))
    #expect(json.contains("fingerprint"))
}

@Test func `notes without times or a cleanup write no notes.json`() throws {
    let folder = try makeFolder()
    try folder.saveNotes(MeetingNotes(text: "later", times: [nil]))
    #expect(FileManager.default.fileExists(atPath: folder.notesFile.path))
    #expect(!FileManager.default.fileExists(atPath: folder.noteTimesFile.path))
}

@Test func `empty notes create no files`() throws {
    let folder = try makeFolder()
    try folder.saveNotes(MeetingNotes())
    #expect(!FileManager.default.fileExists(atPath: folder.notesFile.path))
    #expect(folder.loadNotes() == MeetingNotes(text: "", times: [nil]))
}

@Test func `clearing notes that were saved leaves an empty file`() throws {
    let folder = try makeFolder()
    try folder.saveNotes(MeetingNotes(text: "a", times: [1]))
    try folder.saveNotes(MeetingNotes(text: "", times: [nil]))
    #expect(try String(contentsOf: folder.notesFile, encoding: .utf8) == "")
    #expect(!FileManager.default.fileExists(atPath: folder.noteTimesFile.path))
}

@Test func `an edit in another app keeps the times of unchanged lines`() throws {
    let folder = try makeFolder()
    try folder.saveNotes(MeetingNotes(text: "one\ntwo\nthree", times: [1, 2, 3]))
    try Data("zero\none\nTWO\nthree\n".utf8).write(to: folder.notesFile)
    let loaded = folder.loadNotes()
    #expect(loaded.times == [nil, 1, nil, 3, nil])
}

@Test func `fingerprints differ between meetings`() throws {
    let first = try makeFolder()
    let second = try makeFolder()
    try first.saveNotes(MeetingNotes(text: "same", times: [1]))
    try second.saveNotes(MeetingNotes(text: "same", times: [1]))
    let prints = try [first, second].map { try #require($0.loadNoteTimes()?.lines.first?.fingerprint) }
    #expect(prints[0] != prints[1])
}

@Test func `a notes.json from a newer Minutes is left alone`() throws {
    let folder = try makeFolder()
    let newer = #"{"schemaVersion": 9, "salt": "x", "lines": [], "future": true}"#
    try Data(newer.utf8).write(to: folder.noteTimesFile)
    try folder.saveNotes(MeetingNotes(text: "a", times: [1]))
    #expect(try String(contentsOf: folder.noteTimesFile, encoding: .utf8) == newer)
    #expect(folder.loadNotes().times == [nil])
}

// MARK: - Cleaned-up notes

@Test func `a cleanup is saved with where it came from`() throws {
    let folder = try makeFolder()
    try folder.saveNotes(MeetingNotes(text: "budget fri", times: [4]))
    let date = Date(timeIntervalSince1970: 1_800_000_900)
    try folder.saveCleanedNotes("## Budget\n- Due Friday\n\n", model: "builtin:e4b", at: date) { _ in }
    #expect(folder.loadCleanedNotes() == "## Budget\n- Due Friday\n")
    let loaded = folder.loadNotes()
    #expect(loaded.cleaned == NoteTimes.Cleaned(model: "builtin:e4b", createdAt: date))
    #expect(loaded.times == [4])
    #expect(loaded.text == "budget fri")
}

@Test func `a new cleanup sends the old one to be discarded`() throws {
    let folder = try makeFolder()
    try folder.saveNotes(MeetingNotes(text: "a"))
    let trash = folder.url.deletingLastPathComponent().appendingPathComponent("Trash-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    let discard: (URL) throws -> Void = { url in
        try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
    }
    try folder.saveCleanedNotes("First", model: "m", discard: discard)
    try folder.saveCleanedNotes("Second", model: "m", discard: discard)
    #expect(folder.loadCleanedNotes() == "Second\n")
    let old = try String(contentsOf: trash.appendingPathComponent("notes-cleaned.md"), encoding: .utf8)
    #expect(old == "First\n")
}

@Test func `saving notes keeps the cleanup's record`() throws {
    let folder = try makeFolder()
    try folder.saveNotes(MeetingNotes(text: "a"))
    let notes = try folder.saveCleanedNotes("Clean", model: "m") { _ in }
    var edited = notes
    edited.text = "a\nb"
    edited.times = [nil, nil]
    try folder.saveNotes(edited)
    #expect(folder.loadNotes().cleaned?.model == "m")
}
