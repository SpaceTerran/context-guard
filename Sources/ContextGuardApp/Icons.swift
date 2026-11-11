import AppKit
import ContextGuardCore
import SwiftUI

enum MenuBarIcon {
    /// The gauge; filled while a popup is waiting for an answer, crossed out when off.
    static func image(on: Bool, asking: Bool) -> NSImage {
        let name = on && asking ? "gauge.with.needle.fill" : "gauge.with.needle"
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: "Context Guard")?
            .withSymbolConfiguration(config) else { return NSImage() }
        guard !on else {
            symbol.isTemplate = true
            return symbol
        }
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            // A slash with a cut-out gap around it, like the system's ".slash" symbols.
            let from = CGPoint(x: rect.minX + 2, y: rect.maxY - 1)
            let to = CGPoint(x: rect.maxX - 2, y: rect.minY + 1)
            ctx.setLineCap(.round)
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(3.6)
            ctx.move(to: from)
            ctx.addLine(to: to)
            ctx.strokePath()
            ctx.setBlendMode(.normal)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.4)
            ctx.move(to: from)
            ctx.addLine(to: to)
            ctx.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The app icon in SpaceTerran's app-icon style: the gauge in planet violet on the brand's dark tile with
/// a 1 px edge. Its cut-outs show the tile, like the SpaceTerran mark's. build.sh renders it into the
/// app bundle.
enum AppIcon {
    /// Apple's icon grid: an 824-point rounded square centred on a 1024 canvas, with a soft shadow.
    /// Its 185-point corners are the brand's 22 % tile radius.
    @MainActor
    static func render(pixels: Int) -> NSBitmapImageRep? {
        let tile = RoundedRectangle(cornerRadius: 185, style: .continuous)
        let view = ZStack {
            tile
                .fill(Theme.iconTile)
                .overlay(tile.strokeBorder(Theme.iconEdge, lineWidth: 10))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.28), radius: 14, y: 10)
            Image(systemName: "gauge.with.needle.fill")
                .font(.system(size: 470, weight: .semibold))
                .foregroundStyle(Theme.planet)
                .offset(y: -6)
        }
        .frame(width: 1024, height: 1024)
        let renderer = ImageRenderer(content: view)
        renderer.scale = CGFloat(pixels) / 1024
        guard let cg = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg)
    }

    /// Writes the PNG sizes `iconutil` expects into an `.iconset` folder.
    @MainActor
    static func writeIconset(to dir: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for points in [16, 32, 128, 256, 512] {
                for scale in [1, 2] {
                    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                    guard let rep = render(pixels: points * scale),
                          let png = rep.representation(using: .png, properties: [:]) else { return false }
                    try png.write(to: dir.appendingPathComponent(name))
                }
            }
            return true
        } catch {
            return false
        }
    }
}

extension Symbol {
    /// The SF Symbol the Mac draws for it.
    var systemName: String {
        switch self {
        case .watching: return "circle"
        case .asking: return "questionmark.circle"
        case .waiting: return "clock"
        case .sending: return "paperplane"
        case .sent: return "checkmark.circle"
        case .skipped: return "minus.circle"
        case .notWatching: return "eye.slash"
        case .needsYou: return "questionmark.bubble.fill"
        case .compacting: return "arrow.down.right.and.arrow.up.left.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .saved: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        case .off: return "pause.circle.fill"
        case .saving: return "tray.and.arrow.down.fill"
        }
    }
}
