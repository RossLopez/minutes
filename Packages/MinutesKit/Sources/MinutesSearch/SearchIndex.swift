// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesStorage
import SQLite3

/// One passage found by a search, with the meeting it's from.
public struct SearchHit: Identifiable, Equatable, Sendable {
    /// The passage's row, stable until its meeting is indexed again.
    public var id: Int64
    public var meetingID: UUID
    /// The meeting's folder name in `Meetings/`.
    public var folderName: String
    public var meetingTitle: String
    public var meetingDate: Date
    public var chunk: SearchChunk
    /// The passage cut down around the words that matched, which sit between U+0001 and U+0002.
    /// Nil when only the meaning matched.
    public var snippet: String?
}

/// Which meetings a search looks in.
public struct SearchFilter: Equatable, Sendable {
    /// Meetings that started in this range.
    public var dates: Range<Date>?
    /// Only these meetings, when set.
    public var meetings: Set<UUID>?

    public init(dates: Range<Date>? = nil, meetings: Set<UUID>? = nil) {
        self.dates = dates
        self.meetings = meetings
    }

    public static let everything = SearchFilter()
}

public struct SearchIndexStatus: Equatable, Sendable {
    public var meetings: Int
    public var chunks: Int
    /// Passages with a vector from the embedding model asked about.
    public var embedded: Int
}

/// `.minutes/index.sqlite`: every meeting's passages, for searching by keyword and by meaning.
///
/// It's a cache of the files in `Meetings/`, so anything wrong with it is fixed by deleting it
/// and building it again. SQLite calls block, so the actor runs on a queue of its own.
public actor SearchIndex {
    /// Raised whenever the tables change, which makes an older index be built again.
    static let schemaVersion = 1

    public nonisolated let file: URL
    let database: SQLiteConnection
    /// Every vector from one model, kept in memory once searched, since they're read in full.
    var vectors: VectorTable?

    private let queue = DispatchSerialQueue(label: "io.github.rosslopez.minutes.search")
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    public init(file: URL) throws {
        self.file = file
        database = try Self.open(file)
    }

    public init(library: MinutesLibrary) throws {
        try self.init(file: library.internalFolder.appendingPathComponent("index.sqlite"))
    }

    public func status(model: String?) throws -> SearchIndexStatus {
        let counts = try database.rows("""
        SELECT (SELECT count(*) FROM meetings), (SELECT count(*) FROM chunks),
               (SELECT count(*) FROM vectors WHERE model = ?)
        """, .text(model ?? "")) { row in
            SearchIndexStatus(meetings: Int(row.int(0)), chunks: Int(row.int(1)), embedded: Int(row.int(2)))
        }
        return counts.first ?? SearchIndexStatus(meetings: 0, chunks: 0, embedded: 0)
    }

    /// Empties the index, for Rebuild Index. The next update fills it again.
    public func removeAll() throws {
        try database.transaction {
            try database.execute("DELETE FROM meetings")
        }
        vectors = nil
    }

    // MARK: - Opening

    private static func open(_ file: URL) throws -> SQLiteConnection {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let connection = try SQLiteConnection(url: file)
            if try version(of: connection) == schemaVersion {
                try prepare(connection)
                return connection
            }
        } catch let error as SQLiteError where error.isDamaged {
            // Made again below.
        }
        // From another version, or damaged: it's only a cache, so start again.
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: file.path + suffix))
        }
        let connection = try SQLiteConnection(url: file)
        try prepare(connection)
        try connection.execute(schema)
        try connection.execute("PRAGMA user_version = \(schemaVersion)")
        return connection
    }

    private static func version(of connection: SQLiteConnection) throws -> Int {
        let tables = try connection.rows("SELECT count(*) FROM sqlite_master") { $0.int(0) }
        let version = try connection.rows("PRAGMA user_version") { $0.int(0) }
        // An empty file is a new index, and gets the schema below.
        return tables.first == 0 ? -1 : Int(version.first ?? 0)
    }

    private static func prepare(_ connection: SQLiteConnection) throws {
        try connection.execute("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA synchronous = NORMAL")
    }

    private static let schema = """
    CREATE TABLE meetings (
        id TEXT PRIMARY KEY,
        folder TEXT NOT NULL,
        title TEXT NOT NULL,
        started_at REAL NOT NULL,
        duration REAL,
        fingerprint TEXT NOT NULL
    );
    CREATE TABLE chunks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
        kind TEXT NOT NULL,
        start REAL,
        end REAL,
        speakers TEXT NOT NULL,
        text TEXT NOT NULL
    );
    CREATE INDEX chunks_by_meeting ON chunks(meeting_id);
    CREATE VIRTUAL TABLE chunks_fts USING fts5(
        text, speakers, content = 'chunks', content_rowid = 'id',
        tokenize = 'porter unicode61 remove_diacritics 2'
    );
    CREATE TRIGGER chunks_added AFTER INSERT ON chunks BEGIN
        INSERT INTO chunks_fts(rowid, text, speakers) VALUES (new.id, new.text, new.speakers);
    END;
    CREATE TRIGGER chunks_removed AFTER DELETE ON chunks BEGIN
        INSERT INTO chunks_fts(chunks_fts, rowid, text, speakers) VALUES ('delete', old.id, old.text, old.speakers);
    END;
    CREATE TABLE vectors (
        chunk_id INTEGER PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE,
        model TEXT NOT NULL,
        vector BLOB NOT NULL
    );
    CREATE INDEX vectors_by_model ON vectors(model);
    """
}

extension SearchChunk {
    /// How speakers are kept in the index: one column FTS can search.
    var speakerColumn: String {
        speakers.joined(separator: "\n")
    }
}
