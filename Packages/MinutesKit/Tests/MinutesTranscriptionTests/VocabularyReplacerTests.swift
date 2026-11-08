// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesStorage
import MinutesTranscription
import Testing

private let list = [
    VocabularyEntry(term: "Tanium", variants: ["tan ium", "tannium", "tan e um"]),
    VocabularyEntry(term: "BPA"),
    VocabularyEntry(term: "POAM", variants: ["po am", "poem"]),
    VocabularyEntry(term: "Node.js", variants: ["node js"]),
    VocabularyEntry(term: "U.S.", variants: ["us of a"]),
]

/// One word per second, so a word's position is its start time.
private func words(_ text: String) -> [TranscriptWord] {
    text.split(separator: " ").enumerated().map { index, word in
        TranscriptWord(text: String(word), start: Double(index), end: Double(index) + 0.5)
    }
}

private func replaced(_ text: String) -> String {
    VocabularyReplacer(entries: list).apply(to: words(text)).map(\.text).joined(separator: " ")
}

@Test(arguments: [
    ("we use tannium daily", "we use Tanium daily"),
    ("we use TANNIUM daily", "we use Tanium daily"),
    ("we use tan ium daily", "we use Tanium daily"),
    ("we use Tan Ium daily", "we use Tanium daily"),
    ("we use tan e um daily", "we use Tanium daily"),
    ("the bpa contract", "the BPA contract"),
    ("is it tannium?", "is it Tanium?"),
    ("(tannium), then", "(Tanium), then"),
    ("\"tan ium\" works", "\"Tanium\" works"),
    ("tannium's agent", "Tanium's agent"),
    ("tannium’s agent", "Tanium’s agent"),
    ("tan ium's agent.", "Tanium's agent."),
    ("node js works", "Node.js works"),
    ("in the us of a.", "in the U.S."),
])
func `listed variants become the term`(text: String, expected: String) {
    #expect(replaced(text) == expected)
}

@Test(arguments: [
    "titanium is a metal",
    "tanniums are plural",
    "stand tan ium-free",
    "the tan is nice",
])
func `parts of other words are left alone`(text: String) {
    #expect(replaced(text) == text)
}

@Test(arguments: [
    "get a tan. ium is odd",
    "a tan, ium is odd",
    "the tan (ium) is odd",
])
func `punctuation between words stops a match`(text: String) {
    #expect(replaced(text) == text)
}

@Test func `the longest match wins`() {
    let replacer = VocabularyReplacer(entries: [
        VocabularyEntry(term: "Short", variants: ["tan"]),
        VocabularyEntry(term: "Long", variants: ["tan ium"]),
    ])
    #expect(replacer.apply(to: words("tan ium tan")).map(\.text) == ["Long", "Short"])
}

@Test func `a term outranks another entry's variant`() {
    let replacer = VocabularyReplacer(entries: [
        VocabularyEntry(term: "Other", variants: ["SIEM"]),
        VocabularyEntry(term: "SIEM"),
    ])
    #expect(replacer.apply(to: words("siem")).map(\.text) == ["SIEM"])
}

@Test func `a combined word spans the words it replaced`() throws {
    let result = VocabularyReplacer(entries: list).apply(to: words("we use tan e um daily"))
    #expect(result.map(\.text) == ["we", "use", "Tanium", "daily"])
    let term = try #require(result.dropFirst(2).first)
    #expect(term.start == 2)
    #expect(term.end == 4.5)
    #expect(result.last?.start == 5)
}

@Test func `words away from a match keep their exact times`() {
    let input = words("one tannium three")
    let result = VocabularyReplacer(entries: list).apply(to: input)
    #expect(result[0] == input[0])
    #expect(result[2] == input[2])
    #expect(result[1].start == input[1].start)
    #expect(result[1].end == input[1].end)
}

@Test func `an empty list changes nothing`() {
    let input = words("Some Words, here.")
    #expect(VocabularyReplacer(entries: []).apply(to: input) == input)
}

@Test func `punctuation alone never matches`() {
    let replacer = VocabularyReplacer(entries: [VocabularyEntry(term: "Dash", variants: ["..."])])
    #expect(replacer.apply(to: words("wait ... what")).map(\.text) == ["wait", "...", "what"])
}

@Test func `a replacement can hold a space`() {
    let replacer = VocabularyReplacer(entries: [VocabularyEntry(term: "Sentinel One", variants: ["sentinel 1"])])
    #expect(replacer.apply(to: words("sentinel 1 alert")).map(\.text) == ["Sentinel One", "alert"])
}
