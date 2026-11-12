import ContextGuardCore
import Foundation

/// `context-guard ui`: the Windows app runs this and draws what it writes (Core's `Feed`): it reads
/// the app's intents from stdin and writes JSON lines to stdout until the app closes stdin. Like
/// the Mac app, it watches Context Guard's folders (read once a burst of writes settles), looks
/// again every 2 seconds, and wakes when a notice, a popup's progress or a countdown is due.
final class UIFeed: @unchecked Sendable {
    /// Everything but reading stdin runs here, one thing at a time.
    private let queue = DispatchQueue(label: "context-guard.ui")
    private let feed: Feed
    private let paths: Paths
    private var watchers: [FolderWatcher] = []
    private var refreshQueued = false
    private var wake: DispatchWorkItem?
    private let out = FileHandle.standardOutput

    init(paths: Paths, env: [String: String]) {
        self.paths = paths
        feed = Feed(paths: paths, registry: FileRegistry(dir: paths.registryDir),
                    codexLinkInstalled: { CodexLinkInstall.isInstalled(paths, env: env) })
    }

    func run() -> Never {
        queue.async { self.begin() }
        while let line = readLine(strippingNewline: true) {
            let text = line.hasSuffix("\r") ? String(line.dropLast()) : line
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            queue.async {
                self.write(self.feed.handle(text))
                self.schedule()
            }
        }
        // The app closed its end: it's gone. Finish what it asked for, then go.
        queue.sync {}
        exit(0)
    }

    private func begin() {
        try? paths.ensureDirectories()
        let changed: @Sendable () -> Void = { [self] in queue.async { self.queueRefresh() } }
        watchers = [paths.root, paths.sessionsDir, paths.answersDir, paths.registryDir, paths.mutedDir].map { FolderWatcher($0, changed) }
        write(feed.start())
        schedule()
        lookAgain()
    }

    /// Registry status (busy or idle) and process exits don't always touch a watched folder.
    private func lookAgain() {
        queue.asyncAfter(deadline: .now() + 2) {
            self.write(self.feed.refresh())
            self.schedule()
            self.lookAgain()
        }
    }

    /// A hook event rewrites several files in a burst; read them once.
    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        queue.asyncAfter(deadline: .now() + 0.15) {
            self.refreshQueued = false
            self.write(self.feed.refresh())
            self.schedule()
        }
    }

    private func schedule() {
        wake?.cancel()
        wake = nil
        guard let at = feed.nextWake() else { return }
        let item = DispatchWorkItem {
            self.write(self.feed.tick())
            self.schedule()
        }
        wake = item
        queue.asyncAfter(deadline: .now() + max(0, at.timeIntervalSinceNow), execute: item)
    }

    private func write(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        do {
            try out.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
        } catch {
            // Nobody reads it any more.
            exit(0)
        }
    }
}
