// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import MinutesLLM
import Synchronization
import Testing

// MARK: - Helpers

private func chunk(_ content: String?, reasoning: String? = nil) -> String {
    var delta: [String: Any] = [:]
    delta["content"] = content ?? NSNull()
    delta["reasoning_content"] = reasoning
    let object: [String: Any] = ["object": "chat.completion.chunk", "choices": [["index": 0, "delta": delta]]]
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    return "data: \(String(bytes: data, encoding: .utf8) ?? "")\n\n"
}

private func provider(_ base: URL, key: String? = nil) -> OpenAICompatibleProvider {
    OpenAICompatibleProvider(
        id: "endpoint:test/gemma", baseURL: base, model: "gemma", apiKey: key, contextLength: 8192,
        serverName: "Studio", location: .localNetwork, configuration: stubConfiguration,
    )
}

private func answer(_ provider: OpenAICompatibleProvider) async throws -> String {
    var text = ""
    for try await piece in provider.generate([LLMMessage(.user, "Hi")], options: GenerationOptions()) {
        text += piece
    }
    return text
}

private func failure(_ stub: StubEndpoint) async -> EndpointError? {
    do {
        _ = try await answer(provider(stubEndpoint(stub)))
        return nil
    } catch {
        return error as? EndpointError
    }
}

private let json = ["Content-Type": "application/json"]

// MARK: - Answers

@Test(arguments: [1, 5, 64, 100_000])
func `a streamed answer is read however the connection splits it`(size: Int) async throws {
    let stream = chunk(nil) + chunk("## Over") + chunk("view\nGrüße") + chunk(" 👋") + "data: [DONE]\n\n"
    let bytes = Data(stream.utf8)
    let pieces = stride(from: 0, to: bytes.count, by: size).map { bytes[$0 ..< min($0 + size, bytes.count)] }
    let base = stubEndpoint(StubEndpoint(pieces: pieces.map { Data($0) }))
    #expect(try await answer(provider(base)) == "## Overview\nGrüße 👋")
}

@Test func `the request asks for a stream with the options, and no top_k`() async throws {
    let base = stubEndpoint(StubEndpoint(pieces: [Data((chunk("Hi") + "data: [DONE]\n\n").utf8)]))
    _ = try await answer(provider(base, key: "sk-test"))
    let stub = stubbed(base)
    let request = try #require(stub.requests.first)
    #expect(request.url?.absoluteString == "\(base.absoluteString)/chat/completions")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    let sent = try #require(stub.bodies.first)
    let body = try #require(JSONSerialization.jsonObject(with: sent) as? [String: Any])
    #expect(body["model"] as? String == "gemma")
    #expect(body["stream"] as? Bool == true)
    #expect(body["max_tokens"] as? Int == 2048)
    #expect(body["seed"] as? Int == 1)
    #expect(body["top_p"] != nil && body["temperature"] != nil)
    #expect(body["top_k"] == nil)
    #expect(body["reasoning_effort"] as? String == "none")
    let messages = try #require(body["messages"] as? [[String: String]])
    #expect(messages == [["role": "user", "content": "Hi"]])
}

@Test func `without a key there's no Authorization header`() async throws {
    let base = stubEndpoint(StubEndpoint(pieces: [Data((chunk("Hi") + "data: [DONE]\n\n").utf8)]))
    _ = try await answer(provider(base, key: ""))
    #expect(stubbed(base).requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func `reasoning is dropped, in its own field or as a leading think block`() async throws {
    let stream = chunk(nil, reasoning: "The user wants") + chunk(nil, reasoning: " a summary.")
        + chunk("<think>Hidden") + chunk(" plan</think>\n\n") + chunk("## Overview") + "data: [DONE]\n\n"
    let base = stubEndpoint(StubEndpoint(pieces: [Data(stream.utf8)]))
    #expect(try await answer(provider(base)) == "## Overview")
}

@Test func `a server that ignores stream and sends one JSON body still works`() async throws {
    let object = ["choices": [["index": 0, "message": ["role": "assistant", "content": "## Overview"]]]]
    let base = try stubEndpoint(StubEndpoint(
        headers: ["Content-Type": "application/json"],
        pieces: [JSONSerialization.data(withJSONObject: object)],
    ))
    #expect(try await answer(provider(base)) == "## Overview")
}

@Test func `a stream that ends without DONE keeps what it sent`() async throws {
    let base = stubEndpoint(StubEndpoint(pieces: [Data((chunk("Cut") + chunk(" short")).utf8)]))
    #expect(try await answer(provider(base)) == "Cut short")
}

@Test func `a server that doesn't take reasoning_effort is asked again without it, once`() async throws {
    let stream = Data((chunk("Hi") + "data: [DONE]\n\n").utf8)
    let base = stubEndpoint(StubEndpoint(pieces: [stream], rejectsReasoningEffort: true))
    let strict = provider(base)
    #expect(try await answer(strict) == "Hi")
    #expect(try await answer(strict) == "Hi")
    let bodies = stubbed(base).bodies.map { String(bytes: $0, encoding: .utf8) ?? "" }
    // Refused once, then left out from then on.
    #expect(bodies.map { $0.contains("reasoning_effort") } == [true, false, false])
}

// MARK: - Failures

@Test func `a rejected key says so`() async {
    let body = Data(#"{"error":{"message":"Invalid API Key","type":"authentication_error"}}"#.utf8)
    let error = await failure(StubEndpoint(status: 401, headers: json, pieces: [body]))
    #expect(error?.reason == .keyRejected)
    #expect(error?.message == "Studio didn't accept the API key.")
}

@Test func `a missing model and a wrong address are told apart`() async {
    let model = Data(#"{"error":{"message":"model \"gemma\" not found, try pulling it first"}}"#.utf8)
    let missing = await failure(StubEndpoint(status: 404, headers: json, pieces: [model]))
    #expect(missing?.reason == .modelNotFound("gemma"))
    #expect(missing?.message == "gemma isn't on Studio anymore. Pick another model in Settings.")

    // llama-server's answer for a path it doesn't have.
    let path = Data(#"{"error":{"message":"File Not Found","type":"not_found_error","code":404}}"#.utf8)
    #expect(await failure(StubEndpoint(status: 404, headers: json, pieces: [path]))?.reason == .wrongAddress)
}

@Test func `a transcript longer than the server's context says how to fix it`() async {
    // llama-server's own wording, which echoes no prompt text but is still never shown.
    let body = Data(#"""
    {"error":{"code":400,"message":"request (6016 tokens) exceeds the available context size (4096 tokens), \#
    try increasing it","type":"exceed_context_size_error","n_prompt_tokens":6016,"n_ctx":4096}}
    """#.utf8)
    let error = await failure(StubEndpoint(status: 400, headers: json, pieces: [body]))
    #expect(error?.reason == .contextExceeded)
    #expect(error?.message.contains("6016") == false)
}

@Test func `other failures give the status, never the server's words`() async {
    let echo = Data(#"{"error":{"message":"Bad request: Dana said the budget is due Friday"}}"#.utf8)
    let rejected = await failure(StubEndpoint(status: 400, headers: json, pieces: [echo]))
    #expect(rejected?.reason == .rejected(status: 400))
    #expect(rejected?.message == "Studio refused the request (status 400).")
    let problem = await failure(StubEndpoint(status: 503, headers: json, pieces: [Data("busy".utf8)]))
    #expect(problem?.message == "Studio had a problem (status 503).")
}

@Test func `an error inside the stream is reported`() async {
    let stream = chunk("Part") + #"data: {"error":{"code":500,"message":"slot unavailable"}}"# + "\n\n"
    let error = await failure(StubEndpoint(pieces: [Data(stream.utf8)]))
    #expect(error?.reason == .serverProblem(status: 500))
}

@Test func `a web page or other JSON isn't taken for an answer`() async {
    let page = StubEndpoint(headers: ["Content-Type": "text/html"], pieces: [Data("<html></html>".utf8)])
    #expect(await failure(page)?.reason == .notCompatible)
    let other = StubEndpoint(headers: ["Content-Type": "application/json"], pieces: [Data(#"{"ok":true}"#.utf8)])
    #expect(await failure(other)?.reason == .notCompatible)
    #expect(await failure(StubEndpoint(pieces: []))?.reason == .notCompatible)
}

@Test func `a server that can't be reached says where to look`() async {
    let error = await failure(StubEndpoint(failure: URLError(.cannotConnectToHost)))
    #expect(error?.reason == .cannotConnect)
    #expect(error?.message.contains("Local Network") == true)
    #expect(await failure(StubEndpoint(failure: URLError(.timedOut)))?.message == "Studio stopped responding.")
}

@Test func `a redirect to another host is refused, so the key and transcript don't follow it`() async throws {
    let elsewhere = stubEndpoint(StubEndpoint(pieces: [Data((chunk("Hi") + "data: [DONE]\n\n").utf8)]))
    let base = stubEndpoint(StubEndpoint(redirect: elsewhere.appending(path: "chat/completions")))
    await #expect(throws: EndpointError(.redirected, server: "Studio", location: .localNetwork)) {
        try await answer(provider(base, key: "sk-test"))
    }
    #expect(stubbed(elsewhere).requests.isEmpty)

    // Model downloads do follow them, which shows the stub's redirect is a real one.
    let download = stubEndpoint(StubEndpoint(redirect: elsewhere.appending(path: "chat/completions")))
    for try await _ in ByteStream.events(for: URLRequest(url: download), configuration: stubConfiguration()) {}
    #expect(stubbed(elsewhere).requests.count == 1)
}

@Test func `cancelling stops the request`() async throws {
    let base = stubEndpoint(StubEndpoint(pieces: [Data(chunk("Started").utf8)], stalls: true))
    let consumer = Task {
        var text = ""
        for try await piece in provider(base).generate([LLMMessage(.user, "Hi")], options: GenerationOptions()) {
            text += piece
        }
        return text
    }
    try await waitUntil { stubbed(base).requests.count == 1 }
    consumer.cancel()
    // A cancelled consumer sees the stream end, keeping what had arrived.
    #expect(try await consumer.value == "Started")
    try await waitUntil { stubbed(base).stopped == 1 }
}

// MARK: - Token estimates

@Test func `token estimates err on the high side`() {
    // 300 characters of English: about 75 tokens for Gemma.
    let english = String(repeating: "The plan works. ", count: 19).prefix(300)
    let estimate = OpenAICompatibleProvider.estimatedTokens([LLMMessage(.user, String(english))])
    #expect(estimate >= 100 && estimate <= 120)
    // Japanese is close to a token a character, so each one counts as a token.
    let japanese = String(repeating: "会議", count: 50)
    #expect(OpenAICompatibleProvider.estimatedTokens([LLMMessage(.user, japanese)]) >= 100)
}

// MARK: - With a real server

/// A running server's base URL, like `http://127.0.0.1:8080/v1` for `llama-server`. These tests
/// are skipped without one.
private let realEndpoint = ProcessInfo.processInfo.environment["MINUTES_TEST_ENDPOINT"].flatMap(URL.init)

@Test(.enabled(if: realEndpoint != nil, "Set MINUTES_TEST_ENDPOINT to a server's base URL"))
func `a real server streams an answer, and its errors are read`() async throws {
    let base = try #require(realEndpoint)
    let real = OpenAICompatibleProvider(id: "test", baseURL: base, model: "test", apiKey: nil, contextLength: 4096,
                                        serverName: "Test")
    var pieces: [String] = []
    let options = GenerationOptions(maxTokens: 40)
    for try await piece in real.generate([LLMMessage(.user, "Name three colors.")], options: options) {
        pieces.append(piece)
    }
    #expect(pieces.count > 3)
    #expect(!pieces.joined().contains("<|channel>"))

    // Far more than any server's context.
    let huge = [LLMMessage(.user, String(repeating: "word ", count: 300_000))]
    await #expect(throws: EndpointError(.contextExceeded, server: "Test")) {
        for try await _ in real.generate(huge, options: options) {}
    }
    let wrong = OpenAICompatibleProvider(id: "test", baseURL: base.appending(path: "nothing"), model: "test",
                                         apiKey: nil, contextLength: 4096, serverName: "Test")
    await #expect(throws: EndpointError(.wrongAddress, server: "Test")) {
        for try await _ in wrong.generate([LLMMessage(.user, "Hi")], options: options) {}
    }
}
