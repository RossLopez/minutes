// SPDX-License-Identifier: GPL-3.0-or-later

import AVFAudio
import Foundation
@testable import MinutesAudio
import Testing

@Test func `a finished file reads back exactly through CoreAudio`() throws {
    let folder = try TemporaryFolder()
    let url = folder.file("track.caf")
    let samples = sine(frequency: 440, rate: 48000, frames: 4800)
    try writeCAF(samples, to: url)

    let file = try AVAudioFile(forReading: url)
    #expect(file.fileFormat.sampleRate == 48000)
    #expect(file.fileFormat.channelCount == 1)
    #expect(file.length == 4800)
    #expect(try AudioAnalysis.read(url).samples == samples)
}

@Test func `the header is the size the frame count assumes`() {
    #expect(CAFTrackWriter.header().count == CAFTrackWriter.headerSize)
}

@Test func `a file left open, as in a crash, is still readable`() throws {
    let folder = try TemporaryFolder()
    let url = folder.file("track.caf")
    let samples = sine(frequency: 440, rate: 48000, frames: 4800)
    let writer = try CAFTrackWriter(url: url)
    try samples.withUnsafeBufferPointer { try writer.append($0) }

    #expect(try AudioAnalysis.read(url).samples == samples)
    writer.close()
}

@Test func `a file cut off anywhere past the header reads as the whole frames it holds`() throws {
    let folder = try TemporaryFolder()
    let source = folder.file("source.caf")
    let samples = sine(frequency: 440, rate: 48000, frames: 480)
    try writeCAF(samples, to: source)
    let bytes = try Data(contentsOf: source)

    // Every byte offset across the first few frames, then samples through the rest.
    let offsets = Array(CAFTrackWriter.headerSize ..< CAFTrackWriter.headerSize + 32)
        + Array(stride(from: CAFTrackWriter.headerSize + 32, to: bytes.count, by: 97))
    for offset in offsets {
        let url = folder.file("cut-\(offset).caf")
        try bytes.prefix(offset).write(to: url)
        let wholeFrames = (offset - CAFTrackWriter.headerSize) / MemoryLayout<Float>.size

        #expect(try CAFTrackWriter.frameCount(ofFileAt: url) == wholeFrames)
        let read = try AudioAnalysis.read(url).samples
        #expect(read == Array(samples.prefix(wholeFrames)), "cut at byte \(offset)")
    }
}

@Test func `a file cut off inside the header counts as empty`() throws {
    let folder = try TemporaryFolder()
    let source = folder.file("source.caf")
    try writeCAF([0.5, 0.5], to: source)
    let bytes = try Data(contentsOf: source)

    for offset in 0 ..< CAFTrackWriter.headerSize {
        let url = folder.file("cut-\(offset).caf")
        try bytes.prefix(offset).write(to: url)
        #expect(try CAFTrackWriter.frameCount(ofFileAt: url) == 0)
    }
}

@Test func `silence adds zeros, even past one internal buffer`() throws {
    let folder = try TemporaryFolder()
    let url = folder.file("track.caf")
    let writer = try CAFTrackWriter(url: url)
    try writer.appendSilence(frames: 100_000)
    writer.close()

    #expect(writer.framesWritten == 100_000)
    let samples = try AudioAnalysis.read(url).samples
    #expect(samples.count == 100_000)
    #expect(samples.allSatisfy { $0 == 0 })
}

@Test func `an existing file is never overwritten`() throws {
    let folder = try TemporaryFolder()
    let url = folder.file("track.caf")
    try writeCAF([0.5], to: url)

    #expect(throws: CAFTrackWriter.WriterError.open(errno: EEXIST)) {
        _ = try CAFTrackWriter(url: url)
    }
    #expect(try AudioAnalysis.read(url).samples == [0.5])
}
