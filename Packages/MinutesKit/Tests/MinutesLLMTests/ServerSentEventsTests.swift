// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesLLM
import Testing

private func events(_ text: String, splitEvery size: Int) throws -> [ServerSentEvent] {
    var parser = ServerSentEventParser()
    let bytes = Array(text.utf8)
    var found: [ServerSentEvent] = []
    for start in stride(from: 0, to: bytes.count, by: size) {
        try found += parser.feed(bytes[start ..< min(start + size, bytes.count)])
    }
    if let last = parser.finish() {
        found.append(last)
    }
    return found
}

@Test(arguments: [1, 2, 3, 7, 1000])
func `events come out the same however the bytes are split`(size: Int) throws {
    let stream = """
    data: {"a":1}

    : a comment to keep the connection open

    event: note
    data: first
    data: second

    data: [DONE]


    """
    #expect(try events(stream, splitEvery: size) == [
        ServerSentEvent(data: #"{"a":1}"#),
        ServerSentEvent(name: "note", data: "first\nsecond"),
        ServerSentEvent(data: "[DONE]"),
    ])
}

@Test(arguments: [1, 2, 5, 1000])
func `CRLF and CR line endings work, even split between pieces`(size: Int) throws {
    let stream = "data: one\r\n\r\ndata: two\r\rdata:three\n\n"
    #expect(try events(stream, splitEvery: size).map(\.data) == ["one", "two", "three"])
}

@Test func `only one space after the colon is dropped, and a missing value is empty`() throws {
    let found = try events("data:  padded\ndata\n\n", splitEvery: 100)
    #expect(found == [ServerSentEvent(data: " padded\n")])
}

@Test func `a last event without its blank line still arrives`() throws {
    #expect(try events("data: one\n\ndata: two", splitEvery: 100).map(\.data) == ["one", "two"])
}

@Test func `characters split between pieces arrive whole`() throws {
    #expect(try events("data: Grüße 👋\n\n", splitEvery: 1).map(\.data) == ["Grüße 👋"])
}

@Test func `a line that never ends is refused`() {
    var parser = ServerSentEventParser()
    let piece = [UInt8](repeating: UInt8(ascii: "a"), count: 1 << 20)
    #expect(throws: ServerSentEventParser.TooLarge.self) {
        for _ in 0 ..< 5 {
            _ = try parser.feed(piece)
        }
    }
}

// MARK: - Thinking

private func filtered(_ pieces: [String]) -> String {
    var filter = ThinkingFilter()
    return pieces.map { filter.feed($0) }.joined() + filter.finish()
}

@Test func `a leading think block is dropped, with the blank lines after it`() {
    #expect(filtered(["<think>Plan the summary.</think>\n\n## Overview"]) == "## Overview")
    #expect(filtered(["\n<th", "ink>Plan", " it.</th", "ink>", "\n", "\n## Ov", "erview"]) == "## Overview")
}

@Test func `text without a think block passes through as it comes`() {
    var filter = ThinkingFilter()
    #expect(filter.feed("## Overview") == "## Overview")
    #expect(filter.feed(" and more") == " and more")
    // Only a block at the very start counts.
    #expect(filtered(["Says ", "<think>", " out loud"]) == "Says <think> out loud")
}

@Test func `text that could start a think block is held until it's clear it doesn't`() {
    var filter = ThinkingFilter()
    #expect(filter.feed("<th").isEmpty)
    #expect(filter.feed("e answer") == "<the answer")
    #expect(filtered(["<"]) == "<")
}

@Test func `a think block that never closes shows nothing`() {
    #expect(filtered(["<think>Still thinking", " when it ran out"]).isEmpty)
}
