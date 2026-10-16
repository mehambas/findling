import AppKit
import Combine
import ServiceManagement
import SwiftUI
import FindlingCore

enum SettingsTab: String, CaseIterable {
    case general, locations, exclusions, index
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .locations: return "folder"
        case .exclusions: return "folder.badge.minus"
        case .index: return "internaldrive"
        }
    }
    /// Content height at Medium; the form scrolls when it holds more.
    var height: CGFloat {
        switch self {
        case .general: return 660
        case .locations: return 560
        case .exclusions: return 640
        case .index: return 460
        }
    }
}

/// Open disclosures outlive tab switches and can be set by the visual check.
final class SettingsState: ObservableObject {
    @Published var showsAlwaysSkipped = false
    @Published var showsHidden = false
    @Published var tab = SettingsTab.general
}

/// A window built from AppKit, not a SwiftUI `Settings` scene, so toolbar tabs come from NSTabViewController.
final class SettingsController: NSTabViewController {
    let model: Model
    let state = SettingsState()
    private var subscriptions: Set<AnyCancellable> = []

    init(model: Model) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = []
        for tab in SettingsTab.allCases {
            let host = NSHostingController(rootView: SettingsPane(model: model, state: state, tab: tab))
            host.sizingOptions = []
            host.title = tab.title
            let item = NSTabViewItem(viewController: host)
            item.identifier = tab.rawValue
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            addTabViewItem(item)
        }
        if let saved = UserDefaults.standard.string(forKey: "settingsTab").flatMap(SettingsTab.init(rawValue:)), !model.previewing {
            tab = saved
        }
        state.tab = tab
        model.$textSize.dropFirst().map { _ in () }
            .merge(with: model.shortcut.$problem.dropFirst().map { _ in () }, model.shortcut.$refusal.dropFirst().map { _ in () })
            .sink { [weak self] in DispatchQueue.main.async { self?.fitWindow() } }
            .store(in: &subscriptions)
    }
    required init?(coder: NSCoder) { nil }

    var tab: SettingsTab {
        get { SettingsTab.allCases[max(0, selectedTabViewItemIndex)] }
        set { selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(of: newValue) ?? 0 }
    }

    /// AppKit tints the selected tab with the system accent color; drawing the tab ourselves lets it follow the theme.
    override func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = super.toolbar(toolbar, itemForItemIdentifier: itemIdentifier, willBeInsertedIntoToolbar: flag)
        guard let item, let tab = SettingsTab(rawValue: itemIdentifier.rawValue) else { return item }
        item.view = NSHostingView(rootView: SettingsTabButton(model: model, state: state, tab: tab) { [weak self] in self?.tab = tab })
        // The views draw their own labels. With labels shown, the toolbar would draw them again and
        // push the views above its selection background.
        toolbar.displayMode = .iconOnly
        return item
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        state.tab = tab
        if !model.previewing { UserDefaults.standard.set(tab.rawValue, forKey: "settingsTab") }
        view.window?.title = tab.title
        fitWindow()
    }

    /// Keeps the top edge in place, as tab switches do in System Settings.
    func fitWindow() {
        guard let window = view.window else { return }
        let area = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let chrome = window.frame.height - window.contentLayoutRect.height
        let warnings = [model.shortcut.problem != nil, model.shortcut.refusal != nil].filter { $0 }.count
        let warning = tab == .general ? CGFloat(warnings) * 32 : 0
        let size = NSSize(width: 520, height: min(model.scaled(tab.height + warning), area - chrome - 32).rounded())
        let target = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        guard abs(target.height - window.frame.height) > 0.5 || abs(target.width - window.frame.width) > 0.5 else { return }
        var frame = window.frame
        frame.origin.y += frame.height - target.height
        frame.size = target.size
        window.setFrame(frame, display: true, animate: window.isVisible)
    }
}

private struct SettingsTabButton: View {
    @ObservedObject var model: Model
    @ObservedObject var state: SettingsState
    let tab: SettingsTab
    let select: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let selected = state.tab == tab
        Button(action: select) {
            VStack(spacing: 0) {
                Image(systemName: tab.symbol).font(.system(size: 20)).frame(height: 24)
                Text(tab.title).font(.system(size: 11))
            }
            .padding(.top, 3.25)
            .frame(height: 45, alignment: .top)
            .foregroundStyle(selected ? (activeState == .inactive ? AnyShapeStyle(.primary) : AnyShapeStyle(model.theme.accent(scheme))) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct SettingsPane: View {
    @ObservedObject var model: Model
    @ObservedObject var state: SettingsState
    let tab: SettingsTab
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralSettings(model: model, updater: model.updater)
            case .locations: LocationSettings(model: model)
            case .exclusions: ExclusionSettings(model: model, state: state)
            case .index: IndexSettings(model: model)
            }
        }
        .formStyle(.grouped)
        .font(.system(size: model.scaled(13)))
        .controlSize(model.textSize.controlSize)
        .tint(model.theme.accent(scheme))
        .environment(\.locale, Locale(identifier: "en_US"))
    }
}

private let english = Locale(identifier: "en_US")

private struct GeneralSettings: View {
    @ObservedObject var model: Model
    @ObservedObject var updater: Updater
    @StateObject private var loginItem = LoginItem()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { loginItem.enabled }, set: { loginItem.set($0) })) {
                    TitleAndDetail(model: model, title: "Open at login", detail: loginItem.detail)
                }
                .toggleStyle(.switch)
                if loginItem.status == .requiresApproval {
                    Button("Open Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            .onAppear { loginItem.refresh() }
            Section {
                LabeledContent("Text size") {
                    Picker("Text size", selection: $model.textSize) {
                        ForEach(FindlingTextSize.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .frame(width: model.scaled(216))
                }
                LabeledContent {
                    HStack(spacing: model.scaled(10)) {
                        ForEach(FindlingTheme.allCases) { swatch($0) }
                    }.padding(.trailing, 4)
                } label: {
                    TitleAndDetail(model: model, title: "Theme color", detail: model.theme.title)
                }
            } header: {
                SectionTitle(model: model, text: "Appearance")
            } footer: {
                SectionFooter(model: model, text: "Colors adapt to your Mac’s light or dark appearance. Changes apply immediately and are saved.")
            }
            Section {
                ShortcutRow(model: model, shortcut: model.shortcut)
                LabeledContent("Clear search text") {
                    HStack(spacing: 6) {
                        KeyCap(model: model, keys: "⇧⌫", spoken: "Shift Delete")
                        Text("or").foregroundStyle(.secondary)
                        KeyCap(model: model, keys: "⌘⌫", spoken: "Command Delete")
                    }
                }
            } header: {
                SectionTitle(model: model, text: "Keyboard")
            }
            Section {
                Toggle(isOn: $updater.automatic) {
                    TitleAndDetail(model: model, title: "Check for updates automatically", detail: "Once a day Findling asks GitHub for the latest version number.")
                }
                .toggleStyle(.switch)
                UpdateRow(model: model, updater: updater)
            } header: {
                SectionTitle(model: model, text: "Updates")
            } footer: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Everything stays on this Mac.").foregroundStyle(.primary)
                        Text("No telemetry. The update check sends nothing about you or your files, and Findling never moves or changes them.")
                            .font(.system(size: model.scaled(11))).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "lock").font(.system(size: model.scaled(12))).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
            }
        }
    }

    private func swatch(_ theme: FindlingTheme) -> some View {
        let selected = model.theme == theme
        let color = theme.selection(scheme)
        let size = model.scaled(18)
        return Button { model.theme = theme } label: {
            Circle().fill(color)
                .overlay { Circle().strokeBorder(.black.opacity(0.18), lineWidth: 0.5) }
                .overlay { if selected { Circle().fill(.white).frame(width: model.scaled(6), height: model.scaled(6)) } }
                .overlay { if selected { Circle().strokeBorder(color, lineWidth: 1.5).padding(-3.5) } }
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(theme.title)
        .accessibilityLabel(theme.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct UpdateRow: View {
    @ObservedObject var model: Model
    @ObservedObject var updater: Updater

    var body: some View {
        if let release = updater.release, let version = release.version {
            LabeledContent {
                Button("Download and Install") { updater.install() }
                    .disabled(busy)
                    .help("Downloads the disk image and opens it, then Findling quits so you can drag the new version to Applications.")
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Findling \(version.description) is available")
                    switch updater.status {
                    case .downloading(let fraction):
                        ProgressView(value: fraction).accessibilityLabel("Downloading Findling \(version.description)").frame(height: model.scaled(14))
                    case .opening:
                        detail("Drag Findling from the disk image to Applications and replace this version.")
                    case .failed(let reason):
                        WarningLine(model: model, text: reason)
                    default:
                        HStack(spacing: 4) {
                            detail("You have \(updater.current.description).")
                            Link("Release Notes", destination: release.page).font(.system(size: model.scaled(11)))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            LabeledContent {
                Button("Check Now") { updater.check(manual: true) }.disabled(updater.status == .checking)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Findling \(updater.current.description)")
                    switch updater.status {
                    case .checking: detail("Checking for updates…")
                    case .upToDate: detail("This is the latest version.")
                    case .checkFailed(let reason): WarningLine(model: model, text: "Couldn’t check for updates. " + reason)
                    default: detail(updater.lastCheck.map { "Last checked: " + LauncherStyle.date($0) } ?? "Not checked yet.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var busy: Bool {
        switch updater.status {
        case .downloading, .opening: return true
        default: return false
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(.system(size: model.scaled(11))).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct LocationSettings: View {
    @ObservedObject var model: Model

    var body: some View {
        Form {
            Section {
                if model.roots.isEmpty {
                    EmptyRow(text: "No search locations. Add a folder to start searching.")
                }
                ForEach(arrangedRoots, id: \.path) { root in
                    locationRow(root.path, coveredBy: root.parent)
                }
            } header: {
                SectionTitle(model: model, text: "Search locations")
            } footer: {
                SectionFooter(model: model, text: "Everything inside these folders is indexed. To skip a subfolder, add it under Exclusions.") {
                    Button("Add Folder…") { model.addFolder() }
                }
            }
            Section {
                if model.folderFilters.isEmpty { EmptyRow(text: "No folder filters") }
                ForEach(model.folderFilters, id: \.self) { path in
                    PathRow(model: model, path: path, title: model.filterTitle(path)) { model.removeFolderFilter(path) }
                }
            } header: {
                SectionTitle(model: model, text: "Folder filters")
            } footer: {
                SectionFooter(model: model, text: "Each folder becomes a button in the launcher’s “Search in” row, next to Everywhere; right-click it there to rename or remove it. Combine it with \(typeNames).") {
                    Button("Add Folder Filter…") { model.addFolderFilter() }
                }
            }
        }
        .onAppear { model.refreshLocationCounts() }
        .onChange(of: model.count) { model.refreshLocationCounts() }
        .onChange(of: model.roots) { model.refreshLocationCounts() }
    }

    private var typeNames: String {
        let names = model.kinds.dropFirst().map(\.1)
        return names.dropLast().joined(separator: ", ") + " or " + (names.last ?? "")
    }

    private var arrangedRoots: [(path: String, parent: String?)] {
        let parents = Dictionary(model.roots.map { ($0, model.coveringRoot(of: $0)) }) { first, _ in first }
        return model.roots.filter { parents[$0] ?? nil == nil }.flatMap { top in
            [(top, nil)] + model.roots.filter { parents[$0] ?? nil == top }.map { ($0, top) }
        }
    }

    private func locationRow(_ path: String, coveredBy parent: String?) -> some View {
        let title = locationTitle(path)
        let appFolders = path.hasSuffix("/com~apple~CloudDocs") ? model.iCloudAppFolders.values.compactMap(\.first).sorted() : []
        return HStack(spacing: 10) {
            Image(nsImage: LauncherStyle.icon(path)).resizable()
                .frame(width: model.scaled(20), height: model.scaled(20))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Group {
                    if appFolders.isEmpty {
                        Text(LauncherStyle.path(path)).truncationMode(.middle).help(LauncherStyle.path(path))
                    } else {
                        Text("Includes app folders: " + appFolders.joined(separator: ", "))
                            .help("iCloud Drive shows these app folders too, so they are searched with it: " + appFolders.joined(separator: ", "))
                    }
                }
                .font(.system(size: model.scaled(11))).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            Group {
                if let parent {
                    Text("Already in \(locationTitle(parent))")
                        .help("\(locationTitle(parent)) already includes this folder, so it adds no items.")
                } else if let items = model.locationCounts[path] {
                    Text(items == 1 ? "1 item" : "\(items.formatted(.number.locale(english))) items").monospacedDigit()
                }
            }
            .font(.system(size: model.scaled(11))).foregroundStyle(.secondary).fixedSize()
            RemoveButton(model: model, title: title) {
                model.roots.removeAll { $0 == path }; model.persistRoots()
            }
        }
        .padding(.leading, parent == nil ? 0 : model.scaled(30))
    }
}

private struct ExclusionSettings: View {
    @ObservedObject var model: Model
    @ObservedObject var state: SettingsState

    private var hidden: [String] { model.preferences.filter(\.value.hidden).keys.sorted() }

    var body: some View {
        Form {
            Section {
                if model.excludedFolders.isEmpty { EmptyRow(text: "No excluded folders") }
                ForEach(model.excludedFolders, id: \.self) { path in
                    PathRow(model: model, path: path) {
                        model.excludedFolders.removeAll { $0 == path }; model.persistExclusions()
                    }
                }
            } header: {
                SectionTitle(model: model, text: "Excluded folders")
            } footer: {
                SectionFooter(model: model, text: "These folders and everything inside them are never indexed, even inside a search location or a folder filter.") {
                    Button("Exclude Folder…") { model.addExcludedFolder() }
                }
            }
            Section {
                ForEach(SkipRules.categories) { category in
                    Toggle(isOn: Binding(get: { !model.disabledSkips.contains(category.id) },
                                         set: { model.setSkipCategory(category.id, enabled: $0) })) {
                        TitleAndDetail(model: model, title: category.title, detail: category.examples)
                    }
                    .toggleStyle(.switch)
                    .disabled(model.indexing)
                    .help(category.detail)
                }
                DisclosureRow(model: model, title: "Always skipped", isExpanded: $state.showsAlwaysSkipped)
                if state.showsAlwaysSkipped {
                    TitleAndDetail(model: model, title: "Folders by name",
                                   detail: Scanner.excluded.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: ", "), lines: 2)
                    TitleAndDetail(model: model, title: "Hidden files and folders", detail: "Names that start with a dot")
                    TitleAndDetail(model: model, title: "Symbolic links", detail: "Links are not followed")
                    TitleAndDetail(model: model, title: "Package contents", detail: "The package itself, like an app, is still found")
                    Text("Locations you add are scanned even inside a skipped folder, for example cloud folders in Library. Excluded folders always take priority.")
                        .font(.system(size: model.scaled(11))).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                SectionTitle(model: model, text: "Automatically skipped")
            } footer: {
                SectionFooter(model: model, text: model.indexing
                              ? "You can change these when indexing finishes."
                              : "Turn a category off to index its folders. All locations are then walked again.")
            }
            Section {
                LabeledContent {
                    Button("Restore All") { model.restoreHidden() }.disabled(hidden.isEmpty)
                } label: {
                    TitleAndDetail(model: model,
                                   title: hidden.isEmpty ? "No hidden results" : hidden.count == 1 ? "1 hidden result" : "\(hidden.count) hidden results",
                                   detail: hidden.isEmpty ? "Hide a result from its actions menu to keep it out of search." : "Hidden from a result’s actions menu.")
                }
                if !hidden.isEmpty {
                    DisclosureRow(model: model, title: "Show hidden results", isExpanded: $state.showsHidden)
                    if state.showsHidden {
                        ForEach(hidden, id: \.self) { path in
                            HStack(spacing: 10) {
                                Image(nsImage: LauncherStyle.icon(path)).resizable()
                                    .frame(width: model.scaled(16), height: model.scaled(16))
                                    .padding(.horizontal, model.scaled(2))
                                TitleAndDetail(model: model, title: URL(fileURLWithPath: path).lastPathComponent,
                                               detail: LauncherStyle.path(URL(fileURLWithPath: path).deletingLastPathComponent().path))
                                    .textSelection(.enabled)
                                Spacer(minLength: 12)
                                Button("Restore") { model.preferences[path]?.hidden = false; model.savePreferences() }
                            }
                        }
                    }
                }
            } header: {
                SectionTitle(model: model, text: "Hidden results")
            }
        }
    }
}

private struct IndexSettings: View {
    @ObservedObject var model: Model

    private static let updated: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = english
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    var body: some View {
        let files = model.catalogFiles
        Form {
            if !model.warnings.isEmpty {
                Section {
                    ForEach(model.warnings, id: \.self) { warning in
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: model.scaled(14)))
                                .foregroundStyle(.orange).frame(width: model.scaled(20))
                            TitleAndDetail(model: model, title: LauncherStyle.path(warning.path), detail: warning.reason, lines: 2)
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        SectionTitle(model: model, text: "Access warnings")
                        Text("\(model.warnings.count)")
                            .font(.system(size: model.scaled(11), weight: .semibold)).monospacedDigit()
                            .padding(.horizontal, 6).background(.quaternary, in: Capsule())
                    }
                } footer: {
                    SectionFooter(model: model, text: "Findling couldn’t read these folders, so nothing inside them shows up in results. Grant access in Privacy Settings, or exclude the folders.") {
                        Button("Open Privacy Settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
            }
            Section {
                LabeledContent("Searchable items") {
                    Text(model.count.formatted(.number.locale(english))).monospacedDigit()
                }
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        if model.indexing, model.indexingProgress.fraction == nil { ProgressView().controlSize(.small) }
                        Text(model.indexing ? model.indexingProgress.summary : "Ready to search").monospacedDigit()
                    }
                }
                if model.indexing {
                    VStack(alignment: .leading, spacing: 6) {
                        if let fraction = model.indexingProgress.fraction {
                            ProgressView(value: fraction).accessibilityLabel("Index import")
                        }
                        Text(model.indexingProgress.detail)
                        if let path = model.indexingProgress.currentPath {
                            Text(LauncherStyle.path(path)).lineLimit(1).truncationMode(.middle).help(path).textSelection(.enabled)
                        }
                    }
                    .font(.system(size: model.scaled(11))).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let modified = files.modified {
                    LabeledContent("Last updated", value: Self.updated.string(from: modified))
                }
                if files.bytes > 0 {
                    LabeledContent("Size on disk", value: files.bytes.formatted(.byteCount(style: .file).locale(english)))
                }
            } header: {
                SectionTitle(model: model, text: "Index")
            } footer: {
                SectionFooter(model: model, text: "File changes are picked up within about 3 seconds.")
            }
            Section {
                LabeledContent("Check all locations again") {
                    Button("Refresh Now") { model.refresh() }
                        .disabled(model.indexing)
                        .help("Walks every location again (about 2 minutes) and writes only what changed.")
                }
            } footer: {
                SectionFooter(model: model, text: "Only needed after a “could not watch your folders” warning or for network volumes.")
            }
        }
    }
}

private struct SectionTitle: View {
    @ObservedObject var model: Model
    let text: String
    var body: some View {
        Text(text).font(.system(size: model.scaled(13), weight: .semibold)).foregroundStyle(.primary)
    }
}

/// Without the leading frame, a description shorter than the row is centered.
private struct SectionFooter<Action: View>: View {
    @ObservedObject var model: Model
    let text: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(text)
                .font(.system(size: model.scaled(11))).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            action()
        }
    }
}

extension SectionFooter where Action == EmptyView {
    init(model: Model, text: String) {
        self.init(model: model, text: text) { EmptyView() }
    }
}

private struct TitleAndDetail: View {
    @ObservedObject var model: Model
    let title: String
    let detail: String
    var lines = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.system(size: model.scaled(11))).foregroundStyle(.secondary).lineLimit(lines)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// DisclosureGroup puts its content into a single row of a grouped form; these rows stay separate.
private struct DisclosureRow: View {
    @ObservedObject var model: Model
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button { isExpanded.toggle() } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: model.scaled(11), weight: .semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

private struct EmptyRow: View {
    let text: String
    var body: some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PathRow: View {
    @ObservedObject var model: Model
    let path: String
    var title: String?
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").font(.system(size: model.scaled(14))).foregroundStyle(.secondary)
                .frame(width: model.scaled(20))
            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? locationTitle(path))
                Text(LauncherStyle.path(path)).font(.system(size: model.scaled(11))).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(LauncherStyle.path(path))
            }
            Spacer(minLength: 12)
            RemoveButton(model: model, title: title ?? locationTitle(path), action: remove)
        }
    }
}

private struct RemoveButton: View {
    @ObservedObject var model: Model
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle").font(.system(size: model.scaled(15)))
                .frame(width: model.scaled(22), height: model.scaled(22))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless).foregroundStyle(.secondary)
        .help("Remove \(title)")
        .accessibilityLabel("Remove \(title)")
    }
}

private struct ShortcutRow: View {
    @ObservedObject var model: Model
    @ObservedObject var shortcut: OpenShortcut
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LabeledContent {
            HStack(spacing: model.scaled(8)) {
                recorder
                Button("Reset") { shortcut.reset() }
                    .disabled(shortcut.current == .standard)
                    .help("Use \(Shortcut.standard.title) again")
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Open Findling")
                if let refusal = shortcut.refusal {
                    WarningLine(model: model, text: refusal)
                } else {
                    Text(shortcut.recording ? "Press the new shortcut. Esc cancels." : "Works from any app.")
                        .font(.system(size: model.scaled(11))).foregroundStyle(.secondary)
                }
                if let problem = shortcut.problem { WarningLine(model: model, text: problem.message(current: shortcut.current)) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var recorder: some View {
        let waiting = shortcut.recording && shortcut.held == 0
        let text = shortcut.recording ? (waiting ? "Type shortcut" : Shortcut.symbols(shortcut.held)) : shortcut.current.title
        return Button { shortcut.recording ? shortcut.cancelRecording() : shortcut.beginRecording() } label: {
            Text(text)
                .font(.system(size: model.scaled(12), weight: .medium)).foregroundStyle(waiting ? .secondary : .primary)
                .lineLimit(1)
                .frame(minWidth: model.scaled(92))
                .padding(.horizontal, model.scaled(6)).padding(.vertical, model.scaled(3))
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                .overlay {
                    if shortcut.recording { RoundedRectangle(cornerRadius: 5).strokeBorder(model.theme.accent(scheme), lineWidth: 1.5) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(shortcut.recording ? "Press the new shortcut. Esc cancels." : "Click to record a new shortcut")
        .accessibilityLabel("Shortcut to open Findling")
        .accessibilityValue(shortcut.recording ? "Recording" : shortcut.current.spoken)
        .accessibilityHint(shortcut.recording ? "Press the new shortcut, or Escape to cancel." : "Records a new shortcut.")
        .onDisappear { shortcut.cancelRecording() }
    }
}

private struct WarningLine: View {
    @ObservedObject var model: Model
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: model.scaled(11))).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
    }
}

private struct KeyCap: View {
    @ObservedObject var model: Model
    let keys: String
    let spoken: String

    var body: some View {
        Text(keys)
            .font(.system(size: model.scaled(12), weight: .medium)).foregroundStyle(.primary)
            .padding(.horizontal, model.scaled(6)).padding(.vertical, model.scaled(2))
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel(spoken)
    }
}

private func locationTitle(_ path: String) -> String {
    if path == FileManager.default.homeDirectoryForCurrentUser.path { return "Home folder" }
    if path.hasSuffix("com~apple~CloudDocs") { return "iCloud Drive" }
    if path.hasSuffix("CloudStorage") { return "Cloud folders" }
    return LauncherStyle.folderName(path)
}
