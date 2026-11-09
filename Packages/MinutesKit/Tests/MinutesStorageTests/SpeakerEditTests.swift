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

/// Me, then two others, then the first other again.
private func makeMeeting(in library: MinutesLibrary, title: String = "Sync") throws -> MeetingFolder {
    let folder = try library.createMeetingFolder(startedAt: started, title: title)
    let metadata = MeetingMetadata(title: title, startedAt: started, state: .complete, audioFormat: "aac",
                                   voiceProcessing: false)
    try folder.save(metadata)
    try folder.save(Transcript(engine: "apple", model: "m", segments: [
        line("me", "Morning all", at: 0),
        line("speaker-1", "Hi there", at: 3),
        line("speaker-2", "Hello", at: 6),
        line("speaker-1", "Shall we start", at: 9),
    ]), for: metadata)
    return folder
}

private func readable(_ folder: MeetingFolder) throws -> String {
    try String(contentsOf: folder.transcriptMarkdown, encoding: .utf8)
}

@Test func `speakers nobody has named get numbered labels`() {
    #expect(Transcript.displayName(forSpeaker: "speaker-2") == "Speaker 2")
    #expect(Transcript.displayName(forSpeaker: "me") == "Me")
    #expect(Transcript.displayName(forSpeaker: "others") == "Others")
    #expect(Transcript.displayName(forSpeaker: "speaker-x") == "speaker-x")
}

@Test func `speakers are listed in the order they first talk`() throws {
    let folder = try makeMeeting(in: makeLibrary())
    #expect(try folder.loadTranscript().speakers == ["me", "speaker-1", "speaker-2"])
}

@Test func `naming a speaker puts the name in meeting json and the readable transcript`() throws {
    let folder = try makeMeeting(in: makeLibrary())
    try folder.nameSpeaker("speaker-1", "  Dana ")
    let metadata = try folder.loadMetadata()
    #expect(metadata.speakers?["speaker-1"]?.name == "Dana")
    #expect(metadata.displayName(forSpeaker: "speaker-1") == "Dana")
    let text = try readable(folder)
    #expect(text.contains("**Dana** 0:03\n\nHi there"))
    #expect(text.contains("**Dana** 0:09\n\nShall we start"))
    #expect(text.contains("**Speaker 2** 0:06"))
}

@Test func `a blank name goes back to the numbered label`() throws {
    let folder = try makeMeeting(in: makeLibrary())
    try folder.nameSpeaker("speaker-2", "Sam")
    try folder.nameSpeaker("speaker-2", " ")
    #expect(try folder.loadMetadata().speakers == nil)
    #expect(try readable(folder).contains("**Speaker 2**"))
}

@Test func `your own name can be set for me`() throws {
    let folder = try makeMeeting(in: makeLibrary())
    try folder.nameSpeaker("me", "Ross")
    #expect(try readable(folder).contains("**Ross** 0:00"))
}

@Test func `naming someone who isn't in the transcript is refused`() throws {
    let folder = try makeMeeting(in: makeLibrary())
    #expect(throws: MeetingFolder.SpeakerEditError.noSuchSpeaker) {
        try folder.nameSpeaker("speaker-9", "Nobody")
    }
}

@Test func `naming clears a suggestion and declining one remembers it`() throws {
    let folder = try makeMeeting(in: makeLibrary())
    let sam = UUID()
    try folder.updateSpeakers { $0["speaker-2"] = .init(suggestion: .init(name: "Sam", profile: sam)) }
    try folder.declineSuggestion(for: "speaker-2")
    var entry = try #require(try folder.loadMetadata().speakers?["speaker-2"])
    #expect(entry.suggestion == nil)
    #expect(entry.declinedProfiles == [sam])

    try folder.updateSpeakers { $0["speaker-1"] = .init(suggestion: .init(name: "Dana", profile: UUID())) }
    try folder.nameSpeaker("speaker-1", "Dana")
    entry = try #require(try folder.loadMetadata().speakers?["speaker-1"])
    #expect(entry.suggestion == nil)
    #expect(entry.name == "Dana")
}

@Test func `merging two speakers moves every line and keeps a name`() throws {
    let folder = try makeMeeting(in: makeLibrary())
    try folder.nameSpeaker("speaker-2", "Dana")
    try folder.mergeSpeaker("speaker-2", into: "speaker-1")

    let transcript = try folder.loadTranscript()
    #expect(transcript.segments.map(\.speaker) == ["me", "speaker-1", "speaker-1", "speaker-1"])
    #expect(transcript.segments.map(\.text) == ["Morning all", "Hi there", "Hello", "Shall we start"])
    let speakers = try #require(try folder.loadMetadata().speakers)
    #expect(speakers["speaker-1"]?.name == "Dana")
    #expect(speakers["speaker-2"] == nil)
    #expect(try readable(folder).contains("**Dana** 0:03\n\nHi there\n\nHello\n\nShall we start\n"))
}

@Test func `merging into a named speaker keeps that speaker's name`() throws {
    let folder = try makeMeeting(in: makeLibrary())
    try folder.nameSpeaker("speaker-1", "Dana")
    try folder.nameSpeaker("speaker-2", "Danna")
    try folder.mergeSpeaker("speaker-2", into: "speaker-1")
    #expect(try folder.loadMetadata().speakers?.mapValues(\.name) == ["speaker-1": "Dana"])
}

@Test func `me can't be merged or given someone else's lines`() throws {
    let folder = try makeMeeting(in: makeLibrary())
    #expect(throws: MeetingFolder.SpeakerEditError.cantChangeMe) {
        try folder.mergeSpeaker("speaker-1", into: "me")
    }
    #expect(throws: MeetingFolder.SpeakerEditError.cantChangeMe) {
        try folder.moveLine(at: 0, to: "speaker-1")
    }
    #expect(throws: MeetingFolder.SpeakerEditError.cantChangeMe) {
        try folder.moveLine(at: 1, to: "me")
    }
}

@Test func `moving one line changes only that line`() throws {
    let folder = try makeMeeting(in: makeLibrary())
    try folder.moveLine(at: 3, to: "speaker-2")
    #expect(try folder.loadTranscript().segments.map(\.speaker) == ["me", "speaker-1", "speaker-2", "speaker-2"])
    #expect(try readable(folder).contains("**Speaker 2** 0:06\n\nHello\n\nShall we start\n"))
}

@Test func `moving a line to someone new makes the next speaker`() throws {
    let folder = try makeMeeting(in: makeLibrary())
    let created = try folder.moveLine(at: 2, to: nil)
    #expect(created == "speaker-3")
    #expect(try folder.loadTranscript().segments[2].speaker == "speaker-3")
}

@Test func `a name for a speaker with no lines left is dropped`() throws {
    let folder = try makeMeeting(in: makeLibrary())
    try folder.nameSpeaker("speaker-2", "Sam")
    try folder.moveLine(at: 2, to: "speaker-1")
    #expect(try folder.loadMetadata().speakers == nil)
}

@Test func `speakers can't be edited while the meeting is processing`() throws {
    let folder = try makeMeeting(in: makeLibrary())
    try folder.updateMetadata { $0.processing = ProcessingState(status: .queued) }
    let before = try Data(contentsOf: folder.transcriptJSON)
    #expect(throws: MeetingFolder.SpeakerEditError.meetingBusy) {
        try folder.mergeSpeaker("speaker-2", into: "speaker-1")
    }
    #expect(try Data(contentsOf: folder.transcriptJSON) == before)
}

@Test func `a transcript from a newer version isn't edited`() throws {
    let folder = try makeMeeting(in: makeLibrary())
    var transcript = try folder.loadTranscript()
    transcript.schemaVersion = Transcript.currentSchemaVersion + 1
    try folder.save(transcript, for: folder.loadMetadata())
    let before = try Data(contentsOf: folder.transcriptJSON)
    #expect(throws: MeetingFolder.FolderError.newerFileFormat) {
        try folder.moveLine(at: 1, to: "speaker-2")
    }
    #expect(try Data(contentsOf: folder.transcriptJSON) == before)
}

@Test func `a meeting with no transcript has nobody to name`() throws {
    let library = try makeLibrary()
    let folder = try library.createMeetingFolder(startedAt: started, title: "Empty")
    try folder.save(MeetingMetadata(title: "Empty", startedAt: started, state: .complete, audioFormat: "aac",
                                    voiceProcessing: false))
    #expect(throws: MeetingFolder.SpeakerEditError.noTranscript) {
        try folder.nameSpeaker("speaker-1", "Dana")
    }
}

@Test func `names survive renaming the meeting`() throws {
    let library = try makeLibrary()
    let folder = try makeMeeting(in: library)
    try folder.nameSpeaker("speaker-1", "Dana")
    let renamed = try library.rename(folder, to: "Budget")
    let text = try readable(renamed)
    #expect(text.hasPrefix("# Budget\n"))
    #expect(text.contains("**Dana**"))
}

@Test func `a version 1 meeting json loads with nobody named`() throws {
    let folder = try makeMeeting(in: makeLibrary())
    var object = try #require(JSONSerialization
        .jsonObject(with: Data(contentsOf: folder.metadataURL)) as? [String: Any])
    object["schemaVersion"] = 1
    try JSONSerialization.data(withJSONObject: object).write(to: folder.metadataURL)
    let metadata = try folder.loadMetadata()
    #expect(!metadata.isNewerThanThisApp)
    #expect(metadata.speakers == nil)
    try folder.nameSpeaker("speaker-1", "Dana")
    #expect(try folder.loadMetadata().schemaVersion == MeetingMetadata.currentSchemaVersion)
}

@Test func `previously used names come back most recent first`() throws {
    let library = try makeLibrary()
    let older = try makeMeeting(in: library, title: "Older")
    try older.nameSpeaker("speaker-1", "Dana")
    try older.nameSpeaker("me", "Ross")
    try older.updateMetadata { $0.startedAt = started.addingTimeInterval(-86400) }
    let newer = try makeMeeting(in: library, title: "Newer")
    try newer.nameSpeaker("speaker-1", "Sam")
    try newer.nameSpeaker("speaker-2", "dana")
    try library.speakerProfiles.addSample(
        VoiceSample(meeting: UUID(), recordedAt: started.addingTimeInterval(-90000), seconds: 10, embedding: [1]),
        toProfileNamed: "Alex",
    )
    #expect(library.knownSpeakerNames() == ["dana", "Sam", "Alex"])
}
