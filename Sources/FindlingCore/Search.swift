import Foundation

public struct Entry: Codable, Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let kind: String
    public let project: String
    public let modified: Double
    public init(path: String, name: String, kind: String, project: String = "", modified: Double = 0) {
        self.path = path; self.name = name; self.kind = kind; self.project = project; self.modified = modified
    }
}
public struct QueryUse: Codable, Sendable {
    public var opens: Int
    public var lastOpened: Double
    public init(opens: Int = 0, lastOpened: Double = 0) { self.opens = opens; self.lastOpened = lastOpened }
}
public struct Preference: Codable, Sendable {
    public var pinned = false
    public var hidden = false
    public var opens = 0
    public var lastOpened: Double = 0
    public var queries: [String: QueryUse] = [:]
    public init() {}
    private enum CodingKeys: String, CodingKey { case pinned, hidden, opens, lastOpened, queries }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pinned = try values.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        hidden = try values.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        opens = try values.decodeIfPresent(Int.self, forKey: .opens) ?? 0
        lastOpened = try values.decodeIfPresent(Double.self, forKey: .lastOpened) ?? 0
        queries = try values.decodeIfPresent([String: QueryUse].self, forKey: .queries) ?? [:]
    }
    public mutating func recordOpen(query: String, now: Double = Date().timeIntervalSince1970) {
        opens += 1; lastOpened = now
        let key = Search.queryKey(query)
        guard !key.isEmpty else { return }
        queries[key, default: QueryUse()].opens += 1
        queries[key, default: QueryUse()].lastOpened = now
        if queries.count > 64 {
            let oldest = queries.min { $0.value.lastOpened < $1.value.lastOpened }?.key
            if let oldest { queries.removeValue(forKey: oldest) }
        }
    }
}
public struct Hit: Identifiable, Sendable {
    public var id: String { entry.path }
    public let entry: Entry
    public let score: Double
    public let reason: String
    public let queryOpenedAt: Double
    public let queryMatch: Int
}
public enum Search {
    public static func normalize(_ value: String) -> String {
        // Most paths are ASCII; for them folding is plain lowercasing and much cheaper.
        if value.utf8.allSatisfy({ $0 < 0x80 }) {
            return String(decoding: value.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 | 0x20 : $0 }, as: UTF8.self)
        }
        return value.replacingOccurrences(of: "ı", with: "i").replacingOccurrences(of: "İ", with: "I")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    static func stemLength(_ name: [UInt8]) -> Int {
        name.lastIndex(of: UInt8(ascii: ".")).flatMap { $0 > 0 ? $0 : nil } ?? name.count
    }
    public static func queryKey(_ value: String) -> String {
        normalize(value).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    public static func rank(_ entries: [Entry], query: String, preferences: [String: Preference], kind: String = "Tümü", now: Double = Date().timeIntervalSince1970) -> [Hit] {
        SearchIndex(entries).rank(query: query, preferences: preferences, kind: kind, now: now)
    }
    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var cursor = needle.startIndex
        for c in haystack where cursor < needle.endIndex {
            if c == needle[cursor] { cursor = needle.index(after: cursor) }
        }
        return cursor == needle.endIndex
    }
}

/// Normalize once when the catalog changes; keystrokes only compare prepared bytes.
public struct SearchIndex: Sendable {
    private struct Record: Sendable {
        let entry: Entry
        let name: [UInt8]
        let stemLength: Int
        let project: [UInt8]
        let path: [UInt8]
    }
    private let records: [Record]
    private var priorityRecords: [Record]
    private var priorityFilePaths: Set<String>
    public init(_ entries: [Entry], preferredPaths: Set<String> = [], progress: (@Sendable (Int, Int) -> Void)? = nil) {
        var prepared: [Record] = []
        prepared.reserveCapacity(entries.count)
        var priority: [Record] = []
        var priorityFiles: Set<String> = []
        var lastReport = ProcessInfo.processInfo.systemUptime
        progress?(0, entries.count)
        for (index, entry) in entries.enumerated() {
            if index % 256 == 0 && Task.isCancelled { break }
            let name = Array(Search.normalize(entry.name).utf8)
            let record = Record(entry: entry, name: name, stemLength: Search.stemLength(name),
                          project: Array(Search.normalize(entry.project).utf8), path: Array(Search.normalize(entry.path).utf8))
            prepared.append(record)
            if entry.kind != "Dosyalar" || preferredPaths.contains(entry.path) {
                priority.append(record)
                if entry.kind == "Dosyalar" { priorityFiles.insert(entry.path) }
            }
            if progress != nil && index % 256 == 0 {
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastReport >= 0.25 {
                    lastReport = now
                    progress?(prepared.count, entries.count)
                }
            }
        }
        records = prepared
        priorityRecords = priority
        priorityFilePaths = priorityFiles
        progress?(records.count, entries.count)
    }
    public mutating func promote(_ entry: Entry) {
        guard entry.kind == "Dosyalar", priorityFilePaths.insert(entry.path).inserted else { return }
        priorityRecords.append(contentsOf: SearchIndex([entry], preferredPaths: [entry.path]).priorityRecords)
    }
    public func rank(query: String, preferences: [String: Preference], kind: String = "Tümü", now: Double = Date().timeIntervalSince1970, priorityOnly: Bool = false, folder: String? = nil, excludedPaths: [String] = [], roots: [String]? = nil) -> [Hit] {
        let context = RankContext(query: query, preferences: preferences, kind: kind, now: now, folder: folder, excludedPaths: excludedPaths, roots: roots)
        var best = TopHits()
        for (index, record) in (priorityOnly ? priorityRecords : records).enumerated() {
            if index % 256 == 0 && Task.isCancelled { return [] }
            if let hit = context.hit(record.entry, name: record.name, stemLength: record.stemLength, project: record.project, path: record.path) {
                best.insert(hit.hit)
            }
        }
        return best.hits
    }
}

/// The text tier a record matched. Scores of different tiers never overlap for records
/// without a stored preference, which lets the catalog reader stop after the first full tiers.
enum MatchTier: Int, Comparable, Sendable {
    case letters, path, nameOrProject, contains, prefix, exact, everything
    static func < (a: MatchTier, b: MatchTier) -> Bool { a.rawValue < b.rawValue }
}

struct RankContext: Sendable {
    let normalized: String
    let q: [UInt8]
    let tokens: [[UInt8]]
    let kind: String
    let preferences: [String: Preference]
    let now: Double
    private let folderScope: SearchScope.Paths?
    private let exclusions: SearchScope.Paths
    private let rootScope: SearchScope.Paths?
    private let learned: [String: (tier: Int, date: Double)]
    init(query: String, preferences: [String: Preference], kind: String, now: Double, folder: String?, excludedPaths: [String], roots: [String]?) {
        let normalized = Search.queryKey(query)
        self.normalized = normalized
        q = Array(normalized.utf8)
        tokens = normalized.split(whereSeparator: { $0.isWhitespace }).map { Array($0.utf8) }
        self.kind = kind; self.preferences = preferences; self.now = now
        folderScope = folder.map { SearchScope.Paths([$0]) }
        exclusions = SearchScope.Paths(excludedPaths)
        rootScope = roots.map { SearchScope.Paths($0) }
        // Resolve learned choices once per query, not once for every indexed path.
        var learned: [String: (tier: Int, date: Double)] = [:]
        if !normalized.isEmpty {
            for (path, preference) in preferences {
                if let exact = preference.queries[normalized] {
                    learned[path] = (2, exact.lastOpened)
                } else if normalized.count >= 3 {
                    let related = preference.queries.filter { key, _ in
                        key.count >= 3 && (key.hasPrefix(normalized) || normalized.hasPrefix(key))
                    }.map { $0.value.lastOpened }.max()
                    if let related { learned[path] = (1, related) }
                }
            }
        }
        self.learned = learned
    }
    var allowsLetters: Bool { normalized.count >= 3 }
    func hit(_ entry: Entry, name: [UInt8], stemLength: Int, project: [UInt8], path: [UInt8]) -> (hit: Hit, tier: MatchTier)? {
        if kind != "Tümü" && entry.kind != kind { return nil }
        if let folderScope, !folderScope.contains(entry.path) { return nil }
        let preference = preferences[entry.path]
        if preference?.hidden == true { return nil }
        var score = 0.0
        var reason = "Recently modified"
        var tier = MatchTier.everything
        if !q.isEmpty {
            if name == q || (stemLength == q.count && name.starts(with: q)) {
                score = 1000; reason = "Exact name match"; tier = .exact
            } else if name.starts(with: q) {
                score = 800; reason = "Name starts with your query"; tier = .prefix
            } else if Search.contains(name, q) {
                score = 650; reason = "Name contains your query"; tier = .contains
            } else if tokens.allSatisfy({ Search.contains(name, $0) || Search.contains(project, $0) }) {
                score = 430; reason = "Name or project match"; tier = .nameOrProject
            } else if tokens.allSatisfy({ Search.contains(path, $0) }) {
                score = 180; reason = "Folder path match"; tier = .path
            } else if allowsLetters && Search.subsequence(q, in: name.prefix(stemLength)) {
                score = 100 - Double(max(0, stemLength - q.count)); reason = "Letters match in order"; tier = .letters
            } else { return nil }
        }
        // Scope checks only need to run for textual matches; the full catalog can
        // contain millions of paths, most of which do not match the query.
        if exclusions.contains(entry.path) { return nil }
        if let rootScope, !rootScope.contains(entry.path) { return nil }
        if entry.kind == "Projeler" { score += 45 }
        if entry.kind == "Uygulamalar" { score += 35 }
        let remembered = learned[entry.path]
        let queryOpenedAt = remembered?.date ?? 0
        let queryMatch = remembered?.tier ?? 0
        if queryMatch > 0 { reason = (queryMatch == 2 ? "Previously opened for this query · " : "Previously opened for a related query · ") + reason }
        if preference?.pinned == true { score += 150; reason = "Pinned · " + reason }
        if let preference {
            score += min(60, Double(preference.opens) * 5)
            if preference.lastOpened > 0 { score += max(0, 25 - (now - preference.lastOpened) / 86400) }
        }
        score += max(0, 10 - max(0, now - entry.modified) / 86400)
        return (Hit(entry: entry, score: score, reason: reason, queryOpenedAt: queryOpenedAt, queryMatch: queryMatch), tier)
    }
}

/// Keeps only the best results instead of sorting every matching path.
struct TopHits {
    static let limit = 80
    private(set) var hits: [Hit] = []
    init() { hits.reserveCapacity(Self.limit + 1) }
    var isFull: Bool { hits.count == Self.limit }
    mutating func insert(_ hit: Hit) {
        if isFull, let last = hits.last, !Self.precedes(hit, last) { return }
        var low = 0, high = hits.count
        while low < high {
            let mid = (low + high) / 2
            if Self.precedes(hit, hits[mid]) { high = mid } else { low = mid + 1 }
        }
        hits.insert(hit, at: low)
        if hits.count > Self.limit { hits.removeLast() }
    }
    /// True when no unremembered record scoring at most `score` can still enter the list.
    func excludes(score: Double) -> Bool {
        guard isFull, let last = hits.last else { return false }
        return last.queryMatch == 0 && last.score > score
    }
    static func precedes(_ a: Hit, _ b: Hit) -> Bool {
        if a.queryMatch != b.queryMatch { return a.queryMatch > b.queryMatch }
        if a.queryOpenedAt != b.queryOpenedAt { return a.queryOpenedAt > b.queryOpenedAt }
        return a.score == b.score ? a.entry.path < b.entry.path : a.score > b.score
    }
}

extension Search {
    /// The display order of the best 80; which records they are does not change. Backup copies
    /// follow their originals, and folders sharing a name and match list the shallowest first,
    /// because a folder's modification date says little about which one is meant. Files keep
    /// recently changed first. Records the user opened or pinned keep their place.
    public static func arranged(_ hits: [Hit], preferences: [String: Preference]) -> [Hit] {
        var result = demotingBackups(hits)
        var groups: [String: [Int]] = [:]
        for (index, hit) in result.enumerated() where hit.entry.kind == "Klasörler" || hit.entry.kind == "Projeler" {
            if let preference = preferences[hit.id], preference.pinned || preference.opens > 0 { continue }
            groups[[hit.entry.kind, hit.reason, normalize(hit.entry.name)].joined(separator: "/"), default: []].append(index)
        }
        for slots in groups.values where slots.count > 1 {
            let key = { (hit: Hit) in (insideBackup(hit.entry.path) ? 1 : 0, hit.entry.path.utf8.filter { $0 == UInt8(ascii: "/") }.count) }
            let members = slots.map { result[$0] }.sorted { a, b in
                key(a) == key(b) ? a.entry.path < b.entry.path : key(a) < key(b)
            }
            for (slot, hit) in zip(slots, members) { result[slot] = hit }
        }
        return result
    }
    /// Copies inside backup folders follow the originals they duplicate. The penalty exceeds the
    /// recency bonus but stays below the gap between match tiers, so a better match in a backup
    /// still ranks higher.
    static func demotingBackups(_ hits: [Hit]) -> [Hit] {
        guard hits.contains(where: { insideBackup($0.entry.path) }) else { return hits }
        return hits.map { ($0, $0.score - (insideBackup($0.entry.path) ? 20 : 0)) }.sorted { a, b in
            if a.0.queryMatch != b.0.queryMatch { return a.0.queryMatch > b.0.queryMatch }
            if a.0.queryOpenedAt != b.0.queryOpenedAt { return a.0.queryOpenedAt > b.0.queryOpenedAt }
            return a.1 == b.1 ? a.0.entry.path < b.0.entry.path : a.1 > b.1
        }.map(\.0)
    }
    static func insideBackup(_ path: String) -> Bool {
        path.split(separator: "/").dropLast().contains { ["backup", "backups"].contains($0.lowercased()) }
    }
    static func contains(_ text: [UInt8], _ query: [UInt8]) -> Bool {
        guard !query.isEmpty else { return true }
        guard text.count >= query.count else { return false }
        for start in 0...(text.count - query.count) where text[start] == query[0] {
            var matches = true
            for offset in 1..<query.count where text[start + offset] != query[offset] { matches = false; break }
            if matches { return true }
        }
        return false
    }
    static func subsequence(_ query: [UInt8], in text: ArraySlice<UInt8>) -> Bool {
        var cursor = 0
        for byte in text {
            if byte == query[cursor] { cursor += 1; if cursor == query.count { return true } }
        }
        return false
    }
}
