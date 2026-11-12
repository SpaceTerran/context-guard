import Foundation
import XCTest

/// The brand's colors, radii and font for the Windows app, taken from the Mac's `Theme.swift`, which
/// stays the one place they're set. Three files are written from it and checked byte for byte:
/// - `design/tokens.json`: every color by role (dark and light), the radii and the font;
/// - `windows/ContextGuard.App/Brand.xaml`: the same as XAML theme resources (`Brand<Role>Brush`), with
///   high contrast mapped to the system's colors;
/// - `windows/ContextGuard.App/BrandColors.g.cs`: the colors for the few places code needs one.
///
/// After a change to `Theme.swift`, `CONTEXT_GUARD_UPDATE_CONTRACT=1 swift test --filter BrandTokensTests`
/// rewrites them; read the diff before committing it.
final class BrandTokensTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let updating = ProcessInfo.processInfo.environment["CONTEXT_GUARD_UPDATE_CONTRACT"] == "1"

    /// The brand's typeface on Windows, then what stands in where it isn't installed.
    static let fonts = ["Hack Nerd Font Mono", "Cascadia Mono", "Consolas"]

    /// What each role becomes in high contrast: the system's own colors, so the user's theme wins.
    static let highContrast = [
        "bg": "SystemColorWindowColor", "surface": "SystemColorWindowColor", "panel": "SystemColorWindowColor",
        "hover": "SystemColorHighlightColor", "border": "SystemColorWindowTextColor",
        "borderStrong": "SystemColorWindowTextColor", "heading": "SystemColorWindowTextColor",
        "text": "SystemColorWindowTextColor", "muted": "SystemColorWindowTextColor",
        "disabled": "SystemColorGrayTextColor", "primary": "SystemColorHighlightColor",
        "primaryHover": "SystemColorHighlightColor", "onPrimary": "SystemColorHighlightTextColor",
        "accent": "SystemColorHotlightColor", "success": "SystemColorWindowTextColor",
        "warning": "SystemColorWindowTextColor", "danger": "SystemColorWindowTextColor",
        "planet": "SystemColorWindowTextColor", "iconTile": "SystemColorWindowColor",
        "iconEdge": "SystemColorWindowTextColor",
    ]

    struct Token: Equatable {
        let role: String
        let dark: String
        let light: String
    }

    struct Brand {
        var colors: [Token] = []
        var radii: [(name: String, value: Int)] = []
    }

    /// Reads the roles out of the Mac's `Theme.swift`.
    static func brand() throws -> Brand {
        let source = try String(contentsOf: root.appendingPathComponent("Sources/ContextGuardApp/Theme.swift"), encoding: .utf8)
        var brand = Brand()
        // `isNewline`, not "\n": in a CRLF checkout (Windows) "\r\n" is one Character.
        for line in source.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if let m = line.firstMatch(of: /^static let (\w+) = color\(dark: 0x([0-9A-F]{6}), light: 0x([0-9A-F]{6})\)$/) {
                brand.colors.append(Token(role: String(m.1), dark: String(m.2), light: String(m.3)))
            } else if let m = line.firstMatch(of: /^static let (\w+) = Color\(nsColor: NSColor\(hex: 0x([0-9A-F]{6})\)\)$/) {
                brand.colors.append(Token(role: String(m.1), dark: String(m.2), light: String(m.2)))
            } else if let m = line.firstMatch(of: /^static let (\w+) = Color\.white$/) {
                brand.colors.append(Token(role: String(m.1), dark: "FFFFFF", light: "FFFFFF"))
            } else if let m = line.firstMatch(of: /^static let (\w+): CGFloat = (\d+)$/) {
                brand.radii.append((String(m.1), Int(m.2)!))
            }
        }
        return brand
    }

    func testTheMacThemeHasEveryRole() throws {
        let brand = try Self.brand()
        XCTAssertEqual(brand.colors.map(\.role), [
            "bg", "surface", "panel", "hover", "border", "borderStrong", "heading", "text", "muted", "disabled",
            "primary", "primaryHover", "onPrimary", "accent", "success", "warning", "danger", "planet", "iconTile",
            "iconEdge",
        ], "a role was added to or dropped from Theme.swift: update BrandTokensTests.highContrast, then the files")
        XCTAssertEqual(brand.radii.map(\.name), ["badge", "control", "panel"])
        XCTAssertEqual(Set(Self.highContrast.keys), Set(brand.colors.map(\.role)))
        let source = try String(contentsOf: Self.root.appendingPathComponent("Sources/ContextGuardApp/Theme.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("HackNerdFontMono-Regular"), "the Mac's typeface changed: change Self.fonts too")
    }

    func testTokensJSON() throws {
        let brand = try Self.brand()
        var lines = ["{", "  \"colors\": {"]
        for (i, t) in brand.colors.enumerated() {
            let comma = i == brand.colors.count - 1 ? "" : ","
            lines.append("    \"\(t.role)\": { \"dark\": \"#\(t.dark)\", \"light\": \"#\(t.light)\" }\(comma)")
        }
        lines.append("  },")
        lines.append("  \"radius\": { " + brand.radii.map { "\"\($0.name)\": \($0.value)" }.joined(separator: ", ") + " },")
        lines.append("  \"font\": [" + Self.fonts.map { "\"\($0)\"" }.joined(separator: ", ") + "]")
        lines.append("}")
        try check("design/tokens.json", lines.joined(separator: "\n") + "\n")
    }

    func testBrandXAML() throws {
        let brand = try Self.brand()
        var lines = [
            "<!-- Written by BrandTokensTests from the Mac's Theme.swift (as design/tokens.json): don't edit. -->",
            "<ResourceDictionary",
            "    xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\"",
            "    xmlns:x=\"http://schemas.microsoft.com/winfx/2006/xaml\">",
            "    <ResourceDictionary.ThemeDictionaries>",
        ]
        for theme in ["Dark", "Light"] {
            lines.append("        <ResourceDictionary x:Key=\"\(theme)\">")
            for t in brand.colors {
                let hex = theme == "Dark" ? t.dark : t.light
                lines.append("            <SolidColorBrush x:Key=\"Brand\(Self.pascal(t.role))Brush\" Color=\"#FF\(hex)\" />")
            }
            lines.append("        </ResourceDictionary>")
        }
        lines.append("        <ResourceDictionary x:Key=\"HighContrast\">")
        for t in brand.colors {
            lines.append("            <SolidColorBrush x:Key=\"Brand\(Self.pascal(t.role))Brush\" Color=\"{ThemeResource \(Self.highContrast[t.role]!)}\" />")
        }
        lines.append("        </ResourceDictionary>")
        lines.append("    </ResourceDictionary.ThemeDictionaries>")
        lines.append("    <FontFamily x:Key=\"BrandFont\">\(Self.fonts.joined(separator: ", "))</FontFamily>")
        for r in brand.radii {
            lines.append("    <CornerRadius x:Key=\"Brand\(Self.pascal(r.name))Radius\">\(r.value)</CornerRadius>")
        }
        lines.append("</ResourceDictionary>")
        try check("windows/ContextGuard.App/Brand.xaml", lines.joined(separator: "\n") + "\n")
    }

    func testBrandColorsCS() throws {
        let brand = try Self.brand()
        var lines = [
            "// Written by BrandTokensTests from the Mac's Theme.swift (as design/tokens.json): don't edit.",
            "namespace ContextGuard.App;",
            "",
            "/// <summary>The brand's colors as 0xRRGGBB, dark and light, for code (views use Brand.xaml).</summary>",
            "static class BrandColors",
            "{",
        ]
        for t in brand.colors {
            lines.append("    public static readonly (uint Dark, uint Light) \(Self.pascal(t.role)) = (0x\(t.dark), 0x\(t.light));")
        }
        lines.append("}")
        try check("windows/ContextGuard.App/BrandColors.g.cs", lines.joined(separator: "\n") + "\n")
    }

    static func pascal(_ name: String) -> String { name.prefix(1).uppercased() + name.dropFirst() }

    func check(_ path: String, _ text: String, line: UInt = #line) throws {
        let url = Self.root.appendingPathComponent(path)
        if Self.updating {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            return
        }
        guard let expected = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("\(path) is missing: run with CONTEXT_GUARD_UPDATE_CONTRACT=1", line: line)
            return
        }
        XCTAssertEqual(text, expected.replacingOccurrences(of: "\r\n", with: "\n"),
                       "\(path) differs from Theme.swift: run with CONTEXT_GUARD_UPDATE_CONTRACT=1 and read the diff", line: line)
    }
}
