// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One turn of a conversation with a model.
public struct LLMMessage: Equatable, Sendable {
    public enum Role: String, Sendable {
        case system
        case user
        case assistant
    }

    public var role: Role
    public var content: String

    public init(_ role: Role, _ content: String) {
        self.role = role
        self.content = content
    }
}

/// How a model picks its words.
public struct GenerationOptions: Equatable, Sendable {
    /// The most tokens the answer may use.
    public var maxTokens: Int
    public var temperature: Float
    public var topP: Float
    public var topK: Int
    /// Fixed, so the same prompt gives the same answer, which makes measurements repeatable.
    public var seed: UInt32

    public init(maxTokens: Int = 2048, temperature: Float = 0.3, topP: Float = 0.95, topK: Int = 64, seed: UInt32 = 1) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.seed = seed
    }
}

public enum LLMError: Error, Equatable, Sendable {
    /// The model file isn't there, or isn't one this runtime can load.
    case modelUnavailable
    /// Written for the user. Never holds prompt or answer text.
    case loadFailed(String)
    /// The prompt and the answer's room together don't fit the model's context.
    case promptTooLong(tokens: Int, limit: Int)
    case generationFailed(String)
}

/// Something that writes text: a model inside Minutes, or later an OpenAI-compatible server the
/// user runs. Every feature that uses a model talks to it through this.
public protocol LLMProvider: Sendable {
    /// Stable, like `builtin:gemma-4-12B` or, later, an endpoint's ID and model name.
    var id: String { get }

    /// How many tokens fit, prompt and answer together.
    func contextLength() async throws -> Int

    /// What these messages cost in tokens once formatted for this model, so long transcripts can
    /// be split before they're sent.
    func tokenCount(_ messages: [LLMMessage]) async throws -> Int

    /// The answer, a piece at a time. Cancelling the consuming task stops the model.
    func generate(_ messages: [LLMMessage], options: GenerationOptions) -> AsyncThrowingStream<String, any Error>
}
