// SPDX-License-Identifier: GPL-3.0-or-later

import AVFAudio
import Foundation
@testable import MinutesAudio
import Testing

@Test func `the fixture matches the generator`() throws {
    let expected = AudioAnalysis.makeAlignmentSignal(seconds: 2, sampleRate: 48000, amplitude: 0.1, seed: 42)
    #expect(try Fixture.samples() == expected)
}

@Test(arguments: RecordingAudioFormat.allCases)
func `encoding keeps the length and timing and then removes the CAF`(format: RecordingAudioFormat) async throws {
    let folder = try TemporaryFolder()
    let caf = folder.file("mic.caf")
    let m4a = folder.file("mic.m4a")
    let original = try Fixture.samples()
    try writeCAF(original, to: caf)

    try await TrackEncoder.encode(caf: caf, to: m4a, format: format)

    #expect(!FileManager.default.fileExists(atPath: caf.path))
    #expect(!FileManager.default.fileExists(atPath: folder.file("mic.partial.m4a").path))

    let encoded = try AudioAnalysis.read(m4a)
    #expect(encoded.sampleRate == 48000)
    #expect(abs(encoded.samples.count - original.count) <= 2400)

    let leak = try #require(AudioAnalysis.measureLeak(
        mic: encoded.samples[...],
        system: original[...],
        sampleRate: 48000,
        maxLagSeconds: 0.1,
    ))
    #expect(abs(leak.lagMilliseconds) < 1, "encoded audio moved by \(leak.lagMilliseconds) ms")
    // Noise is the hardest thing for AAC, so this is low for AAC even when timing is perfect.
    #expect(leak.correlation > (format == .aac ? 0.7 : 0.999))
}

@Test func `ALAC is lossless at 24 bits`() async throws {
    let folder = try TemporaryFolder()
    let caf = folder.file("mic.caf")
    let m4a = folder.file("mic.m4a")
    let original = try Fixture.samples()
    try writeCAF(original, to: caf)

    try await TrackEncoder.encode(caf: caf, to: m4a, format: .alac)

    let encoded = try AudioAnalysis.read(m4a).samples
    #expect(encoded.count == original.count)
    let worst = zip(encoded, original).map { abs($0 - $1) }.max() ?? 1
    #expect(worst < 1e-6)
}

@Test func `a crash-truncated CAF encodes`() async throws {
    let folder = try TemporaryFolder()
    let source = folder.file("source.caf")
    try writeCAF(Fixture.samples(), to: source)
    let bytes = try Data(contentsOf: source)
    let caf = folder.file("mic.caf")
    // Cut off partway through a sample.
    try bytes.prefix(CAFTrackWriter.headerSize + 4 * 48000 + 2).write(to: caf)
    let m4a = folder.file("mic.m4a")

    try await TrackEncoder.encode(caf: caf, to: m4a, format: .aac)

    let encoded = try AudioAnalysis.read(m4a).samples
    #expect(abs(encoded.count - 48000) <= 2400)
}

@Test func `an empty track fails and the CAF stays`() async throws {
    let folder = try TemporaryFolder()
    let caf = folder.file("mic.caf")
    try writeCAF([], to: caf)
    let m4a = folder.file("mic.m4a")

    await #expect(throws: TrackEncoder.EncoderError.emptyTrack) {
        try await TrackEncoder.encode(caf: caf, to: m4a, format: .aac)
    }
    #expect(FileManager.default.fileExists(atPath: caf.path))
    #expect(!FileManager.default.fileExists(atPath: m4a.path))
}

@Test func `an interrupted encode can run again`() async throws {
    let folder = try TemporaryFolder()
    let caf = folder.file("mic.caf")
    try writeCAF(Fixture.samples(), to: caf)
    let m4a = folder.file("mic.m4a")
    try Data("left by a crash".utf8).write(to: folder.file("mic.partial.m4a"))

    try await TrackEncoder.encode(caf: caf, to: m4a, format: .aac)

    #expect(!FileManager.default.fileExists(atPath: folder.file("mic.partial.m4a").path))
    #expect(try AudioAnalysis.read(m4a).samples.count > 90000)
}
