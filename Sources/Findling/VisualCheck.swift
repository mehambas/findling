import AppKit
import Carbon
import ImageIO
import SwiftUI
import FindlingCore
import UniformTypeIdentifiers

/// Stands in for RegisterEventHotKey, which would take the shortcut away from the running app.
@MainActor private final class PreviewHotkey: HotkeyRegistration {
    private(set) var registered: Shortcut?
    var taken: Set<Shortcut> = []
    func register(_ shortcut: Shortcut) -> Bool {
        registered = taken.contains(shortcut) ? nil : shortcut
        return registered != nil
    }
    func unregister() { registered = nil }
}

// A deterministic visual/keyboard check. No personal catalog, scanning or saved preferences.
extension AppDelegate {
    func capturePreviews() async {
        // Ignore physical typing while this short-lived fixture window owns focus.
        // Keyboard checks below invoke the same handler with explicit test events.
        let inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { _ in nil }
        defer { if let inputMonitor { NSEvent.removeMonitor(inputMonitor) } }
        guard let index = CommandLine.arguments.firstIndex(of: "--capture-previews"), CommandLine.arguments.count > index + 1 else {
            print("Usage: Findling --capture-previews <output-directory>")
            NSApp.terminate(nil); return
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            model.folderFilters = ["/Users/demo/Projects", "/Users/demo/Documents"]
            let hotkey = PreviewHotkey()
            let spotlight = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey))
            model.shortcut.registration = hotkey
            model.shortcut.macOSShortcuts = { [spotlight, Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey))] }
            activateShortcut()
            guard hotkey.registered == .standard, model.notice.isEmpty, openItem.keyEquivalent == " ",
                  openItem.keyEquivalentModifierMask == [.shift, .command] else { throw checkError("The standard shortcut was not registered or shown in the menu") }
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                model.query = ""
                model.kind = "Tümü"
                model.showingPreview = false
                await settle()
                try capture(panel, to: output.appendingPathComponent("\(name)-suggested.png"))
                model.query = "warehouse"
                await settle()
                try capture(panel, to: output.appendingPathComponent("\(name)-results.png"))
                model.showingPreview = true
                await settle()
                try capture(panel, to: output.appendingPathComponent("\(name)-preview.png"))
                model.query = "no-matching-file-xyz"
                await settle()
                try capture(panel, to: output.appendingPathComponent("\(name)-empty.png"))
            }
            model.query = "warehouse"
            model.showingPreview = false
            await settle()
            panel.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .init("FindlingFocus"), object: nil)
            await settle()
            guard let field = findField(panel.contentView), let editor = field.currentEditor() as? NSTextView,
                  let delegate = field.delegate as? LauncherSearchField.Coordinator else {
                throw checkError("Search field is not focused")
            }
            func command(_ selector: String) -> Bool {
                delegate.control(field, textView: editor, doCommandBy: NSSelectorFromString(selector))
            }
            let initial = model.selection
            guard command("moveDown:"), model.selection != initial else { throw checkError("Arrow down failed") }
            guard command("moveUp:"), model.selection == initial else { throw checkError("Arrow up failed") }
            editor.setSelectedRange(NSRange(location: 2, length: 0))
            guard !command("moveRight:"), !model.showingPreview else { throw checkError("Arrow right intercepted text editing") }
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            guard command("moveRight:"), model.showingPreview else { throw checkError("Preview did not open") }
            guard command("cancelOperation:"), !model.showingPreview else { throw checkError("Escape did not close preview") }
            guard command("insertTab:"), model.kind == "Uygulamalar" else { throw checkError("Tab did not change filter") }
            await settle()
            guard model.hits.isEmpty else { throw checkError("Apps filter returned non-app results") }
            guard command("insertBacktab:"), model.kind == "Tümü" else { throw checkError("Shift-Tab failed") }
            await settle()
            guard !model.hits.isEmpty else { throw checkError("Restored filter lost search results") }
            model.activeFolder = "/Users/demo/Projects/warehouse"
            await settle()
            guard !model.hits.isEmpty, model.hits.allSatisfy({ $0.id == model.activeFolder || $0.id.hasPrefix(model.activeFolder! + "/") }) else { throw checkError("Folder filter leaked other locations") }
            model.excludedFolders = ["/Users/demo/Projects/warehouse"]
            model.persistExclusions()
            await settle()
            guard model.hits.isEmpty else { throw checkError("Exclusion did not apply to cached results") }
            model.excludedFolders = []
            model.persistExclusions()
            model.activeFolder = nil
            await settle()
            guard !model.hits.isEmpty else { throw checkError("Removing exclusion did not restore results") }
            let hiddenBefore = model.preferences.filter { $0.value.hidden }.count
            for modifiers: NSEvent.ModifierFlags in [.shift, .command] {
            for keyCode: UInt16 in [51, 117] {
                model.query = "warehouse"; await settle()
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: keyCode), delegate.handleClearShortcut(event), model.query.isEmpty, editor.string.isEmpty else {
                    throw checkError("Delete shortcut failed to clear the entire query")
                }
            }
            }
            guard model.preferences.filter({ $0.value.hidden }).count == hiddenBefore else { throw checkError("Clear search hid a result") }
            guard command("cancelOperation:"), !panel.isVisible else { throw checkError("Escape did not close panel") }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let fixtureRoots = model.roots
            model.roots = ["/Applications", home, home + "/Nextcloud", home + "/Sites",
                           home + "/Library/Mobile Documents/com~apple~CloudDocs", home + "/Library/CloudStorage"]
            model.locationCounts = ["/Applications": 812, home: 189_402, home + "/Library/Mobile Documents/com~apple~CloudDocs": 861,
                                    home + "/Library/CloudStorage": 12_260]
            guard model.coveringRoot(of: home + "/Sites") == home, model.coveringRoot(of: home + "/Library/CloudStorage") == nil else {
                throw checkError("Nested search locations are not detected")
            }
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                for tab in SettingsTab.allCases {
                    openSettings(tab)
                    await settle()
                    guard let settingsWindow, settingsWindow.title == tab.title else { throw checkError("Settings did not switch to \(tab.title)") }
                    guard settingsWindow.toolbar?.items.allSatisfy({ $0.view != nil }) == true else { throw checkError("Settings tabs are drawn by AppKit, not in the theme color") }
                    try capture(settingsWindow, to: output.appendingPathComponent("\(name)-settings\(tab == .general ? "" : "-" + tab.rawValue).png"))
                }
            }
            try await checkUpdateOffer(output: output)
            try await checkShortcutRecorder(hotkey, macOS: spotlight, output: output)
            if let settingsWindow, let controller = settingsWindow.contentViewController as? SettingsController {
                let preferences = model.preferences
                for path in ["/Users/demo/Documents/warehouse-notes.md", "/Users/demo/Projects/warehouse/inventory.json"] {
                    model.preferences[path, default: Preference()].hidden = true
                }
                model.excludedFolders = [home + "/Pictures/Exports", home + "/Documents/Old Backups"]
                controller.state.showsAlwaysSkipped = true
                controller.state.showsHidden = true
                openSettings(.exclusions)
                var frame = settingsWindow.frame
                frame.origin.y -= 1180 - frame.height
                frame.size.height = 1180
                settingsWindow.setFrame(frame, display: true)
                await settle()
                try capture(settingsWindow, to: output.appendingPathComponent("dark-settings-exclusions-full.png"))
                controller.state.showsAlwaysSkipped = false
                controller.state.showsHidden = false
                model.excludedFolders = []
                model.preferences = preferences
                controller.fitWindow()
            }
            model.roots = fixtureRoots
            model.indexing = true
            model.indexingProgress = .scanning(discovered: 1_234_567, path: "/Users/demo/Nextcloud/Documents/Archive")
            guard model.indexingProgress.fraction == nil else { throw checkError("Scan must not show a speculative percentage") }
            openSettings(.index)
            panel.orderFront(nil)
            await settle()
            try capture(panel, to: output.appendingPathComponent("dark-scanning.png"))
            if let settingsWindow { try capture(settingsWindow, to: output.appendingPathComponent("dark-settings-scanning.png")) }
            model.indexingProgress = .importing(imported: 750_000, fraction: 0.75)
            guard model.indexingProgress.fraction == 0.75, model.indexingProgress.detail.contains("750,000 items imported") else { throw checkError("Import progress is incorrect") }
            await settle()
            try capture(panel, to: output.appendingPathComponent("dark-importing.png"))
            if let settingsWindow { try capture(settingsWindow, to: output.appendingPathComponent("dark-settings-importing.png")) }
            model.indexingProgress = .loading
            guard model.indexingProgress.fraction == nil else { throw checkError("Opening must not show completed progress") }
            model.indexing = false
            model.warnings = [AccessWarning(path: home + "/Desktop", reason: "No permission to read this folder."),
                              AccessWarning(path: home + "/Downloads", reason: "No permission to read this folder.")]
            await settle()
            if let settingsWindow { try capture(settingsWindow, to: output.appendingPathComponent("dark-settings-warnings.png")) }
            model.warnings = []
            model.query = "warehouse"
            model.kind = "Dosyalar"
            model.activeFolder = "/Users/demo/Projects"
            await settle()
            let scopedResults = model.hits.map(\.id)
            guard !scopedResults.isEmpty else { throw checkError("Combined file/folder filters returned no fixture results") }
            for (name, appearance, scheme) in [("light", NSAppearance.Name.aqua, ColorScheme.light), ("dark", .darkAqua, .dark)] {
                NSApp.appearance = NSAppearance(named: appearance)
                for theme in FindlingTheme.allCases {
                    model.theme = theme
                    guard let color = NSColor(theme.selection(scheme)).usingColorSpace(.sRGB) else { throw checkError("Invalid theme color") }
                    func linear(_ channel: CGFloat) -> Double {
                        let c = Double(channel)
                        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
                    }
                    let luminance = 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
                    guard 1.05 / (luminance + 0.05) >= 4.5 else { throw checkError("\(theme.title) selection needs more contrast in \(name)") }
                    for size in FindlingTextSize.allCases {
                        model.textSize = size
                        panel.makeKeyAndOrderFront(nil)
                        NotificationCenter.default.post(name: .init("FindlingFocus"), object: nil)
                        await settle()
                        guard let searchField = findField(panel.contentView), abs((searchField.font?.pointSize ?? 0) - model.scaled(22)) < 0.1 else {
                            throw checkError("Search input did not follow text size")
                        }
                        guard model.query == "warehouse", model.hits.map(\.id) == scopedResults,
                              model.activeFolder == "/Users/demo/Projects", model.kind == "Dosyalar", !model.indexing else {
                            throw checkError("Appearance change altered search or started indexing")
                        }
                        try capture(panel, to: output.appendingPathComponent("\(name)-\(theme.rawValue)-\(size.rawValue).png"))
                    }
                }
                model.showingPreview = true
                await settle()
                try capture(panel, to: output.appendingPathComponent("\(name)-large-preview.png"))
                model.showingPreview = false
                openSettings(.general)
                await settle()
                if let settingsWindow { try capture(settingsWindow, to: output.appendingPathComponent("\(name)-appearance-settings.png")) }
            }
            model.textSize = .medium
            model.theme = .blue
            model.activeFolder = nil
            model.kind = "Tümü"
            let filters = model.folderFilters
            model.query = "warehouse"
            await settle()
            panel.orderOut(nil)
            show()
            await settle()
            guard let reopened = findField(panel.contentView)?.currentEditor() as? NSTextView, reopened.selectedRange() == NSRange(location: 0, length: 9) else {
                throw checkError("Reopening did not select the last search")
            }
            model.folderFilterNames[filters[0]] = "Work"
            model.activeFolder = filters[0]
            guard model.filterTitle(filters[0]) == "Work" else { throw checkError("Filter name is not shown") }
            model.removeFolderFilter(filters[0])
            guard model.activeFolder == nil, model.folderFilters == Array(filters.dropFirst()), model.folderFilterNames.isEmpty else {
                throw checkError("Removing the active filter left it selected or named")
            }
            model.folderFilters = filters
            let rootsBefore = model.roots
            model.roots = ["/Applications", home, home + "/Library/CloudStorage"]
            model.addFolderFilters([home + "/Notes/family", home + "/Library/Mobile Documents/com~apple~CloudDocs/Shared"])
            guard model.roots == ["/Applications", home, home + "/Library/CloudStorage", home + "/Library/Mobile Documents/com~apple~CloudDocs/Shared"],
                  model.folderFilters == filters + [home + "/Notes/family", home + "/Library/Mobile Documents/com~apple~CloudDocs/Shared"] else {
                throw checkError("A folder filter inside a location was added as a location, or one outside was not")
            }
            model.roots = rootsBefore
            model.folderFilters = filters
            model.kind = "Projeler"
            model.hasProjects = false
            guard model.kind == "Tümü", !model.kinds.contains(where: { $0.0 == "Projeler" }) else { throw checkError("Projects filter stayed without projects") }
            model.kind = "Uygulamalar"
            model.cycleFilter(1)
            guard model.kind == "Klasörler" else { throw checkError("Tab stopped on the hidden Projects filter") }
            model.hasProjects = true
            model.kind = "Tümü"
            panel.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .init("FindlingAddFilter"), object: nil)
            await settle()
            guard let sheet = panel.attachedSheet as? NSOpenPanel, panel.isVisible else { throw checkError("Add Folder Filter did not open a sheet on the launcher") }
            panel.endSheet(sheet, returnCode: .cancel)
            await settle()
            guard panel.isVisible, model.folderFilters == filters else { throw checkError("Cancelling Add Folder Filter changed the launcher") }
            model.folderFilters = []
            panel.orderFront(nil)
            await settle()
            try capture(panel, to: output.appendingPathComponent("dark-no-folder-filters.png"))
            model.folderFilters = filters
            try await checkPreviewDetails(output: output)
            print("PASS: 3 text sizes × 4 themes × 2 appearances, selection contrast, combined filters, input font, appearance changes preserve search, indexing progress, keyboard navigation, settings tabs, update offer, shortcut recorder, refusals and registration, folder filter sheet, naming and removal, reopened search selection, Projects only with projects, filter locations only when needed, preview dates, size, pixels, pages, thumbnails and Markdown; 65 visual captures.")
            NSApp.terminate(nil)
        } catch {
            fputs("Visual check failed: \(error)\n", stderr)
            exit(1)
        }
    }
    /// A newer release shows at the top of the menu bar menu and in Settings › General, with the download's progress in both.
    private func checkUpdateOffer(output: URL) async throws {
        let updater = model.updater
        updater.release = Release(tag: "v9.9.0", page: URL(string: "https://github.com/mehambas/findling/releases/tag/v9.9.0")!, assets: [:])
        openSettings(.general)
        await settle()
        guard let settingsWindow, updateItem.title == "Update to 9.9.0…", !updateItem.isHidden, !updateSeparator.isHidden else {
            throw checkError("The update offer is missing from the menu")
        }
        try capture(settingsWindow, to: output.appendingPathComponent("dark-settings-update.png"))
        updater.status = .downloading(0.42)
        await settle()
        guard updateItem.title == "Downloading 9.9.0… 42%" else { throw checkError("The download's progress is missing from the menu") }
        try capture(settingsWindow, to: output.appendingPathComponent("dark-settings-update-downloading.png"))
        updater.status = .idle
        updater.release = nil
        await settle()
        guard updateItem.isHidden, updateSeparator.isHidden else { throw checkError("The update offer stayed in the menu") }
    }

    /// Recording pauses the shortcut; a refused one keeps the old shortcut registered and says why.
    private func checkShortcutRecorder(_ hotkey: PreviewHotkey, macOS: Shortcut, output: URL) async throws {
        let shortcut = model.shortcut
        let optionK = Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(optionKey | cmdKey))
        let optionSpace = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))
        func press(_ shortcut: Shortcut, type: NSEvent.EventType = .keyDown) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: shortcut.modifierFlags, timestamp: 0, windowNumber: settingsWindow?.windowNumber ?? 0,
                             context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(shortcut.keyCode))!
        }
        func record(_ new: Shortcut) {
            shortcut.beginRecording()
            shortcut.handle(press(new))
        }
        NSApp.appearance = NSAppearance(named: .aqua)
        openSettings(.general)
        shortcut.beginRecording()
        guard shortcut.recording, hotkey.registered == nil, openItem.keyEquivalent.isEmpty else { throw checkError("Recording did not pause the shortcut") }
        await settle()
        guard let settingsWindow else { throw checkError("No settings window") }
        try capture(settingsWindow, to: output.appendingPathComponent("light-settings-shortcut-recording.png"))
        shortcut.handle(press(optionK, type: .flagsChanged))
        guard shortcut.held == optionK.modifiers else { throw checkError("Held modifiers are not shown while recording") }
        for refused in [Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(shiftKey)), Shortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(optionKey)),
                        Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey)), Shortcut(keyCode: UInt32(kVK_F5), modifiers: 0),
                        Shortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey))] {
            shortcut.handle(press(refused))
            guard shortcut.recording, shortcut.refusal?.contains(refused.title) == true, hotkey.registered == nil else { throw checkError("\(refused.title) was accepted") }
        }
        guard Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)).refusal == nil, optionK.refusal == nil else {
            throw checkError("⌥Space or ⌥⌘K was refused")
        }
        await settle()
        try capture(settingsWindow, to: output.appendingPathComponent("light-settings-shortcut-refused.png"))
        shortcut.handle(press(optionK))
        guard !shortcut.recording, shortcut.current == optionK, hotkey.registered == optionK, shortcut.problem == nil,
              openItem.keyEquivalent == "k", openItem.keyEquivalentModifierMask == [.option, .command] else { throw checkError("The new shortcut was not registered or shown in the menu") }
        record(macOS)
        guard shortcut.current == optionK, hotkey.registered == optionK, shortcut.problem == ShortcutProblem(shortcut: macOS, owner: .macOS), shortcut.works else {
            throw checkError("A macOS shortcut replaced the old one")
        }
        hotkey.taken = [optionSpace]
        record(optionSpace)
        guard shortcut.current == optionK, hotkey.registered == optionK, shortcut.problem == ShortcutProblem(shortcut: optionSpace, owner: .otherApp) else {
            throw checkError("A shortcut held by another app replaced the old one")
        }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await settle()
        try capture(settingsWindow, to: output.appendingPathComponent("dark-settings-shortcut-taken.png"))
        record(Shortcut(keyCode: UInt32(kVK_Escape), modifiers: 0))
        guard !shortcut.recording, shortcut.current == optionK, hotkey.registered == optionK else { throw checkError("Escape did not restore the old shortcut") }
        shortcut.reset()
        guard shortcut.current == .standard, hotkey.registered == .standard, shortcut.problem == nil, openItem.keyEquivalent == " " else {
            throw checkError("Reset did not restore \(Shortcut.standard.title)")
        }
        hotkey.taken = [.standard]
        activateShortcut()
        guard model.notice.contains("Settings › General"), model.noticeTab == .general, !shortcut.works, openItem.keyEquivalent.isEmpty else {
            throw checkError("A taken shortcut at launch did not point to Settings")
        }
        model.notice = ""
        hotkey.taken = []
        activateShortcut()
        guard model.noticeTab == nil, shortcut.works, shortcut.problem == nil else { throw checkError("The shortcut did not recover") }
    }

    /// The launcher fixtures exist only in the index, so dates, sizes and thumbnails need real files with fixed dates.
    private func checkPreviewDetails(output: URL) async throws {
        let folder = URL(fileURLWithPath: "/tmp/Findling Preview")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("Harbor Sketch.png"), pdf = folder.appendingPathComponent("Quarterly Report.pdf")
        let notes = folder.appendingPathComponent("Project Notes.md")
        try drawHarbor(to: image)
        try drawReport(to: pdf)
        try Self.notes.write(to: notes, atomically: true, encoding: .utf8)
        let created = DateComponents(calendar: .current, year: 2026, month: 3, day: 12, hour: 9, minute: 14).date!
        let modified = DateComponents(calendar: .current, year: 2026, month: 10, day: 3, hour: 17, minute: 40).date!
        for url in [image, pdf, notes] {
            try FileManager.default.setAttributes([.creationDate: created, .modificationDate: modified], ofItemAtPath: url.path)
        }
        let opened = DateComponents(calendar: .current, year: 2026, month: 10, day: 9, hour: 20, minute: 5).date!
        var time = timespec(tv_sec: Int(opened.timeIntervalSince1970), tv_nsec: 0)
        guard setxattr(image.path, "com.apple.lastuseddate#PS", &time, MemoryLayout<timespec>.size, 0, 0) == 0 else { throw checkError("Could not mark the image as opened") }
        model.addFixtures([image, pdf, notes].map { Entry(path: $0.path, name: $0.lastPathComponent, kind: "Dosyalar") })
        model.activeFolder = nil
        model.kind = "Tümü"
        model.showingPreview = true
        panel.makeKeyAndOrderFront(nil)
        func show(_ url: URL, until ready: (PreviewContent) -> Bool) async throws -> PreviewContent {
            model.query = url.deletingPathExtension().lastPathComponent
            await settle()
            func loaded() -> PreviewContent? { model.preview.flatMap { $0.path == url.path && ready($0) ? $0 : nil } }
            for _ in 0..<50 where loaded() == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            guard let preview = loaded() else { throw checkError("The preview of \(url.lastPathComponent) did not load") }
            guard preview.details.created == created, preview.details.modified == modified else {
                throw checkError("Wrong dates for \(url.lastPathComponent): \(preview.details)")
            }
            await settle()
            return preview
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            let photo = try await show(image) { $0.thumbnail != nil }
            guard photo.details.opened == opened, photo.details.sizeSummary?.hasSuffix(" · 1600 × 1000") == true else { throw checkError("Wrong image details: \(photo.details)") }
            try capture(panel, to: output.appendingPathComponent("\(name)-preview-image.png"))
            let report = try await show(pdf) { $0.thumbnail != nil }
            guard report.details.opened == nil, report.details.sizeSummary?.hasSuffix(" · 3 pages") == true else { throw checkError("Wrong PDF details: \(report.details)") }
            try capture(panel, to: output.appendingPathComponent("\(name)-preview-pdf.png"))
            let markdown = try await show(notes) { !$0.markdown.isEmpty }.markdown
            guard markdown.first?.kind == .heading(1), String(markdown[0].text.characters) == "Project Notes",
                  markdown.contains(where: { $0.kind == .item(depth: 1, marker: "☑") }), markdown.contains(where: { $0.kind == .code }),
                  !markdown.contains(where: { String($0.text.characters).contains("tags:") || String($0.text.characters).contains("[[") }) else {
                throw checkError("Markdown preview is not laid out as blocks")
            }
            try capture(panel, to: output.appendingPathComponent("\(name)-preview-markdown.png"))
            try scrollPreviewToEnd()
            await settle()
            try capture(panel, to: output.appendingPathComponent("\(name)-preview-markdown-end.png"))
        }
        model.query = pdf.deletingPathExtension().lastPathComponent
        model.textSize = .large
        await settle()
        try capture(panel, to: output.appendingPathComponent("dark-large-preview-pdf.png"))
        model.textSize = .medium
        model.showingPreview = false
        await settle()
    }
    private func scrollPreviewToEnd() throws {
        func scrollViews(_ view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews) }
        guard let content = panel.contentView, let scroll = scrollViews(content).first(where: { $0.convert($0.bounds, to: nil).minX > 290 }),
              let document = scroll.documentView else { throw checkError("No scrolling preview") }
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: document.isFlipped ? max(0, document.frame.height - clip.bounds.height) : 0))
        scroll.reflectScrolledClipView(clip)
    }
    static let notes = """
        ---
        tags: [findling, preview]
        aliases: [Notes]
        ---
        # Project Notes

        Notes for the **Findling** preview, with *emphasis*, `inline code` and a link to [[Roadmap|the roadmap]].

        ## This week
        - [x] Dates and sizes in the preview
        - [ ] Rendered Markdown
          - Headings, lists and code blocks
          - Obsidian links and callouts
        - Thumbnails for [[Images#Formats]]

        > [!tip] Keep it light
        > Read only the first 6 KB, and only while the preview is open.

        ```swift
        let blocks = MarkdownPreview.blocks(text)
        ```

        | Size | Thumbnail |
        |---|---|
        | Medium | 128 pt |
        | Large | 128 pt |

        ---

        1. Measure
        2. Ship
        """
    func drawHarbor(to url: URL) throws {
        let width = 1600, height = 1000
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [CGColor(srgbRed: 0.98, green: 0.72, blue: 0.47, alpha: 1),
                                                                                              CGColor(srgbRed: 0.16, green: 0.25, blue: 0.52, alpha: 1)] as CFArray, locations: [0, 1])
        else { throw checkError("Could not draw the image fixture") }
        context.drawLinearGradient(sky, start: CGPoint(x: 0, y: 420), end: CGPoint(x: 0, y: height), options: [])
        context.setFillColor(CGColor(srgbRed: 1, green: 0.86, blue: 0.5, alpha: 1))
        context.fillEllipse(in: CGRect(x: 990, y: 400, width: 220, height: 220))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.2, blue: 0.3, alpha: 1))
        context.addLines(between: [CGPoint(x: 0, y: 420), CGPoint(x: 260, y: 560), CGPoint(x: 520, y: 470), CGPoint(x: 760, y: 540), CGPoint(x: 900, y: 420)])
        context.fillPath()
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.28, blue: 0.45, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 420))
        context.setFillColor(CGColor(srgbRed: 1, green: 0.86, blue: 0.5, alpha: 0.35))
        for row in 0..<6 { context.fill(CGRect(x: 1000 - row * 30, y: 380 - row * 60, width: 200 + row * 60, height: 8)) }
        context.setFillColor(CGColor(srgbRed: 0.97, green: 0.96, blue: 0.93, alpha: 1))
        context.addLines(between: [CGPoint(x: 420, y: 250), CGPoint(x: 520, y: 520), CGPoint(x: 600, y: 250)])
        context.fillPath()
        context.setFillColor(CGColor(srgbRed: 0.35, green: 0.2, blue: 0.15, alpha: 1))
        context.addLines(between: [CGPoint(x: 360, y: 240), CGPoint(x: 660, y: 240), CGPoint(x: 620, y: 190), CGPoint(x: 400, y: 190)])
        context.fillPath()
        guard let cgImage = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw checkError("Could not write the image fixture")
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw checkError("Could not write the image fixture") }
    }
    func drawReport(to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextCreator: "Findling"] as CFDictionary) else { throw checkError("Could not write the PDF fixture") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for page in 1...3 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(srgbRed: 0.05, green: 0.4, blue: 0.85, alpha: 1))
            context.fill(CGRect(x: 0, y: 742, width: 595, height: 100))
            ("Quarterly Report" as NSString).draw(at: CGPoint(x: 48, y: 778), withAttributes: [.font: NSFont.systemFont(ofSize: 34, weight: .bold), .foregroundColor: NSColor.white])
            ("Q3 2026 · Page \(page) of 3" as NSString).draw(at: CGPoint(x: 48, y: 704), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.gray])
            if page == 1 {
                for (index, value) in [180, 260, 220, 330].enumerated() {
                    context.setFillColor(CGColor(srgbRed: 0.05, green: 0.4, blue: 0.85, alpha: 0.4 + Double(index) * 0.2))
                    context.fill(CGRect(x: 60 + index * 125, y: 340, width: 90, height: value))
                }
            }
            context.setFillColor(CGColor(gray: 0.82, alpha: 1))
            for line in 0..<(page == 1 ? 7 : 22) { context.fill(CGRect(x: 48, y: (page == 1 ? 290 : 660) - line * 26, width: line % 4 == 3 ? 320 : 499, height: 9)) }
            context.endPDFPage()
        }
        NSGraphicsContext.restoreGraphicsState()
        context.closePDF()
    }

    func settle() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
        for _ in 0..<100 where model.searching { try? await Task.sleep(nanoseconds: 50_000_000) }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    private func capture(_ window: NSWindow, to url: URL) throws {
        // The frame view also draws the title bar and the settings toolbar.
        guard let view = window === panel ? window.contentView : window.contentView?.superview else { throw checkError("No content view") }
        if window === panel, abs(view.bounds.height - model.panelHeight) > 1 {
            throw checkError("Panel height \(view.bounds.height) differs from expected \(model.panelHeight)")
        }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw checkError("No bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw checkError("No PNG") }
        try data.write(to: url)
        print("Captured \(url.lastPathComponent): \(Int(view.bounds.width)) × \(Int(view.bounds.height)) pt")
    }
    func findField(_ view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField { return field }
        return view.subviews.lazy.compactMap { self.findField($0) }.first
    }
    func checkError(_ message: String) -> NSError { NSError(domain: "Findling.VisualCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
