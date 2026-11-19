#if os(Windows)
import ContextGuardCore
import Foundation
import WinSDK

/// Windows' router: the named pipe `\\.\pipe\codex-ipc`. A pipe's name is the same for every user
/// of the PC, so the program serving it is checked before anything is sent: it must be yours.
public struct CodexAppPipeConnector: CodexAppConnecting {
    public static let defaultPipe = #"\\.\pipe\codex-ipc"#
    public let pipe: String

    public init(pipe: String = CodexAppPipeConnector.defaultPipe) {
        self.pipe = pipe
    }

    public func connect() throws -> CodexAppRouter {
        let stream = try NamedPipeStream.connect(pipe)
        guard let pid = stream.serverProcessId, WindowsProcess.isYours(pid) else {
            stream.close()
            throw CodexLinkError.notYours(pipe)
        }
        return CodexAppRouter(transport: stream, hostExecutable: WindowsProcess.executable(pid))
    }
}

/// Who runs a process, and its program.
enum WindowsProcess {
    /// It runs as the same user as this process.
    static func isYours(_ pid: UInt32) -> Bool {
        guard let theirs = user(of: pid), let mine = user(of: GetCurrentProcessId()) else { return false }
        return theirs == mine
    }

    /// The user a process runs as: its token's SID, as bytes. nil when it can't be read (another
    /// user's process, an elevated one, or none).
    static func user(of pid: UInt32) -> [UInt8]? {
        guard pid != 0, let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(pid)) else { return nil }
        defer { CloseHandle(process) }
        var opened: HANDLE?
        guard OpenProcessToken(process, DWORD(TOKEN_QUERY), &opened), let token = opened else { return nil }
        defer { CloseHandle(token) }
        var size: DWORD = 0
        _ = GetTokenInformation(token, TokenUser, nil, 0, &size)
        guard size > 0 else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { buffer.deallocate() }
        guard GetTokenInformation(token, TokenUser, buffer, size, &size) else { return nil }
        guard let sid = buffer.assumingMemoryBound(to: TOKEN_USER.self).pointee.User.Sid, IsValidSid(sid) else { return nil }
        return [UInt8](UnsafeRawBufferPointer(start: sid, count: Int(GetLengthSid(sid))))
    }

    /// The full path of its program.
    static func executable(_ pid: UInt32) -> String? {
        guard pid != 0, let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(pid)) else { return nil }
        defer { CloseHandle(process) }
        var buffer = [WCHAR](repeating: 0, count: 32_768)
        var size = DWORD(buffer.count)
        guard QueryFullProcessImageNameW(process, 0, &buffer, &size), size > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(size)), as: UTF16.self)
    }

    /// Where the Store installed a package for you (`OpenAI.Codex_2p2nqsd0c76g0`: the Codex app),
    /// the newest version when there are several. nil when it isn't installed.
    static func packageFolder(family: String) -> String? {
        typealias PackagesByFamily = @convention(c) (UnsafePointer<WCHAR>?, UnsafeMutablePointer<UInt32>?,
                                                     UnsafeMutablePointer<UnsafeMutablePointer<WCHAR>?>?,
                                                     UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<WCHAR>?) -> LONG
        typealias PathByFullName = @convention(c) (UnsafePointer<WCHAR>?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<WCHAR>?) -> LONG
        // kernel32 has them from Windows 8; looked up so an older system just has no answer.
        let kernel = "kernel32.dll".withCString(encodedAs: UTF16.self) { GetModuleHandleW($0) }
        guard let kernel, let packagesAt = GetProcAddress(kernel, "GetPackagesByPackageFamily"),
              let pathAt = GetProcAddress(kernel, "GetPackagePathByFullName") else { return nil }
        let packages = unsafeBitCast(packagesAt, to: PackagesByFamily.self)
        let pathOf = unsafeBitCast(pathAt, to: PathByFullName.self)
        let insufficient = LONG(ERROR_INSUFFICIENT_BUFFER)
        return family.withCString(encodedAs: UTF16.self) { familyName -> String? in
            var count: UInt32 = 0
            var length: UInt32 = 0
            guard packages(familyName, &count, nil, &length, nil) == insufficient, count > 0, length > 0 else { return nil }
            var names = [UnsafeMutablePointer<WCHAR>?](repeating: nil, count: Int(count))
            var text = [WCHAR](repeating: 0, count: Int(length))
            // The names point into `text`: read them before it goes.
            return names.withUnsafeMutableBufferPointer { names -> String? in
                text.withUnsafeMutableBufferPointer { text -> String? in
                    guard packages(familyName, &count, names.baseAddress, &length, text.baseAddress) == 0 else { return nil }
                    var folders: [String] = []
                    for name in names.prefix(Int(count)) {
                        guard let name else { continue }
                        var size: UInt32 = 0
                        guard pathOf(name, &size, nil) == insufficient, size > 0 else { continue }
                        var path = [WCHAR](repeating: 0, count: Int(size))
                        guard pathOf(name, &size, &path) == 0 else { continue }
                        folders.append(String(decoding: path.prefix { $0 != 0 }, as: UTF16.self))
                    }
                    return CodexAppBundle.newest(folders)
                }
            }
        }
    }
}
#endif
