// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesLlama
import MinutesLLM
import MinutesPipeline
import MinutesStorage
import Observation
import os

enum SummaryPreferences {
    static let modelKey = "ai.model"
    static let automaticKey = "ai.summarizeAutomatically"
    static let defaultTemplateKey = "ai.defaultTemplate"

    static var modelID: String {
        UserDefaults.standard.string(forKey: modelKey) ?? ModelCatalog.recommended().id
    }

    /// On until the user turns it off.
    static var summarizesAutomatically: Bool {
        UserDefaults.standard.object(forKey: automaticKey) as? Bool ?? true
    }

    static var defaultTemplate: String {
        UserDefaults.standard.string(forKey: defaultTemplateKey) ?? SummaryTemplateStore.defaultName
    }
}

/// Where a catalog model stands on this Mac.
enum ModelState: Equatable {
    case notInstalled
    /// Paused, with this much downloaded.
    case paused(DownloadProgress)
    /// `nil` until the first bytes arrive.
    case downloading(DownloadProgress?)
    case installed
}

/// Connects the summary queue, the model downloads and the built-in model to the rest of the app.
@MainActor @Observable
final class SummaryCenter {
    static let shared = SummaryCenter()

    private nonisolated static let logger = Logger(subsystem: "io.github.rosslopez.minutes", category: "summary")
    private nonisolated static let fakeModelID = "fake"

    /// The context Minutes asks for. Long meetings are read in parts that fit it.
    static let contextLength = 32768

    let queue: SummaryQueue
    private(set) var states: [String: ModelState] = [:]
    /// A download that stopped with an error, by model, said for the user.
    private(set) var downloadFailures: [String: String] = [:]
    /// Goes up when templates change on disk, so views reload them.
    private(set) var templatesRevision = 0

    var modelID = SummaryPreferences.modelID {
        didSet {
            UserDefaults.standard.set(modelID, forKey: SummaryPreferences.modelKey)
            unloadUnusedModels()
            queue.resumeWaitingForModel(in: LibraryStore.shared.library)
        }
    }

    var summarizesAutomatically = SummaryPreferences.summarizesAutomatically {
        didSet {
            UserDefaults.standard.set(summarizesAutomatically, forKey: SummaryPreferences.automaticKey)
        }
    }

    var defaultTemplate = SummaryPreferences.defaultTemplate {
        didSet {
            UserDefaults.standard.set(defaultTemplate, forKey: SummaryPreferences.defaultTemplateKey)
        }
    }

    @ObservationIgnored private var providers: [String: LlamaProvider] = [:]
    @ObservationIgnored private var downloads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let fakeProvider: any LLMProvider?
    @ObservationIgnored private var isHeld = false

    private init() {
        fakeProvider = Self.makeFakeProvider()
        // The queue asks for the model through this, once `self` exists.
        var provider: () -> (any LLMProvider)? = { nil }
        queue = SummaryQueue(
            templates: { Self.templateStore(in: LibraryStore.shared.library) },
            defaultTemplate: { SummaryPreferences.defaultTemplate },
            provider: { provider() },
        )
        provider = { [unowned self] in currentProvider() }
        queue.onChange = { _ in
            Task {
                await LibraryStore.shared.refresh()
            }
        }
        refreshModels()
    }

    private static func makeFakeProvider() -> (any LLMProvider)? {
        #if DEBUG
            if ProcessInfo.processInfo.environment["MINUTES_FAKE_LLM"] == "1" {
                return FakeLLMProvider(id: fakeModelID) { messages in
                    let asked = messages.last?.content.split(separator: "\n").first.map(String.init) ?? ""
                    return """
                    ## Overview
                    A fake summary, written to: \(asked)

                    ## Action items
                    - [ ] **Speaker 2:** Send the notes.
                    """
                }
            }
        #endif
        return nil
    }

    static func templateStore(in library: MinutesLibrary) -> SummaryTemplateStore {
        SummaryTemplateStore(folder: library.templatesFolder, defaultPrompt: SummaryPrompts.defaultInstructions)
    }

    var templateStore: SummaryTemplateStore {
        Self.templateStore(in: LibraryStore.shared.library)
    }

    func templatesChanged() {
        templatesRevision += 1
    }

    private var downloader: ModelDownloader {
        ModelDownloader(modelsFolder: LibraryStore.shared.library.modelsFolder)
    }

    /// Whether moving the library now would pull files out from under something.
    var isBusy: Bool {
        queue.isBusy || !downloads.isEmpty
    }

    // MARK: - The model

    var selectedModel: CatalogModel? {
        ModelCatalog.model(id: modelID)
    }

    /// Whether summaries can be written now.
    var hasModel: Bool {
        fakeProvider != nil || selectedModel.map { states[$0.id] == .installed } == true
    }

    private func currentProvider() -> (any LLMProvider)? {
        if let fakeProvider {
            return fakeProvider
        }
        guard let model = selectedModel, downloader.isInstalled(model) else {
            return nil
        }
        if let provider = providers[model.id] {
            return provider
        }
        let provider = LlamaProvider(
            id: "builtin:\(model.id)",
            modelURL: downloader.installedFile(for: model),
            contextLength: Self.contextLength,
        )
        providers[model.id] = provider
        return provider
    }

    /// The name a summary's `model` field stands for.
    func modelName(for id: String?) -> String? {
        guard let id else {
            return nil
        }
        let bare = id.hasPrefix("builtin:") ? String(id.dropFirst("builtin:".count)) : id
        return ModelCatalog.model(id: bare)?.name ?? bare
    }

    private func unloadUnusedModels() {
        for (id, provider) in providers where id != modelID {
            Task {
                await provider.unload()
            }
            providers[id] = nil
        }
    }

    // MARK: - Downloads

    func refreshModels() {
        let downloader = downloader
        for model in ModelCatalog.all where downloads[model.id] == nil {
            if downloader.isInstalled(model) {
                states[model.id] = .installed
            } else if let partial = downloader.partial(for: model) {
                states[model.id] = .paused(DownloadProgress(received: partial.received, total: partial.remote.size))
            } else {
                states[model.id] = .notInstalled
            }
        }
    }

    /// Asks Hugging Face for the exact file, for the confirmation before a download. Only ever
    /// called from a button the user pressed.
    func prepareDownload(of model: CatalogModel) async throws -> RemoteModelFile {
        let downloader = downloader
        let remote = try await downloader.remoteFile(for: model)
        try downloader.checkSpace(for: model, remote: remote)
        return remote
    }

    /// Starts a download the user confirmed, or resumes a paused one when `remote` is nil.
    func download(_ model: CatalogModel, remote: RemoteModelFile? = nil) {
        guard downloads[model.id] == nil else {
            return
        }
        let downloader = downloader
        downloadFailures[model.id] = nil
        states[model.id] = .downloading(nil)
        downloads[model.id] = Task {
            do {
                try await downloader.download(model, remote: remote) { progress in
                    Task { @MainActor in
                        SummaryCenter.shared.report(progress, for: model)
                    }
                }
                finishDownload(of: model)
            } catch is CancellationError {
                // Paused or cancelled: the caller set what's left.
            } catch {
                Self.logger.error("Model download failed: \(String(describing: error), privacy: .public)")
                downloadFailures[model.id] = Self.describe(error)
            }
            downloads[model.id] = nil
            refreshModels()
        }
    }

    func pauseDownload(of model: CatalogModel) {
        downloads[model.id]?.cancel()
    }

    func cancelDownload(of model: CatalogModel) {
        let downloader = downloader
        let task = downloads[model.id]
        task?.cancel()
        Task {
            await task?.value
            try? downloader.discardPartial(for: model)
            refreshModels()
        }
    }

    /// Whether a model is in use and can't be deleted.
    func isInUse(_ model: CatalogModel) -> Bool {
        model.id == modelID && queue.activity != nil
    }

    func delete(_ model: CatalogModel) async {
        guard !isInUse(model), downloads[model.id] == nil else {
            return
        }
        if let provider = providers.removeValue(forKey: model.id) {
            await provider.unload()
        }
        do {
            try downloader.delete(model)
        } catch {
            Self.logger.error("Deleting a model failed: \(String(describing: type(of: error)), privacy: .public)")
        }
        refreshModels()
    }

    private func report(_ progress: DownloadProgress, for model: CatalogModel) {
        guard downloads[model.id] != nil else {
            return
        }
        states[model.id] = .downloading(progress)
    }

    private func finishDownload(of model: CatalogModel) {
        states[model.id] = .installed
        if selectedModel.map({ states[$0.id] != .installed }) ?? true {
            modelID = model.id
        }
        queue.resumeWaitingForModel(in: LibraryStore.shared.library)
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let ModelDownloadError.notEnoughSpace(needed, available):
            "There isn't enough free space. It needs \(bytes(needed)), and \(bytes(available)) is free."
        case ModelDownloadError.checksumMismatch:
            "The downloaded file didn't match its checksum, so it was deleted. Try downloading again."
        case ModelDownloadError.fileNotFound:
            "Hugging Face no longer has this model's file."
        case let ModelDownloadError.server(status):
            "Hugging Face answered with error \(status)."
        case ModelDownloadError.incomplete:
            "The download stopped early. Resume to carry on where it left off."
        case let error as URLError:
            error.localizedDescription
        default:
            "The download stopped."
        }
    }

    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    // MARK: - With the rest of the app

    /// The library moved or another was chosen: its models and summaries are different.
    func libraryChanged() {
        providers.removeAll()
        refreshModels()
        templatesChanged()
        queue.resumeInterrupted(in: LibraryStore.shared.library)
    }

    /// A transcript is ready.
    func transcriptFinished(_ folder: URL) {
        queue.transcriptFinished(folder, automatically: summarizesAutomatically)
    }

    /// Summaries wait while recording or transcribing, so they never compete for memory.
    func updateHold() {
        let hold = RecordingController.shared.phase != .idle || TranscriptionCenter.shared.queue.isBusy
        guard hold != isHeld else {
            return
        }
        isHeld = hold
        if hold {
            queue.pause()
        } else {
            queue.unpause()
        }
    }

    /// Stops the summary under way and frees the model, which ggml needs before the process
    /// exits. The summary starts again at the next launch.
    func prepareForExit() {
        queue.pause()
        for provider in providers.values {
            provider.unloadBeforeExit()
        }
    }
}
