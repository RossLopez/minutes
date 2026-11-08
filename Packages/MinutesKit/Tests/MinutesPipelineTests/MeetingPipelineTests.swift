// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesPipeline
import MinutesStorage
import MinutesTranscription
import Testing

private func run(_ setup: TestSetup, _ folder: MeetingFolder) async throws -> PipelineResult {
    try await setup.pipeline.run(at: MeetingLocation(folder: folder))
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

private struct Boom: Error {}

@Test func `a meeting ends with both transcript files, a clean mic and nothing left over`() async throws {
    let setup = try TestSetup()
    let folder = try setup.makeMeeting()
    #expect(try await run(setup, folder) == .complete)

    let transcript = try folder.loadTranscript()
    #expect(transcript.engine == "fake")
    #expect(transcript.model == "fake model")
    #expect(transcript.segments.map(\.speaker) == [Transcript.Speaker.others, Transcript.Speaker.me])
    #expect(transcript.segments.map(\.text) == ["their line", "my tannium"])
    #expect(exists(folder.transcriptMarkdown))
    #expect(exists(folder.cleanedMicAudio))
    #expect(!exists(folder.processingFolder))

    let state = try #require(try folder.loadMetadata().processing)
    #expect(state.status == .complete)
    #expect(state.completedSteps == ProcessingStep.allCases)
}

@Test func `the original tracks are never changed`() async throws {
    let setup = try TestSetup()
    let folder = try setup.makeMeeting()
    _ = try await run(setup, folder)
    #expect(try Data(contentsOf: folder.micAudio) == Data("mic audio".utf8))
    #expect(try Data(contentsOf: folder.systemAudio) == Data("system audio".utf8))
}

@Test func `the mic is transcribed from the cleaned track`() async throws {
    let setup = try TestSetup()
    let folder = try setup.makeMeeting()
    _ = try await run(setup, folder)
    #expect(setup.engine.calls == ["mic.m4a", "system.m4a"])
}

@Test func `vocabulary corrects the transcript and reaches the engine`() async throws {
    let setup = try TestSetup()
    let entry = VocabularyEntry(term: "Tanium", variants: ["tannium"])
    setup.vocabulary.withLock { $0 = [entry] }
    let folder = try setup.makeMeeting()
    _ = try await run(setup, folder)
    #expect(try folder.loadTranscript().segments.last?.text == "my Tanium")
    #expect(setup.engine.state.withLock { $0.vocabularies } == [[entry], [entry]])
}

// MARK: - Missing tracks

@Test func `only a mic track still makes a transcript`() async throws {
    let setup = try TestSetup()
    let folder = try setup.makeMeeting(system: false)
    #expect(try await run(setup, folder) == .complete)
    #expect(setup.engine.calls == ["mic.m4a"])
    #expect(try folder.loadTranscript().segments.map(\.speaker) == [Transcript.Speaker.me])
}

@Test func `only a system track still makes a transcript`() async throws {
    let setup = try TestSetup()
    let folder = try setup.makeMeeting(mic: false)
    #expect(try await run(setup, folder) == .complete)
    #expect(setup.cleaner.calls == 0)
    #expect(setup.engine.calls == ["system.m4a"])
    #expect(try folder.loadTranscript().segments.map(\.speaker) == [Transcript.Speaker.others])
}

@Test func `no tracks at all make an empty transcript`() async throws {
    let setup = try TestSetup()
    let folder = try setup.makeMeeting(mic: false, system: false)
    #expect(try await run(setup, folder) == .complete)
    #expect(try folder.loadTranscript().segments.isEmpty)
}

// MARK: - Resuming

@Test(arguments: [0, 1, 2])
func `a run cut off at any step resumes without redoing finished work`(completed: Int) async throws {
    let setup = try TestSetup()
    let folder = try setup.makeMeeting()
    let location = MeetingLocation(folder: folder)
    let gate = Gate()
    switch completed {
    case 0: setup.cleaner.state.withLock { $0.gate = gate }
    default: setup.engine.state.withLock { $0.gate = gate }
    }
    if completed == 2 {
        // Let the mic through, and hold the system track.
        setup.engine.state.withLock { state in
            state.gate = nil
            state.duringCall = { [engine = setup.engine] in
                engine.state.withLock { $0.gate = gate }
            }
        }
    }
    let task = Task {
        try await setup.pipeline.run(at: location)
    }
    await gate.arrival()
    task.cancel()
    gate.open()
    await #expect(throws: CancellationError.self) {
        try await task.value
    }
    let state = try #require(try folder.loadMetadata().processing)
    #expect(state.status == .queued)
    #expect(state.completedSteps == Array(ProcessingStep.allCases.prefix(completed)))
    #expect(!exists(folder.transcriptJSON))

    let cleansBefore = setup.cleaner.calls
    let callsBefore = setup.engine.calls.count
    setup.engine.state.withLock {
        $0.gate = nil
        $0.duringCall = nil
    }
    setup.cleaner.state.withLock { $0.gate = nil }

    // A new pipeline, as after a relaunch.
    #expect(try await run(setup, folder) == .complete)
    #expect(try folder.loadTranscript().segments.count == 2)
    #expect(setup.cleaner.calls - cleansBefore == (completed == 0 ? 1 : 0))
    let redone = setup.engine.calls.dropFirst(callsBefore)
    #expect(Array(redone) == ["mic.m4a", "system.m4a"].suffix(completed == 0 ? 2 : (completed == 1 ? 2 : 1)))
}

@Test func `a step marked finished runs again if its output has gone`() async throws {
    let setup = try TestSetup()
    let folder = try setup.makeMeeting()
    try folder.updateMetadata { metadata in
        metadata.processing = ProcessingState(completedSteps: [.cleanMic, .transcribeMic, .transcribeSystem])
    }
    #expect(try await run(setup, folder) == .complete)
    #expect(setup.cleaner.calls == 1)
    #expect(setup.engine.calls == ["mic.m4a", "system.m4a"])
}

@Test func `a resumed run keeps the engine it started with`() async throws {
    let setup = try TestSetup()
    let folder = try setup.makeMeeting()
    let gate = Gate()
    setup.engine.state.withLock { state in
        state.duringCall = { [engine = setup.engine] in
            engine.state.withLock { $0.gate = gate }
        }
    }
    let task = Task {
        try await setup.pipeline.run(at: MeetingLocation(folder: folder))
    }
    await gate.arrival()
    task.cancel()
    gate.open()
    _ = try? await task.value

    setup.preferred.withLock { $0 = "other" }
    setup.engine.state.withLock {
        $0.gate = nil
        $0.duringCall = nil
    }
    #expect(try await run(setup, folder) == .complete)
    #expect(try folder.loadTranscript().engine == "fake")
    #expect(setup.other.calls.isEmpty)
}

@Test func `a run that hasn't transcribed anything uses the current engine`() async throws {
    let setup = try TestSetup()
    let folder = try setup.makeMeeting()
    try folder.updateMetadata { metadata in
        metadata.processing = ProcessingState(completedSteps: [.cleanMic], engine: "fake")
    }
    setup.preferred.withLock { $0 = "other" }
    _ = try await run(setup, folder)
    #expect(try folder.loadTranscript().engine == "other")
}

// MARK: - Models

@Test func `no model means waiting, and never a download`() async throws {
    let setup = try TestSetup(status: .notInstalled)
    let folder = try setup.makeMeeting()
    #expect(try await run(setup, folder) == .waitingForModel(engine: "fake"))
    #expect(setup.engine.state.withLock { $0.installs } == 0)
    #expect(setup.engine.calls.isEmpty)
    #expect(exists(folder.cleanedMicAudio))
    #expect(try folder.loadMetadata().processing?.status == .waitingForModel)
}

@Test func `waiting meetings go on once the model arrives, without cleaning again`() async throws {
    let setup = try TestSetup(status: .notInstalled)
    let folder = try setup.makeMeeting()
    _ = try await run(setup, folder)
    try await setup.engine.installModel { _ in }
    #expect(try await run(setup, folder) == .complete)
    #expect(setup.cleaner.calls == 1)
}

@Test func `an engine that can't run here reports why`() async throws {
    let setup = try TestSetup(status: .unavailable("Not on this Mac."))
    let folder = try setup.makeMeeting()
    #expect(try await run(setup, folder) == .failed("Not on this Mac."))
    #expect(try folder.loadMetadata().processing?.failure == "Not on this Mac.")
}

@Test func `an unknown engine fails with a way forward`() async throws {
    let setup = try TestSetup()
    setup.preferred.withLock { $0 = "gone" }
    let folder = try setup.makeMeeting()
    let result = try await run(setup, folder)
    guard case let .failed(message) = result else {
        Issue.record("Expected a failure, got \(result)")
        return
    }
    #expect(message.contains("Settings"))
}

// MARK: - Failures

@Test func `a failure is recorded, the audio is safe and a retry finishes`() async throws {
    let setup = try TestSetup()
    let folder = try setup.makeMeeting()
    setup.engine.state.withLock { $0.failure = Boom() }

    let result = try await run(setup, folder)
    guard case .failed = result else {
        Issue.record("Expected a failure, got \(result)")
        return
    }
    let state = try #require(try folder.loadMetadata().processing)
    #expect(state.status == .failed)
    #expect(state.completedSteps == [.cleanMic])
    #expect(state.failure?.isEmpty == false)
    #expect(exists(folder.micAudio))
    #expect(!exists(folder.transcriptJSON))

    #expect(try await run(setup, folder) == .complete)
    #expect(try folder.loadMetadata().processing?.failure == nil)
}

@Test func `a full disk says so`() async throws {
    let setup = try TestSetup()
    let folder = try setup.makeMeeting()
    setup.cleaner.state.withLock { $0.failure = CocoaError(.fileWriteOutOfSpace) }
    let result = try await run(setup, folder)
    #expect(result == .failed("Your disk is full. Free up some space and try again."))
}

@Test func `a folder from a newer version is left alone`() async throws {
    let setup = try TestSetup()
    let folder = try setup.makeMeeting()
    var metadata = try folder.loadMetadata()
    metadata.schemaVersion = MeetingMetadata.currentSchemaVersion + 1
    try folder.save(metadata)
    let before = try Data(contentsOf: folder.metadataURL)

    let result = try await run(setup, folder)
    guard case .failed = result else {
        Issue.record("Expected a failure, got \(result)")
        return
    }
    #expect(try Data(contentsOf: folder.metadataURL) == before)
    #expect(setup.cleaner.calls == 0)
}

// MARK: - Renaming

@Test func `renaming during transcription sends the finished files to the new folder`() async throws {
    let setup = try TestSetup()
    let folder = try setup.makeMeeting()
    let location = MeetingLocation(folder: folder)
    let gate = Gate()
    setup.engine.state.withLock { $0.gate = gate }
    let task = Task {
        try await setup.pipeline.run(at: location)
    }
    await gate.arrival()
    let renamed = try location.move { try setup.library.rename($0, to: "Budget") }
    gate.open()
    #expect(try await task.value == .complete)

    #expect(!exists(folder.url))
    #expect(exists(renamed.transcriptJSON))
    #expect(!exists(renamed.processingFolder))
    #expect(try String(contentsOf: renamed.transcriptMarkdown, encoding: .utf8).hasPrefix("# Budget\n"))
    let metadata = try renamed.loadMetadata()
    #expect(metadata.title == "Budget")
    #expect(metadata.processing?.status == .complete)
}

@Test func `a step that loses its files to a rename starts over`() async throws {
    let setup = try TestSetup()
    let folder = try setup.makeMeeting()
    let location = MeetingLocation(folder: folder)
    let gate = Gate()
    setup.cleaner.state.withLock { $0.gate = gate }
    let task = Task {
        try await setup.pipeline.run(at: location)
    }
    await gate.arrival()
    // The fake cleaner copies by its old path, which no longer exists once the folder moves.
    let renamed = try location.move { try setup.library.rename($0, to: "Budget") }
    setup.cleaner.state.withLock { $0.gate = nil }
    gate.open()
    #expect(try await task.value == .complete)
    #expect(setup.cleaner.calls == 2)
    #expect(exists(renamed.cleanedMicAudio))
}
