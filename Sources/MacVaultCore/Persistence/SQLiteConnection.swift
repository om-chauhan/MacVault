import Foundation
import CSQLite

public enum SQLValue: Sendable, Equatable {
    case integer(Int64)
    case real(Double)
    case text(String)
    case null

    public static func int(_ v: Int64?) -> SQLValue { v.map(SQLValue.integer) ?? .null }
    public static func int(_ v: Int?) -> SQLValue { v.map { .integer(Int64($0)) } ?? .null }
    public static func string(_ v: String?) -> SQLValue { v.map(SQLValue.text) ?? .null }
    public static func date(_ v: Date?) -> SQLValue { v.map { .text(Timestamp.string($0)) } ?? .null }
    public static func bool(_ v: Bool?) -> SQLValue { v.map { .integer($0 ? 1 : 0) } ?? .null }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin wrapper over a single SQLite connection. Not thread-safe on its own;
/// `Store` (an actor) owns the only instance.
final class SQLiteConnection {
    private(set) var handle: OpaquePointer?

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw DatabaseError.openFailed(code: rc, message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 5_000)
        try execute("PRAGMA foreign_keys = ON;")
        if path != ":memory:" {
            try execute("PRAGMA journal_mode = WAL;")
        }
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    var lastErrorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        if rc != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorPointer)
            throw DatabaseError.stepFailed(code: rc, message: message)
        }
    }

    /// Runs a statement that returns no rows.
    func run(_ sql: String, _ values: [SQLValue] = []) throws {
        let statement = try prepare(sql)
        try statement.bind(values)
        _ = try statement.step()
    }

    /// Runs a query and maps each row.
    func query<T>(_ sql: String, _ values: [SQLValue] = [], map: (Row) throws -> T) throws -> [T] {
        let statement = try prepare(sql)
        try statement.bind(values)
        var rows: [T] = []
        while try statement.step() {
            rows.append(try map(Row(statement: statement)))
        }
        return rows
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw DatabaseError.prepareFailed(code: rc, message: lastErrorMessage, sql: sql)
        }
        return Statement(stmt: stmt, connection: self)
    }

    /// Runs `body` in a transaction; rolls back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let value = try body()
            try execute("COMMIT;")
            return value
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    var changes: Int { Int(sqlite3_changes(handle)) }
}

final class Statement {
    private let stmt: OpaquePointer
    private unowned let connection: SQLiteConnection

    init(stmt: OpaquePointer, connection: SQLiteConnection) {
        self.stmt = stmt
        self.connection = connection
    }

    deinit { sqlite3_finalize(stmt) }

    func bind(_ values: [SQLValue]) throws {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .integer(let v): rc = sqlite3_bind_int64(stmt, index, v)
            case .real(let v): rc = sqlite3_bind_double(stmt, index, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, index, v, -1, SQLITE_TRANSIENT)
            case .null: rc = sqlite3_bind_null(stmt, index)
            }
            guard rc == SQLITE_OK else {
                throw DatabaseError.stepFailed(code: rc, message: connection.lastErrorMessage)
            }
        }
    }

    /// Returns true when a row is available.
    func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw DatabaseError.stepFailed(code: rc, message: connection.lastErrorMessage)
        }
    }

    fileprivate var raw: OpaquePointer { stmt }
}

struct Row {
    fileprivate let statement: Statement

    private var stmt: OpaquePointer { statement.raw }

    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }

    func int64(_ i: Int32) -> Int64? { isNull(i) ? nil : sqlite3_column_int64(stmt, i) }
    func int(_ i: Int32) -> Int? { int64(i).map(Int.init) }
    func bool(_ i: Int32) -> Bool? { int64(i).map { $0 != 0 } }

    func string(_ i: Int32) -> String? {
        guard !isNull(i), let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }

    func date(_ i: Int32) -> Date? { string(i).flatMap(Timestamp.date) }

    func requiredString(_ i: Int32, _ column: String) throws -> String {
        guard let v = string(i) else { throw DatabaseError.invalidValue(column: column) }
        return v
    }

    func requiredDate(_ i: Int32, _ column: String) throws -> Date {
        guard let v = date(i) else { throw DatabaseError.invalidValue(column: column) }
        return v
    }
}
