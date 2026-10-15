import Foundation
import CoreServices
import os

/// Directory-level FSEvents. Events are coalesced by the stream latency; history since a stored
/// event id is replayed, so changes made while the app was not running are not missed.
public final class FileWatcher: @unchecked Sendable {
    public struct Batch: Sendable {
        public let changes: [FileChange]
        /// Highest event id in the batch; store it only after the changes are applied.
        public let lastEventId: UInt64
        public let historyDone: Bool
        /// Event ids wrapped around; stored ids no longer order changes.
        public let rescan: Bool
    }

    public static let log = Logger(subsystem: "com.hamzabasaran.findling", category: "events")
    private let queue = DispatchQueue(label: "Findling.FileWatcher", qos: .utility)
    private let handler: @Sendable (Batch) -> Void
    private var stream: FSEventStreamRef?

    public init(handler: @escaping @Sendable (Batch) -> Void) { self.handler = handler }
    deinit { stop() }

    public static var currentEventId: UInt64 { FSEventsGetCurrentEventId() }

    /// Identifies the event history of every volume holding a path. A different value means the
    /// history was reset (for example after a volume was erased) and a full scan is required.
    public static func historyIdentity(for paths: [String]) -> String {
        var identities: Set<String> = []
        for path in paths {
            var info = stat()
            guard stat(path, &info) == 0 else { continue }
            if let uuid = FSEventsCopyUUIDForDevice(info.st_dev) {
                identities.insert(CFUUIDCreateString(nil, uuid) as String)
            } else {
                identities.insert("device-\(info.st_dev)")
            }
        }
        return identities.sorted().joined(separator: ",")
    }

    @discardableResult
    public func start(paths: [String], since: UInt64?, latency: TimeInterval = 3) -> Bool {
        stop()
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return false }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            var changes: [FileChange] = []
            var last: UInt64 = 0
            var historyDone = false, rescan = false
            for index in 0..<min(count, list.count) {
                let flag = Int(flags[index])
                if flag & kFSEventStreamEventFlagHistoryDone != 0 { historyDone = true; continue }
                if flag & kFSEventStreamEventFlagEventIdsWrapped != 0 { rescan = true }
                last = max(last, ids[index])
                let recursive = flag & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                                        | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount) != 0
                var path = list[index]
                while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
                if recursive { FileWatcher.log.info("Rescan requested: flags \(String(flag, radix: 16), privacy: .public) \(path, privacy: .private)") }
                changes.append(FileChange(path: path, recursive: recursive))
            }
            watcher.handler(Batch(changes: changes, lastEventId: last, historyDone: historyDone, rescan: rescan))
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(nil, callback, &context, existing as CFArray,
                                                since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return false }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created); FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
