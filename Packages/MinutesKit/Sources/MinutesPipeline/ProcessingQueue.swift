// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesStorage
import Observation
import os

/// Runs the pipeline on one meeting at a time, oldest first. Jobs go by folder, not meeting ID,
/// because copying a meeting in Finder duplicates its ID.
@MainActor
@Observable
public final class ProcessingQueue {
    /// The meeting being worked on.
    public struct Activity: Equatable, Sendable {
        public fileprivate(set) var folder: URL
        public fileprivate(set) var progress: PipelineProgress?
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

    private static let logger = Logger(subsystem: "io.github.rosslopez.minutes", category: "processing")

    public private(set) var activity: Activity?
    public private(set) var isPaused = false
    private var waiting: [Waiting] = []

    /// A meeting's state on disk changed.
    @ObservationIgnored public var onChange: @MainActor (URL) -> Void = { _ in }
    /// A meeting's transcript is ready.
    @ObservationIgnored public var onFinish: @MainActor (URL) -> Void = { _ in }

    @ObservationIgnored private let pipeline: MeetingPipeline
    @ObservationIgnored private var job: Job?
    @ObservationIgnored private var stopReason: StopReason?
    @ObservationIgnored private let keepAwake = KeepAwake(reason: "Transcribing a meeting")

    public init(pipeline: MeetingPipeline) {
        self.pipeline = pipeline
    }

    public var isBusy: Bool {
        activity != nil || !waiting.isEmpty
    }

    public func isWaiting(_ folder: URL) -> Bool {
        waiting.contains { $0.folder == folder }
    }

    /// Adds a meeting, or resumes one that was stopped or failed. Meetings from a newer version are left alone.
    public func enqueue(_ folder: URL) {
        guard activity?.folder != folder, !isWaiting(folder) else {
            return
        }
        let meeting = MeetingFolder(url: folder)
        do {
            let metadata = try meeting.updateMetadata { metadata in
                var state = metadata.processing ?? ProcessingState()
                state.status = .queued
                state.failure = nil
                metadata.processing = state
            }
            waiting.append(Waiting(folder: folder, startedAt: metadata.startedAt))
            waiting.sort { $0.startedAt < $1.startedAt }
            onChange(folder)
            advance()
        } catch {
            Self.logger.error("Couldn't queue a meeting: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// Makes a new transcript, for a new vocabulary or engine. The old one stays until the new one is ready.
    public func transcribeAgain(_ folder: URL) {
        guard activity?.folder != folder, !isWaiting(folder) else {
            return
        }
        let meeting = MeetingFolder(url: folder)
        try? FileManager.default.removeItem(at: meeting.processingFolder)
        let hasCleaned = FileManager.default.fileExists(atPath: meeting.cleanedMicAudio.path)
        do {
            try meeting.updateMetadata { metadata in
                metadata.processing = ProcessingState(completedSteps: hasCleaned ? [.cleanMic] : [])
            }
            enqueue(folder)
        } catch {
            Self.logger.error("Couldn't start over: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// Tells the other voices apart in a finished meeting, keeping its transcription. For meetings
    /// processed before the diarizer's model was installed.
    public func identifySpeakers(_ folder: URL) {
        guard activity?.folder != folder, !isWaiting(folder) else {
            return
        }
        do {
            try MeetingPipeline.prepareToIdentifySpeakers(MeetingFolder(url: folder))
            enqueue(folder)
        } catch {
            Self.logger.error("Couldn't identify speakers: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// At launch: picks up what a quit or crash interrupted. Meetings the user stopped stay stopped.
    public func resumeInterrupted(in library: MinutesLibrary) {
        enqueue(meetings(in: library) { $0 == .queued })
    }

    /// The model arrived, so meetings waiting for it can go on.
    public func resumeWaitingForModel(in library: MinutesLibrary) {
        enqueue(meetings(in: library) { $0 == .waitingForModel })
    }

    /// Stops a meeting until the user resumes it, including across launches.
    public func stop(_ folder: URL) {
        if let job, job.location.folder.url == folder {
            stopReason = .stoppedByUser
            job.task.cancel()
            return
        }
        waiting.removeAll { $0.folder == folder }
        Self.markStopped(MeetingFolder(url: folder))
        onChange(folder)
    }

    /// Holds off while recording, so capture never competes for the machine. An interrupted step starts over.
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

    /// Moves a meeting's folder. `body` does the move and returns the new location. Goes through
    /// here even mid-processing, so the running job follows the folder.
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

    private func enqueue(_ folders: [URL]) {
        for folder in folders {
            enqueue(folder)
        }
    }

    private func meetings(in library: MinutesLibrary, where matches: (ProcessingState.Status) -> Bool) -> [URL] {
        library.meetings().compactMap { entry in
            guard let metadata = entry.metadata, metadata.state == .complete, !metadata.isNewerThanThisApp,
                  let status = metadata.processing?.status, matches(status)
            else {
                return nil
            }
            return entry.id
        }
    }

    private func advance() {
        guard !isPaused, job == nil else {
            return
        }
        guard !waiting.isEmpty else {
            keepAwake.end()
            return
        }
        let next = waiting.removeFirst()
        keepAwake.begin()
        let location = MeetingLocation(folder: MeetingFolder(url: next.folder))
        activity = Activity(folder: next.folder)
        stopReason = nil
        onChange(next.folder)
        let task = Task { [pipeline] in
            let result: PipelineResult?
            do {
                result = try await pipeline.run(at: location) { progress in
                    Task { @MainActor [weak self] in
                        self?.report(progress, from: location)
                    }
                }
            } catch {
                result = nil
            }
            finish(result, location: location)
        }
        job = Job(location: location, task: task, startedAt: next.startedAt)
    }

    private func report(_ progress: PipelineProgress, from location: MeetingLocation) {
        guard job?.location === location else {
            return
        }
        activity?.progress = progress
    }

    private func finish(_ result: PipelineResult?, location: MeetingLocation) {
        let folder = location.folder
        let startedAt = job?.startedAt ?? .distantPast
        job = nil
        activity = nil
        if result == .complete {
            onFinish(folder.url)
        } else if result == nil {
            switch stopReason {
            case .stoppedByUser:
                Self.markStopped(folder)
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

    private static func markStopped(_ folder: MeetingFolder) {
        try? folder.updateMetadata { metadata in
            metadata.processing?.status = .stopped
        }
    }
}
