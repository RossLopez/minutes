// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import AVFoundation
import Foundation

public enum RecordingAudioFormat: String, CaseIterable, Codable, Sendable {
    case aac
    case alac
}

/// Turns a finished or crash-truncated CAF into the final `.m4a`.
public enum TrackEncoder {
    public enum EncoderError: Error, Equatable {
        case emptyTrack
        case durationMismatch(expectedFrames: Int, actualFrames: Int)
    }

    /// AAC can differ by a little from padding, which this allows. 2400 frames is 50 ms at 48 kHz.
    private static let durationToleranceFrames = 2400
    private static let bufferFrames: AVAudioFrameCount = 48000

    /// Encodes `caf` to `destination`, and deletes `caf` only after checking the result's duration.
    /// A partial output never takes the final name, so an interrupted encode can simply run again.
    public static func encode(caf: URL, to destination: URL, format: RecordingAudioFormat) async throws {
        let task = Task.detached(priority: .utility) {
            try encodeBlocking(caf: caf, to: destination, format: format)
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func encodeBlocking(caf: URL, to destination: URL, format: RecordingAudioFormat) throws {
        let input = try AVAudioFile(forReading: caf, commonFormat: .pcmFormatFloat32, interleaved: false)
        let expectedFrames = Int(input.length)
        guard expectedFrames > 0 else {
            throw EncoderError.emptyTrack
        }

        let partial = destination.deletingPathExtension().appendingPathExtension("partial.m4a")
        try? FileManager.default.removeItem(at: partial)

        do {
            try write(input: input, to: partial, format: format)
            let check = try AVAudioFile(forReading: partial)
            let actualFrames = Int(check.length)
            guard abs(actualFrames - expectedFrames) <= durationToleranceFrames else {
                throw EncoderError.durationMismatch(expectedFrames: expectedFrames, actualFrames: actualFrames)
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        try FileManager.default.removeItem(at: caf)
    }

    private static func write(input: AVAudioFile, to url: URL, format: RecordingAudioFormat) throws {
        let output = try AVAudioFile(
            forWriting: url,
            settings: settings(for: format),
            commonFormat: .pcmFormatFloat32,
            interleaved: false,
        )
        defer { output.close() }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: bufferFrames) else {
            throw CoreAudioError(operation: "allocate encode buffer", status: kAudioHardwareUnspecifiedError)
        }
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer)
            if buffer.frameLength == 0 {
                break
            }
            try output.write(from: buffer)
        }
    }

    private static func settings(for format: RecordingAudioFormat) -> [String: Any] {
        var settings: [String: Any] = [
            AVSampleRateKey: Double(TrackTimeline.sampleRate),
            AVNumberOfChannelsKey: 1,
        ]
        switch format {
        case .aac:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = 96000
        case .alac:
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = 24
        }
        return settings
    }
}
