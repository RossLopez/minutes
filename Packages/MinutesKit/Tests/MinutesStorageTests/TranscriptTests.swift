// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import MinutesStorage
import Testing

private func makeLibrary() throws -> MinutesLibrary {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MinutesTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return MinutesLibrary(root: root)
}

private func makeMeeting(in library: MinutesLibrary, title: String = "Recording") throws -> MeetingFolder {
    let folder = try library.createMeetingFolder(startedAt: Date(timeIntervalSince1970: 1_800_000_000), title: title)
    try folder.save(MeetingMetadata(
        title: title,
        startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        state: .complete,
        audioFormat: "aac",
        voiceProcessing: false,
    ))
    return folder
}

private func segment(_ speaker: String, _ text: String, at start: Double) -> TranscriptSegment {
    let words = text.split(separator: " ").enumerated().map { index, word in
        TranscriptWord(text: String(word), start: start + Double(index), end: start + Double(index) + 0.5)
    }
    return TranscriptSegment(speaker: speaker, words: words)
}

@Test func `a segment takes its times and text from its words`() {
    let made = segment(Transcript.Speaker.me, "Hello there", at: 2)
    #expect(made.start == 2)
    #expect(made.end == 3.5)
    #expect(made.text == "Hello there")
}

@Test func `word times are rounded to milliseconds and never end before they start`() {
    let word = TranscriptWord(text: "Hi", start: 1.23456, end: 1)
    #expect(word.start == 1.235)
    #expect(word.end == 1.235)
}

@Test func `a transcript survives a round trip through its files`() throws {
    let folder = try makeMeeting(in: makeLibrary())
    let transcript = Transcript(
        engine: "apple",
        model: "SpeechTranscriber en_US",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        segments: [segment(Transcript.Speaker.me, "Hello there", at: 2)],
    )
    try folder.save(transcript, title: "Sync", startedAt: Date())
    #expect(try folder.loadTranscript() == transcript)
    #expect(FileManager.default.fileExists(atPath: folder.transcriptMarkdown.path))
}

@Test func `a transcript's fields stay readable in the file`() throws {
    let folder = try makeMeeting(in: makeLibrary())
    try folder.save(
        Transcript(engine: "apple", model: "m", segments: [segment(Transcript.Speaker.others, "Hi", at: 1.25)]),
        title: "Sync",
        startedAt: Date(),
    )
    let text = try String(contentsOf: folder.transcriptJSON, encoding: .utf8)
    #expect(text.contains("\"speaker\" : \"others\""))
    #expect(text.contains("\"start\" : 1.25"))
}

@Test func `the readable transcript names speakers and starts a block when the speaker changes`() {
    let transcript = Transcript(engine: "apple", model: "m", segments: [
        segment(Transcript.Speaker.me, "First line", at: 5),
        segment(Transcript.Speaker.me, "Second line", at: 9),
        segment(Transcript.Speaker.others, "A reply", at: 3725),
    ])
    let text = transcript.markdown(title: "Weekly", startedAt: Date(timeIntervalSince1970: 0))
    #expect(text.hasPrefix("# Weekly\n"))
    #expect(text.contains("**Me** 0:05\n\nFirst line\n\nSecond line\n\n**Others** 1:02:05\n\nA reply\n"))
}

@Test func `renaming a meeting updates the title in its readable transcript`() throws {
    let library = try makeLibrary()
    let folder = try makeMeeting(in: library)
    try folder.save(Transcript(engine: "apple", model: "m", segments: []), title: "Recording", startedAt: Date())
    let renamed = try library.rename(folder, to: "Budget")
    let text = try String(contentsOf: renamed.transcriptMarkdown, encoding: .utf8)
    #expect(text.hasPrefix("# Budget\n"))
}

@Test func `meetings from before processing existed still load`() throws {
    let folder = try makeMeeting(in: makeLibrary())
    let metadata = try folder.loadMetadata()
    #expect(metadata.processing == nil)
    let text = try String(contentsOf: folder.metadataURL, encoding: .utf8)
    #expect(!text.contains("processing"))
}

@Test func `processing state survives a round trip`() throws {
    let folder = try makeMeeting(in: makeLibrary())
    let state = ProcessingState(status: .failed, completedSteps: [.cleanMic], engine: "apple", failure: "No disk space")
    try folder.updateMetadata { $0.processing = state }
    #expect(try folder.loadMetadata().processing == state)
}

@Test func `metadata updates keep changes made since the last read`() throws {
    let folder = try makeMeeting(in: makeLibrary())
    try folder.updateMetadata { $0.title = "Changed elsewhere" }
    try folder.updateMetadata { $0.processing = ProcessingState() }
    let metadata = try folder.loadMetadata()
    #expect(metadata.title == "Changed elsewhere")
    #expect(metadata.processing != nil)
}

@Test func `metadata from a newer version isn't updated`() throws {
    let folder = try makeMeeting(in: makeLibrary())
    var metadata = try folder.loadMetadata()
    metadata.schemaVersion = MeetingMetadata.currentSchemaVersion + 1
    try folder.save(metadata)
    #expect(throws: MeetingFolder.FolderError.newerFileFormat) {
        try folder.updateMetadata { $0.title = "Lost fields" }
    }
    #expect(try folder.loadMetadata().title == "Recording")
}

@Test func `concurrent metadata updates all land`() async throws {
    let folder = try makeMeeting(in: makeLibrary())
    try folder.updateMetadata { $0.mic = MeetingMetadata.Track() }
    await withThrowingTaskGroup { group in
        for index in 0 ..< 50 {
            group.addTask {
                try folder.updateMetadata { $0.mic.gaps.append(.init(startSeconds: Double(index), durationSeconds: 1)) }
            }
        }
    }
    #expect(try folder.loadMetadata().mic.gaps.count == 50)
}
