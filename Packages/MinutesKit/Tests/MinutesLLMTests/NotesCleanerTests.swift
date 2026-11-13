// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import MinutesLLM
import Synchronization
import Testing

/// A line every 30 seconds for `minutes` minutes, each naming its own time.
private func transcript(minutes: Int) -> [SummaryLine] {
    (0 ..< minutes * 2).map { index in
        SummaryLine(start: Double(index * 30), speaker: index.isMultiple(of: 2) ? "Bea" : "Chris",
                    text: "We talked about item number \(index) at some length today.")
    }
}

private let notes = [
    NoteLine("budget - bea wants #s fri", seconds: 125),
    NoteLine("remote: rubber? ask chris", seconds: 610),
    NoteLine(""),
    NoteLine("follow up w/ dana"),
]

private func cleaner(context: Int = 32768, answer: String = "## Budget\n- Bea wants numbers by Friday.") -> (
    NotesCleaner, FakeLLMProvider,
) {
    let provider = FakeLLMProvider(contextLength: context) { _ in answer }
    return (NotesCleaner(provider: provider), provider)
}

private func userPrompt(_ provider: FakeLLMProvider) throws -> String {
    try #require(provider.received.last?.last?.content)
}

@Test func `the notes, names and whole transcript go to the model`() async throws {
    let (cleaner, provider) = cleaner()
    let result = try await cleaner.clean(notes, transcript: transcript(minutes: 12), names: ["Bea", "Chris"],
                                         summary: nil, meeting: "Kickoff")
    #expect(result.text == "## Budget\n- Bea wants numbers by Friday.")
    #expect(result.context == .wholeTranscript)
    let prompt = try userPrompt(provider)
    #expect(prompt.contains("Meeting: Kickoff"))
    #expect(prompt.contains("People in the meeting: Bea, Chris"))
    #expect(prompt.contains("[2:05] budget - bea wants #s fri"))
    #expect(prompt.contains("\nfollow up w/ dana"))
    #expect(prompt.contains("[11:30] Chris: We talked about item number 23"))
    #expect(provider.received.last?.first?.role == .system)
}

@Test func `a long transcript is cut to excerpts around the notes`() async throws {
    // About 4,000 tokens of transcript in a context that holds a quarter of it.
    let (cleaner, provider) = cleaner(context: 3000)
    let result = try await cleaner.clean(notes, transcript: transcript(minutes: 120), names: [], summary: nil,
                                         meeting: "Long")
    #expect(result.context == .excerpts(count: 2, before: 180, after: 60))
    let prompt = try userPrompt(provider)
    #expect(prompt.contains("From 0:00 to 3:05:"))
    #expect(prompt.contains("From 7:10 to 11:10:"))
    #expect(prompt.contains("item number 15 "))
    #expect(!prompt.contains("item number 14 "))
    #expect(!prompt.contains("item number 23 "))
}

@Test func `excerpts close together are merged`() {
    let excerpts = NotesCleaner.excerpts(of: transcript(minutes: 20), around: [300, 400], before: 180, after: 60)
    #expect(excerpts.count == 1)
    #expect(excerpts[0].hasPrefix("From 2:00 to 7:40:"))
}

@Test func `excerpts narrow until they fit`() async throws {
    let said = String(repeating: "Words said here. ", count: 6)
    let lines = (0 ..< 400).map { SummaryLine(start: Double($0 * 5), speaker: "Bea", text: said + "\($0)") }
    let (cleaner, _) = cleaner(context: 2000)
    let result = try await cleaner.clean([NoteLine("one", seconds: 600)], transcript: lines, names: [],
                                         summary: nil, meeting: "M")
    guard case let .excerpts(count, before, after) = result.context else {
        Issue.record("Expected excerpts, got \(result.context)")
        return
    }
    #expect(count == 1)
    #expect(before < 180)
    #expect(after == before / 3)
}

@Test func `untimed notes with a long transcript use the summary`() async throws {
    let (cleaner, provider) = cleaner(context: 3000)
    let untimed = [NoteLine("budget fri"), NoteLine("ask chris")]
    let result = try await cleaner.clean(untimed, transcript: transcript(minutes: 120), names: ["Bea"],
                                         summary: "## Overview\nThe budget is due Friday.", meeting: "M")
    #expect(result.context == .summary)
    #expect(try userPrompt(provider).contains("The budget is due Friday."))
}

@Test func `with nothing that fits, only names go with the notes`() async throws {
    let (cleaner, provider) = cleaner(context: 3000)
    let result = try await cleaner.clean([NoteLine("budget")], transcript: transcript(minutes: 120),
                                         names: ["Bea"], summary: nil, meeting: "M")
    #expect(result.context == .namesOnly)
    #expect(try !userPrompt(provider).contains("Transcript"))
}

@Test func `notes alone work without a transcript`() async throws {
    let (cleaner, _) = cleaner()
    let result = try await cleaner.clean(notes, transcript: [], names: [], summary: nil, meeting: "M")
    #expect(result.context == .namesOnly)
}

@Test func `blank notes are refused`() async {
    let (cleaner, provider) = cleaner()
    await #expect(throws: NotesCleaner.Failure.noNotes) {
        try await cleaner.clean([NoteLine(""), NoteLine("  ")], transcript: [], names: [], summary: nil,
                                meeting: "M")
    }
    #expect(provider.received.isEmpty)
}

@Test func `notes too long for the context are refused`() async {
    let long = (0 ..< 500).map { NoteLine("A long line of notes, number \($0), with words.") }
    let (cleaner, _) = cleaner(context: 4096)
    await #expect(throws: LLMError.self) {
        try await cleaner.clean(long, transcript: [], names: [], summary: nil, meeting: "M")
    }
}

@Test func `the answer has room for three times the notes, within limits`() async throws {
    let (cleaner, _) = cleaner()
    let short = try await cleaner.prompt(notes: [NoteLine("a")], transcript: [], names: [], summary: nil,
                                         meeting: "M")
    #expect(short.maxTokens == 1024)
    let lines = (0 ..< 200).map { NoteLine("A long line of notes, number \($0), with words.") }
    let long = try await cleaner.prompt(notes: lines, transcript: [], names: [], summary: nil, meeting: "M")
    #expect(long.maxTokens == 4096)
}

@Test func `blank lines around the notes are left out`() async throws {
    let (cleaner, provider) = cleaner()
    _ = try await cleaner.clean([NoteLine(""), NoteLine("a"), NoteLine("")], transcript: [], names: [],
                                summary: nil, meeting: "M")
    #expect(try userPrompt(provider).hasSuffix("The notes to tidy up:\na"))
}

@Test func `the answer streams as it's written`() async throws {
    let (cleaner, _) = cleaner(answer: "## One\n- two three")
    let pieces = Pieces()
    _ = try await cleaner.clean([NoteLine("a")], transcript: [], names: [], summary: nil, meeting: "M") {
        pieces.append($0)
    }
    #expect(pieces.all.joined() == "## One\n- two three")
    #expect(pieces.all.count > 1)
}

@Test func `cancelling stops the cleanup`() async {
    let (cleaner, _) = cleaner(answer: String(repeating: "word ", count: 5000))
    let task = Task {
        try await cleaner.clean([NoteLine("a")], transcript: [], names: [], summary: nil, meeting: "M")
    }
    task.cancel()
    await #expect(throws: CancellationError.self) {
        try await task.value
    }
}

private final class Pieces: Sendable {
    private let storage = Mutex<[String]>([])

    func append(_ piece: String) {
        storage.withLock { $0.append(piece) }
    }

    var all: [String] {
        storage.withLock { $0 }
    }
}
