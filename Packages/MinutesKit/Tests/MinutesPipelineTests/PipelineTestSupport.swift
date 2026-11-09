// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesAudio
import MinutesDiarization
import MinutesPipeline
import MinutesStorage
import MinutesTranscription
import Synchronization
import Testing

/// Lets a test hold a step open, and know when it got there.
final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var hasArrived = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// Called by the code being held. Returns when the gate opens.
    func pass() async {
        let arrivals = state.withLock { state in
            state.hasArrived = true
            defer { state.arrivalWaiters = [] }
            return state.arrivalWaiters
        }
        arrivals.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            let openAlready = state.withLock { state in
                if !state.isOpen {
                    state.waiters.append(continuation)
                }
                return state.isOpen
            }
            if openAlready {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }

    func arrival() async {
        await withCheckedContinuation { continuation in
            let arrived = state.withLock { state in
                if !state.hasArrived {
                    state.arrivalWaiters.append(continuation)
                }
                return state.hasArrived
            }
            if arrived {
                continuation.resume()
            }
        }
    }
}

/// Hears a fixed line for each file, and counts what it's asked to do.
final class FakeEngine: TranscriptionEngine, Sendable {
    struct State {
        var status = TranscriptionModelStatus.installed
        var calls: [String] = []
        var installs = 0
        var vocabularies: [[VocabularyEntry]] = []
        var failure: any Error?
        var gate: Gate?
        var duringCall: (@Sendable () -> Void)?
        /// What the system track says, instead of "their line".
        var systemWords: [TranscriptWord]?
    }

    let id: String
    let modelName = "fake model"
    let downloadSizeBytes: Int64? = 1000
    let canRemoveModel = true
    let state: Mutex<State>

    init(id: String = "fake", status: TranscriptionModelStatus = .installed) {
        self.id = id
        state = Mutex(State(status: status))
    }

    var calls: [String] {
        state.withLock { $0.calls }
    }

    func modelStatus() async -> TranscriptionModelStatus {
        state.withLock { $0.status }
    }

    func installModel(progress _: @escaping @Sendable (Double) -> Void) async throws {
        state.withLock {
            $0.installs += 1
            $0.status = .installed
        }
    }

    func removeModel() async throws {
        state.withLock { $0.status = .notInstalled }
    }

    func transcribe(
        audio: URL,
        vocabulary: [VocabularyEntry],
        workFolder: URL,
        progress: @escaping @Sendable (Double) -> Void,
    ) async throws -> [TranscriptWord] {
        let (gate, failure, duringCall, systemWords) = state.withLock { state in
            state.calls.append(audio.lastPathComponent)
            state.vocabularies.append(vocabulary)
            defer { state.failure = nil }
            return (state.gate, state.failure, state.duringCall, state.systemWords)
        }
        #expect(FileManager.default.fileExists(atPath: workFolder.path))
        progress(0.5)
        await gate?.pass()
        duringCall?()
        try Task.checkCancellation()
        if let failure {
            throw failure
        }
        if audio.lastPathComponent == "system.m4a", let systemWords {
            return systemWords
        }
        return audio.lastPathComponent == "system.m4a"
            ? [TranscriptWord(text: "their", start: 1, end: 1.5), TranscriptWord(text: "line", start: 1.5, end: 2)]
            : [TranscriptWord(text: "my", start: 3, end: 3.5), TranscriptWord(text: "tannium", start: 3.5, end: 4)]
    }
}

/// Hears the turns it's given, and counts what it's asked to do.
final class FakeDiarizer: SpeakerDiarizer, Sendable {
    struct State {
        var status = DiarizationModelStatus.installed
        var diarization = Diarization(turns: [])
        var calls = 0
        var embeddingSpans: [[ClosedRange<Double>]] = []
        var embedding: [Float] = [1, 0]
        var failure: any Error?
        var gate: Gate?
    }

    let id = "fake-diarizer"
    let modelName = "fake diarizer"
    let downloadSizeBytes: Int64 = 100
    let state = Mutex(State())

    var calls: Int {
        state.withLock { $0.calls }
    }

    func modelStatus() async -> DiarizationModelStatus {
        state.withLock { $0.status }
    }

    func installModel(progress _: @escaping @Sendable (Double) -> Void) async throws {
        state.withLock { $0.status = .installed }
    }

    func removeModel() async throws {
        state.withLock { $0.status = .notInstalled }
    }

    func diarize(
        audio: URL,
        workFolder: URL,
        progress: @escaping @Sendable (Double) -> Void,
    ) async throws -> Diarization {
        #expect(audio.lastPathComponent == "system.m4a")
        #expect(FileManager.default.fileExists(atPath: workFolder.path))
        let (gate, failure, diarization) = state.withLock { state in
            state.calls += 1
            defer { state.failure = nil }
            return (state.gate, state.failure, state.diarization)
        }
        progress(0.5)
        await gate?.pass()
        try Task.checkCancellation()
        if let failure {
            throw failure
        }
        return diarization
    }

    func embedding(audio _: URL, spans: [ClosedRange<Double>], workFolder: URL) async throws -> [Float] {
        #expect(FileManager.default.fileExists(atPath: workFolder.path))
        return state.withLock { state in
            state.embeddingSpans.append(spans)
            return state.embedding
        }
    }
}

/// Counts cleanups, and copies the input as its "cleaned" result.
final class FakeCleaner: Sendable {
    struct State {
        var calls = 0
        var gate: Gate?
        var failure: any Error?
    }

    let state = Mutex(State())

    var calls: Int {
        state.withLock { $0.calls }
    }

    var clean: MeetingPipeline.Cleaner {
        { [self] mic, _, output, _, _ in
            let (gate, failure) = state.withLock { state in
                state.calls += 1
                defer { state.failure = nil }
                return (state.gate, state.failure)
            }
            await gate?.pass()
            try Task.checkCancellation()
            if let failure {
                throw failure
            }
            try FileManager.default.copyItem(at: mic, to: output)
            return .copied
        }
    }
}

final class TestSetup: Sendable {
    let library: MinutesLibrary
    let engine: FakeEngine
    let cleaner = FakeCleaner()
    let preferred = Mutex("fake")
    let vocabulary = Mutex<[VocabularyEntry]>([])
    let other = FakeEngine(id: "other")
    let diarizer = FakeDiarizer()
    let remembersVoices = Mutex(false)
    let yourName = Mutex<String?>(nil)

    var naming: SpeakerNaming {
        SpeakerNaming(
            diarizer: { [diarizer] in diarizer },
            profiles: library.speakerProfiles,
            remembersVoices: { [self] in remembersVoices.withLock { $0 } },
        )
    }

    var pipeline: MeetingPipeline {
        MeetingPipeline(
            cleanMic: cleaner.clean,
            engineWithID: { [engine, other] id in
                [engine, other].first { $0.id == id }
            },
            preferredEngineID: { [self] in
                preferred.withLock { $0 }
            },
            vocabulary: { [self] in
                vocabulary.withLock { $0 }
            },
            diarizer: { [diarizer] in diarizer },
            speakerMemory: { [self] in
                remembersVoices.withLock { $0 } ? library.speakerProfiles : nil
            },
            yourName: { [self] in
                yourName.withLock { $0 }
            },
        )
    }

    init(status: TranscriptionModelStatus = .installed) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MinutesTests-\(UUID().uuidString)")
        library = MinutesLibrary(root: root)
        try library.prepareLayout()
        engine = FakeEngine(status: status)
    }
}

extension TestSetup {
    /// A finished meeting with both audio files, queued for processing.
    func makeMeeting(
        title: String = "Recording",
        startedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        mic: Bool = true,
        system: Bool = true,
    ) throws -> MeetingFolder {
        let folder = try library.createMeetingFolder(startedAt: startedAt, title: title)
        var metadata = MeetingMetadata(
            title: title,
            startedAt: startedAt,
            state: .complete,
            audioFormat: "aac",
            voiceProcessing: false,
        )
        metadata.processing = ProcessingState()
        try folder.save(metadata)
        if mic {
            try Data("mic audio".utf8).write(to: folder.micAudio)
        }
        if system {
            try Data("system audio".utf8).write(to: folder.systemAudio)
        }
        return folder
    }
}
