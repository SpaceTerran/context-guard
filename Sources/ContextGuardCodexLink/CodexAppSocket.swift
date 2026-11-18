import ContextGuardCore
#if canImport(Darwin)
import Darwin
#endif
import Foundation

/// Codex's folder: `CODEX_HOME`, else `.codex` in your home folder. The Codex app and the Codex
/// CLI both keep their sessions, sign-in and sockets there.
public enum CodexHome {
    public static func path(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        #if os(Windows)
        // Windows separators throughout.
        let home = env["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "\\.codex"
        return PathRules.native(home)
        #else
        if let codexHome = env["CODEX_HOME"], !codexHome.isEmpty {
            return (codexHome as NSString).expandingTildeInPath
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        #endif
    }
}

/// A connection to the Codex app's router, and what's known of the program at the other end.
public struct CodexAppRouter: Sendable {
    public let transport: CodexAppTransport
    /// The program running the router: the Codex app's own, unless another Codex client of yours
    /// (one that started first) runs it. nil when it can't be told.
    public let hostExecutable: String?

    public init(transport: CodexAppTransport, hostExecutable: String?) {
        self.transport = transport
        self.hostExecutable = hostExecutable
    }
}

/// Finds the Codex app's router and connects to it.
public protocol CodexAppConnecting: Sendable {
    /// Throws when no router answers (the app isn't running: the socket it leaves when it quits
    /// refuses connections), or when the one that answers isn't run by you.
    func connect() throws -> CodexAppRouter
}

#if !os(Windows)
/// The Mac's router: a Unix socket in Codex's folder, where the app makes it.
public struct CodexAppSocketConnector: CodexAppConnecting {
    public let codexHome: String
    public let temporaryDirectory: String

    public init(codexHome: String, temporaryDirectory: String = NSTemporaryDirectory()) {
        self.codexHome = codexHome
        self.temporaryDirectory = temporaryDirectory
    }

    /// Where the app listens: `ipc/ipc.sock` in Codex's folder. When that path is longer than a
    /// socket address holds, the app links a short folder to `ipc` instead, named after its real
    /// path: `/tmp/codex-ipc-<uid>/<sha256 of the real path, in hex>/ipc.sock`.
    public static func socketPath(codexHome: String, uid: uid_t = getuid()) -> String {
        let ipc = (codexHome as NSString).appendingPathComponent("ipc")
        let direct = (ipc as NSString).appendingPathComponent("ipc.sock")
        if direct.utf8.count <= SocketStream.maxPathBytes { return direct }
        // Without the folder there's no app to find; the path is the same either way.
        let real = realPath(ipc) ?? ipc
        return "/tmp/codex-ipc-\(uid)/\(Digest.hex(Digest.sha256(Data(real.utf8))))/ipc.sock"
    }

    /// Where earlier app versions listened. The app still connects there when nothing answers at
    /// `socketPath`, so another, older Codex client of yours may run the router there.
    public static func legacySocketPath(temporaryDirectory: String, uid: uid_t = getuid()) -> String {
        ((temporaryDirectory as NSString).appendingPathComponent("codex-ipc") as NSString)
            .appendingPathComponent("ipc-\(uid).sock")
    }

    /// The places tried, in the app's order.
    public var socketPaths: [String] {
        [Self.socketPath(codexHome: codexHome), Self.legacySocketPath(temporaryDirectory: temporaryDirectory)]
    }

    public func connect() throws -> CodexAppRouter {
        var firstFailure: Error?
        for path in socketPaths {
            do {
                return try Self.connect(path)
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        throw firstFailure ?? CodexLinkError.connect(ENOENT)
    }

    /// Connects, then checks who answered: a socket file can be left by anyone with access to its
    /// folder, but the process at the other end of the connection can't pretend to be you.
    static func connect(_ path: String) throws -> CodexAppRouter {
        let stream = try SocketStream.connect(unixPath: path)
        do {
            let peer = try stream.peer()
            guard peer.uid == getuid() else { throw CodexLinkError.notYours(path) }
            return CodexAppRouter(transport: stream, hostExecutable: peer.pid.flatMap(executable))
        } catch {
            stream.close()
            throw error
        }
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func executable(_ pid: pid_t) -> String? {
        var buf = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = pid > 0 ? proc_pidpath(pid, &buf, UInt32(buf.count)) : 0
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix(Int(n)), as: UTF8.self)
    }
}
#endif
