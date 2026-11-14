// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesLlama
import MinutesLLM
import MinutesSearch
import MinutesStorage
import NaturalLanguage

// Search checks, run against a library folder. The index goes in a scratch file unless
// --index-file names one, so the library's own `.minutes/index.sqlite` is never touched.
//
//   minutes-llmcheck --library <root> --index [--embedder <gguf> | --embedder apple]
//   minutes-llmcheck --library <root> --retrieval <questions.json> [--embedder ...]
//   minutes-llmcheck (<model.gguf> | --endpoint <url>) --library <root> --ask <question>
//       [--embedder ...] [--meeting <folder name>]
//
// A questions file is a JSON list of {"question", "places": [{"meeting", "from", "to"}]}. A
// question is answered when one of the first results is a transcript passage from a meeting whose
// folder name contains "meeting", overlapping from–to seconds.

struct SearchCheckOptions {
    var library: MinutesLibrary
    var indexFile: URL
    /// The index file is the check's own, removed when it's done.
    var isScratch: Bool
    var embedder: any EmbeddingProvider?

    init(library: MinutesLibrary, indexFile: URL?, embedder: any EmbeddingProvider?) {
        self.library = library
        self.indexFile = indexFile ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("minutes-llmcheck-\(UUID().uuidString).sqlite")
        isScratch = indexFile == nil
        self.embedder = embedder
    }
}

/// `apple` for the system's contextual embedding, otherwise a GGUF file.
func makeEmbedder(_ argument: String?) throws -> (any EmbeddingProvider)? {
    guard let argument else {
        return nil
    }
    if argument == "apple" {
        return try AppleEmbedder()
    }
    let url = URL(fileURLWithPath: argument)
    return LlamaEmbedder(id: "check:\(url.deletingPathExtension().lastPathComponent)", modelURL: url)
}

/// Opens the index and brings it up to date, printing how long that took.
func preparedIndex(_ options: SearchCheckOptions, report: Bool) async throws -> SearchIndex {
    let index = try SearchIndex(file: options.indexFile)
    let start = ContinuousClock.now
    let update = try await index.update(library: options.library)
    let keywordSeconds = seconds(since: start)
    var status = try await index.status(model: options.embedder?.id)
    if report {
        print(String(format: "%d meetings indexed, %d unchanged, %d passages, keyword index %.2f s",
                     update.indexed, update.unchanged, status.chunks, keywordSeconds))
    }
    guard let embedder = options.embedder else {
        return index
    }
    let embedStart = ContinuousClock.now
    let count = try await index.embedMissing(using: embedder)
    let embedSeconds = seconds(since: embedStart)
    status = try await index.status(model: embedder.id)
    if report {
        print(String(format: "embedded %d passages with %@ in %.2f s (%.1f passages/s), %d of %d have vectors",
                     count, embedder.id, embedSeconds, Double(count) / max(embedSeconds, 0.001),
                     status.embedded, status.chunks))
        if let llama = embedder as? LlamaEmbedder {
            let stats = await llama.statistics
            print(String(format: "model load %.2f s, %d tokens, peak memory %.0f MB",
                         stats.loadSeconds, stats.tokens, peakMemoryMB()))
        }
    }
    return index
}

func runIndexCheck(_ options: SearchCheckOptions) async throws {
    let index = try await preparedIndex(options, report: true)
    let size = try index.file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    let wal = (try? URL(fileURLWithPath: index.file.path + "-wal").resourceValues(forKeys: [.fileSizeKey]))?
        .fileSize ?? 0
    print(String(format: "index %.2f MB, with its write-ahead log", Double(size + wal) / 1_048_576))
    await finish(options)
}

// MARK: - Retrieval

/// Where a question's answer is: a meeting whose folder name holds `meeting`, from–to seconds.
private struct RetrievalPlace: Decodable {
    enum CodingKeys: String, CodingKey {
        case meeting, from
        case until = "to"
    }

    var meeting: String
    var from: Double
    var until: Double
}

private struct RetrievalQuestion: Decodable {
    var question: String
    var places: [RetrievalPlace]

    func isAnswered(by hit: SearchHit) -> Bool {
        guard hit.chunk.kind == .transcript, let start = hit.chunk.start else {
            return false
        }
        let end = hit.chunk.end ?? start
        return places.contains { place in
            hit.folderName.contains(place.meeting) && start <= place.until && end >= place.from
        }
    }
}

/// hit@1, @5, @10 and @20, and the mean reciprocal rank over the first ten, for each way of searching.
func runRetrievalCheck(_ options: SearchCheckOptions, questionsFile: String) async throws {
    let questions = try JSONDecoder().decode(
        [RetrievalQuestion].self, from: Data(contentsOf: URL(fileURLWithPath: questionsFile)),
    )
    let index = try await preparedIndex(options, report: true)
    let methods: [SearchMethod] = options.embedder == nil ? [.keywords] : SearchMethod.allCases
    for method in methods {
        var ranks: [Int?] = []
        var queryTime = 0.0
        for question in questions {
            let start = ContinuousClock.now
            let hits = try await index.search(question.question, embedder: options.embedder, limit: 20,
                                              method: method)
            queryTime += seconds(since: start)
            let rank = hits.firstIndex(where: question.isAnswered).map { $0 + 1 }
            ranks.append(rank)
            if ProcessInfo.processInfo.environment["LLMCHECK_SHOW_HITS"] == "1" {
                for hit in hits.prefix(5) {
                    let time = Int(hit.chunk.start ?? 0)
                    print("      \(hit.folderName.suffix(1)) \(time / 60):\(String(format: "%02d", time % 60)) "
                        + hit.chunk.text.prefix(90).replacingOccurrences(of: "\n", with: " "))
                }
            }
            print("  \(method.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) "
                + "\(rank.map { "#\($0)" } ?? "--")  \(question.question)")
        }
        let count = Double(ranks.count)
        let hit1 = Double(ranks.count { $0 == 1 }) / count
        let within = { (limit: Int) in Double(ranks.count { ($0 ?? 99) <= limit }) / count }
        let mrr = ranks.reduce(0.0) { $0 + ($1.map { $0 <= 10 ? 1 / Double($0) : 0 } ?? 0) } / count
        print(String(format: "%@: hit@1 %.2f, @5 %.2f, @10 %.2f, @20 %.2f, MRR@10 %.2f, %.0f ms a query",
                     method.rawValue, hit1, within(5), within(10), within(20), mrr, queryTime / count * 1000))
    }
    await finish(options)
}

// MARK: - Asking

/// Answers a question the way the Chat view does, printing the sources it was given.
func runAskCheck(
    _ options: SearchCheckOptions,
    question: String,
    meeting: String?,
    provider: any LLMProvider,
) async throws {
    let index = try await preparedIndex(options, report: false)
    var scope = ChatScope.library
    if let meeting {
        let entry = options.library.meetings().first { $0.folder.url.lastPathComponent.contains(meeting) }
        guard let id = entry?.metadata?.id else {
            fail("No meeting folder contains \(meeting)")
        }
        scope = .meeting(id)
    }
    let answerer = ChatAnswerer(index: index, provider: provider, embedder: options.embedder)
    let start = ContinuousClock.now
    let prepared = try await answerer.prepare(question, history: [], scope: scope, filter: .everything)
    let prepareSeconds = seconds(since: start)
    for source in prepared.sources {
        let time = source.start.map { String(format: "%d:%02d", Int($0) / 60, Int($0) % 60) } ?? "-"
        print("[\(source.number)] \(source.meetingTitle) \(time) \(source.kind.rawValue)")
    }
    print("---")
    var answer = ""
    var firstPiece: Double?
    let answerStart = ContinuousClock.now
    if prepared.sources.isEmpty {
        answer = ChatAnswerer.nothingFound
    } else {
        for try await piece in answerer.answer(prepared) {
            firstPiece = firstPiece ?? seconds(since: answerStart)
            answer += piece
        }
    }
    print(Citations.cleaned(answer, count: prepared.sources.count))
    print("---")
    print(String(format: "%d sources, search and fitting %.2f s, first text after %.2f s, answer %.1f s",
                 prepared.sources.count, prepareSeconds, firstPiece ?? 0, seconds(since: answerStart)))
    if let builtIn = provider as? LlamaProvider {
        let stats = await builtIn.statistics
        print(String(format: "prompt %d tokens, answer %d tokens, peak memory %.0f MB",
                     stats.promptTokens, stats.generatedTokens, peakMemoryMB()))
        await builtIn.unload()
    }
    await finish(options)
}

/// Frees the model, which ggml needs before exit, and removes a scratch index.
private func finish(_ options: SearchCheckOptions) async {
    if let llama = options.embedder as? LlamaEmbedder {
        await llama.unload()
    }
    if options.isScratch {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: options.indexFile.path + suffix)
        }
    }
}

// MARK: - Apple's embedding, for comparison

/// The system's English contextual embedding, averaged over tokens. Only for comparing with
/// EmbeddingGemma: the app doesn't use it.
final class AppleEmbedder: EmbeddingProvider, @unchecked Sendable {
    let id: String
    let dimensions: Int
    private let embedding: NLContextualEmbedding
    private let lock = NSLock()

    init() throws {
        guard let embedding = NLContextualEmbedding(language: .english) else {
            fail("No contextual embedding for English on this Mac.")
        }
        guard embedding.hasAvailableAssets else {
            fail("The system's English embedding isn't downloaded. Minutes doesn't download it.")
        }
        try embedding.load()
        self.embedding = embedding
        id = "apple:\(embedding.modelIdentifier)/\(embedding.revision)"
        dimensions = embedding.dimension
    }

    func embed(documents: [EmbeddingDocument]) async throws -> [[Float]] {
        try documents.map { try vector($0.text) }
    }

    func embed(query: String) async throws -> [Float] {
        try vector(query)
    }

    private func vector(_ text: String) throws -> [Float] {
        lock.lock()
        defer {
            lock.unlock()
        }
        let result = try embedding.embeddingResult(for: text, language: .english)
        var sum = [Double](repeating: 0, count: dimensions)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex ..< text.endIndex) { vector, _ in
            for (index, value) in vector.enumerated() where index < sum.count {
                sum[index] += value
            }
            count += 1
            return true
        }
        return EmbeddingMath.normalized(sum.map { Float($0 / Double(max(count, 1))) })
    }
}
