// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A stand-in embedder for tests: each word adds to a slot chosen by a stable hash, so texts
/// that share words come out close together, and the same text always gives the same vector.
public struct FakeEmbeddingProvider: EmbeddingProvider {
    public let id: String
    public let dimensions: Int

    public init(id: String = "fake-embedding", dimensions: Int = 64) {
        self.id = id
        self.dimensions = dimensions
    }

    public func embed(documents: [EmbeddingDocument]) async throws -> [[Float]] {
        documents.map { vector(for: $0.text) }
    }

    public func embed(query: String) async throws -> [Float] {
        vector(for: query)
    }

    private func vector(for text: String) -> [Float] {
        var vector = [Float](repeating: 0, count: dimensions)
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        for word in words {
            // FNV-1a, because Swift's own hash changes from run to run.
            var hash: UInt64 = 0xCBF2_9CE4_8422_2325
            for byte in word.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3
            }
            vector[Int(hash % UInt64(dimensions))] += 1
        }
        return EmbeddingMath.normalized(vector)
    }
}
