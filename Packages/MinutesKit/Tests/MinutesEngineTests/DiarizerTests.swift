// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesDiarization
@testable import MinutesFluidAudio
import Testing

private func clip() throws -> URL {
    try #require(Bundle.module.url(forResource: "gettysburg-15s", withExtension: "m4a", subdirectory: "Fixtures"))
}

private func workFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("MinutesTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func source(_ samples: [Float]) -> MappedAudioSource {
    MappedAudioSource(data: samples.withUnsafeBufferPointer { Data(buffer: $0) })
}

private func copy(_ source: MappedAudioSource, offset: Int, count: Int) throws -> [Float] {
    var out = [Float](repeating: -1, count: count)
    try out.withUnsafeMutableBufferPointer { buffer in
        try source.copySamples(into: buffer.baseAddress!, offset: offset, count: count)
    }
    return out
}

@Test func `the mapped source hands back the samples it holds`() throws {
    let audio = source([1, 2, 3, 4, 5])
    #expect(audio.sampleCount == 5)
    #expect(try copy(audio, offset: 1, count: 3) == [2, 3, 4])
}

@Test func `reading past either end of the mapped source gives silence`() throws {
    let audio = source([1, 2, 3])
    #expect(try copy(audio, offset: 2, count: 3) == [3, 0, 0])
    #expect(try copy(audio, offset: -2, count: 3) == [0, 0, 1])
    #expect(try copy(audio, offset: 10, count: 2) == [0, 0])
}

/// FluidAudio's network switch and the models folder are shared, so these run one at a time.
@Suite(.serialized) struct FluidDiarizerTests {
    @Test func `the diarizer with no model says so rather than downloading`() async throws {
        let empty = try workFolder()
        let diarizer = FluidDiarizer { empty }
        #expect(await diarizer.modelStatus() == .notInstalled)
        #expect(FluidNetwork.isOffline)
        await #expect(throws: (any Error).self) {
            try await diarizer.diarize(audio: clip(), workFolder: workFolder()) { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: empty.path).isEmpty)
    }

    @Test func `network access is back off after a download fails`() async throws {
        struct Refused: Error {}
        await #expect(throws: Refused.self) {
            try await FluidNetwork.allowingDownloads { () async throws in
                #expect(!FluidNetwork.isOffline)
                throw Refused()
            }
        }
        #expect(FluidNetwork.isOffline)
    }

    /// Set `MINUTES_TEST_DIARIZER_MODELS` to a folder holding the models, or an empty one with
    /// `MINUTES_TEST_DIARIZER_DOWNLOAD=1` to fetch them there.
    private func diarizer() async throws -> FluidDiarizer {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["MINUTES_TEST_DIARIZER_MODELS"] else {
            try Test.cancel("MINUTES_TEST_DIARIZER_MODELS isn't set")
        }
        let diarizer = FluidDiarizer { URL(fileURLWithPath: path, isDirectory: true) }
        if await diarizer.modelStatus() != .installed, environment["MINUTES_TEST_DIARIZER_DOWNLOAD"] == "1" {
            try await diarizer.installModel { _ in }
        }
        try #require(await diarizer.modelStatus() == .installed)
        return diarizer
    }

    @Test func `one voice is one speaker, with turns covering the speech`() async throws {
        let diarizer = try await diarizer()
        let result = try await diarizer.diarize(audio: clip(), workFolder: workFolder()) { _ in }
        #expect(result.speakers.count == 1)
        let spoken = result.turns.reduce(0) { $0 + $1.duration }
        #expect(spoken > 8, "Heard \(spoken) s of speech")
        #expect(result.embeddings.count == 1)
        #expect(result.embeddings.values.first?.count == 256)
    }

    @Test func `a voice's embedding from part of a track matches the whole`() async throws {
        let diarizer = try await diarizer()
        let audio = try clip()
        let result = try await diarizer.diarize(audio: audio, workFolder: workFolder()) { _ in }
        let whole = try #require(result.embeddings.values.first)
        let part = try await diarizer.embedding(audio: audio, spans: [1 ... 7], workFolder: workFolder())
        let dot = zip(whole, part).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        let norms = sqrt(whole.reduce(0) { $0 + $1 * $1 }) * sqrt(part.reduce(0) { $0 + $1 * $1 })
        #expect(dot / norms > 0.6, "Similarity \(dot / norms)")
    }
}
