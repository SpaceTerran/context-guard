import AppKit
import ContextGuardCore
import SwiftUI

/// The mark of the tool a session runs in (`ToolLogo`): before its title in the menu, its question
/// and its notices, so sessions from different tools are told apart at a glance.
enum ToolMark {
    /// The mark's outline on its 24-point square, y down.
    static func path(_ host: SessionHost) -> CGPath {
        let p = CGMutablePath()
        for step in ToolLogo.steps(ToolLogo.path(host)) {
            switch step {
            case .move(let x, let y): p.move(to: CGPoint(x: x, y: y))
            case .line(let x, let y): p.addLine(to: CGPoint(x: x, y: y))
            case .curve(let x1, let y1, let x2, let y2, let x, let y):
                p.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
            case .close: p.closeSubpath()
            }
        }
        return p
    }

    @MainActor private static var menuIcons: [String: NSImage] = [:]

    /// A session's icon in the menu: its tool's mark, then its symbol, as one template image (a menu
    /// item has one), so the menu tints both as it does the title. The symbol keeps a slot of one
    /// width, so every title starts at the same place.
    @MainActor
    static func menuIcon(_ host: SessionHost, symbol: Symbol) -> NSImage {
        let key = "\(host.rawValue):\(symbol.rawValue)"
        if let cached = menuIcons[key] { return cached }
        let side: CGFloat = 13, gap: CGFloat = 5, slot: CGFloat = 16, height: CGFloat = 16
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let glyph = NSImage(systemSymbolName: symbol.systemName, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        let mark = path(host)
        let image = NSImage(size: NSSize(width: side + gap + slot, height: height), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            // The path is y down: flip it onto the image, centred top to bottom.
            ctx.translateBy(x: 0, y: (height + side) / 2)
            ctx.scaleBy(x: side / ToolLogo.size, y: -side / ToolLogo.size)
            ctx.addPath(mark)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            if let glyph {
                let size = glyph.size
                glyph.draw(in: NSRect(x: side + gap + (slot - size.width) / 2, y: (height - size.height) / 2,
                                      width: size.width, height: size.height))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "\(host.name), \(symbol.rawValue)"
        menuIcons[key] = image
        return image
    }
}

/// The mark, filling the middle of the square it's given, in the foreground style.
struct ToolMarkShape: Shape {
    let host: SessionHost

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / ToolLogo.size
        let half = ToolLogo.size / 2 * s
        let t = CGAffineTransform(translationX: rect.midX - half, y: rect.midY - half).scaledBy(x: s, y: s)
        return Path(ToolMark.path(host)).applying(t)
    }
}

/// The mark before a line of text: as tall as a capital letter of 13-point text, sitting a point below
/// its baseline (put it in an `HStack(alignment: .firstTextBaseline)`). VoiceOver reads the tool's name.
struct ToolMarkView: View {
    let host: SessionHost
    var side: CGFloat = 11

    var body: some View {
        ToolMarkShape(host: host)
            .frame(width: side, height: side)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            .accessibilityElement()
            .accessibilityLabel(host.name)
            .accessibilityAddTraits(.isImage)
    }
}
