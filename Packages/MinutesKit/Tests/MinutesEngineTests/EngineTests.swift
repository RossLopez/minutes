// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesParakeet
import MinutesStorage
import MinutesTranscription
import Testing

private func clip() throws -> URL {
    try #require(Bundle.module.url(forResource: "gettysburg-15s", withExtension: "m4a", subdirectory: "Fixtures"))
}

private func workFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("MinutesTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// What every engine must get right about this recording.
private func check(_ words: [TranscriptWord]) throws {
    let text = words.map(\.text).joined(separator: " ").lowercased()
    for expected in ["years ago", "fathers", "continent", "liberty", "created equal"] {
        #expect(text.contains(expected), "Missing a phrase, in \(words.count) words")
    }
    #expect(zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start }, "Words must be in time order")
    #expect(words.allSatisfy { $0.start <= $0.end && $0.end <= 15.5 })
    // "liberty" is spoken about 8.6 seconds in. Allow for each engine's timing and for the stripped comma.
    let liberty = try #require(words.first { $0.text.lowercased().hasPrefix("liberty") })
    #expect(abs(liberty.start - 8.6) < 1, "Heard at \(liberty.start) s")
}

@Test func `the Apple engine hears a real voice with word times`() async throws {
    let engine = AppleSpeechEngine()
    let status = await engine.modelStatus()
    guard status == .installed else {
        try Test.cancel("Apple's speech model isn't ready here: \(status)")
    }
    try await check(engine.transcribe(audio: clip(), vocabulary: [], workFolder: workFolder()) { _ in })
}

/// Set `MINUTES_TEST_PARAKEET_MODELS` to a folder holding the models, or an empty one with
/// `MINUTES_TEST_PARAKEET_DOWNLOAD=1` to fetch them there.
private func parakeet() async throws -> ParakeetEngine {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["MINUTES_TEST_PARAKEET_MODELS"] else {
        try Test.cancel("MINUTES_TEST_PARAKEET_MODELS isn't set")
    }
    let engine = ParakeetEngine { URL(fileURLWithPath: path, isDirectory: true) }
    if await engine.modelStatus() != .installed, environment["MINUTES_TEST_PARAKEET_DOWNLOAD"] == "1" {
        try await engine.installModel { _ in }
    }
    try #require(await engine.modelStatus() == .installed)
    return engine
}

@Test func `the Parakeet engine hears a real voice with word times`() async throws {
    let engine = try await parakeet()
    try await check(engine.transcribe(audio: clip(), vocabulary: [], workFolder: workFolder()) { _ in })
}

@Test func `the Parakeet vocabulary step corrects a term and keeps its timing`() async throws {
    let engine = try await parakeet()
    // The recording says "liberty", so a sound-alike term must not take it over, and everything else still works.
    let terms = [VocabularyEntry(term: "Tanium", variants: ["tan ium"]), VocabularyEntry(term: "Conceived")]
    let words = try await engine.transcribe(audio: clip(), vocabulary: terms, workFolder: workFolder()) { _ in }
    try check(words)
    #expect(!words.contains { $0.text.contains("Tanium") })
}

@Test func `an engine with no model says so rather than downloading`() async throws {
    let empty = try workFolder()
    let engine = ParakeetEngine { empty }
    #expect(await engine.modelStatus() == .notInstalled)
    #expect(try FileManager.default.contentsOfDirectory(atPath: empty.path).isEmpty)
}

@Test func `the Parakeet engine can't transcribe without its model and doesn't fetch one`() async throws {
    let empty = try workFolder()
    let engine = ParakeetEngine { empty }
    await #expect(throws: (any Error).self) {
        try await engine.transcribe(audio: clip(), vocabulary: [], workFolder: workFolder()) { _ in }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: empty.path).isEmpty)
}
