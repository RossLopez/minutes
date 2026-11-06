// SPDX-License-Identifier: GPL-3.0-or-later

@testable import MinutesAudio
import Testing

private func convertInChunks(_ converter: TrackConverter, samples: [Float], rate: Double, chunk: Int = 512) -> [Float] {
    var output: [Float] = []
    samples.withUnsafeBufferPointer { buffer in
        var offset = 0
        while offset < samples.count {
            let count = min(chunk, samples.count - offset)
            output += converter.convert(buffer.baseAddress! + offset, frames: count, rate: rate)
            offset += count
        }
    }
    return output
}

@Test func `audio at 48 kHz passes through unchanged`() {
    let samples = sine(frequency: 440, rate: 48000, frames: 4800)
    #expect(convertInChunks(TrackConverter(), samples: samples, rate: 48000) == samples)
}

@Test(arguments: [24000.0, 44100.0, 96000.0, 16000.0])
func `other rates come out at 48 kHz with the same tone`(rate: Double) {
    let samples = sine(frequency: 1000, rate: rate, frames: Int(rate))
    let output = convertInChunks(TrackConverter(), samples: samples, rate: rate)

    // The resampler holds back a small tail, so it won't be exact.
    #expect(abs(output.count - 48000) < 512)

    // Count rising zero crossings in the settled middle: one per cycle of the tone.
    let middle = output[(output.count / 4) ..< (output.count * 3 / 4)]
    let crossings = zip(middle, middle.dropFirst()).count { $0 < 0 && $1 >= 0 }
    let expected = Double(middle.count) / 48000 * 1000
    #expect(abs(Double(crossings) - expected) <= 2)
}

@Test func `a rate change mid-track keeps converting`() {
    let converter = TrackConverter()
    let first = convertInChunks(converter, samples: sine(frequency: 500, rate: 24000, frames: 24000), rate: 24000)
    let second = convertInChunks(converter, samples: sine(frequency: 500, rate: 44100, frames: 44100), rate: 44100)
    let third = convertInChunks(converter, samples: sine(frequency: 500, rate: 48000, frames: 48000), rate: 48000)
    #expect(abs(first.count - 48000) < 512)
    #expect(abs(second.count - 48000) < 512)
    #expect(third.count == 48000)
}
