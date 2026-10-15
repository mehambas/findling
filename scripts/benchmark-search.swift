import Foundation
import Darwin

// Build with FindlingCore sources (see README). Works on copies: never pass the live catalog paths.
// benchmark-search <previous catalog> <new catalog> [--scan] [--compare] [--utility] [queries…]
// --utility runs at the QoS the app indexes with, so a --scan is comparable to a first index.
private func footprint() -> String {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    guard result == KERN_SUCCESS else { return "?" }
    return "\(info.phys_footprint / 1_048_576) MB footprint (peak \(info.ledger_phys_footprint_peak / 1_048_576) MB), \(info.resident_size / 1_048_576) MB resident"
}
private func cpu() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}
private func milliseconds(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }
private final class FirstResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int?
    func record(_ milliseconds: Int) { lock.lock(); if value == nil { value = milliseconds }; lock.unlock() }
    var milliseconds: Int? { lock.lock(); defer { lock.unlock() }; return value }
}

@main struct SearchBenchmark {
    static func main() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        if CommandLine.arguments.contains("--utility") {
            try await Task(priority: .utility) { try await run() }.value
        } else {
            try await run()
        }
    }
    static func run() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 2 else { print("Usage: benchmark-search <previous catalog> <new catalog> [--scan] [--compare] [queries…]"); return }
        let legacy = arguments.removeFirst(), path = arguments.removeFirst()
        let scan = arguments.contains("--scan"), compare = arguments.contains("--compare")
        arguments.removeAll { $0.hasPrefix("--") }
        let defaults = UserDefaults(suiteName: "com.hamzabasaran.findling")!
        let preferences = defaults.data(forKey: "preferences").flatMap { try? JSONDecoder().decode([String: Preference].self, from: $0) } ?? [:]
        let roots = defaults.stringArray(forKey: "roots") ?? SearchScope.defaultRoots(home: NSHomeDirectory())
        let excluded = defaults.stringArray(forKey: "excludedFolders") ?? []
        print("Preferences: \(preferences.count); roots: \(roots.count); exclusions: \(excluded.count)")

        let catalog = try Catalog(path: path)
        var start = Date(), cpuStart = cpu()
        try await catalog.upgradeSchema()
        print("Upgrade: \(milliseconds(since: start)) ms, CPU \(Int(cpu() - cpuStart)) s")
        start = Date(); cpuStart = cpu()
        try await catalog.migrateLegacy(path: legacy)
        let total = try await catalog.count()
        print("Import: \(total) items, \(milliseconds(since: start)) ms, CPU \(Int(cpu() - cpuStart)) s; \(footprint())")

        if scan {
            start = Date(); cpuStart = cpu()
            let report = try await catalog.index(roots.map { IndexRequest(path: $0) }, roots: roots, exclusions: excluded)
            print("Full walk: \(report.changes) changed records, \(report.warnings.count) warnings, \(milliseconds(since: start)) ms, CPU \(Int(cpu() - cpuStart)) s; \(footprint())")
            start = Date(); cpuStart = cpu()
            let again = try await catalog.index(roots.map { IndexRequest(path: $0) }, roots: roots, exclusions: excluded)
            print("Second walk: \(again.changes) changed records, \(milliseconds(since: start)) ms, CPU \(Int(cpu() - cpuStart)) s; \(footprint())")
        }

        let reader = try SearchReader(path: path)
        let queries = arguments.isEmpty ? ["", "a", "s", "fi", "findling", "invc", "ftra", "readme", "invoice", "report", "wp-content", "photos", "src main",
                                           "Çalışma", "zq", "xyz", "pdf", "notes", "code/app", "bulunmayan-xyz"] : arguments
        let index = compare ? SearchIndex(try await catalog.load(), preferredPaths: Set(preferences.keys)) : nil
        if compare { print("Reference index loaded; \(footprint())") }
        var mismatches = 0
        for query in queries {
            for round in 0..<2 {
                let now = Date().timeIntervalSince1970
                let began = Date()
                let first = FirstResult()
                let hits = try await reader.search(SearchRequest(query: query, preferences: preferences, excludedPaths: excluded, roots: roots, now: now)) { _ in
                    first.record(milliseconds(since: began))
                }
                if round == 1 {
                    print("\"\(query)\": first \(first.milliseconds.map { "\($0) ms" } ?? "-"), all \(milliseconds(since: began)) ms, \(hits.count) results; top: \(hits.first?.id ?? "none")")
                }
                if round == 1, let index {
                    let expected = index.rank(query: query, preferences: preferences, now: now, excludedPaths: excluded, roots: roots)
                    if expected.map(\.id) != hits.map(\.id) || expected.map(\.score) != hits.map(\.score) {
                        mismatches += 1
                        print("  MISMATCH: expected top \(expected.prefix(3).map(\.id)), got \(hits.prefix(3).map(\.id))")
                    }
                }
            }
        }
        if compare { print("Compared \(queries.count) queries with the in-memory ranking: \(mismatches) mismatches") }
        print("Done; \(footprint())")
    }
}
