#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `live-test/ui-demo.sh snap` has the app draw its windows to PNGs, so the views
/// can be looked at while the display sleeps or the screen is locked, when screen capture sees
/// nothing and accessibility can't reach the windows (so a Settings tab can't be picked either).
/// The app draws them itself: no screen recording, and nothing else on screen.
@MainActor
enum Snapshots {
    private static var sources: [DispatchSourceSignal] = []
    private static var shown: NSWindow?

    /// With `CONTEXT_GUARD_SNAPSHOTS` set to a folder, SIGUSR1 writes the PNGs there and SIGUSR2
    /// shows a Settings window for `live-test/ui-demo.sh capture`.
    static func start(model: AppModel) {
        guard let path = ProcessInfo.processInfo.environment["CONTEXT_GUARD_SNAPSHOTS"], !path.isEmpty else { return }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        for (sig, act) in [(SIGUSR1, { write(model: model, to: dir) }), (SIGUSR2, { show(model: model, in: dir) })] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { MainActor.assumeIsolated { act() } }
            s.resume()
            sources.append(s)
        }
    }

    /// The Settings window on the tab named in `show`, as the README shows it, for a screen capture
    /// (`screencapture -l`, which gives the corners and nothing else; drawing the view can't). It
    /// goes behind every other window and is never key, so nothing you type reaches it. Its window
    /// number goes to `shown`. With no `show` file, it closes.
    static func show(model: AppModel, in dir: URL) {
        shown?.orderOut(nil)
        shown = nil
        let marker = dir.appendingPathComponent("shown")
        try? FileManager.default.removeItem(at: marker)
        let name = (try? String(contentsOf: dir.appendingPathComponent("show"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tab = name.flatMap(SettingsTab.init(rawValue:)) else { return }
        let w = SettingsWindow.makeWindow()
        SettingsWindow.fill(w, model: model, tab: tab)
        w.center()
        w.orderBack(nil)
        shown = w
        try? "\(w.windowNumber)\n".write(to: marker, atomically: true, encoding: .utf8)
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
