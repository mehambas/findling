import AppKit
import SwiftUI

struct LauncherSearchField: NSViewRepresentable {
    @ObservedObject var model: Model
    @Environment(\.colorScheme) private var scheme
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = "Search your Mac"
        field.font = .systemFont(ofSize: model.scaled(22))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.cell?.usesSingleLineMode = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search your Mac")
        context.coordinator.field = field
        context.coordinator.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
            coordinator?.handleClearShortcut(event) == true ? nil : event
        }
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: .init("FindlingFocus"), object: nil, queue: .main) { [weak field] notification in
            guard let field else { return }
            if field.window?.firstResponder !== field.currentEditor() {
                field.window?.makeFirstResponder(field)
                field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0)
            }
            // As in Spotlight, the last search comes back selected: typing replaces it.
            if notification.object as? String == "reopen" { field.currentEditor()?.selectAll(nil) }
        }
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        let font = NSFont.systemFont(ofSize: model.scaled(22))
        if field.font != font { field.font = font }
        if field.stringValue != model.query {
            field.stringValue = model.query
            field.currentEditor()?.selectedRange = NSRange(location: model.query.utf16.count, length: 0)
        }
        if let editor = field.currentEditor() as? NSTextView {
            if editor.font != font { editor.font = font }
            let accent = NSColor(model.theme.accent(scheme))
            editor.insertionPointColor = accent
            editor.selectedTextAttributes = [.backgroundColor: accent.withAlphaComponent(0.3)]
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: Model
        weak var field: NSTextField?
        var observer: NSObjectProtocol?
        var keyMonitor: Any?
        init(model: Model) { self.model = model }
        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        }
        func handleClearShortcut(_ event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard modifiers == .shift || modifiers == .command, event.keyCode == 51 || event.keyCode == 117,
                  let field, event.window === field.window,
                  let editor = field.currentEditor() as? NSTextView, field.window?.firstResponder === editor else { return false }
            editor.insertText("", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            model.query = ""
            return true
        }
        func controlTextDidChange(_ obj: Notification) { if let field { model.query = field.stringValue } }
        func controlTextDidBeginEditing(_ obj: Notification) {
            guard let editor = field?.currentEditor() as? NSTextView else { return }
            editor.allowsUndo = true
            let accent = model.theme.editorAccent(editor.effectiveAppearance)
            editor.insertionPointColor = accent
            editor.selectedTextAttributes = [.backgroundColor: accent.withAlphaComponent(0.3)]
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let atEnd = textView.selectedRange() == NSRange(location: textView.string.utf16.count, length: 0)
            switch NSStringFromSelector(selector) {
            case "moveDown:": model.move(1)
            case "moveUp:": model.move(-1)
            case "insertNewline:": model.open()
            case "insertTab:": model.cycleFilter(1)
            case "insertBacktab:": model.cycleFilter(-1)
            case "moveRight:" where atEnd && !model.showingPreview && model.selected != nil: model.showingPreview = true
            case "moveLeft:" where atEnd && model.showingPreview: model.showingPreview = false
            case "cancelOperation:":
                if model.showingPreview { model.showingPreview = false }
                else { control.window?.orderOut(nil) }
            default: return false
            }
            return true
        }
    }
}
