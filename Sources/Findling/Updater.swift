import AppKit
import CryptoKit
import FindlingCore
import os

/// Asks GitHub for the latest release at most once a day and installs it from its disk image. Findling is not
/// notarized, so it cannot replace itself: it opens the disk image and quits, and the user drags the new version
/// to Applications.
@MainActor final class Updater: ObservableObject {
    enum Status: Equatable {
        case idle, checking, upToDate
        case checkFailed(String)
        case downloading(Double)
        case opening
        case failed(String)
    }

    /// A release newer than this copy. It is kept across launches, since the next check can be a day away.
    @Published var release: Release? { didSet { if release != oldValue { save() } } }
    @Published var status = Status.idle
    @Published private(set) var lastCheck: Date?
    @Published var automatic: Bool {
        didSet {
            guard active else { return }
            UserDefaults.standard.set(automatic, forKey: "checkForUpdates")
            if automatic { checkIfDue() }
        }
    }
    let current: AppVersion
    private let active: Bool
    /// Trying an update with the testing variables leaves the stored check time and offer alone.
    private let persists: Bool
    private var checkTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private static let log = Logger(subsystem: "com.hamzabasaran.findling", category: "update")
    private static let installer = "Findling.dmg"

    init(active: Bool) {
        let current = GitHubReleases.version.flatMap(AppVersion.init)
        // A bare `swift build` binary has no Info.plist and so no version to compare.
        let enabled = active && current != nil
        self.current = current ?? AppVersion("0.0.0")!
        self.active = enabled
        persists = enabled && !GitHubReleases.testing
        automatic = (enabled ? UserDefaults.standard.object(forKey: "checkForUpdates") as? Bool : nil) ?? true
        guard persists, let current else { return }
        lastCheck = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date
        let stored = UserDefaults.standard.data(forKey: "availableUpdate").flatMap { try? JSONDecoder().decode(Release.self, from: $0) }
        release = stored.flatMap { $0.version.map { $0 > current } == true ? $0 : nil }
        if release == nil { UserDefaults.standard.removeObject(forKey: "availableUpdate") }
    }

    func start() {
        guard active else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.checkIfDue() }
        // Timers stand still while the Mac sleeps, so one for the whole day would run late; hourly ticks compare with the clock.
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard automatic, Date().timeIntervalSince(lastCheck ?? .distantPast) >= 24 * 3600 else { return }
        check(manual: false)
    }

    /// Only a manual check reports that nothing is newer or that GitHub could not be asked.
    func check(manual: Bool) {
        guard active, checkTask == nil, downloadTask == nil else { return }
        if manual { status = .checking }
        lastCheck = Date()
        if persists { UserDefaults.standard.set(lastCheck, forKey: "lastUpdateCheck") }
        checkTask = Task {
            defer { checkTask = nil }
            do {
                let latest = try await GitHubReleases.latest()
                let offer = latest.version.map { $0 > current } == true ? latest : nil
                Self.log.info("Latest release \(latest.tag, privacy: .public), this is \(self.current.description, privacy: .public)")
                if offer != release { release = offer; status = .idle }
                if manual { status = offer == nil ? .upToDate : .idle }
            } catch {
                Self.log.info("Update check failed: \(error.localizedDescription, privacy: .public)")
                if manual { status = .checkFailed(GitHubReleases.reason(error)) }
            }
        }
    }

    func install() {
        guard let release, let version = release.version, downloadTask == nil else { return }
        let missing = "This release has no checksum to verify the download, so its page is open in your browser instead."
        guard let installer = release.assets[Self.installer], let checksum = release.assets[Self.installer + ".sha256"] else {
            return openPage(release, because: missing)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Findling-\(version).dmg")
        status = .downloading(0)
        downloadTask = Task {
            defer { downloadTask = nil }
            do {
                guard let expected = try await GitHubReleases.digest(at: checksum) else { return openPage(release, because: missing) }
                let digest = try await GitHubReleases.download(installer, to: file) { fraction in
                    DispatchQueue.main.async { if case .downloading = self.status { self.status = .downloading(fraction) } }
                }
                guard digest == expected else {
                    try? FileManager.default.removeItem(at: file)
                    Self.log.error("Checksum mismatch for \(installer.absoluteString, privacy: .public)")
                    return openPage(release, because: "The download didn’t match its checksum and was deleted. The release page is open in your browser instead.")
                }
                status = .opening
                if !NSWorkspace.shared.open(file) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                // Finder won't replace an app that is still running; the pause lets the row say what comes next.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                NSApp.terminate(nil)
            } catch {
                try? FileManager.default.removeItem(at: file)
                Self.log.error("Update download failed: \(error.localizedDescription, privacy: .public)")
                status = .failed(GitHubReleases.reason(error))
            }
        }
    }

    private func openPage(_ release: Release, because reason: String) {
        NSWorkspace.shared.open(release.page)
        status = .failed(reason)
    }

    private func save() {
        guard persists else { return }
        if let release, let data = try? JSONEncoder().encode(release) {
            UserDefaults.standard.set(data, forKey: "availableUpdate")
        } else {
            UserDefaults.standard.removeObject(forKey: "availableUpdate")
        }
    }

    /// The first item of the menu bar menu while a release is offered. Takes the values a `@Published` sink receives,
    /// which arrive before the properties change.
    static func menuTitle(_ release: Release?, _ status: Status) -> String? {
        guard let version = release?.version else { return nil }
        switch status {
        case .downloading(let fraction): return "Downloading \(version)… \(Int(fraction * 100))%"
        case .opening: return "Opening \(version)…"
        default: return "Update to \(version)…"
        }
    }
}

/// Findling's only network access. The ephemeral session keeps no cookies, cache or credentials, and requests carry
/// nothing about the Mac or its user: the address, `Findling/<version>` and fixed Accept headers.
enum GitHubReleases {
    private static let environment = ProcessInfo.processInfo.environment
    /// FINDLING_FAKE_VERSION pretends to be another version and FINDLING_UPDATE_BASE replaces the API address,
    /// so an update can be tried against a local server that answers `<base>/releases/latest`.
    static let version = environment["FINDLING_FAKE_VERSION"] ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    static let testing = environment["FINDLING_FAKE_VERSION"] != nil || environment["FINDLING_UPDATE_BASE"] != nil
    private static let base = environment["FINDLING_UPDATE_BASE"].flatMap(URL.init(string:)) ?? URL(string: "https://api.github.com/repos/mehambas/findling")!

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        // Without a fixed Accept-Language, URLSession sends the user's preferred languages.
        configuration.httpAdditionalHeaders = ["User-Agent": "Findling/\(version ?? "0")", "Accept-Language": "en"]
        return URLSession(configuration: configuration)
    }()

    static func latest() async throws -> Release {
        var request = URLRequest(url: base.appendingPathComponent("releases/latest"))
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try check(response)
        return try Release.parse(data)
    }

    /// Nil when the release has no checksum file or the file holds no digest.
    static func digest(at url: URL) async throws -> String? {
        let (data, response) = try await session.data(from: url)
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        try check(response)
        return Release.digest(inChecksumFile: String(decoding: data, as: UTF8.self))
    }

    /// Hashes while writing, so the file is not read a second time. Returns the SHA-256 in hex.
    static func download(_ url: URL, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let (bytes, response) = try await session.bytes(from: url)
        try check(response)
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path]) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let total = response.expectedContentLength
        var hash = SHA256()
        var buffer = Data(capacity: 1 << 16)
        var written: Int64 = 0
        func flush() throws {
            hash.update(data: buffer)
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
            if total > 0 { progress(min(1, Double(written) / Double(total))) }
        }
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count == 1 << 16 { try flush() }
        }
        try flush()
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct HTTPStatus: LocalizedError {
        let code: Int
        var errorDescription: String? {
            [403, 429].contains(code) ? "GitHub is limiting requests. Try again later." : "GitHub answered with status \(code)."
        }
    }

    private static func check(_ response: URLResponse) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw HTTPStatus(code: code) }
    }

    static func reason(_ error: Error) -> String {
        error is DecodingError ? "GitHub’s answer could not be read." : error.localizedDescription
    }
}
