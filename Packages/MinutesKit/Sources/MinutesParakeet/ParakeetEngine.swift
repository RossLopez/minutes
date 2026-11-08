// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import FluidAudio
import Foundation
import MinutesAudio
import MinutesStorage
import MinutesTranscription

/// Parakeet TDT v2 through FluidAudio: an optional engine, downloaded only when the user asks.
/// Models live in `~/Minutes/Models`. FluidAudio's network access stays off except during that download.
public struct ParakeetEngine: TranscriptionEngine {
    public static let engineID = "parakeet"

    /// FluidAudio names these folders after its download sources, and insists on those names.
    private static let speechFolderName = "parakeet-tdt-0.6b-v2"
    private static let vocabularyFolderName = "parakeet-ctc-110m-coreml"

    /// FluidAudio's debug output includes transcript text, and Minutes never logs that.
    private static let libraryConfigured: Void = {
        AppLogger.minimumLevel = .error
        AppLogger.mirrorsToConsole = false
        ModelHub.offlineMode = true
    }()

    public let id = ParakeetEngine.engineID
    public let modelName = "Parakeet TDT 0.6b v2"
    /// About 450 MB for speech and 99 MB for vocabulary, as measured in docs/TRANSCRIPTION_SPIKE.md.
    public let downloadSizeBytes: Int64? = 550_000_000
    public let canRemoveModel = true

    private let modelsFolder: @Sendable () -> URL

    public init(modelsFolder: @escaping @Sendable () -> URL) {
        self.modelsFolder = modelsFolder
        _ = Self.libraryConfigured
    }

    public func modelStatus() async -> TranscriptionModelStatus {
        let folder = modelsFolder()
        let hasSpeech = AsrModels.modelsExist(
            at: folder.appendingPathComponent(Self.speechFolderName, isDirectory: true),
            version: .v2,
        )
        let hasVocabulary = CtcModels.modelsExist(
            at: folder.appendingPathComponent(Self.vocabularyFolderName, isDirectory: true),
        )
        return hasSpeech && hasVocabulary ? .installed : .notInstalled
    }

    /// Downloads into a hidden folder and moves the result into place, so a cancelled or
    /// failed download never looks like an installed model.
    public func installModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        let manager = FileManager.default
        let folder = modelsFolder()
        let incoming = folder.appendingPathComponent(".downloading-parakeet", isDirectory: true)
        try? manager.removeItem(at: incoming)
        try manager.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: incoming) }

        ModelHub.offlineMode = false
        defer { ModelHub.offlineMode = true }

        let speechWeight = 0.82
        let speech = incoming.appendingPathComponent(Self.speechFolderName, isDirectory: true)
        _ = try await AsrModels.download(to: speech, version: .v2) { update in
            progress(update.fractionCompleted * speechWeight)
        }
        try Task.checkCancellation()
        let vocabulary = incoming.appendingPathComponent(Self.vocabularyFolderName, isDirectory: true)
        _ = try await CtcModels.download(to: vocabulary, variant: .ctc110m)
        progress(1)

        for name in [Self.speechFolderName, Self.vocabularyFolderName] {
            let destination = folder.appendingPathComponent(name, isDirectory: true)
            try? manager.removeItem(at: destination)
            try manager.moveItem(at: incoming.appendingPathComponent(name, isDirectory: true), to: destination)
        }
    }

    public func removeModel() async throws {
        let folder = modelsFolder()
        for name in [Self.speechFolderName, Self.vocabularyFolderName] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name, isDirectory: true))
        }
    }

    public func transcribe(
        audio: URL,
        vocabulary: [VocabularyEntry],
        workFolder: URL,
        progress: @escaping @Sendable (Double) -> Void,
    ) async throws -> [TranscriptWord] {
        // FluidAudio's loaders download anything missing while another job has its network access on.
        guard await modelStatus() == .installed else {
            throw CocoaError(.fileNoSuchFile)
        }
        let folder = modelsFolder()
        let models = try await AsrModels.load(
            from: folder.appendingPathComponent(Self.speechFolderName, isDirectory: true),
            version: .v2,
        )
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        let booster = try await VocabularyBooster(
            entries: vocabulary,
            modelFolder: folder.appendingPathComponent(Self.vocabularyFolderName, isDirectory: true),
        )

        let splitter = try TrackSplitter(url: audio)
        let pieceURL = workFolder.appendingPathComponent("piece.caf")
        var words: [TranscriptWord] = []
        while let piece = try splitter.next(writingTo: pieceURL) {
            try Task.checkCancellation()
            var state = await TdtDecoderState.make(decoderLayers: manager.decoderLayerCount)
            let result = try await manager.transcribe(piece.url, decoderState: &state)
            try Task.checkCancellation()
            let timings = result.tokenTimings ?? []
            var heard = buildWordTimings(from: timings).map {
                TranscriptWord(text: $0.word, start: $0.startTime, end: $0.endTime)
            }
            if let booster {
                heard = try await booster.rescore(heard, text: result.text, timings: timings, audio: piece.url)
            }
            words += heard.map {
                TranscriptWord(text: $0.text, start: $0.start + piece.startSeconds, end: $0.end + piece.startSeconds)
            }
            if splitter.totalSeconds > 0 {
                progress(min((piece.startSeconds + piece.durationSeconds) / splitter.totalSeconds, 1))
            }
        }
        await manager.cleanup()
        return words
    }
}

/// FluidAudio's vocabulary step, with the strict settings from docs/TRANSCRIPTION_SPIKE.md.
///
/// It's built from FluidAudio's parts rather than `VocabularyBoostingSession`, because the session
/// only reads its tokenizer from FluidAudio's default folder, and models belong in `~/Minutes/Models`.
private struct VocabularyBooster {
    private static let termAdvantage: Float = 0
    private static let minimumSimilarity: Float = 0.7
    private static let searchMarginSeconds = 0.5

    private let context: CustomVocabularyContext
    private let spotter: CtcKeywordSpotter
    private let rescorer: VocabularyRescorer

    /// `nil` if there's nothing to listen for, which saves loading a model.
    init?(entries: [VocabularyEntry], modelFolder: URL) async throws {
        let tokenizer = try await CtcTokenizer.load(from: modelFolder)
        let terms = entries.compactMap { entry -> CustomVocabularyTerm? in
            let tokens = tokenizer.encode(entry.term)
            guard !tokens.isEmpty else {
                return nil
            }
            return CustomVocabularyTerm(
                text: entry.term,
                aliases: entry.variants.isEmpty ? nil : entry.variants,
                ctcTokenIds: tokens,
            )
        }
        guard !terms.isEmpty else {
            return nil
        }
        let models = try await CtcModels.load(from: modelFolder, variant: .ctc110m)
        context = CustomVocabularyContext(terms: terms)
        spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        rescorer = try await VocabularyRescorer.create(
            spotter: spotter,
            vocabulary: context,
            config: .default,
            ctcModelDirectory: modelFolder,
        )
    }

    /// The step returns only text, so timings carry over from what the engine first heard.
    func rescore(
        _ words: [TranscriptWord],
        text: String,
        timings: [TokenTiming],
        audio: URL,
    ) async throws -> [TranscriptWord] {
        guard !timings.isEmpty else {
            return words
        }
        let samples = try AudioConverter().resampleAudioFile(audio)
        let spotted = try await spotter.spotKeywordsWithLogProbs(audioSamples: samples, customVocabulary: context)
        guard !spotted.logProbs.isEmpty else {
            return words
        }
        let output = rescorer.ctcTokenRescore(
            transcript: text,
            tokenTimings: timings,
            logProbs: spotted.logProbs,
            frameDuration: spotted.frameDuration,
            cbw: Self.termAdvantage,
            marginSeconds: Self.searchMarginSeconds,
            minSimilarity: max(Self.minimumSimilarity, context.minSimilarity),
        )
        return output.wasModified ? TimedTextAligner.retime(words, toMatch: output.text) : words
    }
}
