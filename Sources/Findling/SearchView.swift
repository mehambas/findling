import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FindlingCore

// Measurements and colors from the OpenDesign Findling macOS launcher board.
enum LauncherStyle {
    private static let icons: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>(); cache.countLimit = 512; return cache
    }()
    static func icon(_ path: String) -> NSImage {
        if let image = icons.object(forKey: path as NSString) { return image }
        // Fixtures, and items deleted since the last index update, have no file to take the icon from.
        let image: NSImage
        if FileManager.default.fileExists(atPath: path) {
            image = NSWorkspace.shared.icon(forFile: path)
        } else {
            let pathExtension = URL(fileURLWithPath: path).pathExtension
            image = NSWorkspace.shared.icon(for: pathExtension.isEmpty ? .folder : UTType(filenameExtension: pathExtension) ?? .data)
        }
        icons.setObject(image, forKey: path as NSString)
        return image
    }
    private static let dates: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
    static func date(_ date: Date) -> String { dates.string(from: date) }
    static let kinds = [("Tümü", "All"), ("Uygulamalar", "Apps"), ("Projeler", "Projects"), ("Klasörler", "Folders"), ("Dosyalar", "Files")]
    static func kind(_ raw: String) -> String { kinds.first { $0.0 == raw }?.1 ?? raw }
    static func itemKind(_ entry: Entry) -> String {
        switch entry.kind {
        case "Uygulamalar": return "Application"
        case "Projeler": return "Project"
        case "Klasörler": return "Folder"
        default:
            let ext = URL(fileURLWithPath: entry.path).pathExtension
            return ext.isEmpty ? "File" : ext.uppercased() + " document"
        }
    }
    /// iCloud Drive and its app folders live under ~/Library/Mobile Documents; Finder shows them by name.
    static var cloudFolders: [(path: String, name: String)] = []
    static func path(_ path: String) -> String {
        for folder in cloudFolders where path == folder.path || path.hasPrefix(folder.path + "/") {
            return folder.name + path.dropFirst(folder.path.count)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : path.replacingOccurrences(of: home + "/", with: "~/")
    }
    /// Cloud folders are named `Provider-account` (`Nextcloud-cloud.example.com-Name`); Finder shows the provider.
    static func folderName(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        guard url.deletingLastPathComponent().lastPathComponent == "CloudStorage", let provider = url.lastPathComponent.split(separator: "-").first else {
            return url.lastPathComponent
        }
        return String(provider)
    }
}

struct LauncherMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct SearchView: View {
    @ObservedObject var model: Model
    @Environment(\.colorScheme) private var scheme
    @State private var showSpinner = false
    private var selectionColor: Color { model.theme.selection(scheme) }
    private var accent: Color { model.theme.accent(scheme) }
    private var fill: Color { scheme == .dark ? .white.opacity(0.13) : .black.opacity(0.09) }
    private var line: Color { scheme == .dark ? .white.opacity(0.1) : .black.opacity(0.1) }
    private var hasPreview: Bool { model.showingPreview && model.selected != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "magnifyingglass").font(.system(size: model.scaled(20))).foregroundStyle(.secondary)
                LauncherSearchField(model: model)
                ProgressView().controlSize(.small).frame(width: 16).opacity(showSpinner ? 1 : 0)
                Button { showSettings(nil) } label: {
                    Image(systemName: "gearshape").font(.system(size: model.scaled(16))).foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("Settings (⌘,)").accessibilityLabel("Settings")
            }
            .padding(.leading, 20).padding(.trailing, 16).frame(height: model.scaled(56))
            if model.showsFilters { filters }
            line.frame(height: 1)
            HStack(spacing: 0) {
                results.frame(width: hasPreview ? 296 : nil)
                    .frame(maxWidth: hasPreview ? nil : .infinity, maxHeight: .infinity)
                if hasPreview {
                    line.frame(width: 1)
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }.frame(maxHeight: .infinity)
            line.frame(height: 1)
            footer
        }
        .background {
            ZStack {
                LauncherMaterial()
                (scheme == .dark ? Color(red: 30/255, green: 30/255, blue: 32/255).opacity(0.82) : Color(red: 246/255, green: 246/255, blue: 248/255).opacity(0.8))
            }
        }
        .tint(accent)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(scheme == .dark ? .white.opacity(0.16) : .black.opacity(0.14), lineWidth: 0.5))
        .environment(\.locale, Locale(identifier: "en_US"))
        .task(id: hasPreview ? model.selection : nil) { await model.loadPreview() }
        .task(id: model.searching) {
            showSpinner = false
            guard model.searching else { return }
            try? await Task.sleep(nanoseconds: 120_000_000)
            if !Task.isCancelled { showSpinner = true }
        }
        .alert("Findling", isPresented: Binding(get: { !model.notice.isEmpty }, set: { if !$0 { model.notice = "" } })) {
            if let tab = model.noticeTab {
                Button("Open Settings") { model.notice = ""; showSettings(tab) }
                Button("OK", role: .cancel) { model.notice = "" }
            } else {
                Button("OK") { model.notice = "" }
            }
        } message: { Text(model.notice) }
    }

    private var filters: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(model.kinds, id: \.0) { raw, title in
                            Button { model.kind = raw; focusSearch() } label: {
                                Text(title).font(.system(size: model.scaled(12), weight: model.kind == raw ? .semibold : .medium))
                                    .foregroundStyle(model.kind == raw ? .primary : .secondary)
                                    .padding(.horizontal, 10).frame(height: model.scaled(24))
                                    .background(model.kind == raw ? fill : .clear, in: Capsule())
                            }.buttonStyle(.plain).accessibilityAddTraits(model.kind == raw ? [.isSelected] : [])
                        }
                    }
                }
                key("⇥").help("Tab to switch type filters; Shift-Tab to go back")
            }.frame(height: model.scaled(36))
            HStack(spacing: 10) {
                Text("Search in").font(.system(size: model.scaled(11), weight: .medium)).foregroundStyle(.secondary)
                    .fixedSize()
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            folderChip("Everywhere", path: nil).id("everywhere")
                            ForEach(model.folderFilters, id: \.self) { path in
                                folderChip(model.filterTitle(path), path: path).id(path)
                                    .contextMenu {
                                        Button("Rename Filter…") { NotificationCenter.default.post(name: .init("FindlingRenameFilter"), object: path) }
                                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                                        Divider()
                                        Button("Remove from Search in") { model.removeFolderFilter(path) }
                                    }
                            }
                            Button { NotificationCenter.default.post(name: .init("FindlingAddFilter"), object: nil) } label: {
                                Image(systemName: "plus").font(.system(size: model.scaled(11), weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: model.scaled(26), height: model.scaled(26))
                                    .background(fill.opacity(0.4), in: Circle())
                                    .overlay(Circle().strokeBorder(line, lineWidth: 1))
                                    .contentShape(Circle())
                            }.buttonStyle(.plain).help("Add a folder to this row").accessibilityLabel("Add Folder Filter…")
                        }.padding(.vertical, 2)
                    }
                    .onChange(of: model.activeFolder) { _, path in proxy.scrollTo(path ?? "everywhere") }
                }
            }.frame(height: model.scaled(36))
                .accessibilityElement(children: .contain).accessibilityLabel("Search location filters")
        }.padding(.horizontal, 16).frame(height: model.filterHeight)
    }
    private func folderChip(_ title: String, path: String?) -> some View {
        let selected = model.activeFolder == path
        return Button { model.activeFolder = path; focusSearch() } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder").font(.system(size: model.scaled(11)))
                Text(title).lineLimit(1)
                if selected { Image(systemName: "checkmark").font(.system(size: model.scaled(10), weight: .semibold)) }
            }.font(.system(size: model.scaled(12), weight: model.activeFolder == path ? .semibold : .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 10).frame(height: model.scaled(26))
                .background(selected ? selectionColor : fill.opacity(0.4), in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? selectionColor : line, lineWidth: 1))
        }.buttonStyle(.plain).help(path.map { "Filter: search only in " + LauncherStyle.path($0) } ?? "Filter: search all included locations")
            .accessibilityLabel("Search in \(title)")
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var results: some View {
        Group {
            if model.visibleHits.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.searching ? "Searching…" : model.indexing ? "No matches yet" : model.query.isEmpty ? "Your Mac, within reach" : "No results for “\(model.query)”")
                        .font(.system(size: model.scaled(14), weight: .medium)).lineLimit(2)
                    Text(model.indexing ? "Still indexing; new items will appear." : "Findling matches names and paths, not what’s inside files. Check the spelling, or add the folder to your search scope.")
                        .font(.system(size: model.scaled(12))).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Search scope…") { showSettings(.locations) }.buttonStyle(.plain).foregroundStyle(accent).font(.system(size: model.scaled(12), weight: .medium)).padding(.top, 8)
                }.padding(.leading, 54).padding(.trailing, 20).padding(.vertical, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if model.query.isEmpty {
                                Text(model.kind == "Tümü" ? "Suggested" : LauncherStyle.kind(model.kind))
                                    .font(.system(size: model.scaled(11), weight: .semibold)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).frame(height: model.scaled(28))
                            }
                            ForEach(model.visibleHits) { hit in row(hit).id(hit.id) }
                            if model.visibleHits.count == 80 {
                                Text("Showing the first 80 results. Keep typing to narrow them down.")
                                    .font(.system(size: model.scaled(11))).foregroundStyle(.secondary).padding(8)
                            }
                        }.padding(8)
                    }
                    .onChange(of: model.selection) { _, value in if let value { proxy.scrollTo(value) } }
                }
            }
        }
    }

    private func row(_ hit: Hit) -> some View {
        let selected = model.selection == hit.id
        return HStack(spacing: 10) {
            Image(nsImage: LauncherStyle.icon(hit.id)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(highlighted(hit.entry.name)).font(.system(size: model.scaled(14), weight: .medium)).lineLimit(1)
                    if model.preferences[hit.id]?.pinned == true { Image(systemName: "pin.fill").font(.system(size: model.scaled(10))) }
                }.frame(height: model.scaled(18))
                (Text(hit.entry.project.isEmpty ? "" : hit.entry.project + " · ").fontWeight(.semibold)
                 + Text(LauncherStyle.path(URL(fileURLWithPath: hit.id).deletingLastPathComponent().path)))
                    .font(.system(size: model.scaled(12))).foregroundStyle(selected ? Color.white.opacity(0.9) : .secondary)
                    .lineLimit(1).truncationMode(.middle).frame(height: model.scaled(16))
            }.frame(maxWidth: .infinity, alignment: .leading)
            if selected && !hasPreview && (!model.query.isEmpty || model.preferences[hit.id]?.pinned == true) {
                Text(model.query.isEmpty ? "Pinned" : hit.reason).font(.system(size: model.scaled(12))).foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1).frame(maxWidth: 260, alignment: .trailing)
            }
        }.padding(.leading, 8).padding(.trailing, 12).frame(height: model.scaled(44))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? selectionColor : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.open(hit) }
            .onTapGesture { model.select(hit); focusSearch() }
            .contextMenu {
                Button("Open") { model.open(hit) }
                Button("Show in Finder") { model.reveal(hit) }
                Divider()
                Button(model.preferences[hit.id]?.pinned == true ? "Unpin" : "Pin") { model.pin(hit) }
                Button("Hide This Result") { model.hide(hit) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityAction { model.open(hit) }
    }

    private var detail: some View {
        ScrollView {
            if let hit = model.selected {
                let loaded = model.preview?.path == hit.id ? model.preview : nil
                let side = PreviewContent.showsThumbnail(hit.entry) ? PreviewContent.thumbnailSize : 64
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        Group {
                            if let thumbnail = loaded?.thumbnail {
                                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(line, lineWidth: 1))
                            } else {
                                Image(nsImage: LauncherStyle.icon(hit.id)).resizable()
                            }
                        }.frame(width: side, height: side)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.entry.name).font(.system(size: model.scaled(17), weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                            Text(LauncherStyle.itemKind(hit.entry)).font(.system(size: model.scaled(12))).foregroundStyle(.secondary)
                        }
                    }
                    Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
                        fact("Where", LauncherStyle.path(hit.id))
                        if !hit.entry.project.isEmpty { fact("Project", hit.entry.project) }
                        fact("Why", hit.reason)
                        if let details = loaded?.details {
                            if let date = details.created { fact("Created", LauncherStyle.date(date)) }
                            if let date = details.modified { fact("Modified", LauncherStyle.date(date)) }
                            if let date = details.opened { fact("Opened", LauncherStyle.date(date)) }
                            if let size = details.sizeSummary { fact("Size", size) }
                        }
                    }.font(.system(size: model.scaled(12))).textSelection(.enabled)
                    if let loaded, !loaded.markdown.isEmpty {
                        markdown(loaded.markdown, truncated: loaded.truncated)
                    } else if let text = loaded?.text, !text.isEmpty {
                        Text(text).font(.system(size: model.scaled(12), design: .monospaced)).lineSpacing(4)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.vertical, 10).padding(.horizontal, 12)
                            .background(fill.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                    }
                }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 16)
            }
        }
    }

    private func markdown(_ blocks: [MarkdownBlock], truncated: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks.indices, id: \.self) { index in
                markdownBlock(blocks[index]).padding(.top, index == 0 ? 0 : isItem(blocks[index]) && isItem(blocks[index - 1]) ? 3 : 8)
            }
            if truncated { Text("…").foregroundStyle(.secondary).padding(.top, 8) }
        }
        .font(.system(size: model.scaled(13))).lineSpacing(3)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { _ in .discarded })
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.vertical, 12).padding(.horizontal, 14)
        .background(fill.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }
    private func isItem(_ block: MarkdownBlock) -> Bool { if case .item = block.kind { return true } else { return false } }
    @ViewBuilder private func markdownBlock(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(block.text).font(.system(size: model.scaled(level == 1 ? 16 : level == 2 ? 14 : 13), weight: level == 1 ? .bold : .semibold))
                .padding(.top, level <= 2 ? 4 : 0)
        case .paragraph:
            Text(block.text)
        case .item(let depth, let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary).frame(minWidth: model.scaled(14), alignment: .trailing)
                Text(block.text).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.leading, CGFloat(depth - 1) * model.scaled(20))
        case .quote:
            Text(block.text).foregroundStyle(.secondary).padding(.leading, 12)
                .overlay(alignment: .leading) { Capsule().fill(.secondary.opacity(0.35)).frame(width: 3) }
        case .code, .table:
            Text(block.text).font(.system(size: model.scaled(12), design: .monospaced)).lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).padding(.horizontal, 10)
                .background(fill, in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            line.frame(height: 1).padding(.vertical, 2)
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                if model.indexing { ProgressView().controlSize(.mini) }
                Text(model.indexing ? model.indexingProgress.summary : "\(model.count.formatted(.number.locale(Locale(identifier: "en_US")))) items · on this Mac")
                    .lineLimit(1).truncationMode(.tail)
                    .help(model.indexing ? model.indexingProgress.help : "Open Settings for index details.")
                if !model.warnings.isEmpty {
                    Button { showSettings(.index) } label: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("\(model.warnings.count)").foregroundStyle(.secondary)
                    }.buttonStyle(.plain).help("\(model.warnings.count) access warnings")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if model.selected != nil {
                Button { model.open() } label: { hint("↵", "Open") }.buttonStyle(.plain)
                Button { model.showingPreview.toggle() } label: { hint(hasPreview ? "←" : "→", hasPreview ? "Close preview" : "Preview") }.buttonStyle(.plain)
                Button { NotificationCenter.default.post(name: .init("FindlingActions"), object: nil) } label: { hint("⌘K", "Actions") }.buttonStyle(.plain)
            } else {
                Button { showSettings(.locations) } label: { hint("⌘,", "Search scope") }.buttonStyle(.plain)
            }
        }.font(.system(size: model.scaled(11))).foregroundStyle(.secondary).padding(.horizontal, 16).frame(height: model.scaled(32))
    }
    private func key(_ value: String) -> some View {
        Text(value).font(.system(size: model.scaled(11), weight: .medium)).foregroundStyle(.primary)
            .padding(.horizontal, 4).frame(minWidth: model.scaled(18)).frame(height: model.scaled(18)).background(fill, in: RoundedRectangle(cornerRadius: 4))
    }
    private func hint(_ value: String, _ title: String) -> some View { HStack(spacing: 5) { key(value); Text(title) } }
    private func focusSearch() { NotificationCenter.default.post(name: .init("FindlingFocus"), object: nil) }
    private func showSettings(_ tab: SettingsTab?) { NotificationCenter.default.post(name: .init("FindlingSettings"), object: tab?.rawValue) }
    private func highlighted(_ name: String) -> AttributedString {
        var text = AttributedString(name)
        if !model.query.isEmpty, let range = text.range(of: model.query, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].font = .system(size: model.scaled(14), weight: .bold)
        }
        return text
    }
}
