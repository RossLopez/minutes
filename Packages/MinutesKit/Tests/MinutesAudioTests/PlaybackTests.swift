// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
@testable import MinutesAudio
import Testing

private let sampleRate = 48000.0
private let micFrequency = 1000.0
private let systemFrequency = 3000.0

/// Silence, then a tone starting at `onset` seconds. Each track gets its own frequency, so a mix
/// can show which tracks reached it and when.
private func encodedTone(
    frequency: Double,
    onset: Double = 0.5,
    seconds: Double = 2,
    in folder: TemporaryFolder,
    name: String,
) async throws -> URL {
    let total = Int(seconds * sampleRate)
    let silent = Int(onset * sampleRate)
    let tone = sine(frequency: frequency, rate: sampleRate, frames: total - silent)
    let caf = folder.file("\(name).caf")
    let m4a = folder.file("\(name).m4a")
    try writeCAF([Float](repeating: 0, count: silent) + tone, to: caf)
    try await TrackEncoder.encode(caf: caf, to: m4a, format: .alac)
    return m4a
}

/// Renders the composition through the mix, the way playback would, without audio hardware.
@MainActor
private func render(_ composition: PlaybackComposition, muted: Set<PlaybackTrack> = []) async throws -> [Float] {
    let reader = try AVAssetReader(asset: composition.asset)
    let output = AVAssetReaderAudioMixOutput(
        audioTracks: composition.asset.tracks,
        audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ],
    )
    output.audioMix = composition.audioMix(muted: muted)
    let provider = reader.outputProvider(for: output)
    try reader.start()

    var samples: [Float] = []
    while let buffer = try await provider.next() {
        samples += buffer.withUnsafeSampleBuffer { sampleBuffer -> [Float] in
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                return []
            }
            let bytes = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes { pointer in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: pointer.baseAddress!)
            }
            return chunk
        }
    }
    return samples
}

/// How much of one frequency a stretch of audio holds (Goertzel), scaled so a full-scale sine reads 1.
private func strength(of frequency: Double, in samples: ArraySlice<Float>) -> Double {
    let coefficient = 2 * cos(2 * .pi * frequency / sampleRate)
    var previous = 0.0
    var beforePrevious = 0.0
    for sample in samples {
        let current = Double(sample) + coefficient * previous - beforePrevious
        beforePrevious = previous
        previous = current
    }
    let power = previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious
    return 2 * power.squareRoot() / Double(max(samples.count, 1))
}

/// The time the frequency first appears, to within 2 ms.
private func onset(of frequency: Double, in samples: [Float]) -> Double? {
    let window = Int(sampleRate * 0.004)
    let hop = Int(sampleRate * 0.002)
    for start in stride(from: 0, to: samples.count - window, by: hop)
        where strength(of: frequency, in: samples[start ..< start + window]) > 0.05
    {
        return Double(start) / sampleRate
    }
    return nil
}

/// The second half of the audio, where both tones have started.
private func tail(_ samples: [Float]) -> ArraySlice<Float> {
    samples[(samples.count / 2)...]
}

@Test @MainActor func `both tracks play together when nothing is muted`() async throws {
    let folder = try TemporaryFolder()
    let composition = try await PlaybackComposition.make(
        mic: encodedTone(frequency: micFrequency, in: folder, name: "mic"),
        system: encodedTone(frequency: systemFrequency, in: folder, name: "system"),
    )

    let samples = try await render(composition)

    #expect(strength(of: micFrequency, in: tail(samples)) > 0.05)
    #expect(strength(of: systemFrequency, in: tail(samples)) > 0.05)
    #expect(composition.availableTracks == [.mic, .system])
}

@Test(arguments: [
    (PlaybackTrack.mic, micFrequency, systemFrequency),
    (PlaybackTrack.system, systemFrequency, micFrequency),
])
@MainActor
func `muting a track silences it and leaves the other`(
    muted: PlaybackTrack,
    silenced: Double,
    kept: Double,
) async throws {
    let folder = try TemporaryFolder()
    let composition = try await PlaybackComposition.make(
        mic: encodedTone(frequency: micFrequency, in: folder, name: "mic"),
        system: encodedTone(frequency: systemFrequency, in: folder, name: "system"),
    )

    let samples = try await render(composition, muted: [muted])

    #expect(strength(of: silenced, in: tail(samples)) < 0.001)
    #expect(strength(of: kept, in: tail(samples)) > 0.05)
}

@Test @MainActor func `the tracks stay aligned in the mix`() async throws {
    let folder = try TemporaryFolder()
    let composition = try await PlaybackComposition.make(
        mic: encodedTone(frequency: micFrequency, onset: 0.5, in: folder, name: "mic"),
        system: encodedTone(frequency: systemFrequency, onset: 0.5, in: folder, name: "system"),
    )

    let samples = try await render(composition)

    let micOnset = try #require(onset(of: micFrequency, in: samples))
    let systemOnset = try #require(onset(of: systemFrequency, in: samples))
    #expect(abs(micOnset - systemOnset) <= 0.005, "mic \(micOnset) s, system \(systemOnset) s")
    #expect(abs(micOnset - 0.5) <= 0.01, "mic started at \(micOnset) s")
}

@Test @MainActor func `a tone heard mid-track is at its true time, not moved by the other track`() async throws {
    let folder = try TemporaryFolder()
    let composition = try await PlaybackComposition.make(
        mic: encodedTone(frequency: micFrequency, onset: 0.25, in: folder, name: "mic"),
        system: encodedTone(frequency: systemFrequency, onset: 1.25, in: folder, name: "system"),
    )

    let samples = try await render(composition)

    let micOnset = try #require(onset(of: micFrequency, in: samples))
    let systemOnset = try #require(onset(of: systemFrequency, in: samples))
    #expect(abs(systemOnset - micOnset - 1.0) <= 0.005)
}

@Test @MainActor func `a meeting with only one track still plays`() async throws {
    let folder = try TemporaryFolder()
    let composition = try await PlaybackComposition.make(
        mic: nil,
        system: encodedTone(frequency: systemFrequency, in: folder, name: "system"),
    )

    let samples = try await render(composition)

    #expect(composition.availableTracks == [.system])
    #expect(strength(of: systemFrequency, in: tail(samples)) > 0.05)
}

@Test @MainActor func `a missing or damaged track is skipped`() async throws {
    let folder = try TemporaryFolder()
    let damaged = folder.file("damaged.m4a")
    try Data("not audio".utf8).write(to: damaged)

    let composition = try await PlaybackComposition.make(
        mic: damaged,
        system: encodedTone(frequency: systemFrequency, in: folder, name: "system"),
    )
    #expect(composition.availableTracks == [.system])

    let other = try await PlaybackComposition.make(
        mic: encodedTone(frequency: micFrequency, in: folder, name: "mic"),
        system: folder.file("gone.m4a"),
    )
    #expect(other.availableTracks == [.mic])
}

@Test @MainActor func `no playable track is an error`() async throws {
    let folder = try TemporaryFolder()
    await #expect(throws: PlaybackError.noAudio) {
        try await PlaybackComposition.make(mic: nil, system: folder.file("gone.m4a"))
    }
}

@Test @MainActor func `the length follows the longer track`() async throws {
    let folder = try TemporaryFolder()
    let composition = try await PlaybackComposition.make(
        mic: encodedTone(frequency: micFrequency, seconds: 1, in: folder, name: "mic"),
        system: encodedTone(frequency: systemFrequency, seconds: 2, in: folder, name: "system"),
    )

    #expect(abs(composition.asset.duration.seconds - 2) < 0.05)
}

@Test @MainActor func `the player reports its length and seeks where it's told`() async throws {
    let folder = try TemporaryFolder()
    let player = try await TwoTrackPlayer.load(
        mic: encodedTone(frequency: micFrequency, in: folder, name: "mic"),
        system: encodedTone(frequency: systemFrequency, in: folder, name: "system"),
    )
    defer { player.close() }

    #expect(abs(player.state.duration - 2) < 0.05)
    #expect(!player.state.isPlaying)
    #expect(player.availableTracks == [.mic, .system])

    player.seek(to: 1.25)
    #expect(player.state.currentTime == 1.25)
    player.seek(to: -5)
    #expect(player.state.currentTime == 0)
    player.seek(to: 500)
    #expect(player.state.currentTime == player.state.duration)
}
