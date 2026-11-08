// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import AVFoundation

/// Cuts a long track into pieces, each ending at the quietest moment near its limit, so a cut
/// doesn't land in the middle of a word. A track that's short enough comes back as itself.
///
/// Parakeet's vocabulary step uses more memory, and invents more terms, on long files
/// (see docs/TRANSCRIPTION_SPIKE.md). Reads straight through, because seeking in AAC isn't exact.
public final class TrackSplitter {
    public struct Piece: Equatable, Sendable {
        public let url: URL
        public let startSeconds: Double
        public let durationSeconds: Double
    }

    /// A track up to this much longer than the limit stays whole, rather than leaving a tiny last piece.
    private static let wholeFileAllowance = 1.2
    private static let blockFrames: AVAudioFrameCount = 48000

    public let totalSeconds: Double

    private let url: URL
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    private let rate: Double
    private let longestFrames: Int
    private let searchFrames: Int
    private var carry: [Float] = []
    private var framesDone = 0
    private var isFinished = false

    /// - Parameters:
    ///   - longestPieceSeconds: No piece runs longer than this, unless the whole track nearly fits.
    ///   - searchSeconds: How far before the limit to look for a pause.
    public init(url: URL, longestPieceSeconds: Double = 1800, searchSeconds: Double = 150) throws {
        self.url = url
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        rate = file.processingFormat.sampleRate
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: Self.blockFrames) else {
            throw CocoaError(.fileReadUnknown)
        }
        self.buffer = buffer
        longestFrames = Int(longestPieceSeconds * rate)
        searchFrames = min(Int(searchSeconds * rate), longestFrames)
        totalSeconds = Double(file.length) / rate
    }

    /// The next piece, or `nil` at the end. Each call may write to `pieceURL`, replacing what's there.
    public func next(writingTo pieceURL: URL) throws -> Piece? {
        guard !isFinished else {
            return nil
        }
        if framesDone == 0, Double(file.length) <= Double(longestFrames) * Self.wholeFileAllowance {
            isFinished = true
            return Piece(url: url, startSeconds: 0, durationSeconds: totalSeconds)
        }
        try? FileManager.default.removeItem(at: pieceURL)
        let writer = try AVAudioFile(
            forWriting: pieceURL,
            settings: file.processingFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false,
        )
        defer { writer.close() }

        var written = 0
        try write(carry, to: writer)
        written += carry.count
        carry = []
        while written < longestFrames - searchFrames, try readBlock() {
            try writer.write(from: buffer)
            written += Int(buffer.frameLength)
        }
        let window = try readWindow(frames: longestFrames - written)
        if file.framePosition >= file.length, window.count < longestFrames - written {
            isFinished = true
            try write(window, to: writer)
            written += window.count
        } else {
            let cut = Self.quietestFrame(in: window, blockFrames: Int(rate / 10))
            try write(Array(window[..<cut]), to: writer)
            written += cut
            // Reading the window can run past it, and that's already waiting in `carry`.
            carry = Array(window[cut...]) + carry
            isFinished = carry.isEmpty && file.framePosition >= file.length
        }
        let piece = Piece(
            url: pieceURL,
            startSeconds: Double(framesDone) / rate,
            durationSeconds: Double(written) / rate,
        )
        framesDone += written
        return piece
    }

    private func readBlock() throws -> Bool {
        // A single read can return early with frames still to come (see docs/NOTES.md).
        guard file.framePosition < file.length else {
            return false
        }
        try file.read(into: buffer)
        return buffer.frameLength > 0
    }

    private func readWindow(frames: Int) throws -> [Float] {
        var window: [Float] = []
        window.reserveCapacity(frames)
        while window.count < frames, try readBlock() {
            window += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }
        if window.count > frames {
            carry = Array(window[frames...])
            window.removeLast(window.count - frames)
        }
        return window
    }

    private func write(_ samples: [Float], to writer: AVAudioFile) throws {
        var offset = 0
        while offset < samples.count {
            let count = min(samples.count - offset, Int(Self.blockFrames))
            samples[offset ..< offset + count].withUnsafeBufferPointer {
                buffer.floatChannelData![0].update(from: $0.baseAddress!, count: count)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try writer.write(from: buffer)
            offset += count
        }
    }

    /// The middle of the quietest block. Later wins a tie, keeping pieces as long as allowed.
    private static func quietestFrame(in window: [Float], blockFrames: Int) -> Int {
        guard window.count > blockFrames else {
            return window.count
        }
        var best = window.count - blockFrames / 2
        var bestEnergy = Float.infinity
        var start = 0
        while start + blockFrames <= window.count {
            let energy = window[start ..< start + blockFrames].reduce(0) { $0 + $1 * $1 }
            if energy <= bestEnergy {
                bestEnergy = energy
                best = start + blockFrames / 2
            }
            start += blockFrames
        }
        return best
    }
}
