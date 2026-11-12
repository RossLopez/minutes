// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Synchronization

/// A model on a server the user runs, such as llama.cpp's `llama-server`, LM Studio or Ollama,
/// through the OpenAI chat completions API. Foundation only.
public final class OpenAICompatibleProvider: LLMProvider {
    public let id: String
    /// Like `http://localhost:8080/v1`.
    public let baseURL: URL
    public let model: String
    /// The endpoint's name, for messages.
    public let serverName: String
    public let location: NetworkLocation
    private let apiKey: String?
    private let context: Int
    private let configuration: @Sendable () -> URLSessionConfiguration
    /// Whether to ask for no reasoning, until the server says it doesn't take the option.
    private let asksForNoReasoning = Mutex(true)

    public init(
        id: String,
        baseURL: URL,
        model: String,
        apiKey: String?,
        contextLength: Int,
        serverName: String,
        location: NetworkLocation = .thisMac,
        configuration: @escaping @Sendable () -> URLSessionConfiguration = EndpointRequest.configuration,
    ) {
        self.id = id
        self.baseURL = baseURL
        self.model = model
        self.serverName = serverName
        self.location = location
        self.apiKey = apiKey
        context = contextLength
        self.configuration = configuration
    }

    public func contextLength() async throws -> Int {
        context
    }

    /// An estimate, since a server doesn't share its tokenizer.
    public func tokenCount(_ messages: [LLMMessage]) async throws -> Int {
        Self.estimatedTokens(messages)
    }

    /// Three characters of English per token, where Gemma measured about four, and a token for
    /// every other character, which covers scripts that tokenize closer to one each. Too many
    /// only means a long meeting is read in more parts.
    public static func estimatedTokens(_ messages: [LLMMessage]) -> Int {
        messages.reduce(8) { total, message in
            var ascii = 0
            var other = 0
            for scalar in message.content.unicodeScalars {
                if scalar.isASCII {
                    ascii += 1
                } else {
                    other += 1
                }
            }
            return total + (ascii + 2) / 3 + other + 8
        }
    }

    public func generate(
        _ messages: [LLMMessage],
        options: GenerationOptions,
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await stream(messages, options: options) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: describe(error))
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Request

    private func stream(
        _ messages: [LLMMessage],
        options: GenerationOptions,
        emit: (String) -> Void,
    ) async throws {
        let noReasoning = asksForNoReasoning.withLock { $0 }
        do {
            try await stream(messages, options: options, noReasoning: noReasoning, emit: emit)
        } catch let error as EndpointError where noReasoning {
            guard case .rejectedReasoningOption = error.reason else {
                throw error
            }
            asksForNoReasoning.withLock { $0 = false }
            try await stream(messages, options: options, noReasoning: false, emit: emit)
        }
    }

    private func stream(
        _ messages: [LLMMessage],
        options: GenerationOptions,
        noReasoning: Bool,
        emit: (String) -> Void,
    ) async throws {
        var chat = ChatRequest(model: model, messages: messages, options: options)
        chat.reasoningEffort = noReasoning ? "none" : nil
        let body = try chat.encoded()
        let request = EndpointRequest.make(baseURL.appending(path: "chat/completions"), apiKey: apiKey, body: body)
        var reader = AnswerReader(model: model)
        events: for try await event in ByteStream.events(
            for: request,
            configuration: configuration(),
            redirects: .sameOrigin,
        ) {
            switch event {
            case let .response(response):
                try reader.begin(response)
            case let .data(data):
                for piece in try reader.read(data) {
                    emit(piece)
                }
                if reader.isDone {
                    // Leaving the loop closes the connection.
                    break events
                }
            }
        }
        try Task.checkCancellation()
        for piece in try reader.finish() {
            emit(piece)
        }
    }

    private func describe(_ error: any Error) -> any Error {
        switch error {
        case var known as EndpointError:
            known.server = serverName
            known.location = location
            return known
        case let error as URLError where error.code == .cancelled:
            return CancellationError()
        case let error as URLError:
            return EndpointError(EndpointError.reason(for: error) ?? .cannotConnect, server: serverName,
                                 location: location)
        case is ServerSentEventParser.TooLarge:
            return EndpointError(.notCompatible, server: serverName, location: location)
        default:
            return error
        }
    }
}

/// What every request to an endpoint shares.
public enum EndpointRequest {
    /// No cookies, cache or credentials kept. Five minutes without a byte ends a request, but there's
    /// no limit on the whole thing, since a slow server can take minutes to read a long transcript.
    @Sendable
    public static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        return configuration
    }

    static func make(_ url: URL, apiKey: String?, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

/// The body of `POST /chat/completions`. No `top_k`, which isn't in OpenAI's API and which some
/// servers reject. `reasoning_effort` is `none`, so a model that can think doesn't, as built-in
/// models don't: llama-server lets Gemma 4 think by default, which tripled the time a summary took.
private struct ChatRequest: Encodable {
    struct Message: Encodable {
        var role: String
        var content: String
    }

    var model: String
    var messages: [Message]
    var stream = true
    var temperature: Float
    var topP: Float
    var maxTokens: Int
    var seed: UInt32
    /// Left out when nil.
    var reasoningEffort: String?

    init(model: String, messages: [LLMMessage], options: GenerationOptions) {
        self.model = model
        self.messages = messages.map { Message(role: $0.role.rawValue, content: $0.content) }
        temperature = options.temperature
        topP = options.topP
        maxTokens = options.maxTokens
        seed = options.seed
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(self)
    }
}
