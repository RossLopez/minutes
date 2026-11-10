// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import llama
import os

/// llama.cpp's one-time setup.
enum LlamaRuntime {
    private static let logger = Logger(subsystem: "io.github.rosslopez.minutes", category: "llama")

    /// Set `MINUTES_LLAMA_LOG=1` to see everything llama.cpp says on standard error, for development.
    private static let isVerbose = ProcessInfo.processInfo.environment["MINUTES_LLAMA_LOG"] == "1"

    private static let started: Void = {
        // llama.cpp logs a lot by default. Keep only errors, and mark them private: its messages
        // describe the model and memory, but a log is no place to risk meeting text.
        llama_log_set({ level, text, _ in
            guard let text else {
                return
            }
            if LlamaRuntime.isVerbose {
                FileHandle.standardError.write(Data(String(cString: text).utf8))
            } else if level == GGML_LOG_LEVEL_ERROR {
                LlamaRuntime.logger.error("llama.cpp: \(String(cString: text), privacy: .private)")
            }
        }, nil)
        // After the log is set, or Metal's start-up messages get through.
        llama_backend_init()
    }()

    static func start() {
        started
    }
}
