// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesLLM
import Testing

@Test func `passages and questions are written as EmbeddingGemma's card asks`() {
    let format = EmbeddingFormat.embeddingGemma
    #expect(format.query("who owns the budget?") == "task: search result | query: who owns the budget?")
    #expect(format.document(EmbeddingDocument(title: "Kickoff", text: "Hi")) == "title: Kickoff | text: Hi")
    #expect(format.document(EmbeddingDocument(title: nil, text: "Hi")) == "title: none | text: Hi")
    #expect(format.document(EmbeddingDocument(title: "", text: "Hi")) == "title: none | text: Hi")
    // Braces in a title or text are left alone.
    #expect(format.document(EmbeddingDocument(title: "{text}", text: "{title}")) == "title: {text} | text: {title}")
}

@Test func `a cut vector has length one`() {
    let cut = EmbeddingMath.truncated([3, 4, 12], to: 2)
    #expect(cut == [0.6, 0.8])
    #expect(EmbeddingMath.normalized([0, 0]) == [0, 0])
}

@Test func `the fake embedder puts texts that share words close together`() async throws {
    let embedder = FakeEmbeddingProvider()
    let query = try await embedder.embed(query: "budget numbers")
    let vectors = try await embedder.embed(documents: [
        EmbeddingDocument(title: nil, text: "Bea has the budget numbers"),
        EmbeddingDocument(title: nil, text: "A rubber remote control"),
    ])
    let scores = vectors.map { zip($0, query).reduce(0) { $0 + $1.0 * $1.1 } }
    #expect(scores[0] > scores[1])
    #expect(try await embedder.embed(query: "budget numbers") == query)
}
