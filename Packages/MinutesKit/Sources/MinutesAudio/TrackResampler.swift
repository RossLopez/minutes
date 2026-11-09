// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import AVFoundation

/// Rewrites a track at another sample rate, as raw 32-bit floats, for models that read audio from
/// a mapped file. It works a block at a time, so a four-hour track never sits in memory, and it
/// writes where it's told, so meeting audio stays inside the meeting folder.
public enum TrackResampler {
    private static let blockFrames: AVAudioFrameCount = 16384

    /// The number of samples written. Throws `CancellationError` if cancelled, and leaves no
    /// file behind when it throws.
    @discardableResult
    public static func writeRawMono(from url: URL, to output: URL, sampleRate: Double) throws -> Int {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let conversion = try Conversion(file: file, sampleRate: sampleRate, blockFrames: blockFrames)

        let manager = FileManager.default
        try? manager.removeItem(at: output)
        guard manager.createFile(atPath: output.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            return try conversion.run(into: handle)
        } catch {
            try? manager.removeItem(at: output)
            throw error
        }
    }
}

/// The converter and buffers for one track.
private struct Conversion {
    let converter: AVAudioConverter
    let source: BlockSource
    let converted: AVAudioPCMBuffer

    init(file: AVAudioFile, sampleRate: Double, blockFrames: AVAudioFrameCount) throws {
        let fileRate = file.processingFormat.sampleRate
        guard let mono = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: fileRate,
                  channels: 1,
                  interleaved: false,
              ),
              let target = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: sampleRate,
                  channels: 1,
                  interleaved: false,
              ),
              let converter = AVAudioConverter(from: mono, to: target),
              let reading = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: blockFrames),
              let input = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: blockFrames),
              let converted = AVAudioPCMBuffer(
                  pcmFormat: target,
                  frameCapacity: AVAudioFrameCount(Double(blockFrames) * sampleRate / fileRate) + 64,
              )
        else {
            throw CocoaError(.fileReadUnknown)
        }
        self.converter = converter
        self.converted = converted
        source = BlockSource(file: file, reading: reading, input: input)
    }

    func run(into handle: FileHandle) throws -> Int {
        var written = 0
        while true {
            try Task.checkCancellation()
            converted.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
                source.next(outStatus)
            }
            if let conversionError {
                throw conversionError
            }
            if let failure = source.failure {
                throw failure
            }
            let frames = Int(converted.frameLength)
            if frames > 0 {
                try handle.write(contentsOf: Data(
                    bytes: converted.floatChannelData![0],
                    count: frames * MemoryLayout<Float>.size,
                ))
                written += frames
            }
            if status == .endOfStream || status == .error || (frames == 0 && source.isFinished) {
                return written
            }
        }
    }
}

/// Feeds the converter the track's first channel, a block at a time.
private final class BlockSource {
    private let file: AVAudioFile
    private let reading: AVAudioPCMBuffer
    private let input: AVAudioPCMBuffer
    private(set) var isFinished = false
    private(set) var failure: any Error?

    init(file: AVAudioFile, reading: AVAudioPCMBuffer, input: AVAudioPCMBuffer) {
        self.file = file
        self.reading = reading
        self.input = input
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        // A single read can return early with frames still to come (see docs/NOTES.md).
        guard !isFinished, file.framePosition < file.length else {
            isFinished = true
            status.pointee = .endOfStream
            return nil
        }
        do {
            try file.read(into: reading)
        } catch {
            failure = error
            isFinished = true
            status.pointee = .endOfStream
            return nil
        }
        let frames = Int(reading.frameLength)
        guard frames > 0 else {
            isFinished = true
            status.pointee = .endOfStream
            return nil
        }
        input.floatChannelData![0].update(from: reading.floatChannelData![0], count: frames)
        input.frameLength = reading.frameLength
        status.pointee = .haveData
        return input
    }
}
