// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A stretch of time when one speaker was talking.
public struct SpeakerTurn: Codable, Equatable, Sendable {
    public var speaker: String
    public var start: Double
    public var end: Double

    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = max(start, end)
    }

    public var duration: Double {
        end - start
    }
}

/// Who spoke when on one track, plus what each voice sounds like.
///
/// The embeddings are biometric data about other people. They live only in `.processing/` during
/// a run, and in `Speakers/` when the user turns on speaker memory. They're never logged.
public struct Diarization: Codable, Equatable, Sendable {
    /// In time order, one speaker at a time.
    public var turns: [SpeakerTurn]
    /// Keyed by the speaker IDs in `turns`.
    public var embeddings: [String: [Float]]

    public init(turns: [SpeakerTurn], embeddings: [String: [Float]] = [:]) {
        self.turns = turns
        self.embeddings = embeddings
    }

    public var speakers: [String] {
        var seen = Set<String>()
        return turns.compactMap { seen.insert($0.speaker).inserted ? $0.speaker : nil }
    }
}

public enum DiarizationModelStatus: Equatable, Sendable {
    case installed
    case notInstalled
    /// It can't run here, with a reason written for the user.
    case unavailable(String)
}

/// Tells the people on one audio track apart, entirely on this Mac.
public protocol SpeakerDiarizer: Sendable {
    /// What's stored in `meeting.json`, like `pyannote-community-1`.
    var id: String { get }
    var modelName: String { get }
    var downloadSizeBytes: Int64 { get }

    func modelStatus() async -> DiarizationModelStatus

    /// Downloads the model. Only ever called because the user asked.
    func installModel(progress: @escaping @Sendable (Double) -> Void) async throws

    func removeModel() async throws

    /// Speaker IDs are the engine's own. Silence gives no turns.
    ///
    /// - Parameters:
    ///   - workFolder: Exists, and belongs to this call. It's deleted later, so it can hold temporary files.
    ///   - progress: From 0 to 1.
    func diarize(
        audio: URL,
        workFolder: URL,
        progress: @escaping @Sendable (Double) -> Void,
    ) async throws -> Diarization

    /// One embedding for the voice heard in `spans`, comparable with `Diarization.embeddings`.
    func embedding(audio: URL, spans: [ClosedRange<Double>], workFolder: URL) async throws -> [Float]
}
