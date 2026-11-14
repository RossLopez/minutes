// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import llama
import MinutesLLM

/// One loaded embedding model and its context. Owned by `LlamaEmbedder`, which keeps it to one
/// thread.
final class LlamaEmbeddingModel {
    let model: OpaquePointer
    let context: OpaquePointer
    let vocab: OpaquePointer
    /// The pooled vector's length.
    let width: Int
    /// The most tokens one passage can be. Longer ones are cut.
    let maxTokens: Int
    private let maxSequences: Int

    init(url: URL, contextLength: Int, sequences: Int) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LLMError.modelUnavailable
        }
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = -1
        guard let model = llama_model_load_from_file(url.path, modelParams) else {
            throw LLMError.loadFailed("The search model file couldn't be loaded. It may be damaged.")
        }
        let trained = Int(llama_model_n_ctx_train(model))
        let length = UInt32(trained > 0 ? min(contextLength, trained) : contextLength)
        var contextParams = llama_context_default_params()
        contextParams.embeddings = true
        contextParams.n_ctx = length
        // Attention looks both ways in an embedding model, so a passage has to go through in one
        // batch, and a batch is as big as the context.
        contextParams.n_batch = length
        contextParams.n_ubatch = length
        contextParams.n_seq_max = UInt32(sequences)
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw LLMError.loadFailed("There isn't enough memory for the search model.")
        }
        guard llama_pooling_type(context) != LLAMA_POOLING_TYPE_NONE, let vocab = llama_model_get_vocab(model) else {
            llama_free(context)
            llama_model_free(model)
            throw LLMError.loadFailed("This model doesn't make one vector per passage.")
        }
        self.model = model
        self.context = context
        self.vocab = vocab
        width = Int(llama_model_n_embd_out(model))
        maxTokens = Int(length)
        maxSequences = sequences
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    /// The passage's tokens, with its text never read as control tokens, cut to fit. Asking for
    /// the start token adds the end token too, when the model wants one.
    func tokens(_ text: String) throws -> [llama_token] {
        var tokens = try LlamaModel.tokenize(text, vocab: vocab, addStart: true, special: false)
        guard tokens.count > maxTokens else {
            return tokens
        }
        let end = llama_vocab_get_add_eos(vocab) ? [tokens[tokens.count - 1]] : []
        tokens.removeSubrange((maxTokens - end.count)...)
        return tokens + end
    }

    /// One pooled vector per passage, at full width. Passages go through several at a time.
    func embed(_ passages: [[llama_token]]) throws -> [[Float]] {
        var vectors: [[Float]] = []
        var start = 0
        while start < passages.count {
            try Task.checkCancellation()
            var end = start
            var total = 0
            while end < passages.count, end - start < maxSequences, total + passages[end].count <= maxTokens {
                total += passages[end].count
                end += 1
            }
            vectors += try embedBatch(Array(passages[start ..< end]))
            start = end
        }
        return vectors
    }

    private func embedBatch(_ passages: [[llama_token]]) throws -> [[Float]] {
        let total = passages.reduce(0) { $0 + $1.count }
        var batch = llama_batch_init(Int32(total), 0, 1)
        defer {
            llama_batch_free(batch)
        }
        var index = 0
        for (sequence, tokens) in passages.enumerated() {
            for (position, token) in tokens.enumerated() {
                batch.token[index] = token
                batch.pos[index] = llama_pos(position)
                batch.n_seq_id[index] = 1
                batch.seq_id[index]![0] = llama_seq_id(sequence)
                batch.logits[index] = 1
                index += 1
            }
        }
        batch.n_tokens = Int32(total)
        if let memory = llama_get_memory(context) {
            llama_memory_clear(memory, true)
        }
        let result = llama_model_has_encoder(model) && !llama_model_has_decoder(model)
            ? llama_encode(context, batch)
            : llama_decode(context, batch)
        guard result == 0 else {
            throw LLMError.generationFailed("The search model stopped with error \(result).")
        }
        return try passages.indices.map { sequence in
            guard let pointer = llama_get_embeddings_seq(context, llama_seq_id(sequence)) else {
                throw LLMError.generationFailed("The search model gave no vector.")
            }
            return Array(UnsafeBufferPointer(start: pointer, count: width))
        }
    }
}
