// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SQLite3

/// A failed SQLite call. Only the result code is kept: SQLite's own messages can quote a search,
/// and errors end up in logs.
public struct SQLiteError: Error, Equatable, Sendable {
    public let code: Int32

    /// The database file isn't one, or is damaged, so it should be made again.
    var isDamaged: Bool {
        let primary = code & 0xFF
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
    }
}

enum SQLiteValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null

    static func optional(_ value: Double?) -> SQLiteValue {
        value.map(SQLiteValue.double) ?? .null
    }
}

/// One connection, used from one actor. Statements are prepared once and kept.
final class SQLiteConnection {
    private let handle: OpaquePointer
    private var statements: [String: SQLiteStatement] = [:]

    init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let result = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            sqlite3_close_v2(handle)
            throw SQLiteError(code: result)
        }
        self.handle = handle
        sqlite3_extended_result_codes(handle, 1)
    }

    deinit {
        statements.removeAll()
        sqlite3_close_v2(handle)
    }

    /// Runs statements that take no values and return no rows, like the schema.
    func execute(_ sql: String) throws {
        try check(sqlite3_exec(handle, sql, nil, nil, nil))
    }

    func statement(_ sql: String) throws -> SQLiteStatement {
        if let cached = statements[sql] {
            return cached
        }
        var pointer: OpaquePointer?
        try check(sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &pointer, nil))
        guard let pointer else {
            throw SQLiteError(code: SQLITE_MISUSE)
        }
        let statement = SQLiteStatement(pointer, connection: self)
        statements[sql] = statement
        return statement
    }

    func run(_ sql: String, _ values: SQLiteValue...) throws {
        try statement(sql).run(values)
    }

    func rows<T>(_ sql: String, _ values: SQLiteValue..., map: (SQLiteRow) throws -> T) throws -> [T] {
        try statement(sql).rows(values, map: map)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    func check(_ result: Int32) throws {
        guard result == SQLITE_OK || result == SQLITE_ROW || result == SQLITE_DONE else {
            throw SQLiteError(code: sqlite3_extended_errcode(handle))
        }
    }
}

/// SQLite copies bound text and blobs right away, so Swift's buffers can go.
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteStatement {
    private let handle: OpaquePointer
    private unowned let connection: SQLiteConnection

    init(_ handle: OpaquePointer, connection: SQLiteConnection) {
        self.handle = handle
        self.connection = connection
    }

    deinit {
        sqlite3_finalize(handle)
    }

    func run(_ values: [SQLiteValue]) throws {
        try bind(values)
        defer {
            sqlite3_reset(handle)
        }
        while try step() {}
    }

    func rows<T>(_ values: [SQLiteValue], map: (SQLiteRow) throws -> T) throws -> [T] {
        try bind(values)
        defer {
            sqlite3_reset(handle)
        }
        var result: [T] = []
        let row = SQLiteRow(handle: handle)
        while try step() {
            try result.append(map(row))
        }
        return result
    }

    private func step() throws -> Bool {
        let result = sqlite3_step(handle)
        try connection.check(result)
        return result == SQLITE_ROW
    }

    private func bind(_ values: [SQLiteValue]) throws {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result = switch value {
            case let .int(number):
                sqlite3_bind_int64(handle, index, number)
            case let .double(number):
                sqlite3_bind_double(handle, index, number)
            case let .text(text):
                sqlite3_bind_text(handle, index, text, -1, transient)
            case let .blob(data):
                data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(handle, index, bytes.baseAddress, Int32(bytes.count), transient)
                }
            case .null:
                sqlite3_bind_null(handle, index)
            }
            try connection.check(result)
        }
    }
}

/// The current row of a statement. Only valid inside `rows`' closure.
struct SQLiteRow {
    fileprivate let handle: OpaquePointer

    func int(_ column: Int32) -> Int64 {
        sqlite3_column_int64(handle, column)
    }

    func double(_ column: Int32) -> Double? {
        sqlite3_column_type(handle, column) == SQLITE_NULL ? nil : sqlite3_column_double(handle, column)
    }

    func text(_ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(handle, column) else {
            return ""
        }
        return String(cString: pointer)
    }

    func blob(_ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(handle, column))
        guard count > 0, let pointer = sqlite3_column_blob(handle, column) else {
            return Data()
        }
        return Data(bytes: pointer, count: count)
    }
}
