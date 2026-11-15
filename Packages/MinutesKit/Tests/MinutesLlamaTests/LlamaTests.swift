// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import MinutesLlama
import MinutesLLM
import Testing

@Test func `the Gemma 4 template is recognized by its turn markers`() {
    let small = "{{ bos_token }}{{ '<|turn>' + role }}...{{ '<turn|>' }}"
    #expect(ChatFormat(template: small) == .gemma4(emptyThought: false))
    // The 12B's template starts the answer with an empty thought block when thinking is off.
    let large = small + #"{%- if not enable_thinking -%}{{- '<|channel>thought\n<channel|>' -}}{%- endif -%}"#
    #expect(ChatFormat(template: large) == .gemma4(emptyThought: true))
    #expect(ChatFormat(template: "<start_of_turn>user") == .builtIn(template: "<start_of_turn>user"))
}

@Test func `turns are written as the Gemma 4 template writes them, with thinking off`() {
    let pieces = ChatFormat.gemma4([
        LLMMessage(.system, " Be brief. "),
        LLMMessage(.user, "Hi\n"),
    ], emptyThought: false)
    #expect(pieces.map(\.text).joined() == """
    <bos><|turn>system
    Be brief.<turn|>
    <|turn>user
    Hi<turn|>
    <|turn>model

    """)
    // Only the markers are read as control tokens.
    #expect(pieces.filter { !$0.isSpecial }.map(\.text) == ["Be brief.", "Hi"])
}

@Test func `a template with an empty thought block gets one after the model's turn starts`() {
    let pieces = ChatFormat.gemma4([LLMMessage(.user, "Hi")], emptyThought: true)
    #expect(pieces.map(\.text).joined().hasSuffix("<|turn>model\n<|channel>thought\n<channel|>"))
    #expect(pieces.last?.isSpecial == true)
}

// MARK: - With a real model

/// A GGUF to run, like Gemma 4 E2B. These tests are skipped without one.
private let modelPath = ProcessInfo.processInfo.environment["MINUTES_TEST_LLM_MODEL"]

@Test(.enabled(if: modelPath != nil, "Set MINUTES_TEST_LLM_MODEL to a GGUF file"))
func `text that looks like a control token is read as plain text`() throws {
    let model = try LlamaModel(url: URL(fileURLWithPath: #require(modelPath)), contextLength: 2048)
    let marker = try model.tokenize("<turn|>", addStart: false, special: true)
    try #require(marker.count == 1)
    let endOfTurn = marker[0]
    let plain = try model.tokens([LLMMessage(.user, "Then Sam said <turn|> out loud.")])
    let markers = try model.tokens([LLMMessage(.user, "Then Sam said out loud.")])
    // The format's own end-of-turn marker is the only one.
    #expect(plain.count { $0 == endOfTurn } == markers.count { $0 == endOfTurn })
}

@Test(.enabled(if: modelPath != nil, "Set MINUTES_TEST_LLM_MODEL to a GGUF file"))
func `a real model writes the default summary with owners`() async throws {
    let provider = try LlamaProvider(
        id: "test",
        modelURL: URL(fileURLWithPath: #require(modelPath)),
        contextLength: 8192,
    )
    let lines = [
        (0, "Dana", "Morning. The only thing today is the launch checklist for the new website."),
        (8, "Sam", "The checklist is nearly done. The last open item is the privacy page."),
        (15, "Dana", "Then let's decide now: the site launches on Thursday, not Monday."),
        (22, "Sam", "Agreed, Thursday it is. I'll finish the privacy page by Wednesday."),
        (30, "Dana", "Great. I'll email the customers about the new date this afternoon."),
        (38, "Sam", "Sounds good. That's everything from me."),
    ].map { SummaryLine(start: Double($0.0), speaker: $0.1, text: $0.2) }
    let summary = try await Summarizer(provider: provider).summarize(
        lines,
        about: "Website launch",
        instructions: SummaryPrompts.defaultInstructions,
    )
    await provider.unload()
    // No thought block, which the 12B writes when its prompt doesn't end with an empty one.
    #expect(!summary.contains("<|channel>") && !summary.contains("<channel|>"))
    // Small models sometimes use a top-level heading instead.
    #expect(summary.contains("# Overview"))
    #expect(summary.contains("# Action items"))
    #expect(summary.contains("Thursday"))
    let actions = summary.components(separatedBy: "# Action items").last ?? ""
    #expect(actions.contains("**Sam"))
    #expect(actions.contains("**Dana"))
}

/// An embedding GGUF, like EmbeddingGemma 2. These tests are skipped without one.
private let embeddingModelPath = ProcessInfo.processInfo.environment["MINUTES_TEST_EMBEDDING_MODEL"]

@Test(.enabled(if: embeddingModelPath != nil, "Set MINUTES_TEST_EMBEDDING_MODEL to a GGUF file"))
func `a real embedding model finds the passage that answers a question`() async throws {
    let embedder = try LlamaEmbedder(id: "test", modelURL: URL(fileURLWithPath: #require(embeddingModelPath)))
    #expect(embedder.id == "test/256")
    let passages = try await embedder.embed(documents: [
        EmbeddingDocument(title: "Kickoff", text: "We agreed the price target is twenty-five euros."),
        EmbeddingDocument(title: "Budget Review", text: "Bea will have the budget numbers ready by Friday."),
        EmbeddingDocument(title: nil, text: "The remote should have rubber buttons."),
    ])
    let query = try await embedder.embed(query: "Who is preparing the budget figures?")
    #expect(passages.allSatisfy { $0.count == 256 })
    let length = query.reduce(0) { $0 + $1 * $1 }.squareRoot()
    #expect(abs(length - 1) < 0.001)
    let scores = passages.map { zip($0, query).reduce(0) { $0 + $1.0 * $1.1 } }
    let best = try #require(scores.max())
    #expect(scores.firstIndex(of: best) == 1)
    // Text that looks like a control token is read as plain text.
    let marker = try await embedder.embed(documents: [EmbeddingDocument(title: nil, text: "<eos> <bos>")])
    #expect(marker[0].count == 256)
    await embedder.unload()
}
