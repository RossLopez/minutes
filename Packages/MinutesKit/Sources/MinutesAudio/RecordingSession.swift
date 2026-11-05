// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

public enum RecordingTrack: String, CaseIterable, Sendable {
    case mic
    case system
}

public struct TrackSummary: Equatable, Sendable {
    public let frames: Int
    /// Where the track's first real audio landed. Nil if it never delivered any.
    public let firstAudioSeconds: Double?
    public let gaps: [RecordingGap]
    public let droppedFrames: UInt64
    public let failure: String?
}

public struct RecordingSummary: Equatable, Sendable {
    public let durationSeconds: Double
    public let mic: TrackSummary
    public let system: TrackSummary
}

public struct TrackLevels: Equatable, Sendable {
    public let mic: Float
    public let system: Float
}

/// Records one meeting: a source and a crash-safe file per track, on one shared timeline.
///
/// If one track fails, the other keeps recording. Starting fails only when neither track can run.
public final class RecordingSession: @unchecked Sendable {
    public enum SessionError: Error, Equatable {
        case noTrackStarted(mic: String, system: String)
    }

    public typealias EventHandler = @Sendable (RecordingTrack, CaptureEvent) -> Void

    private static let logger = Logger(subsystem: "io.github.rosslopez.minutes", category: "recording")
    private static let drainInterval = DispatchTimeInterval.milliseconds(250)
    /// How many drains between full disk syncs. 20 × 250 ms is 5 seconds.
    private static let drainsPerSync = 20

    private let micSource: any AudioCaptureSource
    private let systemSource: any AudioCaptureSource
    private let micURL: URL
    private let systemURL: URL
    private let events: EventHandler
    private let nowNanos: @Sendable () -> UInt64
    private let micRing = AudioRing()
    private let systemRing = AudioRing()
    private let queue = DispatchQueue(label: "io.github.rosslopez.minutes.recording", qos: .userInitiated)

    // Used only on `queue`.
    private var micPipeline: TrackPipeline?
    private var systemPipeline: TrackPipeline?
    private var micFailure: String?
    private var systemFailure: String?
    private var timer: DispatchSourceTimer?
    private var drainCount = 0
    private var originNanos: UInt64 = 0

    public init(
        micSource: any AudioCaptureSource,
        systemSource: any AudioCaptureSource,
        micURL: URL,
        systemURL: URL,
        events: @escaping EventHandler,
        nowNanos: @escaping @Sendable () -> UInt64 = { HostClock.nowNanos() },
    ) {
        self.micSource = micSource
        self.systemSource = systemSource
        self.micURL = micURL
        self.systemURL = systemURL
        self.events = events
        self.nowNanos = nowNanos
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                continuation.resume(with: Result { try self.startOnQueue() })
            }
        }
    }

    /// The highest level per track since the last call.
    public func takeLevels() -> TrackLevels {
        TrackLevels(mic: micRing.takePeak(), system: systemRing.takePeak())
    }

    /// Stops both sources and closes both files. Each file is complete when this returns.
    public func stop() async -> RecordingSummary {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.stopOnQueue())
            }
        }
    }

    private func startOnQueue() throws {
        originNanos = nowNanos()
        (micPipeline, micFailure) = startTrack(.mic, source: micSource, url: micURL, ring: micRing)
        (systemPipeline, systemFailure) = startTrack(.system, source: systemSource, url: systemURL, ring: systemRing)

        if micPipeline == nil, systemPipeline == nil {
            throw SessionError.noTrackStarted(mic: micFailure ?? "", system: systemFailure ?? "")
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.drainInterval, repeating: Self.drainInterval)
        timer.setEventHandler { [weak self] in
            self?.drain()
        }
        timer.resume()
        self.timer = timer
    }

    private func startTrack(
        _ track: RecordingTrack,
        source: any AudioCaptureSource,
        url: URL,
        ring: AudioRing,
    ) -> (TrackPipeline?, String?) {
        let events = events
        do {
            let pipeline = try TrackPipeline(url: url, ring: ring, originNanos: originNanos)
            do {
                try source.start(writingTo: ring) { events(track, $0) }
            } catch {
                // Nothing was recorded, so don't leave an empty track for recovery to find.
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            return (pipeline, nil)
        } catch {
            let reason = String(describing: error)
            Self.logger.error("Track \(track.rawValue, privacy: .public) failed to start: \(reason, privacy: .public)")
            events(track, .failed(reason: reason))
            return (nil, reason)
        }
    }

    private func drain() {
        micPipeline?.drain()
        systemPipeline?.drain()
        reportWriteFailure(.mic, pipeline: micPipeline, failure: &micFailure)
        reportWriteFailure(.system, pipeline: systemPipeline, failure: &systemFailure)

        drainCount += 1
        if drainCount % Self.drainsPerSync == 0 {
            micPipeline?.sync()
            systemPipeline?.sync()
        }
    }

    private func reportWriteFailure(_ track: RecordingTrack, pipeline: TrackPipeline?, failure: inout String?) {
        guard failure == nil, let error = pipeline?.writeError else {
            return
        }
        let reason = String(describing: error)
        failure = reason
        Self.logger.error("Track \(track.rawValue, privacy: .public) write failed: \(reason, privacy: .public)")
        events(track, .failed(reason: reason))
    }

    private func stopOnQueue() -> RecordingSummary {
        timer?.cancel()
        timer = nil
        if micPipeline != nil {
            micSource.stop()
        }
        if systemPipeline != nil {
            systemSource.stop()
        }
        // Stopping takes time and audio arrives until it's done, so the end comes after, or the
        // track stopped last would run longer than the other.
        let endNanos = nowNanos()
        micPipeline?.drain()
        systemPipeline?.drain()
        // Device latency correction can put one track past the end, so both go to the longer one.
        let frames = max(micPipeline?.framesWritten ?? 0, systemPipeline?.framesWritten ?? 0)
        micPipeline?.finish(endNanos: endNanos, minimumFrames: frames)
        systemPipeline?.finish(endNanos: endNanos, minimumFrames: frames)
        reportWriteFailure(.mic, pipeline: micPipeline, failure: &micFailure)
        reportWriteFailure(.system, pipeline: systemPipeline, failure: &systemFailure)

        return RecordingSummary(
            durationSeconds: (Double(endNanos) - Double(originNanos)) / 1_000_000_000,
            mic: summary(pipeline: micPipeline, ring: micRing, failure: micFailure),
            system: summary(pipeline: systemPipeline, ring: systemRing, failure: systemFailure),
        )
    }

    private func summary(pipeline: TrackPipeline?, ring: AudioRing, failure: String?) -> TrackSummary {
        TrackSummary(
            frames: pipeline?.framesWritten ?? 0,
            firstAudioSeconds: pipeline?.firstAudioFrame.map { Double($0) / Double(TrackTimeline.sampleRate) },
            gaps: pipeline?.gaps ?? [],
            droppedFrames: ring.droppedFrames,
            failure: failure,
        )
    }
}
