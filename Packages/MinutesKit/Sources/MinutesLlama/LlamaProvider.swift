// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import llama
import MinutesLLM
import os

/// A GGUF model run inside Minutes by llama.cpp, on the GPU through Metal.
///
/// The model loads on first use and unloads after it has sat idle, so its memory isn't held
/// between summaries. llama.cpp's calls block for seconds at a time, so this actor runs on a
/// queue of its own rather than on Swift's shared threads.
public actor LlamaProvider: LLMProvider {
    public struct Statistics: Equatable, Sendable {
        public var loadSeconds: Double = 0
        public var promptTokens = 0
        public var promptSeconds: Double = 0
        public var generatedTokens = 0
        public var generateSeconds: Double = 0
    }

    public nonisolated let id: String
    private let modelURL: URL
    private let requestedContext: Int
    private let idleUnload: Duration

    private let queue = DispatchSerialQueue(label: "io.github.rosslopez.minutes.llama")
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    private var loaded: LlamaModel?
    private var unloadTask: Task<Void, Never>?
    private var uses = 0
    public private(set) var statistics = Statistics()

    /// - Parameters:
    ///   - contextLength: tokens for prompt and answer together, capped at what the model was trained on.
    ///   - idleUnload: how long the model stays loaded after its last use.
    public init(id: String, modelURL: URL, contextLength: Int = 32768, idleUnload: Duration = .seconds(60)) {
        self.id = id
        self.modelURL = modelURL
        requestedContext = contextLength
        self.idleUnload = idleUnload
        LlamaRuntime.start()
    }

    public func contextLength() async throws -> Int {
        try await using { Int(llama_n_ctx($0.context)) }
    }

    public func tokenCount(_ messages: [LLMMessage]) async throws -> Int {
        try await using { model in
            try model.tokens(messages).count
        }
    }

    public nonisolated func generate(
        _ messages: [LLMMessage],
        options: GenerationOptions,
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(messages, options: options) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// The prompt exactly as the model will read it, for checking a model's conversation format.
    public func formattedPrompt(_ messages: [LLMMessage]) async throws -> String {
        try await using { try $0.format(messages).map(\.text).joined() }
    }

    /// Frees the model now rather than waiting for it to go idle.
    public func unload() {
        unloadTask?.cancel()
        loaded = nil
    }

    /// Frees the model while the app quits, blocking until any work under way returns. ggml
    /// crashes at exit if Metal still holds a model. Cancel the work first, so this is quick, and
    /// never call it from the provider's own queue.
    public nonisolated func unloadBeforeExit() {
        queue.sync {
            assumeIsolated { $0.unload() }
        }
    }

    // MARK: - Running

    private func run(
        _ messages: [LLMMessage],
        options: GenerationOptions,
        emit: @Sendable (String) -> Void,
    ) async throws {
        try await using { model in
            let prompt = try model.tokens(messages)
            let limit = Int(llama_n_ctx(model.context))
            guard prompt.count + options.maxTokens <= limit else {
                throw LLMError.promptTooLong(tokens: prompt.count + options.maxTokens, limit: limit)
            }
            var stats = statistics
            stats.promptTokens = prompt.count
            let promptStart = ContinuousClock.now
            try model.prefill(prompt)
            stats.promptSeconds = Self.seconds(since: promptStart)

            let generateStart = ContinuousClock.now
            stats.generatedTokens = try model.generate(options: options, emit: emit)
            stats.generateSeconds = Self.seconds(since: generateStart)
            statistics = stats
        }
    }

    /// Loads the model if needed, runs `body`, then starts the idle clock again.
    private func using<T>(_ body: (LlamaModel) throws -> T) async throws -> T {
        unloadTask?.cancel()
        uses += 1
        defer {
            uses -= 1
            scheduleUnload()
        }
        if loaded == nil {
            let start = ContinuousClock.now
            loaded = try LlamaModel(url: modelURL, contextLength: requestedContext)
            statistics.loadSeconds = Self.seconds(since: start)
        }
        guard let loaded else {
            throw LLMError.modelUnavailable
        }
        return try body(loaded)
    }

    private func scheduleUnload() {
        guard uses == 0 else {
            return
        }
        let delay = idleUnload
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else {
                return
            }
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() {
        if uses == 0 {
            loaded = nil
        }
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
