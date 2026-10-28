import Foundation

public struct Scan: Sendable {
    public var entries: [Entry]
    public var warnings: [String]
    public var inaccessiblePaths: [String]
}
public struct ScanProgress: Sendable {
    public let discovered: Int
    public let currentPath: String
    public init(discovered: Int, currentPath: String) { self.discovered = discovered; self.currentPath = currentPath }
}
public enum SearchScope {
    public struct Paths: Sendable {
        private let values: [(root: String, prefix: String)]
        public init(_ paths: [String]) {
            values = paths.map { ($0, $0 == "/" ? "/" : $0 + "/") }
        }
        public func contains(_ path: String) -> Bool {
            values.contains { path == $0.root || path.hasPrefix($0.prefix) }
        }
    }
    public static func contains(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
    /// Safari lives here since macOS 13; /Applications only holds a symlink, which the scan skips.
    /// /System/Cryptexes/App links here too, and scanned paths come back resolved.
    public static let cryptexApplications = "/System/Volumes/Preboot/Cryptexes/App/System/Applications"
    public static func defaultRoots(home: String) -> [String] {
        [home, "/Applications", "/System/Applications", cryptexApplications,
         home + "/Library/Mobile Documents/com~apple~CloudDocs",
         home + "/Library/CloudStorage"]
    }
    public static func standardized(_ path: String) -> String { CatalogPath.canonical(URL(fileURLWithPath: path).standardizedFileURL.path) }
    /// Roots whose tree is not already covered by another root. Explicit cloud / hidden roots
    /// survive when their ancestor's scan skips them.
    public static func effectiveRoots(_ roots: [String], exclusions: SearchScope.Paths, rules: SkipRules = .default) -> [String] {
        let unique = Array(Set(roots.map(standardized))).sorted { $0.count < $1.count }
        return unique.filter { root in
            !exclusions.contains(root) && !unique.contains { other in
                guard other != root, contains(root, in: other) else { return false }
                return !Scanner.skipsComponents(of: root, below: other, rules: rules)
            }
        }.sorted()
    }
    /// The outermost other root whose walk already reaches `root`, so `root` adds nothing.
    /// Nil for roots inside a skipped or hidden folder of every other root, like cloud folders in Library.
    public static func coveringRoot(of root: String, in roots: [String], rules: SkipRules = .default) -> String? {
        let path = standardized(root)
        return roots.filter { other in
            let parent = standardized(other)
            return parent != path && contains(path, in: parent) && !Scanner.skipsComponents(of: path, below: parent, rules: rules)
        }.min { standardized($0).count < standardized($1).count }
    }
}

/// Folders nobody searches for. Each category can be turned off in Settings.
public struct SkipCategory: Identifiable, Sendable {
    struct Marker: Sendable { let name: String; let marker: String }
    struct Nested: Sendable { let names: Set<String>; let parents: Set<String>; let sibling: String }
    public let id: String
    public let title: String
    public let detail: String
    /// A few typical names for a one-line summary; `detail` has the full list.
    public let examples: String
    /// Folder names skipped wherever they occur.
    let names: Set<String>
    /// Generic names (`out`, `bin`, `tmp`) that mean output only inside a project.
    let projectNames: Set<String>
    let suffixes: [String]
    /// A folder of `name` is skipped when `marker` exists inside it.
    let markers: [Marker]
    /// A folder is skipped when its parent has one of `parents` as name and contains `sibling`.
    let nested: [Nested]
    /// Image copies with a size suffix whose original lies in the same folder.
    let generatedImages: Bool
    /// Release folders in a `tags` folder other than the newest.
    let olderReleases: Bool
    init(id: String, title: String, detail: String, examples: String, names: Set<String> = [], projectNames: Set<String> = [], suffixes: [String] = [],
         markers: [Marker] = [], nested: [Nested] = [], generatedImages: Bool = false, olderReleases: Bool = false) {
        self.id = id; self.title = title; self.detail = detail; self.examples = examples; self.names = names; self.projectNames = projectNames
        self.suffixes = suffixes; self.markers = markers; self.nested = nested; self.generatedImages = generatedImages
        self.olderReleases = olderReleases
    }
}

/// The skip categories in effect. Names are checked for every folder; markers and parents cost
/// one `access` call for the few folders whose name matches.
public struct SkipRules: Sendable, Equatable {
    public static let categories: [SkipCategory] = [
        SkipCategory(id: "dependencies", title: "Dependencies and packages",
                     detail: "node_modules, vendor, Pods, Carthage, site-packages, __pycache__, Python environments (venv, env), deps, _build, *.egg-info and the Go module cache.",
                     examples: "node_modules, vendor, Pods, venv",
                     names: ["node_modules", "bower_components", "jspm_packages", "vendor", "Pods", "Carthage", "site-packages", "__pycache__", "venv", "deps", "_build", "dist-newstyle"],
                     suffixes: [".egg-info", ".dist-info"],
                     markers: [SkipCategory.Marker(name: "env", marker: "pyvenv.cfg")],
                     nested: [SkipCategory.Nested(names: ["mod"], parents: ["pkg"], sibling: "sumdb")]),
        SkipCategory(id: "buildOutput", title: "Build output and caches",
                     detail: "build, dist, target, coverage, DerivedData and similar folders anywhere; inside projects also out, bin, obj, tmp, cache and logs.",
                     examples: "build, dist, target, DerivedData",
                     names: ["build", "dist", "target", "coverage", "DerivedData", "zig-out", "zig-cache", "Intermediate", "DerivedDataCache", "storybook-static", "_site"],
                     projectNames: ["out", "bin", "obj", "tmp", "temp", "cache", "caches", "logs", "log", "Binaries", "Saved"]),
        SkipCategory(id: "cms", title: "CMS cores and plugins",
                     detail: "WordPress core (wp-admin, wp-includes, Bedrock’s wp folder) and its plugins, Drupal core and TYPO3 core. Themes and uploaded originals stay searchable.",
                     examples: "wp-admin, wp-includes, wp-content/plugins",
                     names: ["wp-admin", "wp-includes"],
                     markers: [SkipCategory.Marker(name: "wp", marker: "wp-includes"), SkipCategory.Marker(name: "core", marker: "lib/Drupal.php"),
                               SkipCategory.Marker(name: "typo3", marker: "sysext")],
                     nested: [SkipCategory.Nested(names: ["plugins", "mu-plugins", "languages", "upgrade", "upgrade-temp-backup", "cache"], parents: ["wp-content", "app"], sibling: "themes")]),
        SkipCategory(id: "generatedImages", title: "Generated image sizes",
                     detail: "Copies such as photo-300x200.jpg, photo-scaled.jpg or photo-e1700000000.jpg when photo.jpg lies in the same folder.",
                     examples: "photo-300x200.jpg next to photo.jpg",
                     generatedImages: true),
        SkipCategory(id: "olderReleases", title: "Older release copies",
                     detail: "Version folders in a tags folder, as in Subversion checkouts (tags/2.4.1, tags/2.5.0). Only the newest version stays searchable.",
                     examples: "tags/2.4.1 when tags/2.5.0 exists",
                     olderReleases: true)
    ]
    /// Raised when the built-in rules change, so existing catalogs are walked again once.
    public static let version = 1
    public let disabled: Set<String>
    private let names: Set<String>
    private let projectNames: Set<String>
    private let suffixes: [String]
    private let markers: [SkipCategory.Marker]
    private let nested: [SkipCategory.Nested]
    let skipsGeneratedImages: Bool
    let skipsOlderReleases: Bool

    public init(disabled: Set<String> = []) {
        self.disabled = disabled
        let active = Self.categories.filter { !disabled.contains($0.id) }
        names = active.reduce(into: []) { $0.formUnion($1.names) }
        projectNames = active.reduce(into: []) { $0.formUnion($1.projectNames) }
        suffixes = active.flatMap(\.suffixes)
        markers = active.flatMap(\.markers)
        nested = active.flatMap(\.nested)
        skipsGeneratedImages = active.contains(where: \.generatedImages)
        skipsOlderReleases = active.contains(where: \.olderReleases)
    }
    public static let `default` = SkipRules()
    public static func == (a: SkipRules, b: SkipRules) -> Bool { a.disabled == b.disabled }

    /// The part of the rules that needs no file system access; used for paths that are not being listed.
    func skipsByName(_ name: String) -> Bool {
        Scanner.excluded.contains(name) || names.contains(name) || suffixes.contains { name.hasSuffix($0) }
    }
    /// Whether a listed folder is skipped. `project` is the enclosing project, `parent` the name of the folder it was listed in.
    func skips(folder name: String, path: String, project: String, parent: String) -> Bool {
        if skipsByName(name) { return true }
        if !project.isEmpty, projectNames.contains(name) { return true }
        if markers.contains(where: { $0.name == name && access(path + "/" + $0.marker, F_OK) == 0 }) { return true }
        return nested.contains { $0.names.contains(name) && $0.parents.contains(parent) && access(CatalogPath.parent(of: path) + "/" + $0.sibling, F_OK) == 0 }
    }
    /// `photo-300x200.jpg`, `photo-300x200@2x.jpg`, `photo-scaled.jpg`, `photo-rotated.jpg` and WordPress's
    /// edit copy `photo-e1700000000.jpg` are generated from `photo.jpg`.
    static func original(ofGeneratedImage name: String) -> String? {
        let bytes = Array(name.utf8)
        guard let dot = bytes.lastIndex(of: UInt8(ascii: ".")), dot > 0 else { return nil }
        let extension_ = String(decoding: bytes[(dot + 1)...], as: UTF8.self)
        guard ["jpg", "jpeg", "png", "gif", "webp", "avif", "heic", "bmp", "tif", "tiff"].contains(extension_.lowercased()) else { return nil }
        guard let dash = bytes[..<dot].lastIndex(of: UInt8(ascii: "-")), dash > 0 else { return nil }
        var suffix = bytes[(dash + 1)..<dot]
        if suffix.count > 3, suffix.suffix(3).elementsEqual("@2x".utf8) { suffix = suffix.dropLast(3) }
        let digits = { (slice: ArraySlice<UInt8>) in !slice.isEmpty && slice.count <= 5 && slice.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }
        let generated: Bool
        if suffix.elementsEqual("scaled".utf8) || suffix.elementsEqual("rotated".utf8) {
            generated = true
        } else if suffix.first == UInt8(ascii: "e"), suffix.count == 11, suffix.dropFirst().allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) {
            generated = true
        } else if let x = suffix.firstIndex(of: UInt8(ascii: "x")) {
            generated = digits(suffix[..<x]) && digits(suffix[(x + 1)...])
        } else {
            generated = false
        }
        guard generated else { return nil }
        return String(decoding: bytes[..<dash], as: UTF8.self) + "." + extension_
    }
    /// The newest of `names` when every one is a release such as `2.4.10` or `5.4.7-RC1`. Folders
    /// like `swift` or `2024` mean the `tags` folder holds something else, and nothing is skipped.
    static func newestRelease(among names: [String]) -> String? {
        guard names.count > 1 else { return nil }
        let releases = names.compactMap { name in release(name).map { (name, $0) } }
        guard releases.count == names.count else { return nil }
        return releases.max { precedes($0.1, $1.1) }?.0
    }
    /// At least `major.minor`, an optional leading `v`; anything after the numbers marks a pre-release.
    static func release(_ name: String) -> (numbers: [Int], prerelease: Bool)? {
        var rest = name[...]
        if rest.first == "v" { rest = rest.dropFirst() }
        var numbers: [Int] = []
        while true {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, digits.count <= 9, let number = Int(digits) else { return nil }
            numbers.append(number)
            rest = rest.dropFirst(digits.count)
            guard rest.first == ".", rest.dropFirst().first?.isNumber == true else { break }
            rest = rest.dropFirst()
        }
        return numbers.count > 1 ? (numbers, !rest.isEmpty) : nil
    }
    private static func precedes(_ a: (numbers: [Int], prerelease: Bool), _ b: (numbers: [Int], prerelease: Bool)) -> Bool {
        for i in 0..<max(a.numbers.count, b.numbers.count) {
            let x = i < a.numbers.count ? a.numbers[i] : 0, y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x < y }
        }
        return a.prerelease && !b.prerelease
    }
}

public enum Scanner {
    /// System folders that are always skipped; everything else is governed by `SkipRules`.
    public static let excluded: Set<String> = ["Library", "$RECYCLE.BIN", "System Volume Information", "lost+found", "Backups.backupdb", "Temporary Items", "Network Trash Folder"]
    static let projectMarkers = [".git", "Package.swift", "package.json", "Cargo.toml", "pyproject.toml", "pubspec.yaml"]
    static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .isPackageKey, .isHiddenKey]
    static let keySet = Set(keys)
    public static func isProject(_ url: URL) -> Bool { isProject(path: url.path) }
    /// `access` is one system call per marker; the URL route stats every path component first.
    static func isProject(path: String) -> Bool {
        projectMarkers.contains { access(path + "/" + $0, F_OK) == 0 }
    }
    /// Whether a scan starting at `root` never reaches `path` because an intermediate
    /// component is hidden or automatically skipped.
    static func skipsComponents(of path: String, below root: String, rules: SkipRules = .default) -> Bool {
        let relative = path.dropFirst(root == "/" ? 1 : root.count + 1)
        return relative.split(separator: "/").contains { rules.skipsByName(String($0)) || $0.hasPrefix(".") }
    }

    public static func scan(roots: [String], maxDepth: Int? = nil, excludedPaths: [String] = [], rules: SkipRules = .default,
                            progress: (@Sendable (ScanProgress) -> Void)? = nil) -> Scan {
        let exclusions = SearchScope.Paths(excludedPaths)
        var found: [String: Entry] = [:]
        var warnings: [String] = []
        var inaccessible: [String] = []
        var reporter = ProgressReporter(progress)
        for root in SearchScope.effectiveRoots(roots, exclusions: exclusions, rules: rules) {
            reporter.currentPath = root
            reporter.report(force: true)
            do {
                try Walker(exclusions: exclusions, maxDepth: maxDepth, rules: rules).run(root: root, reporter: &reporter, record: { found[$0.path] = $0 }) { listing in
                    for child in listing.children { found[child.entry.path] = child.entry }
                    return listing.children.filter(\.descendable).map(\.entry)
                } failed: { path, message in
                    warnings.append(message); inaccessible.append(path)
                }
            } catch { break }
        }
        reporter.report(force: true)
        return Scan(entries: Array(found.values), warnings: Array(Set(warnings)).sorted(), inaccessiblePaths: inaccessible)
    }
}

struct ProgressReporter {
    private let progress: (@Sendable (ScanProgress) -> Void)?
    private var last = 0.0
    var currentPath = ""
    var discovered = 0
    init(_ progress: (@Sendable (ScanProgress) -> Void)?, discovered: Int = 0) { self.progress = progress; self.discovered = discovered }
    mutating func report(force: Bool = false) {
        guard let progress else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - last >= 0.25 else { return }
        last = now
        progress(ScanProgress(discovered: discovered, currentPath: currentPath))
    }
}

/// One directory's visible children, classified with the same rules for full and partial scans.
struct Listing {
    struct Child {
        let entry: Entry
        let isDirectory: Bool
        let descendable: Bool
        /// Files, apps and packages: never have indexed descendants.
        let isLeaf: Bool
    }
    let directory: String
    let depth: Int
    let children: [Child]
}

struct Walker {
    let exclusions: SearchScope.Paths
    let maxDepth: Int?
    let rules: SkipRules
    init(exclusions: SearchScope.Paths, maxDepth: Int?, rules: SkipRules = .default) {
        self.exclusions = exclusions; self.maxDepth = maxDepth; self.rules = rules
    }

    static func entry(for url: URL, values: URLResourceValues, context: String) -> Entry {
        entry(path: CatalogPath.canonical(url.path), name: CatalogPath.canonical(url.lastPathComponent), url: url, values: values, context: context)
    }
    static func entry(path: String, name: String, url: URL, values: URLResourceValues, context: String) -> Entry {
        let dir = values.isDirectory == true
        let app = url.pathExtension.lowercased() == "app"
        let project = dir && !app && Scanner.isProject(path: path)
        let kind = app ? "Uygulamalar" : project ? "Projeler" : dir ? "Klasörler" : "Dosyalar"
        return Entry(path: path, name: name, kind: kind, project: project ? name : context,
                     modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0)
    }
    static func rootEntry(_ url: URL) -> Entry {
        let project = Scanner.isProject(url)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let name = CatalogPath.canonical(url.lastPathComponent)
        return Entry(path: CatalogPath.canonical(url.path), name: name, kind: project ? "Projeler" : "Klasörler", project: project ? name : "", modified: modified)
    }

    /// Lists one directory. Directories are descended only when `visit` returns them.
    /// Children come back in path order, so the catalog's path index is written sequentially.
    func list(_ directory: URL, context: String, depth: Int) throws -> Listing {
        var failure: Error?
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Scanner.keys, options: [.skipsSubdirectoryDescendants],
                                                              errorHandler: { _, error in failure = error; return false }) else {
            throw CocoaError(.fileReadUnknown)
        }
        var children: [Listing.Child] = []
        var done = false
        let parent = CatalogPath.canonical(directory.lastPathComponent)
        // The enumerator yields one child at a time; `contentsOfDirectory` held every URL of a
        // folder with 177,000 children at once (291 MB), and the pool bounds Foundation's temporaries.
        while !done {
            autoreleasepool {
                for _ in 0..<1024 {
                    guard let url = enumerator.nextObject() as? URL else { done = true; return }
                    guard let values = try? url.resourceValues(forKeys: Scanner.keySet), values.isHidden != true, values.isSymbolicLink != true else { continue }
                    let path = CatalogPath.canonical(url.path), name = CatalogPath.canonical(url.lastPathComponent)
                    let dir = values.isDirectory == true
                    if dir && rules.skips(folder: name, path: path, project: context, parent: parent) { continue }
                    if exclusions.contains(path) { continue }
                    let entry = Self.entry(path: path, name: name, url: url, values: values, context: context)
                    let isLeaf = !dir || entry.kind == "Uygulamalar" || values.isPackage == true
                    let descendable = !isLeaf && (maxDepth.map { depth + 1 < $0 } ?? true)
                    children.append(Listing.Child(entry: entry, isDirectory: dir, descendable: descendable, isLeaf: isLeaf))
                }
            }
        }
        if let failure { throw failure }
        children.sort { CatalogPath.isOrdered($0.entry.name, before: $1.entry.name) }
        // Some volumes report an item twice; the catalog holds one record per path.
        var unique: [Listing.Child] = []
        unique.reserveCapacity(children.count)
        for child in children where unique.last?.entry.path != child.entry.path { unique.append(child) }
        if rules.skipsGeneratedImages, unique.contains(where: { !$0.isDirectory && SkipRules.original(ofGeneratedImage: $0.entry.name) != nil }) {
            let names = Set(unique.lazy.map(\.entry.name))
            unique.removeAll { !$0.isDirectory && SkipRules.original(ofGeneratedImage: $0.entry.name).map(names.contains) == true }
        }
        if rules.skipsOlderReleases, parent == "tags", let newest = SkipRules.newestRelease(among: unique.filter(\.isDirectory).map(\.entry.name)) {
            unique.removeAll { $0.isDirectory && $0.entry.name != newest }
        }
        return Listing(directory: CatalogPath.canonical(directory.path), depth: depth, children: unique)
    }

    /// Walks from a configured root. Root semantics match the previous scanner: a root is always
    /// listed, starts without inherited project context and may itself be hidden or skipped.
    func run(root: String, reporter: inout ProgressReporter, record: (Entry) throws -> Void,
             visit: (Listing) throws -> [Entry], failed: (String, String) throws -> Void) throws {
        guard case let (base, entry)? = Self.readableRoot(root) else {
            try failed(SearchScope.standardized(root), "Could not read: \(SearchScope.standardized(root))"); return
        }
        try record(entry)
        reporter.discovered += 1
        try walk(from: [(base, entry.project, 0)], reporter: &reporter, visit: visit, failed: failed)
    }
    static func readableRoot(_ root: String) -> (URL, Entry)? {
        let base = URL(fileURLWithPath: root).standardizedFileURL
        guard FileManager.default.isReadableFile(atPath: base.path) else { return nil }
        return (base, rootEntry(base))
    }

    /// Level order: shallow folders become searchable first, and only one level is held in memory.
    func walk(from start: [(URL, String, Int)], reporter: inout ProgressReporter, visit: (Listing) throws -> [Entry], failed: (String, String) throws -> Void) throws {
        var level = start
        while !level.isEmpty {
            var next: [(URL, String, Int)] = []
            for (directory, context, depth) in level {
                try Task.checkCancellation()
                reporter.currentPath = directory.path
                // A walk is one long synchronous job; without a pool per folder, Foundation's
                // temporary objects for millions of items stay alive until it ends.
                try autoreleasepool {
                    let listing: Listing
                    do { listing = try list(directory, context: context, depth: depth) }
                    catch {
                        try failed(directory.path, "\(directory.lastPathComponent): \(error.localizedDescription)")
                        return
                    }
                    reporter.discovered += listing.children.count
                    reporter.report()
                    for child in try visit(listing) {
                        next.append((URL(fileURLWithPath: child.path, isDirectory: true), child.project, depth + 1))
                    }
                }
            }
            level = next
        }
    }
}
