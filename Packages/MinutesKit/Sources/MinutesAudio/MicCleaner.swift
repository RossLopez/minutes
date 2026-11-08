// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import AVFoundation
import Foundation

/// Makes `mic.m4a`: the mic track with any of the system track's sound that reached it removed.
///
/// Reads in small blocks, so a four-hour meeting uses the same memory as a four-minute one.
/// Never changes its inputs. With headphones there's nothing to remove, so the result is an exact copy.
public enum MicCleaner {
    public enum Outcome: Equatable, Sendable {
        /// `echoDecibels` is the echo found, relative to the system track.
        case cleaned(echoDecibels: Float)
        /// No echo was found, or the system track never had sound.
        case copied
    }

    /// An echo estimate quieter than this, relative to the system track, is nothing worth removing.
    static let echoThresholdDecibels: Float = -50
    /// The tracks can sit up to about 10 ms off in either direction, and a filter can't use what
    /// hasn't happened yet. Holding the mic back this long keeps the echo after its source.
    private static let micHoldBack = 1440 // 30 ms at 48 kHz.
    private static let scale: Float = 32768
    private static let durationToleranceFrames = 2400

    /// Writes the result to `output`, replacing anything there.
    public static func clean(
        mic: URL,
        system: URL?,
        output: URL,
        format: RecordingAudioFormat,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
    ) async throws -> Outcome {
        let task = Task.detached(priority: .utility) {
            try cleanBlocking(mic: mic, system: system, output: output, format: format, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func cleanBlocking(
        mic: URL,
        system: URL?,
        output: URL,
        format: RecordingAudioFormat,
        progress: (Double) -> Void,
    ) throws -> Outcome {
        try? FileManager.default.removeItem(at: output)
        guard let system, FileManager.default.fileExists(atPath: system.path) else {
            try FileManager.default.copyItem(at: mic, to: output)
            return .copied
        }
        do {
            let echo = try filter(mic: mic, system: system, output: output, format: format, progress: progress)
            if echo > echoThresholdDecibels {
                return .cleaned(echoDecibels: echo)
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        try FileManager.default.removeItem(at: output)
        try FileManager.default.copyItem(at: mic, to: output)
        return .copied
    }

    /// Returns the echo level it found.
    private static func filter(
        mic: URL,
        system: URL,
        output: URL,
        format: RecordingAudioFormat,
        progress: (Double) -> Void,
    ) throws -> Float {
        let hop = EchoCanceller.hop
        let micReader = try BlockReader(url: mic, hop: hop, holdBack: micHoldBack, scale: scale)
        let systemReader = try BlockReader(url: system, hop: hop, holdBack: 0, scale: scale)
        let writer = try BlockWriter(
            url: output,
            format: format,
            hop: hop,
            skip: micHoldBack + hop,
            frames: micReader.frames,
            scale: 1 / scale,
        )
        let canceller = EchoCanceller()
        let suppressor = ResidualEchoSuppressor(hop: hop)
        let block = FloatBuffer(count: hop)

        var hopsDone = 0
        while writer.remaining > 0 {
            try Task.checkCancellation()
            try canceller.process(mic: micReader.next(), system: systemReader.next())
            suppressor.process(
                error: canceller.error.pointer,
                echo: canceller.echo.pointer,
                leak: canceller.leak,
                into: block.pointer,
            )
            try writer.write(block.pointer)
            hopsDone += 1
            if hopsDone % 512 == 0 {
                progress(1 - Double(writer.remaining) / Double(max(micReader.frames, 1)))
            }
        }
        writer.close()
        try verify(output, expectedFrames: micReader.frames)
        guard canceller.referenceEnergy > 0 else {
            return -.infinity
        }
        return AudioAnalysis.decibels(Float((canceller.echoEnergy / canceller.referenceEnergy).squareRoot()))
    }

    private static func verify(_ url: URL, expectedFrames: Int) throws {
        let actualFrames = try Int(AVAudioFile(forReading: url).length)
        guard abs(actualFrames - expectedFrames) <= durationToleranceFrames else {
            throw TrackEncoder.EncoderError.durationMismatch(expectedFrames: expectedFrames, actualFrames: actualFrames)
        }
    }
}

/// Hands out fixed-size blocks from a file, as silence once the file runs out.
private final class BlockReader {
    let frames: Int

    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    private let block: FloatBuffer
    private let scale: Float
    private var pendingSilence: Int
    private var available = 0
    private var position = 0

    init(url: URL, hop: Int, holdBack: Int, scale: Float) throws {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        frames = Int(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16384) else {
            throw CocoaError(.fileReadUnknown)
        }
        self.buffer = buffer
        block = FloatBuffer(count: hop)
        self.scale = scale
        pendingSilence = holdBack
    }

    func next() throws -> UnsafePointer<Float> {
        var filled = min(pendingSilence, block.count)
        block.pointer.update(repeating: 0, count: filled)
        pendingSilence -= filled
        while filled < block.count {
            if position == available, try !refill() {
                (block.pointer + filled).update(repeating: 0, count: block.count - filled)
                break
            }
            let count = min(block.count - filled, available - position)
            for index in 0 ..< count {
                block.pointer[filled + index] = buffer.floatChannelData![0][position + index] * scale
            }
            filled += count
            position += count
        }
        return UnsafePointer(block.pointer)
    }

    private func refill() throws -> Bool {
        // A single read can return early with frames still to come (see docs/NOTES.md).
        guard file.framePosition < file.length else {
            return false
        }
        try file.read(into: buffer)
        available = Int(buffer.frameLength)
        position = 0
        return available > 0
    }
}

/// Writes blocks to a file, dropping the first few frames and stopping at the track's exact length.
private final class BlockWriter {
    private(set) var remaining: Int

    private var file: AVAudioFile?
    private let buffer: AVAudioPCMBuffer
    private let hop: Int
    private let scale: Float
    private var toSkip: Int

    init(url: URL, format: RecordingAudioFormat, hop: Int, skip: Int, frames: Int, scale: Float) throws {
        let output = try AVAudioFile(
            forWriting: url,
            settings: TrackEncoder.settings(for: format),
            commonFormat: .pcmFormatFloat32,
            interleaved: false,
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: AVAudioFrameCount(hop))
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        file = output
        self.buffer = buffer
        self.hop = hop
        self.scale = scale
        toSkip = skip
        remaining = frames
    }

    func write(_ block: UnsafePointer<Float>) throws {
        let skipped = min(toSkip, hop)
        toSkip -= skipped
        let count = min(hop - skipped, remaining)
        guard count > 0, let file else {
            return
        }
        for index in 0 ..< count {
            buffer.floatChannelData![0][index] = block[skipped + index] * scale
        }
        buffer.frameLength = AVAudioFrameCount(count)
        try file.write(from: buffer)
        remaining -= count
    }

    /// `AVAudioFile` finishes the file when it's released.
    func close() {
        file?.close()
        file = nil
    }
}
