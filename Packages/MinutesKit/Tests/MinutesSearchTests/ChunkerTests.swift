// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import MinutesSearch
import MinutesStorage
import Testing

private func segment(_ speaker: String, _ start: Double, _ text: String) -> TranscriptSegment {
    let words = text.split(separator: " ").enumerated().map { index, word in
        TranscriptWord(text: String(word), start: start + Double(index), end: start + Double(index) + 0.5)
    }
    return TranscriptSegment(speaker: speaker, words: words)
}

@Test func `transcript passages are whole segments with names and times`() {
    let transcript = Transcript(engine: "fake", model: "fake", segments: [
        segment("me", 0, filler(120, tag: "a")),
        segment("me", 130, filler(60, tag: "b")),
        segment("speaker-1", 200, filler(50, tag: "c")),
        segment("speaker-1", 260, filler(10, tag: "d")),
    ])
    let chunks = MeetingChunker.transcriptChunks(transcript) { $0 == "me" ? "Me" : "Dana" }
    #expect(chunks.count == 2)
    #expect(chunks[0].start == 0)
    #expect(chunks[0].end == 249.5)
    #expect(chunks[0].speakers == ["Me", "Dana"])
    // Consecutive segments from one speaker are one line.
    #expect(chunks[0].text.components(separatedBy: "\n").count == 2)
    #expect(chunks[0].text.hasPrefix("Me: a1 "))
    // The next passage starts with the last segment again.
    #expect(chunks[1].start == 200)
    #expect(chunks[1].text.hasPrefix("Dana: c1 "))
    #expect(chunks[1].text.hasSuffix("d10"))
}

@Test func `a long segment isn't repeated in the next passage`() {
    let transcript = Transcript(engine: "fake", model: "fake", segments: [
        segment("me", 0, filler(250, tag: "a")),
        segment("me", 300, filler(5, tag: "b")),
    ])
    let chunks = MeetingChunker.transcriptChunks(transcript) { _ in "Me" }
    #expect(chunks.count == 2)
    #expect(chunks[1].text == "Me: b1 b2 b3 b4 b5")
}

@Test func `no passage is repeated when the last one ends on a full passage`() {
    let transcript = Transcript(engine: "fake", model: "fake", segments: [segment("me", 0, filler(200))])
    #expect(MeetingChunker.transcriptChunks(transcript) { _ in "Me" }.count == 1)
}

@Test func `summaries split at headings, and long sections at paragraphs`() {
    let long = (1 ... 4).map { filler(100, tag: "p\($0)x") }.joined(separator: "\n\n")
    let sections = MeetingChunker.sections("""
    ## Overview
    Short.

    ## Decisions
    \(long)
    ###
    """)
    #expect(sections.first == "## Overview\nShort.")
    // 400 words of paragraphs make two passages of up to 300 words.
    #expect(sections.count == 3)
    #expect(sections[1].hasPrefix("## Decisions\np1x1"))
    #expect(sections[2].hasPrefix("p3x1"))
}

@Test func `typed notes are grouped at blank lines, at their first line's time`() {
    let notes = MeetingNotes(text: "budget\nbea friday\n\nremote\n", times: [10, 20, nil, 90, nil])
    let chunks = MeetingChunker.noteChunks(notes)
    #expect(chunks == [
        SearchChunk(kind: .notes, start: 10, text: "budget\nbea friday"),
        SearchChunk(kind: .notes, start: 90, text: "remote"),
    ])
}
