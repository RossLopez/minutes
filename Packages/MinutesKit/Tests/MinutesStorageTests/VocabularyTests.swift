// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import MinutesStorage
import Testing

private let tanium = VocabularyEntry(term: "Tanium", variants: ["tan ium", "tannium"])

@Test func `a line holds a term and its variants`() {
    #expect(Vocabulary.parse("Tanium = tan ium, tannium\nBPA\n") == [tanium, VocabularyEntry(term: "BPA")])
}

@Test(arguments: [
    "Tanium=tan ium,tannium",
    "  Tanium   =   tan   ium ,  tannium  ",
    "\u{FEFF}Tanium = tan ium, tannium",
    "Tanium = tan ium, tannium, , TANNIUM, tanium",
    "# A comment\n\n   \nTanium = tan ium, tannium\r\n",
    "Tanium = tan ium\ntanium = tannium",
])
func `hand-edited lines read the same`(text: String) {
    #expect(Vocabulary.parse(text) == [tanium])
}

@Test(arguments: ["", "\n\n", "# Only comments", " = no term here", "=", "   "])
func `lines without a term are ignored`(text: String) {
    #expect(Vocabulary.parse(text).isEmpty)
}

@Test func `an equals sign with nothing after it is a term with no variants`() {
    #expect(Vocabulary.parse("BPA =") == [VocabularyEntry(term: "BPA")])
}

@Test func `a saved list reads back the same`() {
    let entries = [
        tanium,
        VocabularyEntry(term: "BPA"),
        VocabularyEntry(term: "Sentinel One", variants: ["sentinel 1"]),
    ]
    #expect(Vocabulary.parse(Vocabulary.render(entries)) == entries)
}

@Test func `the file explains itself and says comments get replaced`() {
    let text = Vocabulary.render([tanium])
    #expect(text.hasPrefix("# Custom vocabulary"))
    #expect(text.hasSuffix("Tanium = tan ium, tannium\n"))
}

@Test func `a library without a vocabulary file has an empty list`() throws {
    let library = MinutesLibrary(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    #expect(try library.loadVocabulary().isEmpty)
}

@Test func `a vocabulary file that isn't text throws rather than reading as empty`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MinutesTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let library = MinutesLibrary(root: root)
    try Data([0xFF, 0xFE, 0x00, 0xD8]).write(to: library.vocabularyFile)
    #expect(throws: (any Error).self) {
        try library.loadVocabulary()
    }
}

@Test func `the library saves and loads its list`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MinutesTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let library = MinutesLibrary(root: root)
    try library.saveVocabulary([tanium])
    #expect(try library.loadVocabulary() == [tanium])
}

@Test(arguments: [
    "term,variants\nTanium,tan ium,tannium\n",
    "Tanium,tan ium,tannium",
    "\"Tanium\",\"tan ium, tannium\"\r\n",
    "TERM,other\nTanium,tan ium,,tannium\n\n",
    "\u{FEFF}Tanium,tan ium,tannium\n",
])
func `csv files read the same`(text: String) {
    #expect(Vocabulary.parseCSV(text) == [tanium])
}

@Test func `a term can hold a comma and a quote in csv`() {
    let entry = VocabularyEntry(term: "Acme, \"Inc\"", variants: ["acme inc"])
    #expect(Vocabulary.parseCSV(Vocabulary.renderCSV([entry])) == [entry])
}

@Test func `a csv export reads back the same`() {
    let entries = [tanium, VocabularyEntry(term: "BPA")]
    #expect(Vocabulary.parseCSV(Vocabulary.renderCSV(entries)) == entries)
}

@Test func `an unfinished quote in csv doesn't lose the row`() {
    #expect(Vocabulary.parseCSV("\"Tanium,tan ium") == [VocabularyEntry(term: "Tanium,tan ium")])
}

@Test func `importing keeps what's there and adds new variants`() {
    let merged = Vocabulary.merging(
        [VocabularyEntry(term: "Tanium", variants: ["tan ium"])],
        with: [VocabularyEntry(term: "TANIUM", variants: ["tannium"]), VocabularyEntry(term: "BPA")],
    )
    #expect(merged == [tanium, VocabularyEntry(term: "BPA")])
}
