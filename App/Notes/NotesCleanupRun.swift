// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesLLM
import MinutesStorage
import Observation

/// One cleanup of a meeting's notes: waiting its turn, being written, then waiting for the user
/// to accept or discard it. Nothing is saved until they accept.
@MainActor @Observable
final class NotesCleanupRun {
    enum Phase: Equatable {
        /// Said for the user, like "Waiting for the summary to finish…".
        case waiting(String)
        case writing
        case finished
        /// Said for the user. Never holds note or transcript text.
        case failed(String)
    }

    private(set) var phase = Phase.waiting("Starting…")
    /// The cleaned-up notes so far.
    private(set) var text = ""
    /// The notes as they were when the cleanup started, which the review compares against.
    let original: String
    /// The provider's ID, saved with the result.
    private(set) var modelID: String?

    @ObservationIgnored private let lines: [NoteLine]
    @ObservationIgnored private let folder: () -> URL
    @ObservationIgnored private var task: Task<Void, Never>?

    init(document: NotesDocument) {
        original = document.text
        lines = zip(document.lines, document.times).map { NoteLine($0, seconds: $1) }
        folder = { [weak document] in document?.folder ?? URL(fileURLWithPath: "/nonexistent") }
    }

    var isRunning: Bool {
        switch phase {
        case .waiting, .writing: true
        case .finished, .failed: false
        }
    }

    func start(provider: @escaping @MainActor () -> (any LLMProvider)?) {
        task = Task { [weak self] in
            await self?.perform(provider: provider)
        }
    }

    /// Stops the cleanup, keeping nothing. `reason` is shown, when there is one.
    func cancel(reason: String? = nil) {
        task?.cancel()
        task = nil
        if isRunning {
            phase = .failed(reason ?? "Stopped.")
        }
    }

    private func perform(provider: @MainActor () -> (any LLMProvider)?) async {
        let summaries = SummaryCenter.shared.queue
        do {
            // Recording comes first, as it does for summaries.
            try await wait(until: { RecordingController.shared.phase == .idle },
                           saying: "Waiting for the recording to end…")
            try await wait(until: { !TranscriptionCenter.shared.queue.isBusy },
                           saying: "Waiting for transcription to finish…")
            try await wait(until: { !NotesCenter.shared.isWriting(other: self) },
                           saying: "Waiting for another cleanup to finish…")
            // Summaries take turns with cleanups, so only one thing uses a model at a time.
            summaries.hold()
            defer {
                summaries.release()
            }
            try await wait(until: { summaries.activity == nil }, saying: "Waiting for the summary to finish…")
            guard let provider = provider() else {
                phase = .failed("The model isn't installed.")
                return
            }
            modelID = provider.id
            phase = .writing
            let context = await Self.context(in: MeetingFolder(url: folder()))
            let result = try await NotesCleaner(provider: provider).clean(
                lines,
                transcript: context.lines,
                names: context.names,
                summary: context.summary,
                meeting: context.title,
            ) { [weak self] piece in
                Task { @MainActor in
                    self?.append(piece)
                }
            }
            try Task.checkCancellation()
            text = result.text
            phase = .finished
        } catch is CancellationError {
            // `cancel` said why.
        } catch where Task.isCancelled {
            // Some providers report a cancel as an error of their own.
        } catch {
            NotesCenter.logger.error("Notes cleanup failed: \(String(describing: type(of: error)), privacy: .public)")
            phase = .failed(Self.describe(error))
        }
    }

    private func append(_ piece: String) {
        if phase == .writing {
            text += piece
        }
    }

    private func wait(until isReady: @MainActor () -> Bool, saying message: String) async throws {
        while !isReady() {
            phase = .waiting(message)
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    private struct Context {
        var title = ""
        var names: [String] = []
        var lines: [SummaryLine] = []
        var summary: String?
    }

    /// The transcript with speakers' names, and the summary, read off the main actor.
    private static func context(in folder: MeetingFolder) async -> Context {
        await Task.detached {
            var context = Context()
            guard let metadata = try? folder.loadMetadata() else {
                return context
            }
            context.title = metadata.title
            context.summary = folder.loadSummary()
            guard let transcript = try? folder.loadTranscript() else {
                return context
            }
            var names: [String] = []
            context.lines = transcript.segments.map { segment in
                let name = metadata.displayName(forSpeaker: segment.speaker)
                if !names.contains(name) {
                    names.append(name)
                }
                return SummaryLine(start: segment.start, speaker: name, text: segment.text)
            }
            context.names = names
            return context
        }.value
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case NotesCleaner.Failure.noNotes:
            "There are no notes to clean up."
        case LLMError.promptTooLong:
            "These notes are too long for this model's context."
        case LLMError.modelUnavailable:
            "The model isn't installed."
        case let LLMError.loadFailed(reason), let LLMError.generationFailed(reason):
            reason
        case let error as EndpointError:
            error.message
        default:
            "The notes couldn't be cleaned up."
        }
    }
}

extension NotesCenter {
    /// Whether a cleanup other than `run` is being written.
    func isWriting(other run: NotesCleanupRun) -> Bool {
        cleanups.values.contains { $0 !== run && $0.phase == .writing }
    }

    /// Whether a cleanup is waiting or being written, which keeps the library from moving.
    var isBusy: Bool {
        cleanups.values.contains(where: \.isRunning)
    }

    /// Whether a cleanup is using this built-in model, so it can't be deleted.
    func isUsing(builtIn id: String) -> Bool {
        cleanups.values.contains { $0.isRunning && $0.modelID == ModelChoice.builtIn(id).storageID }
    }

    func cleanup(for document: NotesDocument) -> NotesCleanupRun? {
        cleanups[document.meetingID]
    }

    /// The model cleanups use now, or nil when none can be.
    var cleanupChoice: ModelChoice? {
        AIModelCenter.shared.resolvedChoice(for: .notesCleanup, installed: SummaryCenter.shared.installedModels)
    }

    var hasCleanupModel: Bool {
        SummaryCenter.shared.fakeProvider != nil || cleanupChoice != nil
    }

    func startCleanup(of document: NotesDocument) {
        guard document.hasText, !isRecording(document), cleanups[document.meetingID]?.isRunning != true else {
            return
        }
        flush(document.folder)
        let run = NotesCleanupRun(document: document)
        cleanups[document.meetingID] = run
        run.start { [weak self] in
            self?.cleanupProvider()
        }
    }

    private func cleanupProvider() -> (any LLMProvider)? {
        if let fake = SummaryCenter.shared.fakeProvider {
            return fake
        }
        switch cleanupChoice {
        case nil:
            return nil
        case let .builtIn(id)?:
            return BuiltInModels.shared.provider(for: id)
        case let choice?:
            return AIModelCenter.shared.provider(for: choice)
        }
    }

    func discardCleanup(of document: NotesDocument) {
        cleanups[document.meetingID]?.cancel()
        cleanups[document.meetingID] = nil
    }

    /// Saves the cleanup as `notes-cleaned.md`. A cleanup it replaces goes to the Trash.
    func acceptCleanup(of document: NotesDocument) -> Bool {
        guard let run = cleanups[document.meetingID], run.phase == .finished, let model = run.modelID else {
            return false
        }
        flush(document.folder)
        do {
            try MeetingFolder(url: document.folder).saveCleanedNotes(run.text, model: model) { file in
                try LibraryStore.shared.discard(file)
            }
        } catch {
            Self.logger.error("Saving cleaned notes failed: \(String(describing: type(of: error)), privacy: .public)")
            return false
        }
        cleanups[document.meetingID] = nil
        cleanedNotesSaved(for: document)
        return true
    }

    /// Recording takes the Mac's attention, so cleanups stop and can be run again after.
    func stopCleanupsForRecording() {
        for run in cleanups.values where run.isRunning {
            run.cancel(reason: "Stopped for a recording. Try again after it.")
        }
    }
}
