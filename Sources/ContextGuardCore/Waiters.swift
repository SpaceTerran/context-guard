import Foundation

/// The Stop hooks waiting in the background (`HookRunner.runWaiter`), at most one per session.
public enum Waiters {
    public struct Running: Equatable, Sendable {
        public var sessionId: String
        public var pid: Int32
        public var start: ProcessStart?
    }

    /// Tells every waiting Stop hook to go. Each one finds its token gone the next time it looks
    /// (every couple of seconds) and exits 0, sending nothing. The installers run this
    /// (`context-guard hook --stop`) before removing Context Guard, so no waiter is left to send a
    /// save message once it's gone, or to hold the program open (Windows can't delete a running
    /// program). Returns the ones that were running.
    public static func release(_ paths: Paths, probe: any ProcessProbing = SystemProcessProbe(), lockTimeout: TimeInterval = 2) -> [Running] {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.sessionsDir, includingPropertiesForKeys: nil)) ?? []
        var running: [Running] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
            let id = file.deletingPathExtension().lastPathComponent
            guard let snap = SessionState.load(id, paths), snap.waiterToken != nil else { continue }
            var s = snap
            if let lock = FileLock.acquire(paths.lockFile(id), timeout: lockTimeout) {
                defer { lock.release() }
                guard let locked = SessionState.load(id, paths), locked.waiterToken != nil else { continue }
                s = locked
                s.waiterToken = nil
                try? s.save(paths)
            }
            // Released or not (the lock stayed busy), a waiter that's still running is reported, so
            // the caller can wait for it and say so if it doesn't go.
            if let pid = s.waiterPid, probe.isRunning(pid, startedAt: s.waiterStart) {
                running.append(Running(sessionId: id, pid: pid, start: s.waiterStart))
            }
        }
        return running
    }

    /// Waits up to `timeout` for `waiters` to exit. Returns the ones still running.
    public static func wait(for waiters: [Running], timeout: TimeInterval, poll: TimeInterval = 0.1,
                            probe: any ProcessProbing = SystemProcessProbe()) -> [Running] {
        let deadline = Date().addingTimeInterval(timeout)
        var left = waiters
        while true {
            left = left.filter { probe.isRunning($0.pid, startedAt: $0.start) }
            if left.isEmpty || Date() >= deadline { return left }
            Thread.sleep(forTimeInterval: poll)
        }
    }
}
