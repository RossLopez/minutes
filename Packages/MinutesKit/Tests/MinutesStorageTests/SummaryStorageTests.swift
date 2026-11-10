// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import MinutesStorage
import Testing

private let started = Date(timeIntervalSince1970: 1_800_000_000)

private func makeLibrary() throws -> MinutesLibrary {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MinutesTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return MinutesLibrary(root: root)
}

private func line(_ speaker: String, _ text: String, at start: Double) -> TranscriptSegment {
    let words = text.split(separator: " ").enumerated().map { index, word in
        TranscriptWord(text: String(word), start: start + Double(index), end: start + Double(index) + 0.5)
    }
    return TranscriptSegment(speaker: speaker, words: words)
}

private func makeMeeting(in library: MinutesLibrary) throws -> MeetingFolder {
    let folder = try library.createMeetingFolder(startedAt: started, title: "Sync")
    let metadata = MeetingMetadata(title: "Sync", startedAt: started, state: .complete, audioFormat: "aac",
                                   voiceProcessing: false)
    try folder.save(metadata)
    try folder.save(Transcript(engine: "apple", model: "m", segments: [
        line("me", "Morning all", at: 0),
        line("speaker-1", "I'll send the budget", at: 3),
        line("speaker-2", "Thanks", at: 6),
    ]), for: metadata)
    return folder
}

private let names = ["me": "Me", "speaker-1": "Speaker 1", "speaker-2": "Speaker 2"]

@Test func `a summary is saved with where it came from`() throws {
    let folder = try makeMeeting(in: makeLibrary())
    let date = Date(timeIntervalSince1970: 1_800_000_600)
    try folder.saveSummary("## Overview\nShort.\n\n", template: "Default", model: "builtin:e2b", names: names, at: date)
    #expect(folder.loadSummary() == "## Overview\nShort.\n")
    let summary = try #require(try folder.loadMetadata().summary)
    #expect(summary.status == .complete)
    #expect(summary.template == "Default")
    #expect(summary.model == "builtin:e2b")
    #expect(summary.createdAt == date)
    #expect(summary.names == names)
    #expect(try folder.loadMetadata().schemaVersion == MeetingMetadata.currentSchemaVersion)
}

@Test func `a new summary keeps the old one in summaries`() throws {
    let folder = try makeMeeting(in: makeLibrary())
    try folder.saveSummary("First", template: "Default", model: "m", names: names, at: started)
    try folder.saveSummary("Second", template: "Standup", model: "m", names: names, at: started.addingTimeInterval(60))
    try folder.saveSummary("Third", template: "Default", model: "m", names: names, at: started.addingTimeInterval(120))
    #expect(folder.loadSummary() == "Third\n")
    let previous = folder.previousSummaries()
    #expect(previous.count == 2)
    #expect(previous.first?.lastPathComponent.hasSuffix(" Standup.md") == true)
    #expect(try String(contentsOf: previous[0], encoding: .utf8) == "Second\n")
    #expect(try String(contentsOf: previous[1], encoding: .utf8) == "First\n")
}

@Test func `naming a speaker puts the name in the summary`() throws {
    let folder = try makeMeeting(in: makeLibrary())
    let text = "- [ ] **Speaker 1:** send the budget\n- Speaker 12 is someone else"
    try folder.saveSummary(text, template: "Default", model: "m", names: names)
    try folder.nameSpeaker("speaker-1", "Dana")
    #expect(folder.loadSummary() == "- [ ] **Dana:** send the budget\n- Speaker 12 is someone else\n")
    let summary = try #require(try folder.loadMetadata().summary)
    #expect(summary.names?["speaker-1"] == "Dana")
    #expect(summary.namesChanged == true)

    try folder.nameSpeaker("speaker-1", "Dana Smith")
    #expect(folder.loadSummary()?.contains("**Dana Smith:**") == true)
}

@Test func `merging a speaker gives their summary mentions to the other`() throws {
    let folder = try makeMeeting(in: makeLibrary())
    try folder.nameSpeaker("speaker-1", "Dana")
    try folder.saveSummary(
        "Dana and Speaker 2 agreed.",
        template: "Default",
        model: "m",
        names: ["me": "Me", "speaker-1": "Dana", "speaker-2": "Speaker 2"],
    )
    try folder.mergeSpeaker("speaker-2", into: "speaker-1")
    #expect(folder.loadSummary() == "Dana and Dana agreed.\n")
}

@Test func `swapped names don't collapse into one`() {
    let text = MeetingFolder.replacingWholeWords([("Sam", "Alex"), ("Alex", "Sam")], in: "Sam asked Alex.")
    #expect(text == "Alex asked Sam.")
}

@Test func `a summary written without names is left alone`() throws {
    let folder = try makeMeeting(in: makeLibrary())
    try Data("Speaker 1 said hi.".utf8).write(to: folder.summaryFile)
    try folder.nameSpeaker("speaker-1", "Dana")
    #expect(folder.loadSummary() == "Speaker 1 said hi.")
}

// MARK: - Templates

private func makeStore() throws -> SummaryTemplateStore {
    try SummaryTemplateStore(folder: makeLibrary().templatesFolder, defaultPrompt: "Summarize.")
}

@Test func `the default template is written once and hand edits are kept`() throws {
    let store = try makeStore()
    #expect(store.templates() == [SummaryTemplate(name: "Default", prompt: "Summarize.")])
    try Data("My own words.".utf8).write(to: store.folder.appendingPathComponent("Default.md"))
    #expect(store.template(named: "Default").prompt == "My own words.")
    try store.restoreDefault()
    #expect(store.template(named: "Default").prompt == "Summarize.")
}

@Test func `templates are listed default first, then by name, skipping files that aren't text`() throws {
    let store = try makeStore()
    try store.save(SummaryTemplate(name: "standup", prompt: "a"))
    try store.save(SummaryTemplate(name: "Board", prompt: "b"))
    try Data([0xFF, 0xFE, 0x00]).write(to: store.folder.appendingPathComponent("Broken.md"))
    try Data("x".utf8).write(to: store.folder.appendingPathComponent("notes.txt"))
    #expect(store.templates().map(\.name) == ["Default", "Board", "standup"])
    #expect(try Data(contentsOf: store.folder.appendingPathComponent("Broken.md")) == Data([0xFF, 0xFE, 0x00]))
}

@Test func `new templates get an unused name`() throws {
    let store = try makeStore()
    #expect(try store.add(named: "Standup", prompt: "a") == "Standup")
    #expect(try store.add(named: "Standup", prompt: "b") == "Standup 2")
    #expect(try store.add(named: "a/b", prompt: "c") == "a b")
}

@Test func `renaming a template renames its file`() throws {
    let store = try makeStore()
    try store.add(named: "Standup", prompt: "a")
    try store.add(named: "Board", prompt: "b")
    #expect(try store.rename("Standup", to: " Daily ") == "Daily")
    #expect(store.templates().map(\.name) == ["Default", "Board", "Daily"])
    #expect(throws: SummaryTemplateStore.StoreError.nameTaken) {
        try store.rename("Daily", to: "Board")
    }
    #expect(throws: SummaryTemplateStore.StoreError.emptyName) {
        try store.rename("Daily", to: "  ")
    }
    #expect(try store.rename("Daily", to: "daily") == "daily")
}

@Test func `a missing template falls back to the default`() throws {
    let store = try makeStore()
    #expect(store.template(named: "Gone").name == "Default")
}
