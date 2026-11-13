// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesLLM
import Testing

private func freshDefaults() throws -> UserDefaults {
    let name = "minutes-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private let studio = Endpoint(
    id: UUID(uuidString: "6F1C2B0E-8C55-4C3B-9A51-0D5E0B9E2A10")!,
    name: "LM Studio",
    baseURL: URL(string: "http://localhost:1234/v1")!,
    models: ["qwen3-8b"],
)

// MARK: - Choices

@Test func `choices are saved and read back by their storage ID`() {
    let endpoint = ModelChoice.endpoint(studio.id, model: "library/llama3.1:8b")
    #expect(endpoint.storageID == "endpoint:6F1C2B0E-8C55-4C3B-9A51-0D5E0B9E2A10/library/llama3.1:8b")
    #expect(ModelChoice(storageID: endpoint.storageID) == endpoint)
    #expect(ModelChoice(storageID: "builtin:gemma-4-12b") == .builtIn("gemma-4-12b"))
    // Milestone 5 saved a bare catalog ID.
    #expect(ModelChoice(storageID: "gemma-4-e4b") == .builtIn("gemma-4-e4b"))
    for broken in ["", "endpoint:", "endpoint:not-a-uuid/model", "endpoint:\(studio.id.uuidString)/", "other:x"] {
        #expect(ModelChoice(storageID: broken) == nil)
    }
}

@Test func `the Milestone 5 model becomes the default`() throws {
    let defaults = try freshDefaults()
    let preferences = ModelPreferences(defaults: defaults, fallback: .builtIn("gemma-4-12b"))
    #expect(preferences.defaultChoice == .builtIn("gemma-4-12b"))
    defaults.set("gemma-4-e2b", forKey: ModelPreferences.legacyKey)
    #expect(preferences.defaultChoice == .builtIn("gemma-4-e2b"))
    preferences.defaultChoice = .endpoint(studio.id, model: "qwen3-8b")
    #expect(preferences.defaultChoice == .endpoint(studio.id, model: "qwen3-8b"))
    #expect(defaults.string(forKey: ModelPreferences.defaultKey) == "endpoint:\(studio.id.uuidString)/qwen3-8b")
}

@Test func `a feature uses its own choice, else the default`() throws {
    let preferences = try ModelPreferences(defaults: freshDefaults(), fallback: .builtIn("gemma-4-12b"))
    let installed: Set = ["gemma-4-12b"]
    #expect(preferences.resolvedChoice(for: .summaries, endpoints: [studio], installed: installed)
        == .builtIn("gemma-4-12b"))
    preferences.setChoice(.endpoint(studio.id, model: "qwen3-8b"), for: .summaries)
    #expect(preferences.resolvedChoice(for: .summaries, endpoints: [studio], installed: installed)
        == .endpoint(studio.id, model: "qwen3-8b"))
    #expect(preferences.resolvedChoice(for: .chat, endpoints: [studio], installed: installed)
        == .builtIn("gemma-4-12b"))
    preferences.setChoice(nil, for: .summaries)
    #expect(preferences.choice(for: .summaries) == nil)
}

@Test func `a choice that can't be used falls back, and nothing usable is nil`() throws {
    let preferences = try ModelPreferences(defaults: freshDefaults(), fallback: .builtIn("gemma-4-12b"))
    preferences.setChoice(.builtIn("gemma-4-e2b"), for: .summaries)
    // Its endpoint's gone, or its model isn't downloaded: the default is used.
    #expect(preferences.resolvedChoice(for: .summaries, endpoints: [], installed: ["gemma-4-12b"])
        == .builtIn("gemma-4-12b"))
    #expect(preferences.resolvedChoice(for: .summaries, endpoints: [], installed: []) == nil)
    // A model the server stopped listing is still tried, so its error can say so.
    preferences.setChoice(.endpoint(studio.id, model: "gone"), for: .summaries)
    #expect(preferences.resolvedChoice(for: .summaries, endpoints: [studio], installed: [])
        == .endpoint(studio.id, model: "gone"))
}

@Test func `forgetting an endpoint resets every choice that used it`() throws {
    let preferences = try ModelPreferences(defaults: freshDefaults(), fallback: .builtIn("gemma-4-12b"))
    let other = UUID()
    preferences.defaultChoice = .endpoint(studio.id, model: "qwen3-8b")
    preferences.setChoice(.endpoint(studio.id, model: "qwen3-8b"), for: .summaries)
    preferences.setChoice(.endpoint(other, model: "x"), for: .chat)
    preferences.forget(endpoint: studio.id)
    #expect(preferences.defaultChoice == .builtIn("gemma-4-12b"))
    #expect(preferences.choice(for: .summaries) == nil)
    #expect(preferences.choice(for: .chat) == .endpoint(other, model: "x"))
}

// MARK: - Endpoints

@Test func `endpoints are saved without their keys`() throws {
    let defaults = try freshDefaults()
    let store = EndpointStore(defaults: defaults)
    #expect(store.load().isEmpty)
    var saved = studio
    saved.usesAPIKey = true
    saved.detectedContextLengths = ["qwen3-8b": 8192]
    saved.location = .thisMac
    store.save([saved])
    #expect(store.load() == [saved])
    let json = try String(bytes: #require(defaults.data(forKey: EndpointStore.key)), encoding: .utf8)
    #expect(json?.contains("sk-") == false)
}

@Test func `the context length is the user's, then the server's, then 8192`() {
    var endpoint = studio
    #expect(endpoint.contextLength(for: "qwen3-8b") == 8192)
    #expect(endpoint.isContextAssumed(for: "qwen3-8b"))
    endpoint.detectedContextLengths = ["qwen3-8b": 32768]
    #expect(endpoint.contextLength(for: "qwen3-8b") == 32768)
    #expect(!endpoint.isContextAssumed(for: "qwen3-8b"))
    endpoint.contextLength = 4096
    #expect(endpoint.contextLength(for: "qwen3-8b") == 4096)
}

@Test func `llama-server's path-like model names are shortened for showing`() {
    #expect(Endpoint.displayName(ofModel: "/Users/me/models/gemma-4-E4B_q4_0-it.gguf") == "gemma-4-E4B_q4_0-it")
    #expect(Endpoint.displayName(ofModel: "qwen/qwen3-8b") == "qwen/qwen3-8b")
}

@Test func `an address is checked before it's saved`() throws {
    let check = EndpointAddressProblem.check
    #expect(try check(" http://localhost:8080/v1/ ", .thisMac).get().absoluteString == "http://localhost:8080/v1")
    #expect(try check("http://192.168.1.5:1234/v1", .localNetwork).get().host() == "192.168.1.5")
    #expect(try check("https://api.example.com/v1", .internet).get().scheme == "https")
    #expect(check("http://api.example.com/v1", .internet) == .failure(.needsHTTPS))
    for broken in ["", "localhost:8080", "ftp://host/v1", "http://", "http://host/v1?x=1"] {
        #expect(check(broken, nil) == .failure(.invalid))
    }
}

// MARK: - Secrets

@Test func `secrets are kept by account`() throws {
    let store = InMemorySecretStore()
    try store.setSecret("sk-one", for: studio.secretAccount)
    #expect(try store.secret(for: studio.secretAccount) == "sk-one")
    try store.removeSecret(for: studio.secretAccount)
    #expect(try store.secret(for: studio.secretAccount) == nil)
}
