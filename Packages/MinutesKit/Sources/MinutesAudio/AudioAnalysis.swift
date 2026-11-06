// SPDX-License-Identifier: GPL-3.0-or-later

import Accelerate
@preconcurrency import AVFoundation

/// Measurements used to verify recordings. Used by `minutes-audiocheck` and tests.
public enum AudioAnalysis {
    public struct TrackLevel: Equatable, Sendable {
        public let durationSeconds: Double
        public let peak: Float
        public let rmsDecibels: Float
    }

    /// How a stretch of the system track shows up in the mic track.
    public struct LeakMeasurement: Equatable, Sendable {
        /// How far the mic trails the system track, in milliseconds.
        public let lagMilliseconds: Double
        /// −1 to 1, at the best lag. Near 0 means the two are unrelated.
        public let correlation: Float
        /// The system signal's level in the mic, relative to the system track.
        public let echoDecibels: Float
    }

    public static func read(_ url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate
        guard file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65536)
        else {
            return ([], rate)
        }
        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        // A single read can return early with frames still to come (see docs/NOTES.md).
        while file.framePosition < file.length {
            try file.read(into: buffer)
            if buffer.frameLength == 0 {
                break
            }
            samples += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }
        return (samples, rate)
    }

    public static func level(of samples: [Float], sampleRate: Double) -> TrackLevel {
        guard !samples.isEmpty else {
            return TrackLevel(durationSeconds: 0, peak: 0, rmsDecibels: -.infinity)
        }
        let peak = vDSP.maximumMagnitude(samples)
        let rms = vDSP.rootMeanSquare(samples)
        return TrackLevel(
            durationSeconds: Double(samples.count) / sampleRate,
            peak: peak,
            rmsDecibels: decibels(rms),
        )
    }

    /// Finds the system signal in the mic, searching lags up to `maxLagSeconds` in either direction.
    public static func measureLeak(
        mic: ArraySlice<Float>,
        system: ArraySlice<Float>,
        sampleRate: Double,
        maxLagSeconds: Double = 0.5,
    ) -> LeakMeasurement? {
        let maxLag = Int(maxLagSeconds * sampleRate)
        let length = min(mic.count, system.count) - 2 * maxLag
        guard length > 0 else {
            return nil
        }
        let reference = Array(system[(system.startIndex + maxLag) ..< (system.startIndex + maxLag + length)])
        let candidates = Array(mic[mic.startIndex ..< (mic.startIndex + length + 2 * maxLag)])

        // The result at index i is the correlation with `candidates` starting at i, so a lag of i − maxLag.
        var correlations = [Float](repeating: 0, count: 2 * maxLag + 1)
        vDSP_conv(candidates, 1, reference, 1, &correlations, 1, vDSP_Length(correlations.count), vDSP_Length(length))

        var bestIndex: vDSP_Length = 0
        var bestValue: Float = 0
        vDSP_maxmgvi(correlations, 1, &bestValue, &bestIndex, vDSP_Length(correlations.count))

        let aligned = Array(candidates[Int(bestIndex) ..< (Int(bestIndex) + length)])
        let referenceEnergy = vDSP.dot(reference, reference)
        let micEnergy = vDSP.dot(aligned, aligned)
        guard referenceEnergy > 0, micEnergy > 0 else {
            return nil
        }
        let dot = vDSP.dot(aligned, reference)
        return LeakMeasurement(
            lagMilliseconds: (Double(bestIndex) - Double(maxLag)) / sampleRate * 1000,
            correlation: dot / (referenceEnergy * micEnergy).squareRoot(),
            echoDecibels: decibels(abs(dot) / referenceEnergy),
        )
    }

    /// Seeded noise bursts, unlike a steady tone, can only line up at one lag.
    public static func makeAlignmentSignal(seconds: Double, sampleRate: Double, amplitude: Float,
                                           seed: UInt64) -> [Float]
    {
        var state = seed | 1
        let count = Int(seconds * sampleRate)
        let burst = Int(sampleRate * 0.4)
        return (0 ..< count).map { index in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            guard index % Int(sampleRate) < burst else {
                return 0
            }
            return amplitude * (Float(state % 2001) / 1000 - 1)
        }
    }

    public static func decibels(_ value: Float) -> Float {
        value > 0 ? 20 * log10(value) : -.infinity
    }
}
