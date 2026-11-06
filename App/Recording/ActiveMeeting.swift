// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesAudio
import MinutesStorage
import os

/// One recording's folder, metadata and capture session, from starting to fully saved.
@MainActor
final class ActiveMeeting {
    private static let logger = Logger(subsystem: "io.github.rosslopez.minutes", category: "meeting")

    let folder: MeetingFolder
    private let session: RecordingSession
    private var metadata: MeetingMetadata

    /// Creates the meeting's folder and starts capture. If no track can start, nothing is left behind.
    init(
        library: MinutesLibrary,
        useFakeAudio: Bool,
        events: @escaping RecordingSession.EventHandler,
    ) async throws {
        let startDate = Date()
        let options = MicCapture.Options(
            voiceProcessing: RecordingPreferences.voiceProcessing,
            deviceUID: RecordingPreferences.inputDeviceUID,
        )
        folder = try library.createMeetingFolder(startedAt: startDate, title: "Recording")
        metadata = MeetingMetadata(
            title: "Recording",
            startedAt: startDate,
            audioFormat: RecordingPreferences.audioFormat.rawValue,
            voiceProcessing: options.voiceProcessing,
            inputDeviceName: RecordingSources.inputDeviceName(for: options),
            outputDeviceName: AudioDevices.defaultOutputName(),
        )
        let sources = RecordingSources.make(options: options, useFakeAudio: useFakeAudio)
        session = RecordingSession(
            micSource: sources.mic,
            systemSource: sources.system,
            micURL: folder.micCAF,
            systemURL: folder.systemCAF,
            events: events,
        )
        do {
            try folder.save(metadata)
            try await session.start()
        } catch {
            // Nothing was captured, so the folder holds no audio worth keeping.
            try? FileManager.default.removeItem(at: folder.url)
            throw error
        }
    }

    func takeLevels() -> TrackLevels {
        session.takeLevels()
    }

    /// Stops capture and leaves the meeting ready to encode. The CAF files are complete after this.
    func finishCapture() async {
        let summary = await session.stop()
        metadata.durationSeconds = summary.durationSeconds
        metadata.state = .encoding
        metadata.mic = trackMetadata(summary.mic)
        metadata.system = trackMetadata(summary.system)
        do {
            try folder.save(metadata)
        } catch {
            Self.logger.error("Saving meeting.json failed: \(String(describing: error), privacy: .public)")
        }
        let droppedMic = summary.mic.droppedFrames
        let droppedSystem = summary.system.droppedFrames
        Self.logger.info("Capture finished: dropped mic=\(droppedMic) system=\(droppedSystem)")
    }

    func encode() async throws {
        try await MeetingFinisher.encodeTracks(in: folder, metadata: metadata)
    }

    private func trackMetadata(_ summary: TrackSummary) -> MeetingMetadata.Track {
        MeetingMetadata.Track(
            startOffsetSeconds: summary.firstAudioSeconds,
            gaps: summary.gaps.map { .init(startSeconds: $0.startSeconds, durationSeconds: $0.durationSeconds) },
            failure: summary.failure,
        )
    }
}
