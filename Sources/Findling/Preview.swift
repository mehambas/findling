import AppKit
import QuickLookThumbnailing
import os
import FindlingCore

struct PreviewContent {
    let path: String
    var details: FileDetails
    var text = ""
    var truncated = false
    var markdown: [MarkdownBlock] = []
    var thumbnail: NSImage?

    static let thumbnailSize: CGFloat = 128
    static let textLimit = 6000
    static let textTypes: Set<String> = ["txt", "md", "markdown", "swift", "json", "js", "ts", "css", "html", "yaml", "yml", "toml", "csv", "sh"]
    static func showsText(_ entry: Entry) -> Bool {
        entry.kind == "Dosyalar" && textTypes.contains(URL(fileURLWithPath: entry.path).pathExtension.lowercased())
    }
    static func showsMarkdown(_ entry: Entry) -> Bool {
        showsText(entry) && ["md", "markdown"].contains(URL(fileURLWithPath: entry.path).pathExtension.lowercased())
    }
    /// Decided from the entry alone so the header keeps its size while the thumbnail loads or when it fails.
    static func showsThumbnail(_ entry: Entry) -> Bool { entry.kind == "Dosyalar" && !showsText(entry) }

    private static let thumbnails: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>(); cache.countLimit = 64; return cache
    }()

    static func thumbnail(_ path: String, modified: Date?) async -> NSImage? {
        let key = "\(path)|\(modified?.timeIntervalSince1970 ?? 0)" as NSString
        if let image = thumbnails.object(forKey: key) { return image }
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: thumbnailSize, height: thumbnailSize),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        let generator = QLThumbnailGenerator.shared
        // Unreadable or damaged files fail here (QLThumbnailErrorDomain 0); the icon stays.
        guard let image = try? await withTaskCancellationHandler(operation: { try await generator.generateBestRepresentation(for: request).nsImage },
                                                                  onCancel: { generator.cancel(request) }) else { return nil }
        thumbnails.setObject(image, forKey: key)
        return image
    }

    private static let spotlight = DispatchQueue(label: "Findling.Spotlight", qos: .utility)
    /// One lookup at a time on its own queue: each can block its thread for seconds, and on the shared pool a few would stall search.
    static func addingSpotlight(_ details: FileDetails, path: String) async -> FileDetails? {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                spotlight.async {
                    continuation.resume(returning: cancelled.withLock { $0 } ? nil : details.addingSpotlight(path))
                }
            }
        } onCancel: { cancelled.withLock { $0 = true } }
    }

    static func text(_ path: String) -> (text: String, truncated: Bool) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return ("", false) }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: textLimit + 1)) ?? Data()
        let truncated = data.count > textLimit
        // The cut can split a multi-byte character (ç, ş, emoji), and one broken byte fails the whole decode.
        for trim in 0...(truncated ? 3 : 0) {
            if let text = String(data: data.prefix(textLimit).dropLast(trim), encoding: .utf8) { return (text, truncated) }
        }
        return ("", false)
    }
}

extension Model {
    func loadPreview() async {
        guard showingPreview, let hit = selected else { preview = nil; return }
        let path = hit.id
        let details = await Task.detached(priority: .userInitiated) { FileDetails.read(path) }.value
        guard !Task.isCancelled else { return }
        preview = PreviewContent(path: path, details: details)
        async let spotlight = details.asksSpotlight ? PreviewContent.addingSpotlight(details, path: path) : nil
        if !details.dataless, PreviewContent.showsText(hit.entry) {
            let markdown = PreviewContent.showsMarkdown(hit.entry)
            let (text, truncated, blocks) = await Task.detached(priority: .userInitiated) { () -> (String, Bool, [MarkdownBlock]) in
                let (text, truncated) = PreviewContent.text(path)
                return (text, truncated, markdown ? MarkdownPreview.blocks(text) : [])
            }.value
            guard !Task.isCancelled else { return }
            preview?.text = text
            preview?.truncated = truncated
            preview?.markdown = blocks
        } else if !details.dataless, PreviewContent.showsThumbnail(hit.entry), let image = await PreviewContent.thumbnail(path, modified: details.modified) {
            if !Task.isCancelled { preview?.thumbnail = image }
        }
        if let more = await spotlight, !Task.isCancelled, preview?.path == path { preview?.details = more }
    }
}
