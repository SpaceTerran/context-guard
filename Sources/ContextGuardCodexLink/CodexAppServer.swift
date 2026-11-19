import ContextGuardCore
#if canImport(Darwin)
import Darwin
#endif
import Foundation

/// A program this one started.
protocol ChildRunning: AnyObject {
    var isRunning: Bool { get }
    func terminate()
}

extension Process: ChildRunning {}

/// JSON-RPC over a child process's standard input and output, one message per line: how
/// `codex app-server` talks when it's run directly.
public final class StdioChannel: RPCChannel, @unchecked Sendable {
    /// Larger than any reply the link reads (the model list is the largest).
    public static let maxLine = 32 << 20

    private let process: ChildRunning
    private let input: FileHandle
    private let output: FileHandle
    private let writeLock = NSLock()
    private let endLock = NSLock()
    private var ended = false
    // Reader only.
    private var buffer = Data()

    init(process: ChildRunning, input: FileHandle, output: FileHandle) {
        self.process = process
        self.input = input
        self.output = output
    }

    /// Starts `executable` with `arguments`, its standard error discarded.
    public static func start(executable: String, arguments: [String], environment: [String: String],
                             directory: URL) throws -> StdioChannel {
        #if os(Windows)
        // Without a console window of its own (Foundation's `Process` would give it one).
        let child = try WindowsChild.start(executable: PathRules.native(executable), arguments: arguments,
                                           environment: environment, directory: PathRules.native(directory.path))
        return StdioChannel(process: child, input: child.input, output: child.output)
        #else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        let toChild = Pipe(), fromChild = Pipe()
        process.standardInput = toChild
        process.standardOutput = fromChild
        process.standardError = FileHandle.nullDevice
        #if canImport(Darwin)
        // A child that has gone makes a write fail rather than end the link (SIGPIPE).
        _ = fcntl(toChild.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        #endif
        do {
            try process.run()
        } catch {
            throw CodexLinkError.unavailable("couldn't start \(executable): \(error.localizedDescription)")
        }
        // The child's ends belong to it now.
        try? toChild.fileHandleForReading.close()
        try? fromChild.fileHandleForWriting.close()
        return StdioChannel(process: process, input: toChild.fileHandleForWriting, output: fromChild.fileHandleForReading)
        #endif
    }

    public func receive() throws -> String? {
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                if line.isEmpty { continue }
                return String(decoding: line, as: UTF8.self)
            }
            let chunk = output.availableData
            // The child ended: a line it didn't finish is dropped.
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
            guard buffer.count <= Self.maxLine else { throw CodexLinkError.tooLarge }
        }
    }

    public func send(text: String) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        // Its input is closed once it has ended (`end` closes it under this lock).
        guard !hasEnded else { throw CodexLinkError.closed("the app server has stopped") }
        do {
            try input.write(contentsOf: Data((text + "\n").utf8))
        } catch {
            throw CodexLinkError.closed("the app server has stopped")
        }
    }

    private var hasEnded: Bool {
        endLock.lock()
        defer { endLock.unlock() }
        return ended
    }

    /// Closes its input, which ends the app server; one still running a moment later is stopped.
    public func end() {
        endLock.lock()
        let first = !ended
        ended = true
        endLock.unlock()
        guard first else { return }
        writeLock.lock()
        try? input.close()
        writeLock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [self] in
            if process.isRunning { process.terminate() }
        }
    }

    public func release() {
        end()
        try? output.close()
    }
}

/// Starts app servers of the Codex app's own: its judge and its settings for Context Guard, for
/// someone who may have the app and no Codex CLI.
public protocol CodexAppServerLaunching: Sendable {
    /// A new app server on the app's sign-in. `hostExecutable` is the program running the app's
    /// router (`CodexAppRouter`). Throws `.unavailable` when there's no Codex to run.
    func launch(hostExecutable: String?, onEvent: @escaping @Sendable (CodexEvent) -> Void) throws -> CodexDaemon
}

/// `codex app-server` from the Codex app's bundle, run in Context Guard's empty judge folder, on
/// the same Codex folder as the app (its `auth.json` is the app's sign-in).
public struct CodexAppServerLauncher: CodexAppServerLaunching {
    public let codexHome: String
    public let folder: URL

    public init(codexHome: String, folder: URL) {
        self.codexHome = codexHome
        self.folder = folder
    }

    public func launch(hostExecutable: String?, onEvent: @escaping @Sendable (CodexEvent) -> Void) throws -> CodexDaemon {
        guard let binary = CodexAppBundle.codexBinary(hostExecutable: hostExecutable) else {
            throw CodexLinkError.unavailable("the Codex app's own codex wasn't found")
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = codexHome
        let channel = try StdioChannel.start(executable: binary, arguments: ["app-server"], environment: env, directory: folder)
        let rpc = RPCConnection(channel: channel, onEvent: onEvent)
        rpc.start()
        return rpc
    }
}

/// Where the Codex app keeps the Codex CLI it runs.
public enum CodexAppBundle {
    #if os(Windows)
    /// The Codex app's Store package family.
    public static let packageFamily = "OpenAI.Codex_2p2nqsd0c76g0"

    /// Next to the app's program (`<package>\app\resources\codex.exe`) when the app runs the
    /// router, else in the Codex app the Store installed for you.
    /// `installedApp` stands in for the Store's answer in tests.
    public static func codexBinary(hostExecutable: String?, installedApp: (() -> String?)? = nil,
                                   isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> String? {
        if let host = hostExecutable.map({ PathRules.native($0) }), let cut = host.lastIndex(of: "\\") {
            let path = String(host[..<cut]) + "\\resources\\codex.exe"
            if isExecutable(path) { return path }
        }
        // A stand-in that answers nil means no app, not "ask the Store".
        let installed: String?
        if let installedApp {
            installed = installedApp()
        } else {
            installed = WindowsProcess.packageFolder(family: packageFamily)
        }
        guard let folder = installed.map({ PathRules.native($0) }) else { return nil }
        let path = folder + "\\app\\resources\\codex.exe"
        return isExecutable(path) ? path : nil
    }
    #else
    /// Inside the app: `ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`.
    public static let inBundle = "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
    /// Where the app is when the router's program doesn't say (another client of yours runs it).
    public static let usualPlaces = ["/Applications/ChatGPT.app", "~/Applications/ChatGPT.app"]

    /// The app running the router first (`…/ChatGPT.app/Contents/MacOS/ChatGPT`), then the app
    /// where it's usually installed.
    public static func codexBinary(hostExecutable: String?,
                                   isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> String? {
        var bundles: [String] = []
        if let host = hostExecutable {
            let macOS = (host as NSString).deletingLastPathComponent
            let contents = (macOS as NSString).deletingLastPathComponent
            let bundle = (contents as NSString).deletingLastPathComponent
            if (macOS as NSString).lastPathComponent == "MacOS", (contents as NSString).lastPathComponent == "Contents",
               bundle.hasSuffix(".app") {
                bundles.append(bundle)
            }
        }
        bundles += usualPlaces.map { ($0 as NSString).expandingTildeInPath }
        return bundles.map { ($0 as NSString).appendingPathComponent(inBundle) }.first(where: isExecutable)
    }
    #endif

    /// A Store package folder's version: `…\OpenAI.Codex_26.1111.2228.0_x64__2p2nqsd0c76g0` →
    /// [26, 1111, 2228, 0]. Empty when the name has none.
    public static func packageVersion(_ folder: String) -> [Int] {
        let name = folder.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? folder
        let parts = name.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return [] }
        let numbers = parts[1].split(separator: ".").map { Int($0) }
        return numbers.contains(nil) ? [] : numbers.compactMap { $0 }
    }

    /// The newest of a package's folders, by `packageVersion`.
    public static func newest(_ folders: [String]) -> String? {
        folders.max { packageVersion($0).lexicographicallyPrecedes(packageVersion($1)) }
    }
}
