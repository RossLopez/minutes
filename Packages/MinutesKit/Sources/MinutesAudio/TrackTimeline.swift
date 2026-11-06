// SPDX-License-Identifier: GPL-3.0-or-later

/// Maps host time to a position in a track's file, so both tracks stay on one timeline.
///
/// The mic and the output device run on separate clocks. Each chunk's host time says where
/// it belongs: if the file is behind, silence fills the difference, and if it's ahead, the
/// start of the chunk is dropped.
public struct TrackTimeline: Sendable {
    public static let sampleRate = 48000

    /// Differences under this are left alone. 240 frames is 5 ms at 48 kHz.
    public static let defaultToleranceFrames = 240

    public struct Placement: Equatable, Sendable {
        public let padFrames: Int
        public let dropFrames: Int
    }

    public let originNanos: UInt64
    public let toleranceFrames: Int
    public private(set) var writtenFrames = 0

    public init(originNanos: UInt64, toleranceFrames: Int = TrackTimeline.defaultToleranceFrames) {
        self.originNanos = originNanos
        self.toleranceFrames = toleranceFrames
    }

    /// Where a chunk of `frames` frames starting at `startNanos` goes. The caller writes
    /// `padFrames` of silence, then the chunk without its first `dropFrames` frames.
    public mutating func place(startNanos: UInt64, frames: Int) -> Placement {
        let difference = expectedFrames(atNanos: startNanos) - writtenFrames
        var padFrames = 0
        var dropFrames = 0
        if difference > toleranceFrames {
            padFrames = difference
        } else if difference < -toleranceFrames {
            dropFrames = min(-difference, frames)
        }
        writtenFrames += padFrames + frames - dropFrames
        return Placement(padFrames: padFrames, dropFrames: dropFrames)
    }

    /// Silence needed to bring the file up to `endNanos`, so both tracks end together.
    public mutating func padToEnd(endNanos: UInt64) -> Int {
        let padFrames = max(0, expectedFrames(atNanos: endNanos) - writtenFrames)
        writtenFrames += padFrames
        return padFrames
    }

    /// Silence needed to reach `frames`, so tracks that were corrected differently still match.
    public mutating func pad(toFrames frames: Int) -> Int {
        let padFrames = max(0, frames - writtenFrames)
        writtenFrames += padFrames
        return padFrames
    }

    private func expectedFrames(atNanos nanos: UInt64) -> Int {
        let elapsed = Double(nanos) - Double(originNanos)
        return Int((elapsed * Double(Self.sampleRate) / 1_000_000_000).rounded())
    }
}
