#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `live-test/ui-demo.sh snap` has the app draw its windows to PNGs, so the views
/// can be looked at while the display sleeps or the screen is locked, when screen capture sees
/// nothing and accessibility can't reach the windows (so a Settings tab can't be picked either).
/// The app draws them itself: no screen recording, and nothing else on screen.
@MainActor
enum Snapshots {
    private static var source: DispatchSourceSignal?

    /// With `CONTEXT_GUARD_SNAPSHOTS` set to a folder, SIGUSR1 writes the PNGs there.
    static func start(model: AppModel) {
        guard let dir = ProcessInfo.processInfo.environment["CONTEXT_GUARD_SNAPSHOTS"], !dir.isEmpty else { return }
        signal(SIGUSR1, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        s.setEventHandler { MainActor.assumeIsolated { write(model: model, to: URL(fileURLWithPath: dir, isDirectory: true)) } }
        s.resume()
        source = s
    }

    /// `window-<number>.png` for each visible window, the frame (title bar and all) included;
    /// `settings-<tab>.png` for each Settings tab, drawn off screen; and `index.txt`: file, kind,
    /// title, frame. The index is written last, so its presence means the PNGs are done.
    static func write(model: AppModel, to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var index: [String] = []
        let windows = NSApp.windows.filter(\.isVisible).sorted { $0.frame.maxY > $1.frame.maxY }
        for w in windows {
            guard let view = w.contentView?.superview ?? w.contentView else { continue }
            let name = "window-\(w.windowNumber).png"
            guard draw(view, to: dir.appendingPathComponent(name)) else { continue }
            let f = w.frame
            index.append("\(name)\t\(String(describing: type(of: w)))\t\(w.title)\t\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))")
        }
        for tab in SettingsTab.allCases {
            let host = NSHostingView(rootView: SettingsView(model: model, tab: tab))
            host.frame.size = host.fittingSize
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let name = "settings-\(tab.rawValue).png"
            if draw(host, to: dir.appendingPathComponent(name)) {
                index.append("\(name)\tSettingsView\t\(tab.title)\t\(Int(host.frame.width))x\(Int(host.frame.height))")
            }
        }
        try? (index.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("index.txt"), atomically: true, encoding: .utf8)
    }

    private static func draw(_ view: NSView, to url: URL) -> Bool {
        let rect = view.bounds
        guard rect.width > 0, rect.height > 0, let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return false }
        view.cacheDisplay(in: rect, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}
#endif
