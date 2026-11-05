// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A stretch of silence in a track where the source wasn't delivering audio.
public struct RecordingGap: Equatable, Sendable, Codable {
    public let startSeconds: Double
    public let durationSeconds: Double
}

/// Moves one track from its ring to its file. Used only on the session's drain queue.
final class TrackPipeline {
    /// Padding longer than this is a real gap. 2400 frames is 50 ms at 48 kHz.
    static let gapThresholdFrames = 2400

    let ring: AudioRing
    private let writer: CAFTrackWriter
    private let converter = TrackConverter()
    private var timeline: TrackTimeline
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: TrackPipeline.scratchFrames)
    private static let scratchFrames = 32768

    private(set) var firstAudioFrame: Int?
    private(set) var gaps: [RecordingGap] = []
    private(set) var writeError: Error?

    init(url: URL, ring: AudioRing, originNanos: UInt64) throws {
        writer = try CAFTrackWriter(url: url)
        self.ring = ring
        timeline = TrackTimeline(originNanos: originNanos)
    }

    deinit {
        scratch.deallocate()
    }

    var framesWritten: Int {
        timeline.writtenFrames
    }

    func drain() {
        guard writeError == nil else {
            return
        }
        var chunk = MRTChunkBox()
        while chunk.read(from: ring, into: scratch, capacity: UInt32(Self.scratchFrames)) {
            write(chunk: chunk)
        }
    }

    func sync() {
        writer.sync()
    }

    /// Writes what's left, pads to the end of the session and closes the file.
    func finish(endNanos: UInt64) {
        drain()
        if writeError == nil {
            do {
                try writer.appendSilence(frames: timeline.padToEnd(endNanos: endNanos))
            } catch {
                writeError = error
            }
        }
        writer.close()
    }

    private func write(chunk: MRTChunkBox) {
        let converted = converter.convert(scratch, frames: chunk.frames, rate: chunk.sampleRate)
        guard !converted.isEmpty else {
            return
        }
        let positionBefore = timeline.writtenFrames
        let placement = timeline.place(
            startNanos: HostClock.nanos(fromHostTime: chunk.hostTime),
            frames: converted.count,
        )
        if firstAudioFrame == nil {
            firstAudioFrame = positionBefore + placement.padFrames
        } else if placement.padFrames >= Self.gapThresholdFrames {
            gaps.append(RecordingGap(
                startSeconds: Double(positionBefore) / Double(TrackTimeline.sampleRate),
                durationSeconds: Double(placement.padFrames) / Double(TrackTimeline.sampleRate),
            ))
        }
        do {
            try writer.appendSilence(frames: placement.padFrames)
            try converted.withUnsafeBufferPointer {
                try writer.append(UnsafeBufferPointer(rebasing: $0[placement.dropFrames...]))
            }
        } catch {
            writeError = error
        }
    }
}
