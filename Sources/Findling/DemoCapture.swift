import AppKit
import FindlingCore

/// Sample files in a temporary folder; the launcher shows that folder as the home folder.
private struct DemoFiles {
    var entries: [Entry] = []
    var report: URL!
    var notes: URL!
    var projects: URL!
}

/// Frames for the README animations, composed onto a desktop-like background, plus an ffmpeg concat list.
@MainActor private final class DemoRecorder {
    static let margin: CGFloat = 48
    static let tallestPanel: CGFloat = 558
    private let folder: URL
    private let colors: [CGColor]
    private var frames: [(name: String, seconds: Double)] = []

    init(folder: URL, dark: Bool) {
        self.folder = folder
        colors = dark ? [CGColor(srgbRed: 0.11, green: 0.16, blue: 0.31, alpha: 1), CGColor(srgbRed: 0.29, green: 0.17, blue: 0.37, alpha: 1)]
                      : [CGColor(srgbRed: 0.80, green: 0.87, blue: 0.97, alpha: 1), CGColor(srgbRed: 0.96, green: 0.85, blue: 0.90, alpha: 1)]
    }

    func add(_ window: NSWindow, seconds: Double) throws {
        guard let view = window.contentView else { throw DemoError("No content view") }
        view.layoutSubtreeIfNeeded()
        guard view.bounds.height <= Self.tallestPanel, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw DemoError("The panel is \(view.bounds.height) pt tall; the canvas holds \(Self.tallestPanel) pt")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let panel = bitmap.cgImage else { throw DemoError("No panel image") }
        let scale = CGFloat(panel.width) / view.bounds.width
        let width = Int((view.bounds.width + 2 * Self.margin) * scale), height = Int((Self.tallestPanel + 2 * Self.margin) * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1]) else {
            throw DemoError("No canvas")
        }
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])
        context.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 44 * scale, color: CGColor(gray: 0, alpha: 0.45))
        let top = CGFloat(height) - Self.margin * scale
        context.draw(panel, in: CGRect(x: (CGFloat(width) - CGFloat(panel.width)) / 2, y: top - CGFloat(panel.height), width: CGFloat(panel.width), height: CGFloat(panel.height)))
        guard let image = context.makeImage() else { throw DemoError("No frame") }
        let name = String(format: "frame-%03d.png", frames.count)
        guard let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil) else {
            throw DemoError("Could not write \(name)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw DemoError("Could not write \(name)") }
        frames.append((name, seconds))
    }

    func hold(_ seconds: Double) { frames[frames.count - 1].seconds += seconds }

    func finish() throws {
        guard let last = frames.last else { throw DemoError("No frames") }
        // The concat demuxer drops the last duration unless the last file is listed once more.
        let list = frames.map { "file '\($0.name)'\nduration \($0.seconds)\n" }.joined() + "file '\(last.name)'\n"
        try list.write(to: folder.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
    }
}

private struct DemoError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

extension AppDelegate {
    func captureDemo() async {
        let inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { _ in nil }
        defer { if let inputMonitor { NSEvent.removeMonitor(inputMonitor) } }
        guard let index = CommandLine.arguments.firstIndex(of: "--capture-demo"), CommandLine.arguments.count > index + 1 else {
            print("Usage: Findling --capture-demo <output-directory>")
            NSApp.terminate(nil); return
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("Findling Demo")
        do {
            try? FileManager.default.removeItem(at: home)
            let files = try makeDemoFiles(in: home)
            LauncherStyle.cloudFolders = [(home.path, "~")]
            model.replaceFixtures(files.entries)
            model.count = 248_317
            model.folderFilters = [home.path + "/Projects", home.path + "/Documents"]
            for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                let folder = output.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let recorder = DemoRecorder(folder: folder, dark: name == "dark")
                try await playDemo(files, recorder: recorder)
                try recorder.finish()
            }
            try? FileManager.default.removeItem(at: home)
            print("Demo frames: \(output.path)/dark, \(output.path)/light")
            NSApp.terminate(nil)
        } catch {
            try? FileManager.default.removeItem(at: home)
            fputs("Demo capture failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private func playDemo(_ files: DemoFiles, recorder: DemoRecorder) async throws {
        model.query = ""
        model.kind = "Tümü"
        model.activeFolder = nil
        model.showingPreview = false
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .init("FindlingFocus"), object: nil)
        await settle()
        guard let field = findField(panel.contentView), let editor = field.currentEditor() as? NSTextView,
              let delegate = field.delegate as? LauncherSearchField.Coordinator else { throw DemoError("Search field is not focused") }
        func press(_ selector: String) async throws {
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            guard delegate.control(field, textView: editor, doCommandBy: NSSelectorFromString(selector)) else { throw DemoError("\(selector) was not handled") }
            await settle()
        }
        func type(_ text: String) async throws {
            for end in text.indices {
                model.query = String(text[...end])
                await settle()
                try recorder.add(panel, seconds: 0.13)
            }
        }
        func previewLoaded(_ url: URL?, until ready: (PreviewContent) -> Bool = { _ in true }) async throws {
            for _ in 0..<50 {
                if let preview = model.preview, preview.path == (url?.path ?? model.selection), ready(preview) { await settle(); return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            throw DemoError("The preview of \(url?.lastPathComponent ?? model.selection ?? "the selection") did not load")
        }

        try recorder.add(panel, seconds: 1.3)
        try await type("qrep")
        guard model.selection?.hasPrefix(files.report.deletingLastPathComponent().path + "/Quarterly Report") == true else { throw DemoError("“qrep” did not find a report first") }
        recorder.hold(1.1)
        try await press("moveRight:")
        try await previewLoaded(nil) { $0.thumbnail != nil }
        try recorder.add(panel, seconds: 2.4)
        model.query = ""
        await settle()
        try recorder.add(panel, seconds: 0.4)
        try await type("notes")
        try await previewLoaded(nil)
        recorder.hold(1.0)
        for _ in 0..<5 where model.selection != files.notes.path {
            try await press("moveDown:")
            let reached = model.selection == files.notes.path
            try await previewLoaded(nil) { !reached || !$0.markdown.isEmpty }
            try recorder.add(panel, seconds: reached ? 2.6 : 0.5)
        }
        guard model.selection == files.notes.path else { throw DemoError("The Markdown note is not among the first results") }
        model.activeFolder = files.projects.path
        await settle()
        try await previewLoaded(nil) { !$0.markdown.isEmpty }
        try recorder.add(panel, seconds: 2.4)
    }

    private func makeDemoFiles(in home: URL) throws -> DemoFiles {
        let manager = FileManager.default
        var files = DemoFiles()
        let created = DateComponents(calendar: .current, year: 2026, month: 3, day: 12, hour: 9, minute: 14).date!
        let modified = DateComponents(calendar: .current, year: 2026, month: 10, day: 3, hour: 17, minute: 40).date!
        // Earlier entries count as more recently changed, which decides between equally good matches.
        func record(_ url: URL, kind: String, project: String) {
            files.entries.append(Entry(path: url.path, name: url.lastPathComponent, kind: kind, project: project,
                                       modified: modified.timeIntervalSince1970 - Double(files.entries.count) * 3600))
        }
        @discardableResult
        func folder(_ relative: String, project: String = "", isProject: Bool = false) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            record(url, kind: isProject ? "Projeler" : "Klasörler", project: isProject ? "" : project)
            return url
        }
        @discardableResult
        func file(_ relative: String, project: String = "", write: (URL) throws -> Void = { try "".write(to: $0, atomically: true, encoding: .utf8) }) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(url)
            try manager.setAttributes([.creationDate: created, .modificationDate: modified], ofItemAtPath: url.path)
            record(url, kind: "Dosyalar", project: project)
            return url
        }
        // Only shown in lists: an app's preview would show when it was last opened on this Mac.
        for app in ["/System/Applications/Calendar.app", "/System/Applications/Photos.app",
                    "/System/Applications/Preview.app", "/System/Applications/Reminders.app"] where manager.fileExists(atPath: app) {
            files.entries.append(Entry(path: app, name: URL(fileURLWithPath: app).lastPathComponent, kind: "Uygulamalar"))
        }
        try folder("Documents")
        try folder("Documents/Reports")
        files.report = try file("Documents/Reports/Quarterly Report Q3.pdf", write: drawReport(to:))
        try file("Documents/Reports/Quarterly Report Q2.pdf", write: drawReport(to:))
        try folder("Documents/Notes")
        files.notes = try file("Documents/Notes/Project Notes.md") { try Self.notes.write(to: $0, atomically: true, encoding: .utf8) }
        try file("Documents/Notes/Meeting Notes.md") { try "# Meeting Notes\n\n- Release plan\n- Icon review\n".write(to: $0, atomically: true, encoding: .utf8) }
        try folder("Pictures")
        try file("Pictures/Harbor Sketch.png", write: drawHarbor(to:))
        try folder("Downloads")
        try file("Downloads/Release Notes.pdf", write: drawReport(to:))
        files.projects = try folder("Projects")
        try folder("Projects/storefront", isProject: true)
        try file("Projects/storefront/package.json", project: "storefront") { try "{ \"name\": \"storefront\" }\n".write(to: $0, atomically: true, encoding: .utf8) }
        try file("Projects/storefront/README.md", project: "storefront") { try "# storefront\n".write(to: $0, atomically: true, encoding: .utf8) }
        try folder("Projects/warehouse", isProject: true)
        try file("Projects/warehouse/Package.swift", project: "warehouse")
        try file("Projects/warehouse/inventory.json", project: "warehouse") { try "[]\n".write(to: $0, atomically: true, encoding: .utf8) }
        try file("Projects/warehouse/release-notes.md", project: "warehouse") { try "# Release notes\n\n## 0.4.0\n- [x] Faster catalog updates\n- [x] Search in folders\n- [ ] Shortcut recorder\n\n> Ships next week.\n".write(to: $0, atomically: true, encoding: .utf8) }
        // Writing the files changed their folders' dates.
        for entry in files.entries where entry.kind == "Klasörler" || entry.kind == "Projeler" {
            try manager.setAttributes([.creationDate: created, .modificationDate: modified], ofItemAtPath: entry.path)
        }
        return files
    }
}
