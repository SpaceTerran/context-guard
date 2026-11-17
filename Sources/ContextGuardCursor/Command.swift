import Foundation

/// Runs another program and waits for it, at most `timeout`.
enum Command {
    struct Output: Equatable {
        var status: Int32
        var stdout: Data
        var stderr = Data()
        var text: String { String(decoding: stdout, as: UTF8.self) }
        var errorText: String { String(decoding: stderr, as: UTF8.self) }
    }

    /// nil when it couldn't start or ran out of time (it's stopped then). `input` is its standard
    /// input (none: empty).
    static func run(_ program: URL, _ args: [String], environment: [String: String]? = nil, directory: URL? = nil,
                    input: Data? = nil, timeout: TimeInterval) -> Output? {
        let p = Process()
        p.executableURL = program
        p.arguments = args
        if let environment { p.environment = environment }
        if let directory { p.currentDirectoryURL = directory }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe = input.map { _ in Pipe() }
        p.standardInput = inPipe ?? FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        // Read and write while it runs, so a full pipe never stalls either side.
        let stdout = Collected(), stderr = Collected()
        let readers = [(out, stdout), (err, stderr)].map { pipe, into in
            Thread {
                into.set(pipe.fileHandleForReading.readDataToEndOfFile())
                into.finished.signal()
            }
        }
        do { try p.run() } catch { return nil }
        readers.forEach { $0.start() }
        if let inPipe, let input {
            // It may quit without reading it all: writing to the closed pipe then fails rather than
            // ending this process.
            signal(SIGPIPE, SIG_IGN)
            Thread {
                try? inPipe.fileHandleForWriting.write(contentsOf: input)
                try? inPipe.fileHandleForWriting.close()
            }.start()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            p.terminate()
            if done.wait(timeout: .now() + 2) != .success { kill(p.processIdentifier, SIGKILL) }
            return nil
        }
        _ = stdout.finished.wait(timeout: .now() + 2)
        _ = stderr.finished.wait(timeout: .now() + 2)
        return Output(status: p.terminationStatus, stdout: stdout.get(), stderr: stderr.get())
    }

    /// The program as found on `PATH`, then in the usual places Homebrew and installers put them.
    static func find(_ name: String, environment env: [String: String], also: [String] = []) -> URL? {
        let home = env["HOME"] ?? NSHomeDirectory()
        let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init) + also
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "\(home)/.local/bin"]
        let fm = FileManager.default
        for dir in dirs where !dir.isEmpty {
            let path = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    private final class Collected: @unchecked Sendable {
        let finished = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var data = Data()
        func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }
}
