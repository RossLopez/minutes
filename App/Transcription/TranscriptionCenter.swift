// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesDiarization
import MinutesFluidAudio
import MinutesPipeline
import MinutesStorage
import MinutesTranscription
import Observation
import os
import Synchronization
import UserNotifications

/// The library as it is right now, for work that runs off the main actor. The library can move.
final class CurrentLibrary: Sendable {
    private let library: Mutex<MinutesLibrary>

    init(_ library: MinutesLibrary) {
        self.library = Mutex(library)
    }

    var value: MinutesLibrary {
        library.withLock { $0 }
    }

    func set(_ newLibrary: MinutesLibrary) {
        library.withLock { $0 = newLibrary }
    }
}

enum TranscriptionPreferences {
    static let engineKey = "transcription.engine"

    static var engineID: String {
        UserDefaults.standard.string(forKey: engineKey) ?? AppleSpeechEngine.engineID
    }
}

/// What a meeting's transcript is waiting on, if anything.
enum TranscriptStatus: Equatable {
    case working(PipelineProgress?)
    case waiting
    case stopped
    case failed(String)
    case needsModel(engineID: String)
    case notStarted
    case newerVersion
    case idle
}

/// Connects the processing queue and the transcription engines to the rest of the app.
@MainActor @Observable
final class TranscriptionCenter {
    static let shared = TranscriptionCenter()

    private nonisolated static let logger = Logger(subsystem: "io.github.rosslopez.minutes", category: "transcription")
    private nonisolated static let fakeEngineID = "fake"

    let queue: ProcessingQueue
    let engines: [any TranscriptionEngine]
    let diarizer: any SpeakerDiarizer
    private(set) var preferredEngineID = TranscriptionPreferences.engineID
    private(set) var modelStatuses: [String: TranscriptionModelStatus] = [:]
    /// The engine whose model is downloading.
    private(set) var installingEngineID: String?
    private(set) var installProgress = 0.0
    private(set) var installFailed = false

    @ObservationIgnored private var installTask: Task<Void, Never>?

    private init() {
        let current = LibraryStore.shared.currentLibrary
        let engines = Self.makeEngines(current: current)
        let diarizer = Self.makeDiarizer(current: current)
        self.engines = engines
        self.diarizer = diarizer
        queue = ProcessingQueue(pipeline: MeetingPipeline(
            engineWithID: { id in
                engines.first { $0.id == id } ?? engines.first { $0.id == Self.fakeEngineID }
            },
            preferredEngineID: {
                engines.contains { $0.id == Self.fakeEngineID } ? Self.fakeEngineID : TranscriptionPreferences.engineID
            },
            vocabulary: {
                do {
                    return try current.value.loadVocabulary()
                } catch {
                    Self.logger.error("Vocabulary unreadable: \(String(describing: type(of: error)), privacy: .public)")
                    return []
                }
            },
            diarizer: { diarizer },
            speakerMemory: {
                SpeakerPreferences.remembersVoices ? current.value.speakerProfiles : nil
            },
            yourName: {
                SpeakerPreferences.yourName
            },
        ))
        queue.onChange = { _ in
            Task {
                await LibraryStore.shared.refresh()
            }
        }
        queue.onFinish = { folder in
            Self.notifyFinished(folder)
        }
    }

    private static func makeEngines(current: CurrentLibrary) -> [any TranscriptionEngine] {
        #if DEBUG
            if let release = ProcessInfo.processInfo.environment["MINUTES_FAKE_TRANSCRIPTION"] {
                return [FakeTranscriptionEngine(id: fakeEngineID, releaseFile: URL(fileURLWithPath: release))]
            }
        #endif
        return [AppleSpeechEngine(), ParakeetEngine { current.value.modelsFolder }]
    }

    private static func makeDiarizer(current: CurrentLibrary) -> any SpeakerDiarizer {
        #if DEBUG
            if ProcessInfo.processInfo.environment["MINUTES_FAKE_DIARIZATION"] == "1" {
                return FakeDiarizer()
            }
        #endif
        return FluidDiarizer { current.value.modelsFolder }
    }

    /// Whether moving the library now would pull files out from under something.
    var isBusy: Bool {
        queue.isBusy || installingEngineID != nil
    }

    func engine(withID id: String) -> (any TranscriptionEngine)? {
        engines.first { $0.id == id }
    }

    func status(for entry: MeetingEntry) -> TranscriptStatus {
        if let activity = queue.activity, activity.folder == entry.id {
            return .working(activity.progress)
        }
        if queue.isWaiting(entry.id) {
            return .waiting
        }
        guard let metadata = entry.metadata, !metadata.isNewerThanThisApp else {
            return .newerVersion
        }
        guard let processing = metadata.processing else {
            return .notStarted
        }
        switch processing.status {
        // Marked as queued but not in the queue, as in a folder copied in Finder mid-job.
        case .queued, .stopped: return .stopped
        case .failed: return .failed(processing.failure ?? "Minutes couldn't finish transcribing this meeting.")
        case .waitingForModel: return .needsModel(engineID: processing.engine ?? preferredEngineID)
        case .complete: return .idle
        }
    }

    /// For the meeting's row in the list.
    func badge(for entry: MeetingEntry) -> String? {
        switch status(for: entry) {
        case .working: "Transcribing…"
        case .waiting: "Waiting to transcribe"
        case .stopped: "Transcription stopped"
        case .failed: "Transcription failed"
        case .needsModel: "Needs a speech model"
        case .notStarted, .newerVersion, .idle: nil
        }
    }

    /// The menu item for making a transcript, or `nil` if this meeting can't have one made right now.
    func transcribeTitle(for entry: MeetingEntry) -> String? {
        switch status(for: entry) {
        case .working, .waiting, .newerVersion: nil
        case .notStarted: "Transcribe"
        case .stopped, .failed, .needsModel, .idle: "Transcribe Again"
        }
    }

    func transcribe(_ entry: MeetingEntry) {
        queue.transcribeAgain(entry.id)
    }

    func setPreferredEngine(_ id: String) {
        guard id != preferredEngineID else {
            return
        }
        UserDefaults.standard.set(id, forKey: TranscriptionPreferences.engineKey)
        preferredEngineID = id
        // Meetings that were waiting for the other engine's model may not need to any more.
        queue.resumeWaitingForModel(in: LibraryStore.shared.library)
    }

    // MARK: - Models

    func refreshModelStatuses() async {
        for engine in engines {
            modelStatuses[engine.id] = await engine.modelStatus()
        }
    }

    /// Only ever called from a button the user pressed.
    func installModel(for engineID: String) {
        guard installingEngineID == nil, let engine = engine(withID: engineID) else {
            return
        }
        installingEngineID = engineID
        installProgress = 0
        installFailed = false
        installTask = Task {
            do {
                try await engine.installModel { fraction in
                    Task { @MainActor in
                        TranscriptionCenter.shared.installProgress = fraction
                    }
                }
                try Task.checkCancellation()
                await finishInstall(of: engineID)
            } catch {
                if !(error is CancellationError) {
                    Self.logger.error("Model download failed: \(String(describing: type(of: error)), privacy: .public)")
                    installFailed = true
                }
                await refreshModelStatuses()
            }
            installingEngineID = nil
            installTask = nil
        }
    }

    func cancelInstall() {
        installTask?.cancel()
    }

    func removeModel(for engineID: String) async {
        guard let engine = engine(withID: engineID), engine.canRemoveModel, !queue.isBusy else {
            return
        }
        do {
            try await engine.removeModel()
        } catch {
            Self.logger.error("Removing a model failed: \(String(describing: type(of: error)), privacy: .public)")
        }
        if preferredEngineID == engineID {
            setPreferredEngine(AppleSpeechEngine.engineID)
        }
        await refreshModelStatuses()
    }

    private func finishInstall(of engineID: String) async {
        await refreshModelStatuses()
        // An optional engine gets downloaded to be used. Apple's is already the default.
        setPreferredEngine(engineID)
        queue.resumeWaitingForModel(in: LibraryStore.shared.library)
    }

    /// Carries only the meeting's title.
    private static func notifyFinished(_ folder: URL) {
        guard let title = try? MeetingFolder(url: folder).loadMetadata().title else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Transcript Ready"
        content.body = title
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Self.logger.info("No notification: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }
}
