import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import FindlingCore

final class FileDetailsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func writeImage(_ name: String, width: Int, height: Int, type: UTType, orientation: Int = 1) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testImageSizeAndDates() throws {
        let url = try writeImage("photo.png", width: 640, height: 480, type: .png)
        let created = Date(timeIntervalSince1970: 1_773_300_000), modified = Date(timeIntervalSince1970: 1_791_000_000)
        try FileManager.default.setAttributes([.creationDate: created, .modificationDate: modified], ofItemAtPath: url.path)
        let details = FileDetails.read(url.path)
        XCTAssertEqual(details.created, created)
        XCTAssertEqual(details.modified, modified)
        XCTAssertFalse(details.dataless)
        XCTAssertEqual(details.size, try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64))
        XCTAssertEqual(details.pixelWidth, 640)
        XCTAssertEqual(details.pixelHeight, 480)
        XCTAssertNil(details.pages)
        XCTAssertTrue(details.sizeSummary?.hasSuffix(" · 640 × 480") == true, details.sizeSummary ?? "")
        XCTAssertNil(details.opened, "Spotlight's stand-in for items it has not indexed is the modification date")
    }

    func testLastOpenedFromLaunchServices() throws {
        let url = try writeImage("opened.png", width: 10, height: 10, type: .png)
        var time = timespec(tv_sec: 1_791_100_000, tv_nsec: 500_000_000)
        XCTAssertEqual(setxattr(url.path, "com.apple.lastuseddate#PS", &time, MemoryLayout<timespec>.size, 0, 0), 0)
        XCTAssertEqual(FileDetails.read(url.path).opened, Date(timeIntervalSince1970: 1_791_100_000.5))
    }

    func testSyncStampIsNotAnOpen() throws {
        let url = try writeImage("synced.png", width: 10, height: 10, type: .png)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_780_000_000)], ofItemAtPath: url.path)
        var time = timespec(tv_sec: 1_780_000_000, tv_nsec: 0)
        XCTAssertEqual(setxattr(url.path, "com.apple.lastuseddate#PS", &time, MemoryLayout<timespec>.size, 0, 0), 0)
        XCTAssertNil(FileDetails.read(url.path).opened)
    }

    func testRotatedPhotoShowsDisplayedSize() throws {
        let url = try writeImage("portrait.jpg", width: 400, height: 300, type: .jpeg, orientation: 6)
        let details = FileDetails.read(url.path)
        XCTAssertEqual(details.pixelWidth, 300)
        XCTAssertEqual(details.pixelHeight, 400)
    }

    func testPDFPages() throws {
        let url = folder.appendingPathComponent("report.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<3 {
            context.beginPDFPage(nil)
            context.fill(CGRect(x: 40, y: 40, width: 200, height: 20))
            context.endPDFPage()
        }
        context.closePDF()
        let details = FileDetails.read(url.path)
        XCTAssertEqual(details.pages, 3)
        XCTAssertNil(details.pixelWidth)
        XCTAssertTrue(details.sizeSummary?.hasSuffix(" · 3 pages") == true, details.sizeSummary ?? "")
    }

    func testSpotlightOnlyWhereNothingElseKnows() throws {
        let note = folder.appendingPathComponent("note.md"), document = folder.appendingPathComponent("letter.docx")
        try "# Not".write(to: note, atomically: true, encoding: .utf8)
        try Data().write(to: document)
        XCTAssertFalse(FileDetails.read(note.path).asksSpotlight)
        XCTAssertFalse(FileDetails.read(try writeImage("photo.png", width: 10, height: 10, type: .png).path).asksSpotlight)
        XCTAssertTrue(FileDetails.read(document.path).asksSpotlight, "Page counts of documents come from Spotlight")
        XCTAssertTrue(FileDetails.read(folder.path).asksSpotlight, "Folders and apps keep their last open in Spotlight")
        let added = FileDetails.read(folder.path).addingSpotlight(folder.path)
        XCTAssertTrue(added.opened == nil || added.opened != added.modified)
        let text = FileDetails.read(note.path)
        XCTAssertEqual(text.addingSpotlight(note.path), text)
    }

    func testFolderHasDatesButNoSize() throws {
        let details = FileDetails.read(folder.path)
        XCTAssertNotNil(details.created)
        XCTAssertNotNil(details.modified)
        XCTAssertNil(details.size)
        XCTAssertNil(details.sizeSummary)
    }

    func testSizeSummaryFormatting() {
        var details = FileDetails()
        details.size = 2_400_000
        details.pages = 1
        XCTAssertEqual(details.sizeSummary, "2.4 MB · 1 page")
        details.size = 0
        details.pages = nil
        XCTAssertEqual(details.sizeSummary, "0 bytes")
    }

    func testMissingFileReadsNothing() {
        let details = FileDetails.read(folder.appendingPathComponent("missing.txt").path)
        XCTAssertEqual(details, FileDetails())
    }
}
