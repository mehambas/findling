import Foundation

/// A version such as 0.10.0 or v1.0.0-beta.2, compared part by part: 0.10.0 is newer than 0.9.0, and 1.0.0 than 1.0.0-beta.2.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]
    public let prerelease: String?
    /// Without the leading v of a tag.
    public let description: String

    private static let pattern = try! Regex(#"^[vV]?(\d+(?:\.\d+)*)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$"#)

    public init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = text.wholeMatch(of: Self.pattern), let core = match.output[1].substring else { return nil }
        parts = core.split(separator: ".").map { Int($0) ?? .max }
        prerelease = match.output[2].substring.map(String.init)
        description = text.first == "v" || text.first == "V" ? String(text.dropFirst()) : text
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for index in 0..<max(a.parts.count, b.parts.count) {
            let left = index < a.parts.count ? a.parts[index] : 0, right = index < b.parts.count ? b.parts[index] : 0
            if left != right { return left < right }
        }
        switch (a.prerelease, b.prerelease) {
        case let (left?, right?): return left.compare(right, options: .numeric) == .orderedAscending
        case (.some, nil): return true
        default: return false
        }
    }

    /// 1.0 and 1.0.0 are the same version.
    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// What the update check needs from GitHub's `releases/latest`, which never returns drafts or pre-releases.
public struct Release: Codable, Equatable, Sendable {
    public let tag: String
    public let page: URL
    /// Download addresses by asset name.
    public let assets: [String: URL]

    public init(tag: String, page: URL, assets: [String: URL]) {
        self.tag = tag; self.page = page; self.assets = assets
    }

    public var version: AppVersion? { AppVersion(tag) }

    public static func parse(_ data: Data) throws -> Release {
        struct Answer: Decodable {
            struct Asset: Decodable { let name: String; let browserDownloadUrl: URL }
            let tagName: String
            let htmlUrl: URL
            let assets: [Asset]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let answer = try decoder.decode(Answer.self, from: data)
        guard AppVersion(answer.tagName) != nil else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "The tag \(answer.tagName) is not a version"))
        }
        return Release(tag: answer.tagName, page: answer.htmlUrl,
                       assets: Dictionary(answer.assets.map { ($0.name, $0.browserDownloadUrl) }) { first, _ in first })
    }

    /// A `.sha256` file as `shasum -a 256` writes it: the hex digest, optionally followed by the file name.
    public static func digest(inChecksumFile text: String) -> String? {
        guard let digest = text.split(whereSeparator: \.isWhitespace).first, digest.count == 64,
              digest.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return digest.lowercased()
    }
}
