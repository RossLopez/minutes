// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesLLM
import MinutesStorage
import Observation
import os
import Synchronization

/// Writes summaries one meeting at a time, oldest first, apart from transcription: a summary that
/// fails or stops never touches the transcript. Its state lives in each meeting's `summary` block,
/// so work a quit interrupted picks up at the next launch.
@MainActor
@Observable
public final class SummaryQueue {
    /// The meeting whose summary is being written.
    public struct Activity: Equatable, Sendable {
        public fileprivate(set) var folder: URL
        public fileprivate(set) var stage: Summarizer.Stage?
        /// What's been written so far, while it streams.
        public fileprivate(set) var text = ""
    }

    private struct Waiting {
        var folder: URL
        let startedAt: Date
    }

    private enum StopReason {
        case paused
        case stoppedByUser
        case removed
    }

    private struct Job {
        let location: MeetingLocation
        let task: Task<Void, Never>
        let startedAt: Date
    }

    public nonisolated static let tooLittleSaid = "Too little was said to summarize."
    public nonisolated static let modelNotInstalled = "The model isn't installed."

    private static let logger = Logger(subsystem: "io.github.rosslopez.minutes", category: "summary")

    public private(set) var activity: Activity?
    public private(set) var isPaused = false
    private var waiting: [Waiting] = []

    /// A meeting's summary changed on disk.
    @ObservationIgnored public var onChange: @MainActor (URL) -> Void = { _ in }

    /// The model to write with, or nil when the chosen one isn't installed.
    @ObservationIgnored private let provider: @MainActor () -> (any LLMProvider)?
    /// Asked as each summary starts, since the library can move.
    @ObservationIgnored private let templates: @MainActor () -> SummaryTemplateStore
    /// The template new meetings use, by name.
    @ObservationIgnored private let defaultTemplate: @MainActor () -> String
    @ObservationIgnored private var job: Job?
    @ObservationIgnored private var stopReason: StopReason?
    @ObservationIgnored private let keepAwake = KeepAwake(reason: "Summarizing a meeting")

    public init(
        templates: @escaping @MainActor () -> SummaryTemplateStore,
        defaultTemplate: @escaping @MainActor () -> String = { SummaryTemplateStore.defaultName },
        provider: @escaping @MainActor () -> (any LLMProvider)?,
    ) {
        self.templates = templates
        self.defaultTemplate = defaultTemplate
        self.provider = provider
    }

    public var isBusy: Bool {
        activity != nil || !waiting.isEmpty
    }

    public func isWaiting(_ folder: URL) -> Bool {
        waiting.contains { $0.folder == folder }
    }

    /// A transcript is ready. Summarizes it when asked to and a model is installed, unless it
    /// already has a summary: a new transcript leaves the old summary for the user to regenerate.
    public func transcriptFinished(_ folder: URL, automatically: Bool) {
        guard automatically, provider() != nil,
              (try? MeetingFolder(url: folder).loadMetadata())?.summary == nil
        else {
            return
        }
        enqueue(folder)
    }

    /// Writes a summary, or a new one. `template` changes the meeting's template, by name.
    public func enqueue(_ folder: URL, template: String? = nil) {
        guard activity?.folder != folder, !isWaiting(folder) else {
            return
        }
        do {
            let metadata = try MeetingFolder(url: folder).updateSummary { summary in
                var updated = summary ?? MeetingMetadata.Summary(status: .queued, template: defaultTemplate())
                updated.status = .queued
                updated.failure = nil
                if let template {
                    updated.requestedTemplate = template == updated.template ? nil : template
                }
                summary = updated
            }
            guard !metadata.isNewerThanThisApp else {
                return
            }
            waiting.append(Waiting(folder: folder, startedAt: metadata.startedAt))
            waiting.sort { $0.startedAt < $1.startedAt }
            onChange(folder)
            advance()
        } catch {
            Self.logger.error("Couldn't queue a summary: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// At launch: picks up what a quit or crash interrupted. Stopped summaries stay stopped.
    public func resumeInterrupted(in library: MinutesLibrary) {
        for folder in meetings(in: library, where: { $0 == .queued }) {
            enqueue(folder)
        }
    }

    /// A model was installed or chosen, so summaries waiting for one can go on.
    public func resumeWaitingForModel(in library: MinutesLibrary) {
        for folder in meetings(in: library, where: { $0 == .waitingForModel }) {
            enqueue(folder)
        }
    }

    /// Stops a summary until the user asks again, including across launches.
    public func stop(_ folder: URL) {
        if let job, job.location.folder.url == folder {
            stopReason = .stoppedByUser
            job.task.cancel()
            return
        }
        waiting.removeAll { $0.folder == folder }
        Self.mark(MeetingFolder(url: folder), .stopped)
        onChange(folder)
    }

    /// Holds off while recording or transcribing, so they never compete for memory. A summary
    /// under way starts again later.
    public func pause() {
        isPaused = true
        if let job {
            stopReason = .paused
            job.task.cancel()
        }
    }

    public func unpause() {
        isPaused = false
        advance()
    }

    /// Lets go of a meeting that's about to be moved to the Trash, and waits for its work to stop.
    public func remove(_ folder: URL) async {
        waiting.removeAll { $0.folder == folder }
        if let job, job.location.folder.url == folder {
            stopReason = .removed
            job.task.cancel()
            await job.task.value
        }
    }

    /// Stops everything before the app quits. Queued summaries start again at the next launch.
    public func stopForQuit() async {
        isPaused = true
        if let job {
            stopReason = .paused
            job.task.cancel()
            await job.task.value
        }
    }

    /// Moves a meeting's folder. `body` does the move and returns the new location. Goes through
    /// here even mid-summary, so the running job follows the folder.
    public func move(
        _ folder: URL,
        using body: (MeetingFolder) throws -> MeetingFolder,
    ) throws -> MeetingFolder {
        if let job, job.location.folder.url == folder {
            let moved = try job.location.move(body)
            activity?.folder = moved.url
            return moved
        }
        let moved = try body(MeetingFolder(url: folder))
        if let index = waiting.firstIndex(where: { $0.folder == folder }) {
            waiting[index].folder = moved.url
        }
        return moved
    }

    // MARK: - Running

    private func advance() {
        guard !isPaused, job == nil else {
            return
        }
        guard !waiting.isEmpty else {
            keepAwake.end()
            return
        }
        let next = waiting.removeFirst()
        guard let provider = provider() else {
            Self.mark(MeetingFolder(url: next.folder), .waitingForModel)
            onChange(next.folder)
            advance()
            return
        }
        keepAwake.begin()
        let location = MeetingLocation(folder: MeetingFolder(url: next.folder))
        activity = Activity(folder: next.folder)
        stopReason = nil
        onChange(next.folder)
        let (stage, emit) = callbacks(for: location)
        let templates = templates()
        let task = Task { [weak self] in
            let outcome: Outcome
            do {
                try await SummaryRun.summarize(
                    at: location,
                    provider: provider,
                    templates: templates,
                    stage: stage,
                    emit: emit,
                )
                outcome = .complete
            } catch is CancellationError {
                outcome = .cancelled
            } catch Summarizer.Failure.tooLittleSaid {
                outcome = .failed(Self.tooLittleSaid)
            } catch {
                Self.logger.error("Summary failed: \(String(describing: error), privacy: .private)")
                outcome = .failed(SummaryRun.describe(error))
            }
            self?.finish(outcome, location: location)
        }
        job = Job(location: location, task: task, startedAt: next.startedAt)
    }

    private enum Outcome {
        case complete
        case cancelled
        case failed(String)
    }

    /// Passes the stage and the text so far to the main actor, as the summary is written.
    private func callbacks(
        for location: MeetingLocation,
    ) -> (stage: @Sendable (Summarizer.Stage) -> Void, emit: @Sendable (String) -> Void) {
        let written = Mutex("")
        let stage: @Sendable (Summarizer.Stage) -> Void = { [weak self] stage in
            Task { @MainActor in
                self?.report(stage: stage, from: location)
            }
        }
        let emit: @Sendable (String) -> Void = { [weak self] piece in
            let text = written.withLock { text in
                text += piece
                return text
            }
            Task { @MainActor in
                self?.report(text: text, from: location)
            }
        }
        return (stage, emit)
    }

    private func finish(_ outcome: Outcome, location: MeetingLocation) {
        let folder = location.folder
        let startedAt = job?.startedAt ?? .distantPast
        job = nil
        activity = nil
        switch outcome {
        case .complete:
            break
        case let .failed(message):
            Self.mark(folder, .failed, failure: message)
        case .cancelled:
            switch stopReason {
            case .stoppedByUser:
                Self.mark(folder, .stopped)
            case .paused, .none:
                // Goes back to the front. Its state on disk still says it's queued.
                waiting.insert(Waiting(folder: folder.url, startedAt: startedAt), at: 0)
            case .removed:
                break
            }
        }
        stopReason = nil
        onChange(folder.url)
        advance()
        if isPaused {
            keepAwake.end()
        }
    }
}

private extension SummaryQueue {
    func meetings(
        in library: MinutesLibrary,
        where matches: (MeetingMetadata.Summary.Status) -> Bool,
    ) -> [URL] {
        library.meetings().compactMap { entry in
            guard let metadata = entry.metadata, !metadata.isNewerThanThisApp,
                  let status = metadata.summary?.status, matches(status)
            else {
                return nil
            }
            return entry.id
        }
    }

    func report(stage: Summarizer.Stage, from location: MeetingLocation) {
        guard job?.location === location else {
            return
        }
        activity?.stage = stage
    }

    func report(text: String, from location: MeetingLocation) {
        guard job?.location === location, text.count > (activity?.text.count ?? 0) else {
            return
        }
        activity?.text = text
    }

    static func mark(
        _ folder: MeetingFolder,
        _ status: MeetingMetadata.Summary.Status,
        failure: String? = nil,
    ) {
        _ = try? folder.updateSummary { summary in
            summary?.status = status
            summary?.failure = status == .waitingForModel ? modelNotInstalled : failure
        }
    }
}
