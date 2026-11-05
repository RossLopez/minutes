// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesAudioRT

struct MRTChunkBox {
    private var chunk = MRTChunk()

    var frames: Int {
        Int(chunk.frameCount)
    }

    /// When the chunk's first sample was really heard or spoken, on the host clock.
    var startNanos: UInt64 {
        UInt64(Int64(HostClock.nanos(fromHostTime: chunk.hostTime)) + chunk.timeOffsetNanos)
    }

    var sampleRate: Double {
        chunk.sampleRate
    }

    mutating func read(from ring: AudioRing, into destination: UnsafeMutablePointer<Float>, capacity: UInt32) -> Bool {
        mrt_ring_read_chunk(ring.raw, &chunk, destination, capacity)
    }
}
