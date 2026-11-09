// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesDiarization
import MinutesPipeline
import MinutesStorage
import Testing

private struct Boom: Error {}

/// One word a second: the first voice from 0 to 7 s, the second from 10 to 17 s.
private let twoVoices = (0 ..< 8).map { TranscriptWord(text: "a\($0)", start: Double($0), end: Double($0) + 0.8) }
    + (10 ..< 18).map { TranscriptWord(text: "b\($0)", start: Double($0), end: Double($0) + 0.8) }

private func twoVoiceSetup() throws -> TestSetup {
    let setup = try TestSetup()
    setup.engine.state.withLock { $0.systemWords = twoVoices }
    setup.diarizer.state.withLock {
        $0.diarization = Diarization(
            turns: [SpeakerTurn(speaker: "A", start: 0, end: 8), SpeakerTurn(speaker: "B", start: 9.5, end: 18)],
            embeddings: ["A": [1, 0.05], "B": [0.6, 0.6]],
        )
    }
    return setup
}

private func run(_ setup: TestSetup, _ folder: MeetingFolder) async throws -> PipelineResult {
    try await setup.pipeline.run(at: MeetingLocation(folder: folder))
}

private func speakers(_ folder: MeetingFolder) throws -> [String] {
    try folder.loadTranscript().segments.map(\.speaker)
}

private func readable(_ folder: MeetingFolder) throws -> String {
    try String(contentsOf: folder.transcriptMarkdown, encoding: .utf8)
}

/// What the queue's Transcribe Again does to the meeting's files.
private func startOver(_ folder: MeetingFolder) throws {
    try? FileManager.default.removeItem(at: folder.processingFolder)
    try folder.updateMetadata { $0.processing = ProcessingState(completedSteps: [.cleanMic]) }
}

@Test func `the other voices are told apart and numbered by who speaks first`() async throws {
    let setup = try twoVoiceSetup()
    let folder = try setup.makeMeeting()
    #expect(try await run(setup, folder) == .complete)
    #expect(try speakers(folder) == ["speaker-1", "me", "speaker-2"])
    #expect(setup.diarizer.calls == 1)
    #expect(try folder.loadMetadata().processing?.completedSteps == ProcessingStep.allCases)
    #expect(try readable(folder).contains("**Speaker 1** 0:00"))
    #expect(try readable(folder).contains("**Speaker 2** 0:10"))
    // The voices were only ever in `.processing`.
    #expect(!FileManager.default.fileExists(atPath: folder.processingFolder.path))
}

@Test func `me is shown with your name`() async throws {
    let setup = try twoVoiceSetup()
    setup.yourName.withLock { $0 = " Ross " }
    let folder = try setup.makeMeeting()
    _ = try await run(setup, folder)
    #expect(try folder.loadMetadata().speakers?["me"]?.name == "Ross")
    #expect(try readable(folder).contains("**Ross** 0:03"))
}

@Test func `without the model the others stay as Others and the meeting still finishes`() async throws {
    let setup = try twoVoiceSetup()
    setup.diarizer.state.withLock { $0.status = .notInstalled }
    let folder = try setup.makeMeeting()
    #expect(try await run(setup, folder) == .complete)
    #expect(try Set(speakers(folder)) == ["others", "me"])
    #expect(setup.diarizer.calls == 0)
}

@Test func `a diarizer that fails leaves Others and the meeting still finishes`() async throws {
    let setup = try twoVoiceSetup()
    setup.diarizer.state.withLock { $0.failure = Boom() }
    let folder = try setup.makeMeeting()
    #expect(try await run(setup, folder) == .complete)
    #expect(try Set(speakers(folder)) == ["others", "me"])
}

@Test func `with no system track there's nobody to tell apart`() async throws {
    let setup = try twoVoiceSetup()
    let folder = try setup.makeMeeting(system: false)
    #expect(try await run(setup, folder) == .complete)
    #expect(setup.diarizer.calls == 0)
}

@Test func `a run cut off while diarizing resumes there without transcribing again`() async throws {
    let setup = try twoVoiceSetup()
    let gate = Gate()
    setup.diarizer.state.withLock { $0.gate = gate }
    let folder = try setup.makeMeeting()
    let task = Task { try await run(setup, folder) }
    await gate.arrival()
    task.cancel()
    gate.open()
    await #expect(throws: CancellationError.self) {
        try await task.value
    }
    #expect(try folder.loadMetadata().processing?.completedSteps == [.cleanMic, .transcribeMic, .transcribeSystem])

    setup.diarizer.state.withLock { $0.gate = nil }
    #expect(try await run(setup, folder) == .complete)
    #expect(setup.engine.calls.count == 2)
    #expect(setup.diarizer.calls == 2)
    #expect(try speakers(folder) == ["speaker-1", "me", "speaker-2"])
}

@Test func `a meeting renamed while diarizing finishes at its new place`() async throws {
    let setup = try twoVoiceSetup()
    let gate = Gate()
    setup.diarizer.state.withLock { $0.gate = gate }
    let folder = try setup.makeMeeting()
    let location = MeetingLocation(folder: folder)
    let task = Task { try await setup.pipeline.run(at: location) }
    await gate.arrival()
    let renamed = try location.move { try setup.library.rename($0, to: "Budget") }
    gate.open()
    #expect(try await task.value == .complete)
    #expect(try speakers(renamed) == ["speaker-1", "me", "speaker-2"])
    #expect(!FileManager.default.fileExists(atPath: folder.url.path))
}

// MARK: - Speaker memory

private func saveProfiles(_ setup: TestSetup) throws -> (dana: SpeakerProfile, sam: SpeakerProfile) {
    let store = setup.library.speakerProfiles
    func sample(_ embedding: [Float]) -> VoiceSample {
        VoiceSample(meeting: UUID(), recordedAt: Date(timeIntervalSince1970: 1_700_000_000), seconds: 30,
                    embedding: embedding)
    }
    return try (store.addSample(sample([1, 0]), toProfileNamed: "Dana"),
                store.addSample(sample([0, 1]), toProfileNamed: "Sam"))
}

@Test func `remembered voices name people, and an unsure match is only a suggestion`() async throws {
    let setup = try twoVoiceSetup()
    setup.remembersVoices.withLock { $0 = true }
    let (dana, sam) = try saveProfiles(setup)
    let folder = try setup.makeMeeting()
    _ = try await run(setup, folder)

    let names = try #require(try folder.loadMetadata().speakers)
    #expect(names["speaker-1"]?.name == "Dana")
    #expect(names["speaker-1"]?.profile == dana.id)
    // Equally like both, and Dana is taken.
    #expect(names["speaker-2"]?.name == nil)
    #expect(names["speaker-2"]?.suggestion == MeetingMetadata.Suggestion(name: "Sam", profile: sam.id))
    #expect(try readable(folder).contains("**Dana** 0:00"))
}

@Test func `with speaker memory off, saved voices aren't used`() async throws {
    let setup = try twoVoiceSetup()
    _ = try saveProfiles(setup)
    let folder = try setup.makeMeeting()
    _ = try await run(setup, folder)
    #expect(try folder.loadMetadata().speakers == nil)
}

@Test func `transcribing again keeps names even when the speakers are numbered differently`() async throws {
    let setup = try twoVoiceSetup()
    let folder = try setup.makeMeeting()
    _ = try await run(setup, folder)
    try folder.nameSpeaker("speaker-1", "Dana")
    try folder.nameSpeaker("speaker-2", "Sam")

    // This time a word of the second voice comes first, so the numbers swap.
    setup.engine.state.withLock {
        $0.systemWords = [TranscriptWord(text: "early", start: 0, end: 0.2)] + twoVoices.dropFirst()
    }
    setup.diarizer.state.withLock {
        $0.diarization.turns = [
            SpeakerTurn(speaker: "B", start: 0, end: 0.5),
            SpeakerTurn(speaker: "A", start: 0.5, end: 8),
            SpeakerTurn(speaker: "B", start: 9.5, end: 18),
        ]
    }
    try startOver(folder)
    #expect(try await run(setup, folder) == .complete)

    let transcript = try folder.loadTranscript()
    let metadata = try folder.loadMetadata()
    let first = try #require(transcript.segments.first { $0.text.hasPrefix("a1") })
    let second = try #require(transcript.segments.first { $0.text.hasPrefix("b10") })
    #expect(metadata.displayName(forSpeaker: first.speaker) == "Dana")
    #expect(metadata.displayName(forSpeaker: second.speaker) == "Sam")
}

@Test func `identify speakers tells apart an older meeting without transcribing it again`() async throws {
    let setup = try twoVoiceSetup()
    setup.diarizer.state.withLock { $0.status = .notInstalled }
    let folder = try setup.makeMeeting()
    _ = try await run(setup, folder)
    #expect(try Set(speakers(folder)) == ["others", "me"])

    setup.diarizer.state.withLock { $0.status = .installed }
    try MeetingPipeline.prepareToIdentifySpeakers(folder)
    #expect(try await run(setup, folder) == .complete)
    #expect(try speakers(folder) == ["speaker-1", "me", "speaker-2"])
    #expect(setup.engine.calls.count == 2)
    #expect(try folder.loadTranscript().segments.contains { $0.text == "my tannium" })
}

// MARK: - Naming

private func finishedMeeting(_ setup: TestSetup) async throws -> MeetingFolder {
    let folder = try setup.makeMeeting()
    _ = try await run(setup, folder)
    return folder
}

@Test func `naming someone with memory on saves their voice from their lines`() async throws {
    let setup = try twoVoiceSetup()
    setup.remembersVoices.withLock { $0 = true }
    let folder = try await finishedMeeting(setup)
    #expect(try await setup.naming.name("speaker-1", in: folder, to: "Dana") == .remembered)

    let profile = try #require(setup.library.speakerProfiles.profiles().first)
    #expect(profile.name == "Dana")
    #expect(try profile.samples.map(\.meeting) == [folder.loadMetadata().id])
    #expect(try folder.loadMetadata().speakers?["speaker-1"]?.profile == profile.id)
    // Their one line, from the first word's start to the last word's end.
    #expect(setup.diarizer.state.withLock { $0.embeddingSpans } == [[0 ... 7.8]])
    // The work folder is gone.
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.url.path).filter { $0.hasPrefix(".") }
    #expect(leftovers.isEmpty)
}

@Test func `with memory off, naming saves nothing`() async throws {
    let setup = try twoVoiceSetup()
    let folder = try await finishedMeeting(setup)
    #expect(try await setup.naming.name("speaker-1", in: folder, to: "Dana") == .named)
    #expect(!FileManager.default.fileExists(atPath: setup.library.speakersFolder.path))
    #expect(try folder.loadMetadata().speakers?["speaker-1"]?.name == "Dana")
}

@Test func `a speaker heard for under five seconds is named but not remembered`() async throws {
    let setup = try twoVoiceSetup()
    setup.remembersVoices.withLock { $0 = true }
    setup.engine.state.withLock { $0.systemWords = Array(twoVoices.prefix(3)) + twoVoices.suffix(8) }
    let folder = try await finishedMeeting(setup)
    #expect(try await setup.naming.name("speaker-1", in: folder, to: "Dana") == .notEnoughSpeech)
    #expect(setup.library.speakerProfiles.profiles().isEmpty)
    #expect(try folder.loadMetadata().speakers?["speaker-1"]?.name == "Dana")
}

@Test func `correcting a name moves this meeting's voice to the right person`() async throws {
    let setup = try twoVoiceSetup()
    setup.remembersVoices.withLock { $0 = true }
    let folder = try await finishedMeeting(setup)
    try await setup.naming.name("speaker-1", in: folder, to: "Dana")
    try await setup.naming.name("speaker-1", in: folder, to: "Sam")
    #expect(setup.library.speakerProfiles.profiles().map(\.name) == ["Sam"])

    try await setup.naming.name("speaker-1", in: folder, to: nil)
    #expect(setup.library.speakerProfiles.profiles().isEmpty)
    #expect(try folder.loadMetadata().speakers == nil)
}

@Test func `your own voice is never saved`() async throws {
    let setup = try twoVoiceSetup()
    setup.remembersVoices.withLock { $0 = true }
    let folder = try await finishedMeeting(setup)
    #expect(try await setup.naming.name("me", in: folder, to: "Ross") == .named)
    #expect(setup.library.speakerProfiles.profiles().isEmpty)
}

@Test func `merging measures the kept speaker again from all their lines`() async throws {
    let setup = try twoVoiceSetup()
    setup.remembersVoices.withLock { $0 = true }
    let folder = try await finishedMeeting(setup)
    try await setup.naming.name("speaker-1", in: folder, to: "Dana")
    try await setup.naming.merge("speaker-2", into: "speaker-1", in: folder)
    #expect(try speakers(folder).filter { $0 != "me" } == ["speaker-1", "speaker-1"])
    #expect(setup.diarizer.state.withLock { $0.embeddingSpans.last } == [0 ... 7.8, 10 ... 17.8])
    #expect(setup.library.speakerProfiles.profiles().first?.samples.count == 1)
}

@Test func `naming waits while the meeting is processing`() async throws {
    let setup = try twoVoiceSetup()
    let folder = try await finishedMeeting(setup)
    try folder.updateMetadata { $0.processing?.status = .queued }
    await #expect(throws: MeetingFolder.SpeakerEditError.meetingBusy) {
        try await setup.naming.name("speaker-1", in: folder, to: "Dana")
    }
}
