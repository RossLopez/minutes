// SPDX-License-Identifier: GPL-3.0-or-later

import Accelerate
import Foundation
import MinutesLLM

/// Every vector from one model, in one block of memory, so a search is one matrix product.
struct VectorTable {
    var model: String
    var dimensions: Int
    var chunkIDs: [Int64] = []
    var meetingIDs: [UUID] = []
    var dates: [Double] = []
    /// Row after row, `dimensions` values each.
    var values: [Float] = []

    /// The closest passages that pass the filter, best first.
    func nearest(to query: [Float], filter: SearchFilter, limit: Int) -> [Int64] {
        guard !chunkIDs.isEmpty, query.count == dimensions else {
            return []
        }
        var scores = [Float](repeating: 0, count: chunkIDs.count)
        vDSP_mmul(values, 1, query, 1, &scores, 1, vDSP_Length(chunkIDs.count), 1, vDSP_Length(dimensions))
        let lower = filter.dates?.lowerBound.timeIntervalSince1970 ?? -.infinity
        let upper = filter.dates?.upperBound.timeIntervalSince1970 ?? .infinity
        return scores.indices
            .filter { row in
                let inMeetings = filter.meetings?.contains(meetingIDs[row]) ?? true
                return inMeetings && dates[row] >= lower && dates[row] < upper
            }
            .sorted { scores[$0] > scores[$1] }
            .prefix(limit)
            .map { chunkIDs[$0] }
    }
}

public extension SearchIndex {
    /// Embeds passages that don't have a vector from this model yet, a batch at a time, newest
    /// meetings first, and drops vectors from other models. Returns how many it embedded.
    /// Cancelling stops it between batches, keeping what's done.
    ///
    /// - Parameter maxBatches: stop after this many, so a caller can pause between them.
    @discardableResult
    func embedMissing(
        using embedder: any EmbeddingProvider,
        batchSize: Int = 32,
        maxBatches: Int = .max,
    ) async throws -> Int {
        try database.run("DELETE FROM vectors WHERE model != ?", .text(embedder.id))
        var total = 0
        for _ in 0 ..< maxBatches {
            try Task.checkCancellation()
            let batch = try database.rows("""
            SELECT c.id, m.title, c.text FROM chunks c JOIN meetings m ON m.id = c.meeting_id
            WHERE NOT EXISTS (SELECT 1 FROM vectors v WHERE v.chunk_id = c.id)
            ORDER BY m.started_at DESC, c.id LIMIT ?
            """, .int(Int64(batchSize))) { row in
                (id: row.int(0), document: EmbeddingDocument(title: row.text(1), text: row.text(2)))
            }
            guard !batch.isEmpty else {
                break
            }
            // Other calls can run while this waits, and may remove these passages.
            let embedded = try await embedder.embed(documents: batch.map(\.document))
            try database.transaction {
                for (item, vector) in zip(batch, embedded) {
                    try database.run("""
                    INSERT OR REPLACE INTO vectors (chunk_id, model, vector)
                    SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM chunks WHERE id = ?)
                    """, .int(item.id), .text(embedder.id), .blob(Self.data(vector)), .int(item.id))
                }
            }
            total += batch.count
            vectors = nil
        }
        return total
    }

    internal func vectorTable(model: String, dimensions: Int) throws -> VectorTable {
        if let vectors, vectors.model == model, vectors.dimensions == dimensions {
            return vectors
        }
        var table = VectorTable(model: model, dimensions: dimensions)
        _ = try database.rows("""
        SELECT v.chunk_id, c.meeting_id, m.started_at, v.vector FROM vectors v
        JOIN chunks c ON c.id = v.chunk_id JOIN meetings m ON m.id = c.meeting_id WHERE v.model = ?
        """, .text(model)) { row in
            let blob = row.blob(3)
            guard blob.count == dimensions * MemoryLayout<Float>.size,
                  let meeting = UUID(uuidString: row.text(1))
            else {
                return
            }
            table.chunkIDs.append(row.int(0))
            table.meetingIDs.append(meeting)
            table.dates.append(row.double(2) ?? 0)
            blob.withUnsafeBytes { table.values.append(contentsOf: $0.bindMemory(to: Float.self)) }
        }
        vectors = table
        return table
    }

    private static func data(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
