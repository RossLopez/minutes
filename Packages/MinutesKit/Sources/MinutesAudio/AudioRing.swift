// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesAudioRT

/// Owns a real-time ring. The producer must stop before the last reference goes away.
public final class AudioRing: @unchecked Sendable {
    let raw: OpaquePointer

    /// The default holds about 21 seconds at 48 kHz, far more than a drain interval.
    public init(capacityFrames: UInt32 = 1 << 20) {
        raw = mrt_ring_create(capacityFrames)
    }

    deinit {
        mrt_ring_destroy(raw)
    }

    public func setSampleRate(_ sampleRate: Double) {
        mrt_ring_set_sample_rate(raw, sampleRate)
    }

    /// Writes from a non-real-time context, for tests and fake sources.
    @discardableResult
    public func write(_ samples: [Float], hostTime: UInt64) -> Bool {
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else {
                return true
            }
            return mrt_ring_write(raw, base, 1, UInt32(buffer.count), hostTime)
        }
    }

    /// The highest absolute sample since the last call.
    public func takePeak() -> Float {
        mrt_ring_take_peak(raw)
    }

    public var droppedFrames: UInt64 {
        mrt_ring_dropped_frames(raw)
    }
}
