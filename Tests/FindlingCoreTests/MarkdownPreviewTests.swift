import XCTest
@testable import FindlingCore

final class MarkdownPreviewTests: XCTestCase {
    private func outline(_ source: String) -> [String] {
        MarkdownPreview.blocks(source).map { block in
            let text = String(block.text.characters)
            switch block.kind {
            case .heading(let level): return "h\(level) \(text)"
            case .paragraph: return "p \(text)"
            case .item(let depth, let marker): return "\(String(repeating: "  ", count: depth - 1))\(marker.isEmpty ? "" : marker + " ")\(text)"
            case .quote: return "> \(text)"
            case .code: return "code \(text)"
            case .table: return "table\n\(text)"
            case .rule: return "---"
            }
        }
    }

    func testBlocks() {
        let source = """
        # Başlık

        Bir **kalın** paragraf.

        ## Alt başlık
        - bir
          - iç içe
        - [ ] yapılacak
        - [x] bitti

        1. birinci

           ikinci paragraf
        2. ikinci

        ```swift
        let x = 1
        ```

        ---
        """
        XCTAssertEqual(outline(source), ["h1 Başlık", "p Bir kalın paragraf.", "h2 Alt başlık", "• bir", "  ◦ iç içe", "☐ yapılacak", "☑ bitti",
                                         "1. birinci", "ikinci paragraf", "2. ikinci", "code let x = 1", "---"])
    }

    func testInlineStylesStay() throws {
        let block = try XCTUnwrap(MarkdownPreview.blocks("Bir **kalın** ve `kod`").first)
        XCTAssertTrue(block.text.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized && String(block.text[$0.range].characters) == "kalın" })
        XCTAssertTrue(block.text.runs.contains { $0.inlinePresentationIntent == .code })
    }

    func testFrontMatterIsDropped() {
        XCTAssertEqual(outline("---\ntags: [a, b]\ncreated: 2026-04-08\n---\n# Not"), ["h1 Not"])
        XCTAssertEqual(outline("---\r\ntags: [a]\r\n---\r\nMetin"), ["p Metin"])
        XCTAssertEqual(outline("Metin\n\n---\n\nSon"), ["p Metin", "---", "p Son"], "A rule later in the text is not front matter")
    }

    func testObsidianLinksAndCallouts() {
        XCTAssertEqual(outline("Bak: [[Yol Haritası]], [[Plan|plana]], [[Not#Bölüm]] ve ![[resim.png]]"),
                       ["p Bak: Yol Haritası, plana, Not › Bölüm ve resim.png"])
        XCTAssertEqual(outline("> [!note] Dikkat\n> içerik"), ["> Dikkat\niçerik"])
        XCTAssertEqual(outline("> [!warning]\n> içerik"), ["> Warning\niçerik"])
        XCTAssertEqual(outline("```\n[[kalsın]]\n> [!note] kalsın\n```"), ["code [[kalsın]]\n> [!note] kalsın"], "Code stays as written")
    }

    func testTableIsAligned() throws {
        XCTAssertEqual(outline("| Ad | Boyut |\n|---|---|\n| Medium | 128 pt |\n| Large | 128 |"),
                       ["table\nAd      Boyut \nMedium  128 pt\nLarge   128   "])
        let table = try XCTUnwrap(MarkdownPreview.blocks("| Ad | Boyut |\n|---|---|\n| ç | 2 |").first?.text)
        XCTAssertEqual(table.runs.compactMap { $0.inlinePresentationIntent == .stronglyEmphasized ? String(table[$0.range].characters) : nil }, ["Ad  Boyut"])
    }

    func testCutOffTextStillReads() {
        XCTAssertEqual(outline("# Başlık\n\n```swift\nlet x = 1\nlet y"), ["h1 Başlık", "code let x = 1\nlet y"])
        XCTAssertEqual(outline("- [ ]"), ["• [ ]"])
        XCTAssertEqual(outline(""), [])
    }
}
