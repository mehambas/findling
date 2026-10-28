import XCTest
@testable import FindlingCore

private final class ProgressRecorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []
    func append(_ value: Value) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    var snapshot: [Value] { lock.lock(); defer { lock.unlock() }; return values }
}

final class SearchTests: XCTestCase {
    func testScanProgressCountsUniqueIncludedItems() throws {
        // Keep scope paths free of macOS's /var -> /private/var alias.
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/scan-progress-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in ["public", "private", "node_modules"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
            try Data().write(to: root.appendingPathComponent(directory + "/document.txt"))
        }
        let progress = ProgressRecorder<ScanProgress>()
        let scan = Scanner.scan(roots: [root.path, root.appendingPathComponent("public").path], excludedPaths: [root.appendingPathComponent("private").path], progress: { progress.append($0) })
        let updates = progress.snapshot
        XCTAssertEqual(updates.first?.discovered, 0)
        XCTAssertEqual(updates.last?.discovered, scan.entries.count)
        XCTAssertEqual(scan.entries.count, 3, scan.entries.map(\.path).sorted().joined(separator: "\n")) // root, public, document
        XCTAssertTrue(updates.allSatisfy { !$0.currentPath.isEmpty })
        XCTAssertEqual(updates.map(\.discovered), updates.map(\.discovered).sorted())
    }

    func testPreparationProgressUsesActualTotalAndPreservesResults() {
        let entries = (0..<600).map { Entry(path: "/docs/invoice-\($0).pdf", name: "invoice-\($0).pdf", kind: "Dosyalar") }
        let progress = ProgressRecorder<(Int, Int)>()
        let index = SearchIndex(entries, preferredPaths: [entries[0].path]) { progress.append(($0, $1)) }
        let updates = progress.snapshot
        XCTAssertEqual(updates.first?.0, 0)
        XCTAssertEqual(updates.last?.0, entries.count)
        XCTAssertTrue(updates.allSatisfy { $0.1 == entries.count && $0.0 <= $0.1 })
        XCTAssertEqual(updates.map { $0.0 }, updates.map { $0.0 }.sorted())
        XCTAssertEqual(index.rank(query: "invoice", preferences: [:], priorityOnly: true).map(\.id), [entries[0].path])
        let emptyProgress = ProgressRecorder<(Int, Int)>()
        _ = SearchIndex([]) { emptyProgress.append(($0, $1)) }
        XCTAssertEqual(emptyProgress.snapshot.last?.0, 0)
        XCTAssertEqual(emptyProgress.snapshot.last?.1, 0)
    }
    func testTurkishNormalization() {
        XCTAssertEqual(Search.normalize("IŞIK İÇİN GÜNEŞ"), "isik icin gunes")
        let entries = [Entry(path: "/f/çalışma.txt", name: "çalışma.txt", kind: "Dosyalar")]
        XCTAssertEqual(Search.rank(entries, query: "calisma", preferences: [:]).count, 1)
    }
    func testExactNameBeatsPathAndUsage() {
        let exact = Entry(path: "/apps/Sakla.app", name: "Sakla.app", kind: "Uygulamalar")
        let noisy = Entry(path: "/sakla/old/readme.md", name: "readme.md", kind: "Dosyalar", project: "sakla")
        var p = Preference(); p.opens = 100; p.pinned = true
        XCTAssertEqual(Search.rank([noisy, exact], query: "sakla", preferences: [noisy.path: p]).first?.entry, exact)
    }
    func testBackupCopiesFollowTheirOriginals() {
        let now = Date().timeIntervalSince1970
        let original = Entry(path: "/site/functions.php", name: "functions.php", kind: "Dosyalar", modified: now - 86400 * 30)
        let copy = Entry(path: "/site/Backups/pre-pull/functions.php", name: "functions.php", kind: "Dosyalar", modified: now)
        let prefix = Entry(path: "/site/functions-old.php", name: "functions-old.php", kind: "Dosyalar", modified: now)
        let ranked = Search.rank([prefix, copy, original], query: "functions", preferences: [:], now: now)
        XCTAssertEqual(ranked.map(\.id), [copy.path, original.path, prefix.path])
        XCTAssertEqual(Search.demotingBackups(ranked).map(\.id), [original.path, copy.path, prefix.path])
        var opened = Preference(); opened.queries["functions"] = QueryUse(); opened.queries["functions"]?.lastOpened = now
        XCTAssertEqual(Search.demotingBackups(Search.rank([copy, original], query: "functions", preferences: [copy.path: opened], now: now)).first?.id, copy.path)
        XCTAssertFalse(Search.insideBackup("/site/backups"))
    }
    func testSameNamedFoldersListShallowestFirstUnlessOpened() {
        let now = Date().timeIntervalSince1970
        let deep = Entry(path: "/n/docs/archive/tugba", name: "tugba", kind: "Klasörler", modified: now)
        let middle = Entry(path: "/n/storage/Tugba", name: "Tugba", kind: "Klasörler", modified: now - 86400 * 2)
        let shallow = Entry(path: "/n/tugba", name: "tugba", kind: "Klasörler", modified: now - 86400 * 30)
        let file = Entry(path: "/n/docs/archive/tugba.txt", name: "tugba.txt", kind: "Dosyalar", modified: now - 86400)
        let ranked = Search.rank([deep, middle, shallow, file], query: "tugba", preferences: [:], now: now)
        let arranged = Search.arranged(ranked, preferences: [:])
        XCTAssertEqual(arranged.filter { $0.entry.kind == "Klasörler" }.map(\.id), [shallow.path, middle.path, deep.path])
        XCTAssertEqual(arranged.firstIndex { $0.id == file.path }, ranked.firstIndex { $0.id == file.path })
        var opened = Preference(); opened.opens = 1; opened.queries["tugba"] = QueryUse(); opened.queries["tugba"]?.lastOpened = now
        let preferences = [deep.path: opened]
        let remembered = Search.arranged(Search.rank([deep, middle, shallow, file], query: "tugba", preferences: preferences, now: now), preferences: preferences)
        XCTAssertEqual(remembered.first?.id, deep.path)
        XCTAssertEqual(remembered.filter { $0.entry.kind == "Klasörler" }.map(\.id), [deep.path, shallow.path, middle.path])
    }
    func testHiddenPinnedFiltersAndIrrelevant() {
        let a = Entry(path: "/a", name: "Fatura.pdf", kind: "Dosyalar")
        let b = Entry(path: "/b", name: "Fatura.pdf", kind: "Dosyalar")
        var p = Preference(); p.pinned = true
        XCTAssertEqual(Search.rank([a,b], query: "fatura", preferences: [b.path:p]).first?.id, b.path)
        p.hidden = true
        XCTAssertEqual(Search.rank([a,b], query: "fatura", preferences: [b.path:p]).map(\.id), [a.path])
        XCTAssertTrue(Search.rank([a], query: "xzy", preferences: [:]).isEmpty)
        XCTAssertTrue(Search.rank([a], query: "", preferences: [:], kind: "Projeler").isEmpty)
        XCTAssertEqual(Search.rank([a], query: "ftra", preferences: [:]).count, 1)
    }
    func testPreparedIndexUpdatesResultsAcross190ThousandEntries() {
        var entries = (0..<190_622).map { i in
            Entry(path: "/Users/test/Code/apps/project-\(i % 50)/Sources/Folder/Document-\(i).swift", name: "Document-\(i).swift", kind: "Dosyalar", project: "project-\(i % 50)")
        }
        entries.append(Entry(path: "/Applications/Ada.app", name: "Ada.app", kind: "Uygulamalar"))
        entries.append(Entry(path: "/Applications/Sakla.app", name: "Sakla.app", kind: "Uygulamalar"))
        let index = SearchIndex(entries)
        for query in ["sakla", "ada", "Document-12", "bulunmayan-xyz"] {
            let start = Date()
            let result = index.rank(query: query, preferences: [:])
            let elapsed = Date().timeIntervalSince(start)
            print("Prepared search \(entries.count) entries, \(query): \(Int(elapsed * 1000)) ms")
            if query == "ada" { XCTAssertEqual(result.first?.entry.name, "Ada.app"); XCTAssertFalse(result.contains { $0.entry.name == "Sakla.app" }) }
            if query == "sakla" { XCTAssertEqual(result.first?.entry.name, "Sakla.app") }
            if query == "bulunmayan-xyz" { XCTAssertTrue(result.isEmpty) }
            XCTAssertLessThanOrEqual(result.count, 80)
            #if !DEBUG
            XCTAssertLessThan(elapsed, 1.0, "Prepared search must respond within a second at this catalog size")
            #endif
        }
    }
    func testHomeScopeCoversPersonalFoldersAndExplicitCloudRoots() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        for folder in ["Notes", "PersonalArchive", "Library/CloudStorage/Drive", "Library/Caches"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["Notes/Gehaltsabrechnung.pdf", "PersonalArchive/letter.pdf", "Library/CloudStorage/Drive/cloud.pdf", "Library/Caches/noise.txt"] {
            try Data().write(to: root.appendingPathComponent(file))
        }
        let roots = SearchScope.defaultRoots(home: root.path)
        XCTAssertTrue(roots.contains(root.path))
        XCTAssertTrue(roots.contains(SearchScope.cryptexApplications))
        let scan = Scanner.scan(roots: [root.path, root.appendingPathComponent("Library/CloudStorage").path])
        XCTAssertTrue(scan.entries.contains { $0.name == "Gehaltsabrechnung.pdf" })
        XCTAssertTrue(scan.entries.contains { $0.name == "letter.pdf" })
        XCTAssertTrue(scan.entries.contains { $0.name == "cloud.pdf" })
        XCTAssertFalse(scan.entries.contains { $0.name == "noise.txt" })
    }
    func testSafariIsFoundInsideTheCryptex() throws {
        let safari = SearchScope.cryptexApplications + "/Safari.app"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: safari))
        let scan = Scanner.scan(roots: ["/Applications", SearchScope.cryptexApplications])
        XCTAssertEqual(scan.entries.filter { $0.name == "Safari.app" }.map(\.path), [safari])
    }
    func testOverviewFindsDottedFolderBeforeDeepScanFinishes() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let project = root.appendingPathComponent("Sites/moebelbraum.yng.io")
        try fm.createDirectory(at: project.appendingPathComponent("Sources/Deep"), withIntermediateDirectories: true)
        try Data().write(to: project.appendingPathComponent("Package.swift"))
        try Data().write(to: project.appendingPathComponent("Sources/Deep/main.swift"))
        let overview = Scanner.scan(roots: [root.path], maxDepth: 2)
        let hits = SearchIndex(overview.entries).rank(query: "moebelbraum.yng.io", preferences: [:])
        XCTAssertEqual(hits.first.map { URL(fileURLWithPath: $0.entry.path).resolvingSymlinksInPath().path }, project.resolvingSymlinksInPath().path)
        XCTAssertFalse(overview.entries.contains { $0.name == "main.swift" })
        let full = Scanner.scan(roots: [root.path])
        XCTAssertEqual(full.entries.first { $0.name == "main.swift" }?.project, "moebelbraum.yng.io")
    }
    func testQueryChoiceIsRememberedAndRecentChoiceWins() throws {
        let exact = Entry(path: "/projects/warehouse", name: "warehouse", kind: "Projeler")
        let chosen = Entry(path: "/projects/warehouse/customer-data", name: "customer-data", kind: "Klasörler")
        let index = SearchIndex([exact, chosen])
        XCTAssertEqual(index.rank(query: "warehouse", preferences: [:]).first?.id, exact.path)
        var use = Preference(); use.recordOpen(query: "  WAREHOUSE  ", now: 100)
        let stored = try JSONEncoder().encode([chosen.path: use])
        var preferences = try JSONDecoder().decode([String: Preference].self, from: stored)
        let result = index.rank(query: "warehouse", preferences: preferences)
        XCTAssertEqual(result.first?.id, chosen.path)
        XCTAssertTrue(result.first?.reason.contains("Previously opened") == true)
        XCTAssertEqual(index.rank(query: "ware", preferences: preferences).first?.id, chosen.path)
        preferences[exact.path, default: Preference()].recordOpen(query: "warehouse", now: 200)
        XCTAssertEqual(index.rank(query: "warehouse", preferences: preferences).first?.id, exact.path)
        preferences[exact.path]?.hidden = true
        XCTAssertEqual(index.rank(query: "warehouse", preferences: preferences).first?.id, chosen.path)
        XCTAssertTrue(index.rank(query: "unrelated", preferences: preferences).isEmpty)
    }
    func testAbbreviatedQueryRemembersOpenedFolderButExactChoiceWins() {
        let folder = Entry(path: "/Sites/moebelbraum.yng.io", name: "moebelbraum.yng.io", kind: "Klasörler")
        let image = Entry(path: "/Downloads/moebelbraum.jpg", name: "moebelbraum.jpg", kind: "Dosyalar")
        var prior = Preference(); prior.recordOpen(query: "moebelbraum.yng.io", now: 200)
        let index = SearchIndex([image, folder], preferredPaths: [folder.path])
        var prefs = [folder.path: prior]
        XCTAssertEqual(index.rank(query: "MOEBELB", preferences: prefs).first?.id, folder.path)
        XCTAssertEqual(index.rank(query: "moebelb", preferences: prefs, priorityOnly: true).first?.id, folder.path)
        var exact = Preference(); exact.recordOpen(query: "moebelb", now: 100)
        prefs[image.path] = exact
        XCTAssertEqual(index.rank(query: "moebelb", preferences: prefs).first?.id, image.path)
        XCTAssertEqual(index.rank(query: "mo", preferences: prefs).first?.queryMatch, 0)
        XCTAssertTrue(index.rank(query: "unrelated", preferences: prefs).isEmpty)
    }
    func testFolderFiltersAndExclusionsRespectPathBoundariesAndMemory() {
        let entries = [
            Entry(path: "/Sites/site/report.md", name: "report.md", kind: "Dosyalar"),
            Entry(path: "/Sites/site/private/report.md", name: "report.md", kind: "Dosyalar"),
            Entry(path: "/Sites/site-archive/report.md", name: "report.md", kind: "Dosyalar")
        ]
        var chosen = Preference(); chosen.recordOpen(query: "report")
        let index = SearchIndex(entries)
        let results = index.rank(query: "report", preferences: [entries[1].path: chosen], folder: "/Sites/site", excludedPaths: ["/Sites/site/private"])
        XCTAssertEqual(results.map(\.id), [entries[0].path])
        XCTAssertTrue(index.rank(query: "report", preferences: [:], roots: []).isEmpty)
        XCTAssertEqual(index.rank(query: "report", preferences: [:], roots: ["/Sites/site-archive"]).map(\.id), [entries[2].path])
    }
    func testPrioritySearchIncludesRememberedFilesAndPromotedFiles() {
        let file = Entry(path: "/docs/invoice.txt", name: "invoice.txt", kind: "Dosyalar")
        var index = SearchIndex([file])
        XCTAssertTrue(index.rank(query: "invoice", preferences: [:], priorityOnly: true).isEmpty)
        index.promote(file); index.promote(file)
        XCTAssertEqual(index.rank(query: "invoice", preferences: [:], priorityOnly: true).map(\.id), [file.path])
        let restored = SearchIndex([file], preferredPaths: [file.path])
        XCTAssertEqual(restored.rank(query: "invoice", preferences: [:], priorityOnly: true).first?.id, file.path)
    }
    func testExcludedFolderCannotReenterThroughExplicitRoot() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        for dir in ["private/deeper", "private-other", "public"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
            try Data().write(to: root.appendingPathComponent(dir + "/report.txt"))
        }
        let excluded = root.appendingPathComponent("private").path
        let scan = Scanner.scan(roots: [root.path, excluded + "/deeper"], excludedPaths: [excluded])
        XCTAssertFalse(scan.entries.contains { SearchScope.contains($0.path, in: excluded) })
        XCTAssertTrue(scan.entries.contains { $0.path.contains("private-other/report.txt") })
        XCTAssertTrue(scan.entries.contains { $0.path.contains("public/report.txt") })
    }
    func testEffectiveRootsDropCoveredRootsButKeepSkippedOnes() {
        let home = "/u/home"
        XCTAssertEqual(SearchScope.effectiveRoots([home, home + "/Sites", home + "/Nextcloud"], exclusions: SearchScope.Paths([])), [home])
        XCTAssertEqual(SearchScope.effectiveRoots([home, home + "/Library/CloudStorage", "/Applications"], exclusions: SearchScope.Paths([])),
                       ["/Applications", home, home + "/Library/CloudStorage"])
        XCTAssertEqual(SearchScope.effectiveRoots([home + "/Sites", home], exclusions: SearchScope.Paths([home + "/Sites"])), [home])
    }
    func testCoveringRootIsTheOutermostRootThatReachesALocation() {
        let home = "/u/home", cloud = home + "/Library/CloudStorage"
        let roots = ["/Applications", home, home + "/Sites", home + "/Sites/shop", cloud, cloud + "/Nextcloud-x"]
        XCTAssertEqual(SearchScope.coveringRoot(of: home + "/Sites", in: roots), home)
        XCTAssertEqual(SearchScope.coveringRoot(of: home + "/Sites/shop", in: roots), home)
        XCTAssertNil(SearchScope.coveringRoot(of: home, in: roots))
        XCTAssertNil(SearchScope.coveringRoot(of: cloud, in: roots))
        XCTAssertEqual(SearchScope.coveringRoot(of: cloud + "/Nextcloud-x", in: roots), cloud)
        XCTAssertNil(SearchScope.coveringRoot(of: home + "/.config", in: roots + [home + "/.config"]))
        XCTAssertNil(SearchScope.coveringRoot(of: home + "/Code/node_modules", in: [home, home + "/Code/node_modules"]))
        XCTAssertEqual(SearchScope.coveringRoot(of: home + "/Code/node_modules", in: [home, home + "/Code/node_modules"], rules: SkipRules(disabled: ["dependencies"])), home)
    }
    func testOldPreferencesRemainCompatible() throws {
        let old = Data(#"{"pinned":true,"hidden":false,"opens":12,"lastOpened":123}"#.utf8)
        let decoded = try JSONDecoder().decode(Preference.self, from: old)
        XCTAssertTrue(decoded.pinned); XCTAssertEqual(decoded.opens, 12); XCTAssertEqual(decoded.lastOpened, 123)
        XCTAssertTrue(decoded.queries.isEmpty)
        var blank = decoded; blank.recordOpen(query: "   ", now: 456)
        XCTAssertTrue(blank.queries.isEmpty); XCTAssertEqual(blank.opens, 13)
    }
    func testCatalogRoundTripAndReplacement() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try Catalog(path: folder.appendingPathComponent("index.sqlite").path)
        let empty = try await store.load(); XCTAssertTrue(empty.isEmpty)
        let entry = Entry(path: "/test", name: "test", kind: "Projeler")
        try await store.save([entry])
        let restored = try await store.load(); XCTAssertEqual(restored, [entry])
        try await store.save([])
        let replaced = try await store.load(); XCTAssertTrue(replaced.isEmpty)
    }
    func testScannerExcludesDependenciesAndSymlinksRecognizesProjects() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        for dir in ["project/node_modules", "project/.git", "project/Sources", "Demo.app/Contents"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent("project/node_modules/noise.js"))
        try Data().write(to: root.appendingPathComponent("project/Sources/main.swift"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("loop").path, withDestinationPath: root.path)
        let scan = Scanner.scan(roots: [root.path, root.appendingPathComponent("project").path])
        XCTAssertFalse(scan.entries.contains { $0.path.contains("node_modules") || $0.path.contains("Contents") || $0.name == "loop" })
        XCTAssertEqual(scan.entries.first { $0.name == "project" }?.kind, "Projeler")
        XCTAssertEqual(scan.entries.first { $0.name == "main.swift" }?.project, "project")
        XCTAssertEqual(Set(scan.entries.map(\.path)).count, scan.entries.count)
        XCTAssertFalse(Scanner.scan(roots: [root.appendingPathComponent("missing").path]).warnings.isEmpty)
    }
    func testSkipCategoriesCoverOutputCMSAndGeneratedImagesUnlessTurnedOff() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let files = ["project/.git/HEAD", "project/out/o.txt", "project/src/a.swift", "out/keep.txt", "pkg.egg-info/PKG-INFO",
                     "site/.git/HEAD", "site/web/wp/wp-includes/load.php", "site/web/wp/index.php", "site/web/app/plugins/seo/seo.php",
                     "site/web/app/themes/own/style.css", "site/web/app/uploads/2024/photo.jpg", "site/web/app/uploads/2024/photo-300x200.jpg",
                     "site/web/app/uploads/2024/photo-300x200@2x.jpg", "site/web/app/uploads/2024/photo-scaled.jpg", "site/web/app/uploads/2024/photo-e1700000000.jpg",
                     "site/web/app/uploads/2024/lonely-100x100.jpg", "site/web/app/uploads/2024/report-2024.pdf", "docs/plugins/list.md", "go/pkg/sumdb/x", "go/pkg/mod/y.go",
                     "tool/env/pyvenv.cfg", "tool/env/lib/six.py", "notes/env/settings.txt",
                     "plugin/tags/2.4.1/old.php", "plugin/tags/2.10.0-RC1/rc.php", "plugin/tags/2.10.0/new.php", "plugin/trunk/trunk.php",
                     "blog/tags/swift/post.md", "blog/tags/1.0/tagged.md", "repo/refs/tags/v1.0"]
        for file in files {
            try fm.createDirectory(at: root.appendingPathComponent(file).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: root.appendingPathComponent(file))
        }
        let entries = Scanner.scan(roots: [root.path]).entries
        let names = Set(entries.map(\.name))
        for skipped in ["o.txt", "PKG-INFO", "pkg.egg-info", "wp", "load.php", "index.php", "seo.php", "photo-300x200.jpg", "photo-300x200@2x.jpg", "photo-scaled.jpg", "photo-e1700000000.jpg", "mod", "y.go", "pyvenv.cfg", "six.py", "2.4.1", "old.php", "rc.php"] {
            XCTAssertFalse(names.contains(skipped), skipped)
        }
        // The same name outside a WordPress content folder stays.
        XCTAssertFalse(entries.contains { $0.path.hasSuffix("/web/app/plugins") })
        XCTAssertTrue(entries.contains { $0.path.hasSuffix("/docs/plugins") })
        for kept in ["keep.txt", "a.swift", "themes", "style.css", "uploads", "photo.jpg", "lonely-100x100.jpg", "report-2024.pdf", "list.md", "sumdb", "settings.txt", "new.php", "trunk.php", "post.md", "tagged.md", "v1.0"] {
            XCTAssertTrue(names.contains(kept), kept)
        }
        XCTAssertEqual(SkipRules.original(ofGeneratedImage: "photo-300x200@2x.JPG"), "photo.JPG")
        XCTAssertNil(SkipRules.original(ofGeneratedImage: "a-3x.jpg"))
        XCTAssertNil(SkipRules.original(ofGeneratedImage: "x-10x10.txt"))
        XCTAssertNil(SkipRules.original(ofGeneratedImage: "-10x10.jpg"))
        XCTAssertEqual(SkipRules.newestRelease(among: ["5.12", "5.3.10", "5.12.4", "5.4.7-RC1", "v5.9"]), "5.12.4")
        XCTAssertEqual(SkipRules.newestRelease(among: ["2.2.0-RC1", "2.2"]), "2.2")
        XCTAssertNil(SkipRules.newestRelease(among: ["2023", "2024"]))
        XCTAssertNil(SkipRules.newestRelease(among: ["1.0", "swift"]))
        XCTAssertNil(SkipRules.newestRelease(among: ["1.0"]))
        let everything = Set(Scanner.scan(roots: [root.path], rules: SkipRules(disabled: Set(SkipRules.categories.map(\.id)))).entries.map(\.name))
        for name in ["o.txt", "wp", "load.php", "seo.php", "photo-300x200.jpg", "y.go", "PKG-INFO", "six.py", "old.php", "rc.php"] { XCTAssertTrue(everything.contains(name), name) }
        XCTAssertTrue(Scanner.skipsComponents(of: root.appendingPathComponent("project/node_modules/x").path, below: root.path))
        XCTAssertFalse(Scanner.skipsComponents(of: root.appendingPathComponent("project/node_modules/x").path, below: root.path, rules: SkipRules(disabled: ["dependencies"])))
    }
}
