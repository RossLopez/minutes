// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A model the user can pick: one inside Minutes, or one on an endpoint.
public enum ModelChoice: Hashable, Sendable {
    /// A catalog ID, like `gemma-4-12b`.
    case builtIn(String)
    case endpoint(UUID, model: String)

    /// Read from `builtin:<id>` or `endpoint:<uuid>/<model>`. A bare catalog ID, as Milestone 5
    /// saved it, is a built-in model.
    public init?(storageID: String) {
        if storageID.hasPrefix("builtin:") {
            self = .builtIn(String(storageID.dropFirst("builtin:".count)))
        } else if storageID.hasPrefix("endpoint:") {
            let rest = storageID.dropFirst("endpoint:".count)
            // A model name can have slashes of its own, so only the first one splits.
            guard let slash = rest.firstIndex(of: "/"),
                  let id = UUID(uuidString: String(rest[..<slash])),
                  rest.index(after: slash) < rest.endIndex
            else {
                return nil
            }
            self = .endpoint(id, model: String(rest[rest.index(after: slash)...]))
        } else if !storageID.isEmpty, !storageID.contains(":") {
            self = .builtIn(storageID)
        } else {
            return nil
        }
    }

    /// Saved in preferences, and as the provider ID in a summary's `model` field.
    public var storageID: String {
        switch self {
        case let .builtIn(id): "builtin:\(id)"
        case let .endpoint(id, model): "endpoint:\(id.uuidString)/\(model)"
        }
    }

    public var endpointID: UUID? {
        if case let .endpoint(id, _) = self {
            return id
        }
        return nil
    }
}

/// Each thing Minutes uses a model for, which can each have their own.
public enum AIFeature: String, CaseIterable, Identifiable, Sendable {
    case summaries
    /// Milestone 7.
    case notesCleanup
    /// Milestone 8.
    case chat

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .summaries: "Summaries"
        case .notesCleanup: "Notes cleanup"
        case .chat: "Chat"
        }
    }

    /// Whether this version of Minutes uses the choice yet.
    public var isAvailable: Bool {
        self == .summaries
    }
}

/// The default model and each feature's choice, in preferences.
public struct ModelPreferences {
    public static let defaultKey = "ai.defaultModel"
    /// Milestone 5's one model, a bare catalog ID. Read when there's no default yet.
    public static let legacyKey = "ai.model"

    private let defaults: UserDefaults
    private let fallback: ModelChoice

    /// - Parameter fallback: the default before the user picks one.
    public init(defaults: UserDefaults = .standard, fallback: ModelChoice) {
        self.defaults = defaults
        self.fallback = fallback
    }

    public static func key(for feature: AIFeature) -> String {
        "ai.model.\(feature.rawValue)"
    }

    public var defaultChoice: ModelChoice {
        get {
            let saved = defaults.string(forKey: Self.defaultKey) ?? defaults.string(forKey: Self.legacyKey)
            return saved.flatMap(ModelChoice.init(storageID:)) ?? fallback
        }
        nonmutating set {
            defaults.set(newValue.storageID, forKey: Self.defaultKey)
        }
    }

    /// Nil is "Same as default".
    public func choice(for feature: AIFeature) -> ModelChoice? {
        defaults.string(forKey: Self.key(for: feature)).flatMap(ModelChoice.init(storageID:))
    }

    public func setChoice(_ choice: ModelChoice?, for feature: AIFeature) {
        if let choice {
            defaults.set(choice.storageID, forKey: Self.key(for: feature))
        } else {
            defaults.removeObject(forKey: Self.key(for: feature))
        }
    }

    /// What `feature` uses: its own choice while it still exists, else the default. Nil when neither
    /// can be used, such as a built-in model that isn't downloaded.
    public func resolvedChoice(
        for feature: AIFeature,
        endpoints: [Endpoint],
        installed: Set<String>,
    ) -> ModelChoice? {
        let usable = { (choice: ModelChoice) -> Bool in
            switch choice {
            case let .builtIn(id): installed.contains(id)
            // A model the server no longer lists is still tried, so its own error can say so.
            case let .endpoint(id, _): endpoints.contains { $0.id == id }
            }
        }
        return [choice(for: feature), defaultChoice].compactMap(\.self).first(where: usable)
    }

    /// An endpoint was removed: choices that used it go back to the default, and a default that
    /// used it goes back to `fallback`.
    public func forget(endpoint id: UUID) {
        for feature in AIFeature.allCases where choice(for: feature)?.endpointID == id {
            setChoice(nil, for: feature)
        }
        if defaultChoice.endpointID == id {
            defaultChoice = fallback
        }
    }
}
