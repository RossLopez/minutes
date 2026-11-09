// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import MinutesAudio
import Testing

private func readRaw(_ url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

/// Upward zero crossings per second, which is the frequency of a clean sine.
private func frequency(of samples: ArraySlice<Float>, rate: Double) -> Double {
    let crossings = zip(samples, samples.dropFirst()).count { $0 < 0 && $1 >= 0 }
    return Double(crossings) / (Double(samples.count) / rate)
}

@Test func `a track comes out at the new rate with the same length and pitch`() throws {
    let folder = try TemporaryFolder()
    let input = folder.file("tone.caf")
    try writeCAF(sine(frequency: 440, rate: 48000, frames: 3 * 48000), to: input)

    let output = folder.file("tone.raw")
    let written = try TrackResampler.writeRawMono(from: input, to: output, sampleRate: 16000)
    let samples = try readRaw(output)

    #expect(written == samples.count)
    #expect(abs(samples.count - 3 * 16000) <= 64)
    #expect(abs(frequency(of: samples[16000 ..< 32000], rate: 16000) - 440) <= 2)
}

@Test func `a track longer than one block keeps every second`() throws {
    let folder = try TemporaryFolder()
    let input = folder.file("long.caf")
    // About 25 of the resampler's blocks.
    try writeCAF(sine(frequency: 1000, rate: 48000, frames: 8 * 48000), to: input)

    let output = folder.file("long.raw")
    try TrackResampler.writeRawMono(from: input, to: output, sampleRate: 16000)
    let samples = try readRaw(output)

    #expect(abs(samples.count - 8 * 16000) <= 64)
    #expect(abs(frequency(of: samples[(7 * 16000 - 8000) ..< (7 * 16000)], rate: 16000) - 1000) <= 4)
}

@Test func `an empty track writes an empty file`() throws {
    let folder = try TemporaryFolder()
    let input = folder.file("empty.caf")
    try writeCAF([], to: input)

    let output = folder.file("empty.raw")
    #expect(try TrackResampler.writeRawMono(from: input, to: output, sampleRate: 16000) == 0)
    #expect(try readRaw(output).isEmpty)
}

@Test func `an unreadable track throws and leaves nothing behind`() throws {
    let folder = try TemporaryFolder()
    let input = folder.file("broken.m4a")
    try Data("not audio".utf8).write(to: input)
    let output = folder.file("broken.raw")
    #expect(throws: (any Error).self) {
        try TrackResampler.writeRawMono(from: input, to: output, sampleRate: 16000)
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
}
