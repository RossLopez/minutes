// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesAudio
import MinutesDiarization
import MinutesStorage
import MinutesTranscription
import os

public struct PipelineProgress: Equatable, Sendable {
    public let step: ProcessingStep
    /// From 0 to 1, if the step can tell.
    public let fraction: Double?

    public init(step: ProcessingStep, fraction: Double?) {
        self.step = step
        self.fraction = fraction
    }
}

public enum PipelineResult: Equatable, Sendable {
    case complete
    /// The model isn't installed. Downloading it is the user's call, so processing waits.
    case waitingForModel(engine: String)
    /// Written for the user, with no transcript content. The audio is untouched.
    case failed(String)
}

/// Stop → clean mic → transcribe mic → transcribe system → diarize system → merge → `transcript.json`
/// and `transcript.md`.
///
/// After each step, `meeting.json` records that it finished, so a quit or crash resumes from
/// there. Resuming restarts an interrupted step rather than picking up mid-way. Work in progress
/// stays in `.processing/`, and finished files appear in one atomic step.
public struct MeetingPipeline: Sendable {
    public typealias Cleaner = @Sendable (
        _ mic: URL,
        _ system: URL?,
        _ output: URL,
        _ format: RecordingAudioFormat,
        _ progress: @escaping @Sendable (Double) -> Void,
    ) async throws -> MicCleaner.Outcome

    static let logger = Logger(subsystem: "io.github.rosslopez.minutes", category: "pipeline")

    private let cleanMic: Cleaner
    private let engineWithID: @Sendable (String) -> (any TranscriptionEngine)?
    private let preferredEngineID: @Sendable () -> String
    let vocabulary: @Sendable () -> [VocabularyEntry]
    let diarizer: @Sendable () -> (any SpeakerDiarizer)?
    let speakerMemory: @Sendable () -> SpeakerProfileStore?
    let yourName: @Sendable () -> String?

    /// - Parameters:
    ///   - diarizer: Tells the other voices apart. With none, or no model, they stay as Others.
    ///   - speakerMemory: Saved voices to name people by, or `nil` with speaker memory off.
    ///   - yourName: The name for Me.
    public init(
        cleanMic: @escaping Cleaner = { mic, system, output, format, progress in
            try await MicCleaner.clean(mic: mic, system: system, output: output, format: format, progress: progress)
        },
        engineWithID: @escaping @Sendable (String) -> (any TranscriptionEngine)?,
        preferredEngineID: @escaping @Sendable () -> String,
        vocabulary: @escaping @Sendable () -> [VocabularyEntry],
        diarizer: @escaping @Sendable () -> (any SpeakerDiarizer)? = { nil },
        speakerMemory: @escaping @Sendable () -> SpeakerProfileStore? = { nil },
        yourName: @escaping @Sendable () -> String? = { nil },
    ) {
        self.cleanMic = cleanMic
        self.engineWithID = engineWithID
        self.preferredEngineID = preferredEngineID
        self.vocabulary = vocabulary
        self.diarizer = diarizer
        self.speakerMemory = speakerMemory
        self.yourName = yourName
    }

    /// Runs whatever's left to do. Throws only `CancellationError`, leaving the meeting ready to resume.
    public func run(
        at location: MeetingLocation,
        progress: @escaping @Sendable (PipelineProgress) -> Void = { _ in },
    ) async throws -> PipelineResult {
        do {
            return try await runSteps(at: location, progress: progress)
        } catch {
            // Engines report being cancelled in their own ways.
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            let message = Self.describe(error)
            Self.logger.error("Processing failed: \(String(describing: type(of: error)), privacy: .public)")
            record(.failed, failure: message, at: location)
            return .failed(message)
        }
    }

    private func runSteps(
        at location: MeetingLocation,
        progress: @escaping @Sendable (PipelineProgress) -> Void,
    ) async throws -> PipelineResult {
        let state = try begin(at: location)
        let engineID = state.engine ?? preferredEngineID()
        guard let engine = engineWithID(engineID) else {
            throw PipelineFailure.engineMissing
        }
        for step in ProcessingStep.allCases where !isFinished(step, state: state, folder: location.folder) {
            try Task.checkCancellation()
            if step == .transcribeMic || step == .transcribeSystem {
                switch await engine.modelStatus() {
                case .installed:
                    break
                case .notInstalled:
                    record(.waitingForModel, failure: nil, at: location)
                    return .waitingForModel(engine: engineID)
                case let .unavailable(reason):
                    throw PipelineFailure.engineUnavailable(reason)
                }
            }
            progress(PipelineProgress(step: step, fraction: nil))
            let started = ContinuousClock.now
            try await performSurvivingMoves(at: location) { folder in
                try await perform(step, StepContext(folder: folder, location: location, engine: engine) { fraction in
                    progress(PipelineProgress(step: step, fraction: fraction))
                })
            }
            Self.logger.info("\(step.rawValue, privacy: .public) took \(started.duration(to: .now), privacy: .public)")
            try location.access { folder in
                try folder.updateMetadata { metadata in
                    metadata.processing?.completedSteps.append(step)
                }
            }
        }
        try finish(at: location)
        return .complete
    }

    /// Marks the run as under way, and picks its engine unless a track already used one.
    private func begin(at location: MeetingLocation) throws -> ProcessingState {
        try location.access { folder in
            let metadata = try folder.updateMetadata { metadata in
                var state = metadata.processing ?? ProcessingState()
                state.status = .queued
                state.failure = nil
                let hasTranscribed = state.completedSteps.contains(.transcribeMic)
                    || state.completedSteps.contains(.transcribeSystem)
                if state.engine == nil || !hasTranscribed {
                    state.engine = preferredEngineID()
                }
                metadata.processing = state
            }
            try FileManager.default.createDirectory(at: folder.processingFolder, withIntermediateDirectories: true)
            return metadata.processing ?? ProcessingState()
        }
    }

    /// A step only counts as done if what it made is still there.
    private func isFinished(_ step: ProcessingStep, state: ProcessingState, folder: MeetingFolder) -> Bool {
        guard state.completedSteps.contains(step) else {
            return false
        }
        let manager = FileManager.default
        switch step {
        case .cleanMic:
            return manager.fileExists(atPath: folder.cleanedMicAudio.path)
                || !manager.fileExists(atPath: folder.micAudio.path)
        case .transcribeMic:
            return manager.fileExists(atPath: Self.wordsFile(.transcribeMic, in: folder).path)
        case .transcribeSystem:
            return manager.fileExists(atPath: Self.wordsFile(.transcribeSystem, in: folder).path)
        case .diarizeSystem:
            return manager.fileExists(atPath: Self.wordsFile(.diarizeSystem, in: folder).path)
        case .merge:
            return manager.fileExists(atPath: folder.transcriptJSON.path)
        }
    }

    /// If the folder moves during a step, the step's files can vanish from under it, so it starts over at the new
    /// place.
    private func performSurvivingMoves(
        at location: MeetingLocation,
        _ body: (MeetingFolder) async throws -> Void,
    ) async throws {
        while true {
            let folder = location.folder
            do {
                try await body(folder)
                return
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), location.folder != folder else {
                    throw error
                }
            }
        }
    }
}

// MARK: - Steps

extension MeetingPipeline {
    /// What a step works with. `folder` is where it was when the step began.
    struct StepContext {
        let folder: MeetingFolder
        let location: MeetingLocation
        let engine: any TranscriptionEngine
        let progress: @Sendable (Double) -> Void
    }

    private func perform(_ step: ProcessingStep, _ context: StepContext) async throws {
        switch step {
        case .cleanMic:
            try await performCleaning(context)
        case .transcribeMic:
            try await performTranscription(step, audio: context.folder.playbackMicAudio, context)
        case .transcribeSystem:
            try await performTranscription(step, audio: context.folder.systemAudio, context)
        case .diarizeSystem:
            try await performDiarization(context)
        case .merge:
            try performMerge(location: context.location, engine: context.engine)
        }
    }

    private func performCleaning(_ context: StepContext) async throws {
        let manager = FileManager.default
        let folder = context.folder
        guard manager.fileExists(atPath: folder.micAudio.path) else {
            return
        }
        let metadata = try folder.loadMetadata()
        let name = "mic.m4a"
        _ = try await cleanMic(
            folder.micAudio,
            manager.fileExists(atPath: folder.systemAudio.path) ? folder.systemAudio : nil,
            folder.processingFolder.appendingPathComponent(name),
            RecordingAudioFormat(rawValue: metadata.audioFormat) ?? .aac,
            context.progress,
        )
        try context.location.access { current in
            try Self.moveIntoPlace(current.processingFolder.appendingPathComponent(name), current.cleanedMicAudio)
        }
    }

    private func performTranscription(_ step: ProcessingStep, audio: URL, _ context: StepContext) async throws {
        let manager = FileManager.default
        var words: [TranscriptWord] = []
        let workName = "work-\(step.rawValue)"
        if manager.fileExists(atPath: audio.path) {
            let work = context.folder.processingFolder.appendingPathComponent(workName, isDirectory: true)
            try? manager.removeItem(at: work)
            try manager.createDirectory(at: work, withIntermediateDirectories: true)
            words = try await context.engine.transcribe(
                audio: audio,
                vocabulary: vocabulary(),
                workFolder: work,
                progress: context.progress,
            )
            // An engine that stopped early mustn't pass for a finished track.
            try Task.checkCancellation()
            if step == .transcribeMic {
                words = try await removingLeftoverEcho(from: words, context)
            }
        }
        let data = try JSONEncoder().encode(words)
        try context.location.access { current in
            try data.write(to: Self.wordsFile(step, in: current), options: .atomic)
            try? manager.removeItem(at: current.processingFolder.appendingPathComponent(workName, isDirectory: true))
        }
    }

    /// With no echo found, `mic.m4a` is an exact copy of the original, so every quiet word is a real one.
    /// If the audio can't be read, the words all stay: a stray line is better than a lost one.
    private func removingLeftoverEcho(
        from words: [TranscriptWord],
        _ context: StepContext,
    ) async throws -> [TranscriptWord] {
        let manager = FileManager.default
        let folder = context.folder
        guard !words.isEmpty,
              manager.fileExists(atPath: folder.cleanedMicAudio.path),
              manager.fileExists(atPath: folder.systemAudio.path),
              !manager.contentsEqual(atPath: folder.micAudio.path, andPath: folder.cleanedMicAudio.path)
        else {
            return words
        }
        do {
            let mic = try await LevelTimeline.read(folder.cleanedMicAudio)
            let system = try await LevelTimeline.read(folder.systemAudio)
            let kept = LeftoverEchoFilter.keeping(words, mic: mic, system: system)
            Self.logger.info("Leftover echo: dropped \(words.count - kept.count, privacy: .public) words")
            return kept
        } catch {
            // A folder that moved restarts the step at its new place.
            if error is CancellationError || context.location.folder != folder {
                throw error
            }
            Self.logger.error("Couldn't measure levels: \(String(describing: type(of: error)), privacy: .public)")
            return words
        }
    }

    private func finish(at location: MeetingLocation) throws {
        try location.access { folder in
            try folder.updateMetadata { metadata in
                metadata.processing?.status = .complete
                metadata.processing?.failure = nil
            }
            try? FileManager.default.removeItem(at: folder.processingFolder)
        }
    }

    private func record(_ status: ProcessingState.Status, failure: String?, at location: MeetingLocation) {
        try? location.access { folder in
            try folder.updateMetadata { metadata in
                metadata.processing?.status = status
                metadata.processing?.failure = failure
            }
        }
    }

    static func wordsFile(_ step: ProcessingStep, in folder: MeetingFolder) -> URL {
        folder.processingFolder.appendingPathComponent("\(step.rawValue).json")
    }

    static func loadWords(_ step: ProcessingStep, in folder: MeetingFolder) throws -> [TranscriptWord] {
        try JSONDecoder().decode([TranscriptWord].self, from: Data(contentsOf: wordsFile(step, in: folder)))
    }

    /// `rename` replaces the destination in one step, so a player or reader sees the old file or the new one.
    private static func moveIntoPlace(_ source: URL, _ destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func describe(_ error: any Error) -> String {
        if let failure = error as? PipelineFailure {
            return failure.message
        }
        if case MeetingFolder.FolderError.newerFileFormat = error {
            return "This meeting was saved by a newer version of Minutes."
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError {
            return "Your disk is full. Free up some space and try again."
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) {
            return "Your disk is full. Free up some space and try again."
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileNoSuchFileError {
            return "A file Minutes needed couldn't be found. If this meeting is on a drive, connect it and try again."
        }
        return "Minutes couldn't finish transcribing this meeting. Your audio is safe."
    }
}

private enum PipelineFailure: Error {
    case engineMissing
    case engineUnavailable(String)

    var message: String {
        switch self {
        case .engineMissing: "The transcription engine for this meeting isn't available. Choose another in Settings."
        case let .engineUnavailable(reason): reason
        }
    }
}
