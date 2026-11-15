// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesStorage

/// What an update changed.
public struct IndexUpdate: Equatable, Sendable {
    public var indexed = 0
    public var renamed = 0
    public var removed = 0
    public var unchanged = 0

    public var changedAnything: Bool {
        indexed + renamed + removed > 0
    }
}

public extension SearchIndex {
    /// Brings the index up to date with the library: meetings whose files changed are indexed
    /// again, and meetings that are gone are dropped. Vectors are left for `embedMissing`.
    func update(library: MinutesLibrary) throws -> IndexUpdate {
        let known = try database.rows("SELECT id, folder, fingerprint FROM meetings") { row in
            (id: row.text(0), folder: row.text(1), fingerprint: row.text(2))
        }
        var saved = Dictionary(known.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = IndexUpdate()
        for entry in library.meetings() {
            try Task.checkCancellation()
            guard let metadata = entry.metadata, metadata.state == .complete, !metadata.isNewerThanThisApp else {
                continue
            }
            let id = metadata.id.uuidString
            let folderName = entry.folder.url.lastPathComponent
            let fingerprint = Self.fingerprint(of: entry.folder)
            let previous = saved.removeValue(forKey: id)
            if previous?.fingerprint == fingerprint {
                if previous?.folder == folderName {
                    result.unchanged += 1
                } else {
                    try database.run("UPDATE meetings SET folder = ? WHERE id = ?", .text(folderName), .text(id))
                    result.renamed += 1
                }
                continue
            }
            try index(entry.folder, metadata: metadata, fingerprint: fingerprint)
            result.indexed += 1
        }
        // Gone from the library: trashed, or moved out by hand.
        for id in saved.keys {
            try database.run("DELETE FROM meetings WHERE id = ?", .text(id))
            result.removed += 1
        }
        if result.changedAnything {
            vectors = nil
        }
        return result
    }

    /// A meeting's passages, replacing any it had. Vectors of passages whose text and meeting
    /// title haven't changed are kept, so editing one note doesn't embed the whole meeting again.
    private func index(_ folder: MeetingFolder, metadata: MeetingMetadata, fingerprint: String) throws {
        let chunks = MeetingChunker.chunks(
            transcript: try? folder.loadTranscript(),
            metadata: metadata,
            summary: folder.loadSummary(),
            notes: folder.loadNotes(),
            cleanedNotes: folder.loadCleanedNotes(),
        )
        let id = metadata.id.uuidString
        try database.transaction {
            let kept = try database.rows("""
            SELECT c.kind, c.text, m.title, v.model, v.vector FROM chunks c
            JOIN meetings m ON m.id = c.meeting_id JOIN vectors v ON v.chunk_id = c.id
            WHERE c.meeting_id = ?
            """, .text(id)) { row in
                (key: Self.vectorKey(kind: row.text(0), text: row.text(1), title: row.text(2)),
                 model: row.text(3), vector: row.blob(4))
            }
            let reusable = Dictionary(grouping: kept, by: \.key)
            try database.run("DELETE FROM meetings WHERE id = ?", .text(id))
            try database.run(
                "INSERT INTO meetings (id, folder, title, started_at, duration, fingerprint) VALUES (?, ?, ?, ?, ?, ?)",
                .text(id), .text(folder.url.lastPathComponent), .text(metadata.title),
                .double(metadata.startedAt.timeIntervalSince1970), .optional(metadata.durationSeconds),
                .text(fingerprint),
            )
            for chunk in chunks {
                try database.run(
                    "INSERT INTO chunks (meeting_id, kind, start, end, speakers, text) VALUES (?, ?, ?, ?, ?, ?)",
                    .text(id), .text(chunk.kind.rawValue), .optional(chunk.start), .optional(chunk.end),
                    .text(chunk.speakerColumn), .text(chunk.text),
                )
                let key = Self.vectorKey(kind: chunk.kind.rawValue, text: chunk.text, title: metadata.title)
                if let old = reusable[key]?.first {
                    try database.run(
                        "INSERT INTO vectors (chunk_id, model, vector) VALUES (?, ?, ?)",
                        .int(database.lastInsertRowID), .text(old.model), .blob(old.vector),
                    )
                }
            }
        }
    }

    private static func vectorKey(kind: String, text: String, title: String) -> String {
        "\(kind)\n\(title)\n\(text)"
    }

    /// The sizes and dates of the files a meeting's passages come from. Any change means the
    /// meeting is read again.
    static func fingerprint(of folder: MeetingFolder) -> String {
        let files = [
            folder.metadataURL, folder.transcriptJSON, folder.summaryFile,
            folder.notesFile, folder.noteTimesFile, folder.cleanedNotesFile,
        ]
        return files.map { url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, let date = values.contentModificationDate
            else {
                return "\(url.lastPathComponent):-"
            }
            return "\(url.lastPathComponent):\(size):\(date.timeIntervalSince1970)"
        }
        .joined(separator: "|")
    }
}
