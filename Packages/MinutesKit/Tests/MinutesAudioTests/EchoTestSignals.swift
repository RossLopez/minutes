// SPDX-License-Identifier: GPL-3.0-or-later

import Accelerate
import Foundation

/// Made-up signals for testing echo removal, repeatable from a seed.
enum EchoSignals {
    static let rate = 48000

    struct Noise {
        var state: UInt64

        init(seed: UInt64) {
            state = seed | 1
        }

        mutating func next() -> Float {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Float(state % 20001) / 10000 - 1
        }
    }

    /// Noise shaped like talking: most energy in the low frequencies, in syllables, with pauses between phrases.
    static func speech(seconds: Double, seed: UInt64, amplitude: Float = 0.2) -> [Float] {
        var noise = Noise(seed: seed)
        let count = Int(seconds * Double(rate))
        var low: Float = 0
        var band: Float = 0
        var samples = [Float](repeating: 0, count: count)
        let syllableRate = 3.5 + Double(seed % 5) * 0.3
        for index in 0 ..< count {
            let time = Double(index) / Double(rate)
            let source = noise.next()
            low += 0.08 * (source - low)
            band += 0.3 * (low - band)
            let syllable = pow(max(sin(2 * .pi * syllableRate * time), 0), 0.5)
            let phrase = sin(2 * .pi * time / (3.1 + Double(seed % 3))) > -0.5 ? 1.0 : 0.0
            samples[index] = amplitude * 4 * (0.8 * band + 0.2 * low) * Float(syllable * phrase)
        }
        return samples
    }

    /// A decaying room response: a direct path after `delay` frames, then reverberation lasting about 100 ms.
    static func room(gain: Float, delay: Int = 240, seed: UInt64 = 7) -> [Float] {
        var noise = Noise(seed: seed)
        let tail = 4800
        var response = [Float](repeating: 0, count: delay + tail)
        response[delay] = 1
        for index in 1 ..< tail {
            response[delay + index] = 0.35 * noise.next() * exp(-Float(index) / 1000)
        }
        let energy = vDSP.dot(response, response)
        let normal = gain / energy.squareRoot()
        return response.map { $0 * normal }
    }

    static func convolve(_ signal: [Float], with response: [Float]) -> [Float] {
        var padded = signal + [Float](repeating: 0, count: response.count)
        padded.withUnsafeMutableBufferPointer { _ in }
        var result = [Float](repeating: 0, count: signal.count)
        let reversed = Array(response.reversed())
        let input = [Float](repeating: 0, count: response.count - 1) + signal
        vDSP_conv(input, 1, reversed, 1, &result, 1, vDSP_Length(signal.count), vDSP_Length(response.count))
        return result
    }

    /// Plays a signal slightly fast or slow, like two audio devices on separate clocks.
    static func drifted(_ signal: [Float], partsPerMillion: Double) -> [Float] {
        let step = 1 + partsPerMillion / 1_000_000
        return signal.indices.map { index in
            let position = Double(index) * step
            let lower = Int(position)
            guard lower + 1 < signal.count else {
                return 0
            }
            let fraction = Float(position - Double(lower))
            return signal[lower] * (1 - fraction) + signal[lower + 1] * fraction
        }
    }

    static func add(_ first: [Float], _ second: [Float]) -> [Float] {
        zip(first, second).map(+)
    }

    /// Level in decibels between two points in time.
    static func level(_ samples: [Float], from start: Double, to end: Double) -> Float {
        let slice = Array(samples[Int(start * Double(rate)) ..< min(Int(end * Double(rate)), samples.count)])
        return 20 * log10(max(vDSP.rootMeanSquare(slice), 1e-9))
    }

    /// How much of `reference` remains in `samples`, in decibels, between two points in time.
    static func gain(of reference: [Float], in samples: [Float], from start: Double, to end: Double) -> Float {
        let range = Int(start * Double(rate)) ..< min(Int(end * Double(rate)), samples.count)
        let wanted = Array(reference[range])
        let found = Array(samples[range])
        return 20 * log10(max(abs(vDSP.dot(wanted, found)) / vDSP.dot(wanted, wanted), 1e-9))
    }
}
