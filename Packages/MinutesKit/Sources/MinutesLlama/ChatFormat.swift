// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesLLM

/// A run of prompt text, and whether its control tokens, like `<|turn>`, are read as such.
struct PromptPiece: Equatable {
    var text: String
    /// True for the format's own markers. Message text is never special, so a transcript that
    /// happens to contain `<turn|>` can't end a turn early.
    var isSpecial: Bool
}

/// How a model's conversation is written out.
enum ChatFormat: Equatable {
    /// Gemma 4's `<|turn>role … <turn|>` format. llama.cpp's built-in templates don't know it
    /// yet, and the GGUF's template needs a Jinja engine, so Minutes writes it.
    /// `emptyThought` is set when the template, with thinking off, starts the answer with an
    /// empty thought block, as the 12B's does. Without it that model writes the block itself.
    case gemma4(emptyThought: Bool)
    /// One of llama.cpp's built-in formats, picked from the GGUF's template.
    case builtIn(template: String)

    /// The empty thought block, as it's written in the template's source.
    private static let emptyThoughtSource = #"<|channel>thought\n<channel|>"#

    init(template: String) {
        guard template.contains("<|turn>"), template.contains("<turn|>") else {
            self = .builtIn(template: template)
            return
        }
        self = .gemma4(emptyThought: template.contains(Self.emptyThoughtSource))
    }

    /// The Gemma 4 template's output for text messages, with thinking off and no tools: an
    /// optional system turn first, then each turn, then the start of the model's answer.
    static func gemma4(_ messages: [LLMMessage], emptyThought: Bool) -> [PromptPiece] {
        var pieces = [PromptPiece(text: "<bos>", isSpecial: true)]
        for message in messages {
            let role = message.role == .assistant ? "model" : message.role.rawValue
            pieces.append(PromptPiece(text: "<|turn>\(role)\n", isSpecial: true))
            pieces.append(PromptPiece(
                text: message.content.trimmingCharacters(in: .whitespacesAndNewlines),
                isSpecial: false,
            ))
            pieces.append(PromptPiece(text: "<turn|>\n", isSpecial: true))
        }
        pieces.append(PromptPiece(text: "<|turn>model\n", isSpecial: true))
        if emptyThought {
            pieces.append(PromptPiece(text: "<|channel>thought\n<channel|>", isSpecial: true))
        }
        return pieces
    }
}
