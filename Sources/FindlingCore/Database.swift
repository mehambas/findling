import Foundation
import CSQLite

enum SQLValue {
    case text(String)
    /// Raw UTF-8 bytes bound as text; used for exclusive upper bounds that are not valid UTF-8.
    case bytes([UInt8])
    case int(Int64)
    case double(Double)
}
extension SQLValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    init(stringLiteral value: String) { self = .text(value) }
    init(integerLiteral value: Int) { self = .int(Int64(value)) }
}

let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One SQLite connection. Each connection is owned by a single actor; WAL lets searches
/// read while the writer indexes.
final class Database {
    let handle: OpaquePointer
    private var statements: [String: OpaquePointer] = [:]

    init(path: String, readOnly: Bool = false) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw NSError(domain: "Findling", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open the catalog."])
        }
        handle = db
        sqlite3_busy_timeout(db, 5000)
        // A small page cache keeps resident memory bounded; the OS file cache does the rest.
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA journal_size_limit=67108864; PRAGMA cache_size=-8192; PRAGMA temp_store=FILE; PRAGMA mmap_size=0;")
        if readOnly { try execute("PRAGMA query_only=1") }
    }
    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close_v2(handle)
    }

    func failure() -> NSError {
        let code = sqlite3_errcode(handle)
        if code == SQLITE_INTERRUPT { return NSError(domain: "Findling", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Interrupted"]) }
        return NSError(domain: "Findling", code: Int(code), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
    }
    func execute(_ sql: String) throws { guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() } }

    /// Cached prepared statement; callers must not keep it beyond one `query` / `run`.
    private func prepared(_ sql: String, _ values: [SQLValue]) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
        } else {
            var created: OpaquePointer?
            guard sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &created, nil) == SQLITE_OK, let created else { throw failure() }
            statements[sql] = created
            statement = created
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, transient)
            case .bytes(let bytes): _ = bytes.withUnsafeBufferPointer { sqlite3_bind_text(statement, index, UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self), Int32($0.count), transient) }
            case .int(let number): sqlite3_bind_int64(statement, index, number)
            case .double(let number): sqlite3_bind_double(statement, index, number)
            }
        }
        return statement
    }
    private func finish(_ statement: OpaquePointer) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }
    /// Steps through rows until `row` returns false.
    func query(_ sql: String, _ values: [SQLValue] = [], row: (OpaquePointer) throws -> Bool) throws {
        let statement = try prepared(sql, values)
        defer { finish(statement) }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else { throw failure() }
            if try !row(statement) { return }
        }
    }
    func run(_ sql: String, _ values: [SQLValue] = []) throws {
        let statement = try prepared(sql, values)
        defer { finish(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    func scalar(_ sql: String, _ values: [SQLValue] = []) throws -> String? {
        var result: String?
        try query(sql, values) { result = Self.string($0, 0); return false }
        return result
    }
    var changes: Int { Int(sqlite3_changes(handle)) }
    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    static func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let text = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: text)
    }
    static func bytes(_ statement: OpaquePointer, _ column: Int32) -> [UInt8] {
        guard let text = sqlite3_column_text(statement, column) else { return [] }
        return Array(UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(statement, column))))
    }
    static let columns = "path,name,kind,project,modified"
    static func entry(_ statement: OpaquePointer, from column: Int32 = 0) -> Entry {
        Entry(path: string(statement, column), name: string(statement, column + 1), kind: string(statement, column + 2),
              project: string(statement, column + 3), modified: sqlite3_column_double(statement, column + 4))
    }

    func transaction<T>(_ work: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try work(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
}

enum CatalogPath {
    /// Foundation decomposes accented characters in `URL.path` while directory listings keep the
    /// file system's composed names; the catalog keys every path by its composed bytes.
    static func canonical(_ path: String) -> String {
        path.utf8.allSatisfy { $0 < 0x80 } ? path : path.precomposedStringWithCanonicalMapping
    }
    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return slash == path.startIndex ? (path == "/" ? "" : "/") : String(path[..<slash])
    }
    /// Directory lookups use a 64-bit FNV-1a hash instead of storing every parent path again.
    static func hash(_ path: String) -> Int64 {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in path.utf8 { value = (value ^ UInt64(byte)) &* 0x100000001b3 }
        return Int64(bitPattern: value)
    }
    /// `path` and its descendants: the path itself, then `path/` up to (excluding) `path0`.
    static func subtree(_ path: String) -> (exact: String, lower: String, upper: String) {
        path == "/" ? ("/", "/", "0") : (path, path + "/", path + "0")
    }
    static func isOrdered(_ a: String, before b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }
    /// Sorted, disjoint half-open ranges covering each path and its subtree. A path's own range
    /// and its subtree are separate because "/x-y" sorts between "/x" and "/x/".
    static func intervals(_ paths: [String]) -> [(lower: String, upper: String)] {
        let ranges = paths.flatMap { path -> [(lower: String, upper: String)] in
            let range = subtree(path)
            return [(range.exact, range.exact + "\u{1}"), (range.lower, range.upper)]
        }.sorted { isOrdered($0.lower, before: $1.lower) }
        var merged: [(lower: String, upper: String)] = []
        for range in ranges {
            if let last = merged.last, !isOrdered(last.upper, before: range.lower) {
                if isOrdered(last.upper, before: range.upper) { merged[merged.count - 1].upper = range.upper }
            } else {
                merged.append(range)
            }
        }
        return merged
    }
    /// Whether `path` equals or lies below one of `folders`.
    static func isCovered(_ path: String, by folders: Set<String>) -> Bool {
        if folders.contains(path) || folders.contains("/") { return true }
        var current = path
        while true {
            current = parent(of: current)
            if current.isEmpty || current == "/" { return false }
            if folders.contains(current) { return true }
        }
    }
}
