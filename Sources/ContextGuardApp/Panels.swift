import AppKit
import ContextGuardCore
import SwiftUI

/// Floating popups and notices, stacked under the menu bar at the top right like notifications.
/// The shared `Presenter` says what opens and closes.
@MainActor
final class PanelController: @MainActor PanelHost {
    /// The view of a session's question popup.
    var question: (String) -> AnyView = { _ in AnyView(EmptyView()) }
    /// Runs the presenter's sync again.
    var onRecheck: () -> Void = {}
    private var stack: [(key: String, panel: FloatingPanel)] = []
    private var noticeTimers: [String: Timer] = [:]
    private var resizeObservers: [String: NSObjectProtocol] = [:]
    /// Wide enough for a countdown line in the brand's monospaced type.
    static let width: CGFloat = 400
    static let margin: CGFloat = 12
    static let spacing: CGFloat = 10
    /// More than this many at once would run off a laptop screen; the rest wait their turn.
    static let maxOpen = 5

    var openKeys: [String] { stack.map(\.key) }

    var hasRoom: Bool { stack.count < Self.maxOpen }

    /// Opens with a sound, unless five are already up.
    func openQuestion(_ id: String) -> Bool {
        guard hasRoom else { return false }
        open(Presenter.questionKey(id), question(id))
        NSSound(named: "Glass")?.play()
        return true
    }

    /// A notice closes by itself after a few seconds (or with its ✕).
    func showNotice(_ notice: NoticeContent, key: String) {
        open(key, AnyView(NoticeView(notice: notice) { [weak self] in self?.close(key) }))
        noticeTimers[key] = Timer.scheduledTimer(withTimeInterval: notice.seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(key) }
        }
    }

    func recheck(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated { self?.onRecheck() }
        }
    }

    private func open(_ key: String, _ view: AnyView) {
        let panel = FloatingPanel(rootView: view, width: Self.width)
        stack.append((key, panel))
        // SwiftUI resizes the window itself when its content changes (question → "Sending…"), so
        // restack on every resize rather than only after our own fitting.
        resizeObservers[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        layout(appearing: panel)
        panel.orderFrontRegardless()
    }

    func close(_ key: String) {
        guard let i = stack.firstIndex(where: { $0.key == key }) else { return }
        let panel = stack.remove(at: i).panel
        noticeTimers.removeValue(forKey: key)?.invalidate()
        if let observer = resizeObservers.removeValue(forKey: key) { NotificationCenter.default.removeObserver(observer) }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
        layout()
    }

    /// Content can change height (question → progress); keep each panel fitted.
    func fitSizes() {
        var changed = false
        for (_, panel) in stack where panel.fitContent() { changed = true }
        if changed { layout() }
    }

    func layout(appearing: FloatingPanel? = nil) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let area = screen.visibleFrame
        var top = area.maxY - Self.margin
        for (_, panel) in stack {
            let size = panel.frame.size
            let origin = NSPoint(x: area.maxX - size.width - Self.margin, y: top - size.height)
            let target = NSRect(origin: origin, size: size)
            if panel === appearing {
                // Slide in from the right edge, like a notification.
                panel.setFrame(target.offsetBy(dx: 40, dy: 0), display: false)
                panel.alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(target, display: true)
                    panel.animator().alphaValue = 1
                }
            } else if panel.frame != target {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    panel.animator().setFrame(target, display: true)
                }
            }
            top = origin.y - Self.spacing
        }
    }
}

/// A panel that floats over every app and Space without taking focus from the terminal. Clicking a
/// button works right away; Return only answers once you've clicked into the panel.
final class FloatingPanel: NSPanel {
    private let host: NSHostingView<AnyView>
    private let width: CGFloat

    init(rootView: AnyView, width: CGFloat) {
        self.width = width
        host = NSHostingView(rootView: rootView)
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // The SwiftUI card draws the flat panel and its edge; the window adds the shadow, which
        // follows the card's rounded corners because everything around them is clear.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        contentView = host
        _ = fitContent()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Resize to the SwiftUI content's height, keeping the top edge in place. True if it changed.
    func fitContent() -> Bool {
        let height = ceil(host.fittingSize.height)
        guard height > 0, abs(frame.height - height) > 0.5 else { return false }
        var f = frame
        f.origin.y += f.height - height
        f.size = NSSize(width: width, height: height)
        setFrame(f, display: true)
        invalidateShadow()
        return true
    }
}
