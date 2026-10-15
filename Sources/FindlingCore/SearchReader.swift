import Foundation
import CSQLite

public struct SearchRequest: Sendable {
    public var query: String
    public var preferences: [String: Preference]
    public var kind: String
    public var folder: String?
    public var excludedPaths: [String]
    public var roots: [String]
    /// Records searched in addition to the catalog, such as the running app itself.
    public var extra: [Entry]
    /// Names Finder shows instead of the file name in the user's languages, by path, the shown
    /// one first. The file name and every listed name are searched; hits carry the shown name.
    public var aliases: [String: [String]]
    public var now: Double
    public init(query: String, preferences: [String: Preference] = [:], kind: String = "Tümü", folder: String? = nil, excludedPaths: [String] = [],
                roots: [String], extra: [Entry] = [], aliases: [String: [String]] = [:], now: Double = Date().timeIntervalSince1970) {
        self.query = query; self.preferences = preferences; self.kind = kind; self.folder = folder
        self.excludedPaths = excludedPaths; self.roots = roots; self.extra = extra; self.aliases = aliases; self.now = now
    }
}

/// Stops a running statement when its task is cancelled or a scan exceeds its budget.
private final class Interrupter {
    var budget = Int.max
    var exhausted = false
}

/// Searches the catalog on its own connection. Each text tier selects its candidates through an
/// index, keeps the best 80 in the order `SearchIndex` would produce, and later tiers are skipped
/// once no record without a stored preference could still rank in.
public actor SearchReader {
    private let db: Database
    private let interrupter = Interrupter()
    /// Above this many candidates a tier is read in score order (projects, apps, recent, path order)
    /// instead of ranking every candidate.
    var directLimit = 20_000
    /// Statement steps (in units of 1,000 SQLite instructions) allowed for a path-order scan.
    var scanBudget = 4_000

    public init(path: String) throws {
        db = try Database(path: path, readOnly: true)
        sqlite3_progress_handler(db.handle, 1000, { context in
            let interrupter = Unmanaged<Interrupter>.fromOpaque(context!).takeUnretainedValue()
            if Task.isCancelled { return 1 }
            interrupter.budget -= 1
            if interrupter.budget < 0 { interrupter.exhausted = true; return 1 }
            return 0
        }, Unmanaged.passUnretained(interrupter).toOpaque())
        sqlite3_create_function_v2(db.handle, "findling_normalize", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, _, arguments in
            guard let arguments, let text = sqlite3_value_text(arguments[0]) else { sqlite3_result_null(context); return }
            sqlite3_result_text(context, Search.normalize(String(cString: text)), -1, transient)
        }, nil, nil, nil)
        sqlite3_create_function_v2(db.handle, "findling_letters", 3, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, _, arguments in
            guard let arguments, let text = sqlite3_value_text(arguments[0]), let needle = sqlite3_value_text(arguments[2]) else { sqlite3_result_int(context, 0); return }
            let stem = Int(sqlite3_value_int(arguments[1]))
            let query = UnsafeBufferPointer(start: needle, count: Int(sqlite3_value_bytes(arguments[2])))
            var cursor = 0
            if !query.isEmpty {
                for byte in UnsafeBufferPointer(start: text, count: min(stem, Int(sqlite3_value_bytes(arguments[0])))) where byte == query[cursor] {
                    cursor += 1
                    if cursor == query.count { break }
                }
            }
            sqlite3_result_int(context, cursor == query.count ? 1 : 0)
        }, nil, nil, nil)
    }

    public func count() throws -> Int { Int(try db.scalar("SELECT count(*) FROM entries") ?? "0") ?? 0 }
    /// Records at `root` and below, read as a range of the path index.
    public func count(under root: String) throws -> Int {
        interrupter.budget = .max
        let path = SearchScope.standardized(root)
        guard path != "/" else { return try count() }
        return Int(try db.scalar("SELECT count(*) FROM entries WHERE path = ? OR (path >= ? AND path < ?)",
                                 [.text(path), .text(path + "/"), .text(path + "0")]) ?? "0") ?? 0
    }
    /// Whether a project or an app exists; read from the partial kind index.
    public func contains(kind: String) throws -> Bool {
        interrupter.budget = .max
        return try db.scalar("SELECT 1 FROM entries e INDEXED BY entries_kind WHERE \(projectOrApp) AND e.kind = ? LIMIT 1", [.text(kind)]) != nil
    }
    /// Paths of projects or apps, the records the partial kind index covers.
    public func paths(of kind: String) throws -> [String] {
        interrupter.budget = .max
        var paths: [String] = []
        try db.query("SELECT e.path FROM entries e INDEXED BY entries_kind WHERE \(projectOrApp) AND e.kind = ?", [.text(kind)]) {
            paths.append(Database.string($0, 0)); return true
        }
        return paths
    }
    func configure(directLimit: Int, scanBudget: Int) { self.directLimit = directLimit; self.scanBudget = scanBudget }

    public func search(_ request: SearchRequest, partial: (@Sendable ([Hit]) -> Void)? = nil) throws -> [Hit] {
        interrupter.budget = .max
        do {
            var run = try Run(request: request, db: db, interrupter: interrupter, directLimit: directLimit, scanBudget: scanBudget)
            try run.execute(partial: partial)
            return run.best.hits
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}

private let columns = "e.path,e.name,e.kind,e.project,e.modified,e.nname,e.nproject"
private let kindBonus = "CASE e.kind WHEN 'Projeler' THEN 45.0 WHEN 'Uygulamalar' THEN 35.0 ELSE 0.0 END"
private let otherKinds = "+e.kind NOT IN ('Projeler','Uygulamalar')"
/// Matches the partial kind index's condition, which `INDEXED BY entries_kind` requires in the query.
private let projectOrApp = "e.kind IN ('Projeler','Uygulamalar')"

private struct Clause {
    var sql: String
    var values: [SQLValue]
    init(_ sql: String, _ values: [SQLValue] = []) { self.sql = sql; self.values = values }
    static func && (a: Clause, b: Clause) -> Clause { Clause("(\(a.sql)) AND (\(b.sql))", a.values + b.values) }
    static prefix func ! (a: Clause) -> Clause { Clause("NOT (\(a.sql))", a.values) }
    static func all(_ clauses: [Clause], joinedBy separator: String) -> Clause {
        Clause(clauses.map { "(\($0.sql))" }.joined(separator: " \(separator) "), clauses.flatMap(\.values))
    }
    /// Filters only; the unary `+` keeps SQLite from choosing the path index for them.
    static func subtree(_ path: String) -> Clause {
        let range = CatalogPath.subtree(path)
        return Clause("+e.path = ? OR (+e.path >= ? AND +e.path < ?)", [.text(range.exact), .text(range.lower), .text(range.upper)])
    }
}

/// Where a tier's candidates come from when they are few enough to rank all of them.
private enum Source {
    case all
    case index(Clause)
    case fts(String)
    case ranges([(String, String)])
    /// A name-only condition checked on the name index alone, without reading the table.
    case names(Clause)
    case rowids([Int64])
}

private struct Run {
    let request: SearchRequest
    let db: Database
    let interrupter: Interrupter
    let directLimit: Int
    let scanBudget: Int
    let context: RankContext
    var best = TopHits()
    var seen: Set<String> = []
    let filter: Clause
    let recency: Clause
    let q: String
    let qBytes: [UInt8]

    init(request: SearchRequest, db: Database, interrupter: Interrupter, directLimit: Int, scanBudget: Int) throws {
        self.request = request; self.db = db; self.interrupter = interrupter; self.directLimit = directLimit; self.scanBudget = scanBudget
        context = RankContext(query: request.query, preferences: request.preferences, kind: request.kind, now: request.now,
                              folder: request.folder, excludedPaths: request.excludedPaths, roots: request.roots)
        q = context.normalized
        qBytes = context.q
        recency = Clause("max(0.0, 10.0 - max(0.0, ? - e.modified) / 86400.0)", [.double(request.now)])
        var parts: [Clause] = []
        if request.kind != "Tümü" { parts.append(Clause("e.kind = ?", [.text(request.kind)])) }
        // Scope paths arrive in whatever form the settings hold; the SQL ranges compare bytes.
        if let folder = request.folder.map(CatalogPath.canonical) {
            // The plain range lets SQLite walk the path index inside the folder.
            parts.append(Clause("e.path >= ? AND e.path < ?", [.text(folder), .text(CatalogPath.subtree(folder).upper)]) && .subtree(folder))
        }
        parts.append(request.roots.isEmpty ? Clause("0") : .all(request.roots.map { Clause.subtree(CatalogPath.canonical($0)) }, joinedBy: "OR"))
        parts += request.excludedPaths.map { !Clause.subtree(CatalogPath.canonical($0)) }
        // Records evaluated in Swift: stored preferences can outrank every tier, and localized
        // names match outside the name index.
        let handled = (Array(request.preferences.keys) + request.extra.map(\.path) + request.aliases.keys).map(CatalogPath.canonical)
        if !handled.isEmpty {
            let json = String(decoding: try JSONEncoder().encode(handled), as: UTF8.self)
            parts.append(Clause("+e.path NOT IN (SELECT value FROM json_each(?))", [.text(json)]))
        }
        filter = .all(parts, joinedBy: "AND")
    }

    mutating func execute(partial: (@Sendable ([Hit]) -> Void)?) throws {
        try evaluateHandled()
        // Without roots nothing can match; a constant-false filter would also leave SQLite
        // unable to plan the forced partial kind index.
        guard !request.roots.isEmpty else { return }
        var published: [String] = []
        if q.isEmpty {
            try decomposed(tier: .everything, predicate: Clause("1"), base: 0, source: .all)
            return
        }
        let stages: [(MatchTier, Double)] = [(.exact, 1000), (.prefix, 800), (.contains, 650), (.nameOrProject, 430), (.path, 180)]
        for (index, (tier, base)) in stages.enumerated() {
            try Task.checkCancellation()
            try stage(tier, base: base)
            let next = index + 1 < stages.count ? stages[index + 1].1 : 100
            if best.excludes(score: next + 55) { return }
            if let partial, best.hits.map(\.id) != published {
                published = best.hits.map(\.id)
                partial(best.hits)
            }
        }
        if context.allowsLetters { try letters() }
    }

    // MARK: Predicates

    private var exact: Clause {
        Clause("e.nname >= ? AND e.nname < ? AND (e.nname = ? OR (e.stem = ? AND e.nname >= ?))",
               [.text(q), .text(q + "/"), .text(q), .int(Int64(qBytes.count)), .text(q + ".")])
    }
    private var prefix: Clause {
        var upper = qBytes
        upper[upper.count - 1] += 1
        return Clause("e.nname >= ? AND e.nname < ?", [.text(q), .bytes(upper)])
    }
    private var contains: Clause { Clause("instr(e.nname, ?) > 0", [.text(q)]) }
    private var nameOrProject: Clause {
        .all(context.tokens.map { token in
            let text = String(decoding: token, as: UTF8.self)
            return Clause("instr(e.nname, ?) > 0 OR instr(e.nproject, ?) > 0", [.text(text), .text(text)])
        }, joinedBy: "AND")
    }
    private var path: Clause {
        .all(context.tokens.map { Clause("instr(findling_normalize(e.path), ?) > 0", [.text(String(decoding: $0, as: UTF8.self))]) }, joinedBy: "AND")
    }
    private var lettersMatch: Clause { Clause("findling_letters(e.nname, e.stem, ?)", [.text(q)]) }
    private static func phrase(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    private static func ftsUsable(_ text: String) -> Bool { text.unicodeScalars.count >= 3 }

    // MARK: Stages

    private mutating func stage(_ tier: MatchTier, base: Double) throws {
        switch tier {
        case .exact:
            try direct(predicate: exact, base: base, source: .all)
        case .prefix:
            try ranked(tier: tier, predicate: prefix && !exact, base: base, source: .index(prefix))
        case .contains:
            let source: Source = Self.ftsUsable(q) ? .fts("nname : " + Self.phrase(q)) : .names(contains)
            try ranked(tier: tier, predicate: contains && !prefix, base: base, source: source)
        case .nameOrProject:
            let indexed = context.tokens.map { String(decoding: $0, as: UTF8.self) }.filter(Self.ftsUsable)
            // A single token already failed to match names; only projects can match it here.
            let columns = context.tokens.count == 1 ? "nproject" : "{nname nproject}"
            let source: Source = indexed.isEmpty ? .all : .fts(indexed.map { "\(columns) : " + Self.phrase($0) }.joined(separator: " AND "))
            try ranked(tier: tier, predicate: nameOrProject && !contains, base: base, source: source)
        case .path:
            try ranked(tier: tier, predicate: path && !nameOrProject && !contains, base: base, source: try anchors())
        default:
            break
        }
    }

    /// Ranks a tier's candidates directly when there are few, otherwise in score order.
    private mutating func ranked(tier: MatchTier, predicate: Clause, base: Double, source: Source) throws {
        if case .names(let clause) = source {
            // One pass over the name index either yields the few candidates or shows there are many.
            var ids: [Int64] = []
            try db.query("SELECT e.id FROM entries e INDEXED BY entries_nname WHERE \(clause.sql) LIMIT ?", clause.values + [.int(Int64(directLimit + 1))]) {
                ids.append(sqlite3_column_int64($0, 0)); return true
            }
            if ids.count <= directLimit { return try direct(predicate: predicate, base: base, source: .rowids(ids)) }
        } else if try candidates(source, atMost: directLimit) <= directLimit {
            return try direct(predicate: predicate, base: base, source: source)
        }
        try decomposed(tier: tier, predicate: predicate, base: base, source: source)
    }

    private func candidates(_ source: Source, atMost limit: Int) throws -> Int {
        let sql: String
        var values: [SQLValue] = []
        switch source {
        case .all, .names: return Int.max
        case .rowids(let ids): return ids.count
        case .index(let clause): sql = "SELECT 1 FROM entries e WHERE \(clause.sql)"; values = clause.values
        case .fts(let match): sql = "SELECT rowid FROM names WHERE names MATCH ?"; values = [.text(match)]
        case .ranges(let ranges): sql = "SELECT 1 FROM json_each(?) r JOIN entries e ON e.path >= r.value ->> 0 AND e.path < r.value ->> 1"; values = [try Self.json(ranges)]
        }
        return Int(try db.scalar("SELECT count(*) FROM (\(sql) LIMIT ?)", values + [.int(Int64(limit + 1))]) ?? "0") ?? 0
    }

    private static func json(_ ranges: [(String, String)]) throws -> SQLValue {
        .text(String(decoding: try JSONEncoder().encode(ranges.map { [$0.0, $0.1] }), as: UTF8.self))
    }

    private func score(base: Double) -> Clause {
        Clause("((? + \(kindBonus)) + \(recency.sql))", [.double(base)] + recency.values)
    }

    /// Ranks every candidate of the source in SQL and keeps the best 80.
    private mutating func direct(predicate: Clause, base: Double, source: Source, extra: Clause = Clause("1"), order: Clause? = nil) throws {
        let condition = predicate && extra && filter
        let order = order ?? Clause("\(score(base: base).sql) DESC, e.path", score(base: base).values)
        let limit: [SQLValue] = [.int(Int64(TopHits.limit))]
        switch source {
        case .all:
            try evaluate("SELECT \(columns) FROM entries e WHERE \(condition.sql) ORDER BY \(order.sql) LIMIT ?", condition.values + order.values + limit)
        case .index(let clause):
            let indexed = clause && condition
            try evaluate("SELECT \(columns) FROM entries e WHERE \(indexed.sql) ORDER BY \(order.sql) LIMIT ?", indexed.values + order.values + limit)
        case .fts(let match):
            try evaluate("SELECT \(columns) FROM names JOIN entries e ON e.id = names.rowid WHERE names MATCH ? AND \(condition.sql) ORDER BY \(order.sql) LIMIT ?",
                         [.text(match)] + condition.values + order.values + limit)
        case .ranges(let ranges):
            try evaluate("SELECT \(columns) FROM json_each(?) r JOIN entries e ON e.path >= r.value ->> 0 AND e.path < r.value ->> 1 WHERE \(condition.sql) ORDER BY \(order.sql) LIMIT ?",
                         [try Self.json(ranges)] + condition.values + order.values + limit)
        case .names(let clause):
            let indexed = clause && condition
            try evaluate("SELECT \(columns) FROM entries e INDEXED BY entries_nname WHERE \(indexed.sql) ORDER BY \(order.sql) LIMIT ?", indexed.values + order.values + limit)
        case .rowids(let ids):
            let json = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
            try evaluate("SELECT \(columns) FROM entries e WHERE e.id IN (SELECT value FROM json_each(?)) AND \(condition.sql) ORDER BY \(order.sql) LIMIT ?",
                         [.text(json)] + condition.values + order.values + limit)
        }
    }

    /// Reads a large tier in score order: projects and apps by their own index, recently modified
    /// records newest first, then everything else in path order, which is the tie order.
    private mutating func decomposed(tier: MatchTier, predicate: Clause, base: Double, source: Source) throws {
        let kind = request.kind
        let limit: [SQLValue] = [.int(Int64(TopHits.limit))]
        for group in ["Projeler", "Uygulamalar"] where kind == "Tümü" || kind == group {
            let condition = Clause("e.kind = ? AND \(projectOrApp)", [.text(group)]) && predicate && filter
            let order = score(base: base)
            try evaluate("SELECT \(columns) FROM entries e INDEXED BY entries_kind WHERE \(condition.sql) ORDER BY \(order.sql) DESC, e.path LIMIT ?",
                         condition.values + order.values + limit)
        }
        guard kind != "Projeler" && kind != "Uygulamalar" else { return }
        let recent = Clause("e.modified > ? AND \(otherKinds) AND \(recency.sql) > 0", [.double(request.now - 864_001)] + recency.values) && predicate && filter
        try evaluate("SELECT \(columns) FROM entries e INDEXED BY entries_modified WHERE \(recent.sql) ORDER BY e.modified DESC, e.path LIMIT ?", recent.values + limit)
        let old = Clause("\(otherKinds) AND \(recency.sql) = 0", recency.values)
        if case .ranges(let ranges) = source {
            var found = 0
            for (lower, upper) in ranges where found < TopHits.limit {
                try Task.checkCancellation()
                let condition = Clause("e.path >= ? AND e.path < ?", [.text(lower), .text(upper)]) && old && predicate && filter
                found += try evaluate("SELECT \(columns) FROM entries e INDEXED BY entries_path WHERE \(condition.sql) ORDER BY e.path LIMIT ?",
                                      condition.values + [.int(Int64(TopHits.limit - found))])
            }
            return
        }
        // Path order finds the first matches quickly unless they cluster late in the catalog;
        // then ranking all candidates is cheaper.
        let condition = old && predicate && filter
        let snapshot = (best, seen)
        interrupter.budget = scanBudget
        interrupter.exhausted = false
        defer { interrupter.budget = .max }
        do {
            try evaluate("SELECT \(columns) FROM entries e INDEXED BY entries_path WHERE \(condition.sql) ORDER BY e.path LIMIT ?", condition.values + limit)
        } catch where interrupter.exhausted && !Task.isCancelled {
            (best, seen) = snapshot
            interrupter.budget = .max
            // `+` sorts the candidates instead of reading the whole table in path order.
            try direct(predicate: predicate, base: base, source: source, extra: old, order: Clause("+e.path"))
        }
    }

    /// Letter matches rank by stem length. Projects and apps are few; other records are read in
    /// stem length order until no longer stem can reach the list.
    private mutating func letters() throws {
        let higher = path || nameOrProject || contains
        let predicate = lettersMatch && !higher
        let base = Clause("(100.0 - max(0, e.stem - ?))", [.int(Int64(qBytes.count))])
        let order = Clause("((\(base.sql) + \(kindBonus)) + \(recency.sql)) DESC, e.path", base.values + recency.values)
        let limit: [SQLValue] = [.int(Int64(TopHits.limit))]
        for group in ["Projeler", "Uygulamalar"] where request.kind == "Tümü" || request.kind == group {
            let condition = Clause("e.kind = ? AND \(projectOrApp)", [.text(group)]) && predicate && filter
            try evaluate("SELECT \(columns) FROM entries e INDEXED BY entries_kind WHERE \(condition.sql) ORDER BY \(order.sql) LIMIT ?", condition.values + order.values + limit)
        }
        guard request.kind != "Projeler" && request.kind != "Uygulamalar" else { return }
        let longest = Int(try db.scalar("SELECT max(stem) FROM entries") ?? "0") ?? 0
        var lower = qBytes.count, width = 4
        while lower <= longest {
            try Task.checkCancellation()
            let upper = lower + width - 1
            let condition = Clause("e.stem BETWEEN ? AND ?", [.int(Int64(lower)), .int(Int64(upper))]) && lettersMatch && Clause(otherKinds) && !higher && filter
            try evaluate("SELECT \(columns) FROM entries e INDEXED BY entries_stem WHERE \(condition.sql) ORDER BY \(order.sql) LIMIT ?", condition.values + order.values + limit)
            if best.excludes(score: 100 - Double(max(0, upper + 1 - qBytes.count)) + 10) { return }
            lower = upper + 1
            width = min(width * 2, 64)
        }
    }

    /// Folders whose name contains a slash-free part of the query; every path containing that part
    /// lies in one of their subtrees or below a root that contains it. With several parts, a path
    /// must lie below an anchor of each. Relies on scans recording every folder they enter.
    private func anchors() throws -> Source {
        let pieces = Set(context.tokens.flatMap { String(decoding: $0, as: UTF8.self).split(separator: "/").map(String.init) }.filter(Self.ftsUsable))
        guard !pieces.isEmpty else { return .all }
        var scopes = request.roots.map(CatalogPath.canonical)
        if let folder = request.folder { scopes = scopes.isEmpty ? [] : [CatalogPath.canonical(folder)] }
        var result: Set<String>?
        for piece in pieces.sorted() {
            var folders = scopes.filter { Search.contains(Array(Search.normalize($0).utf8), Array(piece.utf8)) }
            try db.query("SELECT e.path FROM names JOIN entries e ON e.id = names.rowid WHERE names MATCH ?", [.text("nname : " + Self.phrase(piece))]) {
                folders.append(Database.string($0, 0)); return true
            }
            var limited: Set<String> = []
            for folder in folders {
                if scopes.contains(where: { SearchScope.contains(folder, in: $0) }) { limited.insert(folder) }
                limited.formUnion(scopes.filter { SearchScope.contains($0, in: folder) })
            }
            if let previous = result {
                result = Set(limited.filter { CatalogPath.isCovered($0, by: previous) }).union(previous.filter { CatalogPath.isCovered($0, by: limited) })
            } else {
                result = limited
            }
        }
        return .ranges(CatalogPath.intervals(Array(result ?? [])).map { ($0.lower, $0.upper) })
    }

    // MARK: Evaluation

    /// Preferences and extra records are ranked in Swift because pins, opens and learned queries
    /// can lift them above any tier.
    private mutating func evaluateHandled() throws {
        let paths = Array(Set((Array(request.preferences.keys) + request.aliases.keys).map(CatalogPath.canonical)))
        for start in stride(from: 0, to: paths.count, by: 500) {
            let chunk = Array(paths[start..<min(start + 500, paths.count)])
            let json = String(decoding: try JSONEncoder().encode(chunk), as: UTF8.self)
            try evaluate("SELECT \(columns) FROM entries e WHERE e.path IN (SELECT value FROM json_each(?))", [.text(json)])
        }
        for entry in request.extra where seen.insert(entry.path).inserted {
            if let hit = Self.hit(entry, name: Array(Search.normalize(entry.name).utf8), project: Array(Search.normalize(entry.project).utf8),
                                  context: context, aliases: request.aliases) {
                best.insert(hit)
            }
        }
    }

    /// Ranks a record by its file name and by each name Finder shows for it in the user's
    /// languages, keeping the best match; the hit carries the shown name.
    static func hit(_ entry: Entry, name: [UInt8], project: [UInt8], context: RankContext, aliases: [String: [String]]) -> Hit? {
        let path = Array(Search.normalize(entry.path).utf8)
        let plain = context.hit(entry, name: name, stemLength: Search.stemLength(name), project: project, path: path)?.hit
        guard let names = aliases[entry.path], let shownName = names.first else { return plain }
        let shown = Entry(path: entry.path, name: shownName, kind: entry.kind, project: entry.project, modified: entry.modified)
        var best = plain.map { Hit(entry: shown, score: $0.score, reason: $0.reason, queryOpenedAt: $0.queryOpenedAt, queryMatch: $0.queryMatch) }
        for alias in names {
            let bytes = Array(Search.normalize(alias).utf8)
            guard let hit = context.hit(shown, name: bytes, stemLength: Search.stemLength(bytes), project: project, path: path)?.hit else { continue }
            if best.map({ TopHits.precedes(hit, $0) }) ?? true { best = hit }
        }
        return best
    }

    @discardableResult
    private mutating func evaluate(_ sql: String, _ values: [SQLValue]) throws -> Int {
        var rows: [(path: String, hit: Hit?)] = []
        let context = self.context, aliases = request.aliases
        try db.query(sql, values) { statement in
            let entry = Database.entry(statement)
            rows.append((entry.path, Self.hit(entry, name: Database.bytes(statement, 5), project: Database.bytes(statement, 6), context: context, aliases: aliases)))
            return true
        }
        for row in rows where seen.insert(row.path).inserted {
            if let hit = row.hit { best.insert(hit) }
        }
        return rows.count
    }
}

extension Clause {
    static func || (a: Clause, b: Clause) -> Clause { Clause("(\(a.sql)) OR (\(b.sql))", a.values + b.values) }
}
