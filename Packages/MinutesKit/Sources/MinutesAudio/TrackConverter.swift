// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import AVFoundation

/// Converts a track's device rate to 48 kHz. Runs off the audio thread.
final class TrackConverter {
    private final class InputState {
        var buffer: AVAudioPCMBuffer?
    }

    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(TrackTimeline.sampleRate),
        channels: 1,
        interleaved: false,
    )!
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ samples: UnsafePointer<Float>, frames: Int, rate: Double) -> [Float] {
        guard rate != Double(TrackTimeline.sampleRate), rate > 0 else {
            return Array(UnsafeBufferPointer(start: samples, count: frames))
        }
        if inputFormat?.sampleRate != rate {
            inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: rate,
                channels: 1,
                interleaved: false,
            )
            converter = inputFormat.flatMap { AVAudioConverter(from: $0, to: outputFormat) }
        }
        guard let converter, let inputFormat,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames))
        else {
            return []
        }
        input.frameLength = AVAudioFrameCount(frames)
        input.floatChannelData![0].update(from: samples, count: frames)

        let capacity = AVAudioFrameCount((Double(frames) * Double(TrackTimeline.sampleRate) / rate).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return []
        }

        let state = InputState()
        state.buffer = input
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard let buffer = state.buffer else {
                status.pointee = .noDataNow
                return nil
            }
            state.buffer = nil
            status.pointee = .haveData
            return buffer
        }
        guard error == nil else {
            return []
        }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
