// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import MinutesStorage
import os

/// Handles meetings a crash or quit left unfinished.
///
/// Encoding resumes by itself, because the user already ended those meetings. A recording cut
/// off by a crash is the user's call.
@MainActor
enum MeetingRecovery {
    private static let logger = Logger(subsystem: "io.github.rosslopez.minutes", category: "recovery")

    /// Returns the folder of the last meeting it finished, if any.
    static func run(library: MinutesLibrary) async -> URL? {
        var lastFinished: URL?
        for (folder, metadata) in library.unfinishedMeetings()
            where await handle(folder: folder, metadata: metadata)
        {
            lastFinished = folder.url
        }
        return lastFinished
    }

    /// Finishes one meeting, asking first if it was cut off. Returns whether it's now complete.
    static func handle(folder: MeetingFolder, metadata: MeetingMetadata) async -> Bool {
        switch metadata.state {
        case .encoding: await resumeEncoding(folder: folder, metadata: metadata)
        case .recording: await offerRecovery(folder: folder, metadata: metadata)
        case .complete: false
        }
    }

    private static func resumeEncoding(folder: MeetingFolder, metadata: MeetingMetadata) async -> Bool {
        do {
            try await MeetingFinisher.encodeTracks(in: folder, metadata: metadata)
            return true
        } catch {
            logger.error("Resuming encoding failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private static func offerRecovery(folder: MeetingFolder, metadata: MeetingMetadata) async -> Bool {
        let seconds = MeetingFinisher.recoverableSeconds(in: folder)
        let started = metadata.startedAt.formatted(date: .abbreviated, time: .shortened)
        let hasAudio = seconds > 0
        let length = Duration.seconds(seconds)
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 2))
        let alert = RecordingAlerts.makeAlert(
            title: "Recover Your Recording?",
            message: hasAudio
                ? "A recording from \(started) didn't finish. \(length) of audio can be recovered."
                : "A recording from \(started) didn't finish, and it has no audio to recover.",
        )
        if hasAudio {
            alert.addButton(withTitle: "Recover")
        }
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()

        if hasAudio, response == .alertFirstButtonReturn {
            return await recover(folder: folder, metadata: metadata, seconds: seconds)
        }
        if response == (hasAudio ? .alertSecondButtonReturn : .alertFirstButtonReturn) {
            await LibraryStore.shared.moveToTrash(MeetingEntry(
                folder: folder,
                metadata: metadata,
                date: metadata.startedAt,
            ))
        }
        return false
    }

    private static func recover(folder: MeetingFolder, metadata: MeetingMetadata, seconds: Double) async -> Bool {
        var recovered = metadata
        recovered.durationSeconds = seconds
        recovered.state = .encoding
        do {
            try folder.save(recovered)
            try await MeetingFinisher.encodeTracks(in: folder, metadata: recovered)
            return true
        } catch {
            logger.error("Recovery failed: \(String(describing: error), privacy: .public)")
            RecordingAlerts.show(
                title: "Minutes Couldn't Finish Recovering",
                message: "The audio is still in the meeting's folder, and Minutes will try again next launch.",
            )
            return false
        }
    }
}
