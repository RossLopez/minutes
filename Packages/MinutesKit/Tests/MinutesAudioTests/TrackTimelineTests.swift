// SPDX-License-Identifier: GPL-3.0-or-later

@testable import MinutesAudio
import Testing

private let origin: UInt64 = 1_000_000_000

private func nanos(atFrame frame: Int) -> UInt64 {
    origin + UInt64(Double(frame) / 48000 * 1_000_000_000)
}

@Test func `a late first chunk is padded to where it belongs`() {
    var timeline = TrackTimeline(originNanos: origin)
    let placement = timeline.place(startNanos: nanos(atFrame: 4800), frames: 480)
    #expect(placement == .init(padFrames: 4800, dropFrames: 0))
    #expect(timeline.writtenFrames == 5280)
}

@Test func `chunks on time are written as they are`() {
    var timeline = TrackTimeline(originNanos: origin)
    for index in 0 ..< 100 {
        #expect(timeline.place(startNanos: nanos(atFrame: index * 512), frames: 512) == .init(
            padFrames: 0,
            dropFrames: 0,
        ))
    }
    #expect(timeline.writtenFrames == 51200)
}

@Test func `small timing noise inside the tolerance is left alone`() {
    var timeline = TrackTimeline(originNanos: origin)
    _ = timeline.place(startNanos: nanos(atFrame: 0), frames: 480)
    let placement = timeline.place(startNanos: nanos(atFrame: 480 + 200), frames: 480)
    #expect(placement == .init(padFrames: 0, dropFrames: 0))
}

@Test func `a stall becomes silence, so later audio stays in place`() {
    var timeline = TrackTimeline(originNanos: origin)
    _ = timeline.place(startNanos: nanos(atFrame: 0), frames: 48000)
    let placement = timeline.place(startNanos: nanos(atFrame: 96000), frames: 480)
    #expect(placement == .init(padFrames: 48000, dropFrames: 0))
    #expect(timeline.writtenFrames == 96480)
}

@Test func `a chunk arriving early loses its overlap`() {
    var timeline = TrackTimeline(originNanos: origin)
    _ = timeline.place(startNanos: nanos(atFrame: 0), frames: 4800)
    let placement = timeline.place(startNanos: nanos(atFrame: 4000), frames: 4800)
    #expect(placement == .init(padFrames: 0, dropFrames: 800))
    #expect(timeline.writtenFrames == 8800)
}

@Test func `dropping can't remove more than the chunk has`() {
    var timeline = TrackTimeline(originNanos: origin)
    _ = timeline.place(startNanos: nanos(atFrame: 0), frames: 48000)
    let placement = timeline.place(startNanos: nanos(atFrame: 1000), frames: 480)
    #expect(placement == .init(padFrames: 0, dropFrames: 480))
    #expect(timeline.writtenFrames == 48000)
}

@Test(arguments: [1.0005, 0.9995, 1.0001, 0.9999])
func `a drifting clock stays near the timeline for hours`(clockRatio: Double) {
    var timeline = TrackTimeline(originNanos: origin)
    let chunkFrames = 512
    var deviceFrames = 0
    var worst = 0
    // Three hours of chunks from a device whose clock runs fast or slow.
    for _ in 0 ..< (3 * 3600 * 48000 / chunkFrames) {
        let start = nanos(atFrame: Int(Double(deviceFrames) * clockRatio))
        _ = timeline.place(startNanos: start, frames: chunkFrames)
        deviceFrames += chunkFrames
        let expected = Int(Double(deviceFrames) * clockRatio)
        worst = max(worst, abs(timeline.writtenFrames - expected))
    }
    // The tolerance, plus one chunk of the measurement landing mid-correction.
    #expect(worst <= TrackTimeline.defaultToleranceFrames + chunkFrames)
}

@Test func `padding to the end evens out the tracks`() {
    var timeline = TrackTimeline(originNanos: origin)
    _ = timeline.place(startNanos: nanos(atFrame: 0), frames: 48000)
    #expect(timeline.padToEnd(endNanos: nanos(atFrame: 96000)) == 48000)
    #expect(timeline.writtenFrames == 96000)
    #expect(timeline.padToEnd(endNanos: nanos(atFrame: 96000)) == 0)
}

@Test func `padding to a frame count only ever adds`() {
    var timeline = TrackTimeline(originNanos: origin)
    _ = timeline.place(startNanos: nanos(atFrame: 0), frames: 1000)
    #expect(timeline.pad(toFrames: 1500) == 500)
    #expect(timeline.pad(toFrames: 1200) == 0)
    #expect(timeline.writtenFrames == 1500)
}

@Test func `padding never goes backwards`() {
    var timeline = TrackTimeline(originNanos: origin)
    _ = timeline.place(startNanos: nanos(atFrame: 0), frames: 48000)
    #expect(timeline.padToEnd(endNanos: nanos(atFrame: 100)) == 0)
    #expect(timeline.writtenFrames == 48000)
}
