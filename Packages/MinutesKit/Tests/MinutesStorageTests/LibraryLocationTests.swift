// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import MinutesStorage
import Testing

private func makeFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinutesTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private struct MoveFixture {
    let base: URL
    let root: URL
    let parent: URL
}

/// A library at `<base>/old/Minutes` holding one file, with an empty `<base>/new` to move to.
private func makeMove() throws -> MoveFixture {
    let base = try makeFolder()
    let root = base.appendingPathComponent("old/Minutes", isDirectory: true)
    let parent = base.appendingPathComponent("new", isDirectory: true)
    let meeting = root.appendingPathComponent("Meetings/2026-11-05 0930 Sync", isDirectory: true)
    try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: meeting.appendingPathComponent("meeting.json"))
    return MoveFixture(base: base, root: root, parent: parent)
}

private func copying(
    verify: @escaping (URL, URL) throws -> Void = LibraryMover.verifyCopy,
    disposed: @escaping (URL) -> Bool = { _ in true },
) -> LibraryMover.Operations {
    LibraryMover.Operations(sameVolume: { _, _ in false }, verify: verify, disposeOfOriginal: disposed)
}

// MARK: - Pointer

@Test func `with no pointer file the library is at the default`() throws {
    let base = try makeFolder()
    defer { try? FileManager.default.removeItem(at: base) }
    let pointer = LibraryPointer(file: base.appendingPathComponent("library.json"))
    let defaultRoot = base.appendingPathComponent("Default")

    #expect(pointer.chosenRoot == nil)
    #expect(pointer.root(default: defaultRoot) == defaultRoot)
    #expect(pointer.status(default: defaultRoot) == .ready)
}

@Test func `a chosen location persists in a readable file`() throws {
    let base = try makeFolder()
    defer { try? FileManager.default.removeItem(at: base) }
    let file = base.appendingPathComponent("nested/library.json")
    let chosen = base.appendingPathComponent("Chosen", isDirectory: true)
    try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)

    try LibraryPointer(file: file).setRoot(chosen)

    let reread = LibraryPointer(file: file)
    #expect(reread.chosenRoot?.path == chosen.standardizedFileURL.path)
    #expect(reread.status() == .ready)
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.contains("rootPath"))
}

@Test func `a chosen location that's gone is reported and not created`() throws {
    let base = try makeFolder()
    defer { try? FileManager.default.removeItem(at: base) }
    let pointer = LibraryPointer(file: base.appendingPathComponent("library.json"))
    let chosen = base.appendingPathComponent("Unplugged/Minutes", isDirectory: true)

    try pointer.setRoot(chosen)

    guard case let .missing(url) = pointer.status() else {
        Issue.record("Expected missing")
        return
    }
    #expect(url.path == chosen.standardizedFileURL.path)
    #expect(!FileManager.default.fileExists(atPath: chosen.path))
}

@Test func `a file where the folder should be counts as missing`() throws {
    let base = try makeFolder()
    defer { try? FileManager.default.removeItem(at: base) }
    let pointer = LibraryPointer(file: base.appendingPathComponent("library.json"))
    let chosen = base.appendingPathComponent("NotAFolder")
    try Data().write(to: chosen)

    try pointer.setRoot(chosen)

    #expect(pointer.status() != .ready)
}

@Test func `clearing goes back to the default`() throws {
    let base = try makeFolder()
    defer { try? FileManager.default.removeItem(at: base) }
    let pointer = LibraryPointer(file: base.appendingPathComponent("library.json"))
    try pointer.setRoot(base)

    try pointer.clear()
    try pointer.clear()

    #expect(pointer.chosenRoot == nil)
}

@Test func `a damaged pointer file falls back to the default`() throws {
    let base = try makeFolder()
    defer { try? FileManager.default.removeItem(at: base) }
    let file = base.appendingPathComponent("library.json")
    try Data("not json".utf8).write(to: file)

    #expect(LibraryPointer(file: file).chosenRoot == nil)
}

// MARK: - Where a library can move

@Test func `a library can't move inside itself`() throws {
    let fixture = try makeMove()
    let (base, root) = (fixture.base, fixture.root)
    defer { try? FileManager.default.removeItem(at: base) }

    #expect(throws: LibraryMover.MoveError.insideCurrentLibrary) {
        try LibraryMover.validate(from: root, toParent: root.appendingPathComponent("Meetings"))
    }
    #expect(throws: LibraryMover.MoveError.insideCurrentLibrary) {
        try LibraryMover.validate(from: root, toParent: root)
    }
}

@Test(arguments: ["Documents", "Documents/Work", "Library/Mobile Documents/com~apple~CloudDocs"])
func `a library can't move into folders that sync to iCloud`(path: String) throws {
    let fixture = try makeMove()
    let (base, root) = (fixture.base, fixture.root)
    defer { try? FileManager.default.removeItem(at: base) }
    let home = base.appendingPathComponent("home", isDirectory: true)
    let target = home.appendingPathComponent(path, isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

    #expect(throws: LibraryMover.MoveError.syncedFolder) {
        try LibraryMover.validate(from: root, toParent: target, home: home)
    }
}

@Test func `a library won't overwrite an existing folder`() throws {
    let fixture = try makeMove()
    let (base, root, parent) = (fixture.base, fixture.root, fixture.parent)
    defer { try? FileManager.default.removeItem(at: base) }
    let taken = parent.appendingPathComponent("Minutes", isDirectory: true)
    try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)

    #expect(throws: LibraryMover.MoveError.alreadyExists(taken)) {
        try LibraryMover.validate(from: root, toParent: parent)
    }
}

@Test func `a similarly named sibling isn't inside the library`() throws {
    let fixture = try makeMove()
    let (base, root) = (fixture.base, fixture.root)
    defer { try? FileManager.default.removeItem(at: base) }
    let sibling = root.deletingLastPathComponent().appendingPathComponent("Minutes Archive", isDirectory: true)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

    #expect(throws: Never.self) {
        try LibraryMover.validate(from: root, toParent: sibling)
    }
}

// MARK: - Moving

private func meetingFile(in root: URL) -> URL {
    root.appendingPathComponent("Meetings/2026-11-05 0930 Sync/meeting.json")
}

@Test func `moving on one volume renames the library and commits`() throws {
    let fixture = try makeMove()
    let (base, root, parent) = (fixture.base, fixture.root, fixture.parent)
    defer { try? FileManager.default.removeItem(at: base) }
    var committed: URL?

    let result = try LibraryMover.move(from: root, toParent: parent) { committed = $0 }

    #expect(result.newRoot == parent.appendingPathComponent("Minutes", isDirectory: true))
    #expect(result.removedOldFolder)
    #expect(committed == result.newRoot)
    #expect(FileManager.default.fileExists(atPath: meetingFile(in: result.newRoot).path))
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test func `a failed commit on one volume puts the library back`() throws {
    let fixture = try makeMove()
    let (base, root, parent) = (fixture.base, fixture.root, fixture.parent)
    defer { try? FileManager.default.removeItem(at: base) }

    #expect(throws: CocoaError.self) {
        try LibraryMover.move(from: root, toParent: parent) { _ in throw CocoaError(.fileWriteUnknown) }
    }
    #expect(FileManager.default.fileExists(atPath: meetingFile(in: root).path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
}

@Test func `moving across volumes copies, commits and only then disposes of the original`() throws {
    let fixture = try makeMove()
    let (base, root, parent) = (fixture.base, fixture.root, fixture.parent)
    defer { try? FileManager.default.removeItem(at: base) }
    var committedFirst = false
    let operations = copying(disposed: { _ in
        // The original must still be whole when this runs.
        #expect(committedFirst)
        #expect(FileManager.default.fileExists(atPath: meetingFile(in: root).path))
        return true
    })

    let result = try LibraryMover.move(
        from: root,
        toParent: parent,
        commit: { _ in committedFirst = true },
        operations: operations,
    )

    #expect(result.removedOldFolder)
    #expect(FileManager.default.fileExists(atPath: meetingFile(in: result.newRoot).path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["Minutes"])
}

@Test func `a failed check keeps the original and removes the copy`() throws {
    let fixture = try makeMove()
    let (base, root, parent) = (fixture.base, fixture.root, fixture.parent)
    defer { try? FileManager.default.removeItem(at: base) }
    var committed = false

    #expect(throws: LibraryMover.MoveError.verificationFailed) {
        try LibraryMover.move(
            from: root,
            toParent: parent,
            commit: { _ in committed = true },
            operations: copying(verify: { _, _ in throw LibraryMover.MoveError.verificationFailed }),
        )
    }
    #expect(!committed)
    #expect(FileManager.default.fileExists(atPath: meetingFile(in: root).path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
}

@Test func `a failed commit across volumes keeps the original and removes the copy`() throws {
    let fixture = try makeMove()
    let (base, root, parent) = (fixture.base, fixture.root, fixture.parent)
    defer { try? FileManager.default.removeItem(at: base) }

    #expect(throws: CocoaError.self) {
        try LibraryMover.move(
            from: root,
            toParent: parent,
            commit: { _ in throw CocoaError(.fileWriteUnknown) },
            operations: copying(disposed: { _ in
                Issue.record("The original must stay")
                return true
            }),
        )
    }
    #expect(FileManager.default.fileExists(atPath: meetingFile(in: root).path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
}

@Test func `an original that can't go to the Trash is reported`() throws {
    let fixture = try makeMove()
    let (base, root, parent) = (fixture.base, fixture.root, fixture.parent)
    defer { try? FileManager.default.removeItem(at: base) }

    let result = try LibraryMover.move(
        from: root,
        toParent: parent,
        commit: { _ in },
        operations: copying(disposed: { _ in false }),
    )

    #expect(!result.removedOldFolder)
    #expect(FileManager.default.fileExists(atPath: root.path))
}

// MARK: - Checking a copy

@Test func `an identical copy passes the check`() throws {
    let fixture = try makeMove()
    let (base, root, parent) = (fixture.base, fixture.root, fixture.parent)
    defer { try? FileManager.default.removeItem(at: base) }
    let copy = parent.appendingPathComponent("Copy")
    try FileManager.default.copyItem(at: root, to: copy)

    #expect(throws: Never.self) {
        try LibraryMover.verifyCopy(original: root, copy: copy)
    }
}

@Test func `a missing file fails the check`() throws {
    let fixture = try makeMove()
    let (base, root, parent) = (fixture.base, fixture.root, fixture.parent)
    defer { try? FileManager.default.removeItem(at: base) }
    let copy = parent.appendingPathComponent("Copy")
    try FileManager.default.copyItem(at: root, to: copy)
    try FileManager.default.removeItem(at: meetingFile(in: copy))

    #expect(throws: LibraryMover.MoveError.verificationFailed) {
        try LibraryMover.verifyCopy(original: root, copy: copy)
    }
}

@Test func `a file of a different size fails the check`() throws {
    let fixture = try makeMove()
    let (base, root, parent) = (fixture.base, fixture.root, fixture.parent)
    defer { try? FileManager.default.removeItem(at: base) }
    let copy = parent.appendingPathComponent("Copy")
    try FileManager.default.copyItem(at: root, to: copy)
    try Data("{\"truncated\":true}".utf8).write(to: meetingFile(in: copy))

    #expect(throws: LibraryMover.MoveError.verificationFailed) {
        try LibraryMover.verifyCopy(original: root, copy: copy)
    }
}

// MARK: - Disk usage

@Test func `disk usage counts each category`() throws {
    let base = try makeFolder()
    defer { try? FileManager.default.removeItem(at: base) }
    let library = MinutesLibrary(root: base)
    try library.prepareLayout()
    let folder = try library.createMeetingFolder(startedAt: Date(), title: "Sync")
    let block = Data(repeating: 1, count: 64 * 1024)
    try block.write(to: folder.micAudio)
    try block.write(to: folder.url.appendingPathComponent("transcript.md"))
    try block.write(to: library.modelsFolder.appendingPathComponent("model.gguf"))
    try block.write(to: library.internalFolder.appendingPathComponent("index.sqlite"))
    try block.write(to: base.appendingPathComponent("Vocabulary.txt"))

    let usage = LibraryDiskUsage(library: library)

    for bytes in [usage.audio, usage.meetingText, usage.models, usage.index, usage.other] {
        #expect(bytes >= 64 * 1024)
        #expect(bytes < 128 * 1024)
    }
    #expect(usage.total == usage.audio + usage.meetingText + usage.models + usage.index + usage.other)
}

@Test func `a missing library uses no disk`() {
    let usage = LibraryDiskUsage(library: MinutesLibrary(root: URL(fileURLWithPath: "/nonexistent/\(UUID())")))
    #expect(usage.total == 0)
}
