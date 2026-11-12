// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesLLM
import Observation
import os

/// How an endpoint's last check went, this session.
enum EndpointStatus: Equatable {
    case checking
    case connected(models: Int)
    case failed(String)
}

/// The endpoints the user added and which model each feature uses.
@MainActor @Observable
final class AIModelCenter {
    static let shared = AIModelCenter()

    private nonisolated static let logger = Logger(subsystem: "io.github.rosslopez.minutes", category: "endpoints")

    private(set) var endpoints: [Endpoint] {
        didSet {
            store.save(endpoints)
        }
    }

    private(set) var statuses: [UUID: EndpointStatus] = [:]

    var defaultChoice: ModelChoice {
        didSet {
            preferences.defaultChoice = defaultChoice
            SummaryCenter.shared.choicesChanged()
        }
    }

    /// Nil is "Same as default".
    private(set) var featureChoices: [AIFeature: ModelChoice] = [:]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secrets: any SecretStore

    private var store: EndpointStore {
        EndpointStore(defaults: defaults)
    }

    private var preferences: ModelPreferences {
        ModelPreferences(defaults: defaults, fallback: .builtIn(ModelCatalog.recommended().id))
    }

    private init() {
        (defaults, secrets) = Self.storage()
        let preferences = ModelPreferences(defaults: defaults, fallback: .builtIn(ModelCatalog.recommended().id))
        endpoints = EndpointStore(defaults: defaults).load()
        defaultChoice = preferences.defaultChoice
        for feature in AIFeature.allCases {
            featureChoices[feature] = preferences.choice(for: feature)
        }
    }

    /// UI tests get preferences and keys of their own, fresh for each test's folder, so they never
    /// touch the user's. `MINUTES_TEST_KEYCHAIN` keeps the real Keychain, for checking it by hand.
    private static func storage() -> (UserDefaults, any SecretStore) {
        #if DEBUG
            if let root = ProcessInfo.processInfo.environment["MINUTES_TEST_ROOT"],
               let defaults = UserDefaults(suiteName: "io.github.rosslopez.minutes.uitest")
            {
                if defaults.string(forKey: "testRoot") != root {
                    defaults.removePersistentDomain(forName: "io.github.rosslopez.minutes.uitest")
                    defaults.set(root, forKey: "testRoot")
                }
                let useKeychain = ProcessInfo.processInfo.environment["MINUTES_TEST_KEYCHAIN"] == "1"
                return (defaults, useKeychain ? KeychainSecretStore() : InMemorySecretStore())
            }
        #endif
        return (.standard, KeychainSecretStore())
    }

    // MARK: - Choices

    func choice(for feature: AIFeature) -> ModelChoice? {
        featureChoices[feature]
    }

    func setChoice(_ choice: ModelChoice?, for feature: AIFeature) {
        featureChoices[feature] = choice
        preferences.setChoice(choice, for: feature)
        SummaryCenter.shared.choicesChanged()
    }

    /// What `feature` uses now, with built-in models that are downloaded.
    func resolvedChoice(for feature: AIFeature, installed: Set<String>) -> ModelChoice? {
        preferences.resolvedChoice(for: feature, endpoints: endpoints, installed: installed)
    }

    func endpoint(_ id: UUID) -> Endpoint? {
        endpoints.first { $0.id == id }
    }

    /// Like "Gemma 4 12B" or "qwen3-8b on LM Studio". A removed endpoint's model goes by its name.
    func name(of choice: ModelChoice) -> String {
        switch choice {
        case let .builtIn(id):
            return ModelCatalog.model(id: id)?.name ?? id
        case let .endpoint(id, model):
            let shown = Endpoint.displayName(ofModel: model)
            return endpoint(id).map { "\(shown) on \($0.name)" } ?? shown
        }
    }

    /// Whether the choice sends transcripts off the user's network, or might.
    func isOffNetwork(_ choice: ModelChoice) -> Bool {
        choice.endpointID.flatMap(endpoint).map(\.isOffNetwork) ?? false
    }

    // MARK: - Providers

    func provider(for choice: ModelChoice) -> OpenAICompatibleProvider? {
        guard case let .endpoint(id, model) = choice, let endpoint = endpoint(id) else {
            return nil
        }
        return OpenAICompatibleProvider(
            id: choice.storageID,
            baseURL: endpoint.baseURL,
            model: model,
            apiKey: apiKey(for: endpoint),
            contextLength: endpoint.contextLength(for: model),
            serverName: endpoint.name,
            location: endpoint.location ?? .internet,
        )
    }

    func apiKey(for endpoint: Endpoint) -> String? {
        guard endpoint.usesAPIKey else {
            return nil
        }
        do {
            return try secrets.secret(for: endpoint.secretAccount)
        } catch {
            Self.logger.error("Reading an API key failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Endpoints

    /// Saves a new or edited endpoint. A nil key leaves the saved one as it is, and an empty one
    /// removes it.
    func save(_ endpoint: Endpoint, apiKey: String?) throws {
        var endpoint = endpoint
        if let apiKey {
            if apiKey.isEmpty {
                try secrets.removeSecret(for: endpoint.secretAccount)
            } else {
                try secrets.setSecret(apiKey, for: endpoint.secretAccount)
            }
            endpoint.usesAPIKey = !apiKey.isEmpty
        }
        if let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) {
            endpoints[index] = endpoint
        } else {
            endpoints.append(endpoint)
        }
        SummaryCenter.shared.choicesChanged()
    }

    func remove(_ endpoint: Endpoint) {
        try? secrets.removeSecret(for: endpoint.secretAccount)
        endpoints.removeAll { $0.id == endpoint.id }
        statuses[endpoint.id] = nil
        preferences.forget(endpoint: endpoint.id)
        defaultChoice = preferences.defaultChoice
        for feature in AIFeature.allCases {
            featureChoices[feature] = preferences.choice(for: feature)
        }
    }

    /// Asks a server for its models: an endpoint being edited, or a saved one. Only ever called
    /// from a button the user pressed.
    static func connect(
        to url: URL,
        apiKey: String?,
        name: String,
    ) async throws -> (EndpointConnection, NetworkLocation?) {
        let location = await NetworkLocator.location(of: url)
        if case let .failure(problem) = EndpointAddressProblem.check(url.absoluteString, location: location) {
            throw problem
        }
        let client = EndpointClient(baseURL: url, apiKey: apiKey, serverName: name, location: location ?? .internet)
        return try await (client.connect(), location)
    }

    /// Refresh Models for a saved endpoint: its list, context lengths and location.
    func refresh(_ endpoint: Endpoint) async {
        statuses[endpoint.id] = .checking
        do {
            let (connection, location) = try await Self.connect(
                to: endpoint.baseURL,
                apiKey: apiKey(for: endpoint),
                name: endpoint.name,
            )
            guard var current = self.endpoint(endpoint.id) else {
                return
            }
            current.apply(connection, location: location)
            endpoints[endpoints.firstIndex { $0.id == endpoint.id }!] = current
            statuses[endpoint.id] = .connected(models: connection.models.count)
        } catch {
            statuses[endpoint.id] = .failed(Self.describe(error))
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as EndpointError: error.message
        case let problem as EndpointAddressProblem: problem.message
        default: "Minutes couldn't check this server."
        }
    }
}

extension Endpoint {
    /// What a test found.
    mutating func apply(_ connection: EndpointConnection, location: NetworkLocation?) {
        baseURL = connection.baseURL
        models = connection.models
        detectedContextLengths = connection.contextLengths
        self.location = location ?? self.location
    }
}
