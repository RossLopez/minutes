// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesLLM
import Synchronization
import Testing

private func lines(_ count: Int, wordsEach: Int = 10) -> [SummaryLine] {
    (0 ..< count).map { index in
        let words = (0 ..< wordsEach).map { "word\($0)" }.joined(separator: " ")
        return SummaryLine(
            start: Double(index * 30),
            speaker: index.isMultiple(of: 2) ? "Dana" : "Speaker 2",
            text: words,
        )
    }
}

@Test func `lines show the time and the speaker's name`() {
    #expect(SummaryLine(start: 724.9, speaker: "Dana", text: "Ship it.").promptText == "[12:04] Dana: Ship it.")
    #expect(SummaryLine(start: 3724, speaker: "Me", text: "Hi.").promptText == "[1:02:04] Me: Hi.")
}

@Test func `a transcript that fits is summarized in one pass, streaming`() async throws {
    let provider = FakeLLMProvider { _ in "## Overview\nAll good." }
    let pieces = PieceCollector()
    let summary = try await Summarizer(provider: provider).summarize(
        lines(10),
        about: "Budget Review",
        instructions: "Summarize it.",
        emit: { pieces.add($0) },
    )
    #expect(summary == "## Overview\nAll good.")
    #expect(pieces.joined == "## Overview\nAll good.")
    #expect(provider.received.count == 1)
    let prompt = try #require(provider.received.first?.last?.content)
    #expect(prompt.contains("Summarize it."))
    #expect(prompt.contains("Meeting: Budget Review"))
    #expect(prompt.contains("[0:30] Speaker 2: word0"))
}

@Test func `too little said is refused before the model runs`() async throws {
    let provider = FakeLLMProvider()
    await #expect(throws: Summarizer.Failure.tooLittleSaid) {
        try await Summarizer(provider: provider).summarize(lines(1), about: "Short", instructions: "")
    }
    #expect(provider.received.isEmpty)
}

@Test func `a long transcript is read in parts that each fit, then summarized from the notes`() async throws {
    let provider = FakeLLMProvider(contextLength: 3000) { messages in
        messages.last?.content.contains("Write notes on this part") == true ? "- noted" : "## Overview\nDone."
    }
    var summarizer = Summarizer(provider: provider)
    summarizer.summaryTokens = 500
    summarizer.notesTokens = 300
    let stages = StageCollector()
    let summary = try await summarizer.summarize(
        lines(200),
        about: "Long",
        instructions: "Summarize it.",
        stage: { stages.add($0) },
    )
    #expect(summary == "## Overview\nDone.")
    let notes = provider.received.dropLast()
    #expect(notes.count > 1)
    for prompt in notes {
        #expect(try await provider.tokenCount(prompt) + 300 <= 3000)
    }
    // Every line is read exactly once, in order, and none is cut.
    let read = notes.flatMap { prompt in
        prompt.last?.content.split(separator: "\n").filter { $0.hasPrefix("[") } ?? []
    }
    #expect(read == lines(200).map { Substring($0.promptText) })
    #expect(stages.all.first == .readingPart(1, total: notes.count))
    #expect(stages.all.last == .writing)
    let final = try #require(provider.received.last?.last?.content)
    #expect(final.contains("Notes on part \(notes.count) of \(notes.count):"))
}

@Test func `notes too long for one prompt are combined in rounds`() async throws {
    let provider = FakeLLMProvider(contextLength: 3000) { messages in
        let prompt = messages.last?.content ?? ""
        if prompt.contains("Write notes on this part") {
            return String(repeating: "- a long note about this part ", count: 120)
        }
        return prompt.contains("Merge them into one set") ? "- merged" : "## Overview\nDone."
    }
    var summarizer = Summarizer(provider: provider)
    summarizer.summaryTokens = 500
    summarizer.notesTokens = 300
    let stages = StageCollector()
    let summary = try await summarizer.summarize(
        lines(400),
        about: "Very long",
        instructions: "Summarize it.",
        stage: { stages.add($0) },
    )
    #expect(summary == "## Overview\nDone.")
    #expect(stages.all.contains(.combiningNotes))
}

@Test func `cancelling stops the summary`() async throws {
    let provider = FakeLLMProvider { _ in String(repeating: "word ", count: 100_000) }
    let task = Task {
        try await Summarizer(provider: provider).summarize(lines(10), about: "Meeting", instructions: "")
    }
    task.cancel()
    await #expect(throws: CancellationError.self) {
        try await task.value
    }
}

@Test func `characters split across tokens are held until they're whole`() {
    var assembler = UTF8Assembler()
    let euro = Array("€".utf8)
    #expect(assembler.append([0x41] + euro[..<2]) == "A")
    #expect(assembler.append(Array(euro[2...])) == "€")
    #expect(assembler.append(Array("é".utf8).prefix(1).map(\.self)) == nil)
    #expect(assembler.flush() != nil)
    #expect(assembler.flush() == nil)
}

private final class PieceCollector: Sendable {
    private let pieces = Mutex<[String]>([])
    func add(_ piece: String) {
        pieces.withLock { $0.append(piece) }
    }

    var joined: String {
        pieces.withLock { $0.joined() }
    }
}

private final class StageCollector: Sendable {
    private let stages = Mutex<[Summarizer.Stage]>([])
    func add(_ stage: Summarizer.Stage) {
        stages.withLock { $0.append(stage) }
    }

    var all: [Summarizer.Stage] {
        stages.withLock { $0 }
    }
}
