// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Synchronization

/// An OpenAI-compatible server the user added. Saved in preferences without its API key, which is
/// in the Keychain.
public struct Endpoint: Codable, Identifiable, Equatable, Sendable {
    /// What Minutes assumes when neither the user nor the server says.
    public static let defaultContextLength = 8192

    public var id: UUID
    public var name: String
    /// Like `http://localhost:8080/v1`.
    public var baseURL: URL
    /// Whether there's a key in the Keychain, so it's only read when a request needs it.
    public var usesAPIKey: Bool
    /// Set by the user. Nil is Automatic.
    public var contextLength: Int?
    /// What the server said at the last test, by model.
    public var detectedContextLengths: [String: Int]
    /// From the last test, so the pickers work while the server is off.
    public var models: [String]
    /// Where the server was at the last check.
    public var location: NetworkLocation?

    public init(
        id: UUID = UUID(),
        name: String,
        baseURL: URL,
        usesAPIKey: Bool = false,
        contextLength: Int? = nil,
        detectedContextLengths: [String: Int] = [:],
        models: [String] = [],
        location: NetworkLocation? = nil,
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.usesAPIKey = usesAPIKey
        self.contextLength = contextLength
        self.detectedContextLengths = detectedContextLengths
        self.models = models
        self.location = location
    }

    /// The user's setting, else what the server said, else the default.
    public func contextLength(for model: String) -> Int {
        contextLength ?? detectedContextLengths[model] ?? Self.defaultContextLength
    }

    /// Whether the context length is only Minutes' guess.
    public func isContextAssumed(for model: String) -> Bool {
        contextLength == nil && detectedContextLengths[model] == nil
    }

    /// Whether transcripts sent here leave the user's network, or might.
    public var isOffNetwork: Bool {
        location.map { $0 == .internet } ?? true
    }

    /// The Keychain account for its key.
    public var secretAccount: String {
        "endpoint:\(id.uuidString)"
    }

    /// A model's name for showing. llama-server names a model by its file's full path.
    public static func displayName(ofModel model: String) -> String {
        guard model.hasPrefix("/") else {
            return model
        }
        let file = (model as NSString).lastPathComponent
        return file.lowercased().hasSuffix(".gguf") ? String(file.dropLast(5)) : file
    }
}

/// Why an address can't be saved.
public enum EndpointAddressProblem: Error, Equatable, Sendable {
    /// Not a URL at all, or not http or https.
    case invalid
    /// Plain http to a server off the user's network, which anyone along the way could read.
    case needsHTTPS

    public var message: String {
        switch self {
        case .invalid: "Enter an address that starts with http:// or https://, like http://localhost:8080/v1."
        case .needsHTTPS: "A server outside your network needs an address that starts with https://."
        }
    }

    /// The address as typed, made a URL, or why it can't be one. `location` is nil when it's not
    /// known yet.
    public static func check(_ text: String, location: NetworkLocation?) -> Result<URL, Self> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(), !host.isEmpty, url.query == nil, url.fragment == nil
        else {
            return .failure(.invalid)
        }
        if scheme == "http", location == .internet {
            return .failure(.needsHTTPS)
        }
        return .success(url)
    }
}

/// The endpoint list, saved as JSON in preferences.
public struct EndpointStore {
    public static let key = "ai.endpoints"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [Endpoint] {
        guard let data = defaults.data(forKey: Self.key) else {
            return []
        }
        return (try? JSONDecoder().decode([Endpoint].self, from: data)) ?? []
    }

    public func save(_ endpoints: [Endpoint]) {
        guard let data = try? JSONEncoder().encode(endpoints) else {
            return
        }
        defaults.set(data, forKey: Self.key)
    }
}

/// Where API keys are kept: the Keychain in the app, memory in tests.
public protocol SecretStore: Sendable {
    func secret(for account: String) throws -> String?
    func setSecret(_ secret: String, for account: String) throws
    func removeSecret(for account: String) throws
}

public final class InMemorySecretStore: SecretStore {
    private let secrets = Mutex<[String: String]>([:])

    public init() {}

    public func secret(for account: String) throws -> String? {
        secrets.withLock { $0[account] }
    }

    public func setSecret(_ secret: String, for account: String) throws {
        secrets.withLock { $0[account] = secret }
    }

    public func removeSecret(for account: String) throws {
        _ = secrets.withLock { $0.removeValue(forKey: account) }
    }
}
