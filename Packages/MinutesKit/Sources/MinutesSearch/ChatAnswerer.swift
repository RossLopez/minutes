// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesLLM

/// A question ready to send: the prompt, and the sources it holds.
public struct PreparedAnswer: Sendable {
    public var messages: [LLMMessage]
    public var sources: [ChatSource]
    public var options: GenerationOptions
    /// Earlier turns that didn't fit and were left out.
    public var droppedTurns: Int
}

/// Answers a question from the index: finds passages, fits as many as the model's context holds,
/// and asks the model.
public struct ChatAnswerer: Sendable {
    /// Passages looked at for a question across the library. More than ever fit, so the fitting
    /// decides.
    public static let candidates = 24
    /// Earlier turns sent at most, newest kept.
    public static let historyTurns = 6
    /// What's said when nothing in the meetings matched, without asking the model.
    public static let nothingFound = "I couldn't find anything about that in your meetings."

    private let index: SearchIndex
    private let provider: any LLMProvider
    private let embedder: any EmbeddingProvider?
    private let timeZone: TimeZone

    public init(
        index: SearchIndex,
        provider: any LLMProvider,
        embedder: any EmbeddingProvider?,
        timeZone: TimeZone = .current,
    ) {
        self.index = index
        self.provider = provider
        self.embedder = embedder
        self.timeZone = timeZone
    }

    /// The tokens kept for the answer: an eighth of the context, between 1,024 and 2,048.
    public static func answerRoom(context: Int) -> Int {
        min(2048, max(1024, context / 8))
    }

    public func prepare(
        _ question: String,
        history: [ChatTurn],
        scope: ChatScope,
        filter: SearchFilter,
        today: Date = Date(),
    ) async throws -> PreparedAnswer {
        let candidates = try await sources(for: question, history: history, scope: scope, filter: filter)
        let context = try await provider.contextLength()
        let room = Self.answerRoom(context: context)
        let fitted = try await fit(question, history: Array(history.suffix(Self.historyTurns)), candidates: candidates,
                                   budget: context - room, today: today)
        return PreparedAnswer(
            messages: fitted.messages,
            sources: fitted.sources,
            options: GenerationOptions(maxTokens: room),
            droppedTurns: history.count - fitted.history,
        )
    }

    public func answer(_ prepared: PreparedAnswer) -> AsyncThrowingStream<String, any Error> {
        provider.generate(prepared.messages, options: prepared.options)
    }

    // MARK: - Finding sources

    private struct Candidates {
        /// A meeting's whole text, in order, sent when it all fits.
        var whole: [SearchHit]?
        /// The best matches, best first.
        var ranked: [SearchHit]
    }

    /// A follow-up is searched together with the question before it, so "and who owns that?"
    /// still finds the meeting.
    private func sources(
        for question: String,
        history: [ChatTurn],
        scope: ChatScope,
        filter: SearchFilter,
    ) async throws -> Candidates {
        let query = ([history.last?.question].compactMap(\.self) + [question]).joined(separator: "\n")
        switch scope {
        case .library:
            return try await Candidates(ranked: index.search(query, filter: filter, embedder: embedder,
                                                             limit: Self.candidates))
        case let .meeting(id):
            let ranked = try await index.search(query, filter: SearchFilter(meetings: [id]), embedder: embedder,
                                                limit: Self.candidates)
            return try await Candidates(whole: index.passages(of: id), ranked: ranked)
        }
    }

    private struct Fitted {
        var messages: [LLMMessage]
        var sources: [ChatSource]
        var history: Int
    }

    /// Older turns go first, down to none, until the question fits with room for sources. Then
    /// sources are added in order until the budget is used: a meeting's whole text if it all
    /// fits, otherwise its best matches.
    private func fit(
        _ question: String,
        history: [ChatTurn],
        candidates: Candidates,
        budget: Int,
        today: Date,
    ) async throws -> Fitted {
        func messages(_ history: [ChatTurn], _ sources: [ChatSource]) -> [LLMMessage] {
            ChatPrompts.messages(history: history, question: question, sources: sources, today: today,
                                 timeZone: timeZone)
        }
        var history = history
        while !history.isEmpty, try await provider.tokenCount(messages(history, [])) > budget / 2 {
            history.removeFirst()
        }
        let base = try await provider.tokenCount(messages(history, []))
        guard base < budget else {
            throw LLMError.promptTooLong(tokens: base, limit: budget)
        }
        var chosen: [ChatSource] = []
        if let whole = candidates.whole, !whole.isEmpty {
            chosen = try await take(whole, base: base, budget: budget)
            if chosen.count < whole.count {
                chosen = []
            }
        }
        if chosen.isEmpty {
            chosen = try await take(candidates.ranked, base: base, budget: budget)
        }
        // Counting sources one at a time can be off by a few tokens, so check the whole prompt.
        while !chosen.isEmpty, try await provider.tokenCount(messages(history, chosen)) > budget {
            chosen.removeLast()
        }
        return Fitted(messages: messages(history, chosen), sources: chosen, history: history.count)
    }

    /// As many of `hits` as fit, numbered from 1.
    private func take(_ hits: [SearchHit], base: Int, budget: Int) async throws -> [ChatSource] {
        let empty = try await provider.tokenCount([LLMMessage(.user, "")])
        var used = base
        var chosen: [ChatSource] = []
        for hit in hits {
            let source = ChatSource(number: chosen.count + 1, hit: hit)
            let block = ChatPrompts.block(source, timeZone: timeZone) + "\n\n"
            let cost = try await provider.tokenCount([LLMMessage(.user, block)]) - empty
            guard used + cost <= budget else {
                break
            }
            used += cost
            chosen.append(source)
        }
        return chosen
    }
}
