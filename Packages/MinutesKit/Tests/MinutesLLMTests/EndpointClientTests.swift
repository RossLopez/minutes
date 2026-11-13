// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import MinutesLLM
import Testing

private func client(_ base: URL, key: String? = nil) -> EndpointClient {
    EndpointClient(baseURL: base, apiKey: key, serverName: "Studio", configuration: stubConfiguration)
}

/// A server whose routes sit under `prefix`, like `/v1`.
private func server(_ routes: [String: (status: Int, json: String)]) -> URL {
    stubEndpoint(StubEndpoint(routes: routes))
}

// MARK: - Models and context

@Test func `llama-server's models come with their context length`() async throws {
    // Trimmed from llama-server b12110's own answer.
    let list = #"""
    {"object":"list","data":[{"id":"gemma-4-E4B_q4_0-it.gguf","object":"model","owned_by":"llamacpp",
    "meta":{"n_ctx":32768,"n_ctx_train":131072}}]}
    """#
    let base = server(["/v1/models": (200, list)])
    let connection = try await client(base, key: "sk-test").connect()
    #expect(connection == EndpointConnection(
        baseURL: base,
        models: ["gemma-4-E4B_q4_0-it.gguf"],
        contextLengths: ["gemma-4-E4B_q4_0-it.gguf": 32768],
    ))
    #expect(stubbed(base).requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    // Nothing else was asked once the list had it.
    #expect(stubbed(base).requests.count == 1)
}

@Test func `llama-server's props give the context when the list doesn't`() async throws {
    let base = server([
        "/v1/models": (200, #"{"data":[{"id":"gemma"}]}"#),
        "/props": (200, #"{"default_generation_settings":{"n_ctx":16384},"total_slots":1}"#),
    ])
    #expect(try await client(base).connect().contextLengths == ["gemma": 16384])
}

@Test func `LM Studio's loaded context length is read for each model`() async throws {
    let base = server([
        "/v1/models": (200, #"{"data":[{"id":"qwen3-8b"},{"id":"gemma-3-12b"},{"id":"qwen3-8b"}]}"#),
        "/api/v0/models": (200, #"""
        {"data":[{"id":"qwen3-8b","state":"loaded","max_context_length":40960,"loaded_context_length":8192},
        {"id":"gemma-3-12b","state":"not-loaded","max_context_length":131072}]}
        """#),
    ])
    let connection = try await client(base).connect()
    #expect(connection.models == ["qwen3-8b", "gemma-3-12b"])
    #expect(connection.contextLengths == ["qwen3-8b": 8192])
}

@Test func `a server that doesn't say leaves the context length to the user`() async throws {
    // Ollama's list, whose context comes from each model's own settings.
    let base = server(["/v1/models": (200, #"{"object":"list","data":[{"id":"llama3.1:8b","owned_by":"library"}]}"#)])
    let connection = try await client(base).connect()
    #expect(connection.models == ["llama3.1:8b"])
    #expect(connection.contextLengths.isEmpty)
}

@Test func `an address without its v1 is tried again with it`() async throws {
    let base = server(["/v1/models": (200, #"{"data":[{"id":"gemma"}],"object":"list"}"#)])
    let typed = base.deletingLastPathComponent()
    let connection = try await client(typed).connect()
    #expect(connection.baseURL.absoluteString == typed.appending(path: "v1").absoluteString)
    #expect(connection.models == ["gemma"])
}

@Test func `a wrong address reports the address the user typed`() async {
    let base = server(["/v1/models": (200, #"{"data":[]}"#)])
    let typed = base.deletingLastPathComponent().appending(path: "api")
    await #expect(throws: EndpointError(.wrongAddress, server: "Studio")) {
        try await client(typed).connect()
    }
}

@Test func `connection reports a rejected key, a web page and no server`() async throws {
    let locked = server(["/v1/models": (401, #"{"error":{"message":"Invalid API Key"}}"#)])
    await #expect(throws: EndpointError(.keyRejected, server: "Studio")) {
        try await client(locked, key: "wrong").connect()
    }
    let page = stubEndpoint(StubEndpoint(headers: ["Content-Type": "text/html"], pieces: [Data("<html>".utf8)]))
    await #expect(throws: EndpointError(.notCompatible, server: "Studio")) {
        try await client(page).connect()
    }
    let nobody = try #require(URL(string: "http://nobody-\(UUID().uuidString).test/v1"))
    await #expect(throws: EndpointError(.cannotConnect, server: "Studio")) {
        try await client(nobody).connect()
    }
}

// MARK: - Where a server is

@Test(arguments: [
    ("127.0.0.1", NetworkLocation.thisMac), ("127.4.5.6", .thisMac), ("0.0.0.0", .thisMac),
    ("::1", .thisMac), ("::", .thisMac), ("::ffff:127.0.0.1", .thisMac),
    ("10.0.0.2", .localNetwork), ("172.16.0.1", .localNetwork), ("172.31.255.255", .localNetwork),
    ("192.168.1.20", .localNetwork), ("169.254.10.1", .localNetwork),
    ("100.64.0.1", .localNetwork), ("100.127.255.254", .localNetwork),
    ("fd7a:115c:a1e0::1", .localNetwork), ("fe80::1", .localNetwork), ("fe80::1%en0", .localNetwork),
    ("::ffff:192.168.1.1", .localNetwork),
    ("172.15.0.1", .internet), ("172.32.0.1", .internet), ("192.169.0.1", .internet),
    ("100.63.0.1", .internet), ("100.128.0.1", .internet), ("8.8.8.8", .internet),
    ("2606:4700::1111", .internet), ("fec0::1", .internet),
])
func `addresses are placed by range`(address: String, location: NetworkLocation) {
    #expect(NetworkLocator.location(ofAddress: address) == location)
}

@Test func `names are resolved, and the farthest address counts`() async throws {
    #expect(try await NetworkLocator.location(of: #require(URL(string: "http://localhost:8080/v1"))) == .thisMac)
    #expect(try await NetworkLocator.location(of: #require(URL(string: "http://studio.localhost/v1"))) == .thisMac)
    #expect(try await NetworkLocator.location(of: #require(URL(string: "http://[::1]:1234/v1"))) == .thisMac)
    #expect(try await NetworkLocator.location(of: #require(URL(string: "http://192.168.1.5:1234/v1"))) == .localNetwork)
    // Names that aren't there: one that looks local, and one that doesn't.
    let missing = "minutes-test-\(UUID().uuidString.prefix(8).lowercased())"
    #expect(try await NetworkLocator.location(of: #require(URL(string: "http://\(missing).local/v1"))) == .localNetwork)
    #expect(try await NetworkLocator.location(of: #require(URL(string: "http://\(missing).invalid/v1"))) == nil)
    #expect(NetworkLocation.internet > .localNetwork && NetworkLocation.localNetwork > .thisMac)
}

// MARK: - With a real server

@Test(.enabled(if: ProcessInfo.processInfo.environment["MINUTES_TEST_ENDPOINT"] != nil,
               "Set MINUTES_TEST_ENDPOINT to a server's base URL"))
func `a real server lists its models, with or without the v1`() async throws {
    let base = try #require(ProcessInfo.processInfo.environment["MINUTES_TEST_ENDPOINT"].flatMap(URL.init))
    let connection = try await EndpointClient(baseURL: base, apiKey: nil, serverName: "Test").connect()
    let model = try #require(connection.models.first)
    #expect(connection.contextLengths[model] != nil)
    // llama-server answers at its root too, so that address is kept as typed.
    let root = base.deletingLastPathComponent()
    #expect(try await EndpointClient(baseURL: root, apiKey: nil, serverName: "Test").connect().models
        == connection.models)
}
