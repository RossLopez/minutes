// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Foundation
@testable import MinutesAudio
import Testing

/// Runs the cleaner on made-up tracks, and returns its result and output.
private func clean(
    mic: [Float],
    system: [Float]?,
    format: RecordingAudioFormat = .alac,
) async throws -> (outcome: MicCleaner.Outcome, samples: [Float]) {
    let folder = try TemporaryFolder()
    let micURL = folder.file("mic.caf")
    try writeCAF(mic, to: micURL)
    var systemURL: URL?
    if let system {
        systemURL = folder.file("system.caf")
        try writeCAF(system, to: #require(systemURL))
    }
    let output = folder.file("cleaned.m4a")
    let outcome = try await MicCleaner.clean(mic: micURL, system: systemURL, output: output, format: format)
    return try (outcome, AudioAnalysis.read(output).samples)
}

@Test func `an echo drops by at least 15 dB once the filter has settled`() async throws {
    let system = EchoSignals.speech(seconds: 40, seed: 11)
    let echo = EchoSignals.convolve(system, with: EchoSignals.room(gain: 0.09))
    let result = try await clean(mic: echo, system: system)

    let before = EchoSignals.level(echo, from: 15, to: 40)
    let after = EchoSignals.level(result.samples, from: 15, to: 40)
    #expect(before - after >= 15, "Removed \(before - after) dB")
    guard case let .cleaned(found) = result.outcome else {
        Issue.record("Expected the echo to be found")
        return
    }
    #expect(abs(found - -21) < 6, "Found echo at \(found) dB")
}

@Test func `a voice over an echo keeps its level`() async throws {
    let system = EchoSignals.speech(seconds: 40, seed: 11)
    let voice = EchoSignals.speech(seconds: 40, seed: 23, amplitude: 0.1)
    let echo = EchoSignals.convolve(system, with: EchoSignals.room(gain: 0.09))
    let result = try await clean(mic: EchoSignals.add(voice, echo), system: system)

    let kept = EchoSignals.gain(of: voice, in: result.samples, from: 15, to: 40)
    #expect(abs(kept) <= 1, "The voice changed by \(kept) dB")
    let before = EchoSignals.gain(of: echo, in: EchoSignals.add(voice, echo), from: 15, to: 40)
    let after = EchoSignals.gain(of: echo, in: result.samples, from: 15, to: 40)
    #expect(before - after >= 10, "Removed \(before - after) dB under double talk")
}

@Test func `an echo that appears after a voice has been talking alone still gets found`() async throws {
    let silence = [Float](repeating: 0, count: 20 * EchoSignals.rate)
    let voice = EchoSignals.speech(seconds: 60, seed: 23, amplitude: 0.1)
    let system = silence + EchoSignals.speech(seconds: 40, seed: 11)
    let echo = EchoSignals.convolve(system, with: EchoSignals.room(gain: 0.09))
    let result = try await clean(mic: EchoSignals.add(voice, echo), system: system)
    let kept = EchoSignals.gain(of: voice, in: result.samples, from: 5, to: 18)
    #expect(abs(kept) <= 0.5, "The voice changed by \(kept) dB with no echo around")
    let removed = EchoSignals.gain(of: echo, in: EchoSignals.add(voice, echo), from: 40, to: 60)
        - EchoSignals.gain(of: echo, in: result.samples, from: 40, to: 60)
    #expect(removed >= 10, "Removed \(removed) dB")
}

@Test func `a voice on its own isn't touched and comes back as an exact copy`() async throws {
    let voice = EchoSignals.speech(seconds: 15, seed: 23, amplitude: 0.1)
    let system = EchoSignals.speech(seconds: 15, seed: 11)
    let folder = try TemporaryFolder()
    let micURL = folder.file("mic.m4a")
    let systemURL = folder.file("system.m4a")
    try writeM4A(voice, to: micURL)
    try writeM4A(system, to: systemURL)
    let output = folder.file("cleaned.m4a")
    let outcome = try await MicCleaner.clean(mic: micURL, system: systemURL, output: output, format: .aac)
    #expect(outcome == .copied)
    #expect(try Data(contentsOf: output) == Data(contentsOf: micURL))
}

@Test func `no system track makes a copy`() async throws {
    let voice = EchoSignals.speech(seconds: 3, seed: 23)
    let result = try await clean(mic: voice, system: nil)
    #expect(result.outcome == .copied)
    #expect(result.samples == voice)
}

@Test func `a silent system track makes a copy`() async throws {
    let voice = EchoSignals.speech(seconds: 3, seed: 23)
    let result = try await clean(mic: voice, system: [Float](repeating: 0, count: voice.count))
    #expect(result.outcome == .copied)
}

@Test func `a silent mic with a loud system track makes a copy`() async throws {
    let silence = [Float](repeating: 0, count: 5 * EchoSignals.rate)
    let result = try await clean(mic: silence, system: EchoSignals.speech(seconds: 5, seed: 11))
    #expect(result.outcome == .copied)
}

@Test func `slow clock drift doesn't stop the filter working`() async throws {
    let system = EchoSignals.speech(seconds: 90, seed: 11)
    // Over 4× what was measured here. Removal falls off beyond this: see docs/NOTES.md.
    let echo = EchoSignals.drifted(
        EchoSignals.convolve(system, with: EchoSignals.room(gain: 0.09)),
        partsPerMillion: 10,
    )
    let result = try await clean(mic: echo, system: system)
    let before = EchoSignals.level(echo, from: 60, to: 88)
    let after = EchoSignals.level(result.samples, from: 60, to: 88)
    #expect(before - after >= 15, "Removed \(before - after) dB")
}

@Test func `a sudden shift in timing recovers`() async throws {
    let system = EchoSignals.speech(seconds: 60, seed: 11)
    // The timeline pads or drops about 5 ms at a time to stay in step.
    let echo = EchoSignals.convolve(system, with: EchoSignals.room(gain: 0.09))
    let shift = 240
    let split = 30 * EchoSignals.rate
    let shifted = Array(echo[0 ..< split]) + [Float](repeating: 0, count: shift) +
        Array(echo[split ..< echo.count - shift])
    let result = try await clean(mic: shifted, system: system)
    let before = EchoSignals.level(shifted, from: 45, to: 60)
    let after = EchoSignals.level(result.samples, from: 45, to: 60)
    #expect(before - after >= 12, "Removed \(before - after) dB")
}

@Test func `the output lines up with the input to the sample`() async throws {
    let system = EchoSignals.speech(seconds: 30, seed: 11)
    let voice = EchoSignals.speech(seconds: 30, seed: 23, amplitude: 0.1)
    let echo = EchoSignals.convolve(system, with: EchoSignals.room(gain: 0.09))
    let result = try await clean(mic: EchoSignals.add(voice, echo), system: system)
    #expect(result.samples.count == voice.count)
    let measure = try #require(AudioAnalysis.measureLeak(
        mic: result.samples[10 * EchoSignals.rate ..< 29 * EchoSignals.rate],
        system: voice[10 * EchoSignals.rate ..< 29 * EchoSignals.rate],
        sampleRate: Double(EchoSignals.rate),
        maxLagSeconds: 0.1,
    ))
    #expect(abs(measure.lagMilliseconds) < 0.05, "Off by \(measure.lagMilliseconds) ms")
}

@Test func `aac output keeps the track's length`() async throws {
    let system = EchoSignals.speech(seconds: 10, seed: 11)
    let echo = EchoSignals.convolve(system, with: EchoSignals.room(gain: 0.09))
    let result = try await clean(mic: echo, system: system, format: .aac)
    #expect(abs(result.samples.count - echo.count) <= 2400)
}

@Test func `a shorter system track is treated as silence after it ends`() async throws {
    let system = EchoSignals.speech(seconds: 5, seed: 11)
    let voice = EchoSignals.speech(seconds: 8, seed: 23, amplitude: 0.1)
    let result = try await clean(mic: voice, system: system)
    #expect(result.samples.count == voice.count)
}

@Test func `cancelling stops the work and leaves no output`() async throws {
    let folder = try TemporaryFolder()
    let micURL = folder.file("mic.caf")
    let systemURL = folder.file("system.caf")
    let length = 600 * EchoSignals.rate
    try writeCAF([Float](repeating: 0.01, count: length), to: micURL)
    try writeCAF([Float](repeating: 0.01, count: length), to: systemURL)
    let output = folder.file("cleaned.m4a")
    let task = Task {
        try await MicCleaner.clean(mic: micURL, system: systemURL, output: output, format: .aac)
    }
    task.cancel()
    await #expect(throws: CancellationError.self) {
        try await task.value
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
}

private func writeM4A(_ samples: [Float], to url: URL) throws {
    let caf = url.deletingPathExtension().appendingPathExtension("caf")
    try writeCAF(samples, to: caf)
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(EchoSignals.rate),
        channels: 1,
        interleaved: false,
    ))
    let file = try AVAudioFile(
        forWriting: url,
        settings: TrackEncoder.settings(for: .aac),
        commonFormat: .pcmFormatFloat32,
        interleaved: false,
    )
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer {
        buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
    }
    try file.write(from: buffer)
    file.close()
    try FileManager.default.removeItem(at: caf)
}
