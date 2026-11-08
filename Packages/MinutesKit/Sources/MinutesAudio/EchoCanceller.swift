// SPDX-License-Identifier: GPL-3.0-or-later

import Accelerate

/// Predicts how the system track reaches the mic through the room, and subtracts it.
///
/// A partitioned frequency-domain adaptive filter (see Valin, "On Adjusting the Learning Rate in
/// Frequency Domain Echo Cancellation With Double-Talk", 2007). There are two copies of the filter:
/// one keeps learning, and the one that makes the output is replaced only when the learner proves
/// better. So someone talking over the system audio can't drag the output off course.
final class EchoCanceller {
    static let hop = 1024
    /// 20 hops at 48 kHz covers about 430 ms of room.
    static let partitions = 20

    /// Far-end energy per sample below this, on a 16-bit scale, doesn't count as sound (about −60 dBFS).
    private static let activeEnergyPerSample: Float = 1000

    /// What's left of the mic after the output filter, for the last hop.
    let error = FloatBuffer(count: hop)
    /// The output filter's echo estimate, for the last hop.
    let echo = FloatBuffer(count: hop)
    /// How much of the estimated echo power is thought to remain in `error`.
    private(set) var leak: Float = 0
    /// Total energy of the echo estimate and of the system track, while the system track had sound.
    private(set) var echoEnergy: Double = 0
    private(set) var referenceEnergy: Double = 0

    private let fft = RealFFT(size: hop * 2)
    private let bins = hop + 1
    private let history: SpectrumBuffer
    private let learner: SpectrumBuffer
    private let output: SpectrumBuffer
    private var newest = 0
    private var constrainNext = 0

    private let referenceTime = FloatBuffer(count: hop * 2)
    private let scratchTime = FloatBuffer(count: hop * 2)
    private let scratchSpectrum: SpectrumBuffer
    private let learnerError = FloatBuffer(count: hop)
    private let learnerEcho = FloatBuffer(count: hop)
    private let gradientSpectrum: SpectrumBuffer
    private let errorSpectrum: SpectrumBuffer
    private let echoSpectrum: SpectrumBuffer
    private let referencePower: FloatBuffer
    private let errorPower: FloatBuffer
    private let echoPower: FloatBuffer
    private let smoothedErrorPower: FloatBuffer
    private let smoothedEchoPower: FloatBuffer
    private let stepByBin: FloatBuffer

    private var learnerCovariance: Float = 0
    private var learnerVariance: Float = 0
    private var hasAdapted = false
    private var adaptationSum: Float = 0
    private var smoothedLearnerEnergy: Float = 0
    private var smoothedOutputEnergy: Float = 0
    private var partitionGains = [Float](repeating: 1, count: partitions)
    private var hopsUntilGainUpdate = 0

    init() {
        history = SpectrumBuffer(bins: bins, spectra: Self.partitions)
        learner = SpectrumBuffer(bins: bins, spectra: Self.partitions)
        output = SpectrumBuffer(bins: bins, spectra: Self.partitions)
        scratchSpectrum = SpectrumBuffer(bins: bins)
        gradientSpectrum = SpectrumBuffer(bins: bins)
        errorSpectrum = SpectrumBuffer(bins: bins)
        echoSpectrum = SpectrumBuffer(bins: bins)
        referencePower = FloatBuffer(count: bins)
        errorPower = FloatBuffer(count: bins)
        echoPower = FloatBuffer(count: bins)
        smoothedErrorPower = FloatBuffer(count: bins)
        smoothedEchoPower = FloatBuffer(count: bins)
        stepByBin = FloatBuffer(count: bins)
    }

    /// Takes one hop of each track, scaled to 16-bit range. Results are in `error` and `echo`.
    func process(mic: UnsafePointer<Float>, system: UnsafePointer<Float>) {
        push(system)
        let referenceHopEnergy = energy(system)
        let isReferenceActive = referenceHopEnergy > Float(Self.hop) * Self.activeEnergyPerSample

        predict(with: learner, into: learnerEcho)
        predict(with: output, into: echo)
        subtract(learnerEcho, from: mic, into: learnerError)
        subtract(echo, from: mic, into: error)

        adapt(system: referenceHopEnergy, isReferenceActive: isReferenceActive)
        chooseOutputFilter(isReferenceActive: isReferenceActive)
        recoverIfNeeded()

        if isReferenceActive {
            echoEnergy += Double(energy(echo.pointer))
            referenceEnergy += Double(referenceHopEnergy)
        }
    }

    private func slot(_ age: Int) -> Int {
        (newest + Self.partitions - age) % Self.partitions
    }

    private func energy(_ block: UnsafePointer<Float>) -> Float {
        vDSP_dotpr_value(block, block, Self.hop)
    }

    private func subtract(_ estimate: FloatBuffer, from mic: UnsafePointer<Float>, into result: FloatBuffer) {
        vDSP_vsub(estimate.pointer, 1, mic, 1, result.pointer, 1, vDSP_Length(Self.hop))
    }

    private func push(_ system: UnsafePointer<Float>) {
        referenceTime.pointer.update(from: referenceTime.pointer + Self.hop, count: Self.hop)
        (referenceTime.pointer + Self.hop).update(from: system, count: Self.hop)
        newest = (newest + 1) % Self.partitions
        fft.forward(referenceTime.pointer, into: history.split(at: newest))

        referencePower.clear()
        var scale = 1 / Float(fft.size * fft.size)
        for age in 0 ..< Self.partitions {
            var spectrum = history.split(at: slot(age))
            vDSP_zvmgsa(&spectrum, 1, referencePower.pointer, 1, referencePower.pointer, 1, vDSP_Length(bins))
        }
        vDSP_vsmul(referencePower.pointer, 1, &scale, referencePower.pointer, 1, vDSP_Length(bins))
    }

    /// The filter's output for this hop: the last half of the circular convolution, as in overlap-save.
    private func predict(with filter: SpectrumBuffer, into result: FloatBuffer) {
        scratchSpectrum.clear()
        var sum = scratchSpectrum.split()
        for age in 0 ..< Self.partitions {
            var reference = history.split(at: slot(age))
            var weights = filter.split(at: age)
            vDSP_zvma(&reference, 1, &weights, 1, &sum, 1, &sum, 1, vDSP_Length(bins))
        }
        fft.inverse(sum, into: scratchTime.pointer)
        result.pointer.update(from: scratchTime.pointer + Self.hop, count: Self.hop)
    }

    private func transform(_ block: FloatBuffer, into spectrum: SpectrumBuffer, power: FloatBuffer) {
        scratchTime.clear()
        (scratchTime.pointer + Self.hop).update(from: block.pointer, count: Self.hop)
        var split = spectrum.split()
        fft.forward(scratchTime.pointer, into: split)
        vDSP_zvmags(&split, 1, power.pointer, 1, vDSP_Length(bins))
        var scale = 1 / Float(fft.size * fft.size)
        vDSP_vsmul(power.pointer, 1, &scale, power.pointer, 1, vDSP_Length(bins))
    }

    private func adapt(system: Float, isReferenceActive: Bool) {
        transform(learnerError, into: errorSpectrum, power: errorPower)
        transform(learnerEcho, into: echoSpectrum, power: echoPower)

        let errorEnergy = energy(learnerError.pointer) + 1
        let echoEnergy = energy(learnerEcho.pointer) + 1
        updateLeak(errorEnergy: errorEnergy, echoEnergy: echoEnergy)
        guard isReferenceActive else {
            return
        }
        let correlation = vDSP_dotpr_value(learnerError.pointer, learnerEcho.pointer, Self.hop)
        computeSteps(system: system, errorEnergy: errorEnergy, echoEnergy: echoEnergy, correlation: correlation)
        updateLearner()
    }

    /// Measures how far changes in the echo estimate's power explain changes in the error's. The
    /// two only move together through leftover echo, because the near-end talker is unrelated.
    private func updateLeak(errorEnergy: Float, echoEnergy: Float) {
        let smoothing: Float = 0.35
        var covariance: Float = 0
        var variance: Float = 0
        for bin in 0 ..< bins {
            let errorChange = errorPower.pointer[bin] - smoothedErrorPower.pointer[bin]
            let echoChange = echoPower.pointer[bin] - smoothedEchoPower.pointer[bin]
            covariance += errorChange * echoChange
            variance += echoChange * echoChange
            smoothedErrorPower.pointer[bin] += smoothing * errorChange
            smoothedEchoPower.pointer[bin] += smoothing * echoChange
        }
        let baseRate = 2 * Float(Self.hop) / 48000
        let rate = min(baseRate * echoEnergy / errorEnergy, baseRate)
        learnerCovariance += rate * (covariance - learnerCovariance)
        learnerVariance += rate * (variance - learnerVariance)
        let measured = learnerVariance > 1 ? learnerCovariance / learnerVariance : 0.5
        leak = min(max(measured, 0.005), 1)
    }

    /// Learns quickly while unconverged, then only as fast as the leftover echo justifies.
    private func computeSteps(system: Float, errorEnergy: Float, echoEnergy: Float, correlation: Float) {
        guard hasAdapted else {
            let rate = min(0.25 * system, 0.25 * errorEnergy) / errorEnergy
            adaptationSum += rate
            hasAdapted = adaptationSum > Float(Self.partitions) && leak * echoEnergy > 0.03 * echoEnergy
            for bin in 0 ..< bins {
                stepByBin.pointer[bin] = rate / (referencePower.pointer[bin] + 10)
            }
            return
        }
        var ratio = (0.0001 * system + 3 * leak * echoEnergy) / errorEnergy
        ratio = min(max(ratio, correlation * correlation / (errorEnergy * echoEnergy + 1)), 0.5)
        for bin in 0 ..< bins {
            let total = smoothedErrorPower.pointer[bin] + 1
            let residual = 0.7 * leak * smoothedEchoPower.pointer[bin] + 0.3 * ratio * total
            stepByBin.pointer[bin] = min(residual / total, 0.5) / (referencePower.pointer[bin] + 10)
        }
    }

    private func updateLearner() {
        updatePartitionGains()
        var scale = 1 / Float(fft.size * fft.size)
        vDSP_vsmul(stepByBin.pointer, 1, &scale, stepByBin.pointer, 1, vDSP_Length(bins))
        var errorSplit = errorSpectrum.split()
        var gradient = gradientSpectrum.split()
        vDSP_zrvmul(&errorSplit, 1, stepByBin.pointer, 1, &gradient, 1, vDSP_Length(bins))
        var scaled = scratchSpectrum.split()
        for age in 0 ..< Self.partitions {
            var gain = partitionGains[age]
            vDSP_vsmul(gradient.realp, 1, &gain, scaled.realp, 1, vDSP_Length(bins))
            vDSP_vsmul(gradient.imagp, 1, &gain, scaled.imagp, 1, vDSP_Length(bins))
            var reference = history.split(at: slot(age))
            var weights = learner.split(at: age)
            vDSP_zvcma(&reference, 1, &scaled, 1, &weights, 1, &weights, 1, vDSP_Length(bins))
        }
        constrain(learner.split(at: constrainNext))
        constrainNext = (constrainNext + 1) % Self.partitions
    }

    /// A room's echo sits mostly in a few partitions, so those learn fastest. That's what lets the
    /// filter keep up with two devices' clocks slowly drifting apart. The gains average one, so
    /// the overall step size, and the filter's stability, stay the same.
    private func updatePartitionGains() {
        guard hopsUntilGainUpdate == 0 else {
            hopsUntilGainUpdate -= 1
            return
        }
        hopsUntilGainUpdate = 3
        var norms = (0 ..< Self.partitions).map { index -> Float in
            let spectrum = learner.split(at: index)
            var sum: Float = 0
            vDSP_svemg(spectrum.realp, 1, &sum, vDSP_Length(bins))
            var imagSum: Float = 0
            vDSP_svemg(spectrum.imagp, 1, &imagSum, vDSP_Length(bins))
            return sum + imagSum
        }
        let largest = norms.max() ?? 0
        guard largest > 0 else {
            return
        }
        // A floor keeps every partition learning, in case the room changes.
        let floor = 0.1 * largest
        vDSP.add(floor, norms, result: &norms)
        let total = norms.reduce(0, +)
        partitionGains = norms.map { $0 * Float(Self.partitions) / total }
    }

    /// Keeps a partition's filter short enough that it can't wrap around. One partition per hop is enough in practice.
    private func constrain(_ weights: DSPSplitComplex) {
        fft.inverse(weights, into: scratchTime.pointer)
        (scratchTime.pointer + Self.hop).update(repeating: 0, count: Self.hop)
        fft.forward(scratchTime.pointer, into: weights)
    }

    private func chooseOutputFilter(isReferenceActive: Bool) {
        guard isReferenceActive else {
            return
        }
        let smoothing: Float = 0.2
        smoothedLearnerEnergy += smoothing * (energy(learnerError.pointer) - smoothedLearnerEnergy)
        smoothedOutputEnergy += smoothing * (energy(error.pointer) - smoothedOutputEnergy)
        if smoothedLearnerEnergy * 1.1 < smoothedOutputEnergy {
            output.copy(from: learner)
            smoothedOutputEnergy = smoothedLearnerEnergy
        } else if smoothedLearnerEnergy > 8 * smoothedOutputEnergy, smoothedOutputEnergy > 1 {
            learner.copy(from: output)
            smoothedLearnerEnergy = smoothedOutputEnergy
        }
    }

    /// Starts over rather than letting one bad value poison the rest of a long recording.
    private func recoverIfNeeded() {
        guard !energy(error.pointer).isFinite || !energy(learnerError.pointer).isFinite else {
            return
        }
        learner.clear()
        output.clear()
        echo.clear()
        learnerCovariance = 0
        learnerVariance = 0
        hasAdapted = false
        adaptationSum = 0
        smoothedLearnerEnergy = 0
        smoothedOutputEnergy = 0
        smoothedErrorPower.clear()
        smoothedEchoPower.clear()
    }
}

private func vDSP_dotpr_value(_ first: UnsafePointer<Float>, _ second: UnsafePointer<Float>, _ count: Int) -> Float {
    var result: Float = 0
    vDSP_dotpr(first, 1, second, 1, &result, vDSP_Length(count))
    return result
}
