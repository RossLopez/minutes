// SPDX-License-Identifier: GPL-3.0-or-later

@testable import MinutesAudio
import Testing

private func signal(seconds: Double = 2, seed: UInt64 = 7) -> [Float] {
    AudioAnalysis.makeAlignmentSignal(seconds: seconds, sampleRate: 48000, amplitude: 0.1, seed: seed)
}

@Test(arguments: [-96, 0, 480, 4800])
func `finds a known delay and level`(delayFrames: Int) throws {
    let system = signal()
    // The mic hears the system at a quarter of its level, which is −12 dB.
    let mic = (0 ..< system.count).map { index -> Float in
        let source = index - delayFrames
        return system.indices.contains(source) ? system[source] * 0.25 : 0
    }
    let leak = try #require(AudioAnalysis.measureLeak(
        mic: mic[...],
        system: system[...],
        sampleRate: 48000,
        maxLagSeconds: 0.2,
    ))
    #expect(abs(leak.lagMilliseconds - Double(delayFrames) / 48) < 0.1)
    #expect(leak.correlation > 0.95)
    #expect(abs(leak.echoDecibels - -12.04) < 0.5)
}

@Test func `unrelated signals show low correlation`() throws {
    let leak = try #require(AudioAnalysis.measureLeak(
        mic: signal(seed: 1)[...],
        system: signal(seed: 2)[...],
        sampleRate: 48000,
        maxLagSeconds: 0.05,
    ))
    #expect(abs(leak.correlation) < 0.1)
}

@Test func `silence gives no measurement`() {
    let silence = [Float](repeating: 0, count: 48000)
    #expect(AudioAnalysis
        .measureLeak(mic: silence[...], system: silence[...], sampleRate: 48000, maxLagSeconds: 0.05) == nil)
}

@Test func `too little audio gives no measurement`() {
    let short = [Float](repeating: 0.1, count: 100)
    #expect(AudioAnalysis.measureLeak(mic: short[...], system: short[...], sampleRate: 48000) == nil)
}

@Test func `levels are right for a known signal`() {
    let level = AudioAnalysis.level(of: [Float](repeating: 0.5, count: 48000), sampleRate: 48000)
    #expect(level.durationSeconds == 1)
    #expect(level.peak == 0.5)
    #expect(abs(level.rmsDecibels - -6.02) < 0.01)
}

@Test func `the same seed gives the same signal`() {
    #expect(signal(seed: 9) == signal(seed: 9))
    #expect(signal(seed: 9) != signal(seed: 10))
}
