import ContextGuardCore
#if os(Windows)
import WinSDK
#endif
import Foundation

/// How a running `context-guard codex` is told to stop on Windows, where there are no signals:
/// Ctrl+C or Ctrl+Break in its console, its console closing, signing out or shutting down, or a
/// named event for its Context Guard folder (the background link has no console). The Mac's link
/// stops on SIGTERM and SIGINT instead.
public enum CodexLinkStop {
    /// One name per Context Guard folder, in the signed-in user's session.
    public static func eventName(for root: URL) -> String {
        let digest = Digest.hex(Digest.sha256(Data(PathRules.key(root.path).utf8)))
        return "Local\\ContextGuard.CodexLink.Stop." + digest.prefix(16)
    }

    #if os(Windows)
    /// Asks the link for `root` to stop. false when none is running.
    @discardableResult
    public static func request(for root: URL) -> Bool {
        let event = eventName(for: root).withCString(encodedAs: UTF16.self) { OpenEventW(DWORD(EVENT_MODIFY_STATE), false, $0) }
        guard let event else { return false }
        defer { CloseHandle(event) }
        return SetEvent(event)
    }

    /// Listens until the process ends. `stop` runs once, on another thread. Call `stopped()` once the
    /// link has stopped: when the console is closing (or you're signing out), Windows ends the
    /// process as soon as the handler returns, so the handler waits for that (at most 4 seconds).
    public final class Listener: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        private let stop: @Sendable () -> Void
        private let done = DispatchSemaphore(value: 0)

        public init?(root: URL, _ stop: @escaping @Sendable () -> Void) {
            self.stop = stop
            let event = Self.eventName(root).withCString(encodedAs: UTF16.self) { CreateEventW(nil, true, false, $0) }
            guard let event else { return nil }
            // An event left set by a request that came after the last link had already gone.
            ResetEvent(event)
            let box = EventBox(event)
            Thread.detachNewThread { [self] in
                WaitForSingleObject(box.event, INFINITE)
                fire()
            }
            Listener.current = self
            SetConsoleCtrlHandler(consoleEvent, true)
        }

        private static func eventName(_ root: URL) -> String { CodexLinkStop.eventName(for: root) }

        public func stopped() { done.signal() }

        fileprivate func fire() {
            lock.lock()
            let first = !fired
            fired = true
            lock.unlock()
            if first { stop() }
        }

        fileprivate func waitUntilStopped() { _ = done.wait(timeout: .now() + 4) }

        nonisolated(unsafe) fileprivate static var current: Listener?
    }
    #endif
}

#if os(Windows)
private final class EventBox: @unchecked Sendable {
    let event: HANDLE
    init(_ event: HANDLE) { self.event = event }
}

/// Runs on a thread Windows starts for it.
private func consoleEvent(_ type: DWORD) -> WindowsBool {
    guard let listener = CodexLinkStop.Listener.current else { return false }
    listener.fire()
    switch Int32(type) {
    case CTRL_CLOSE_EVENT, CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT:
        listener.waitUntilStopped()
    default:
        break
    }
    return true
}
#endif
