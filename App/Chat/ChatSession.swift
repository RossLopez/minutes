// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesLLM
import MinutesSearch
import Observation

/// One open conversation: asking, the answer as it's written, and saving after each answer.
@MainActor @Observable
final class ChatSession: Identifiable {
    enum Phase: Equatable {
        case idle
        /// Said for the user, like "Waiting for the summary to finish…".
        case waiting(String)
        case searching
        case answering
        /// Said for the user. Never holds question, answer or meeting text.
        case failed(String)
    }

    nonisolated let id: UUID
    private(set) var document: ChatDocument
    private(set) var phase = Phase.idle
    /// The question being answered, with the answer so far.
    private(set) var pending: ChatTurn?
    /// Said when earlier turns were left out to make room.
    private(set) var note: String?
    /// Where it was last saved. Nil until the first answer.
    private(set) var fileURL: URL?

    @ObservationIgnored private let folder: @MainActor () -> URL?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// - Parameter folder: where it's saved, asked each time, since a meeting's folder moves when
    ///   it's renamed.
    init(document: ChatDocument, fileURL: URL?, folder: @escaping @MainActor () -> URL?) {
        id = document.id
        self.document = document
        self.fileURL = fileURL
        self.folder = folder
    }

    var isBusy: Bool {
        switch phase {
        case .waiting, .searching, .answering: true
        case .idle, .failed: false
        }
    }

    var filter: SearchFilter {
        get {
            document.filter
        }
        set {
            document.filter = newValue
            if !document.turns.isEmpty {
                save()
            }
        }
    }

    func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isBusy else {
            return
        }
        note = nil
        pending = ChatTurn(question: question)
        task = Task { [weak self] in
            await self?.perform(question)
        }
    }

    /// Stops the answer, keeping what's written so far.
    func stop() {
        task?.cancel()
    }

    func rename(to title: String) {
        document.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    /// The file moved, like when its meeting was renamed.
    func moved(to url: URL) {
        fileURL = url
    }

    private func perform(_ question: String) async {
        let center = ChatCenter.shared
        let summaries = SummaryCenter.shared.queue
        var holding = false
        defer {
            if holding {
                summaries.release()
            }
            task = nil
        }
        do {
            guard let provider = center.provider() else {
                throw ChatFailure.noModel
            }
            guard let index = SearchCenter.shared.currentIndex else {
                throw ChatFailure.noIndex
            }
            // Built-in models take turns, so only one thing uses one at a time.
            try await wait(
                until: { !NotesCenter.shared.isWritingCleanup },
                saying: "Waiting for a notes cleanup to finish…",
            )
            summaries.hold()
            holding = true
            try await wait(until: { summaries.activity == nil }, saying: "Waiting for the summary to finish…")
            phase = .searching
            let answerer = ChatAnswerer(index: index, provider: provider, embedder: SearchCenter.shared.embedder)
            let prepared = try await answerer.prepare(question, history: document.turns, scope: document.scope,
                                                      filter: document.filter)
            pending?.sources = prepared.sources
            if prepared.droppedTurns > 0 {
                note = "Earlier questions were left out to fit this model."
            }
            if prepared.sources.isEmpty {
                pending?.answer = ChatAnswerer.nothingFound
            } else {
                phase = .answering
                for try await piece in answerer.answer(prepared) {
                    pending?.answer += piece
                }
            }
            document.model = provider.id
            finish()
        } catch is CancellationError {
            finish()
        } catch where Task.isCancelled {
            // Some providers report a cancel as an error of their own.
            finish()
        } catch {
            ChatCenter.logger.error("Chat failed: \(String(describing: type(of: error)), privacy: .public)")
            phase = .failed(Self.describe(error))
            keepPending()
        }
    }

    /// Adds the turn and saves, when there's an answer to keep.
    private func finish() {
        phase = .idle
        keepPending()
    }

    private func keepPending() {
        guard var turn = pending else {
            return
        }
        pending = nil
        // The file keeps what was shown: citations of sources that don't exist are dropped.
        turn.answer = Citations.cleaned(turn.answer, count: turn.sources.count)
        guard !turn.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        document.turns.append(turn)
        save()
    }

    private func save() {
        guard let folder = folder() else {
            return
        }
        // A meeting renamed since the last save took the file with it.
        let previous = fileURL.map { folder.appendingPathComponent($0.lastPathComponent) }
        do {
            fileURL = try ChatFiles.save(document, in: folder, replacing: previous)
            ChatCenter.shared.saved(self)
        } catch {
            ChatCenter.logger.error("Saving a chat failed: \(String(describing: type(of: error)), privacy: .public)")
            note = "Minutes couldn't save this chat."
        }
    }

    private func wait(until isReady: @MainActor () -> Bool, saying message: String) async throws {
        while !isReady() {
            phase = .waiting(message)
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    private enum ChatFailure: Error {
        case noModel
        case noIndex
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case ChatFailure.noModel:
            "Choose a chat model in Settings › AI Models."
        case ChatFailure.noIndex:
            "Minutes can't read its search index. Try Rebuild Index in Settings › Storage."
        case LLMError.promptTooLong:
            "This question is too long for the model's context."
        case LLMError.modelUnavailable:
            "The model isn't installed."
        case let LLMError.loadFailed(reason), let LLMError.generationFailed(reason):
            reason
        case let error as EndpointError:
            error.message
        default:
            "Minutes couldn't answer that."
        }
    }
}
