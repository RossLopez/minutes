// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesAudio
import Testing

@Test func `a track's level is measured in tenth of a second blocks`() async throws {
    let folder = try TemporaryFolder()
    let url = folder.file("levels.caf")
    // 0.5 full scale is about −9 dBFS as a sine, then quiet, then a part block at the end.
    let loud = sine(frequency: 440, rate: 48000, frames: 48000, amplitude: 0.5)
    let quiet = sine(frequency: 440, rate: 48000, frames: 48000 + 2400, amplitude: 0.005)
    try writeCAF(loud + quiet, to: url)

    let levels = try await LevelTimeline.read(url)
    #expect(levels.decibels.count == 21)
    #expect(abs(levels.decibels[5] - -9.03) < 0.1)
    #expect(abs(levels.decibels[15] - -49.03) < 0.1)
    #expect(abs(levels.decibels[20] - -49.03) < 0.5)
}

@Test func `the level between two moments averages power, not decibels`() throws {
    let levels = LevelTimeline(decibels: [-20, -40, -60])
    let level = try #require(levels.level(from: 0, to: 0.2))
    #expect(abs(level - -22.97) < 0.1)
}

@Test func `a moment shorter than a block still gets a level`() {
    let levels = LevelTimeline(decibels: [-20, -40])
    #expect(levels.level(from: 0.15, to: 0.15) == -40)
}

@Test func `a moment outside the track has no level`() {
    let levels = LevelTimeline(decibels: [-20, -40])
    #expect(levels.level(from: 5, to: 6) == nil)
}

@Test func `the noise floor sits near the quietest of the track's sound`() {
    let speech = [Float](repeating: -20, count: 80)
    let room = [Float](repeating: -50, count: 20)
    #expect(LevelTimeline(decibels: speech + room).noiseFloor == -50)
}

@Test func `gaps in the audio don't count as the room's background`() {
    let gaps = [Float](repeating: -120, count: 50)
    let room = [Float](repeating: -50, count: 50)
    #expect(LevelTimeline(decibels: gaps + room).noiseFloor == -50)
}

@Test func `a track with no sound has no noise floor`() {
    #expect(LevelTimeline(decibels: [-120, -120]).noiseFloor == nil)
    #expect(LevelTimeline(decibels: []).noiseFloor == nil)
}
