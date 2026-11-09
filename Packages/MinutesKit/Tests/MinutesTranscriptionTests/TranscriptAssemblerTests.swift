// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesStorage
@testable import MinutesTranscription
import Testing

private func word(_ text: String, _ start: Double, _ end: Double? = nil) -> TranscriptWord {
    TranscriptWord(text: text, start: start, end: end ?? start + 0.3)
}

private func lines(_ words: [TranscriptWord]) -> [String] {
    TranscriptAssembler.segments(from: words, speaker: "me").map(\.text)
}

@Test func `no words make no lines`() {
    #expect(lines([]).isEmpty)
}

@Test func `continuous speech stays on one line`() {
    #expect(lines([word("one", 0), word("two", 0.4), word("three", 0.8)]) == ["one two three"])
}

@Test func `a long pause starts a new line`() {
    #expect(lines([word("one", 0, 0.5), word("two", 1.4, 1.8), word("three", 3, 3.2)]) == ["one two", "three"])
}

@Test func `a short sentence doesn't end the line`() {
    #expect(lines([word("Yes.", 0), word("Right", 0.4)]) == ["Yes. Right"])
}

@Test func `a long line ends at a sentence end`() {
    let words = [word("First", 0, 3), word("part.", 3, 6.5), word("Second", 6.6)]
    #expect(lines(words) == ["First part.", "Second"])
}

@Test func `speech with no sentence ends still breaks`() {
    let words = (0 ..< 100).map { word("word", Double($0) * 0.4) }
    let segments = TranscriptAssembler.segments(from: words, speaker: "me")
    #expect(segments.count > 1)
    #expect(segments.allSatisfy { $0.end - $0.start <= TranscriptAssembler.longestLine })
    #expect(segments.flatMap(\.words) == words)
}

@Test func `a word longer than the limit still gets a line`() {
    #expect(lines([word("long", 0, 40), word("next", 40.1)]) == ["long", "next"])
}

@Test func `lines carry their speaker`() {
    let segments = TranscriptAssembler.segments(from: [word("Hi", 0)], speaker: Transcript.Speaker.others)
    #expect(segments.first?.speaker == Transcript.Speaker.others)
}

@Test func `merged lines follow time across tracks`() {
    let mine = TranscriptAssembler.segments(from: [word("mine", 5), word("later", 20)], speaker: "me")
    let theirs = TranscriptAssembler.segments(from: [word("theirs", 1), word("middle", 10)], speaker: "others")
    #expect(TranscriptAssembler.merge(mine, theirs).map(\.text) == ["theirs", "mine", "middle", "later"])
}

@Test func `overlapping lines stay whole`() {
    let theirs = TranscriptAssembler.segments(
        from: [word("a", 0, 1), word("long", 1, 2), word("line", 2, 3)],
        speaker: "others",
    )
    let mine = TranscriptAssembler.segments(from: [word("yeah", 1.5)], speaker: "me")
    let merged = TranscriptAssembler.merge(mine, theirs)
    #expect(merged.map(\.text) == ["a long line", "yeah"])
}

@Test func `lines starting together keep the first track first`() {
    let mine = TranscriptAssembler.segments(from: [word("mine", 2)], speaker: "me")
    let theirs = TranscriptAssembler.segments(from: [word("theirs", 2)], speaker: "others")
    #expect(TranscriptAssembler.merge(mine, theirs).map(\.speaker) == ["me", "others"])
}

@Test func `merging with an empty track returns the other`() {
    let mine = TranscriptAssembler.segments(from: [word("mine", 2)], speaker: "me")
    #expect(TranscriptAssembler.merge(mine, []) == mine)
}

// MARK: - Retiming rewritten text

private let spoken = [word("we", 0, 1), word("use", 1, 2), word("tan", 2, 3), word("ium", 3, 4), word("daily", 4, 5)]

@Test func `unchanged text keeps every word as it was`() {
    #expect(TimedTextAligner.retime(spoken, toMatch: "we use tan ium daily") == spoken)
}

@Test func `a rewritten word takes the time of the words it replaced`() {
    let result = TimedTextAligner.retime(spoken, toMatch: "we use Tanium daily")
    #expect(result.map(\.text) == ["we", "use", "Tanium", "daily"])
    #expect(result[2].start == 2)
    #expect(result[2].end == 4)
    #expect(result[3] == spoken[4])
}

@Test func `one word rewritten as two shares its time`() {
    let result = TimedTextAligner.retime([word("servicenow", 1, 3)], toMatch: "service now")
    #expect(result.map(\.text) == ["service", "now"])
    #expect(result.first?.start == 1)
    #expect(result.last?.end == 3)
    #expect(result[0].end == result[1].start)
}

@Test func `a removed word disappears and the rest keep their times`() {
    let result = TimedTextAligner.retime(spoken, toMatch: "we use daily")
    #expect(result == [spoken[0], spoken[1], spoken[4]])
}

@Test func `an added word sits next to its neighbor`() {
    let result = TimedTextAligner.retime([word("a", 0, 1), word("b", 2, 3)], toMatch: "a new b")
    #expect(result.map(\.text) == ["a", "new", "b"])
    #expect(result[1].start == 1)
    #expect(result[1].end == 1)
}

@Test func `a rewrite at the very start or end works`() {
    #expect(TimedTextAligner.retime(spoken, toMatch: "They use tan ium every day").first?.start == 0)
    #expect(TimedTextAligner.retime(spoken, toMatch: "They use tan ium every day").last?.end == 5)
}

@Test func `an empty rewrite leaves no words, and no words can gain text`() {
    #expect(TimedTextAligner.retime(spoken, toMatch: "").isEmpty)
    #expect(TimedTextAligner.retime([], toMatch: "hello").map(\.text) == ["hello"])
}

@Test func `changes in several places all land`() {
    let result = TimedTextAligner.retime(spoken, toMatch: "We use tan ium Daily")
    #expect(result.map(\.text) == ["We", "use", "tan", "ium", "Daily"])
    #expect(result[0].start == 0)
    #expect(result[4].end == 5)
}

@Test func `a new line starts where the speaker changes`() {
    let words = [word("Hi", 0), word("there", 0.3), word("Hello", 0.6), word("again", 0.9)]
    let segments = TranscriptAssembler.segments(
        from: words,
        speakers: ["speaker-1", "speaker-1", "speaker-2", "speaker-1"],
    )
    #expect(segments.map(\.speaker) == ["speaker-1", "speaker-2", "speaker-1"])
    #expect(segments.map(\.text) == ["Hi there", "Hello", "again"])
}
