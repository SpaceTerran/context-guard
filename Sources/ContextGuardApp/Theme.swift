import AppKit
import ContextGuardCore
import SwiftUI

/// SpaceTerran's colors and type, by role. Every color has a dark and a light value and
/// follows the appearance of the window it's drawn in. Views use roles, never hex values.
enum Theme {
    static let bg = color(dark: 0x0D0B12, light: 0xF7F6FB)
    static let surface = color(dark: 0x14111C, light: 0xFFFFFF)
    static let panel = color(dark: 0x1A1724, light: 0xFFFFFF)
    static let hover = color(dark: 0x221E2E, light: 0xEFEDF6)
    static let border = color(dark: 0x2E2940, light: 0xE4E1EE)
    static let borderStrong = color(dark: 0x423B58, light: 0xC9C3DA)
    static let heading = color(dark: 0xEDEAF5, light: 0x14111C)
    static let text = color(dark: 0xBDB6D2, light: 0x2A2638)
    static let muted = color(dark: 0x9890B0, light: 0x645E78)
    static let disabled = color(dark: 0x6B6385, light: 0x8A82A3)
    static let primary = color(dark: 0x6D4AFF, light: 0x5B3BE0)
    static let primaryHover = color(dark: 0x5B3BE0, light: 0x4A2FC4)
    static let onPrimary = Color.white
    /// Violet as text: links, focus rings, the selected tab.
    static let accent = color(dark: 0xA78BFA, light: 0x5B3BE0)
    static let success = color(dark: 0x4CC38A, light: 0x1F7A4D)
    static let warning = color(dark: 0xE5A50A, light: 0x8A5A00)
    static let danger = color(dark: 0xF2646F, light: 0xC0283A)

    /// The mark: a violet planet, its cut-outs in the tile's color.
    static let planet = Color(nsColor: NSColor(hex: 0x8E6BFF))
    /// The app icon's tile and edge (the icon is the same in light and dark).
    static let iconTile = Color(nsColor: NSColor(hex: 0x1A1724))
    static let iconEdge = Color(nsColor: NSColor(hex: 0x423B58))

    enum Radius {
        static let badge: CGFloat = 4
        static let control: CGFloat = 6
        static let panel: CGFloat = 8
    }

    /// The icon color for a notice's tone. Status colors only ever mean status.
    static func color(_ tone: Tone) -> Color {
        switch tone {
        case .accent: return accent
        case .success: return success
        case .warning: return warning
        case .danger: return danger
        case .muted: return muted
        }
    }

    // MARK: Type

    /// Hack Nerd Font Mono, the brand's one typeface: hierarchy comes from size, weight and color.
    /// Where it isn't installed, the system's monospaced font stands in.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let bold = [.semibold, .bold, .heavy, .black].contains(weight)
        if let name = bold ? hackBold : hackRegular { return .custom(name, size: size) }
        return .system(size: size, weight: bold ? .bold : .regular, design: .monospaced)
    }

    private static let hackRegular = installed("HackNerdFontMono-Regular")
    private static let hackBold = installed("HackNerdFontMono-Bold")

    private static func installed(_ postScriptName: String) -> String? {
        NSFont(name: postScriptName, size: 12) != nil ? postScriptName : nil
    }

    // MARK: Colors

    /// The Settings window's own background (AppKit draws it, under the title bar too).
    static let windowBackground = dynamic(dark: 0x0D0B12, light: 0xF7F6FB)

    private static func color(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: dynamic(dark: dark, light: light))
    }

    private static func dynamic(dark: UInt32, light: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
