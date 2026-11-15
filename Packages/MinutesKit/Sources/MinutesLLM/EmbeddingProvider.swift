// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A passage to embed, with the title of the meeting it comes from.
public struct EmbeddingDocument: Equatable, Sendable {
    public var title: String?
    public var text: String

    public init(title: String?, text: String) {
        self.title = title
        self.text = text
    }
}

/// Something that turns text into vectors for search by meaning. Vectors come back normalized,
/// so a dot product is their cosine similarity.
public protocol EmbeddingProvider: Sendable {
    /// Stable, and changes whenever the vectors would, like `builtin:embeddinggemma-2/256`.
    var id: String { get }

    /// How long each vector is.
    var dimensions: Int { get }

    func embed(documents: [EmbeddingDocument]) async throws -> [[Float]]

    func embed(query: String) async throws -> [Float]
}

public enum EmbeddingMath {
    /// The first `dimensions` values, scaled to length 1. Matryoshka models like EmbeddingGemma
    /// put the most meaning first, so a shorter vector still works.
    public static func truncated(_ vector: [Float], to dimensions: Int) -> [Float] {
        normalized(Array(vector.prefix(dimensions)))
    }

    public static func normalized(_ vector: [Float]) -> [Float] {
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard length > 0 else {
            return vector
        }
        return vector.map { $0 / length }
    }
}

/// How a model wants its passages and questions written before they're embedded.
public struct EmbeddingFormat: Equatable, Sendable {
    public var queryPrefix: String
    /// Holds `{title}` and `{text}`.
    public var documentTemplate: String

    public init(queryPrefix: String, documentTemplate: String) {
        self.queryPrefix = queryPrefix
        self.documentTemplate = documentTemplate
    }

    /// From EmbeddingGemma's model card, for retrieval.
    public static let embeddingGemma = EmbeddingFormat(
        queryPrefix: "task: search result | query: ",
        documentTemplate: "title: {title} | text: {text}",
    )

    public func query(_ text: String) -> String {
        queryPrefix + text
    }

    public func document(_ document: EmbeddingDocument) -> String {
        let title = document.title.map { $0.isEmpty ? "none" : $0 } ?? "none"
        // One pass, so a title that happens to hold "{text}" stays as it is.
        return documentTemplate
            .replacingOccurrences(of: "{text}", with: "\u{0}")
            .replacingOccurrences(of: "{title}", with: title)
            .replacingOccurrences(of: "\u{0}", with: document.text)
    }
}
