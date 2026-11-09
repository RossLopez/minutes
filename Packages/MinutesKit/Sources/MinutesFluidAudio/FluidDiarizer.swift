// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import FluidAudio
import Foundation
import MinutesAudio
import MinutesDiarization

/// pyannote Community-1 through FluidAudio's offline pipeline: segmentation, voice embeddings and
/// VBx clustering over the whole track. Downloaded only when the user asks, into `~/Minutes/Models`.
public struct FluidDiarizer: SpeakerDiarizer {
    public static let diarizerID = "pyannote-community-1"

    /// FluidAudio picks the folder name, and loads only from a folder with that name.
    private static let folderName = Repo.diarizer.folderName
    private static let modelFiles = [
        ModelNames.OfflineDiarizer.segmentationFile,
        ModelNames.OfflineDiarizer.fbankFile,
        ModelNames.OfflineDiarizer.embeddingFile,
        ModelNames.OfflineDiarizer.pldaRhoFile,
    ]

    public let id = FluidDiarizer.diarizerID
    public let modelName = "pyannote Community-1"
    /// Segmentation, FBank, Embedding, PldaRho and the PLDA parameters, as listed on Hugging Face.
    public let downloadSizeBytes: Int64 = 22_000_000

    private let modelsFolder: @Sendable () -> URL
    private let batchSize: Int

    /// - Parameter batchSize: Ten-second windows per segmentation call. It doesn't change the
    ///   result. 8 rather than FluidAudio's 32 lowers a 4-hour meeting's peak from 1.4 GB to
    ///   1.0 GB, for about 13 s more (see docs/NOTES.md).
    public init(modelsFolder: @escaping @Sendable () -> URL, batchSize: Int = 8) {
        self.modelsFolder = modelsFolder
        self.batchSize = batchSize
        _ = FluidNetwork.configured
    }

    private var repoFolder: URL {
        modelsFolder().appendingPathComponent(Self.folderName, isDirectory: true)
    }

    public func modelStatus() async -> DiarizationModelStatus {
        let manager = FileManager.default
        let folder = repoFolder
        let hasModels = Self.modelFiles.allSatisfy { name in
            let compiled = folder.appendingPathComponent(name).appendingPathComponent("coremldata.bin")
            return manager.fileExists(atPath: compiled.path)
        }
        let hasParameters = manager.fileExists(
            atPath: folder.appendingPathComponent(ModelNames.OfflineDiarizer.pldaParameters).path,
        )
        return hasModels && hasParameters ? .installed : .notInstalled
    }

    /// Downloads into a hidden folder and moves the result into place, so a cancelled or
    /// failed download never looks like an installed model.
    public func installModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        let manager = FileManager.default
        let folder = modelsFolder()
        let incoming = folder.appendingPathComponent(".downloading-diarizer", isDirectory: true)
        try? manager.removeItem(at: incoming)
        try manager.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: incoming) }

        try await FluidNetwork.allowingDownloads {
            try await ModelHub.download(.diarizer, to: incoming, variant: "offline") { update in
                progress(update.fractionCompleted)
            }
        }
        try Task.checkCancellation()
        let destination = repoFolder
        try? manager.removeItem(at: destination)
        try manager.moveItem(at: incoming.appendingPathComponent(Self.folderName, isDirectory: true), to: destination)
        progress(1)
    }

    public func removeModel() async throws {
        try? FileManager.default.removeItem(at: repoFolder)
    }

    public func diarize(
        audio: URL,
        workFolder: URL,
        progress: @escaping @Sendable (Double) -> Void,
    ) async throws -> Diarization {
        let manager = try await loadedManager()
        let source = try MappedAudioSource.make(from: audio, in: workFolder, sampleRate: sampleRate)
        try Task.checkCancellation()
        let result = try await manager.process(audioSource: source, audioLoadingSeconds: 0) { done, total in
            progress(total > 0 ? Double(done) / Double(total) : 0)
        }
        try Task.checkCancellation()
        let turns = result.segments.map { segment in
            SpeakerTurn(
                speaker: segment.speakerId,
                start: Double(segment.startTimeSeconds),
                end: Double(segment.endTimeSeconds),
            )
        }
        .sorted { $0.start < $1.start }
        return Diarization(turns: turns, embeddings: result.speakerDatabase ?? [:])
    }

    /// The spans' embeddings, averaged by how long each one is.
    public func embedding(audio: URL, spans: [ClosedRange<Double>], workFolder: URL) async throws -> [Float] {
        let spans = spans.filter { $0.upperBound > $0.lowerBound }
        guard !spans.isEmpty else {
            throw CocoaError(.fileReadUnknown)
        }
        let manager = try await loadedManager()
        let source = try MappedAudioSource.make(from: audio, in: workFolder, sampleRate: sampleRate)
        let vectors = try await manager.embedSpans(
            audioSource: source,
            spans: spans.map { $0.lowerBound ..< $0.upperBound },
        )
        var total = [Float](repeating: 0, count: vectors.first?.count ?? 0)
        for (vector, span) in zip(vectors, spans) where vector.count == total.count {
            let weight = Float(span.upperBound - span.lowerBound)
            for index in total.indices {
                total[index] += vector[index] * weight
            }
        }
        return total
    }

    private var config: OfflineDiarizerConfig {
        // One speaker at a time, so each word belongs to exactly one person.
        var config = OfflineDiarizerConfig(exclusiveSegments: true)
        config.segmentation.batchSize = batchSize
        return config
    }

    private var sampleRate: Double {
        Double(config.segmentation.sampleRate)
    }

    /// Loads from `~/Minutes/Models` only. FluidAudio's own preparation deletes and re-downloads a
    /// model that fails to load, and nothing is fetched without the user asking.
    private func loadedManager() async throws -> OfflineDiarizerManager {
        guard await modelStatus() == .installed else {
            throw CocoaError(.fileNoSuchFile)
        }
        // FluidAudio adds the model's own folder name to this.
        let models = try await OfflineDiarizerModels.load(from: modelsFolder())
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)
        return manager
    }
}

/// Audio for FluidAudio, resampled into the work folder and mapped from there, so a long meeting
/// stays out of memory and its audio never leaves the meeting folder.
struct MappedAudioSource: AudioSampleSource {
    private let data: Data

    static func make(from audio: URL, in workFolder: URL, sampleRate: Double) throws -> MappedAudioSource {
        let raw = workFolder.appendingPathComponent("diarizer-\(Int(sampleRate)).raw")
        try TrackResampler.writeRawMono(from: audio, to: raw, sampleRate: sampleRate)
        return try MappedAudioSource(data: Data(contentsOf: raw, options: .alwaysMapped))
    }

    init(data: Data) {
        self.data = data
    }

    var sampleCount: Int {
        data.count / MemoryLayout<Float>.size
    }

    /// Anything past the end reads as silence.
    func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
        guard count > 0 else {
            return
        }
        destination.update(repeating: 0, count: count)
        let start = max(0, offset)
        let available = min(count - (start - offset), sampleCount - start)
        guard available > 0 else {
            return
        }
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Float.self)
            (destination + (start - offset)).update(from: samples.baseAddress! + start, count: available)
        }
    }
}
