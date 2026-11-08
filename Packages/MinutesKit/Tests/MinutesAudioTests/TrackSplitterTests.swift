// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
@testable import MinutesAudio
import Testing

/// Sound with silent stretches at the given seconds, each half a second long.
private func track(seconds: Int, pausesAt pauses: [Double]) -> [Float] {
    var samples = EchoSignals.speech(seconds: Double(seconds), seed: 5)
    // The test signal has its own pauses, so make everything else audible first.
    for index in samples.indices {
        samples[index] = 0.1 * sin(Float(index) * 0.05) + samples[index]
    }
    for pause in pauses {
        let start = Int(pause * Double(EchoSignals.rate))
        for index in start ..< min(start + EchoSignals.rate / 2, samples.count) {
            samples[index] = 0
        }
    }
    return samples
}

private func pieces(of samples: [Float], longest: Double, search: Double, folder: TemporaryFolder) throws
    -> [(piece: TrackSplitter.Piece, samples: [Float])]
{
    let url = folder.file("track.caf")
    try writeCAF(samples, to: url)
    let splitter = try TrackSplitter(url: url, longestPieceSeconds: longest, searchSeconds: search)
    var result: [(TrackSplitter.Piece, [Float])] = []
    var index = 0
    while let piece = try splitter.next(writingTo: folder.file("piece-\(index).caf")) {
        try result.append((piece, AudioAnalysis.read(piece.url).samples))
        index += 1
    }
    return result
}

@Test func `a short track comes back as itself`() throws {
    let folder = try TemporaryFolder()
    let result = try pieces(of: track(seconds: 10, pausesAt: []), longest: 20, search: 5, folder: folder)
    #expect(result.count == 1)
    #expect(result[0].piece.url == folder.file("track.caf"))
    #expect(result[0].piece.startSeconds == 0)
    #expect(abs(result[0].piece.durationSeconds - 10) < 0.001)
}

@Test func `a track barely over the limit stays whole`() throws {
    let folder = try TemporaryFolder()
    let result = try pieces(of: track(seconds: 23, pausesAt: []), longest: 20, search: 5, folder: folder)
    #expect(result.count == 1)
}

@Test func `pieces put back together are the original, sample for sample`() throws {
    let folder = try TemporaryFolder()
    let samples = track(seconds: 65, pausesAt: [17, 36])
    let result = try pieces(of: samples, longest: 20, search: 5, folder: folder)
    #expect(result.count > 1)
    #expect(result.flatMap(\.samples) == samples)
}

@Test func `cuts land in the pauses`() throws {
    let folder = try TemporaryFolder()
    let samples = track(seconds: 65, pausesAt: [17, 35])
    let result = try pieces(of: samples, longest: 20, search: 5, folder: folder)
    let cuts = result.dropFirst().map(\.piece.startSeconds)
    #expect(cuts.count >= 2)
    #expect(cuts[0] >= 17 && cuts[0] <= 17.5, "First cut at \(cuts[0])")
    #expect(cuts[1] >= 35 && cuts[1] <= 35.5, "Second cut at \(cuts[1])")
}

@Test func `piece start times add up`() throws {
    let folder = try TemporaryFolder()
    let result = try pieces(of: track(seconds: 65, pausesAt: [17, 36]), longest: 20, search: 5, folder: folder)
    var expected = 0.0
    for (piece, samples) in result {
        #expect(abs(piece.startSeconds - expected) < 0.001)
        #expect(abs(piece.durationSeconds - Double(samples.count) / Double(EchoSignals.rate)) < 0.001)
        expected += piece.durationSeconds
    }
}

@Test func `no piece runs past the limit`() throws {
    let folder = try TemporaryFolder()
    let result = try pieces(of: track(seconds: 65, pausesAt: []), longest: 20, search: 5, folder: folder)
    #expect(result.allSatisfy { $0.piece.durationSeconds <= 20.001 })
}

@Test func `an exact multiple of the limit ends cleanly`() throws {
    let folder = try TemporaryFolder()
    let samples = track(seconds: 40, pausesAt: [])
    let result = try pieces(of: samples, longest: 20, search: 5, folder: folder)
    #expect(result.flatMap(\.samples) == samples)
    #expect(result.allSatisfy { !$0.samples.isEmpty })
}
