import Foundation

enum IndexingProgress: Sendable {
    case loading
    case importing(imported: Int, fraction: Double)
    case scanning(discovered: Int, path: String)

    private func number(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    var fraction: Double? {
        guard case let .importing(_, fraction) = self else { return nil }
        return min(1, max(0, fraction))
    }

    var summary: String {
        switch self {
        case .loading: return "Opening index…"
        case .importing: return "Importing previous index · \(Int((fraction ?? 0) * 100))%"
        case let .scanning(discovered, _): return "Checking for changes · \(number(discovered)) items"
        }
    }

    var detail: String {
        switch self {
        case .loading: return "Opening the search catalog."
        case let .importing(imported, fraction): return "\(number(imported)) items imported" + (fraction >= 0.9 ? " · Building the search index." : ". Search starts when the import finishes.")
        case .scanning: return "Only changed items are written. Later changes are picked up as they happen."
        }
    }

    var currentPath: String? {
        guard case let .scanning(_, path) = self, !path.isEmpty else { return nil }
        return path
    }

    var help: String {
        ([summary, detail] + (currentPath.map { [$0] } ?? [])).joined(separator: "\n")
    }
}
