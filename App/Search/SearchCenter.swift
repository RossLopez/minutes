// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesLlama
import MinutesLLM
import MinutesSearch
import MinutesStorage
import Observation
import os

/// A place in a meeting to show, after a search result or a citation is chosen.
struct MeetingReveal: Equatable {
    let meetingID: UUID
    let kind: SearchChunk.Kind
    let seconds: Double?
    /// New for every reveal, so asking twice for the same place still scrolls there.
    let token: Int
}

/// Keeps `.minutes/index.sqlite` up to date with the library, and searches it for the sidebar.
///
/// Indexing and embedding wait while a recording or transcription is under way, so they never
/// compete with either. The search model loads only to embed, and unloads when idle.
@MainActor @Observable
final class SearchCenter {
    static let shared = SearchCenter()

    nonisolated static let logger = Logger(subsystem: "io.github.rosslopez.minutes", category: "search")
    static let searchModel = ModelCatalog.embeddingGemma2

    private(set) var status: SearchIndexStatus?
    private(set) var isUpdating = false
    /// The sidebar's full-text matches, by meeting ID.
    private(set) var matches: [UUID: MeetingMatch] = [:]
    /// The search field changed and the index hasn't answered yet.
    private(set) var isSearching = false
    /// Where the open meeting should show next. Taken by the meeting's view.
    var reveal: MeetingReveal?

    @ObservationIgnored private var index: SearchIndex?
    @ObservationIgnored private var indexRoot: URL?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var needsAnotherUpdate = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var builtInEmbedder: LlamaEmbedder?
    /// Stands in for the search model in UI tests.
    @ObservationIgnored private let fakeEmbedder: FakeEmbeddingProvider?
    @ObservationIgnored private var revealCount = 0

    private init() {
        #if DEBUG
            fakeEmbedder = ProcessInfo.processInfo.environment["MINUTES_FAKE_LLM"] == "1"
                ? FakeEmbeddingProvider() : nil
        #else
            fakeEmbedder = nil
        #endif
    }

    // MARK: - The index

    /// The current library's index, opened again when the library moves.
    var currentIndex: SearchIndex? {
        let library = LibraryStore.shared.library
        guard LibraryStore.shared.missingLocation == nil else {
            return nil
        }
        if index == nil || indexRoot != library.root {
            do {
                index = try SearchIndex(library: library)
                indexRoot = library.root
                matches = [:]
            } catch {
                Self.logger.error("Opening the search index failed: \(String(describing: error), privacy: .public)")
                index = nil
            }
        }
        return index
    }

    var hasSearchModel: Bool {
        fakeEmbedder != nil || SummaryCenter.shared.states[Self.searchModel.id] == .installed
    }

    /// The search model, when it's downloaded.
    var embedder: any EmbeddingProvider? {
        if let fakeEmbedder {
            return fakeEmbedder
        }
        guard SummaryCenter.shared.states[Self.searchModel.id] == .installed else {
            return nil
        }
        let downloader = ModelDownloader(modelsFolder: LibraryStore.shared.library.modelsFolder)
        let url = downloader.installedFile(for: Self.searchModel)
        if builtInEmbedder == nil || builtInEmbedder?.modelURL != url {
            builtInEmbedder = LlamaEmbedder(id: "builtin:\(Self.searchModel.id)", modelURL: url)
        }
        return builtInEmbedder
    }

    /// Something in the library may have changed. Updates soon, once, however often it's asked.
    func scheduleUpdate(after delay: Duration = .milliseconds(400)) {
        guard updateTask == nil else {
            needsAnotherUpdate = true
            return
        }
        updateTask = Task {
            try? await Task.sleep(for: delay)
            repeat {
                needsAnotherUpdate = false
                await runUpdate()
            } while needsAnotherUpdate && !Task.isCancelled
            updateTask = nil
        }
    }

    /// Empties the index and builds it again from the files.
    func rebuild() async {
        updateTask?.cancel()
        await updateTask?.value
        updateTask = nil
        guard let index = currentIndex else {
            return
        }
        do {
            try await index.removeAll()
        } catch {
            Self.logger.error("Emptying the search index failed: \(String(describing: error), privacy: .public)")
        }
        status = nil
        scheduleUpdate(after: .zero)
    }

    private func runUpdate() async {
        guard let index = currentIndex else {
            return
        }
        isUpdating = true
        defer {
            isUpdating = false
        }
        do {
            try await waitForQuiet()
            let start = ContinuousClock.now
            let update = try await index.update(library: LibraryStore.shared.library)
            if update.changedAnything {
                let took = start.duration(to: .now)
                Self.logger
                    .info("Indexed \(update.indexed) meetings, removed \(update.removed), in \(took, privacy: .public)")
                rerunSearch()
            }
            status = try await index.status(model: embedder?.id)
            if let embedder {
                try await embedMissing(in: index, using: embedder)
            }
            status = try await index.status(model: embedder?.id)
        } catch is CancellationError {
            // Rebuilding, or quitting.
        } catch {
            Self.logger.error("Updating the search index failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// A batch at a time, waiting whenever something more important starts.
    private func embedMissing(in index: SearchIndex, using embedder: any EmbeddingProvider) async throws {
        let start = ContinuousClock.now
        var total = 0
        while true {
            try await waitForQuiet()
            let count = try await index.embedMissing(using: embedder, maxBatches: 1)
            guard count > 0 else {
                break
            }
            total += count
            status = try await index.status(model: embedder.id)
        }
        if total > 0 {
            Self.logger.info("Embedded \(total) passages in \(start.duration(to: .now), privacy: .public)")
        }
    }

    private func waitForQuiet() async throws {
        while RecordingController.shared.phase != .idle || TranscriptionCenter.shared.queue.isBusy {
            try await Task.sleep(for: .seconds(2))
        }
    }

    // MARK: - The sidebar's search

    /// Finds meetings by their text as the search field changes.
    func search(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isSearching = false
            if !matches.isEmpty {
                matches = [:]
                LibraryStore.shared.searchResultsChanged()
            }
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else {
                return
            }
            guard let index = currentIndex else {
                isSearching = false
                return
            }
            let found = await (try? index.matchingMeetings(trimmed)) ?? []
            guard !Task.isCancelled else {
                return
            }
            matches = Dictionary(found.map { ($0.meetingID, $0) }, uniquingKeysWith: { first, _ in first })
            isSearching = false
            LibraryStore.shared.searchResultsChanged()
        }
    }

    func match(for entry: MeetingEntry) -> MeetingMatch? {
        entry.metadata.flatMap { matches[$0.id] }
    }

    private func rerunSearch() {
        search(LibraryStore.shared.searchText)
    }

    // MARK: - Showing a place

    func requestReveal(of meetingID: UUID, kind: SearchChunk.Kind, seconds: Double?) {
        revealCount += 1
        reveal = MeetingReveal(meetingID: meetingID, kind: kind, seconds: seconds, token: revealCount)
    }

    // MARK: - The search model

    /// The search model was downloaded: its vectors can be made now.
    func searchModelInstalled() {
        scheduleUpdate(after: .zero)
    }

    /// Frees the search model before its file is deleted.
    func unloadSearchModel() async {
        await builtInEmbedder?.unload()
        builtInEmbedder = nil
    }

    /// ggml needs the model freed before the process exits.
    func prepareForExit() {
        updateTask?.cancel()
        builtInEmbedder?.unloadBeforeExit()
    }
}
