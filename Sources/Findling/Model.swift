import AppKit
import SwiftUI
import FindlingCore
import os

@MainActor final class Model: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { search(resetSelection: true) } } }
    @Published var kind = "Tümü" { didSet { if kind != oldValue { search(resetSelection: true) } } }
    @Published var hits: [Hit] = []
    @Published var selection: String?
    @Published var indexing = false
    @Published var indexingProgress: IndexingProgress = .loading
    @Published var searching = false
    @Published var count = 0
    /// Without projects in the index, as for people who don't write code, the Projects filter is hidden.
    @Published var hasProjects = true { didSet { if !hasProjects, kind == "Projeler" { kind = "Tümü" } } }
    var kinds: [(String, String)] { LauncherStyle.kinds.filter { hasProjects || $0.0 != "Projeler" } }
    @Published var notice = "" { didSet { noticeTab = nil } }
    /// Set after `notice` when the notice offers to open Settings at this tab.
    @Published var noticeTab: SettingsTab?
    let shortcut: OpenShortcut
    @Published var warnings: [AccessWarning] = []
    @Published var roots: [String]
    @Published var folderFilters: [String] = []
    /// Names chosen for filter buttons, by path; the folders themselves keep their names.
    @Published var folderFilterNames: [String: String] = [:]
    @Published var excludedFolders: [String] = []
    /// Skip categories the user turned off; everything else in `SkipRules.categories` is skipped.
    @Published var disabledSkips: Set<String> = []
    @Published var activeFolder: String? { didSet { if activeFolder != oldValue { search(resetSelection: true) } } }
    @Published var preferences: [String: Preference]
    @Published var showingPreview = false
    @Published var preview: PreviewContent?
    @Published var updatedAt: Date?
    /// Items each location adds, by its path in `roots`; filled while Settings shows the locations.
    @Published var locationCounts: [String: Int] = [:]
    @Published var textSize: FindlingTextSize = .medium {
        didSet { if !previewing { UserDefaults.standard.set(textSize.rawValue, forKey: "textSize") } }
    }
    @Published var theme: FindlingTheme = .blue {
        didSet { if !previewing { UserDefaults.standard.set(theme.rawValue, forKey: "themeColor") } }
    }
    func scaled(_ points: CGFloat) -> CGFloat { points * textSize.scale }
    var filterHeight: CGFloat { scaled(72) }
    var showsFilters: Bool { true }
    var visibleHits: [Hit] { query.isEmpty && kind == "Tümü" && activeFolder == nil ? Array(hits.prefix(8)) : hits }
    var bodyHeight: CGFloat {
        if showingPreview && selected != nil { return scaled(396) }
        if visibleHits.isEmpty { return scaled(132) }
        return min(scaled(396), scaled(CGFloat(visibleHits.count * 44 + (query.isEmpty ? 28 : 0))) + 16)
    }
    var panelHeight: CGFloat { scaled(56) + (showsFilters ? filterHeight : 0) + bodyHeight + scaled(32) + 2 }
    // Fixture records for --capture-previews; the app itself searches the catalog on disk.
    private var entries: [Entry] = []
    private var prepared = SearchIndex([])
    private var catalog: Catalog?
    private var reader: SearchReader?
    private var watcher: FileWatcher?
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var scanTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var syncing = false
    private var importing = false
    private var pendingChanges: [FileChange] = []
    private var pendingEventId: UInt64 = 0
    private var lastRescanRequest = Date.distantPast
    private var settleTask: Task<Void, Never>?
    private var progressGeneration = UUID()
    private var countTask: Task<Void, Never>?
    private var catalogFolder = ""
    let previewing: Bool
    // Only a deliberate selection locks the row while the deeper search completes.
    private var selectionWasMoved = false

    var selected: Hit? { hits.first { $0.id == selection } }
    init(previewing: Bool = false) {
        self.previewing = previewing
        shortcut = OpenShortcut(saves: !previewing)
        if previewing {
            roots = ["/Applications", FileManager.default.homeDirectoryForCurrentUser.path]
            preferences = [:]
            entries = [
                Entry(path: "/Applications/Safari.app", name: "Safari.app", kind: "Uygulamalar"),
                Entry(path: "/System/Applications/Notes.app", name: "Notes.app", kind: "Uygulamalar"),
                Entry(path: "/Users/demo/Projects/warehouse", name: "warehouse", kind: "Projeler"),
                Entry(path: "/Users/demo/Projects/warehouse/customer-data", name: "customer-data", kind: "Klasörler", project: "warehouse"),
                Entry(path: "/Users/demo/Documents/warehouse-notes.md", name: "warehouse-notes.md", kind: "Dosyalar"),
                Entry(path: "/Users/demo/Projects/warehouse/inventory.json", name: "inventory.json", kind: "Dosyalar", project: "warehouse"),
                Entry(path: "/Users/demo/Projects/warehouse/README.md", name: "README.md", kind: "Dosyalar", project: "warehouse"),
                Entry(path: "/Users/demo/Downloads", name: "Downloads", kind: "Klasörler")
            ]
            prepared = SearchIndex(entries)
            hits = prepared.rank(query: "", preferences: [:])
            selection = hits.first?.id
            count = 190214
            let documents = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Mobile Documents/"
            iCloudAppFolders = [documents + "iCloud~md~obsidian/Documents": ["Obsidian"], documents + "com~apple~Pages/Documents": ["Pages"],
                                documents + "iCloud~com~apple~iBooks/Documents": ["Books"]]
            return
        }
        textSize = UserDefaults.standard.string(forKey: "textSize").flatMap(FindlingTextSize.init(rawValue:)) ?? .medium
        theme = UserDefaults.standard.string(forKey: "themeColor").flatMap(FindlingTheme.init(rawValue:)) ?? .blue
        folderFilters = UserDefaults.standard.stringArray(forKey: "folderFilters") ?? []
        folderFilterNames = UserDefaults.standard.dictionary(forKey: "folderFilterNames") as? [String: String] ?? [:]
        excludedFolders = UserDefaults.standard.stringArray(forKey: "excludedFolders") ?? []
        disabledSkips = Set(UserDefaults.standard.stringArray(forKey: "skipCategoriesOff") ?? [])
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaults = SearchScope.defaultRoots(home: home.path).filter { FileManager.default.fileExists(atPath: $0) }
        let saved = UserDefaults.standard.stringArray(forKey: "roots")
        if UserDefaults.standard.integer(forKey: "scopeVersion") < 1 {
            let migrated = Array(Set((saved ?? []) + defaults)).sorted()
            roots = migrated
            UserDefaults.standard.set(migrated, forKey: "roots")
            UserDefaults.standard.set(1, forKey: "scopeVersion")
        } else {
            roots = saved ?? defaults
        }
        preferences = (UserDefaults.standard.data(forKey: "preferences")).flatMap { try? JSONDecoder().decode([String: Preference].self, from: $0) } ?? [:]
        LauncherStyle.cloudFolders = iCloudAppFolders.compactMap { path, names in names.first.map { (path, "iCloud Drive/" + $0) } }
            + [(home.path + "/Library/Mobile Documents/com~apple~CloudDocs", "iCloud Drive")]
        indexing = true
        indexingProgress = .loading
        // Tasks started here inherit the main thread's priority; indexing must yield to the apps in use.
        scanTask = Task(priority: .utility) { await update(full: false) }
    }

    // Each stage gets its own token, so queued callbacks from cancelled scans or
    // a completed stage cannot overwrite the current status.
    @discardableResult
    private func reportProgress(_ initial: IndexingProgress) -> @Sendable (IndexingProgress) -> Void {
        let generation = UUID()
        progressGeneration = generation
        indexingProgress = initial
        return { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, self.indexing, self.progressGeneration == generation else { return }
                self.indexingProgress = value
            }
        }
    }

    /// Opens the catalog, imports the previous one once, then brings it up to date.
    private func update(full: Bool) async {
        do {
            try await open()
            try await synchronize(full: full)
        } catch is CancellationError {
            return
        } catch {
            notice = error.localizedDescription
        }
        if !Task.isCancelled { indexing = false }
    }

    private func open() async throws {
        if catalog == nil {
            let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Findling")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            catalogFolder = folder.path
            // A new file: the previous catalog stays untouched for older builds.
            let path = folder.appendingPathComponent("catalog-v2.sqlite").path
            let store = try Catalog(path: path)
            catalog = store
            reader = try SearchReader(path: path)
            try await store.upgradeSchema()
        }
        guard let store = catalog else { return }
        if try await store.metadata("legacyImported") != "1" {
            let legacy = URL(fileURLWithPath: catalogFolder).appendingPathComponent("catalog.sqlite").path
            importing = true
            defer { importing = false }
            do {
                let progress = reportProgress(.importing(imported: 0, fraction: 0))
                let importer = Task.detached(priority: .utility) {
                    try await store.migrateLegacy(path: legacy) { imported, fraction in
                        progress(.importing(imported: imported, fraction: fraction))
                    }
                }
                try await withTaskCancellationHandler(operation: { try await importer.value }, onCancel: { importer.cancel() })
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // An unreadable previous catalog is not fatal: the scan rebuilds everything.
                try await store.setMetadata("legacyImported", "1")
                notice = "The previous index could not be imported (\(error.localizedDescription)). Findling is rebuilding it."
            }
        }
        await refreshCount()
        search()
    }

    private func refreshCount() async {
        if let reader, let value = try? await reader.count() { count = value }
        if let reader, let value = try? await reader.contains(kind: "Projeler") { hasProjects = value }
        await refreshLocalizedNames()
    }

    /// Finder's names in the user's languages (Kalender, Takvim for Calendar.app), by path, the
    /// shown one first. Bundles are read once; system folders are a few dozen file checks.
    private var localizedNames: [String: [String]] = [:]
    private var checkedApps: Set<String> = []
    private func refreshLocalizedNames() async {
        guard let reader, let apps = try? await reader.paths(of: "Uygulamalar") else { return }
        let new = apps.filter { !checkedApps.contains($0) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let found = await Task.detached(priority: .utility) { () -> (folders: [String: [String]], apps: [String: [String]]) in
            var names: [String: [String]] = [:]
            for path in new {
                let localized = LocalizedNames.app(path)
                if !localized.isEmpty { names[path] = localized }
            }
            return (LocalizedNames.folders(in: ["/", home, "/Applications", "/System/Applications"]), names)
        }.value
        checkedApps.formUnion(new)
        localizedNames = localizedNames.filter { $0.key.hasSuffix(".app") }.merging(found.folders) { $1 }.merging(iCloudAppFolders) { $1 }.merging(found.apps) { $1 }
    }

    /// App folders iCloud Drive shows (Obsidian, Pages) live outside its own folder; they are
    /// indexed whenever iCloud Drive is. Found at launch.
    private(set) var iCloudAppFolders = LocalizedNames.iCloudAppFolders(home: FileManager.default.homeDirectoryForCurrentUser.path)
    /// The configured locations plus those app folders: what is walked, watched and searched.
    private var indexedRoots: [String] {
        guard roots.contains(where: { $0.hasSuffix("/Library/Mobile Documents/com~apple~CloudDocs") }) else { return roots }
        return roots + iCloudAppFolders.keys.sorted()
    }

    private struct Scope: Codable, Equatable {
        var roots: [String]
        var exclusions: [String]
        var disabledSkips: [String]
        var rules: Int
        init(roots: [String], exclusions: [String], disabledSkips: [String]) {
            self.roots = roots; self.exclusions = exclusions; self.disabledSkips = disabledSkips; rules = SkipRules.version
        }
        // Scopes stored before skip categories or rule versions existed have no such keys.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            roots = try values.decode([String].self, forKey: .roots)
            exclusions = try values.decode([String].self, forKey: .exclusions)
            disabledSkips = try values.decodeIfPresent([String].self, forKey: .disabledSkips) ?? []
            rules = try values.decodeIfPresent(Int.self, forKey: .rules) ?? 0
        }
    }
    private var skipRules: SkipRules { SkipRules(disabled: disabledSkips) }

    /// Makes the catalog match the current scope. Without stored scope or event history, or
    /// when `full` is set, every root is walked; only changed records are written either way.
    /// Afterwards file system events keep it current.
    private func synchronize(full: Bool) async throws {
        guard let catalog else { return }
        syncing = true
        defer { syncing = false; processPending() }
        let scope = Scope(roots: indexedRoots.sorted(), exclusions: excludedFolders.sorted(), disabledSkips: disabledSkips.sorted())
        let rules = skipRules
        let stored = try await catalog.metadata("scope").flatMap { try? JSONDecoder().decode(Scope.self, from: Data($0.utf8)) }
        let identity = FileWatcher.historyIdentity(for: indexedRoots)
        let cursor = try await catalog.metadata("eventCursor").flatMap(UInt64.init)
        let historyValid = try await catalog.metadata("eventStore") == identity && cursor != nil
        if !full, historyValid, stored == scope {
            startWatching(since: cursor)
            return
        }
        let start = FileWatcher.currentEventId
        let onlyScope = !full && historyValid && stored != nil
        // Replaying from the stored cursor covers changes in unchanged locations while Findling was closed.
        startWatching(since: onlyScope ? cursor : start)
        try await catalog.prune(roots: scope.roots, exclusions: scope.exclusions)
        var requests = scope.roots.map { IndexRequest(path: $0) }
        if onlyScope, let stored, stored.disabledSkips == scope.disabledSkips, stored.rules == scope.rules {
            // Only the scope changed: roots not already covered by an indexed root and formerly
            // excluded folders need a walk. A root inside an indexed tree has its records already.
            // Changed skip categories or rules fall through to a full walk, which adds and removes their folders.
            let covered = SearchScope.effectiveRoots(stored.roots, exclusions: SearchScope.Paths(stored.exclusions), rules: rules)
            requests = SearchScope.effectiveRoots(scope.roots, exclusions: SearchScope.Paths(scope.exclusions), rules: rules).filter { !covered.contains($0) }.map { IndexRequest(path: $0) }
                + stored.exclusions.filter { !scope.exclusions.contains($0) }.map { IndexRequest(path: $0) }
        }
        if !requests.isEmpty {
            indexing = true
            let progress = reportProgress(.scanning(discovered: 0, path: ""))
            let report = try await catalog.index(requests, roots: scope.roots, exclusions: scope.exclusions, rules: rules) { value in
                progress(.scanning(discovered: value.discovered, path: value.currentPath))
            }
            warnings = AccessWarning.list(report)
        }
        if !onlyScope { try await catalog.setMetadata("eventCursor", String(start)) }
        try await catalog.setMetadata("eventStore", identity)
        try await catalog.setMetadata("scope", String(decoding: try JSONEncoder().encode(scope), as: UTF8.self))
        updatedAt = Date()
        await refreshCount()
        search()
    }

    private func startWatching(since: UInt64?) {
        if watcher == nil {
            watcher = FileWatcher { [weak self] batch in
                Task { @MainActor [weak self] in self?.enqueue(batch) }
            }
        }
        if !roots.isEmpty, watcher?.start(paths: indexedRoots, since: since) != true { notice = "Findling could not watch your folders for changes. Use Refresh Now after making changes." }
    }

    private func enqueue(_ batch: FileWatcher.Batch) {
        // The catalog's own writes would otherwise report themselves forever.
        pendingChanges += batch.changes.filter { !SearchScope.contains($0.path, in: catalogFolder) }
        pendingEventId = max(pendingEventId, batch.lastEventId)
        if batch.changes.contains(where: \.recursive) { lastRescanRequest = Date() }
        if batch.rescan { refresh(restart: true, full: true); return }
        processPending()
    }

    /// Applies watcher changes one batch at a time; the event cursor is stored only after a
    /// batch is in the catalog, so an interrupted update is replayed on the next launch.
    private func processPending() {
        guard updateTask == nil, !syncing, let catalog, pendingEventId > 0 || !pendingChanges.isEmpty else { return }
        // Bursts of file activity make FSEvents drop events and ask for rescans repeatedly;
        // one check after the burst covers all of them.
        let quiet = Date().timeIntervalSince(lastRescanRequest)
        if quiet < 5, pendingChanges.contains(where: \.recursive) {
            if settleTask == nil {
                settleTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64((5 - quiet) * 1_000_000_000))
                    self?.settleTask = nil
                    self?.processPending()
                }
            }
            return
        }
        let changes = pendingChanges, lastEventId = pendingEventId
        let scopeRoots = indexedRoots, exclusions = excludedFolders, rules = skipRules
        pendingChanges = []
        pendingEventId = 0
        updateTask = Task(priority: .utility) { [weak self] in
            do {
                let requests = try await catalog.plan(changes, roots: scopeRoots, exclusions: exclusions, rules: rules)
                if !requests.isEmpty {
                    let started = Date()
                    let report = try await catalog.index(requests, roots: scopeRoots, exclusions: exclusions, rules: rules)
                    FileWatcher.log.info("Applied \(changes.count) changes as \(requests.count) requests (rescans: \(requests.filter(\.recursive).map(\.path), privacy: .private)): \(report.changes) records in \(Date().timeIntervalSince(started), format: .fixed(precision: 2)) s")
                    if let self, !report.warnings.isEmpty { self.warnings = Array(Set(self.warnings + AccessWarning.list(report))).sorted() }
                    if report.changes > 0 {
                        await self?.refreshCount()
                        self?.search()
                    }
                }
                if lastEventId > 0 { try await catalog.setMetadata("eventCursor", String(lastEventId)) }
                self?.updatedAt = Date()
            } catch is CancellationError {
            } catch {
                self?.notice = error.localizedDescription
            }
            self?.updateTask = nil
            self?.processPending()
        }
    }

    /// Without arguments (Refresh Now) every location is walked again; unchanged items are not
    /// rewritten. `restart` applies a changed scope and walks only what it added.
    func refresh(restart: Bool = false, full: Bool? = nil) {
        guard !previewing, restart || !indexing else { return }
        scanTask?.cancel()
        let previous = scanTask
        indexing = true
        scanTask = Task(priority: .utility) {
            await previous?.value
            await update(full: full ?? !restart)
        }
    }

    /// The location whose walk already reaches `root`, so `root` adds no items.
    func coveringRoot(of root: String) -> String? {
        SearchScope.coveringRoot(of: root, in: roots, rules: skipRules)
    }

    /// Counts every walked root, then takes out the walked roots nested in it, such as
    /// cloud folders in Library under the home folder. iCloud Drive counts its app folders too.
    func refreshLocationCounts() {
        guard !previewing, let reader, !importing else { return }
        let walked = SearchScope.effectiveRoots(indexedRoots, exclusions: SearchScope.Paths(excludedFolders), rules: skipRules)
        let roots = roots, appFolders = iCloudAppFolders.keys.map(SearchScope.standardized)
        countTask?.cancel()
        countTask = Task(priority: .utility) {
            var total: [String: Int] = [:]
            for root in walked {
                guard !Task.isCancelled, let value = try? await reader.count(under: root) else { return }
                total[root] = value
            }
            func own(_ root: String) -> Int {
                let nested = walked.filter { $0 != root && SearchScope.contains($0, in: root) }
                let outermost = nested.filter { inner in !nested.contains { $0 != inner && SearchScope.contains(inner, in: $0) } }
                return (total[root] ?? 0) - outermost.reduce(0) { $0 + (total[$1] ?? 0) }
            }
            var counts: [String: Int] = [:]
            for root in roots {
                let path = SearchScope.standardized(root)
                guard walked.contains(path) else { continue }
                counts[root] = own(path) + (path.hasSuffix("/com~apple~CloudDocs") ? appFolders.filter(walked.contains).reduce(0) { $0 + own($1) } : 0)
            }
            locationCounts = counts
        }
    }

    /// Size of the catalog files and when they were last written.
    var catalogFiles: (bytes: Int64, modified: Date?) {
        if previewing { return (61_400_000, Calendar.current.date(bySettingHour: 19, minute: 32, second: 0, of: Date())) }
        guard !catalogFolder.isEmpty else { return (0, nil) }
        let files = ["catalog-v2.sqlite", "catalog-v2.sqlite-wal", "catalog-v2.sqlite-shm"].compactMap {
            try? FileManager.default.attributesOfItem(atPath: catalogFolder + "/" + $0)
        }
        let bytes = files.reduce(Int64(0)) { $0 + ((($1[.size] as? NSNumber)?.int64Value) ?? 0) }
        return (bytes, updatedAt ?? files.compactMap { $0[.modificationDate] as? Date }.max())
    }

    private var ownApplication: [Entry] {
        let url = Bundle.main.bundleURL.standardizedFileURL
        guard url.pathExtension == "app" else { return [] }
        return [Entry(path: url.path, name: url.lastPathComponent, kind: "Uygulamalar")]
    }

    func search(resetSelection: Bool = false) {
        searchTask?.cancel()
        searching = true
        if resetSelection { selection = nil; selectionWasMoved = false }
        let generation = UUID()
        searchGeneration = generation
        if previewing {
            let snapshot = prepared, q = query, prefs = preferences, filter = kind, folder = activeFolder, exclusions = excludedFolders
            searchTask = Task {
                let worker = Task.detached(priority: .userInitiated) {
                    snapshot.rank(query: q, preferences: prefs, kind: filter, folder: folder, excludedPaths: exclusions)
                }
                let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled else { return }
                publish(result)
                searching = false
            }
            return
        }
        // The catalog's indexes are built at the end of the first import.
        guard let reader, !importing else { searching = false; return }
        let request = SearchRequest(query: query, preferences: preferences, kind: kind, folder: activeFolder,
                                    excludedPaths: excludedFolders, roots: indexedRoots, extra: ownApplication, aliases: localizedNames)
        // Refreshes after background updates must not queue behind indexing work.
        searchTask = Task(priority: .userInitiated) {
            do {
                // Better tiers arrive first; deeper matches follow without delaying them.
                let result = try await reader.search(request) { partial in
                    Task { @MainActor in
                        guard self.searchGeneration == generation else { return }
                        self.publish(partial)
                    }
                }
                guard !Task.isCancelled, searchGeneration == generation else { return }
                publish(result)
                searching = false
            } catch is CancellationError {
            } catch {
                guard searchGeneration == generation else { return }
                searching = false
                notice = error.localizedDescription
            }
        }
    }
    private func publish(_ result: [Hit]) {
        hits = Search.arranged(result, preferences: preferences)
        if !selectionWasMoved || !hits.contains(where: { $0.id == selection }) { selection = hits.first?.id }
    }
    func select(_ hit: Hit) { selectionWasMoved = true; selection = hit.id }
    /// The other fixtures exist only in the index; preview details need files on disk.
    func addFixtures(_ added: [Entry]) { entries += added; prepared = SearchIndex(entries) }
    func savePreferences() {
        if !previewing, let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: "preferences") }
        search()
    }
    func pin(_ hit: Hit) {
        preferences[hit.id, default: Preference()].pinned.toggle(); savePreferences()
    }
    func hide(_ hit: Hit) {
        preferences[hit.id, default: Preference()].hidden = true; savePreferences()
    }
    func restoreHidden() {
        for key in Array(preferences.keys) { preferences[key]?.hidden = false }; savePreferences()
    }
    func open(_ hit: Hit? = nil) {
        guard let hit = hit ?? selected else { return }
        guard NSWorkspace.shared.open(URL(fileURLWithPath: hit.id)) else { notice = "Could not open: \(hit.entry.name)"; return }
        remember(hit)

        if hit.id != Bundle.main.bundleURL.standardizedFileURL.path { NSApp.hide(nil) }
    }
    private func remember(_ hit: Hit) {
        preferences[hit.id, default: Preference()].recordOpen(query: query)
        savePreferences()
    }
    func reveal(_ hit: Hit? = nil) {
        if let hit = hit ?? selected {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hit.id)])
            remember(hit)
        }
    }
    func addFolder() { chooseFolders(title: "Add search locations") { folders in
        for path in folders where !self.roots.contains(path) { self.roots.append(path) }
        self.persistRoots()
    } }
    /// From the launcher the chosen folder is selected right away: it was added to search in it.
    func addFolderFilter(in window: NSWindow? = nil, select: Bool = false) { chooseFolders(title: "Add folder filters", in: window) { folders in
        self.addFolderFilters(folders, select: select)
    } }
    func addFolderFilters(_ folders: [String], select: Bool = false) {
        let roots = roots
        for path in folders where !folderFilters.contains(path) {
            folderFilters.append(path)
            // Only a folder no location reaches becomes one, such as a cloud folder in the skipped Library;
            // inside the home folder it would add nothing.
            if !self.roots.contains(path), coveringRoot(of: path) == nil { self.roots.append(path) }
        }
        persistFilters()
        if self.roots != roots { persistRoots() }
        if select, let first = folders.first { activeFolder = first }
    }
    func filterTitle(_ path: String) -> String { folderFilterNames[path] ?? LauncherStyle.folderName(path) }
    /// Removes the button only; a search location added with it stays.
    func removeFolderFilter(_ path: String) {
        folderFilters.removeAll { $0 == path }
        folderFilterNames[path] = nil
        persistFilters()
    }
    func renameFolderFilter(_ path: String, in window: NSWindow? = nil) {
        let folder = LauncherStyle.folderName(path)
        let alert = NSAlert()
        alert.messageText = "Rename Filter"
        alert.informativeText = "This name appears on the button in the Search in row. The folder “\(folder)” keeps its name. Leave the field empty to use the folder name."
        let field = NSTextField(string: filterTitle(path))
        field.placeholderString = folder
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let apply = { (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            self.folderFilterNames[path] = name.isEmpty || name == folder ? nil : name
            self.persistFilters()
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: apply) } else { apply(alert.runModal()) }
    }
    func addExcludedFolder() { chooseFolders(title: "Exclude folders from search") { folders in
        for path in folders where !self.excludedFolders.contains(path) { self.excludedFolders.append(path) }
        self.persistExclusions()
    } }
    /// With a window, the panel is its sheet: the launcher stays open while a sheet is attached.
    private func chooseFolders(title: String, in window: NSWindow? = nil, completion: @escaping ([String]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title; panel.prompt = "Choose"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        guard let window else {
            if panel.runModal() == .OK { completion(panel.urls.map { $0.standardizedFileURL.path }) }
            return
        }
        panel.beginSheetModal(for: window) { response in
            if response == .OK { completion(panel.urls.map { $0.standardizedFileURL.path }) }
        }
    }
    func persistRoots() {
        if !previewing { UserDefaults.standard.set(roots, forKey: "roots") }
        search(resetSelection: true)
        refresh(restart: true)
    }
    func persistFilters() {
        if let activeFolder, !folderFilters.contains(activeFolder) { self.activeFolder = nil }
        folderFilterNames = folderFilterNames.filter { folderFilters.contains($0.key) }
        if !previewing {
            UserDefaults.standard.set(folderFilters, forKey: "folderFilters")
            UserDefaults.standard.set(folderFilterNames, forKey: "folderFilterNames")
        }
    }
    func setSkipCategory(_ id: String, enabled: Bool) {
        if enabled { disabledSkips.remove(id) } else { disabledSkips.insert(id) }
        if !previewing { UserDefaults.standard.set(disabledSkips.sorted(), forKey: "skipCategoriesOff") }
        refresh(restart: true)
    }
    func persistExclusions() {
        if !previewing { UserDefaults.standard.set(excludedFolders, forKey: "excludedFolders") }
        // Apply immediately, including to cached results, while the new index is built.
        search(resetSelection: true)
        refresh(restart: true)
    }
    func move(_ delta: Int) {
        guard !visibleHits.isEmpty else { return }
        selectionWasMoved = true
        let index = visibleHits.firstIndex { $0.id == selection } ?? 0
        selection = visibleHits[min(max(0, index + delta), visibleHits.count - 1)].id
    }
    func cycleFilter(_ delta: Int) {
        let kinds = self.kinds.map(\.0)
        let index = kinds.firstIndex(of: kind) ?? 0
        kind = kinds[(index + delta + kinds.count) % kinds.count]
    }
}

/// A folder a walk could not read, with the reason the file system gave.
struct AccessWarning: Hashable, Comparable {
    let path: String
    let reason: String
    static func < (a: AccessWarning, b: AccessWarning) -> Bool { a.path < b.path }
    /// Walks report `name: reason` for folders they could not list and `Could not read: path` for roots.
    static func list(_ report: IndexReport) -> [AccessWarning] {
        zip(report.inaccessiblePaths, report.warnings).map { path, message in
            let prefix = URL(fileURLWithPath: path).lastPathComponent + ": "
            if message.hasPrefix(prefix) { return AccessWarning(path: path, reason: String(message.dropFirst(prefix.count))) }
            return AccessWarning(path: path, reason: message.hasPrefix("Could not read") ? "Could not open this folder." : message)
        }
    }
}
