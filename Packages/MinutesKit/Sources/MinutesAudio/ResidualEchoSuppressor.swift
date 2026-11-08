// SPDX-License-Identifier: GPL-3.0-or-later

import Accelerate

/// Turns down what the adaptive filter couldn't subtract, in the frequencies where echo is what's left.
/// Where the talker is much louder than the estimated echo, the gain stays at one, so their voice is kept.
final class ResidualEchoSuppressor {
    /// How far a frequency can be turned down: −20 dB. Going lower makes the background pump.
    private static let lowestGain: Float = 0.1
    /// Allows for the estimate running low, because a little extra suppression is harder to hear than echo.
    private static let overSubtraction: Float = 2
    /// How fast a room's reverberation is assumed to fade, per hop.
    private static let tailDecay: Float = 0.7

    private let hop: Int
    private let bins: Int
    private let fft: RealFFT
    private let window: FloatBuffer
    private let previousError: FloatBuffer
    private let previousEcho: FloatBuffer
    private let overlap: FloatBuffer
    private let scratchTime: FloatBuffer
    private let errorSpectrum: SpectrumBuffer
    private let echoSpectrum: SpectrumBuffer
    private let errorPower: FloatBuffer
    private let echoPower: FloatBuffer
    private let residual: FloatBuffer
    private let gain: FloatBuffer

    init(hop: Int) {
        self.hop = hop
        bins = hop + 1
        fft = RealFFT(size: hop * 2)
        window = FloatBuffer(count: hop * 2)
        // A square-root Hann window on the way in and out adds up to exactly one at 50% overlap.
        for index in 0 ..< hop * 2 {
            window.pointer[index] = sin(.pi * (Float(index) + 0.5) / Float(hop * 2))
        }
        previousError = FloatBuffer(count: hop)
        previousEcho = FloatBuffer(count: hop)
        overlap = FloatBuffer(count: hop)
        scratchTime = FloatBuffer(count: hop * 2)
        errorSpectrum = SpectrumBuffer(bins: bins)
        echoSpectrum = SpectrumBuffer(bins: bins)
        errorPower = FloatBuffer(count: bins)
        echoPower = FloatBuffer(count: bins)
        residual = FloatBuffer(count: bins)
        gain = FloatBuffer(count: bins)
        gain.pointer.update(repeating: 1, count: bins)
    }

    /// Writes one hop to `output`. The output runs exactly one hop behind the input.
    func process(
        error: UnsafePointer<Float>,
        echo: UnsafePointer<Float>,
        leak: Float,
        into output: UnsafeMutablePointer<Float>,
    ) {
        transform(error, previous: previousError, into: errorSpectrum, power: errorPower)
        transform(echo, previous: previousEcho, into: echoSpectrum, power: echoPower)
        updateGain(leak: leak)

        var spectrum = errorSpectrum.split()
        vDSP_zrvmul(&spectrum, 1, gain.pointer, 1, &spectrum, 1, vDSP_Length(bins))
        fft.inverse(spectrum, into: scratchTime.pointer)
        vDSP_vmul(scratchTime.pointer, 1, window.pointer, 1, scratchTime.pointer, 1, vDSP_Length(hop * 2))

        vDSP_vadd(scratchTime.pointer, 1, overlap.pointer, 1, output, 1, vDSP_Length(hop))
        overlap.pointer.update(from: scratchTime.pointer + hop, count: hop)
    }

    private func transform(
        _ block: UnsafePointer<Float>,
        previous: FloatBuffer,
        into spectrum: SpectrumBuffer,
        power: FloatBuffer,
    ) {
        scratchTime.pointer.update(from: previous.pointer, count: hop)
        (scratchTime.pointer + hop).update(from: block, count: hop)
        previous.pointer.update(from: block, count: hop)
        vDSP_vmul(scratchTime.pointer, 1, window.pointer, 1, scratchTime.pointer, 1, vDSP_Length(hop * 2))
        var split = spectrum.split()
        fft.forward(scratchTime.pointer, into: split)
        vDSP_zvmags(&split, 1, power.pointer, 1, vDSP_Length(bins))
    }

    private func updateGain(leak: Float) {
        for bin in 0 ..< bins {
            let estimate = leak * echoPower.pointer[bin]
            residual.pointer[bin] = max(estimate, Self.tailDecay * residual.pointer[bin])
            let target = 1 - Self.overSubtraction * residual.pointer[bin] / (errorPower.pointer[bin] + 1e-3)
            let clamped = max(target, Self.lowestGain)
            // Opens at once and closes gradually, which avoids clipping the start of a word.
            gain.pointer[bin] = max(clamped, 0.6 * gain.pointer[bin] + 0.4 * clamped)
        }
    }
}
