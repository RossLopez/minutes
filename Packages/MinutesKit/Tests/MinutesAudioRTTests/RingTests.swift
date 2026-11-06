// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesAudioRT
import Testing

/// Tests own the ring's lifetime and use it from one producer and one consumer, as the audio code does.
private struct RingBox: @unchecked Sendable {
    let ring: OpaquePointer
}

private func read(_ ring: OpaquePointer, capacity: Int = 4096) -> (chunk: MRTChunk, samples: [Float])? {
    var chunk = MRTChunk()
    var buffer = [Float](repeating: 0, count: capacity)
    guard mrt_ring_read_chunk(ring, &chunk, &buffer, UInt32(capacity)) else {
        return nil
    }
    return (chunk, Array(buffer[0 ..< Int(chunk.frameCount)]))
}

/// `#expect` can't take an inline array for a C pointer: the pointer it captures has already dangled.
private func write(_ ring: OpaquePointer, _ samples: [Float], hostTime: UInt64 = 0) -> Bool {
    mrt_ring_write(ring, samples, 1, UInt32(samples.count), hostTime)
}

@Test func `read returns what was written, with its timestamp and rate`() throws {
    let ring = mrt_ring_create(1024)
    defer { mrt_ring_destroy(ring) }
    mrt_ring_set_sample_rate(ring, 24000)

    let samples: [Float] = [0.1, -0.2, 0.3]
    #expect(write(ring, samples, hostTime: 12345))

    let result = try #require(read(ring))
    #expect(result.samples == samples)
    #expect(result.chunk.hostTime == 12345)
    #expect(result.chunk.sampleRate == 24000)
    #expect(read(ring) == nil)
}

@Test func `each chunk carries the time offset set when it was written`() throws {
    let ring = mrt_ring_create(1024)
    defer { mrt_ring_destroy(ring) }

    #expect(write(ring, [1]))
    mrt_ring_set_time_offset(ring, -5000)
    #expect(write(ring, [2]))
    #expect(try #require(read(ring)).chunk.timeOffsetNanos == 0)
    #expect(try #require(read(ring)).chunk.timeOffsetNanos == -5000)
}

@Test func `stride keeps only the first channel of interleaved input`() throws {
    let ring = mrt_ring_create(1024)
    defer { mrt_ring_destroy(ring) }

    let interleaved: [Float] = [1, 9, 9, 2, 9, 9, 3, 9, 9]
    let accepted = mrt_ring_write(ring, interleaved, 3, 3, 0)
    #expect(accepted)
    #expect(try #require(read(ring)).samples == [1, 2, 3])
}

@Test func `a full ring drops and counts rather than overwriting`() throws {
    let ring = mrt_ring_create(8)
    defer { mrt_ring_destroy(ring) }

    let samples = [Float](repeating: 0.5, count: 6)
    #expect(write(ring, samples, hostTime: 1))
    #expect(!write(ring, samples, hostTime: 2))
    #expect(mrt_ring_dropped_frames(ring) == 6)

    #expect(try #require(read(ring)).chunk.hostTime == 1)
    #expect(write(ring, samples, hostTime: 3))
    #expect(try #require(read(ring)).chunk.hostTime == 3)
}

@Test func `samples wrap around the end of the buffer intact`() throws {
    let ring = mrt_ring_create(8)
    defer { mrt_ring_destroy(ring) }

    #expect(write(ring, [1, 2, 3, 4, 5, 6]))
    _ = read(ring)
    #expect(write(ring, [7, 8, 9, 10, 11]))
    #expect(try #require(read(ring)).samples == [7, 8, 9, 10, 11])
}

@Test func `a chunk too big for the reader is skipped and counted`() throws {
    let ring = mrt_ring_create(1024)
    defer { mrt_ring_destroy(ring) }

    #expect(write(ring, [Float](repeating: 1, count: 100), hostTime: 1))
    #expect(write(ring, [2, 2], hostTime: 2))
    let result = try #require(read(ring, capacity: 10))
    #expect(result.chunk.hostTime == 2)
    #expect(mrt_ring_dropped_frames(ring) == 100)
}

@Test func `the peak holds the largest magnitude until taken`() {
    let ring = mrt_ring_create(1024)
    defer { mrt_ring_destroy(ring) }

    #expect(write(ring, [0.1, -0.75, 0.2]))
    #expect(write(ring, [0.3]))
    #expect(mrt_ring_take_peak(ring) == 0.75)
    #expect(mrt_ring_take_peak(ring) == 0)
}

@Test func `a producer and consumer running at once lose nothing that was accepted`() async {
    let box = RingBox(ring: mrt_ring_create(4096))
    defer { mrt_ring_destroy(box.ring) }
    let chunks = 200_000
    let producerDone = Flag()

    async let accepted: Int = Task.detached {
        var value: Float = 0
        var buffer = [Float](repeating: 0, count: 64)
        var accepted = 0
        for index in 0 ..< chunks {
            let frames = index % 63 + 1
            for frame in 0 ..< frames {
                buffer[frame] = value + Float(frame)
            }
            if mrt_ring_write(box.ring, buffer, 1, UInt32(frames), UInt64(index)) {
                accepted += frames
            }
            // A float holds whole numbers exactly up to 2^24, so restart well below that.
            value = (value + Float(frames)).truncatingRemainder(dividingBy: 1_000_000)
        }
        producerDone.set()
        return accepted
    }.value

    async let received: (frames: Int, ordered: Bool) = Task.detached {
        var frames = 0
        var lastHostTime: Int64 = -1
        var ordered = true
        var chunk = MRTChunk()
        var buffer = [Float](repeating: 0, count: 64)
        while true {
            // Read the flag first: once the producer is done, an empty ring stays empty.
            let finished = producerDone.value
            if mrt_ring_read_chunk(box.ring, &chunk, &buffer, 64) {
                frames += Int(chunk.frameCount)
                ordered = ordered && Int64(chunk.hostTime) > lastHostTime
                lastHostTime = Int64(chunk.hostTime)
                // Within a chunk, samples must be the unbroken run the producer wrote.
                for frame in 1 ..< max(1, Int(chunk.frameCount)) where buffer[frame] != buffer[0] + Float(frame) {
                    ordered = false
                }
            } else if finished {
                return (frames, ordered)
            }
        }
    }.value

    let (acceptedFrames, result) = await (accepted, received)
    #expect(result.frames == acceptedFrames)
    #expect(result.ordered)
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    var value: Bool {
        lock.withLock { isSet }
    }

    func set() {
        lock.withLock { isSet = true }
    }
}
