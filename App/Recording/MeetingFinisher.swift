// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesAudio
import MinutesStorage

/// Turns a meeting's CAF tracks into its final audio files and marks it complete.
///
/// Safe to run again after an interruption, because each CAF is removed only once its encoded
/// file has been checked.
enum MeetingFinisher {
    static func encodeTracks(in folder: MeetingFolder, metadata: MeetingMetadata) async throws {
        let format = RecordingAudioFormat(rawValue: metadata.audioFormat) ?? .aac
        for (caf, destination) in [(folder.micCAF, folder.micAudio), (folder.systemCAF, folder.systemAudio)] {
            guard FileManager.default.fileExists(atPath: caf.path) else {
                continue
            }
            if try CAFTrackWriter.frameCount(ofFileAt: caf) == 0 {
                // A crash before any audio was written leaves only part of a header.
                try FileManager.default.removeItem(at: caf)
                continue
            }
            try await TrackEncoder.encode(caf: caf, to: destination, format: format)
        }
        var finished = metadata
        finished.state = .complete
        // In place before anything else, so a crash right after this still gets transcribed at next launch.
        finished.processing = ProcessingState()
        try folder.save(finished)
    }

    /// The length of the longest track a crash left behind, in seconds.
    static func recoverableSeconds(in folder: MeetingFolder) -> Double {
        let frames = [folder.micCAF, folder.systemCAF].map { (try? CAFTrackWriter.frameCount(ofFileAt: $0)) ?? 0 }
        return Double(frames.max() ?? 0) / Double(TrackTimeline.sampleRate)
    }
}
