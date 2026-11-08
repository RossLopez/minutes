// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import AVFoundation
import MinutesAudio
@testable import MinutesPipeline
import MinutesStorage
import Testing

// MARK: - The rule

private let room: Float = -50
private let playing = LevelTimeline(decibels: [Float](repeating: -20, count: 100))
private let silent = LevelTimeline(decibels: [Float](repeating: -120, count: 100))

/// Room noise for ten seconds, with the given stretches louder.
private func mic(louder stretches: [ClosedRange<Int>: Float] = [:]) -> LevelTimeline {
    var blocks = [Float](repeating: room, count: 100)
    for (range, level) in stretches {
        for index in range {
            blocks[index] = level
        }
    }
    return LevelTimeline(decibels: blocks)
}

private func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptWord {
    TranscriptWord(text: text, start: start, end: end)
}

@Test func `a phrase as quiet as the room is dropped while the system track plays`() {
    let words = [word("and", 1, 1.2), word("she", 1.3, 1.5)]
    #expect(LeftoverEchoFilter.keeping(words, mic: mic(), system: playing).isEmpty)
}

@Test func `a phrase just under the margin is dropped and one at it stays`() {
    let words = [word("and", 1, 1.2)]
    let under = mic(louder: [10 ... 11: room + LeftoverEchoFilter.marginDecibels - 0.5])
    let over = mic(louder: [10 ... 11: room + LeftoverEchoFilter.marginDecibels + 0.5])
    #expect(LeftoverEchoFilter.keeping(words, mic: under, system: playing).isEmpty)
    #expect(LeftoverEchoFilter.keeping(words, mic: over, system: playing) == words)
}

@Test func `speech over the system track stays`() {
    let words = [word("hello", 1, 1.5)]
    let levels = mic(louder: [10 ... 14: -25])
    #expect(LeftoverEchoFilter.keeping(words, mic: levels, system: playing) == words)
}

@Test func `one audible word keeps its whole phrase`() {
    let words = [word("so", 1, 1.2), word("really", 1.3, 1.8), word("um", 1.9, 2.1)]
    let levels = mic(louder: [13 ... 17: -25])
    #expect(LeftoverEchoFilter.keeping(words, mic: levels, system: playing) == words)
}

@Test func `a quiet phrase is dropped without touching the loud one beside it`() {
    let loud = word("hello", 1, 1.5)
    let quiet = word("phantom", 3, 3.5)
    let levels = mic(louder: [10 ... 14: -25])
    #expect(LeftoverEchoFilter.keeping([loud, quiet], mic: levels, system: playing) == [loud])
}

@Test func `a quiet phrase with nothing playing is the user speaking softly`() {
    let words = [word("quietly", 1, 1.5)]
    #expect(LeftoverEchoFilter.keeping(words, mic: mic(), system: silent) == words)
}

@Test func `a quiet phrase right after the system track stops can still be echo`() {
    let stopping = LevelTimeline(decibels: [Float](repeating: -20, count: 10) + [Float](repeating: -120, count: 90))
    let words = [word("phantom", 1.2, 1.5)]
    #expect(LeftoverEchoFilter.keeping(words, mic: mic(), system: stopping).isEmpty)
}

@Test func `a mic track with no sound keeps every word`() {
    let words = [word("hello", 1, 1.5)]
    let noSound = LevelTimeline(decibels: [Float](repeating: -120, count: 100))
    #expect(LeftoverEchoFilter.keeping(words, mic: noSound, system: playing) == words)
}

@Test func `words past the end of the measured audio stay`() {
    let words = [word("late", 20, 20.5)]
    #expect(LeftoverEchoFilter.keeping(words, mic: mic(), system: playing) == words)
}

// MARK: - In the pipeline

/// `FakeEngine` hears the mic at 3 to 4 seconds and the system track at 1 to 2.
private enum TestAudio {
    static let rate = 48000.0

    /// Six seconds of sine at `amplitude`, or `loudAmplitude` from 3 to 4 seconds.
    static func write(to url: URL, amplitude: Float, loudAmplitude: Float? = nil) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let frames = AVAudioFrameCount(6 * rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for frame in 0 ..< Int(frames) {
            let seconds = Double(frame) / rate
            let level = (3 ... 4).contains(seconds) ? (loudAmplitude ?? amplitude) : amplitude
            buffer.floatChannelData![0][frame] = level * Float(sin(2 * .pi * 440 * seconds))
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000,
        ]
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false,
        )
        try file.write(from: buffer)
    }
}

private extension TestSetup {
    /// A pipeline whose cleaner writes a track that differs from the original.
    func pipeline(cleanedWith clean: @escaping @Sendable (URL) throws -> Void) -> MeetingPipeline {
        MeetingPipeline(
            cleanMic: { _, _, output, _, _ in
                try clean(output)
                return .cleaned(echoDecibels: -20)
            },
            engineWithID: { [engine] _ in engine },
            preferredEngineID: { "fake" },
            vocabulary: { [] },
        )
    }
}

private let roomAmplitude: Float = 0.003

private func makeRealMeeting(_ setup: TestSetup) throws -> MeetingFolder {
    let folder = try setup.makeMeeting()
    try TestAudio.write(to: folder.micAudio, amplitude: 0.05)
    try TestAudio.write(to: folder.systemAudio, amplitude: 0.2)
    return folder
}

@Test func `words heard in leftover echo don't reach the transcript`() async throws {
    let setup = try TestSetup()
    let folder = try makeRealMeeting(setup)
    let pipeline = setup.pipeline { try TestAudio.write(to: $0, amplitude: roomAmplitude) }
    #expect(try await pipeline.run(at: MeetingLocation(folder: folder)) == .complete)
    #expect(try folder.loadTranscript().segments.map(\.speaker) == [Transcript.Speaker.others])
}

@Test func `words clearly above the room reach the transcript`() async throws {
    let setup = try TestSetup()
    let folder = try makeRealMeeting(setup)
    let pipeline = setup.pipeline { try TestAudio.write(to: $0, amplitude: roomAmplitude, loudAmplitude: 0.05) }
    #expect(try await pipeline.run(at: MeetingLocation(folder: folder)) == .complete)
    #expect(try folder.loadTranscript().segments.map(\.speaker) == [
        Transcript.Speaker.others,
        Transcript.Speaker.me,
    ])
}

@Test func `with no echo found every word stays, however quiet`() async throws {
    let setup = try TestSetup()
    let folder = try setup.makeMeeting()
    try TestAudio.write(to: folder.micAudio, amplitude: roomAmplitude)
    try TestAudio.write(to: folder.systemAudio, amplitude: 0.2)
    #expect(try await setup.pipeline.run(at: MeetingLocation(folder: folder)) == .complete)
    #expect(try folder.loadTranscript().segments.contains { $0.speaker == Transcript.Speaker.me })
}

@Test func `audio that can't be measured keeps every word`() async throws {
    let setup = try TestSetup()
    let folder = try setup.makeMeeting()
    let pipeline = setup.pipeline { try Data("not audio".utf8).write(to: $0) }
    #expect(try await pipeline.run(at: MeetingLocation(folder: folder)) == .complete)
    #expect(try folder.loadTranscript().segments.contains { $0.speaker == Transcript.Speaker.me })
}
