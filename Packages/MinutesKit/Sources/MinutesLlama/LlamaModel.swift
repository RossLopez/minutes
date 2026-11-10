// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import llama
import MinutesLLM

/// One loaded model and its context. Owned by `LlamaProvider`, which keeps it to one thread.
final class LlamaModel {
    let model: OpaquePointer
    let context: OpaquePointer
    let vocab: OpaquePointer
    private let chatFormat: ChatFormat
    private let batchSize: Int

    init(url: URL, contextLength: Int) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LLMError.modelUnavailable
        }
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = -1
        guard let model = llama_model_load_from_file(url.path, modelParams) else {
            throw LLMError.loadFailed("The model file couldn't be loaded. It may be damaged or need more memory.")
        }
        let trained = Int(llama_model_n_ctx_train(model))
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(trained > 0 ? min(contextLength, trained) : contextLength)
        contextParams.n_batch = 2048
        // Gemma's sliding-window layers only ever look back a window's length. Each prompt starts
        // from an empty cache, so they don't need cache for the whole context, and on the 12B
        // that would be most of its memory.
        contextParams.swa_full = false
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw LLMError.loadFailed("There isn't enough memory for this model's working space.")
        }
        guard let vocab = llama_model_get_vocab(model), let template = llama_model_chat_template(model, nil) else {
            llama_free(context)
            llama_model_free(model)
            throw LLMError.loadFailed("This model doesn't say how to format a conversation.")
        }
        self.model = model
        self.context = context
        self.vocab = vocab
        chatFormat = ChatFormat(template: String(cString: template))
        batchSize = Int(contextParams.n_batch)
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    /// The conversation as the model expects it, ending where its answer starts.
    func format(_ messages: [LLMMessage]) throws -> [PromptPiece] {
        switch chatFormat {
        case let .gemma4(emptyThought):
            ChatFormat.gemma4(messages, emptyThought: emptyThought)
        case let .builtIn(template):
            try [PromptPiece(text: builtIn(template, messages), isSpecial: true)]
        }
    }

    /// The prompt's tokens, with message text never read as control tokens.
    func tokens(_ messages: [LLMMessage]) throws -> [llama_token] {
        let pieces = try format(messages)
        var tokens: [llama_token] = []
        for (index, piece) in pieces.enumerated() {
            tokens += try tokenize(piece.text, addStart: index == 0, special: piece.isSpecial)
        }
        // A format that writes the start token as text parses to a second copy.
        let start = llama_vocab_bos(vocab)
        if tokens.count >= 2, tokens[0] == start, tokens[1] == start {
            tokens.removeFirst()
        }
        return tokens
    }

    private func builtIn(_ template: String, _ messages: [LLMMessage]) throws -> String {
        let roles = messages.map { strdup($0.role.rawValue) }
        let contents = messages.map { strdup($0.content) }
        defer {
            (roles + contents).forEach { free($0) }
        }
        let chat = zip(roles, contents).map { llama_chat_message(role: $0, content: $1) }
        var capacity = max(1024, messages.reduce(0) { $0 + $1.content.utf8.count } * 2)
        while true {
            var buffer = [CChar](repeating: 0, count: capacity)
            let written = Int(llama_chat_apply_template(template, chat, chat.count, true, &buffer, Int32(capacity)))
            guard written >= 0 else {
                throw LLMError.loadFailed("llama.cpp doesn't know this model's conversation format.")
            }
            if written < capacity {
                // Lenient on purpose: a stray byte becomes U+FFFD instead of losing the text.
                // swiftlint:disable:next optional_data_string_conversion
                return String(decoding: buffer[..<written].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            capacity = written + 1
        }
    }

    func tokenize(_ text: String, addStart: Bool, special: Bool) throws -> [llama_token] {
        let length = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(length) + 8)
        var count = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), addStart, special)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), addStart, special)
        }
        guard count >= 0 else {
            throw LLMError.generationFailed("The prompt couldn't be read into tokens.")
        }
        tokens.removeSubrange(Int(count)...)
        return tokens
    }

    /// Reads the prompt into a fresh context, a batch at a time so cancelling stays quick.
    func prefill(_ tokens: [llama_token]) throws {
        llama_memory_clear(llama_get_memory(context), true)
        var start = 0
        while start < tokens.count {
            try Task.checkCancellation()
            var chunk = Array(tokens[start ..< min(start + batchSize, tokens.count)])
            try decode(&chunk)
            start += chunk.count
        }
    }

    /// Writes the answer a token at a time. Returns how many tokens it wrote.
    func generate(options: GenerationOptions, emit: (String) -> Void) throws -> Int {
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer {
            llama_sampler_free(sampler)
        }
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(Int32(options.topK)))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(options.topP, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(options.temperature))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(options.seed))

        var pending = UTF8Assembler()
        var count = 0
        while count < options.maxTokens {
            try Task.checkCancellation()
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) {
                break
            }
            count += 1
            if let text = pending.append(piece(token)) {
                emit(text)
            }
            var next = [token]
            try decode(&next)
            token = next[0]
        }
        if let rest = pending.flush() {
            emit(rest)
        }
        return count
    }

    private func decode(_ tokens: inout [llama_token]) throws {
        let result = tokens.withUnsafeMutableBufferPointer { buffer in
            llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
        }
        guard result == 0 else {
            throw LLMError.generationFailed("The model stopped with error \(result).")
        }
    }

    /// The token's bytes. Control tokens, like the end of a turn, come back empty.
    private func piece(_ token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if length < 0 {
            buffer = [CChar](repeating: 0, count: Int(-length))
            length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return buffer[..<max(0, Int(length))].map { UInt8(bitPattern: $0) }
    }
}
