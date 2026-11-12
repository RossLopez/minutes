// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What Test Connection found.
public struct EndpointConnection: Equatable, Sendable {
    /// The address that worked, which gains `/v1` when the user left it off.
    public var baseURL: URL
    public var models: [String]
    /// Each model's context length, where the server says.
    public var contextLengths: [String: Int]

    public init(baseURL: URL, models: [String], contextLengths: [String: Int] = [:]) {
        self.baseURL = baseURL
        self.models = models
        self.contextLengths = contextLengths
    }
}

/// Asks an OpenAI-compatible server what it has. Only called when the user tests or refreshes an
/// endpoint, never just from opening Settings.
public struct EndpointClient: Sendable {
    public let baseURL: URL
    public let serverName: String
    public let location: NetworkLocation
    private let apiKey: String?
    private let configuration: @Sendable () -> URLSessionConfiguration

    /// More than any list of models.
    private static let maximumBytes = 4 << 20

    public init(
        baseURL: URL,
        apiKey: String?,
        serverName: String,
        location: NetworkLocation = .thisMac,
        configuration: @escaping @Sendable () -> URLSessionConfiguration = EndpointRequest.configuration,
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.serverName = serverName
        self.location = location
        self.configuration = configuration
    }

    /// The models, and their context lengths where the server says. An address without its `/v1`
    /// is tried again with it.
    public func connect() async throws -> EndpointConnection {
        do {
            return try await connect(at: baseURL)
        } catch let error as EndpointError where [.wrongAddress, .notCompatible].contains(error.reason) {
            guard baseURL.lastPathComponent != "v1" else {
                throw error
            }
            do {
                return try await connect(at: baseURL.appending(path: "v1"))
            } catch {
                // The first failure, which is about the address the user typed.
                throw error
            }
        }
    }

    private func connect(at base: URL) async throws -> EndpointConnection {
        let list = try await modelList(at: base)
        var contexts = list.contextLengths
        if contexts.count < list.models.count {
            await contexts.merge(serverContextLengths(at: base, models: list.models)) { listed, _ in listed }
        }
        return EndpointConnection(baseURL: base, models: list.models, contextLengths: contexts)
    }

    // MARK: - Models

    /// `GET /models`. llama-server also gives each model's `n_ctx`, vLLM `max_model_len` and some
    /// hosted services `context_length`.
    private func modelList(at base: URL) async throws -> EndpointConnection {
        let data = try await get(base.appending(path: "models"))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [[String: Any]]
        else {
            throw EndpointError(.notCompatible, server: serverName, location: location)
        }
        var models: [String] = []
        var contexts: [String: Int] = [:]
        for entry in entries {
            guard let id = entry["id"] as? String, !models.contains(id) else {
                continue
            }
            models.append(id)
            let meta = entry["meta"] as? [String: Any]
            let length = meta?["n_ctx"] ?? entry["max_model_len"] ?? entry["context_length"]
            if let length = (length as? NSNumber)?.intValue, length > 0 {
                contexts[id] = length
            }
        }
        return EndpointConnection(baseURL: base, models: models, contextLengths: contexts)
    }

    // MARK: - Context lengths

    /// Where servers that don't put it in the model list say how much context they run with.
    /// Failures are ignored: this is only a better guess than the default.
    private func serverContextLengths(at base: URL, models: [String]) async -> [String: Int] {
        let root = base.lastPathComponent == "v1" ? base.deletingLastPathComponent() : base
        // llama-server, which serves one model at a time.
        if let data = try? await get(root.appending(path: "props")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            let settings = object["default_generation_settings"] as? [String: Any]
            if let length = ((settings?["n_ctx"] ?? object["n_ctx"]) as? NSNumber)?.intValue, length > 0 {
                return Dictionary(uniqueKeysWithValues: models.map { ($0, length) })
            }
        }
        // LM Studio, for the models it has loaded.
        if let data = try? await get(root.appending(path: "api/v0/models")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let entries = object["data"] as? [[String: Any]]
        {
            return entries.reduce(into: [:]) { found, entry in
                if let id = entry["id"] as? String, models.contains(id),
                   let length = (entry["loaded_context_length"] as? NSNumber)?.intValue, length > 0
                {
                    found[id] = length
                }
            }
        }
        return [:]
    }

    // MARK: - Requests

    private func get(_ url: URL) async throws -> Data {
        let request = EndpointRequest.make(url, apiKey: apiKey)
        var status = 0
        var type = ""
        var data = Data()
        do {
            for try await event in ByteStream.events(for: request, configuration: configuration(),
                                                     redirects: .sameOrigin)
            {
                switch event {
                case let .response(response):
                    status = response.statusCode
                    type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                case let .data(piece):
                    guard data.count + piece.count <= Self.maximumBytes else {
                        throw EndpointError(.notCompatible, server: serverName, location: location)
                    }
                    data.append(piece)
                }
            }
        } catch let error as URLError {
            guard error.code != .cancelled else {
                throw CancellationError()
            }
            throw EndpointError(EndpointError.reason(for: error) ?? .cannotConnect, server: serverName,
                                location: location)
        }
        try Task.checkCancellation()
        guard status == 200 else {
            var reason = EndpointError.reason(status: status, body: data, model: "")
            if case .modelNotFound = reason {
                // No model was asked for, so it's the address.
                reason = .wrongAddress
            }
            throw EndpointError(reason, server: serverName, location: location)
        }
        guard !type.hasPrefix("text/html") else {
            throw EndpointError(.notCompatible, server: serverName, location: location)
        }
        return data
    }
}
