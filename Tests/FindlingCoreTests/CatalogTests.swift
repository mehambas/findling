import XCTest
import CSQLite
@testable import FindlingCore

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Inside the package, so paths avoid macOS's /var -> /private/var alias.
private func temporaryFolder() throws -> URL {
    let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func sorted(_ entries: [Entry]) -> [Entry] { entries.sorted { $0.path < $1.path } }

final class CatalogTests: XCTestCase {
    // MARK: Search equivalence

    private static let words = ["Çalışma", "Fatura", "fatura-2024.pdf", "fatura-arsiv", "fatura arsiv", "fatura.old", "README.md", "readme.txt", "moebelbraum.yng.io", "wp-content", "src", "Sources",
                                "main.swift", "Package.swift", "notes", "Notizen", "güneş.png", "IŞIK İÇİN.md", "a", "ab.txt", "x", "data", "invoice",
                                "Invoice.final.pdf", "日本語メモ.txt", "quote\"name.txt", "star*name", "[bracket].md", "my doc.txt", "My Documents",
                                "archive.tar.gz", "Fotoğraflar", "report.md", "Reports", "a.b", "-dash", "contract-draft.docx", "Contracts"]

    private func fixture(seed: UInt64, size: Int) -> (entries: [Entry], roots: [String], folders: [String], now: Double) {
        var random = SeededGenerator(state: seed)
        let now = 1_800_000_000.0
        var entries: [Entry] = []
        var folders: [String] = []
        func modified() -> Double {
            switch Int.random(in: 0..<10, using: &random) {
            case 0: return now - Double.random(in: 0..<864_000, using: &random)
            case 1: return now + 3600
            case 2: return now - 86_400 * 3
            default: return now - Double(Int.random(in: 11..<2000, using: &random)) * 86_400
            }
        }
        func name() -> String {
            let word = Self.words.randomElement(using: &random)!
            return Int.random(in: 0..<3, using: &random) == 0 ? word : word.replacingOccurrences(of: ".", with: "-\(Int.random(in: 0..<40, using: &random)).", options: [], range: nil)
        }
        func grow(_ path: String, project: String, depth: Int) {
            for _ in 0..<Int.random(in: 2...7, using: &random) where entries.count < size {
                let child = path + "/" + name()
                if entries.contains(where: { $0.path == child }) { continue }
                let directory = depth < 4 && Int.random(in: 0..<3, using: &random) == 0
                if directory {
                    let isProject = Int.random(in: 0..<6, using: &random) == 0
                    let context = isProject ? URL(fileURLWithPath: child).lastPathComponent : project
                    entries.append(Entry(path: child, name: URL(fileURLWithPath: child).lastPathComponent, kind: isProject ? "Projeler" : "Klasörler", project: context, modified: modified()))
                    folders.append(child)
                    grow(child, project: context, depth: depth + 1)
                } else {
                    entries.append(Entry(path: child, name: URL(fileURLWithPath: child).lastPathComponent, kind: "Dosyalar", project: project, modified: modified()))
                }
            }
        }
        let roots = ["/fx/home", "/fx/Applications", "/fx/cloud"]
        for root in roots {
            entries.append(Entry(path: root, name: URL(fileURLWithPath: root).lastPathComponent, kind: "Klasörler", modified: modified()))
        }
        for index in 0..<40 {
            entries.append(Entry(path: "/fx/Applications/\(name())-\(index).app", name: "", kind: "Uygulamalar", modified: modified()))
        }
        entries = entries.map { $0.name.isEmpty ? Entry(path: $0.path, name: URL(fileURLWithPath: $0.path).lastPathComponent, kind: $0.kind, modified: $0.modified) : $0 }
        // Siblings that share a root's prefix must stay outside its scope.
        entries.append(Entry(path: "/fx/home-archive/fatura.pdf", name: "fatura.pdf", kind: "Dosyalar", modified: modified()))
        entries.append(Entry(path: "/fx/home.bak", name: "home.bak", kind: "Dosyalar", modified: now))
        while entries.count < size { grow(Int.random(in: 0..<4, using: &random) == 0 ? "/fx/cloud" : "/fx/home", project: "", depth: 0) }
        // Identical timestamps force path order to break ties.
        for index in stride(from: 0, to: entries.count, by: 7) {
            let e = entries[index]
            entries[index] = Entry(path: e.path, name: e.name, kind: e.kind, project: e.project, modified: now - 86_400 * 20)
        }
        return (entries, roots, folders, now)
    }

    private static let queries = ["", "a", "ab", "x", "f", "fa", "fat", "fatura", "FATURA 2", "calisma", "Çalışma", "ftra", "clsm", "readme", "read me",
                                  "wp-content", "content", "src main", "home", "fx/home", "home/wp", "moebelb", "yng", "my doc", "doc my", "notes 2",
                                  "\"name", "star*", "[br", "日本", "日本メ", "nvc", "zzzz", "i", "isik", "Işık", "tar", "a.b", ".", "/", "-", "cntrct",
                                  "rprt", "md", "app", "applications", "1", "2024"]

    private func compare(reader: SearchReader, index: SearchIndex, fixture: (entries: [Entry], roots: [String], folders: [String], now: Double),
                         preferences: [String: Preference], extra: [Entry], seed: UInt64, samples: Int) async throws {
        var random = SeededGenerator(state: seed)
        let kinds = ["Tümü", "Dosyalar", "Klasörler", "Projeler", "Uygulamalar"]
        for sample in 0..<samples {
            let query = Self.queries[sample % Self.queries.count]
            let kind = sample < Self.queries.count ? "Tümü" : kinds.randomElement(using: &random)!
            let folder: String? = sample < Self.queries.count || Bool.random(using: &random) ? nil : fixture.folders.randomElement(using: &random)
            let excluded = sample < Self.queries.count || Int.random(in: 0..<3, using: &random) > 0 ? [] : [fixture.folders.randomElement(using: &random)!]
            let roots: [String]
            switch sample < Self.queries.count ? 0 : Int.random(in: 0..<6, using: &random) {
            case 0, 1, 2: roots = fixture.roots
            case 3: roots = ["/fx/home"]
            case 4: roots = ["/fx/home", "/fx/home/My Documents"]
            default: roots = []
            }
            let expected = index.rank(query: query, preferences: preferences, kind: kind, now: fixture.now, folder: folder, excludedPaths: excluded, roots: roots)
            let actual = try await reader.search(SearchRequest(query: query, preferences: preferences, kind: kind, folder: folder, excludedPaths: excluded,
                                                               roots: roots, extra: extra, now: fixture.now))
            let describe: ([Hit]) -> [String] = { $0.map { "\($0.id) \($0.score) \($0.reason) \($0.queryMatch) \($0.queryOpenedAt)" } }
            if describe(actual) != describe(expected) {
                let missing = Set(describe(expected)).subtracting(describe(actual)).sorted().prefix(5)
                let unexpected = Set(describe(actual)).subtracting(describe(expected)).sorted().prefix(5)
                XCTFail("seed \(seed) query \"\(query)\" kind \(kind) folder \(folder ?? "-") excluded \(excluded) roots \(roots): expected \(expected.count), got \(actual.count)\nmissing \(Array(missing))\nunexpected \(Array(unexpected))")
                return
            }
        }
    }

    func testReaderMatchesInMemoryRanking() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = fixture(seed: 7, size: 3000)
        let extra = Entry(path: "/fx/home/dev/dist/Findling.app", name: "Findling.app", kind: "Uygulamalar", modified: fixture.now)
        let catalog = try Catalog(path: folder.appendingPathComponent("catalog.sqlite").path)
        try await catalog.save(fixture.entries)
        try await catalog.checkIntegrity()
        var random = SeededGenerator(state: 99)
        var preferences: [String: Preference] = [:]
        for entry in fixture.entries.shuffled(using: &random).prefix(60) {
            var preference = Preference()
            preference.pinned = Int.random(in: 0..<4, using: &random) == 0
            preference.hidden = Int.random(in: 0..<6, using: &random) == 0
            for _ in 0..<Int.random(in: 0..<4, using: &random) {
                preference.recordOpen(query: Self.queries.randomElement(using: &random)!, now: fixture.now - Double(Int.random(in: 0..<30, using: &random)) * 86_400)
            }
            preferences[entry.path] = preference
        }
        preferences["/fx/home/deleted-since.txt"] = Preference()
        let index = SearchIndex(fixture.entries + [extra])
        let reader = try SearchReader(path: folder.appendingPathComponent("catalog.sqlite").path)
        try await compare(reader: reader, index: index, fixture: fixture, preferences: [:], extra: [extra], seed: 1, samples: 300)
        try await compare(reader: reader, index: index, fixture: fixture, preferences: preferences, extra: [extra], seed: 2, samples: 300)
        // Small limits force the score-ordered reads and the fallback after an exhausted scan.
        await reader.configure(directLimit: 3, scanBudget: 1)
        try await compare(reader: reader, index: index, fixture: fixture, preferences: preferences, extra: [extra], seed: 3, samples: 300)
        await reader.configure(directLimit: 3, scanBudget: 1_000_000)
        try await compare(reader: reader, index: index, fixture: fixture, preferences: preferences, extra: [extra], seed: 4, samples: 300)
    }

    func testPathTierKeepsPathOrderAcrossSiblingFolders() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try Catalog(path: folder.appendingPathComponent("catalog.sqlite").path)
        var entries = [Entry(path: "/r", name: "r", kind: "Klasörler"), Entry(path: "/r/fatura", name: "fatura", kind: "Klasörler"),
                       Entry(path: "/r/fatura-arsiv", name: "fatura-arsiv", kind: "Klasörler")]
        entries += (0..<100).map { Entry(path: "/r/fatura/f\($0).txt", name: "f\($0).txt", kind: "Dosyalar") }
        entries += (0..<5).map { Entry(path: "/r/fatura-arsiv/a\($0).txt", name: "a\($0).txt", kind: "Dosyalar") }
        try await catalog.save(entries)
        let reader = try SearchReader(path: folder.appendingPathComponent("catalog.sqlite").path)
        await reader.configure(directLimit: 3, scanBudget: 1_000_000)
        let now = 1_800_000_000.0
        let expected = SearchIndex(entries).rank(query: "fatura", preferences: [:], now: now, roots: ["/r"]).map(\.id)
        let actual = try await reader.search(SearchRequest(query: "fatura", roots: ["/r"], now: now)).map(\.id)
        XCTAssertEqual(actual, expected)
        XCTAssertTrue(actual.contains("/r/fatura-arsiv/a0.txt"))
    }

    func testReaderCountsRecordsBelowARootWithoutSiblingPrefixes() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try Catalog(path: folder.appendingPathComponent("catalog.sqlite").path)
        try await catalog.save([Entry(path: "/r", name: "r", kind: "Klasörler"), Entry(path: "/r/a", name: "a", kind: "Klasörler"),
                                Entry(path: "/r/a/x.txt", name: "x.txt", kind: "Dosyalar"), Entry(path: "/r/a-b", name: "a-b", kind: "Klasörler"),
                                Entry(path: "/r/ab.txt", name: "ab.txt", kind: "Dosyalar")])
        let reader = try SearchReader(path: folder.appendingPathComponent("catalog.sqlite").path)
        let counts = try await (reader.count(under: "/r/a"), reader.count(under: "/r"), reader.count(under: "/"), reader.count(under: "/missing"))
        XCTAssertEqual(counts.0, 2)
        XCTAssertEqual(counts.1, 5)
        XCTAssertEqual(counts.2, 5)
        XCTAssertEqual(counts.3, 0)
        let hadProject = try await reader.contains(kind: "Projeler")
        try await catalog.save([Entry(path: "/r/app", name: "app", kind: "Projeler", project: "app")])
        let hasProject = try await reader.contains(kind: "Projeler")
        XCTAssertFalse(hadProject)
        XCTAssertTrue(hasProject)
    }
    func testReaderPublishesBetterTiersFirst() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try Catalog(path: folder.appendingPathComponent("catalog.sqlite").path)
        let entries = [Entry(path: "/r/fatura", name: "fatura", kind: "Klasörler")] + (0..<5).map { Entry(path: "/r/fatura/f\($0).pdf", name: "f\($0).pdf", kind: "Dosyalar") }
        try await catalog.save(entries)
        let reader = try SearchReader(path: folder.appendingPathComponent("catalog.sqlite").path)
        let partials = Recorder<[String]>()
        let hits = try await reader.search(SearchRequest(query: "fatura", roots: ["/r"])) { partials.append($0.map(\.id)) }
        XCTAssertEqual(hits.first?.id, "/r/fatura")
        XCTAssertEqual(hits.count, 6)
        XCTAssertEqual(partials.snapshot.first, ["/r/fatura"])
    }

    func testLocalizedNamesAreSearchedAndShown() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appendingPathComponent("Calendar.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        for (language, name) in [("en", "\u{200E}Calendar"), ("de", "Kalen\u{00AD}der"), ("tr", "Takvim")] {
            try FileManager.default.createDirectory(at: resources.appendingPathComponent("\(language).lproj"), withIntermediateDirectories: true)
            try "\"CFBundleDisplayName\" = \"\(name)\";".write(to: resources.appendingPathComponent("\(language).lproj/InfoPlist.strings"), atomically: true, encoding: .utf8)
        }
        try (["CFBundleIdentifier": "test.calendar", "CFBundleName": "Calendar", "CFBundlePackageType": "APPL", "CFBundleDevelopmentRegion": "en"] as NSDictionary)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(LocalizedNames.app(app.path, languages: ["de-DE", "de", "tr"]), ["Kalender.app", "Takvim.app"])
        XCTAssertEqual(LocalizedNames.app(app.path, languages: ["en-US", "tr-TR"]), ["Calendar.app", "Takvim.app"])
        XCTAssertEqual(LocalizedNames.app(app.path, languages: ["fr-FR", "tr"]), ["Takvim.app"])
        XCTAssertEqual(LocalizedNames.app(app.path, languages: ["en-US"]), [])
        try Data().write(to: resources.appendingPathComponent("en.lproj/InfoPlist.strings"))
        let empty = folder.appendingPathComponent("Empty.app")
        try FileManager.default.createDirectory(at: empty.appendingPathComponent("Contents/Resources/de.lproj"), withIntermediateDirectories: true)
        try Data().write(to: empty.appendingPathComponent("Contents/Resources/de.lproj/InfoPlist.strings"))
        try (["CFBundleIdentifier": "test.empty", "CFBundlePackageType": "APPL"] as NSDictionary).write(to: empty.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(LocalizedNames.app(empty.path, languages: ["de"]), [])
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("Documents/.localized"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("Downloads/.localized"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Music"), withIntermediateDirectories: true)
        XCTAssertEqual(LocalizedNames.folders(in: [folder.path], languages: ["de"]), [folder.appendingPathComponent("Documents").path: ["Dokumente"]])
        XCTAssertEqual(LocalizedNames.folders(in: [folder.path], languages: ["de", "tr"]),
                       [folder.appendingPathComponent("Documents").path: ["Dokumente", "Belgeler"], folder.appendingPathComponent("Downloads").path: ["Downloads", "İndirilenler"]])
        let containers = folder.appendingPathComponent("home/Library/Mobile Documents")
        for (container, item) in [("iCloud~md~obsidian", "Vault"), ("iCloud~com~example~empty", ".hidden"), ("com~apple~CloudDocs", "file.txt")] {
            try FileManager.default.createDirectory(at: containers.appendingPathComponent("\(container)/Documents/\(item)"), withIntermediateDirectories: true)
        }
        XCTAssertEqual(Array(LocalizedNames.iCloudAppFolders(home: folder.appendingPathComponent("home").path).keys), [containers.appendingPathComponent("iCloud~md~obsidian/Documents").path])

        let catalog = try Catalog(path: folder.appendingPathComponent("catalog.sqlite").path)
        let entries = [Entry(path: "/r/Calendar.app", name: "Calendar.app", kind: "Uygulamalar"), Entry(path: "/r/kalender.jpg", name: "kalender.jpg", kind: "Dosyalar"),
                       Entry(path: "/r/Calendars", name: "Calendars", kind: "Klasörler")]
        try await catalog.save(entries)
        let reader = try SearchReader(path: folder.appendingPathComponent("catalog.sqlite").path)
        let aliases = ["/r/Calendar.app": ["Kalender.app", "Takvim.app"]]
        for query in ["kalender", "calendar", "takvim", "kal", "a", ""] {
            let hits = try await reader.search(SearchRequest(query: query, roots: ["/r"], aliases: aliases))
            XCTAssertEqual(Set(hits.map(\.id)).count, hits.count, query)
            XCTAssertEqual(hits.first { $0.id == "/r/Calendar.app" }?.entry.name, "Kalender.app", query)
        }
        let german = try await reader.search(SearchRequest(query: "kalender", roots: ["/r"], aliases: aliases))
        XCTAssertEqual(german.map(\.id), ["/r/Calendar.app", "/r/kalender.jpg"])
        XCTAssertEqual(german.first?.reason, "Exact name match")
        let english = try await reader.search(SearchRequest(query: "calendar", roots: ["/r"], aliases: aliases))
        XCTAssertEqual(english.first?.id, "/r/Calendar.app")
        let turkish = try await reader.search(SearchRequest(query: "takvim", roots: ["/r"], aliases: aliases))
        XCTAssertEqual(turkish.map(\.id), ["/r/Calendar.app"])
        XCTAssertEqual(turkish.first?.entry.name, "Kalender.app")
        let apps = try await reader.paths(of: "Uygulamalar")
        XCTAssertEqual(apps, ["/r/Calendar.app"])
    }

    func testCancelledSearchStops() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try Catalog(path: folder.appendingPathComponent("catalog.sqlite").path)
        try await catalog.save((0..<20_000).map { Entry(path: "/r/d\($0 % 100)/file-\($0).txt", name: "file-\($0).txt", kind: "Dosyalar") })
        let reader = try SearchReader(path: folder.appendingPathComponent("catalog.sqlite").path)
        let task = Task { try await reader.search(SearchRequest(query: "qzx", roots: ["/r"])) }
        task.cancel()
        do { _ = try await task.value; XCTFail("A cancelled search must not return results") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        let after = try await reader.search(SearchRequest(query: "file-19999", roots: ["/r"]))
        XCTAssertEqual(after.first?.id, "/r/d99/file-19999.txt")
    }

    func testNormalizationFastPathMatchesFolding() {
        func folded(_ value: String) -> String {
            value.replacingOccurrences(of: "ı", with: "i").replacingOccurrences(of: "İ", with: "I")
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        let ascii = String((0..<128).map { Character(Unicode.Scalar(UInt8($0))) })
        XCTAssertEqual(Search.normalize(ascii), folded(ascii))
        for value in ["/Users/Demo/Code/README.md", "Package.swift", "A-Z_a-z 0-9 ~`^", "IŞIK İÇİN", "Çalışma"] {
            XCTAssertEqual(Search.normalize(value), folded(value))
        }
    }

    // MARK: Previous catalog

    private func legacyCatalog(_ entries: [Entry], at path: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE catalog (id INTEGER PRIMARY KEY CHECK(id=1), data BLOB NOT NULL)", nil, nil, nil), SQLITE_OK)
        let data = try JSONEncoder().encode(entries)
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO catalog(id,data) VALUES(1,?)", -1, &statement, nil)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
    }

    func testLegacyCatalogImportResumesAfterInterruption() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let entries = (0..<5000).map { index in
            Entry(path: "/old/{dir \(index % 17)}/\"quoted\" \\ \(index) çalışma}.txt", name: "\"quoted\" \\ \(index) çalışma}.txt", kind: index % 9 == 0 ? "Klasörler" : "Dosyalar",
                  project: index % 5 == 0 ? "proj{\(index % 3)}" : "", modified: Double(index) + 0.25)
        }
        let legacy = folder.appendingPathComponent("catalog.sqlite").path
        try legacyCatalog(entries, at: legacy)
        let catalog = try Catalog(path: folder.appendingPathComponent("catalog-v2.sqlite").path)
        let interrupted = Task {
            try await catalog.migrateLegacy(path: legacy, chunkSize: 4093) { _, _ in withUnsafeCurrentTask { $0?.cancel() } }
        }
        do { try await interrupted.value; XCTFail("Import should stop when cancelled") } catch {}
        let partial = try await catalog.count()
        XCTAssertGreaterThan(partial, 0)
        XCTAssertLessThan(partial, entries.count)
        try await catalog.migrateLegacy(path: legacy, chunkSize: 7)
        let imported = try await catalog.load()
        XCTAssertEqual(sorted(imported), sorted(entries))
        let marker = try await catalog.metadata("legacyImported")
        XCTAssertEqual(marker, "1")
        // A finished import is not repeated and keeps newer records.
        let newer = Entry(path: entries[0].path, name: entries[0].name, kind: "Dosyalar", modified: 99)
        try await catalog.save([newer])
        try await catalog.migrateLegacy(path: legacy)
        let kept = try await catalog.load()
        XCTAssertEqual(kept, [newer])
        let reader = try SearchReader(path: folder.appendingPathComponent("catalog-v2.sqlite").path)
        let hits = try await reader.search(SearchRequest(query: "quoted", roots: ["/old"]))
        XCTAssertEqual(hits.map(\.id), [newer.path])
        let missing = try Catalog(path: folder.appendingPathComponent("other.sqlite").path)
        try await missing.migrateLegacy(path: folder.appendingPathComponent("absent.sqlite").path)
        let missingCount = try await missing.count()
        XCTAssertEqual(missingCount, 0)
    }

    // MARK: Incremental indexing

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testIncrementalUpdatesMatchFreshScan() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + ".sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: store.path + suffix) } }
        for file in ["A/a1.txt", "A/sub/s.txt", "B/b.txt", "B/inner/deep.txt", "proj/deep/x.swift", "node_modules/n.js", ".hidden/h.txt", "Tool.app/Contents/Info.plist", "keep.md",
                     "Blöcke/İçerik/ü.txt", "Blöcke/n.txt"] {
            try write(file, to: root.appendingPathComponent(file))
        }
        let catalog = try Catalog(path: store.path)
        let roots = [root.path]
        _ = try await catalog.index([IndexRequest(path: root.path)], roots: roots, exclusions: [])
        var stored = try await catalog.load()
        XCTAssertEqual(sorted(stored), sorted(Scanner.scan(roots: roots).entries))
        // Foundation hands out decomposed accents in `URL.path`; one byte form must reach the catalog.
        let bytesDistinct: ([Entry]) -> Int = { Set($0.map { Array($0.path.utf8) }).count }
        XCTAssertEqual(bytesDistinct(stored), stored.count)
        XCTAssertTrue(stored.allSatisfy { $0.path.utf8.elementsEqual($0.path.precomposedStringWithCanonicalMapping.utf8) })
        let decomposed = root.appendingPathComponent("Blöcke").path
        _ = try await catalog.index([IndexRequest(path: decomposed, recursive: false), IndexRequest(path: decomposed + "/İçerik")], roots: roots, exclusions: [])
        let afterDecomposed = try await catalog.load()
        XCTAssertEqual(bytesDistinct(afterDecomposed), afterDecomposed.count)
        XCTAssertEqual(afterDecomposed.count, stored.count)

        let fm = FileManager.default
        try fm.removeItem(at: root.appendingPathComponent("A/a1.txt"))
        try write("new", to: root.appendingPathComponent("A/new.txt"))
        try fm.moveItem(at: root.appendingPathComponent("B"), to: root.appendingPathComponent("C"))
        try write("", to: root.appendingPathComponent("proj/.git/HEAD"))
        try write("x", to: root.appendingPathComponent("D/E/f.txt"))
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: root.appendingPathComponent("keep.md").path)
        try write("ignored", to: root.appendingPathComponent("node_modules/more.js"))
        // FSEvents reports the folders whose contents changed.
        let changes = ["A", "", "proj", "node_modules", ".hidden", "D/E"].map { FileChange(path: $0.isEmpty ? root.path : root.appendingPathComponent($0).path, recursive: false) }
        let requests = try await catalog.plan(changes, roots: roots, exclusions: [])
        XCTAssertEqual(Set(requests), [IndexRequest(path: root.path, recursive: false), IndexRequest(path: root.appendingPathComponent("A").path, recursive: false),
                                       IndexRequest(path: root.appendingPathComponent("proj").path, recursive: false)])
        let report = try await catalog.index(requests, roots: roots, exclusions: [])
        XCTAssertGreaterThan(report.changes, 0)
        stored = try await catalog.load()
        XCTAssertEqual(sorted(stored), sorted(Scanner.scan(roots: roots).entries))
        XCTAssertEqual(stored.first { $0.name == "x.swift" }?.project, "proj")
        XCTAssertTrue(stored.contains { $0.path.hasSuffix("/C/inner/deep.txt") })
        // New rows feed the trigram index directly; renames and deletions go through triggers.
        try await catalog.checkIntegrity()
        let reader = try SearchReader(path: store.path)
        let deep = try await reader.search(SearchRequest(query: "deep", roots: roots))
        XCTAssertEqual(deep.filter { $0.entry.name == "deep.txt" }.map(\.id), [root.appendingPathComponent("C/inner/deep.txt").path])
        let renamed = try await reader.search(SearchRequest(query: "x.swift", roots: roots))
        XCTAssertEqual(renamed.first?.entry.project, "proj")
        // The folder filter arrives decomposed, as the open panel delivers it.
        let scoped = try await reader.search(SearchRequest(query: "ü", folder: decomposed, roots: roots))
        XCTAssertEqual(scoped.first?.entry.name, "ü.txt")
        XCTAssertTrue(scoped.allSatisfy { SearchScope.contains($0.id, in: decomposed) })
        XCTAssertEqual(scoped.count, 4)

        // An unchanged rescan writes nothing, also under folders with accented names.
        let quiet = try await catalog.index([IndexRequest(path: root.path)], roots: roots, exclusions: [])
        XCTAssertEqual(quiet.changes, 0)
        let afterQuiet = try await catalog.load()
        XCTAssertEqual(bytesDistinct(afterQuiet), stored.count)

        // Unreadable folders keep their records until access returns.
        let locked = root.appendingPathComponent("A")
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let blocked = try await catalog.index([IndexRequest(path: root.path)], roots: roots, exclusions: [])
        XCTAssertFalse(blocked.warnings.isEmpty)
        let afterBlock = try await catalog.load()
        XCTAssertTrue(afterBlock.contains { $0.path == locked.appendingPathComponent("new.txt").path })
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)

        // Deleted request paths and new exclusions remove their records.
        try fm.removeItem(at: root.appendingPathComponent("C"))
        _ = try await catalog.index([IndexRequest(path: root.appendingPathComponent("C").path, recursive: false)], roots: roots, exclusions: [])
        let afterDelete = try await catalog.load()
        XCTAssertFalse(afterDelete.contains { SearchScope.contains($0.path, in: root.appendingPathComponent("C").path) })
        _ = try await catalog.index([IndexRequest(path: root.path, recursive: false)], roots: roots, exclusions: [])
        try await catalog.prune(roots: roots, exclusions: [root.appendingPathComponent("D").path])
        stored = try await catalog.load()
        XCTAssertFalse(stored.contains { SearchScope.contains($0.path, in: root.appendingPathComponent("C").path) || SearchScope.contains($0.path, in: root.appendingPathComponent("D").path) })
        let expected = Scanner.scan(roots: roots, excludedPaths: [root.appendingPathComponent("D").path]).entries
        XCTAssertEqual(Set(stored).symmetricDifference(expected), [])
        try await catalog.checkIntegrity()
    }

    /// Catalogs written before the schema changes keep their normalized path column and get the
    /// partial kind index on upgrade; the insert trigger is dropped.
    func testEarlierCatalogSchemaKeepsWorking() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("catalog.sqlite").path
        let raw = try Database(path: path)
        try raw.execute("""
        CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE entries(id INTEGER PRIMARY KEY, path TEXT NOT NULL, parent INTEGER NOT NULL, name TEXT NOT NULL, kind TEXT NOT NULL,
          project TEXT NOT NULL, modified REAL NOT NULL, nname TEXT NOT NULL, stem INTEGER NOT NULL, npath TEXT NOT NULL, nproject TEXT NOT NULL);
        CREATE VIRTUAL TABLE names USING fts5(nname, nproject, content='entries', content_rowid='id', tokenize='trigram');
        CREATE UNIQUE INDEX entries_path ON entries(path);
        CREATE INDEX entries_parent ON entries(parent);
        CREATE INDEX entries_nname ON entries(nname);
        CREATE INDEX entries_kind ON entries(kind);
        CREATE INDEX entries_modified ON entries(modified);
        CREATE INDEX entries_stem ON entries(stem, nname);
        CREATE TRIGGER entries_ai AFTER INSERT ON entries BEGIN
          INSERT INTO names(rowid, nname, nproject) VALUES(new.id, new.nname, new.nproject);
        END;
        CREATE TRIGGER entries_ad AFTER DELETE ON entries BEGIN
          INSERT INTO names(names, rowid, nname, nproject) VALUES('delete', old.id, old.nname, old.nproject);
        END;
        CREATE TRIGGER entries_au AFTER UPDATE OF nname, nproject ON entries BEGIN
          INSERT INTO names(names, rowid, nname, nproject) VALUES('delete', old.id, old.nname, old.nproject);
          INSERT INTO names(rowid, nname, nproject) VALUES(new.id, new.nname, new.nproject);
        END;
        INSERT INTO entries(path,parent,name,kind,project,modified,nname,stem,npath,nproject)
          VALUES('/old/Fatura.pdf', 0, 'Fatura.pdf', 'Dosyalar', '', 1, 'fatura.pdf', 6, '/old/fatura.pdf', '');
        """)
        // Rows the earlier code stored with decomposed accents, one of them beside its composed twin.
        let decomposed = "/old/Blöcke".decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Array(decomposed.utf8), Array("/old/Blöcke".utf8))
        for (path, kind) in [(decomposed, "Klasörler"), (decomposed + "/a.txt", "Dosyalar"), (decomposed + "/İç".decomposedStringWithCanonicalMapping, "Klasörler"),
                             (decomposed + "/İç".decomposedStringWithCanonicalMapping + "/b.txt", "Dosyalar"), ("/old/Blöcke/a.txt", "Dosyalar")] {
            let name = String(path[path.index(after: path.lastIndex(of: "/")!)...])
            try raw.run("INSERT INTO entries(path,parent,name,kind,project,modified,nname,stem,npath,nproject) VALUES(?,?,?,?,?,?,?,?,?,?)",
                        [.text(path), .int(CatalogPath.hash(CatalogPath.parent(of: path))), .text(name), .text(kind), "", .double(3), .text(Search.normalize(name)),
                         .int(Int64(Search.stemLength(Array(Search.normalize(name).utf8)))), .text(Search.normalize(path)), ""])
        }
        let catalog = try Catalog(path: path)
        try await catalog.upgradeSchema()
        XCTAssertEqual(try raw.scalar("SELECT count(*) FROM sqlite_master WHERE name='entries_ai'"), "0")
        XCTAssertTrue(try raw.scalar("SELECT sql FROM sqlite_master WHERE name='entries_kind'")?.contains("WHERE") == true)
        let migrated = try await catalog.load()
        XCTAssertEqual(migrated.map(\.path).sorted(), ["/old/Blöcke", "/old/Blöcke/a.txt", "/old/Blöcke/İç", "/old/Blöcke/İç/b.txt", "/old/Fatura.pdf"])
        XCTAssertTrue(migrated.allSatisfy { $0.path.utf8.elementsEqual($0.path.precomposedStringWithCanonicalMapping.utf8) && $0.name.utf8.elementsEqual($0.name.precomposedStringWithCanonicalMapping.utf8) })
        XCTAssertEqual(Set(migrated.map { Array($0.path.utf8) }).count, migrated.count)
        XCTAssertEqual(try raw.scalar("SELECT count(*) FROM entries WHERE parent=?", [.int(CatalogPath.hash("/old/Blöcke"))]), "2")
        XCTAssertEqual(try raw.scalar("SELECT value FROM metadata WHERE key='canonicalPaths'"), "1")
        try await catalog.checkIntegrity()
        // Running the upgrade again changes nothing.
        try await catalog.upgradeSchema()
        let again = try await catalog.load()
        XCTAssertEqual(again, migrated)
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        for file in ["Notlar/Çalışma.md", "proj/Package.swift", "proj/Sources/main.swift"] { try write(file, to: root.appendingPathComponent(file)) }
        _ = try await catalog.index([IndexRequest(path: root.path)], roots: [root.path], exclusions: [])
        try await catalog.checkIntegrity()
        let accented = CatalogPath.canonical(root.appendingPathComponent("Notlar/Çalışma.md").path)
        XCTAssertEqual(try raw.scalar("SELECT npath FROM entries WHERE path=?", [.text(accented)]), Search.normalize(accented))
        let reader = try SearchReader(path: path)
        let hits = try await reader.search(SearchRequest(query: "calisma", roots: [root.path]))
        XCTAssertEqual(hits.map(\.id), [root.appendingPathComponent("Notlar/Çalışma.md").path])
        let byPath = try await reader.search(SearchRequest(query: "notlar/cal", roots: [root.path]))
        XCTAssertEqual(byPath.map(\.id), [root.appendingPathComponent("Notlar/Çalışma.md").path])
        let projects = try await reader.search(SearchRequest(query: "", kind: "Projeler", roots: [root.path]))
        XCTAssertEqual(projects.map(\.id), [root.appendingPathComponent("proj").path])
        try await catalog.save([Entry(path: "/old/Fatura.pdf", name: "Fatura.pdf", kind: "Dosyalar", modified: 2)])
        try await catalog.checkIntegrity()
        // A fresh catalog has neither the column nor the trigger.
        let fresh = try Database(path: folder.appendingPathComponent("fresh.sqlite").path)
        _ = try Catalog(path: folder.appendingPathComponent("fresh.sqlite").path)
        XCTAssertEqual(try fresh.scalar("SELECT count(*) FROM pragma_table_info('entries') WHERE name='npath'"), "0")
        XCTAssertEqual(try fresh.scalar("SELECT count(*) FROM sqlite_master WHERE type='trigger'"), "2")
    }

    func testChangedSkipRulesAddAndRemoveFoldersOnTheNextWalk() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.path + ".sqlite"
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: store + suffix) } }
        for file in ["proj/.git/HEAD", "proj/node_modules/n.js", "proj/build/b.o", "proj/src/a.swift", "keep.md"] { try write(file, to: root.appendingPathComponent(file)) }
        let catalog = try Catalog(path: store)
        let roots = [root.path]
        _ = try await catalog.index([IndexRequest(path: root.path)], roots: roots, exclusions: [])
        var names = Set(try await catalog.load().map(\.name))
        XCTAssertFalse(names.contains("n.js") || names.contains("build"))
        let allowed = SkipRules(disabled: ["dependencies"])
        _ = try await catalog.index([IndexRequest(path: root.path)], roots: roots, exclusions: [], rules: allowed)
        names = Set(try await catalog.load().map(\.name))
        XCTAssertTrue(names.contains("n.js") && names.contains("node_modules"))
        XCTAssertFalse(names.contains("build"))
        let withDependencies = try await catalog.load()
        XCTAssertEqual(Set(withDependencies).symmetricDifference(Scanner.scan(roots: roots, rules: allowed).entries), [])
        let plan = try await catalog.plan([FileChange(path: root.appendingPathComponent("proj/node_modules").path, recursive: false)], roots: roots, exclusions: [], rules: allowed)
        XCTAssertEqual(plan, [IndexRequest(path: root.appendingPathComponent("proj/node_modules").path, recursive: false)])
        let back = try await catalog.index([IndexRequest(path: root.path)], roots: roots, exclusions: [])
        XCTAssertGreaterThan(back.changes, 0)
        names = Set(try await catalog.load().map(\.name))
        XCTAssertFalse(names.contains("n.js") || names.contains("node_modules"))
        try await catalog.checkIntegrity()
    }

    func testPlanSkipsUnindexedFoldersAndExpandsDroppedEvents() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try Catalog(path: folder.appendingPathComponent("catalog.sqlite").path)
        try await catalog.save([Entry(path: "/w/home", name: "home", kind: "Klasörler"), Entry(path: "/w/home/A", name: "A", kind: "Klasörler"),
                                Entry(path: "/w/home/Tool.app", name: "Tool.app", kind: "Uygulamalar"), Entry(path: "/w/home/f.txt", name: "f.txt", kind: "Dosyalar")])
        let roots = ["/w/home", "/w/home/Library/CloudStorage"]
        let plan = try await catalog.plan([
            FileChange(path: "/w/home/A/", recursive: true),
            FileChange(path: "/w/home/node_modules/x", recursive: false),
            FileChange(path: "/w/home/.git", recursive: false),
            FileChange(path: "/w/home/Library/Caches", recursive: false),
            FileChange(path: "/w/home/Tool.app/Contents", recursive: false),
            FileChange(path: "/w/home/A/New/Deeper", recursive: false),
            FileChange(path: "/w/home/private/x", recursive: false),
            FileChange(path: "/w/elsewhere", recursive: false),
            FileChange(path: "/w", recursive: true)
        ], roots: roots, exclusions: ["/w/home/private"])
        XCTAssertEqual(plan, [IndexRequest(path: "/w/home", recursive: false), IndexRequest(path: "/w/home", quick: true), IndexRequest(path: "/w/home/A", recursive: false),
                              IndexRequest(path: "/w/home/Library/CloudStorage", quick: true)])
        XCTAssertEqual(IndexRequest.coalesced([IndexRequest(path: "/w/home"), IndexRequest(path: "/w/home/A", quick: true), IndexRequest(path: "/w/home/B", recursive: false)]),
                       [IndexRequest(path: "/w/home")])
        let shallow = try await catalog.plan([FileChange(path: "/w/home/A/New/Deeper", recursive: true), FileChange(path: "/w/home/Tool.app/Contents", recursive: false)], roots: roots, exclusions: [])
        XCTAssertEqual(shallow, [IndexRequest(path: "/w/home", recursive: false), IndexRequest(path: "/w/home/A", recursive: false)])
    }

    func testQuickRescanFindsStructuralChangesAfterDroppedEvents() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.path + ".sqlite"
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: store + suffix) } }
        for file in ["A/a.txt", "A/deep/d.txt", "B/b.txt", "C/inner/c.txt", "proj/src/x.swift", "keep.md"] {
            try write(file, to: root.appendingPathComponent(file))
        }
        let catalog = try Catalog(path: store)
        let roots = [root.path]
        _ = try await catalog.index([IndexRequest(path: root.path)], roots: roots, exclusions: [])
        let unchanged = try await catalog.index([IndexRequest(path: root.path, quick: true)], roots: roots, exclusions: [])
        XCTAssertEqual(unchanged.changes, 0)
        // Changes whose events were lost: nested additions, deletions, a rename and a new project.
        let fm = FileManager.default
        try write("new", to: root.appendingPathComponent("A/deep/new.txt"))
        try fm.removeItem(at: root.appendingPathComponent("C/inner"))
        try fm.moveItem(at: root.appendingPathComponent("B"), to: root.appendingPathComponent("B2"))
        try write("", to: root.appendingPathComponent("proj/.git/HEAD"))
        try write("", to: root.appendingPathComponent("New/Deeper/n.txt"))
        _ = try await catalog.index([IndexRequest(path: root.path, quick: true)], roots: roots, exclusions: [])
        let stored = try await catalog.load()
        XCTAssertEqual(Set(stored).symmetricDifference(Scanner.scan(roots: roots).entries), [])
        XCTAssertEqual(stored.first { $0.name == "x.swift" }?.project, "proj")
    }

    func testPruneKeepsOnlyRootsOutsideExclusions() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try Catalog(path: folder.appendingPathComponent("catalog.sqlite").path)
        let paths = ["/a", "/r/home", "/r/home/x", "/r/home/private", "/r/home/private/y", "/r/home-other/z", "/r/home.bak", "/r/home0", "/r/apps/A.app", "/r/apps", "/s/t", "/z"]
        try await catalog.save(paths.map { Entry(path: $0, name: URL(fileURLWithPath: $0).lastPathComponent, kind: "Dosyalar") })
        try await catalog.prune(roots: ["/r/home", "/r/apps", "/r/home/x"], exclusions: ["/r/home/private"])
        let kept = try await catalog.load().map(\.path)
        XCTAssertEqual(kept, ["/r/apps", "/r/apps/A.app", "/r/home", "/r/home/x"])
        // Sibling roots sharing a prefix sort between a root and its subtree.
        let siblings = ["/x", "/x-y", "/x-y/b", "/x.bak", "/x/a", "/x/z", "/x/z/c", "/x0", "/w"]
        try await catalog.save(siblings.map { Entry(path: $0, name: URL(fileURLWithPath: $0).lastPathComponent, kind: "Dosyalar") })
        try await catalog.prune(roots: ["/x", "/x-y", "/x/z"], exclusions: [])
        let siblingKept = try await catalog.load().map(\.path)
        XCTAssertEqual(siblingKept, ["/x", "/x-y", "/x-y/b", "/x/a", "/x/z", "/x/z/c"])
        XCTAssertEqual(CatalogPath.intervals(["/x", "/x/z", "/x-y"]).map(\.lower), ["/x", "/x-y", "/x-y/", "/x/"])
    }

    func testCancelledScansStayConsistent() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<1500 { try write("", to: root.appendingPathComponent("d\(index % 30)/e\(index % 7)/file-\(index).txt")) }
        let cancelled = Task { Scanner.scan(roots: [root.path]) }
        cancelled.cancel()
        _ = await cancelled.value
        let store = root.path + ".sqlite"
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: store + suffix) } }
        let catalog = try Catalog(path: store)
        let task = Task { try await catalog.index([IndexRequest(path: root.path)], roots: [root.path], exclusions: []) }
        try await Task.sleep(nanoseconds: 2_000_000)
        task.cancel()
        _ = try? await task.value
        _ = try await catalog.index([IndexRequest(path: root.path)], roots: [root.path], exclusions: [])
        let stored = try await catalog.load()
        XCTAssertEqual(sorted(stored), sorted(Scanner.scan(roots: [root.path]).entries))
    }

    func testFullWalksCancelledAtAnyPointStayConsistent() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<600 { try write("", to: root.appendingPathComponent("d\(index % 20)/e\(index % 5)/file-\(index).txt")) }
        let store = root.path + ".sqlite"
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: store + suffix) } }
        let catalog = try Catalog(path: store)
        let expected = sorted(Scanner.scan(roots: [root.path]).entries)
        for attempt in 0..<40 {
            let task = Task { try await catalog.index([IndexRequest(path: root.path)], roots: [root.path], exclusions: []) }
            try await Task.sleep(nanoseconds: UInt64(attempt % 8) * 250_000)
            task.cancel()
            _ = try? await task.value
            if attempt % 10 == 9 {
                _ = try await catalog.index([IndexRequest(path: root.path)], roots: [root.path], exclusions: [])
                let stored = try await catalog.load()
                XCTAssertEqual(sorted(stored), expected, "attempt \(attempt)")
            }
        }
    }

    // MARK: File system events

    func testWatcherReportsChangesAndReplaysHistory() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let batches = Recorder<FileWatcher.Batch>()
        let watcher = FileWatcher { batches.append($0) }
        XCTAssertTrue(watcher.start(paths: [root.path], since: nil, latency: 0.1))
        try write("one", to: root.appendingPathComponent("sub/one.txt"))
        try await waitUntil { batches.snapshot.contains { $0.changes.contains { $0.path.hasSuffix("/sub") || $0.path == root.path } } }
        watcher.stop()
        let cursor = batches.snapshot.map(\.lastEventId).max() ?? 0
        XCTAssertGreaterThan(cursor, 0)
        try write("two", to: root.appendingPathComponent("later/two.txt"))
        let replay = Recorder<FileWatcher.Batch>()
        let second = FileWatcher { replay.append($0) }
        XCTAssertTrue(second.start(paths: [root.path], since: cursor, latency: 0.1))
        defer { second.stop() }
        try await waitUntil { replay.snapshot.contains(where: \.historyDone) && replay.snapshot.contains { $0.changes.contains { $0.path.hasSuffix("/later") || $0.path == root.path } } }
        XCTAssertFalse(FileWatcher.historyIdentity(for: [root.path]).isEmpty)
    }

    private func waitUntil(timeout: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for file system events") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: Performance

    func testReaderStaysFastOnLargeCatalog() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try Catalog(path: folder.appendingPathComponent("catalog.sqlite").path)
        let now = Date().timeIntervalSince1970
        var entries = (0..<200_000).map { i in
            Entry(path: "/Users/test/Code/apps/project-\(i % 50)/Sources/Folder-\(i % 400)/Document-\(i).swift", name: "Document-\(i).swift", kind: "Dosyalar",
                  project: "project-\(i % 50)", modified: now - Double(i % 900) * 86_400)
        }
        entries.append(Entry(path: "/Applications/Sakla.app", name: "Sakla.app", kind: "Uygulamalar"))
        // Like a real scan, every folder on the way is a record of its own.
        for path in ["/Users/test", "/Users/test/Code", "/Users/test/Code/apps"] {
            entries.append(Entry(path: path, name: URL(fileURLWithPath: path).lastPathComponent, kind: "Klasörler"))
        }
        for project in 0..<50 {
            let base = "/Users/test/Code/apps/project-\(project)"
            entries.append(Entry(path: base, name: "project-\(project)", kind: "Projeler", project: "project-\(project)"))
            entries.append(Entry(path: base + "/Sources", name: "Sources", kind: "Klasörler", project: "project-\(project)"))
        }
        for folder in 0..<400 {
            let project = folder % 50
            entries.append(Entry(path: "/Users/test/Code/apps/project-\(project)/Sources/Folder-\(folder)", name: "Folder-\(folder)", kind: "Klasörler", project: "project-\(project)"))
        }
        let start = Date()
        try await catalog.save(entries)
        print("Catalog write \(entries.count) entries: \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        let reader = try SearchReader(path: folder.appendingPathComponent("catalog.sqlite").path)
        for query in ["", "s", "sakla", "document-12", "dcmnt", "folder-17", "project-3 folder", "bulunmayan-xyz", "sources"] {
            let start = Date()
            let result = try await reader.search(SearchRequest(query: query, roots: ["/Users/test", "/Applications"], now: now))
            let elapsed = Date().timeIntervalSince(start)
            print("Catalog search \(entries.count) entries, \"\(query)\": \(Int(elapsed * 1000)) ms, \(result.count) results")
            if query == "sakla" { XCTAssertEqual(result.first?.entry.name, "Sakla.app") }
            if query == "bulunmayan-xyz" { XCTAssertTrue(result.isEmpty) }
            if ["folder-17", "project-3 folder", "sources"].contains(query) { XCTAssertEqual(result.count, 80) }
            #if !DEBUG
            XCTAssertLessThan(elapsed, 0.5, "Catalog search must stay interactive at this size")
            #endif
        }
    }
}

final class Recorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []
    func append(_ value: Value) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    var snapshot: [Value] { lock.lock(); defer { lock.unlock() }; return values }
}
