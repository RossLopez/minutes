// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import AVFoundation
import Foundation
import MinutesStorage
import Speech

/// Apple's `SpeechTranscriber`. macOS keeps its model and runs it in a system service, so memory
/// use stays flat however long the meeting is.
///
/// It ignores contextual strings (see docs/NOTES.md), so vocabulary only takes effect in the
/// replacement step after transcription.
public struct AppleSpeechEngine: TranscriptionEngine {
    public static let engineID = "apple"
    private static let locale = Locale(identifier: "en_US")

    public let id = AppleSpeechEngine.engineID
    public let modelName = "SpeechTranscriber en_US"
    /// macOS doesn't say how big the download is until it's under way.
    public let downloadSizeBytes: Int64? = nil
    public let canRemoveModel = false

    public init() {}

    public func modelStatus() async -> TranscriptionModelStatus {
        guard SpeechTranscriber.isAvailable else {
            return .unavailable("Apple's speech recognition isn't available on this Mac.")
        }
        guard let module = await makeTranscriber() else {
            return .unavailable("Apple's speech recognition doesn't support English on this Mac.")
        }
        switch await AssetInventory.status(forModules: [module]) {
        case .installed:
            return .installed
        case .unsupported:
            return .unavailable("Apple's speech recognition doesn't support English on this Mac.")
        default:
            // Having no request to make means there's nothing to fetch, whatever the status says (see docs/NOTES.md).
            let request = try? await AssetInventory.assetInstallationRequest(supporting: [module])
            return request == nil ? .installed : .notInstalled
        }
    }

    public func installModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let module = await makeTranscriber(),
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Self.locale)
        else {
            throw CocoaError(.featureUnsupported)
        }
        // Reserving keeps macOS from reclaiming the model when it needs space.
        try await AssetInventory.reserve(locale: locale)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
            return
        }
        let observation = request.progress.observe(\.fractionCompleted) { reported, _ in
            progress(reported.fractionCompleted)
        }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
    }

    public func removeModel() async throws {
        throw CocoaError(.featureUnsupported)
    }

    public func transcribe(
        audio: URL,
        vocabulary _: [VocabularyEntry],
        workFolder _: URL,
        progress: @escaping @Sendable (Double) -> Void,
    ) async throws -> [TranscriptWord] {
        guard let transcriber = await makeTranscriber() else {
            throw CocoaError(.featureUnsupported)
        }
        let file = try AVAudioFile(forReading: audio)
        let duration = Double(file.length) / file.fileFormat.sampleRate
        let collector = Task {
            var words: [TranscriptWord] = []
            for try await result in transcriber.results {
                words += Self.words(in: result.text)
                if let end = words.last?.end, duration > 0 {
                    progress(min(end / duration, 1))
                }
            }
            return words
        }
        let options = SpeechAnalyzer.Options(
            priority: .userInitiated,
            modelRetention: .whileInUse,
            ignoresResourceLimits: true,
        )
        return try await withTaskCancellationHandler {
            let analyzer: SpeechAnalyzer
            do {
                analyzer = try await SpeechAnalyzer(
                    inputAudioFile: file,
                    modules: [transcriber],
                    options: options,
                    finishAfterFile: true,
                )
            } catch {
                collector.cancel()
                throw error
            }
            let words = try await collector.value
            withExtendedLifetime(analyzer) {}
            // A cancelled collector stops early with what it has, which isn't a whole transcript.
            try Task.checkCancellation()
            return words
        } onCancel: {
            collector.cancel()
        }
    }

    private func makeTranscriber() async -> SpeechTranscriber? {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Self.locale) else {
            return nil
        }
        return SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            // Only the times are used. With them alone, the asset status reads differently (see docs/NOTES.md).
            attributeOptions: [.audioTimeRange, .transcriptionConfidence],
        )
    }

    /// Each timed run is a word, with its leading space. Times count from the start of the file.
    private static func words(in text: AttributedString) -> [TranscriptWord] {
        text.runs.compactMap { run in
            guard let range = run.audioTimeRange else {
                return nil
            }
            let word = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else {
                return nil
            }
            return TranscriptWord(text: word, start: range.start.seconds, end: range.end.seconds)
        }
    }
}
