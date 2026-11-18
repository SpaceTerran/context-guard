import Foundation

/// Each session's work in order, on a queue of its own: a look that arrives while one is being
/// handled waits, and only the newest one waiting is kept.
final class SessionWorkers<Look: Sendable>: @unchecked Sendable {
    private final class Worker: @unchecked Sendable {
        let queue: DispatchQueue
        var busy = false
        var pending: Look?

        init(_ label: String) {
            queue = DispatchQueue(label: label)
        }
    }

    private let label: String
    /// Work runs on the calling thread (tests).
    private let inline: Bool
    private let lock = NSLock()
    private var workers: [String: Worker] = [:]

    init(label: String, inline: Bool) {
        self.label = label
        self.inline = inline
    }

    /// Hands `look` to session `id`'s worker. `step` handles one look; `waited` says it has waited
    /// (or is being handled again), so it may be out of date. It returns whether to handle the
    /// same look again right away.
    func schedule(_ id: String, _ look: Look, _ step: @escaping @Sendable (_ look: Look, _ waited: Bool) -> Bool) {
        lock.lock()
        let w = workers[id] ?? Worker("\(label).\(id)")
        workers[id] = w
        if w.busy {
            w.pending = look
            lock.unlock()
            return
        }
        w.busy = true
        lock.unlock()
        if inline {
            run(w, look, step)
        } else {
            w.queue.async { [self] in run(w, look, step) }
        }
    }

    private func run(_ w: Worker, _ first: Look, _ step: @Sendable (Look, Bool) -> Bool) {
        var next: Look? = first
        var waited = false
        while true {
            if let look = next {
                let again = step(look, waited)
                next = again ? look : nil
                waited = again
                if again { continue }
            }
            lock.lock()
            if let p = w.pending {
                w.pending = nil
                lock.unlock()
                next = p
                waited = true
                continue
            }
            w.busy = false
            lock.unlock()
            return
        }
    }
}

/// Which Codex chats each of the link's two connections drives now, so no chat is driven by both:
/// the Codex app server's (a terminal's sessions) and the Codex app's router (the app's chats). A
/// chat open in a terminal is the terminal's, even while the app has it open too.
public final class CodexDrivers: @unchecked Sendable {
    private let lock = NSLock()
    private var terminal: Set<String> = []
    private var app: Set<String> = []

    public init() {}

    /// Loaded in the app server with a terminal showing them.
    public func setTerminal(_ ids: Set<String>) {
        lock.lock()
        terminal = ids
        lock.unlock()
    }

    /// Open in the Codex app, as far as its router says.
    public func setApp(_ ids: Set<String>) {
        lock.lock()
        app = ids
        lock.unlock()
    }

    public func terminalHas(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminal.contains(id)
    }

    public func appHas(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return app.contains(id)
    }
}
