import AppKit
import SwiftUI

enum FindlingTextSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var scale: CGFloat {
        switch self {
        case .small: return 0.93
        case .medium: return 1
        case .large: return 1.14
        }
    }
    var controlSize: ControlSize {
        switch self {
        case .small: return .small
        case .medium: return .regular
        case .large: return .large
        }
    }
}

enum FindlingTheme: String, CaseIterable, Identifiable {
    case blue, purple, teal, rose
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    // Selection backgrounds keep white text readable in both appearances.
    func selection(_ scheme: ColorScheme) -> Color {
        let hex: UInt32
        switch self {
        case .blue: hex = scheme == .dark ? 0x0059D1 : 0x0063E1
        case .purple: hex = scheme == .dark ? 0x7049C8 : 0x6940C6
        case .teal: hex = scheme == .dark ? 0x087E78 : 0x007C73
        case .rose: hex = scheme == .dark ? 0xBB3F70 : 0xB83361
        }
        return Self.color(hex)
    }

    func accent(_ scheme: ColorScheme) -> Color {
        guard scheme == .dark else { return selection(scheme) }
        switch self {
        case .blue: return Self.color(0x80B4FF)
        case .purple: return Self.color(0xBEA1FF)
        case .teal: return Self.color(0x73D7C9)
        case .rose: return Self.color(0xF59ABC)
        }
    }

    func editorAccent(_ appearance: NSAppearance) -> NSColor {
        NSColor(accent(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light))
    }

    private static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255)
    }
}
