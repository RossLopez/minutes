// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesLLM
@testable import MinutesSearch
import MinutesStorage
import SQLite3
import Testing

@Test func `typed text is quoted word by word`() {
    #expect(FTSQuery.allWords("bud") == #""bud" *"#)
    #expect(FTSQuery.allWords("budget fri ") == #""budget" "fri""#)
    #expect(FTSQuery.allWords(#"NEAR("a" b*) -c"#) == #""NEAR" "a" "b" "c" *"#)
    #expect(FTSQuery.allWords("  ?? ") == nil)
    #expect(FTSQuery.anyWord("Who is preparing the budget?") == #""budget" OR "preparing""#)
    #expect(FTSQuery.anyWord("what is it") == nil)
}

@Test func `rank fusion puts passages high in both lists first`() {
    #expect(RankFusion.fuse([[1, 2, 3], [3, 1, 4]]) == [1, 3, 2, 4])
    #expect(RankFusion.fuse([[5, 6], []]) == [5, 6])
}

@Test func `meetings are found by any of their text, with a snippet`() async throws {
    let fixture = try FixtureLibrary()
    try fixture.addMeeting("Kickoff", lines: ["me|0|We need rubber buttons", "speaker-1|5|Agreed on rubber"],
                           summary: "## Decisions\nPrice is twenty-five euros.", notes: "ask chris\nbudget friday",
                           names: ["speaker-1": "Dana"])
    try fixture.addMeeting("Budget Review", lines: ["me|0|The budget is due on Friday"])
    let index = try SearchIndex(file: fixture.indexFile)
    let update = try await index.update(library: fixture.library)
    #expect(update.indexed == 2)

    // Prefixes match while typing, and every word has to match.
    let rubber = try await index.matchingMeetings("rubb")
    #expect(rubber.map(\.hit.meetingTitle) == ["Kickoff"])
    #expect(rubber[0].hit.chunk.kind == .transcript)
    #expect(rubber[0].hit.snippet?.contains("\u{1}rubber\u{2}") == true)
    #expect(try await index.matchingMeetings("euros").first?.hit.chunk.kind == .summary)
    #expect(try await index.matchingMeetings("chris").first?.hit.chunk.start == 0)
    #expect(try await Set(index.matchingMeetings("friday").map(\.hit.meetingTitle)) == ["Kickoff", "Budget Review"])
    // The words can be in different passages of one meeting.
    #expect(try await index.matchingMeetings("friday rubber").map(\.hit.meetingTitle) == ["Kickoff"])
    #expect(try await index.matchingMeetings("friday nothing").isEmpty)
    // Speakers' names are searchable, and stemming finds other forms.
    #expect(try await index.matchingMeetings("Dana").count == 1)
    #expect(try await index.matchingMeetings("agree ").count == 1)
    // FTS syntax is only text.
    #expect(try await index.matchingMeetings(#"rubber" OR "budget"#).isEmpty)
}

@Test func `an update reindexes only what changed, and drops what's gone`() async throws {
    let fixture = try FixtureLibrary()
    let kickoff = try fixture.addMeeting("Kickoff", lines: ["me|0|rubber buttons"])
    let review = try fixture.addMeeting("Review", lines: ["me|0|budget friday"])
    let index = try SearchIndex(file: fixture.indexFile)
    _ = try await index.update(library: fixture.library)
    #expect(try await index.update(library: fixture.library) == IndexUpdate(unchanged: 2))

    // A rename moves the folder and rewrites meeting.json, so the meeting is read again.
    let renamed = try fixture.library.rename(kickoff.folder, to: "Design Kickoff")
    #expect(try await index.update(library: fixture.library) == IndexUpdate(indexed: 1, unchanged: 1))
    #expect(try await index.matchingMeetings("rubber").first?.hit.folderName == renamed.url.lastPathComponent)

    // Moved out of the library.
    _ = try fixture.library.moveToTrash(review.folder)
    #expect(try await index.update(library: fixture.library) == IndexUpdate(removed: 1, unchanged: 1))
    #expect(try await index.matchingMeetings("budget").isEmpty)
    #expect(try await index.status(model: nil).meetings == 1)
}

@Test func `only a folder's new name is saved when nothing in it changed`() async throws {
    let fixture = try FixtureLibrary()
    let meeting = try fixture.addMeeting("Kickoff", lines: ["me|0|rubber buttons"])
    let index = try SearchIndex(file: fixture.indexFile)
    _ = try await index.update(library: fixture.library)
    let moved = fixture.library.meetingsFolder.appendingPathComponent("Moved by hand")
    try FileManager.default.moveItem(at: meeting.folder.url, to: moved)
    #expect(try await index.update(library: fixture.library) == IndexUpdate(renamed: 1))
    #expect(try await index.matchingMeetings("rubber").first?.hit.folderName == "Moved by hand")
}

@Test func `questions find passages by keyword and by meaning, within filters`() async throws {
    let fixture = try FixtureLibrary()
    let early = Date(timeIntervalSince1970: 1_800_000_000)
    let late = early.addingTimeInterval(86400 * 30)
    let first = try fixture.addMeeting("Kickoff", on: early, lines: ["me|0|the remote needs rubber buttons"])
    try fixture.addMeeting("Review", on: late, lines: ["me|0|budget numbers come on friday"])
    let index = try SearchIndex(file: fixture.indexFile)
    _ = try await index.update(library: fixture.library)
    let embedder = FakeEmbeddingProvider()
    #expect(try await index.embedMissing(using: embedder, batchSize: 1) == 2)
    #expect(try await index.embedMissing(using: embedder) == 0)
    #expect(try await index.status(model: embedder.id).embedded == 2)

    let hits = try await index.search("When do the budget numbers come?", embedder: embedder)
    #expect(hits.first?.meetingTitle == "Review")
    #expect(hits.first?.snippet != nil)
    // Only by meaning: no keyword matches, but the fake embedder shares the word "rubber".
    let meaning = try await index.search("rubber", filter: SearchFilter(dates: early ..< late), embedder: embedder)
    #expect(meaning.map(\.meetingTitle) == ["Kickoff"])
    let scoped = try await index.search("budget", filter: SearchFilter(meetings: [first.metadata.id]))
    #expect(scoped.isEmpty)
    #expect(try await index.passages(of: first.metadata.id).count == 1)
}

@Test func `vectors are kept for passages that didn't change, and dropped for another model`() async throws {
    let fixture = try FixtureLibrary()
    let meeting = try fixture.addMeeting("Kickoff", lines: ["me|0|rubber buttons"], notes: "ask chris")
    let index = try SearchIndex(file: fixture.indexFile)
    _ = try await index.update(library: fixture.library)
    let embedder = FakeEmbeddingProvider()
    #expect(try await index.embedMissing(using: embedder) == 2)
    try meeting.folder.saveNotes(MeetingNotes(text: "ask chris and bea", times: [0]))
    _ = try await index.update(library: fixture.library)
    // Only the edited note needs a vector.
    #expect(try await index.embedMissing(using: embedder) == 1)
    #expect(try await index.embedMissing(using: FakeEmbeddingProvider(id: "other")) == 2)
    #expect(try await index.status(model: embedder.id).embedded == 0)
}

@Test func `an index from another version or a damaged one is made again`() async throws {
    let fixture = try FixtureLibrary()
    try fixture.addMeeting("Kickoff", lines: ["me|0|rubber buttons"])
    try Data("not a database".utf8).write(to: fixture.indexFile)
    var index = try SearchIndex(file: fixture.indexFile)
    _ = try await index.update(library: fixture.library)
    #expect(try await index.matchingMeetings("rubber").count == 1)

    var handle: OpaquePointer?
    sqlite3_open(fixture.indexFile.path, &handle)
    sqlite3_exec(handle, "PRAGMA user_version = 999", nil, nil, nil)
    sqlite3_close(handle)
    index = try SearchIndex(file: fixture.indexFile)
    #expect(try await index.status(model: nil).meetings == 0)
    try await index.removeAll()
}

@Test func `meetings still recording aren't indexed`() async throws {
    let fixture = try FixtureLibrary()
    let meeting = try fixture.addMeeting("Live", lines: ["me|0|rubber"])
    _ = try meeting.folder.updateMetadata { $0.state = .recording }
    let index = try SearchIndex(file: fixture.indexFile)
    #expect(try await index.update(library: fixture.library) == IndexUpdate())
}
