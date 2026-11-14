// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import llama
import MinutesLLM

/// A GGUF embedding model, like EmbeddingGemma 2, run inside Minutes by llama.cpp.
///
/// Like `LlamaProvider`, it loads on first use, unloads after sitting idle, and runs on a queue
/// of its own because llama.cpp's calls block.
public actor LlamaEmbedder: EmbeddingProvider {
    public struct Statistics: Equatable, Sendable {
        public var loadSeconds: Double = 0
        public var passages = 0
        public var tokens = 0
        public var seconds: Double = 0
    }

    public nonisolated let id: String
    public nonisolated let dimensions: Int
    public nonisolated let modelURL: URL
    private let format: EmbeddingFormat
    private let contextLength: Int
    private let sequences: Int
    private let idleUnload: Duration

    private let queue = DispatchSerialQueue(label: "io.github.rosslopez.minutes.embedding")
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    private var loaded: LlamaEmbeddingModel?
    private var unloadTask: Task<Void, Never>?
    private var uses = 0
    /// Added up over every call since it was made.
    public private(set) var statistics = Statistics()

    /// - Parameters:
    ///   - id: a stable name for the model. The vector length is added to it.
    ///   - dimensions: how much of each vector to keep. Matryoshka models stay good when cut.
    ///   - contextLength: the most tokens a batch of passages, and so any one passage, can be.
    ///   - sequences: how many passages go through together.
    public init(
        id: String,
        modelURL: URL,
        format: EmbeddingFormat = .embeddingGemma,
        dimensions: Int = 256,
        contextLength: Int = 2048,
        sequences: Int = 16,
        idleUnload: Duration = .seconds(30),
    ) {
        self.id = "\(id)/\(dimensions)"
        self.dimensions = dimensions
        self.modelURL = modelURL
        self.format = format
        self.contextLength = contextLength
        self.sequences = sequences
        self.idleUnload = idleUnload
        LlamaRuntime.start()
    }

    public func embed(documents: [EmbeddingDocument]) async throws -> [[Float]] {
        try await vectors(documents.map(format.document))
    }

    public func embed(query: String) async throws -> [Float] {
        try await vectors([format.query(query)])[0]
    }

    /// The model's own full-width vectors, before they're cut, for checking against llama-server.
    public func fullVectors(_ texts: [String]) async throws -> [[Float]] {
        try await using { model in
            let tokens = try texts.map(model.tokens)
            statistics.passages += texts.count
            statistics.tokens += tokens.reduce(0) { $0 + $1.count }
            return try model.embed(tokens)
        }
    }

    public func unload() {
        unloadTask?.cancel()
        loaded = nil
    }

    /// Frees the model while the app quits. See `LlamaProvider.unloadBeforeExit`.
    public nonisolated func unloadBeforeExit() {
        queue.sync {
            assumeIsolated { $0.unload() }
        }
    }

    private func vectors(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else {
            return []
        }
        let dimensions = dimensions
        return try await using { model in
            guard dimensions <= model.width else {
                throw LLMError.loadFailed("The search model's vectors are shorter than \(dimensions).")
            }
            let start = ContinuousClock.now
            let tokens = try texts.map(model.tokens)
            let vectors = try model.embed(tokens)
            let elapsed = start.duration(to: .now)
            statistics.passages += texts.count
            statistics.tokens += tokens.reduce(0) { $0 + $1.count }
            statistics.seconds += Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            return vectors.map { EmbeddingMath.truncated($0, to: dimensions) }
        }
    }

    private func using<T>(_ body: (LlamaEmbeddingModel) throws -> T) async throws -> T {
        unloadTask?.cancel()
        uses += 1
        defer {
            uses -= 1
            scheduleUnload()
        }
        if loaded == nil {
            let start = ContinuousClock.now
            loaded = try LlamaEmbeddingModel(url: modelURL, contextLength: contextLength, sequences: sequences)
            let elapsed = start.duration(to: .now)
            statistics.loadSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
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
}
