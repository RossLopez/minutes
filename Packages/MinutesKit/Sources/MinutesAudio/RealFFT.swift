// SPDX-License-Identifier: GPL-3.0-or-later

import Accelerate

/// A block of floats that stays put, so vDSP can work on it directly.
final class FloatBuffer {
    let pointer: UnsafeMutablePointer<Float>
    let count: Int

    init(count: Int) {
        self.count = count
        pointer = .allocate(capacity: count)
        pointer.initialize(repeating: 0, count: count)
    }

    deinit {
        pointer.deallocate()
    }

    func clear() {
        pointer.update(repeating: 0, count: count)
    }
}

/// One or more spectra stored one after another, in split-complex form.
final class SpectrumBuffer {
    let real: FloatBuffer
    let imag: FloatBuffer
    let bins: Int

    init(bins: Int, spectra: Int = 1) {
        self.bins = bins
        real = FloatBuffer(count: bins * spectra)
        imag = FloatBuffer(count: bins * spectra)
    }

    func split(at index: Int = 0) -> DSPSplitComplex {
        DSPSplitComplex(realp: real.pointer + index * bins, imagp: imag.pointer + index * bins)
    }

    func copy(from other: SpectrumBuffer) {
        real.pointer.update(from: other.real.pointer, count: real.count)
        imag.pointer.update(from: other.imag.pointer, count: imag.count)
    }

    func clear() {
        real.clear()
        imag.clear()
    }
}

/// A real FFT with plain scaling: `forward` gives the true DFT in `size / 2 + 1` bins, and `inverse` undoes it.
final class RealFFT {
    let size: Int
    let bins: Int

    private let half: Int
    private let log2Size: vDSP_Length
    private let setup: FFTSetup
    private let scratchReal: FloatBuffer
    private let scratchImag: FloatBuffer

    /// `size` must be a power of two.
    init(size: Int) {
        self.size = size
        half = size / 2
        bins = half + 1
        log2Size = vDSP_Length(size.trailingZeroBitCount)
        setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2))!
        scratchReal = FloatBuffer(count: half)
        scratchImag = FloatBuffer(count: half)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    func forward(_ input: UnsafePointer<Float>, into output: DSPSplitComplex) {
        var packed = DSPSplitComplex(realp: output.realp, imagp: output.imagp)
        input.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ctoz($0, 2, &packed, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(setup, &packed, 1, log2Size, FFTDirection(kFFTDirection_Forward))
        // vDSP stores the Nyquist bin in the DC bin's imaginary part, and doubles everything.
        output.realp[half] = output.imagp[0]
        output.imagp[0] = 0
        output.imagp[half] = 0
        var scale: Float = 0.5
        vDSP_vsmul(output.realp, 1, &scale, output.realp, 1, vDSP_Length(bins))
        vDSP_vsmul(output.imagp, 1, &scale, output.imagp, 1, vDSP_Length(bins))
    }

    func inverse(_ input: DSPSplitComplex, into output: UnsafeMutablePointer<Float>) {
        scratchReal.pointer.update(from: input.realp, count: half)
        scratchImag.pointer.update(from: input.imagp, count: half)
        scratchImag.pointer[0] = input.realp[half]
        var packed = DSPSplitComplex(realp: scratchReal.pointer, imagp: scratchImag.pointer)
        vDSP_fft_zrip(setup, &packed, 1, log2Size, FFTDirection(kFFTDirection_Inverse))
        output.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ztoc(&packed, 1, $0, 2, vDSP_Length(half))
        }
        var scale = 1 / Float(size)
        vDSP_vsmul(output, 1, &scale, output, 1, vDSP_Length(size))
    }
}
