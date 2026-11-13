// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesLlama
import MinutesLLM

/// The built-in models every feature shares, with at most one in memory at a time, so a Mac never
/// holds two models at once.
@MainActor
final class BuiltInModels {
    static let shared = BuiltInModels()

    /// The context Minutes asks for. Long meetings are read in parts that fit it.
    static let contextLength = 32768

    private var providers: [String: LlamaProvider] = [:]

    private init() {}

    private var downloader: ModelDownloader {
        ModelDownloader(modelsFolder: LibraryStore.shared.library.modelsFolder)
    }

    /// The catalog model's provider, or nil when it isn't downloaded. Any other built-in model is
    /// let go first. Features take turns with the model, so nothing is using the one let go.
    func provider(for id: String) -> LlamaProvider? {
        guard let model = ModelCatalog.model(id: id), downloader.isInstalled(model) else {
            return nil
        }
        if let provider = providers[model.id] {
            return provider
        }
        unload(except: [])
        let provider = LlamaProvider(
            id: "builtin:\(model.id)",
            modelURL: downloader.installedFile(for: model),
            contextLength: Self.contextLength,
        )
        providers[model.id] = provider
        return provider
    }

    /// Frees every model but those features use now.
    func unload(except inUse: Set<String>) {
        for (id, provider) in providers where !inUse.contains(id) {
            Task {
                await provider.unload()
            }
            providers[id] = nil
        }
    }

    /// Frees a model before its file is deleted.
    func unload(_ id: String) async {
        if let provider = providers.removeValue(forKey: id) {
            await provider.unload()
        }
    }

    /// The library moved or another was chosen, so its models are different files.
    func forgetAll() {
        unload(except: [])
    }

    /// ggml needs every model freed before the process exits. Cancel their work first.
    func prepareForExit() {
        for provider in providers.values {
            provider.unloadBeforeExit()
        }
    }
}
