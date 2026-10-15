import Foundation

/// Names macOS shows instead of the file name in the user's languages: an app's display name
/// (Calendar.app is "Kalender" in German, "Takvim" in Turkish), system folders such as Documents
/// ("Dokumente") and the app folders iCloud Drive shows ("Obsidian"). Findling itself is
/// English-only, so the system would answer in English; the user's languages are matched
/// against the available localizations explicitly.
///
/// Each list starts with the name Finder shows, which may be the file name itself, followed by
/// the names in the user's other languages. An empty list means every name is the file name.
public enum LocalizedNames {
    public static func app(_ path: String, languages: [String] = Locale.preferredLanguages) -> [String] {
        guard path.hasSuffix(".app"), let bundle = Bundle(url: URL(fileURLWithPath: path)) else { return [] }
        // System apps keep every language in one loctable, others a strings file per language.
        let loctable = bundle.path(forResource: "InfoPlist", ofType: "loctable").flatMap(strings)
        let file = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let names = localizations(bundle.localizations, for: languages).map { localization -> String in
            let tables = [loctable?[localization] as? [String: Any],
                          bundle.path(forResource: "InfoPlist", ofType: "strings", inDirectory: nil, forLocalization: localization).flatMap(strings)]
            return tables.compactMap { $0 }.lazy.flatMap { table in ["CFBundleDisplayName", "CFBundleName"].compactMap { table[$0] as? String } }.first { !$0.isEmpty } ?? file
        }
        return distinct(names, file: file).map { $0 + ".app" }
    }

    /// Localized system folders directly inside `parents`, recognized as Finder does: a
    /// `.localized` marker inside the folder and an entry in the system's folder table.
    public static func folders(in parents: [String], languages: [String] = Locale.preferredLanguages) -> [String: [String]] {
        let base = "/System/Library/CoreServices/SystemFolderLocalizations"
        let available = ((try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []).filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(6)) }
        let tables = localizations(available, for: languages).compactMap { strings("\(base)/\($0).lproj/SystemFolderLocalizations.strings") }
        guard let first = tables.first else { return [:] }
        var found: [String: [String]] = [:]
        for parent in parents {
            for name in first.keys {
                let path = (parent == "/" ? "" : parent) + "/" + name
                guard access(path + "/.localized", F_OK) == 0 else { continue }
                let names = distinct(tables.map { $0[name] as? String ?? name }, file: name)
                if !names.isEmpty { found[path] = names }
            }
        }
        return found
    }

    /// App folders iCloud Drive shows next to its own files (Obsidian, Pages, Books): the
    /// `Documents` folder of each app container that holds something, named as Finder names it.
    public static func iCloudAppFolders(home: String) -> [String: [String]] {
        let base = home + "/Library/Mobile Documents"
        var found: [String: [String]] = [:]
        for container in (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? [] where container != "com~apple~CloudDocs" && !container.hasPrefix(".") {
            let documents = base + "/" + container + "/Documents"
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: documents), items.contains(where: { !$0.hasPrefix(".") }) else { continue }
            found[CatalogPath.canonical(documents)] = [CatalogPath.canonical(FileManager.default.displayName(atPath: base + "/" + container))]
        }
        return found
    }

    /// The localization Finder uses first, then the best one for each of the user's other languages.
    private static func localizations(_ available: [String], for languages: [String]) -> [String] {
        let shown = Bundle.preferredLocalizations(from: available, forPreferences: languages).prefix(1)
        let others = languages.compactMap { language in
            Bundle.preferredLocalizations(from: available, forPreferences: [language]).first { code($0) == code(language) }
        }
        var seen: Set<String> = []
        return (shown + others).filter { seen.insert($0).inserted }
    }
    private static func code(_ identifier: String) -> String? { Locale(identifier: identifier).language.languageCode?.identifier }

    /// Drops repeats and invisible format characters, such as soft hyphens (System­einstellungen)
    /// or direction marks (‎WhatsApp), which only guide layout.
    private static func distinct(_ names: [String], file: String) -> [String] {
        var seen: Set<String> = [], result: [String] = []
        for name in names {
            let visible = CatalogPath.canonical(String(String.UnicodeScalarView(name.unicodeScalars.filter { $0.properties.generalCategory != .format })))
            if seen.insert(Search.normalize(visible)).inserted { result.append(visible) }
        }
        return result.allSatisfy({ Search.normalize($0) == Search.normalize(file) }) ? [] : result
    }

    /// Reads compiled and hand-written strings files alike. `NSDictionary(contentsOfFile:)` and
    /// `propertyListFromStringsFileFormat()` raise Objective-C exceptions on empty files, which
    /// some apps ship and Swift cannot catch.
    private static func strings(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
