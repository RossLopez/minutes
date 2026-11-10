// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Synchronization

/// A stand-in model for tests: counts a token per four characters and answers with whatever
/// `answer` returns, a word at a time.
public final class FakeLLMProvider: LLMProvider {
    public let id: String
    private let context: Int
    private let answer: @Sendable ([LLMMessage]) -> String
    private let prompts = Mutex<[[LLMMessage]]>([])

    public init(
        id: String = "fake",
        contextLength: Int = 32768,
        answer: @escaping @Sendable ([LLMMessage]) -> String = { _ in "## Overview\nA fake summary." },
    ) {
        self.id = id
        context = contextLength
        self.answer = answer
    }

    /// Every prompt it was given, in order.
    public var received: [[LLMMessage]] {
        prompts.withLock { $0 }
    }

    public func contextLength() async throws -> Int {
        context
    }

    public func tokenCount(_ messages: [LLMMessage]) async throws -> Int {
        messages.reduce(0) { $0 + $1.content.count / 4 + 4 }
    }

    public func generate(_ messages: [LLMMessage],
                         options _: GenerationOptions) -> AsyncThrowingStream<String, any Error>
    {
        prompts.withLock { $0.append(messages) }
        let text = answer(messages)
        return AsyncThrowingStream { continuation in
            let task = Task {
                for word in text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    continuation.yield(word.offset == 0 ? String(word.element) : " " + word.element)
                    await Task.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
