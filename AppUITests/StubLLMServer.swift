// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Network

/// A small OpenAI-compatible server on 127.0.0.1, inside the test runner: one model, and a summary
/// streamed a few words at a time. Each connection serves one request and closes.
final class StubLLMServer: @unchecked Sendable {
    static let model = "stub-model"
    static let answer = """
    ## Overview
    Written by the stub server.

    ## Action items
    - [ ] **Robin:** Check the stub.
    """

    private let listener: NWListener
    private let queue = DispatchQueue(label: "StubLLMServer")
    private var bodies: [String] = []

    /// The chat requests' bodies, in order.
    var chatRequests: [String] {
        queue.sync { bodies }
    }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
    }

    /// Starts listening and returns the port.
    func start() throws -> UInt16 {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                ready.signal()
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success, let port = listener.port?.rawValue else {
            throw URLError(.cannotConnectToHost)
        }
        return port
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    /// Reads until the headers and the body they announce have arrived.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, _ in
            guard let self else {
                return
            }
            let buffer = buffer + (data ?? Data())
            if let request = Self.request(in: buffer) {
                respond(to: request, on: connection)
            } else if done {
                connection.cancel()
            } else {
                receive(on: connection, buffer: buffer)
            }
        }
    }

    private static func request(in buffer: Data) -> (line: String, body: String)? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        let head = String(bytes: buffer[..<end.lowerBound], encoding: .utf8) ?? ""
        let length = head.split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        let body = buffer[end.upperBound...]
        guard body.count >= length else {
            return nil
        }
        let line = head.split(separator: "\r\n").first.map(String.init) ?? ""
        return (line, String(bytes: body.prefix(length), encoding: .utf8) ?? "")
    }

    private func respond(to request: (line: String, body: String), on connection: NWConnection) {
        let reply: (type: String, body: String)
        if request.line.hasPrefix("GET /v1/models ") {
            reply = ("application/json", #"{"object":"list","data":[{"id":"\#(Self.model)","meta":{"n_ctx":16384}}]}"#)
        } else if request.line.hasPrefix("POST /v1/chat/completions ") {
            bodies.append(request.body)
            reply = ("text/event-stream", Self.stream())
        } else {
            let head = "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: 2\r\n"
                + "Connection: close\r\n\r\n{}"
            send(head, on: connection)
            return
        }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(reply.type)\r\nContent-Length: \(reply.body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n"
        send(head + reply.body, on: connection)
    }

    /// The answer as chat completion chunks, a word at a time.
    private static func stream() -> String {
        let words = answer.split(separator: " ", omittingEmptySubsequences: false).enumerated().map { index, word in
            index == 0 ? String(word) : " " + word
        }
        let chunks = words.map { word -> String in
            let object = ["choices": [["index": 0, "delta": ["content": word]]]]
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            return "data: \(String(bytes: data, encoding: .utf8) ?? "")\n\n"
        }
        return chunks.joined() + "data: [DONE]\n\n"
    }

    private func send(_ text: String, on connection: NWConnection) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
