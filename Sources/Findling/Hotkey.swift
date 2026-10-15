import AppKit
import Carbon

/// A key and its modifiers in Carbon's terms, which both RegisterEventHotKey and macOS's own shortcuts use.
struct Shortcut: Hashable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let standard = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey))
    private static let modifierMask = UInt32(controlKey | optionKey | shiftKey | cmdKey)

    /// Other bits, such as the function key flag macOS sets for arrow keys, are dropped.
    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
    }

    init(event: NSEvent) {
        self.init(keyCode: UInt32(event.keyCode), modifiers: Self.carbon(event.modifierFlags))
    }

    /// A global shortcut takes its keys away from every app. With ⌘ or ⌃ alone a key is an app's own
    /// command (⌘C, ⌃A in text fields, ⌃C in Terminal); with only ⌥ or ⇧ it types text (⌥L is @ on a
    /// German keyboard). Space is the exception launchers rely on; macOS's own shortcuts on it, such as
    /// ⌘Space for Spotlight, are caught by `macOSShortcuts`.
    var refusal: String? {
        if keyCode == UInt32(kVK_Space), modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 { return nil }
        if modifiers & UInt32(controlKey | cmdKey) == 0 {
            let typesText = keyCode == UInt32(kVK_Space) || (Self.specialKeys[Int(keyCode)] == nil && !Self.functionKeys.contains(Int(keyCode)))
            return typesText ? "\(title) types text. Add ⌘ or ⌃." : "Apps use \(title) themselves. Add ⌘ or ⌃."
        }
        if modifiers == UInt32(cmdKey) { return "Apps use \(title) themselves. Add ⇧, ⌥ or ⌃." }
        if modifiers == UInt32(controlKey) { return "Apps use \(title) themselves. Add ⇧, ⌥ or ⌘." }
        return nil
    }

    var title: String { Self.symbols(modifiers) + key.title }
    var spoken: String { (Self.names(modifiers) + [key.spoken]).joined(separator: " ") }
    var keyEquivalent: String { key.equivalent }
    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        return value
    }

    /// In the order menus show them.
    static func symbols(_ modifiers: UInt32) -> String {
        zip([controlKey, optionKey, shiftKey, cmdKey], ["⌃", "⌥", "⇧", "⌘"])
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined()
    }

    private static func names(_ modifiers: UInt32) -> [String] {
        zip([controlKey, optionKey, shiftKey, cmdKey], ["Control", "Option", "Shift", "Command"])
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1)
    }

    private var key: (title: String, spoken: String, equivalent: String) {
        if let special = Self.specialKeys[Int(keyCode)] { return special }
        if let function = Self.functionKeys.firstIndex(of: Int(keyCode)) {
            let name = "F\(function + 1)"
            return (name, name, Self.character(NSF1FunctionKey + function))
        }
        guard let (character, language) = Self.character(for: keyCode) else { return ("Key \(keyCode)", "Key \(keyCode)", "") }
        let title = character.uppercased(with: Locale(identifier: language))
        return (title, title, character)
    }

    private static let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                       kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]

    private static func character(_ functionKey: Int) -> String { UnicodeScalar(UInt32(functionKey)).map(String.init) ?? "" }

    private static let specialKeys: [Int: (String, String, String)] = {
        let function = character(_:)
        return [
            kVK_Space: ("Space", "Space", " "),
            kVK_Return: ("↩", "Return", "\r"),
            kVK_ANSI_KeypadEnter: ("⌅", "Enter", "\u{3}"),
            kVK_Tab: ("⇥", "Tab", "\t"),
            kVK_Delete: ("⌫", "Delete", "\u{8}"),
            kVK_ForwardDelete: ("⌦", "Forward Delete", function(NSDeleteFunctionKey)),
            kVK_Escape: ("⎋", "Escape", "\u{1b}"),
            kVK_LeftArrow: ("←", "Left Arrow", function(NSLeftArrowFunctionKey)),
            kVK_RightArrow: ("→", "Right Arrow", function(NSRightArrowFunctionKey)),
            kVK_UpArrow: ("↑", "Up Arrow", function(NSUpArrowFunctionKey)),
            kVK_DownArrow: ("↓", "Down Arrow", function(NSDownArrowFunctionKey)),
            kVK_Home: ("↖", "Home", function(NSHomeFunctionKey)),
            kVK_End: ("↘", "End", function(NSEndFunctionKey)),
            kVK_PageUp: ("⇞", "Page Up", function(NSPageUpFunctionKey)),
            kVK_PageDown: ("⇟", "Page Down", function(NSPageDownFunctionKey))
        ]
    }()

    /// Hot keys name physical keys; the same key is Y on an American keyboard and Z on a German one.
    private static func character(for keyCode: UInt32) -> (String, String)? {
        for copy in [TISCopyCurrentKeyboardLayoutInputSource, TISCopyCurrentASCIICapableKeyboardLayoutInputSource] {
            guard let source = copy()?.takeRetainedValue(),
                  let layout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
            let data = Unmanaged<CFData>.fromOpaque(layout).takeUnretainedValue() as Data
            var deadKeys: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = data.withUnsafeBytes { bytes in
                UCKeyTranslate(bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                               UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
            }
            let text = String(utf16CodeUnits: characters, count: length).trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            guard status == noErr, !text.isEmpty else { continue }
            let languages = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages)
                .map { Unmanaged<CFArray>.fromOpaque($0).takeUnretainedValue() as? [String] ?? [] } ?? []
            return (text, languages.first ?? "en")
        }
        return nil
    }

    /// Enabled shortcuts from System Settings › Keyboard › Keyboard Shortcuts. They win over
    /// RegisterEventHotKey without making it fail, so this is the only way to notice them.
    static func macOSShortcuts() -> Set<Shortcut> {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr, let entries = list?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return Set(entries.compactMap { entry in
            guard entry[kHISymbolicHotKeyEnabled as String] as? Bool == true,
                  let code = entry[kHISymbolicHotKeyCode as String] as? Int,
                  let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? Int else { return nil }
            return Shortcut(keyCode: UInt32(code), modifiers: UInt32(modifiers))
        })
    }
}

struct ShortcutProblem: Equatable {
    enum Owner { case otherApp, macOS }
    let shortcut: Shortcut
    let owner: Owner

    var reason: String { owner == .macOS ? "used by macOS" : "used by another app" }
    func message(current: Shortcut) -> String {
        let text = shortcut == current ? reason.prefix(1).uppercased() + reason.dropFirst() : "\(shortcut.title) is \(reason)"
        return text + ". Choose another shortcut."
    }
    var launchMessage: String { "\(shortcut.title) is \(reason). Choose another shortcut in Settings › General." }
}

@MainActor protocol HotkeyRegistration: AnyObject {
    /// Replaces whatever was registered; false when another app holds the shortcut.
    func register(_ shortcut: Shortcut) -> Bool
    func unregister()
}

@MainActor final class CarbonHotkey: HotkeyRegistration {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let pressed: () -> Void

    init(pressed: @escaping () -> Void) {
        self.pressed = pressed
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<CarbonHotkey>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { hotkey.pressed() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(_ shortcut: Shortcut) -> Bool {
        unregister()
        guard handler != nil else { return false }
        return RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: 0x42554C31, id: 1),
                                   GetApplicationEventTarget(), 0, &hotKey) == noErr
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }
}

/// The shortcut that opens Findling from any app, and its recorder in Settings.
@MainActor final class OpenShortcut: ObservableObject {
    @Published private(set) var current: Shortcut
    @Published private(set) var problem: ShortcutProblem?
    @Published private(set) var recording = false
    /// Modifiers held while recording, shown before the key is pressed.
    @Published private(set) var held: UInt32 = 0
    /// Why the last key pressed while recording was not taken.
    @Published private(set) var refusal: String?
    /// False while the shortcut is unregistered, held by another app or taken by macOS; menus then leave it out.
    @Published private(set) var works = false
    var registration: HotkeyRegistration?
    var macOSShortcuts: () -> Set<Shortcut> = Shortcut.macOSShortcuts
    private let saves: Bool
    private var monitor: Any?
    private var observer: NSObjectProtocol?

    init(saves: Bool) {
        self.saves = saves
        let saved = saves ? UserDefaults.standard.dictionary(forKey: "openShortcut") : nil
        let stored = (saved?["keyCode"] as? Int).flatMap { code in
            (saved?["modifiers"] as? Int).map { Shortcut(keyCode: UInt32(code), modifiers: UInt32($0)) }
        }
        // Shortcuts saved before the refusal rules, such as ⌘C, would keep breaking other apps.
        current = stored.flatMap { $0.refusal == nil ? $0 : nil } ?? .standard
    }

    /// Registers the saved shortcut at launch; the problem, if any, is for the launch notice.
    @discardableResult func activate() -> ShortcutProblem? {
        problem = attempt(current)
        works = problem == nil && registration != nil
        return problem
    }

    /// The old shortcut stays registered when the new one is taken.
    func change(to shortcut: Shortcut) {
        if let problem = attempt(shortcut) {
            self.problem = problem
            works = attempt(current) == nil && registration != nil
            return
        }
        current = shortcut
        problem = nil
        works = registration != nil
        if saves { UserDefaults.standard.set(["keyCode": Int(shortcut.keyCode), "modifiers": Int(shortcut.modifiers)], forKey: "openShortcut") }
    }

    func reset() {
        cancelRecording()
        change(to: .standard)
    }

    private func attempt(_ shortcut: Shortcut) -> ShortcutProblem? {
        if macOSShortcuts().contains(shortcut) { return ShortcutProblem(shortcut: shortcut, owner: .macOS) }
        if let registration, !registration.register(shortcut) { return ShortcutProblem(shortcut: shortcut, owner: .otherApp) }
        return nil
    }

    /// While recording, the current shortcut is unregistered so pressing it again records it instead of opening Findling.
    func beginRecording() {
        guard !recording else { return }
        recording = true
        held = 0
        refusal = nil
        registration?.unregister()
        works = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.recording else { return event }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                self.cancelRecording()
                return event
            }
            return self.handle(event) ? nil : event
        }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelRecording() }
        }
    }

    func cancelRecording() {
        guard recording else { return }
        stopRecording()
        works = attempt(current) == nil && registration != nil
    }

    private func stopRecording() {
        recording = false
        held = 0
        refusal = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        monitor = nil
        observer = nil
    }

    @discardableResult func handle(_ event: NSEvent) -> Bool {
        guard recording else { return false }
        switch event.type {
        case .flagsChanged:
            held = Shortcut.carbon(event.modifierFlags)
            return false
        case .keyDown:
            guard !event.isARepeat else { return true }
            let shortcut = Shortcut(event: event)
            if shortcut.keyCode == UInt32(kVK_Escape), shortcut.modifiers == 0 {
                cancelRecording()
            } else if let refusal = shortcut.refusal {
                self.refusal = refusal
            } else {
                stopRecording()
                change(to: shortcut)
            }
            return true
        default:
            return false
        }
    }
}
