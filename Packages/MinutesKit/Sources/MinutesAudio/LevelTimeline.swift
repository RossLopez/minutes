// SPDX-License-Identifier: GPL-3.0-or-later

import Accelerate
@preconcurrency import AVFoundation

/// How loud a track is over time, in short blocks. A four-hour track takes about 600 KB.
public struct LevelTimeline: Equatable, Sendable {
    public static let blockSeconds = 0.1

    /// Quieter than any real room, so a block like this is a gap in the audio rather than its background.
    private static let digitalSilence: Float = -100
    /// Low enough to miss speech in a busy meeting, without landing on one unusually quiet moment.
    private static let noiseFloorPercentile = 10
    private static let silentPower: Float = 1e-12

    /// Each block's level in dBFS.
    public let decibels: [Float]

    public init(decibels: [Float]) {
        self.decibels = decibels
    }

    /// Reads in small pieces off the caller's thread. Throws `CancellationError` if cancelled.
    public static func read(_ url: URL) async throws -> LevelTimeline {
        let task = Task.detached(priority: .utility) {
            try readBlocking(url)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// The level of the track's background sound, or `nil` if it has no sound at all.
    public var noiseFloor: Float? {
        let audible = decibels.filter { $0 > Self.digitalSilence }.sorted()
        return audible.isEmpty ? nil : audible[audible.count * Self.noiseFloorPercentile / 100]
    }

    /// The average level from one moment to another, or `nil` if that's outside the track.
    public func level(from start: Double, to end: Double) -> Float? {
        let first = max(0, Int(start / Self.blockSeconds))
        let last = min(decibels.count, max(first + 1, Int((end / Self.blockSeconds).rounded(.up))))
        guard first < last else {
            return nil
        }
        let power = decibels[first ..< last].reduce(Float(0)) { $0 + pow(10, $1 / 10) }
        return Self.decibels(power: power / Float(last - first))
    }

    private static func decibels(power: Float) -> Float {
        10 * log10(max(power, silentPower))
    }

    private static func readBlocking(_ url: URL) throws -> LevelTimeline {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let blockFrames = max(1, Int(file.processingFormat.sampleRate * blockSeconds))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16384) else {
            throw CocoaError(.fileReadUnknown)
        }
        var levels: [Float] = []
        levels.reserveCapacity(Int(file.length) / blockFrames + 1)
        var energy: Float = 0
        var filled = 0
        // A single read can return early with frames still to come (see docs/NOTES.md).
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            if buffer.frameLength == 0 {
                break
            }
            var position = 0
            while position < Int(buffer.frameLength) {
                let count = min(blockFrames - filled, Int(buffer.frameLength) - position)
                var sum: Float = 0
                vDSP_svesq(buffer.floatChannelData![0] + position, 1, &sum, vDSP_Length(count))
                energy += sum
                filled += count
                position += count
                if filled == blockFrames {
                    levels.append(decibels(power: energy / Float(filled)))
                    energy = 0
                    filled = 0
                }
            }
        }
        if filled > 0 {
            levels.append(decibels(power: energy / Float(filled)))
        }
        return LevelTimeline(decibels: levels)
    }
}
