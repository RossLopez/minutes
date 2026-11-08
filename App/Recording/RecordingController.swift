// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import MinutesAudio
import MinutesStorage
import Observation
import os

/// Runs recordings for the whole app: the window, the menu bar and the global shortcut all use this.
@MainActor @Observable
final class RecordingController {
    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case saving
    }

    static let shared = RecordingController()

    private static let logger = Logger(subsystem: "io.github.rosslopez.minutes", category: "controller")
    private static let meterInterval = Duration.milliseconds(66)
    /// How much of the meter's last level survives each tick, so peaks fall smoothly.
    private static let meterDecay: Float = 0.85
    /// About every 10 seconds at the meter's rate.
    private static let ticksPerDiskCheck = 150
    private static let startStallLimit = Duration.seconds(15)

    private(set) var phase = Phase.idle {
        didSet {
            pauseOrResumeTranscribing(after: oldValue)
        }
    }

    private(set) var elapsedSeconds = 0
    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0
    private(set) var notices = RecordingNotices()
    private(set) var lastSavedFolder: URL?
    /// The meeting being recorded or saved, which nothing else may change.
    private(set) var activeFolder: URL?
    /// Goes up when something outside a view needs the Settings window. See `MenuBarLabel`.
    private(set) var settingsRequests = 0

    @ObservationIgnored private let useFakeAudio: Bool
    @ObservationIgnored private var meeting: ActiveMeeting?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var activity: any NSObjectProtocol?
    @ObservationIgnored private var startedAt = ContinuousClock.now
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var freeBytes: Int64?

    private init() {
        #if DEBUG
            useFakeAudio = ProcessInfo.processInfo.environment["MINUTES_FAKE_AUDIO"] == "1"
        #else
            useFakeAudio = false
        #endif
    }

    var isRecording: Bool {
        phase == .recording
    }

    var canToggle: Bool {
        (phase == .idle && !LibraryStore.shared.isMovingLibrary) || phase == .recording
    }

    func toggle() {
        switch phase {
        case .idle:
            startRecording()
        case .recording:
            stopRecording()
        case .starting, .saving:
            break
        }
    }

    func startRecording() {
        guard phase == .idle, !LibraryStore.shared.isMovingLibrary else {
            return
        }
        LibraryStore.shared.player.pause()
        phase = .starting
        notices = RecordingNotices()
        lastSavedFolder = nil
        Task {
            await start()
        }
    }

    func stopRecording() {
        guard phase == .recording else {
            return
        }
        phase = .saving
        Task {
            await finishCapture()
            await encodeFinishedMeeting()
        }
    }

    // MARK: - Starting

    private func start() async {
        guard await LibraryStore.shared.ensureLibraryIsAvailable() else {
            phase = .idle
            return
        }

        if !useFakeAudio {
            guard await ensurePermissions() else {
                phase = .idle
                return
            }
        }

        let watchdog = Task { [weak self] in
            try await Task.sleep(for: Self.startStallLimit)
            self?.handleStalledStart()
        }
        defer {
            watchdog.cancel()
        }

        do {
            meeting = try await makeMeeting()
            beginRecordingState()
        } catch {
            Self.logger.error("Recording failed to start: \(String(describing: error), privacy: .public)")
            phase = .idle
            RecordingAlerts.show(
                title: "Minutes Couldn't Start Recording",
                message: "Neither the microphone nor system audio could start. "
                    + "Check your audio devices, then try again.",
            )
        }
    }

    private func makeMeeting() async throws -> ActiveMeeting {
        let events: RecordingSession.EventHandler = { [weak self] track, event in
            Task { @MainActor in
                self?.handle(event, on: track)
            }
        }
        return try await ActiveMeeting(library: LibraryStore.shared.library, useFakeAudio: useFakeAudio, events: events)
    }

    /// Opening an input can block for as long as the Mac's audio service doesn't answer, and it
    /// can't be cancelled. See "Starting can hang" in docs/NOTES.md.
    private func handleStalledStart() {
        guard phase == .starting else {
            return
        }
        Self.logger.error("Recording hasn't started after \(Self.startStallLimit, privacy: .public)")
        if RecordingAlerts.askToQuitAfterStalledStart(), phase == .starting {
            NSApplication.shared.terminate(nil)
        }
    }

    private func beginRecordingState() {
        // Keeps the Mac awake and marks this work as important. The display can still sleep.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Recording a meeting",
        )
        startedAt = .now
        elapsedSeconds = 0
        tickCount = 0
        freeBytes = availableBytes()
        phase = .recording
        activeFolder = meeting?.folder.url
        Task {
            await LibraryStore.shared.refresh()
        }
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.meterInterval)
                self?.tick()
            }
        }
        Self.logger.info("Recording started")
        #if DEBUG
            SelfSoundTest.startIfRequested()
        #endif
    }

    private func ensurePermissions() async -> Bool {
        let permissions = PermissionsModel.shared
        guard await permissions.requestMicrophoneIfNeeded() == .granted else {
            askToOpenPermissions(.microphone)
            return false
        }
        switch await permissions.checkSystemAudio() {
        case .granted:
            return true
        case .unknown:
            notices.add(.systemAudioUnconfirmed)
            return true
        case .denied, .notRequested, .checking:
            askToOpenPermissions(.systemAudio)
            return false
        }
    }

    private func askToOpenPermissions(_ permission: RecordingAlerts.MissingPermission) {
        if RecordingAlerts.askToOpenPermissions(permission) {
            openPermissionsSettings()
        }
    }

    // MARK: - While recording

    private func tick() {
        guard let levels = meeting?.takeLevels() else {
            return
        }
        micLevel = max(levels.mic, micLevel * Self.meterDecay)
        systemLevel = max(levels.system, systemLevel * Self.meterDecay)

        let elapsed = startedAt.duration(to: .now).components.seconds
        if elapsed != elapsedSeconds {
            elapsedSeconds = Int(elapsed)
            updateWarnings()
        }

        tickCount += 1
        if tickCount.isMultiple(of: Self.ticksPerDiskCheck) {
            freeBytes = availableBytes()
        }
    }

    private func updateWarnings() {
        notices.apply(RecordingWarnings(
            elapsedSeconds: Double(elapsedSeconds),
            limitSeconds: RecordingPreferences.limitSeconds,
            freeBytes: freeBytes,
        ))
    }

    private func availableBytes() -> Int64? {
        let values = try? FileManager.default.homeDirectoryForCurrentUser
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private func handle(_ event: CaptureEvent, on track: RecordingTrack) {
        if case .restarted = event {
            Self.logger.info("Track \(track.rawValue, privacy: .public) restarted")
        }
        notices.apply(event, on: track)
    }

    // MARK: - Stopping

    private func finishCapture() async {
        meterTask?.cancel()
        meterTask = nil
        micLevel = 0
        systemLevel = 0
        await meeting?.finishCapture()
        await LibraryStore.shared.refresh()
    }

    private func encodeFinishedMeeting() async {
        if let meeting {
            do {
                try await meeting.encode()
                lastSavedFolder = meeting.folder.url
                notices.removeInfo()
            } catch {
                Self.logger.error("Encoding failed: \(String(describing: error), privacy: .public)")
                notices.add(.encodingFailed)
            }
        }
        let finished = meeting?.folder.url
        meeting = nil
        activeFolder = nil
        await LibraryStore.shared.refresh(selecting: finished)
        if let finished, lastSavedFolder == finished {
            TranscriptionCenter.shared.queue.enqueue(finished)
            // Asked here so the question comes when there's something to tell. It only ever shows
            // once, and nothing waits for the answer.
            if !useFakeAudio {
                Task {
                    await PermissionsModel.shared.requestNotifications()
                }
            }
        }
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
        phase = .idle
    }
}

// MARK: - Actions

extension RecordingController {
    func dismissSavedBanner() {
        lastSavedFolder = nil
    }

    func revealLastSaved() {
        guard let lastSavedFolder else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([lastSavedFolder])
    }

    func openPermissionsSettings() {
        openSettings(.permissions)
    }

    func openSettings(_ tab: SettingsTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.storageKey)
        settingsRequests += 1
    }

    /// Capture never competes with transcribing, and saving a recording needs the disk.
    private func pauseOrResumeTranscribing(after oldPhase: Phase) {
        guard (phase == .idle) != (oldPhase == .idle) else {
            return
        }
        if phase == .idle {
            TranscriptionCenter.shared.queue.unpause()
        } else {
            TranscriptionCenter.shared.queue.pause()
        }
    }
}

// MARK: - Quitting and recovery

extension RecordingController {
    func handleTerminationRequest() -> NSApplication.TerminateReply {
        switch phase {
        case .idle:
            return .terminateNow
        case .starting:
            // Nothing is recorded yet, and a stalled start must never trap the user in the app.
            return .terminateNow
        case .recording:
            guard RecordingAlerts.confirmQuitWhileRecording() else {
                return .terminateCancel
            }
            phase = .saving
            Task {
                await finishCapture()
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .saving:
            return RecordingAlerts.confirmQuitWhileSaving() ? .terminateNow : .terminateCancel
        }
    }

    func recoverUnfinishedMeetings() async {
        guard phase == .idle else {
            return
        }
        phase = .saving
        if let recovered = await MeetingRecovery.run(library: LibraryStore.shared.library) {
            lastSavedFolder = recovered
        }
        phase = .idle
        await LibraryStore.shared.refresh()
    }

    /// For a meeting left unfinished after someone chose Later.
    func recover(_ entry: MeetingEntry) async {
        guard phase == .idle, let metadata = entry.metadata else {
            return
        }
        phase = .saving
        if await MeetingRecovery.handle(folder: entry.folder, metadata: metadata) {
            lastSavedFolder = entry.id
        }
        phase = .idle
        await LibraryStore.shared.refresh()
        TranscriptionCenter.shared.queue.resumeInterrupted(in: LibraryStore.shared.library)
    }

    // MARK: - Library changes

    func folderMoved(from old: URL, to new: URL) {
        if lastSavedFolder == old {
            lastSavedFolder = new
        }
    }

    func folderGone(_ folder: URL) {
        if lastSavedFolder == folder {
            lastSavedFolder = nil
        }
    }
}
