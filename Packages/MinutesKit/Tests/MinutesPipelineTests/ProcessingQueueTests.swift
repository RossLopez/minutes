// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesPipeline
import MinutesStorage
import MinutesTranscription
import Testing

private func status(_ folder: MeetingFolder) throws -> ProcessingState.Status? {
    try folder.loadMetadata().processing?.status
}

/// Waits until the queue has nothing left, using its own change signal.
@MainActor
private func finished(_ queue: ProcessingQueue) async {
    while queue.isBusy {
        await withCheckedContinuation { continuation in
            withObservationTracking {
                _ = queue.activity
            } onChange: {
                continuation.resume()
            }
        }
        await Task.yield()
    }
}

@MainActor
@Test func `meetings run one at a time, oldest first`() async throws {
    let setup = try TestSetup()
    let gate = Gate()
    setup.engine.state.withLock { $0.gate = gate }
    let newer = try setup.makeMeeting(title: "Newer", startedAt: Date(timeIntervalSince1970: 2_000_000_000))
    let older = try setup.makeMeeting(title: "Older", startedAt: Date(timeIntervalSince1970: 1_000_000_000))
    let oldest = try setup.makeMeeting(title: "Oldest", startedAt: Date(timeIntervalSince1970: 500_000_000))

    let queue = ProcessingQueue(pipeline: setup.pipeline)
    var finishedOrder: [URL] = []
    queue.onFinish = { finishedOrder.append($0) }
    queue.enqueue(newer.url)
    queue.enqueue(older.url)
    queue.enqueue(oldest.url)
    #expect(queue.activity?.folder == newer.url)
    await gate.arrival()
    gate.open()
    await finished(queue)
    // The first was already under way. The other two go by age.
    #expect(finishedOrder == [newer.url, oldest.url, older.url])
    #expect(setup.engine.calls.count == 6)
}

@MainActor
@Test func `enqueuing twice runs once`() async throws {
    let setup = try TestSetup()
    let folder = try setup.makeMeeting()
    let queue = ProcessingQueue(pipeline: setup.pipeline)
    queue.enqueue(folder.url)
    queue.enqueue(folder.url)
    await finished(queue)
    #expect(setup.cleaner.calls == 1)
}

@MainActor
@Test func `stopping stays stopped until resumed, across launches`() async throws {
    let setup = try TestSetup()
    let folder = try setup.makeMeeting()
    let gate = Gate()
    setup.engine.state.withLock { $0.gate = gate }
    let queue = ProcessingQueue(pipeline: setup.pipeline)
    queue.enqueue(folder.url)
    await gate.arrival()
    queue.stop(folder.url)
    gate.open()
    await finished(queue)
    #expect(try status(folder) == .stopped)

    // A relaunch leaves it alone.
    setup.engine.state.withLock { $0.gate = nil }
    let relaunched = ProcessingQueue(pipeline: setup.pipeline)
    relaunched.resumeInterrupted(in: setup.library)
    #expect(!relaunched.isBusy)
    #expect(try status(folder) == .stopped)

    relaunched.enqueue(folder.url)
    await finished(relaunched)
    #expect(try status(folder) == .complete)
    #expect(setup.cleaner.calls == 1)
}

@MainActor
@Test func `stopping a meeting still in line takes it out`() async throws {
    let setup = try TestSetup()
    let gate = Gate()
    setup.engine.state.withLock { $0.gate = gate }
    let first = try setup.makeMeeting(title: "First")
    let second = try setup.makeMeeting(title: "Second")
    let queue = ProcessingQueue(pipeline: setup.pipeline)
    queue.enqueue(first.url)
    queue.enqueue(second.url)
    queue.stop(second.url)
    #expect(!queue.isWaiting(second.url))
    #expect(try status(second) == .stopped)
    await gate.arrival()
    gate.open()
    await finished(queue)
    #expect(try status(first) == .complete)
    #expect(try status(second) == .stopped)
}

@MainActor
@Test func `a launch resumes what a crash interrupted, and nothing else`() async throws {
    let setup = try TestSetup()
    let interrupted = try setup.makeMeeting(title: "Interrupted")
    try interrupted.updateMetadata { $0.processing?.completedSteps = [] }
    let failed = try setup.makeMeeting(title: "Failed")
    try failed.updateMetadata { $0.processing?.status = .failed }
    let old = try setup.makeMeeting(title: "Old")
    try old.updateMetadata { $0.processing = nil }
    let recording = try setup.makeMeeting(title: "Recording")
    try recording.updateMetadata { $0.state = .recording }

    let queue = ProcessingQueue(pipeline: setup.pipeline)
    queue.resumeInterrupted(in: setup.library)
    await finished(queue)
    #expect(try status(interrupted) == .complete)
    #expect(try status(failed) == .failed)
    #expect(try status(old) == nil)
    #expect(try status(recording) == .queued)
}

@MainActor
@Test func `recording pauses the work, and stopping picks it up again`() async throws {
    let setup = try TestSetup()
    let folder = try setup.makeMeeting()
    let gate = Gate()
    setup.engine.state.withLock { $0.gate = gate }
    let queue = ProcessingQueue(pipeline: setup.pipeline)
    queue.enqueue(folder.url)
    await gate.arrival()

    queue.pause()
    gate.open()
    while queue.activity != nil {
        await Task.yield()
    }
    #expect(queue.isWaiting(folder.url))
    #expect(try status(folder) == .queued)

    queue.unpause()
    await finished(queue)
    #expect(try status(folder) == .complete)
}

@MainActor
@Test func `meetings added during a pause wait for it to end`() async throws {
    let setup = try TestSetup()
    let folder = try setup.makeMeeting()
    let queue = ProcessingQueue(pipeline: setup.pipeline)
    queue.pause()
    queue.enqueue(folder.url)
    #expect(queue.activity == nil)
    #expect(queue.isBusy)
    queue.unpause()
    await finished(queue)
    #expect(try status(folder) == .complete)
}

@MainActor
@Test func `removing a running meeting stops its work and writes nothing more`() async throws {
    let setup = try TestSetup()
    let folder = try setup.makeMeeting()
    let gate = Gate()
    setup.engine.state.withLock { $0.gate = gate }
    let queue = ProcessingQueue(pipeline: setup.pipeline)
    queue.enqueue(folder.url)
    await gate.arrival()

    let removal = Task {
        await queue.remove(folder.url)
    }
    await Task.yield()
    gate.open()
    await removal.value
    #expect(!queue.isBusy)

    try setup.library.moveToTrash(folder)
    #expect(!FileManager.default.fileExists(atPath: folder.url.path))
}

@MainActor
@Test func `renaming the running meeting moves its job along`() async throws {
    let setup = try TestSetup()
    let folder = try setup.makeMeeting()
    let gate = Gate()
    setup.engine.state.withLock { $0.gate = gate }
    let queue = ProcessingQueue(pipeline: setup.pipeline)
    var finishedFolder: URL?
    queue.onFinish = { finishedFolder = $0 }
    queue.enqueue(folder.url)
    await gate.arrival()

    let renamed = try queue.move(folder.url) { try setup.library.rename($0, to: "Budget") }
    #expect(queue.activity?.folder == renamed.url)
    gate.open()
    await finished(queue)
    #expect(finishedFolder == renamed.url)
    #expect(FileManager.default.fileExists(atPath: renamed.transcriptJSON.path))
    #expect(!FileManager.default.fileExists(atPath: folder.url.path))
}

@MainActor
@Test func `renaming a meeting in line keeps its place`() async throws {
    let setup = try TestSetup()
    let gate = Gate()
    setup.engine.state.withLock { $0.gate = gate }
    let first = try setup.makeMeeting(title: "First")
    let second = try setup.makeMeeting(title: "Second")
    let queue = ProcessingQueue(pipeline: setup.pipeline)
    queue.enqueue(first.url)
    queue.enqueue(second.url)
    let renamed = try queue.move(second.url) { try setup.library.rename($0, to: "Budget") }
    #expect(queue.isWaiting(renamed.url))
    await gate.arrival()
    gate.open()
    await finished(queue)
    #expect(FileManager.default.fileExists(atPath: renamed.transcriptJSON.path))
}

@MainActor
@Test func `a copied folder gets its own job, though it shares an ID`() async throws {
    let setup = try TestSetup()
    let original = try setup.makeMeeting(title: "Original")
    let copy = MeetingFolder(url: original.url.deletingLastPathComponent().appendingPathComponent("Copy"))
    try FileManager.default.copyItem(at: original.url, to: copy.url)
    let queue = ProcessingQueue(pipeline: setup.pipeline)
    queue.enqueue(original.url)
    queue.enqueue(copy.url)
    await finished(queue)
    #expect(FileManager.default.fileExists(atPath: original.transcriptJSON.path))
    #expect(FileManager.default.fileExists(atPath: copy.transcriptJSON.path))
}

@MainActor
@Test func `transcribing again keeps the old transcript until the new one is ready`() async throws {
    let setup = try TestSetup()
    let folder = try setup.makeMeeting()
    let queue = ProcessingQueue(pipeline: setup.pipeline)
    queue.enqueue(folder.url)
    await finished(queue)
    #expect(try folder.loadTranscript().segments.last?.text == "my tannium")

    setup.vocabulary.withLock { $0 = [VocabularyEntry(term: "Tanium", variants: ["tannium"])] }
    let gate = Gate()
    setup.engine.state.withLock { $0.gate = gate }
    queue.transcribeAgain(folder.url)
    await gate.arrival()
    #expect(try folder.loadTranscript().segments.last?.text == "my tannium")
    gate.open()
    await finished(queue)
    #expect(try folder.loadTranscript().segments.last?.text == "my Tanium")
    #expect(setup.cleaner.calls == 1, "The clean mic is reused")
}

@MainActor
@Test func `transcribing again can switch engine`() async throws {
    let setup = try TestSetup()
    let folder = try setup.makeMeeting()
    let queue = ProcessingQueue(pipeline: setup.pipeline)
    queue.enqueue(folder.url)
    await finished(queue)
    setup.preferred.withLock { $0 = "other" }
    queue.transcribeAgain(folder.url)
    await finished(queue)
    #expect(try folder.loadTranscript().engine == "other")
}

@MainActor
@Test func `meetings waiting for a model resume together when it arrives`() async throws {
    let setup = try TestSetup(status: .notInstalled)
    let first = try setup.makeMeeting(title: "First")
    let second = try setup.makeMeeting(title: "Second")
    let queue = ProcessingQueue(pipeline: setup.pipeline)
    queue.enqueue(first.url)
    queue.enqueue(second.url)
    await finished(queue)
    #expect(try status(first) == .waitingForModel)
    #expect(try status(second) == .waitingForModel)

    try await setup.engine.installModel { _ in }
    queue.resumeWaitingForModel(in: setup.library)
    await finished(queue)
    #expect(try status(first) == .complete)
    #expect(try status(second) == .complete)
}

@MainActor
@Test func `a failed meeting doesn't hold up the next`() async throws {
    let setup = try TestSetup()
    let first = try setup.makeMeeting(title: "First")
    let second = try setup.makeMeeting(title: "Second")
    struct Boom: Error {}
    setup.engine.state.withLock { $0.failure = Boom() }
    let queue = ProcessingQueue(pipeline: setup.pipeline)
    queue.enqueue(first.url)
    queue.enqueue(second.url)
    await finished(queue)
    #expect(try status(first) == .failed)
    #expect(try status(second) == .complete)
}
