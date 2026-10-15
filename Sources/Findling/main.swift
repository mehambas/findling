import SwiftUI
import AppKit
import Combine

@main struct FindlingLauncher {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// Off for the visual check, whose captures and checks follow each step at once.
    var animates = true
    private(set) var isClosing = false
    private var generation = 0

    /// Fades in while the content grows from 98 % at its top edge; with Reduce Motion it only fades.
    /// Keyboard focus moves at once, so nothing typed right after the shortcut is lost.
    func present() {
        generation += 1
        isClosing = false
        guard animates else { alphaValue = 1; makeKeyAndOrderFront(nil); return }
        if !isVisible { alphaValue = 0 }
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = contentView?.layer else { return }
        let size = layer.bounds.size, scale: CGFloat = 0.98
        var start = CATransform3DMakeTranslation(size.width * (1 - scale) / 2, size.height * (1 - scale), 0)
        start = CATransform3DScale(start, scale, scale, 1)
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = start
        grow.toValue = CATransform3DIdentity
        grow.duration = 0.18
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(grow, forKey: "present")
        // The shadow of a transparent window follows its content only when asked.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.invalidateShadow() }
    }

    override func orderOut(_ sender: Any?) {
        guard animates, isVisible, !isClosing else {
            if !isClosing { super.orderOut(sender) }
            return
        }
        isClosing = true
        let current = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == current else { return }
            self.isClosing = false
            self.orderOutNow(sender)
            self.alphaValue = 1
        })
    }
    private func orderOutNow(_ sender: Any?) { super.orderOut(sender) }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: LauncherPanel!
    var settingsWindow: NSWindow?
    var status: NSStatusItem!
    var openItem: NSMenuItem!
    var subscription: AnyCancellable?
    var shortcutSubscription: AnyCancellable?
    let model = Model(previewing: ["--capture-previews", "--capture-demo"].contains(where: CommandLine.arguments.contains))

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: model.panelHeight), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "Findling"
        panel.isFloatingPanel = true; panel.level = .floating; panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: SearchView(model: model))
        // Window geometry comes from the design, not SwiftUI's unconstrained ideal size.
        host.sizingOptions = []
        panel.contentView = host
        panel.delegate = self
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: "Findling")
        status.button?.toolTip = "Findling"
        let menu = NSMenu()
        openItem = add(menu, "Open Findling", #selector(show))
        add(menu, "Refresh Index", #selector(refresh))
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(showSettings(_:)), key: ",")
        menu.addItem(.separator())
        add(menu, "Quit Findling", #selector(quit), key: "q")
        status.menu = menu
        NotificationCenter.default.addObserver(self, selector: #selector(showSettings(_:)), name: .init("FindlingSettings"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(addFolderFilter), name: .init("FindlingAddFilter"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(renameFolderFilter(_:)), name: .init("FindlingRenameFilter"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showActions), name: .init("FindlingActions"), object: nil)
        subscription = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizePanel() }
        }
        shortcutSubscription = model.shortcut.$current.combineLatest(model.shortcut.$works).sink { [weak self] shortcut, works in
            self?.openItem.keyEquivalent = works ? shortcut.keyEquivalent : ""
            self?.openItem.keyEquivalentModifierMask = works ? shortcut.modifierFlags : []
        }
        if CommandLine.arguments.contains("--capture-previews") {
            panel.animates = false
            show()
            Task { await capturePreviews() }
            return
        }
        if CommandLine.arguments.contains("--capture-demo") {
            panel.animates = false
            show()
            Task { await captureDemo() }
            return
        }
        model.shortcut.registration = CarbonHotkey { [weak self] in self?.toggle() }
        activateShortcut()
        show()
    }

    func activateShortcut() {
        guard let problem = model.shortcut.activate() else { return }
        model.notice = problem.launchMessage
        model.noticeTab = .general
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        item.keyEquivalentModifierMask = modifiers
        return item
    }
    private func configureMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Findling")
        add(appMenu, "Settings…", #selector(showSettings(_:)), key: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Findling", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        add(appMenu, "Quit Findling", #selector(quit), key: "q")
        appItem.submenu = appMenu; bar.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = edit; bar.addItem(editItem)
        let resultItem = NSMenuItem()
        let results = NSMenu(title: "Result")
        add(results, "Show in Finder", #selector(reveal), key: "\r")
        add(results, "Toggle Preview", #selector(togglePreview), key: "y")
        add(results, "Actions", #selector(showActions), key: "k")
        add(results, "Pin / Unpin", #selector(pin), key: "p")
        add(results, "Hide This Result", #selector(hideResult))
        resultItem.submenu = results; bar.addItem(resultItem)
        NSApp.mainMenu = bar
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    private var invocationScreen: NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main ?? NSScreen.screens.first
    }
    @objc func show() {
        if let screen = invocationScreen {
            let area = screen.visibleFrame
            let width = min(720, max(1, area.width - 32))
            let height = min(model.panelHeight, max(1, area.height - 32))
            panel.setFrame(NSRect(x: (area.midX - width / 2).rounded(), y: (area.midY - height / 2).rounded(), width: width, height: height), display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.present()
        NotificationCenter.default.post(name: .init("FindlingFocus"), object: "reopen")
    }
    private func resizePanel() {
        guard let panel else { return }
        let area = (panel.screen ?? invocationScreen)?.visibleFrame ?? panel.frame
        let height = min(model.panelHeight, max(1, area.height - 32))
        guard panel.frame.height != height else { return }
        var frame = panel.frame
        frame.origin.y = max(area.minY + 16, frame.maxY - height)
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }
    func toggle() {
        if panel.isKeyWindow && panel.isVisible && !panel.isClosing && panel.screen == invocationScreen { panel.orderOut(nil) }
        else { show() }
    }
    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel, panel.attachedSheet == nil else { return }
        panel.orderOut(nil)
    }
    /// The launcher names a tab in the notification's object; the menu opens the last one.
    @objc func showSettings(_ sender: Any?) {
        openSettings(((sender as? Notification)?.object as? String).flatMap(SettingsTab.init(rawValue:)))
    }
    func openSettings(_ tab: SettingsTab? = nil) {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: SettingsController(model: model))
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        guard let window = settingsWindow, let controller = window.contentViewController as? SettingsController else { return }
        if let tab { controller.tab = tab }
        window.title = controller.tab.title
        controller.fitWindow()
        panel.orderOut(nil)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    @objc func addFolderFilter() { model.addFolderFilter(in: panel, select: true) }
    @objc func renameFolderFilter(_ notification: Notification) {
        if let path = notification.object as? String { model.renameFolderFilter(path, in: panel) }
    }
    @objc func showActions() {
        guard panel.isKeyWindow, model.selected != nil, let view = panel.contentView else { return }
        let menu = NSMenu()
        add(menu, "Open", #selector(openResult), key: "\r", modifiers: [])
        add(menu, "Show in Finder", #selector(reveal), key: "\r")
        menu.addItem(.separator())
        let pinned = model.selection.flatMap { model.preferences[$0]?.pinned } == true
        add(menu, pinned ? "Unpin" : "Pin", #selector(pin), key: "p")
        add(menu, "Hide This Result", #selector(hideResult))
        menu.popUp(positioning: menu.items.first, at: NSPoint(x: view.bounds.width - 250, y: 34), in: view)
    }
    @objc func openResult() { if panel.isKeyWindow { model.open() } }
    @objc func reveal() { if panel.isKeyWindow { model.reveal() } }
    @objc func togglePreview() { if panel.isKeyWindow && model.selected != nil { model.showingPreview.toggle() } }
    @objc func pin() { if panel.isKeyWindow, let hit = model.selected { model.pin(hit) } }
    @objc func hideResult() { if panel.isKeyWindow, let hit = model.selected { model.hide(hit) } }
    @objc func refresh() { model.refresh() }
    @objc func quit() { NSApp.terminate(nil) }
}
