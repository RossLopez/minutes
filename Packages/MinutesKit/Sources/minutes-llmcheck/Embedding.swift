// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesLlama
import MinutesLLM

/// `--embed <file>`: each line of the file embedded as it is, with no prefix, printed as JSON
/// full-width vectors for comparing with llama-server's `/v1/embeddings`. Speed goes to standard
/// error.
func runEmbedCheck(model: URL, linesFile: String) async throws {
    let lines = try String(contentsOfFile: linesFile, encoding: .utf8)
        .split(separator: "\n").map(String.init)
    let embedder = LlamaEmbedder(id: "check", modelURL: model)
    let start = ContinuousClock.now
    let vectors = try await embedder.fullVectors(lines)
    let total = seconds(since: start)
    let data = try JSONSerialization.data(withJSONObject: vectors.map { $0.map(Double.init) })
    FileHandle.standardOutput.write(data)
    let stats = await embedder.statistics
    FileHandle.standardError.write(Data(String(
        format: "%d passages, %d tokens, width %d, load %.2f s, total %.2f s, peak memory %.0f MB\n",
        lines.count, stats.tokens, vectors.first?.count ?? 0, stats.loadSeconds, total, peakMemoryMB(),
    ).utf8))
    await embedder.unload()
}
