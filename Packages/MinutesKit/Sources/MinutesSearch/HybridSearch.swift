// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesLLM

/// The best passage of a meeting that matched what's typed in the search field.
public struct MeetingMatch: Equatable, Sendable {
    public var meetingID: UUID
    public var hit: SearchHit
}

/// Reciprocal rank fusion: each list adds 1 / (k + rank) for every passage in it, so a passage
/// near the top of both lists comes first, without having to compare bm25 with cosine scores.
public enum RankFusion {
    /// Smaller than the usual 60, so the top of either list counts for more than a passage both
    /// lists rank in the middle. Meetings repeat the same words, like "remote" in every passage of
    /// a project, and then the middle of both lists is mostly noise. See docs/NOTES.md.
    public static let constant = 5.0

    public static func fuse(_ lists: [[Int64]]) -> [Int64] {
        var scores: [Int64: Double] = [:]
        var firstSeen: [Int64: Int] = [:]
        for list in lists {
            for (rank, id) in list.enumerated() {
                scores[id, default: 0] += 1 / (constant + Double(rank + 1))
                firstSeen[id] = min(firstSeen[id] ?? .max, rank)
            }
        }
        // Ties go to the passage ranked higher in any list, then to the older row, so results
        // don't shuffle between runs.
        return scores.keys.sorted { left, right in
            if scores[left] != scores[right] {
                return scores[left, default: 0] > scores[right, default: 0]
            }
            if firstSeen[left] != firstSeen[right] {
                return firstSeen[left, default: 0] < firstSeen[right, default: 0]
            }
            return left < right
        }
    }
}

private struct KeywordMatch {
    var id: Int64
    var meeting: UUID
    var snippet: String
}

/// Which kinds of matching a search uses. Only `minutes-llmcheck` asks for one side alone, to
/// measure what each adds.
public enum SearchMethod: String, CaseIterable, Sendable {
    case hybrid
    case keywords
    case meaning
}

public extension SearchIndex {
    /// Passages that answer a question, best first: keyword matches and, with an embedder,
    /// passages close in meaning, fused. Without vectors for the embedder, it's keywords only.
    func search(
        _ question: String,
        filter: SearchFilter = .everything,
        embedder: any EmbeddingProvider? = nil,
        limit: Int = 20,
        method: SearchMethod = .hybrid,
    ) async throws -> [SearchHit] {
        let depth = max(limit * 3, 50)
        let keyword = try FTSQuery.anyWord(question).map { query in
            try keywordMatches(query, filter: filter, limit: depth)
        } ?? []
        var lists = method == .meaning ? [] : [keyword.map(\.id)]
        if method != .keywords, let embedder, try hasVectors(for: embedder) {
            let query = try await embedder.embed(query: question)
            let table = try vectorTable(model: embedder.id, dimensions: embedder.dimensions)
            lists.append(table.nearest(to: query, filter: filter, limit: depth))
        }
        let ranked = Array(RankFusion.fuse(lists).prefix(limit))
        let snippets = Dictionary(keyword.map { ($0.id, $0.snippet) }, uniquingKeysWith: { first, _ in first })
        let byID = try hitsByID(ranked)
        return ranked.compactMap { id in
            byID[id].map { hit in
                var hit = hit
                hit.snippet = snippets[id]
                return hit
            }
        }
    }

    /// Meetings that hold every word typed, in any of their passages, with each one's best
    /// passage, best first. The last word matches as a prefix, so results come while it's typed.
    func matchingMeetings(_ text: String, limit: Int = 200) throws -> [MeetingMatch] {
        let terms = FTSQuery.typedTerms(text)
        guard !terms.isEmpty else {
            return []
        }
        var meetings: Set<UUID>?
        for term in terms {
            let found = try Set(database.rows("""
            SELECT DISTINCT c.meeting_id FROM chunks_fts JOIN chunks c ON c.id = chunks_fts.rowid
            WHERE chunks_fts MATCH ?
            """, .text(term)) { UUID(uuidString: $0.text(0)) }.compactMap(\.self))
            meetings = meetings.map { $0.intersection(found) } ?? found
            if meetings?.isEmpty == true {
                return []
            }
        }
        // The passage that matches most of the words best stands for its meeting.
        let matches = try keywordMatches(terms.joined(separator: " OR "), filter: SearchFilter(meetings: meetings),
                                         limit: 5000)
        var seen = Set<UUID>()
        var best: [KeywordMatch] = []
        for match in matches where !seen.contains(match.meeting) && best.count < limit {
            seen.insert(match.meeting)
            best.append(match)
        }
        let byID = try hitsByID(best.map(\.id))
        return best.compactMap { item in
            byID[item.id].map { hit in
                var hit = hit
                hit.snippet = item.snippet
                return MeetingMatch(meetingID: item.meeting, hit: hit)
            }
        }
    }

    /// All of one meeting's passages, in the order they come: transcript by time, then summary,
    /// cleaned notes and notes.
    func passages(of meeting: UUID) throws -> [SearchHit] {
        try database.rows(
            Self.hitColumns + " WHERE c.meeting_id = ? ORDER BY c.id",
            .text(meeting.uuidString),
            map: Self.hit,
        )
    }

    // MARK: - Pieces

    private func hasVectors(for embedder: any EmbeddingProvider) throws -> Bool {
        try !database.rows("SELECT 1 FROM vectors WHERE model = ? LIMIT 1", .text(embedder.id)) { _ in true }.isEmpty
    }

    private func keywordMatches(_ query: String, filter: SearchFilter, limit: Int) throws -> [KeywordMatch] {
        let meetings: SQLiteValue = filter.meetings.map { ids in
            .text("[" + ids.map { "\"\($0.uuidString)\"" }.joined(separator: ",") + "]")
        } ?? .null
        let lower = filter.dates?.lowerBound.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude
        let upper = filter.dates?.upperBound.timeIntervalSince1970 ?? Double.greatestFiniteMagnitude
        return try database.rows(
            Self.keywordSQL, .text(query), .double(lower), .double(upper), meetings, meetings, .int(Int64(limit)),
        ) { row in
            KeywordMatch(id: row.int(0), meeting: UUID(uuidString: row.text(1)) ?? UUID(), snippet: row.text(2))
        }
    }

    private static let keywordSQL = """
    SELECT c.id, c.meeting_id, snippet(chunks_fts, 0, char(1), char(2), '…', 24)
    FROM chunks_fts JOIN chunks c ON c.id = chunks_fts.rowid JOIN meetings m ON m.id = c.meeting_id
    WHERE chunks_fts MATCH ? AND m.started_at >= ? AND m.started_at < ?
      AND (? IS NULL OR c.meeting_id IN (SELECT value FROM json_each(?)))
    ORDER BY bm25(chunks_fts, 1.0, 0.5), c.id LIMIT ?
    """

    private func hitsByID(_ ids: [Int64]) throws -> [Int64: SearchHit] {
        guard !ids.isEmpty else {
            return [:]
        }
        let list = "[" + ids.map(String.init).joined(separator: ",") + "]"
        let hits = try database.rows(
            Self.hitColumns + " WHERE c.id IN (SELECT value FROM json_each(?))",
            .text(list),
            map: Self.hit,
        )
        return Dictionary(hits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static let hitColumns = """
    SELECT c.id, c.meeting_id, m.folder, m.title, m.started_at, c.kind, c.start, c.end, c.speakers, c.text
    FROM chunks c JOIN meetings m ON m.id = c.meeting_id
    """

    private static func hit(_ row: SQLiteRow) -> SearchHit {
        let speakers = row.text(8)
        return SearchHit(
            id: row.int(0),
            meetingID: UUID(uuidString: row.text(1)) ?? UUID(),
            folderName: row.text(2),
            meetingTitle: row.text(3),
            meetingDate: Date(timeIntervalSince1970: row.double(4) ?? 0),
            chunk: SearchChunk(
                kind: SearchChunk.Kind(rawValue: row.text(5)) ?? .transcript,
                start: row.double(6),
                end: row.double(7),
                speakers: speakers.isEmpty ? [] : speakers.components(separatedBy: "\n"),
                text: row.text(9),
            ),
            snippet: nil,
        )
    }
}
