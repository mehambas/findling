import Foundation
import CoreServices
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Read only for the selected item while the preview is open; nothing here goes into the catalog.
public struct FileDetails: Sendable, Equatable {
    public var created: Date?
    public var modified: Date?
    /// Set by Launch Services when the item is opened; missing for items never opened through Finder or `open`.
    public var opened: Date?
    public var size: Int64?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var pages: Int?
    public var dataless = false
    /// Only Spotlight knows when apps and folders were opened, how large videos are and how many pages documents have.
    public var asksSpotlight = false

    public init() {}

    /// Reads the file system only, so it returns at once; `addingSpotlight` fills in the rest.
    public static func read(_ path: String) -> FileDetails {
        let url = URL(fileURLWithPath: path)
        var details = FileDetails()
        guard let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .contentTypeKey]) else {
            return details
        }
        details.created = values.creationDate
        details.modified = values.contentModificationDate
        details.dataless = isDataless(path)
        details.setOpened(lastUsed(path))
        let regular = values.isRegularFile == true
        // Placeholders show dates only: reading their content would download them.
        guard !details.dataless else { details.asksSpotlight = !regular; return details }
        if regular, let size = values.fileSize { details.size = Int64(size) }
        let type = values.contentType
        if let type, type.conforms(to: .image), let pixels = imagePixels(url) {
            (details.pixelWidth, details.pixelHeight) = pixels
        }
        if let type, type.conforms(to: .pdf), let count = CGPDFDocument(url as CFURL)?.numberOfPages, count > 0 {
            details.pages = count
        }
        details.asksSpotlight = !regular || !(type.map { $0.conforms(to: .image) || $0.conforms(to: .pdf) || $0.conforms(to: .text) } ?? false)
        return details
    }

    /// Spotlight can block for seconds (up to 10 s measured, on notes it has not indexed), so this runs apart from `read`.
    public func addingSpotlight(_ path: String) -> FileDetails {
        guard asksSpotlight, let item = MDItemCreateWithURL(nil, URL(fileURLWithPath: path) as CFURL) else { return self }
        let names = [kMDItemLastUsedDate, kMDItemPixelWidth, kMDItemPixelHeight, kMDItemNumberOfPages] as CFArray
        let values = MDItemCopyAttributes(item, names) as? [String: Any] ?? [:]
        var details = self
        if opened == nil { details.setOpened(values[kMDItemLastUsedDate as String] as? Date) }
        guard !dataless else { return details }
        if pixelWidth == nil, let width = values[kMDItemPixelWidth as String] as? Int, let height = values[kMDItemPixelHeight as String] as? Int {
            (details.pixelWidth, details.pixelHeight) = (width, height)
        }
        if pages == nil { details.pages = values[kMDItemNumberOfPages as String] as? Int }
        return details
    }

    private mutating func setOpened(_ date: Date?) {
        // Spotlight reports the modification date for items it has not indexed, and Nextcloud stamps it on every file it syncs.
        if let date, let modified, abs(date.timeIntervalSince(modified)) < 1 { opened = nil } else { opened = date }
    }

    /// iCloud with optimized storage and File Provider clouds (Nextcloud, Dropbox) leave such placeholders.
    public static func isDataless(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_flags & UInt32(SF_DATALESS) != 0
    }

    public var sizeSummary: String? {
        guard let size else { return nil }
        let style = ByteCountFormatStyle(style: .file, spellsOutZero: false, locale: Locale(identifier: "en_US"))
        var parts = [size.formatted(style)]
        if let pixelWidth, let pixelHeight { parts.append("\(pixelWidth) × \(pixelHeight)") }
        if let pages { parts.append(pages == 1 ? "1 page" : "\(pages) pages") }
        return parts.joined(separator: " · ")
    }

    /// Files carry it themselves; apps and folders have it only in Spotlight.
    private static func lastUsed(_ path: String) -> Date? {
        var time = timespec()
        guard getxattr(path, "com.apple.lastuseddate#PS", &time, MemoryLayout<timespec>.size, 0, 0) == MemoryLayout<timespec>.size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }
    private static func imagePixels(_ url: URL) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        // EXIF orientations 5–8 turn the stored pixels by 90°; Finder shows the size as displayed.
        let rotated = (5...8).contains(properties[kCGImagePropertyOrientation] as? Int ?? 1)
        return rotated ? (height, width) : (width, height)
    }
}
