// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesStorage

public enum TranscriptionModelStatus: Equatable, Sendable {
    case installed
    case notInstalled
    /// This engine can't run here, with a reason written for the user.
    case unavailable(String)
}

/// Turns one audio file into timed words, entirely on this Mac.
public protocol TranscriptionEngine: Sendable {
    /// What's stored in `transcript.json` and Settings, like `apple`.
    var id: String { get }
    /// Which model wrote a transcript, recorded in `transcript.json`.
    var modelName: String { get }

    /// What the download takes, if the engine knows in advance.
    var downloadSizeBytes: Int64? { get }
    /// Whether Minutes owns the model and can delete it. macOS manages its own.
    var canRemoveModel: Bool { get }

    func modelStatus() async -> TranscriptionModelStatus

    /// Downloads the model. Only ever called because the user asked.
    func installModel(progress: @escaping @Sendable (Double) -> Void) async throws

    func removeModel() async throws

    /// Words in time order, with times from the start of the file. Silence gives an empty array.
    ///
    /// - Parameters:
    ///   - vocabulary: For engines that can listen for terms. Corrections after transcription don't belong here.
    ///   - workFolder: Exists, and belongs to this call. It's deleted later, so it can hold temporary files.
    ///   - progress: From 0 to 1, when the engine can tell.
    func transcribe(
        audio: URL,
        vocabulary: [VocabularyEntry],
        workFolder: URL,
        progress: @escaping @Sendable (Double) -> Void,
    ) async throws -> [TranscriptWord]
}
