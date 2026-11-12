// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Reads a chat completions response as it arrives: streamed events, or one JSON body from a
/// server that ignored `stream`. Only `content` is kept. Reasoning fields and a leading
/// `<think>` block are dropped, so a thinking model's notes never reach a summary.
///
/// Errors it throws have no server name yet. The provider adds it.
struct AnswerReader {
    private enum Body {
        case events
        case json
        /// A failure, read only to tell what kind it is.
        case error(status: Int)
    }

    /// Far more than any answer, so a server can't use up memory.
    private static let maximumJSONBytes = 16 << 20
    private static let maximumErrorBytes = 64 << 10

    private let model: String
    private var body = Body.events
    private var parser = ServerSentEventParser()
    private var filter = ThinkingFilter()
    private var held = Data()
    private var sawAnswer = false
    private(set) var isDone = false

    init(model: String) {
        self.model = model
    }

    mutating func begin(_ response: HTTPURLResponse) throws {
        let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard response.statusCode == 200 else {
            body = .error(status: response.statusCode)
            return
        }
        if type.hasPrefix("text/html") {
            throw EndpointError(.notCompatible, server: "")
        }
        body = type.hasPrefix("application/json") ? .json : .events
    }

    mutating func read(_ data: Data) throws -> [String] {
        switch body {
        case .events:
            var pieces: [String] = []
            for event in try parser.feed(data) where !isDone {
                try pieces += handle(event)
            }
            return pieces
        case .json:
            guard held.count + data.count <= Self.maximumJSONBytes else {
                throw EndpointError(.notCompatible, server: "")
            }
            held.append(data)
            return []
        case .error:
            held.append(data.prefix(max(0, Self.maximumErrorBytes - held.count)))
            return []
        }
    }

    /// What's left once the response has ended.
    mutating func finish() throws -> [String] {
        var pieces: [String] = []
        switch body {
        case let .error(status):
            throw EndpointError(EndpointError.reason(status: status, body: held, model: model), server: "")
        case .json:
            pieces = try answer(in: held, streamed: false)
        case .events:
            if !isDone, let event = parser.finish() {
                pieces = try handle(event)
            }
        }
        guard sawAnswer else {
            throw EndpointError(.notCompatible, server: "")
        }
        let rest = filter.finish()
        return rest.isEmpty ? pieces : pieces + [rest]
    }

    private mutating func handle(_ event: ServerSentEvent) throws -> [String] {
        if event.data == "[DONE]" {
            isDone = true
            return []
        }
        return try answer(in: Data(event.data.utf8), streamed: true)
    }

    private mutating func answer(in data: Data, streamed: Bool) throws -> [String] {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let error = object?["error"] {
            // A failure that arrived after the response had already started, as a 200.
            let code = ((error as? [String: Any])?["code"] as? Int).flatMap { (400 ..< 600).contains($0) ? $0 : nil }
            throw EndpointError(EndpointError.reason(status: code ?? 500, body: data, model: model), server: "")
        }
        guard let chunk = try? JSONDecoder().decode(ChatChunk.self, from: data), let choices = chunk.choices else {
            throw EndpointError(.notCompatible, server: "")
        }
        sawAnswer = true
        let text = choices.first.flatMap { streamed ? $0.delta?.content : $0.message?.content } ?? ""
        let shown = filter.feed(text)
        return shown.isEmpty ? [] : [shown]
    }
}

/// The parts of a completion, or a streamed piece of one, that Minutes reads.
private struct ChatChunk: Decodable {
    struct Choice: Decodable {
        var delta: Message?
        var message: Message?
    }

    struct Message: Decodable {
        /// Null in the first piece llama-server sends, which only has the role.
        var content: String?
    }

    var choices: [Choice]?
}
