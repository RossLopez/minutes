// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesLLM
import MinutesPipeline
import MinutesStorage
import Synchronization
import Testing

/// Answers with a fixed summary, and can hold after its first word.
private final class ScriptedModel: LLMProvider, Sendable {
    struct State {
        var answer = "## Overview\nSpeaker 1 will send the budget."
        var gate: Gate?
        var prompts: [[LLMMessage]] = []
    }

    let id = "scripted"
    let state = Mutex(State())

    var prompts: [[LLMMessage]] {
        state.withLock { $0.prompts }
    }

    func contextLength() async throws -> Int {
        100_000
    }

    func tokenCount(_ messages: [LLMMessage]) async throws -> Int {
        messages.reduce(0) { $0 + $1.content.count / 4 }
    }

    func generate(_ messages: [LLMMessage], options _: GenerationOptions) -> AsyncThrowingStream<String, any Error> {
        let (answer, gate) = state.withLock { state in
            state.prompts.append(messages)
            return (state.answer, state.gate)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                let words = answer.split(separator: " ").map(String.init)
                continuation.yield(words[0])
                await gate?.pass()
                for word in words.dropFirst() {
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    continuation.yield(" " + word)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

private final class SummarySetup: Sendable {
    let library: MinutesLibrary
    let model = ScriptedModel()
    let installed = Mutex(true)

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MinutesTests-\(UUID().uuidString)")
        library = MinutesLibrary(root: root)
        try library.prepareLayout()
    }

    @MainActor
    func queue() -> SummaryQueue {
        SummaryQueue(
            templates: { [library] in
                SummaryTemplateStore(folder: library.templatesFolder, defaultPrompt: "Summarize.")
            },
            provider: { [self] in installed.withLock { $0 } ? model : nil },
        )
    }

    /// A transcribed meeting with two people saying enough to summarize.
    func meeting(
        _ title: String = "Budget",
        startedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        words: Int = 30,
    ) throws -> MeetingFolder {
        let folder = try library.createMeetingFolder(startedAt: startedAt, title: title)
        let metadata = MeetingMetadata(title: title, startedAt: startedAt, state: .complete, audioFormat: "aac",
                                       voiceProcessing: false)
        try folder.save(metadata)
        let segments = (0 ..< max(1, words / 10)).map { index in
            TranscriptSegment(
                speaker: index.isMultiple(of: 2) ? "speaker-1" : "speaker-2",
                words: (0 ..< min(words, 10))
                    .map { word in
                        let start = Double(index * 10 + word)
                        return TranscriptWord(text: "word\(word)", start: start, end: start + 0.5)
                    },
            )
        }
        try folder.save(Transcript(engine: "fake", model: "m", segments: segments), for: metadata)
        return folder
    }
}

private func summary(_ folder: MeetingFolder) throws -> MeetingMetadata.Summary? {
    try folder.loadMetadata().summary
}

/// Waits until the queue has nothing left, using its own change signal.
@MainActor
private func finished(_ queue: SummaryQueue) async {
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
private func until(_ condition: () -> Bool) async {
    for _ in 0 ..< 1000 where !condition() {
        try? await Task.sleep(for: .milliseconds(2))
    }
}

@MainActor
@Test func `a finished transcript is summarized automatically, with the meeting's names`() async throws {
    let setup = try SummarySetup()
    let folder = try setup.meeting()
    try folder.nameSpeaker("speaker-1", "Dana")
    let queue = setup.queue()
    queue.transcriptFinished(folder.url, automatically: true)
    await finished(queue)

    #expect(folder.loadSummary() == "## Overview\nSpeaker 1 will send the budget.\n")
    let block = try #require(try summary(folder))
    #expect(block.status == .complete)
    #expect(block.template == "Default")
    #expect(block.model == "scripted")
    #expect(block.names == ["speaker-1": "Dana", "speaker-2": "Speaker 2"])
    let prompt = try #require(setup.model.prompts.first?.last?.content)
    #expect(prompt.contains("Summarize."))
    #expect(prompt.contains("[0:00] Dana: word0"))
    #expect(prompt.contains("[0:10] Speaker 2: word0"))
}

@MainActor
@Test func `nothing is summarized when it's off, there's no model, or a summary exists`() throws {
    let setup = try SummarySetup()
    let queue = setup.queue()
    let off = try setup.meeting("Off")
    queue.transcriptFinished(off.url, automatically: false)
    let existing = try setup.meeting("Existing", startedAt: Date(timeIntervalSince1970: 1_900_000_000))
    try existing.saveSummary("Old.", template: "Default", model: "m", names: [:])
    queue.transcriptFinished(existing.url, automatically: true)
    setup.installed.withLock { $0 = false }
    let noModel = try setup.meeting("No model", startedAt: Date(timeIntervalSince1970: 2_000_000_000))
    queue.transcriptFinished(noModel.url, automatically: true)

    #expect(!queue.isBusy)
    #expect(setup.model.prompts.isEmpty)
    #expect(try summary(off) == nil)
    #expect(try summary(noModel) == nil)
    #expect(existing.loadSummary() == "Old.\n")
}

@MainActor
@Test func `summaries run one at a time, oldest first, streaming as they go`() async throws {
    let setup = try SummarySetup()
    let gate = Gate()
    setup.model.state.withLock { $0.gate = gate }
    let newer = try setup.meeting("Newer", startedAt: Date(timeIntervalSince1970: 2_000_000_000))
    let older = try setup.meeting("Older", startedAt: Date(timeIntervalSince1970: 1_000_000_000))
    let queue = setup.queue()
    var order: [URL] = []
    queue.onChange = { url in
        if (try? summary(MeetingFolder(url: url)))?.status == .complete, !order.contains(url) {
            order.append(url)
        }
    }
    queue.enqueue(newer.url)
    queue.enqueue(older.url)
    await gate.arrival()
    await until { queue.activity?.text == "##" }
    #expect(queue.activity?.folder == newer.url)
    #expect(queue.activity?.stage == .writing)
    #expect(queue.activity?.text == "##")
    #expect(try summary(older)?.status == .queued)
    gate.open()
    await finished(queue)
    #expect(order == [newer.url, older.url])
}

@MainActor
@Test func `stopping stays stopped across launches, until asked again`() async throws {
    let setup = try SummarySetup()
    let gate = Gate()
    setup.model.state.withLock { $0.gate = gate }
    let folder = try setup.meeting()
    let queue = setup.queue()
    queue.enqueue(folder.url)
    await gate.arrival()
    queue.stop(folder.url)
    gate.open()
    await finished(queue)
    #expect(try summary(folder)?.status == .stopped)
    #expect(folder.loadSummary() == nil)

    let relaunched = setup.queue()
    relaunched.resumeInterrupted(in: setup.library)
    #expect(!relaunched.isBusy)
    relaunched.enqueue(folder.url)
    await finished(relaunched)
    #expect(try summary(folder)?.status == .complete)
}

@MainActor
@Test func `a launch resumes summaries a quit interrupted`() async throws {
    let setup = try SummarySetup()
    let folder = try setup.meeting()
    try folder.updateSummary { $0 = MeetingMetadata.Summary(status: .queued, template: "Default") }
    let queue = setup.queue()
    queue.resumeInterrupted(in: setup.library)
    await finished(queue)
    #expect(try summary(folder)?.status == .complete)
}

@MainActor
@Test func `pausing for a recording starts the summary again afterwards`() async throws {
    let setup = try SummarySetup()
    let gate = Gate()
    setup.model.state.withLock { $0.gate = gate }
    let folder = try setup.meeting()
    let queue = setup.queue()
    queue.enqueue(folder.url)
    await gate.arrival()
    queue.pause()
    gate.open()
    await until { queue.activity == nil }
    #expect(queue.isBusy)
    #expect(try summary(folder)?.status == .queued)
    #expect(folder.loadSummary() == nil)

    queue.unpause()
    await finished(queue)
    #expect(try summary(folder)?.status == .complete)
    #expect(setup.model.prompts.count == 2)
}

@MainActor
@Test func `renaming the meeting mid-summary saves it in the new folder`() async throws {
    let setup = try SummarySetup()
    let gate = Gate()
    setup.model.state.withLock { $0.gate = gate }
    let folder = try setup.meeting()
    let queue = setup.queue()
    queue.enqueue(folder.url)
    await gate.arrival()
    let renamed = try queue.move(folder.url) { try setup.library.rename($0, to: "Forecast") }
    #expect(queue.activity?.folder == renamed.url)
    gate.open()
    await finished(queue)
    #expect(renamed.loadSummary() != nil)
    #expect(!FileManager.default.fileExists(atPath: folder.url.path))
}

@MainActor
@Test func `removing the meeting mid-summary writes nothing`() async throws {
    let setup = try SummarySetup()
    let gate = Gate()
    setup.model.state.withLock { $0.gate = gate }
    let folder = try setup.meeting()
    let queue = setup.queue()
    queue.enqueue(folder.url)
    await gate.arrival()
    let removal = Task { await queue.remove(folder.url) }
    // Lets the removal cancel the job before the model goes on.
    for _ in 0 ..< 5 {
        await Task.yield()
    }
    gate.open()
    await removal.value
    #expect(folder.loadSummary() == nil)
    #expect(!queue.isBusy)
}

@MainActor
@Test func `regenerating with another template keeps the old summary`() async throws {
    let setup = try SummarySetup()
    let folder = try setup.meeting()
    let store = SummaryTemplateStore(folder: setup.library.templatesFolder, defaultPrompt: "Summarize.")
    try store.save(SummaryTemplate(name: "Standup", prompt: "List blockers."))
    let queue = setup.queue()
    queue.enqueue(folder.url)
    await finished(queue)
    setup.model.state.withLock { $0.answer = "## Blockers\nNone." }
    queue.enqueue(folder.url, template: "Standup")
    await finished(queue)

    #expect(folder.loadSummary() == "## Blockers\nNone.\n")
    #expect(try summary(folder)?.template == "Standup")
    #expect(try summary(folder)?.requestedTemplate == nil)
    #expect(setup.model.prompts.last?.last?.content.contains("List blockers.") == true)
    let previous = folder.previousSummaries()
    #expect(previous.count == 1)
    #expect(previous.first?.lastPathComponent.hasSuffix(" Default.md") == true)
}

@MainActor
@Test func `a summary waits for a missing model, then goes on when it arrives`() async throws {
    let setup = try SummarySetup()
    let folder = try setup.meeting()
    setup.installed.withLock { $0 = false }
    let queue = setup.queue()
    queue.enqueue(folder.url)
    await finished(queue)
    #expect(try summary(folder)?.status == .waitingForModel)
    #expect(try summary(folder)?.failure == SummaryQueue.modelNotInstalled)

    setup.installed.withLock { $0 = true }
    queue.resumeWaitingForModel(in: setup.library)
    await finished(queue)
    #expect(try summary(folder)?.status == .complete)
    #expect(try summary(folder)?.failure == nil)
}

@MainActor
@Test func `too little said fails the summary and leaves the transcript alone`() async throws {
    let setup = try SummarySetup()
    let folder = try setup.meeting(words: 5)
    let queue = setup.queue()
    queue.enqueue(folder.url)
    await finished(queue)
    #expect(try summary(folder)?.status == .failed)
    #expect(try summary(folder)?.failure == SummaryQueue.tooLittleSaid)
    #expect(try folder.loadMetadata().state == .complete)
    #expect(try folder.loadTranscript().segments.count == 1)
    #expect(setup.model.prompts.isEmpty)
}

@MainActor
@Test func `a speaker named mid-summary gets their name in it`() async throws {
    let setup = try SummarySetup()
    let gate = Gate()
    setup.model.state.withLock { $0.gate = gate }
    let folder = try setup.meeting()
    let queue = setup.queue()
    queue.enqueue(folder.url)
    await gate.arrival()
    try folder.nameSpeaker("speaker-1", "Dana")
    gate.open()
    await finished(queue)
    #expect(folder.loadSummary() == "## Overview\nDana will send the budget.\n")
    #expect(try summary(folder)?.names?["speaker-1"] == "Dana")
}
