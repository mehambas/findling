import Foundation

public struct MarkdownBlock: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case heading(Int), paragraph, item(depth: Int, marker: String), quote, code, table, rule
    }
    public let kind: Kind
    public let text: AttributedString
}

/// SwiftUI's Text draws Markdown's inline styles but runs headings, lists and code blocks together, so the preview lays out blocks itself.
public enum MarkdownPreview {
    public static func blocks(_ source: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let document = try? AttributedString(markdown: prepared(source), options: options) else { return [] }
        var blocks: [MarkdownBlock] = []
        var markedItems = Set<Int>()
        var table: (id: Int, cells: [Int: [Int: String]])?
        func flushTable() {
            if let cells = table?.cells { blocks.append(MarkdownBlock(kind: .table, text: layout(cells))) }
            table = nil
        }
        for (intent, range) in document.runs[\.presentationIntent] {
            guard let components = intent?.components else { continue }
            var text = AttributedString(document[range])
            if let tableID = components.first(where: { if case .table = $0.kind { return true } else { return false } })?.identity {
                if table?.id != tableID { flushTable(); table = (tableID, [:]) }
                var row = 0, column = 0
                for component in components {
                    if case .tableRow(let index) = component.kind { row = index }
                    if case .tableCell(let index) = component.kind { column = index }
                }
                table?.cells[row, default: [:]][column, default: ""] += String(text.characters)
                continue
            }
            flushTable()
            var kind = MarkdownBlock.Kind.paragraph
            var depth = 0, ordered: Bool?, quoted = false
            var item: PresentationIntent.IntentType?
            for component in components {
                switch component.kind {
                case .codeBlock: kind = .code
                case .header(let level): kind = .heading(level)
                case .thematicBreak: kind = .rule
                case .listItem: if item == nil { item = component }
                case .orderedList: depth += 1; ordered = ordered ?? true
                case .unorderedList: depth += 1; ordered = ordered ?? false
                case .blockQuote: quoted = true
                default: break
                }
            }
            if kind == .paragraph, let item, case .listItem(let ordinal) = item.kind {
                var marker = ""
                // Later paragraphs of the same item line up under the first one without a marker of their own.
                if markedItems.insert(item.identity).inserted {
                    marker = ordered == true ? "\(ordinal)." : depth > 1 ? "◦" : "•"
                    let start = String(text.characters.prefix(4))
                    if ["[ ] ", "[x] ", "[X] "].contains(start) {
                        marker = start == "[ ] " ? "☐" : "☑"
                        text.removeSubrange(text.startIndex..<text.index(text.startIndex, offsetByCharacters: 4))
                    }
                }
                kind = .item(depth: depth, marker: marker)
            } else if kind == .paragraph, quoted {
                kind = .quote
            }
            if kind == .code { while text.characters.last?.isNewline == true { text.characters.removeLast() } }
            if kind == .rule { text = AttributedString() }
            blocks.append(MarkdownBlock(kind: kind, text: text))
        }
        flushTable()
        return blocks
    }

    private static let wikiLink = try! Regex(#"!?\[\[([^\]]+)\]\]"#)
    private static let callout = try! Regex(#"^(\s*(?:>\s*)+)\[!([\w-]+)\][+-]?\s*(.*)$"#)

    /// Front matter and Obsidian's links and callouts are not CommonMark; left alone they show up as headings and brackets.
    static func prepared(_ source: String) -> String {
        var lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { ["---", "..."].contains($0.trimmingCharacters(in: .whitespaces)) }) {
            lines.removeSubrange(...end)
        }
        var fenced = false
        for index in lines.indices {
            let start = lines[index].drop { $0 == " " || $0 == ">" }
            if start.hasPrefix("```") || start.hasPrefix("~~~") { fenced.toggle(); continue }
            guard !fenced else { continue }
            lines[index] = lines[index].replacing(wikiLink) { match -> String in
                let target = match.output[1].substring.map(String.init) ?? ""
                if let bar = target.firstIndex(of: "|") { return String(target[target.index(after: bar)...]) }
                return target.split(separator: "#").joined(separator: " › ")
            }
            if let match = lines[index].firstMatch(of: callout) {
                let quote = match.output[1].substring ?? "", type = match.output[2].substring ?? "", title = match.output[3].substring ?? ""
                let continues = index + 1 < lines.count && lines[index + 1].drop { $0 == " " }.hasPrefix(">")
                // A hard break keeps the title on its own line; the quote's next line would otherwise join it.
                lines[index] = "\(quote)**\(title.isEmpty ? type.capitalized : String(title))**" + (continues ? "\\" : "")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Header row 0 in bold; columns padded for a monospaced font, since the preview is too narrow for a real table.
    private static func layout(_ cells: [Int: [Int: String]]) -> AttributedString {
        let rows = cells.keys.sorted()
        let columns = (cells.values.flatMap(\.keys).max() ?? -1) + 1
        let widths = (0..<columns).map { column in cells.values.map { $0[column]?.count ?? 0 }.max() ?? 0 }
        var text = AttributedString()
        for row in rows {
            var line = AttributedString((rows.first == row ? "" : "\n") + (0..<columns).map {
                (cells[row]?[$0] ?? "").padding(toLength: widths[$0], withPad: " ", startingAt: 0)
            }.joined(separator: "  "))
            if row == 0 { line.inlinePresentationIntent = .stronglyEmphasized }
            text += line
        }
        return text
    }
}
