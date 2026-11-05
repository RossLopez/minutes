// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import MinutesAudio
import Testing

/// A controllable clock, so session tests don't depend on real time.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UInt64 = 10_000_000_000

    var nanos: UInt64 {
        lock.withLock { current }
    }

    func advance(toFrame frame: Int) {
        lock.withLock { current = 10_000_000_000 + UInt64(Double(frame) / 48000 * 1_000_000_000) }
    }
}

private final class FakeSource: AudioCaptureSource, @unchecked Sendable {
    enum Failure: Error {
        case refused
    }

    private let lock = NSLock()
    private let clock: FakeClock
    private let rate: Double
    private let startError: Error?
    private var ring: AudioRing?
    private var events: (@Sendable (CaptureEvent) -> Void)?
    private(set) var stopped = false

    init(clock: FakeClock, rate: Double = 48000, startError: Error? = nil) {
        self.clock = clock
        self.rate = rate
        self.startError = startError
    }

    func start(writingTo ring: AudioRing, events: @escaping @Sendable (CaptureEvent) -> Void) throws {
        if let startError {
            throw startError
        }
        ring.setSampleRate(rate)
        lock.withLock {
            self.ring = ring
            self.events = events
        }
    }

    func stop() {
        lock.withLock {
            ring = nil
            stopped = true
        }
    }

    /// Delivers samples timed at a position on the session's timeline.
    func deliver(_ samples: [Float], atFrame frame: Int) {
        let nanos = 10_000_000_000 + UInt64(Double(frame) / 48000 * 1_000_000_000)
        lock.withLock { ring }?.write(samples, hostTime: HostClock.hostTime(fromNanos: nanos))
    }

    func send(_ event: CaptureEvent) {
        lock.withLock { events }?(event)
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(RecordingTrack, CaptureEvent)] = []

    var events: [(RecordingTrack, CaptureEvent)] {
        lock.withLock { stored }
    }

    func add(_ track: RecordingTrack, _ event: CaptureEvent) {
        lock.withLock { stored.append((track, event)) }
    }
}

private struct Harness {
    let folder: TemporaryFolder
    let clock = FakeClock()
    let log = EventLog()
    let mic: FakeSource
    let system: FakeSource
    let session: RecordingSession

    var micURL: URL {
        folder.file("mic.caf")
    }

    var systemURL: URL {
        folder.file("system.caf")
    }

    init(micRate: Double = 48000, micError: Error? = nil, systemError: Error? = nil) throws {
        let folder = try TemporaryFolder()
        let clock = clock
        let log = log
        self.folder = folder
        mic = FakeSource(clock: clock, rate: micRate, startError: micError)
        system = FakeSource(clock: clock, startError: systemError)
        session = RecordingSession(
            micSource: mic,
            systemSource: system,
            micURL: folder.file("mic.caf"),
            systemURL: folder.file("system.caf"),
            events: { log.add($0, $1) },
            nowNanos: { clock.nanos },
        )
    }
}

@Test func `both tracks land on one timeline and end together`() async throws {
    let harness = try Harness()
    try await harness.session.start()

    // Mic audio begins 100 ms in, system audio 300 ms in.
    harness.mic.deliver([Float](repeating: 0.5, count: 4800), atFrame: 4800)
    harness.system.deliver([Float](repeating: 0.25, count: 4800), atFrame: 14400)
    harness.clock.advance(toFrame: 48000)
    let summary = await harness.session.stop()

    #expect(summary.durationSeconds == 1)
    #expect(summary.mic.frames == 48000)
    #expect(summary.system.frames == 48000)
    #expect(summary.mic.firstAudioSeconds == 0.1)
    #expect(summary.system.firstAudioSeconds == 0.3)

    let mic = try AudioAnalysis.read(harness.micURL).samples
    let system = try AudioAnalysis.read(harness.systemURL).samples
    #expect(mic.count == 48000)
    #expect(system.count == 48000)
    #expect(mic[4799] == 0)
    #expect(mic[4800] == 0.5)
    #expect(mic[9599] == 0.5)
    #expect(mic[9600] == 0)
    #expect(system[14399] == 0)
    #expect(system[14400] == 0.25)
}

@Test func `a stall in one track is recorded as a gap and the other is untouched`() async throws {
    let harness = try Harness()
    try await harness.session.start()

    harness.mic.deliver([Float](repeating: 0.5, count: 4800), atFrame: 0)
    harness.system.deliver([Float](repeating: 0.25, count: 96000), atFrame: 0)
    // The mic returns one second after it stopped delivering.
    harness.mic.deliver([Float](repeating: 0.5, count: 4800), atFrame: 52800)
    harness.clock.advance(toFrame: 96000)
    let summary = await harness.session.stop()

    #expect(summary.mic.gaps == [RecordingGap(startSeconds: 0.1, durationSeconds: 1)])
    #expect(summary.system.gaps.isEmpty)

    let mic = try AudioAnalysis.read(harness.micURL).samples
    #expect(mic[52799] == 0)
    #expect(mic[52800] == 0.5)
}

@Test func `a short pause isn't reported as a gap`() async throws {
    let harness = try Harness()
    try await harness.session.start()
    harness.mic.deliver([Float](repeating: 0.5, count: 4800), atFrame: 0)
    harness.mic.deliver([Float](repeating: 0.5, count: 4800), atFrame: 4800 + 1000)
    harness.clock.advance(toFrame: 48000)
    let summary = await harness.session.stop()
    #expect(summary.mic.gaps.isEmpty)
}

@Test func `a mic at another rate still ends up at 48 kHz in the right place`() async throws {
    let harness = try Harness(micRate: 24000)
    try await harness.session.start()
    harness.mic.deliver(sine(frequency: 1000, rate: 24000, frames: 12000), atFrame: 24000)
    harness.clock.advance(toFrame: 96000)
    let summary = await harness.session.stop()

    #expect(summary.mic.frames == 96000)
    let mic = try AudioAnalysis.read(harness.micURL).samples
    #expect(mic.count == 96000)
    #expect(mic[..<24000].allSatisfy { $0 == 0 })
    // The tone sits in the half second after the 500 ms mark.
    let tone = AudioAnalysis.level(of: Array(mic[30000 ..< 44000]), sampleRate: 48000)
    #expect(tone.peak > 0.2)
    #expect(AudioAnalysis.level(of: Array(mic[60000...]), sampleRate: 48000).peak == 0)
}

@Test func `if the system track fails to start, the mic keeps recording`() async throws {
    let harness = try Harness(systemError: FakeSource.Failure.refused)
    try await harness.session.start()
    harness.mic.deliver([Float](repeating: 0.5, count: 4800), atFrame: 0)
    harness.clock.advance(toFrame: 4800)
    let summary = await harness.session.stop()

    #expect(summary.mic.frames == 4800)
    #expect(summary.mic.failure == nil)
    #expect(summary.system.frames == 0)
    #expect(summary.system.failure != nil)
    #expect(!FileManager.default.fileExists(atPath: harness.systemURL.path))
    #expect(harness.log.events.contains { $0.0 == .system })
}

@Test func `if the mic fails to start, system audio keeps recording`() async throws {
    let harness = try Harness(micError: FakeSource.Failure.refused)
    try await harness.session.start()
    harness.system.deliver([Float](repeating: 0.5, count: 4800), atFrame: 0)
    harness.clock.advance(toFrame: 4800)
    let summary = await harness.session.stop()

    #expect(summary.system.frames == 4800)
    #expect(summary.mic.failure != nil)
    #expect(!FileManager.default.fileExists(atPath: harness.micURL.path))
}

@Test func `starting fails only when neither track can run`() async throws {
    let harness = try Harness(micError: FakeSource.Failure.refused, systemError: FakeSource.Failure.refused)
    await #expect(throws: RecordingSession.SessionError.self) {
        try await harness.session.start()
    }
}

@Test func `a track that never delivers still has the full length, all silent`() async throws {
    let harness = try Harness()
    try await harness.session.start()
    harness.mic.deliver([Float](repeating: 0.5, count: 48000), atFrame: 0)
    harness.clock.advance(toFrame: 48000)
    let summary = await harness.session.stop()

    #expect(summary.system.frames == 48000)
    #expect(summary.system.firstAudioSeconds == nil)
    #expect(try AudioAnalysis.read(harness.systemURL).samples.allSatisfy { $0 == 0 })
}

@Test func `source events reach the handler with their track`() async throws {
    let harness = try Harness()
    try await harness.session.start()
    harness.mic.send(.restarted(deviceName: "AirPods"))
    harness.clock.advance(toFrame: 480)
    _ = await harness.session.stop()

    let event = try #require(harness.log.events.first)
    #expect(event.0 == .mic)
    #expect(event.1 == .restarted(deviceName: "AirPods"))
}

@Test func `levels report each track's peak since the last read`() async throws {
    let harness = try Harness()
    try await harness.session.start()
    harness.mic.deliver([0.5, -0.75], atFrame: 0)
    harness.system.deliver([0.25], atFrame: 0)
    #expect(harness.session.takeLevels() == TrackLevels(mic: 0.75, system: 0.25))
    #expect(harness.session.takeLevels() == TrackLevels(mic: 0, system: 0))
    harness.clock.advance(toFrame: 480)
    _ = await harness.session.stop()
}

@Test func `both sources are stopped`() async throws {
    let harness = try Harness()
    try await harness.session.start()
    harness.clock.advance(toFrame: 480)
    _ = await harness.session.stop()
    #expect(harness.mic.stopped)
    #expect(harness.system.stopped)
}
