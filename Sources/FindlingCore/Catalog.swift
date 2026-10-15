import Foundation
import CSQLite

public struct IndexRequest: Sendable, Hashable {
    public let path: String
    public let recursive: Bool
    /// For recursive requests: list only folders whose modification date differs from the stored
    /// one. Adding, removing or renaming an item changes its folder's date, so this finds every
    /// structural change for a fraction of a full walk; edits inside existing files are not seen.
    public let quick: Bool
    public init(path: String, recursive: Bool = true, quick: Bool = false) {
        self.path = SearchScope.standardized(path); self.recursive = recursive; self.quick = recursive && quick
    }
    public static func coalesced(_ requests: [IndexRequest], rules: SkipRules = .default) -> [IndexRequest] {
        let unique = Set(requests)
        return unique.filter { request in
            !unique.contains { other in
                other != request && other.recursive && (!other.quick || request.quick) && SearchScope.contains(request.path, in: other.path)
                    && !Scanner.skipsComponents(of: request.path, below: other.path, rules: rules)
            }
        }.sorted { $0.path == $1.path ? !$0.recursive && $1.recursive : CatalogPath.isOrdered($0.path, before: $1.path) }
    }
}

/// A directory reported by the file system watcher. `recursive` means its whole subtree may
/// have changed, for example after dropped events.
public struct FileChange: Sendable, Hashable {
    public let path: String
    public let recursive: Bool
    public init(path: String, recursive: Bool) { self.path = path; self.recursive = recursive }
}

public struct IndexReport: Sendable {
    public var warnings: [String] = []
    public var inaccessiblePaths: [String] = []
    public var changes = 0
}

public actor Catalog {
    private let db: Database
    private var inTransaction = false
    private var pending = 0
    private var lastCommit = ProcessInfo.processInfo.systemUptime
    private let storesNormalizedPath: Bool

    public init(path: String) throws {
        db = try Database(path: path)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS entries(id INTEGER PRIMARY KEY, path TEXT NOT NULL, parent INTEGER NOT NULL,
          name TEXT NOT NULL, kind TEXT NOT NULL, project TEXT NOT NULL, modified REAL NOT NULL,
          nname TEXT NOT NULL, stem INTEGER NOT NULL, nproject TEXT NOT NULL);
        CREATE VIRTUAL TABLE IF NOT EXISTS names USING fts5(nname, nproject, content='entries', content_rowid='id', tokenize='trigram', columnsize=0);
        """)
        // Earlier catalogs store a normalized copy of every path (a sixth of their size); the
        // reader normalizes on the fly instead. Dropping the column would rewrite the table.
        var columns: Set<String> = []
        try db.query("PRAGMA table_info(entries)") { columns.insert(Database.string($0, 1)); return true }
        storesNormalizedPath = columns.contains("npath")
        // Checkpointing every 1,000 pages made the first index spend half its time in fsync;
        // the WAL is limited to 64 MB anyway, so checkpoint at that size.
        try db.execute("PRAGMA wal_autocheckpoint=16384")
        // Writing the trigram index from a trigger flushed its buffer on every row; new rows now
        // feed it directly. Catalogs created before that still carry the trigger.
        try db.execute("DROP TRIGGER IF EXISTS entries_ai")
        // An interrupted bulk import resumes without indexes; they are built once at its end.
        if try db.scalar("SELECT value FROM metadata WHERE key='legacyBulk'") != "1" { try Self.createIndexes(db) }
    }
    private static let indexNames = ["entries_path", "entries_parent", "entries_nname", "entries_kind", "entries_modified", "entries_stem"]
    private static let triggerNames = ["entries_ad", "entries_au"]
    static func createIndexes(_ db: Database) throws {
        try db.execute("""
        CREATE UNIQUE INDEX IF NOT EXISTS entries_path ON entries(path);
        CREATE INDEX IF NOT EXISTS entries_parent ON entries(parent);
        CREATE INDEX IF NOT EXISTS entries_nname ON entries(nname);
        CREATE INDEX IF NOT EXISTS entries_kind ON entries(kind) WHERE kind IN ('Projeler','Uygulamalar');
        CREATE INDEX IF NOT EXISTS entries_modified ON entries(modified);
        CREATE INDEX IF NOT EXISTS entries_stem ON entries(stem, nname);
        CREATE TRIGGER IF NOT EXISTS entries_ad AFTER DELETE ON entries BEGIN
          INSERT INTO names(names, rowid, nname, nproject) VALUES('delete', old.id, old.nname, old.nproject);
        END;
        CREATE TRIGGER IF NOT EXISTS entries_au AFTER UPDATE OF nname, nproject ON entries BEGIN
          INSERT INTO names(names, rowid, nname, nproject) VALUES('delete', old.id, old.nname, old.nproject);
          INSERT INTO names(rowid, nname, nproject) VALUES(new.id, new.nname, new.nproject);
        END;
        """)
    }

    /// Schema and data changes that take seconds on a large catalog; called off the main thread.
    public func upgradeSchema() throws {
        try commit()
        // The kind index only ever serves projects and apps; a full one was 60 MB.
        if let sql = try db.scalar("SELECT sql FROM sqlite_master WHERE type='index' AND name='entries_kind'"), !sql.contains("WHERE") {
            try db.transaction {
                try db.execute("DROP INDEX entries_kind; CREATE INDEX entries_kind ON entries(kind) WHERE kind IN ('Projeler','Uygulamalar')")
            }
        }
        if try metadata("canonicalPaths") != "1", try metadata("legacyBulk") != "1" {
            try canonicalizePaths()
            try setMetadata("canonicalPaths", "1")
        }
    }
    /// Rows written before paths were canonicalized carry decomposed accents. A walk never
    /// matches them to their folder's listing, so they would stay forever and gain composed twins.
    private func canonicalizePaths() throws {
        var stale: [(id: Int64, entry: Entry)] = []
        try db.query("SELECT id, \(Database.columns) FROM entries WHERE path GLOB '*[^ -~]*'") { statement in
            let entry = Database.entry(statement, from: 1)
            let canonical = Entry(path: CatalogPath.canonical(entry.path), name: CatalogPath.canonical(entry.name), kind: entry.kind,
                                  project: CatalogPath.canonical(entry.project), modified: entry.modified)
            let same = entry.path.utf8.elementsEqual(canonical.path.utf8) && entry.name.utf8.elementsEqual(canonical.name.utf8)
                && entry.project.utf8.elementsEqual(canonical.project.utf8)
            if !same { stale.append((sqlite3_column_int64(statement, 0), canonical)) }
            return true
        }
        guard !stale.isEmpty else { return }
        try db.transaction {
            for (id, entry) in stale {
                let row = row(entry)
                let twin = try self.entry(at: entry.path) != nil
                if !twin {
                    do {
                        try db.run("UPDATE entries SET path=?,parent=?,name=?,project=?,nname=?,stem=?,nproject=?\(storesNormalizedPath ? ",npath=?" : "") WHERE id=?",
                                   [row.values[0], row.values[1], .text(entry.name), .text(entry.project), .text(row.nname), .int(row.stem), .text(row.nproject)]
                                   + (storesNormalizedPath ? [row.values[9]] : []) + [.int(id)])
                        continue
                    } catch let error as NSError where error.code == Int(SQLITE_CONSTRAINT) {}
                }
                try db.run("DELETE FROM entries WHERE id=?", [.int(id)])
            }
        }
    }

    public func count() throws -> Int { Int(try db.scalar("SELECT count(*) FROM entries") ?? "0") ?? 0 }
    /// Verifies the trigram index against the rows; throws when they disagree.
    public func checkIntegrity() throws { try db.execute("INSERT INTO names(names) VALUES('integrity-check')") }
    public func metadata(_ key: String) throws -> String? { try db.scalar("SELECT value FROM metadata WHERE key=?", [.text(key)]) }
    public func setMetadata(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO metadata VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(value)])
    }
    public func entry(at path: String) throws -> Entry? {
        var found: Entry?
        try db.query("SELECT \(Database.columns) FROM entries WHERE path=?", [.text(path)]) { found = Database.entry($0); return false }
        return found
    }
    /// Small fixtures and tests only; the app reads through `SearchReader`.
    public func load() throws -> [Entry] {
        var entries: [Entry] = []
        try db.query("SELECT \(Database.columns) FROM entries ORDER BY path") { entries.append(Database.entry($0)); return true }
        return entries
    }
    public func save(_ entries: [Entry]) throws {
        try db.transaction {
            try db.run("DELETE FROM entries")
            for entry in entries { try insert(entry) }
        }
    }

    // MARK: Writing

    private func begin() throws {
        guard !inTransaction else { return }
        try db.execute("BEGIN IMMEDIATE")
        inTransaction = true
    }
    /// Commits regularly so searches see progress and the WAL stays small.
    private func wrote(_ count: Int = 1) throws {
        pending += count
        let now = ProcessInfo.processInfo.systemUptime
        if pending >= 8192 || now - lastCommit >= 2 { try commit() }
    }
    private func commit() throws {
        lastCommit = ProcessInfo.processInfo.systemUptime
        guard inTransaction else { return }
        inTransaction = false
        pending = 0
        try db.execute("COMMIT")
    }
    private struct Row {
        let values: [SQLValue]
        let nname: String
        let nproject: String
        let stem: Int64
    }
    private func row(_ entry: Entry) -> Row {
        let name = Search.normalize(entry.name), project = Search.normalize(entry.project)
        let stem = Int64(Search.stemLength(Array(name.utf8)))
        var values: [SQLValue] = [.text(entry.path), .int(CatalogPath.hash(CatalogPath.parent(of: entry.path))), .text(entry.name), .text(entry.kind),
                                  .text(entry.project), .double(entry.modified), .text(name), .int(stem), .text(project)]
        if storesNormalizedPath { values.append(.text(Search.normalize(entry.path))) }
        return Row(values: values, nname: name, nproject: project, stem: stem)
    }
    private var insertSQL: String {
        "INSERT INTO entries(path,parent,name,kind,project,modified,nname,stem,nproject\(storesNormalizedPath ? ",npath" : "")) VALUES(?,?,?,?,?,?,?,?,?\(storesNormalizedPath ? ",?" : ""))"
    }
    /// A row known to be absent. A plain insert plus a direct trigram write stays clear of the
    /// statement journal that an upsert or trigger would open on the virtual table.
    private func insert(_ entry: Entry) throws {
        let row = row(entry)
        try db.run(insertSQL, row.values)
        try db.run("INSERT INTO names(rowid,nname,nproject) VALUES(?,?,?)", [.int(db.lastInsertRowID), .text(row.nname), .text(row.nproject)])
    }
    /// Keeps the stored row when the path exists. Returns whether a row was added.
    private func insertIfAbsent(_ entry: Entry) throws -> Bool {
        let row = row(entry)
        try db.run(insertSQL + " ON CONFLICT(path) DO NOTHING", row.values)
        guard db.changes > 0 else { return false }
        try db.run("INSERT INTO names(rowid,nname,nproject) VALUES(?,?,?)", [.int(db.lastInsertRowID), .text(row.nname), .text(row.nproject)])
        return true
    }
    /// Replaces every field of a stored row; the update trigger refreshes the trigram index.
    private func update(_ entry: Entry) throws {
        let row = row(entry)
        try db.run("UPDATE entries SET name=?,kind=?,project=?,modified=?,nname=?,stem=?,nproject=? WHERE path=?",
                   [.text(entry.name), .text(entry.kind), .text(entry.project), .double(entry.modified), .text(row.nname), .int(row.stem), .text(row.nproject), .text(entry.path)])
    }
    /// Writes only what differs from the stored record.
    private func write(_ entry: Entry, old: Entry?) throws -> Bool {
        guard old != entry else { return false }
        try begin()
        if let old {
            if old.name == entry.name, old.project == entry.project {
                try db.run("UPDATE entries SET kind=?, modified=? WHERE path=?", [.text(entry.kind), .double(entry.modified), .text(entry.path)])
            } else {
                try update(entry)
            }
        } else {
            do { try insert(entry) }
            catch let error as NSError where error.code == Int(SQLITE_CONSTRAINT) {
                // The path exists after all, for example listed under two spellings of one name.
                try update(entry)
            }
        }
        try wrote()
        return true
    }
    private func deleteRange(_ condition: String, _ values: [SQLValue]) throws -> Int {
        var total = 0
        while true {
            try Task.checkCancellation()
            try begin()
            try db.run("DELETE FROM entries WHERE id IN (SELECT id FROM entries WHERE \(condition) LIMIT 2048)", values)
            let removed = db.changes
            total += removed
            try wrote(removed)
            if removed < 2048 { return total }
        }
    }
    private func deleteDescendants(_ path: String) throws -> Int {
        let range = CatalogPath.subtree(path)
        return try deleteRange("path >= ? AND path < ?", [.text(range.lower), .text(range.upper)])
    }
    private func deleteTree(_ path: String) throws -> Int {
        try begin()
        try db.run("DELETE FROM entries WHERE path=?", [.text(path)])
        let removed = db.changes
        try wrote(removed)
        return removed + (try deleteDescendants(path))
    }
    private func children(of directory: String) throws -> [String: Entry] {
        var found: [String: Entry] = [:]
        try db.query("SELECT \(Database.columns) FROM entries WHERE parent=?", [.int(CatalogPath.hash(directory))]) {
            let entry = Database.entry($0)
            if CatalogPath.parent(of: entry.path) == directory { found[entry.path] = entry }
            return true
        }
        return found
    }

    // MARK: Indexing

    /// Brings the given paths up to date. Unchanged records are not written; records under
    /// unreadable folders are kept until access returns.
    public func index(_ requests: [IndexRequest], roots: [String], exclusions excludedPaths: [String], rules: SkipRules = .default,
                      progress: (@Sendable (ScanProgress) -> Void)? = nil) async throws -> IndexReport {
        let exclusions = SearchScope.Paths(excludedPaths)
        let effective = SearchScope.effectiveRoots(roots, exclusions: exclusions, rules: rules)
        var report = IndexReport()
        var reporter = ProgressReporter(progress)
        do {
            for request in IndexRequest.coalesced(requests, rules: rules) {
                try Task.checkCancellation()
                try await index(request, roots: effective, exclusions: exclusions, rules: rules, report: &report, reporter: &reporter)
            }
            try commit()
        } catch {
            // Completed work stays valid; the next scan resumes from the stored state.
            try? commit()
            throw error
        }
        reporter.report(force: true)
        report.warnings = Array(Set(report.warnings)).sorted()
        return report
    }

    private func index(_ request: IndexRequest, roots: [String], exclusions: SearchScope.Paths, rules: SkipRules, report: inout IndexReport, reporter: inout ProgressReporter) async throws {
        if request.quick { return try await verify(request.path, roots: roots, exclusions: exclusions, rules: rules, report: &report, reporter: &reporter) }
        let path = request.path
        let walker = Walker(exclusions: exclusions, maxDepth: nil, rules: rules)
        reporter.currentPath = path
        reporter.report(force: true)
        if roots.contains(path) {
            guard case let (base, entry)? = Walker.readableRoot(path) else {
                report.warnings.append("Could not read: \(path)"); report.inaccessiblePaths.append(path)
                return
            }
            if try write(entry, old: try self.entry(at: entry.path)) { report.changes += 1 }
            reporter.discovered += 1
            try await walk(walker, from: [(base, entry.project, 0)], recursive: request.recursive, report: &report, reporter: &reporter)
            return
        }
        guard let root = roots.filter({ SearchScope.contains(path, in: $0) }).max(by: { $0.count < $1.count }),
              !exclusions.contains(path), !Scanner.skipsComponents(of: path, below: root, rules: rules) else { return }
        let url = URL(fileURLWithPath: path)
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: Scanner.keySet) }
        catch {
            if FileManager.default.fileExists(atPath: path) {
                report.warnings.append("Could not read: \(path)"); report.inaccessiblePaths.append(path)
            } else {
                report.changes += try deleteTree(path)
            }
            return
        }
        let directory = values.isDirectory == true
        let parent = CatalogPath.parent(of: path)
        let context = try context(of: parent, root: root)
        if values.isHidden == true || values.isSymbolicLink == true
            || (directory && rules.skips(folder: CatalogPath.canonical(url.lastPathComponent), path: path, project: context, parent: CatalogPath.canonical(URL(fileURLWithPath: parent).lastPathComponent))) {
            report.changes += try deleteTree(path)
            return
        }
        let old = try entry(at: path)
        let entry = Walker.entry(for: url, values: values, context: context)
        if try write(entry, old: old) { report.changes += 1 }
        guard directory, entry.kind != "Uygulamalar", values.isPackage != true else {
            if old != nil && old?.kind != "Dosyalar" { report.changes += try deleteDescendants(path) }
            return
        }
        let recursive = request.recursive || old == nil || old?.project != entry.project
        try await walk(walker, from: [(url, entry.project, 0)], recursive: recursive, report: &report, reporter: &reporter)
    }

    /// A full walk lists on its own thread while this actor writes: listing a tree and writing
    /// its records each take minutes and neither has to wait for the other. Partial walks
    /// decide per folder from stored records whether to descend, so they stay sequential.
    private func walk(_ walker: Walker, from start: [(URL, String, Int)], recursive: Bool, report: inout IndexReport, reporter: inout ProgressReporter) async throws {
        guard recursive else {
            return try walker.walk(from: start, reporter: &reporter) { try apply($0, recursive: false, report: &report) } failed: { path, message in
                report.warnings.append(message); report.inaccessiblePaths.append(path)
            }
        }
        let lister = Lister(walker: walker, start: start, reporter: reporter)
        defer { lister.stop() }
        var finished = false
        for await event in lister.events {
            try Task.checkCancellation()
            switch event {
            case .listing(let listing):
                _ = try apply(listing, recursive: true, report: &report)
                lister.release()
            case .failed(let path, let message):
                report.warnings.append(message); report.inaccessiblePaths.append(path)
            case .finished(let discovered, let error):
                reporter.discovered += discovered
                if let error { throw error }
                finished = true
            }
        }
        // Iteration ends early when the task is cancelled; the walk must not count as complete.
        guard finished else { throw CancellationError() }
    }

    /// Visits stored folders level by level and refreshes only those whose modification date
    /// changed; a refresh walks new folders completely.
    private func verify(_ start: String, roots: [String], exclusions: SearchScope.Paths, rules: SkipRules, report: inout IndexReport, reporter: inout ProgressReporter) async throws {
        var level: [(path: String, stored: Double?, current: Double?)] = [(start, try entry(at: start)?.modified, Self.modificationDates([start])[0])]
        while !level.isEmpty {
            var folders: [(path: String, stored: Double?)] = []
            for (directory, stored, current) in level {
                try Task.checkCancellation()
                // Stored dates come from Foundation; a real change moves the date far more than this.
                if current == nil || stored.map({ abs($0 - current!) > 0.000_01 }) ?? true {
                    try await index(IndexRequest(path: directory, recursive: false), roots: roots, exclusions: exclusions, rules: rules, report: &report, reporter: &reporter)
                }
                guard current != nil else { continue }
                let before = folders.count
                try db.query("SELECT path, modified FROM entries WHERE parent=? AND kind IN ('Klasörler','Projeler')", [.int(CatalogPath.hash(directory))]) {
                    let path = Database.string($0, 0)
                    if CatalogPath.parent(of: path) == directory { folders.append((path, sqlite3_column_double($0, 1))) }
                    return true
                }
                if folders.count > before {
                    reporter.currentPath = directory
                    reporter.discovered += folders.count - before
                    reporter.report()
                }
            }
            let current = Self.modificationDates(folders.map(\.path))
            level = folders.indices.map { (folders[$0].path, folders[$0].stored, current[$0]) }
        }
    }
    /// Bound by disk latency, not CPU: four threads check 240,000 stored folders in 10 s
    /// instead of 45 s at the same CPU cost. The threads inherit the caller's QoS.
    private struct Slots: @unchecked Sendable { let base: UnsafeMutablePointer<Double?> }
    private static func modificationDates(_ paths: [String]) -> [Double?] {
        guard !paths.isEmpty else { return [] }
        var dates = [Double?](repeating: nil, count: paths.count)
        let threads = min(4, max(1, paths.count / 64))
        dates.withUnsafeMutableBufferPointer { buffer in
            let slots = Slots(base: buffer.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: threads) { thread in
                var index = thread
                while index < paths.count {
                    var info = stat()
                    if lstat(paths[index], &info) == 0 { slots.base[index] = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000 }
                    index += threads
                }
            }
        }
        return dates
    }

    /// Reconciles one listed directory with its stored children and returns the folders to
    /// walk next. Partial updates descend only into new folders or folders whose project
    /// context changed, because their descendants' records depend on it.
    private func apply(_ listing: Listing, recursive: Bool, report: inout IndexReport) throws -> [Entry] {
        var existing = try children(of: listing.directory)
        var descend: [Entry] = []
        for child in listing.children {
            let old = existing.removeValue(forKey: child.entry.path)
            if try write(child.entry, old: old) { report.changes += 1 }
            if child.descendable {
                if recursive || old == nil || old?.project != child.entry.project || old?.kind == "Dosyalar" { descend.append(child.entry) }
            } else if child.isLeaf, let old, old.kind != "Dosyalar" {
                report.changes += try deleteDescendants(old.path)
            }
        }
        for stale in existing.keys { report.changes += try deleteTree(stale) }
        return descend
    }

    private func context(of directory: String, root: String) throws -> String {
        if let stored = try entry(at: directory) { return stored.project }
        let url = URL(fileURLWithPath: directory)
        if directory == root { return Walker.rootEntry(url).project }
        if Scanner.isProject(url) && url.pathExtension.lowercased() != "app" { return CatalogPath.canonical(url.lastPathComponent) }
        let parent = CatalogPath.parent(of: directory)
        return parent.isEmpty || !SearchScope.contains(parent, in: root) ? "" : try context(of: parent, root: root)
    }

    /// Removes records outside the configured roots and inside excluded folders.
    public func prune(roots: [String], exclusions: [String]) throws {
        let exclusionScope = SearchScope.Paths(exclusions)
        let kept = Set(roots.map(SearchScope.standardized)).filter { !exclusionScope.contains($0) }
            .sorted { CatalogPath.isOrdered($0, before: $1) }
        defer { try? commit() }
        var lower: (value: String, inclusive: Bool)?
        for range in CatalogPath.intervals(kept) {
            try deleteBetween(lower, (range.lower, false))
            lower = (range.upper, true)
        }
        try deleteBetween(lower, nil)
        for excluded in exclusions { _ = try deleteTree(SearchScope.standardized(excluded)) }
        try commit()
    }
    private func deleteBetween(_ lower: (value: String, inclusive: Bool)?, _ upper: (value: String, inclusive: Bool)?) throws {
        var conditions: [String] = []
        var values: [SQLValue] = []
        if let lower { conditions.append(lower.inclusive ? "path >= ?" : "path > ?"); values.append(.text(lower.value)) }
        if let upper { conditions.append(upper.inclusive ? "path <= ?" : "path < ?"); values.append(.text(upper.value)) }
        _ = try deleteRange(conditions.isEmpty ? "1" : conditions.joined(separator: " AND "), values)
    }

    /// Turns watcher changes into index requests. A change below a folder that is not indexed
    /// (hidden, skipped, inside a package or not yet known) refreshes the nearest indexed folder,
    /// which picks up new folders and ignores skipped ones.
    public func plan(_ changes: [FileChange], roots: [String], exclusions excludedPaths: [String], rules: SkipRules = .default) throws -> [IndexRequest] {
        let exclusions = SearchScope.Paths(excludedPaths)
        let effective = SearchScope.effectiveRoots(roots, exclusions: exclusions, rules: rules)
        var requests: Set<IndexRequest> = []
        var folders: [String: Bool] = [:]
        func isIndexedFolder(_ path: String) throws -> Bool {
            if let known = folders[path] { return known }
            let stored = try entry(at: path)
            let indexed = (stored?.kind == "Klasörler" || stored?.kind == "Projeler")
                && (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]))?.isPackage != true
            folders[path] = indexed
            return indexed
        }
        for change in Set(changes) {
            var path = SearchScope.standardized(change.path)
            if !effective.contains(where: { SearchScope.contains(path, in: $0) }), path.hasPrefix("/System/Volumes/Data/") {
                path = String(path.dropFirst("/System/Volumes/Data".count))
            }
            if change.recursive {
                for root in effective where root != path && SearchScope.contains(root, in: path) { requests.insert(IndexRequest(path: root, quick: true)) }
            }
            guard let root = effective.filter({ SearchScope.contains(path, in: $0) }).max(by: { $0.count < $1.count }),
                  !exclusions.contains(path) else { continue }
            let components = path.dropFirst(root == "/" ? 1 : root.count + 1).split(separator: "/")
            // Activity in skipped folders (dependencies, build output, hidden folders) is frequent and
            // never reaches the catalog; a new parent folder has its own event.
            if components.contains(where: { $0.hasPrefix(".") || rules.skipsByName(String($0)) }) { continue }
            var indexed = root
            var reached = true
            for component in components {
                let next = indexed == "/" ? "/" + component : indexed + "/" + component
                guard try isIndexedFolder(next) else { reached = false; break }
                indexed = next
            }
            requests.insert(IndexRequest(path: indexed, recursive: reached && change.recursive, quick: true))
        }
        return IndexRequest.coalesced(Array(requests), rules: rules)
    }

    // MARK: Previous catalog

    /// Imports the previous single-BLOB catalog in bounded chunks; never allocates its
    /// complete contents. Progress is stored with each batch so an interrupted import resumes.
    /// Into an empty catalog, rows are appended without indexes, which are built once at the end:
    /// maintaining six indexes and the trigram index for millions of unsorted paths is many
    /// times slower. Searches must wait for `legacyImported`.
    public func migrateLegacy(path: String, chunkSize: Int = 1 << 20, progress: (@Sendable (_ imported: Int, _ fraction: Double) -> Void)? = nil) throws {
        guard try metadata("legacyImported") != "1" else { return }
        try commit()
        guard FileManager.default.fileExists(atPath: path) else { try setMetadata("legacyImported", "1"); return }
        var old: OpaquePointer?
        guard sqlite3_open_v2(path, &old, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let old else {
            if let old { sqlite3_close(old) }
            throw NSError(domain: "Findling", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not open the previous catalog."])
        }
        defer { sqlite3_close(old) }
        var blob: OpaquePointer?
        guard sqlite3_blob_open(old, "main", "catalog", "data", 1, 0, &blob) == SQLITE_OK, let blob else {
            // An empty previous catalog has no row to import.
            try setMetadata("legacyImported", "1"); return
        }
        defer { sqlite3_blob_close(blob) }
        var bulk = try metadata("legacyBulk") == "1"
        if !bulk, try count() == 0 {
            try db.execute((Self.triggerNames.map { "DROP TRIGGER IF EXISTS \($0);" } + Self.indexNames.map { "DROP INDEX IF EXISTS \($0);" }).joined())
            try setMetadata("legacyBulk", "1")
            bulk = true
        }
        let size = Int(sqlite3_blob_bytes(blob))
        let decoder = JSONDecoder()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var object: [UInt8] = []
        var depth = 0, quoted = false, escaped = false
        var entries: [Entry] = []
        var imported = Int(try metadata("legacyCount") ?? "0") ?? 0
        let resume = Int(try metadata("legacyOffset") ?? "0") ?? 0
        var lastReport = 0.0
        func store(through offset: Int) throws {
            try db.transaction {
                for entry in entries {
                    if bulk {
                        try db.run(insertSQL, row(entry).values)
                    } else {
                        _ = try insertIfAbsent(entry)
                    }
                }
                imported += entries.count
                try setMetadata("legacyOffset", String(offset))
                try setMetadata("legacyCount", String(imported))
            }
            entries.removeAll(keepingCapacity: true)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastReport >= 0.25 { lastReport = now; progress?(imported, 0.9 * Double(offset) / Double(max(size, 1))) }
        }
        for offset in stride(from: resume, to: size, by: chunkSize) {
            try Task.checkCancellation()
            let length = min(chunkSize, size - offset)
            guard sqlite3_blob_read(blob, &buffer, Int32(length), Int32(offset)) == SQLITE_OK else {
                throw NSError(domain: "Findling", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not read the previous catalog."])
            }
            try autoreleasepool {
            for i in 0..<length {
                let byte = buffer[i]
                if depth == 0 && byte != UInt8(ascii: "{") { continue }
                object.append(byte)
                if quoted {
                    if escaped { escaped = false }
                    else if byte == UInt8(ascii: "\\") { escaped = true }
                    else if byte == UInt8(ascii: "\"") { quoted = false }
                } else if byte == UInt8(ascii: "\"") { quoted = true }
                else if byte == UInt8(ascii: "{") { depth += 1 }
                else if byte == UInt8(ascii: "}") {
                    depth -= 1
                    if depth == 0 {
                        entries.append(try decoder.decode(Entry.self, from: Data(object)))
                        object.removeAll(keepingCapacity: true)
                        if entries.count == 2048 { try store(through: offset + i + 1) }
                    }
                }
            }
            }
        }
        guard depth == 0 else { throw NSError(domain: "Findling", code: 4, userInfo: [NSLocalizedDescriptionKey: "The previous catalog is incomplete."]) }
        try store(through: size)
        if bulk {
            progress?(imported, 0.9)
            try Task.checkCancellation()
            do { try db.execute("CREATE UNIQUE INDEX IF NOT EXISTS entries_path ON entries(path)") }
            catch {
                try db.execute("DELETE FROM entries WHERE id NOT IN (SELECT max(id) FROM entries GROUP BY path)")
                try db.execute("CREATE UNIQUE INDEX IF NOT EXISTS entries_path ON entries(path)")
            }
            try Self.createIndexes(db)
            progress?(imported, 0.95)
            try Task.checkCancellation()
            try db.execute("INSERT INTO names(names) VALUES('rebuild')")
            try db.run("DELETE FROM metadata WHERE key='legacyBulk'")
        }
        try setMetadata("legacyImported", "1")
        progress?(imported, 1)
    }
}

/// Lists a tree on a thread of the caller's QoS and hands each folder's listing to the writer.
/// At most two listings wait, so memory stays bounded when the writer falls behind.
private final class Lister: @unchecked Sendable {
    enum Event {
        case listing(Listing)
        case failed(path: String, message: String)
        case finished(discovered: Int, error: Error?)
    }
    let events: AsyncStream<Event>
    /// Starts at zero and is raised to two: libdispatch traps when a semaphore is freed below its
    /// initial value, which a writer stopped by cancellation leaves behind with listings unreleased.
    private let gate: DispatchSemaphore = {
        let gate = DispatchSemaphore(value: 0)
        gate.signal(); gate.signal()
        return gate
    }()
    private let lock = NSLock()
    private var stopped = false

    init(walker: Walker, start: [(URL, String, Int)], reporter: ProgressReporter) {
        let (events, continuation) = AsyncStream<Event>.makeStream()
        self.events = events
        let qos = DispatchQoS.QoSClass(rawValue: qos_class_self()) ?? .utility
        DispatchQueue.global(qos: qos).async { [self] in
            var reporter = reporter
            let before = reporter.discovered
            do {
                try walker.walk(from: start, reporter: &reporter) { listing in
                    self.gate.wait()
                    if self.isStopped { throw CancellationError() }
                    continuation.yield(.listing(listing))
                    return listing.children.filter(\.descendable).map(\.entry)
                } failed: { path, message in
                    continuation.yield(.failed(path: path, message: message))
                }
                continuation.yield(.finished(discovered: reporter.discovered - before, error: nil))
            } catch {
                continuation.yield(.finished(discovered: reporter.discovered - before, error: error))
            }
            continuation.finish()
        }
    }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func release() { gate.signal() }
    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        gate.signal()
    }
}

