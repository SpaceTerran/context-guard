#if os(Windows)
import ContextGuardCore
import Foundation
import WinSDK

/// The `codex.exe` terminal apps running on this PC. Windows has no controlling terminal to tell a
/// terminal app by, so it's told by its command line, and the Codex desktop app's own copies (under
/// `%LOCALAPPDATA%\OpenAI\Codex\bin\`, started by `ChatGPT.exe`) are left out. A process this one
/// may not read (an elevated one) is left out too: its sessions can't be reached anyway.
public struct SystemCodexTerminals: CodexTerminalProbing {
    public init() {}

    public func terminals() -> [CodexTerminalProcess] {
        let desktopApp = ProcessInfo.processInfo.environment["LOCALAPPDATA"].map { $0 + "\\OpenAI\\Codex\\bin" }
        return Self.processes().compactMap { pid, name in
            guard Self.isCodexProgram(name), let p = Self.read(pid), CodexAttachment.isTerminalApp(p.args) else { return nil }
            if let desktopApp, let program = p.args.first, PathRules.isSameOrInside(WindowsPaths.withoutPrefix(program), desktopApp) {
                return nil
            }
            return p
        }
    }

    static func isCodexProgram(_ name: String) -> Bool { name.lowercased() == "codex.exe" }

    static func pids() -> [Int32] { processes().map(\.pid) }

    static func name(_ pid: Int32) -> String? { processes().first { $0.pid == pid }?.name }

    static func cwd(_ pid: Int32) -> String? { read(pid)?.cwd }

    static func arguments(_ pid: Int32) -> [String]? { read(pid)?.args }

    /// Every process and its program's file name.
    static func processes() -> [(pid: Int32, name: String)] {
        let snap = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0)
        guard let snap, snap != INVALID_HANDLE_VALUE else { return [] }
        defer { CloseHandle(snap) }
        var entry = PROCESSENTRY32W()
        entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
        var out: [(pid: Int32, name: String)] = []
        guard Process32FirstW(snap, &entry) else { return [] }
        repeat {
            let name = withUnsafeBytes(of: entry.szExeFile) { raw in
                String(decodingCString: raw.bindMemory(to: UInt16.self).baseAddress!, as: UTF16.self)
            }
            if entry.th32ProcessID != 0 { out.append((Int32(bitPattern: entry.th32ProcessID), name)) }
        } while Process32NextW(snap, &entry)
        return out
    }

    /// Its command line and working folder from its process parameters, and when it started.
    static func read(_ pid: Int32) -> CodexTerminalProcess? {
        guard pid > 0, let h = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION) | DWORD(PROCESS_VM_READ), false, DWORD(pid)) else {
            return nil
        }
        defer { CloseHandle(h) }
        var created = FILETIME(), exited = FILETIME(), kernel = FILETIME(), user = FILETIME()
        var startedAt: Double?
        if GetProcessTimes(h, &created, &exited, &kernel, &user) {
            let start = ProcessStart(windowsFileTime: UInt64(created.dwHighDateTime) << 32 | UInt64(created.dwLowDateTime))
            startedAt = Double(start.seconds) + Double(start.microseconds) / 1_000_000
        }
        guard let params = ProcessMemory.parameters(h),
              let commandLine = ProcessMemory.unicodeString(h, params, at: 0x70),
              let cwd = ProcessMemory.unicodeString(h, params, at: 0x38), !cwd.isEmpty else { return nil }
        let args = WindowsPaths.splitCommandLine(commandLine)
        guard !args.isEmpty else { return nil }
        return CodexTerminalProcess(pid: pid, cwd: PathRules.native(cwd), args: args, startedAt: startedAt)
    }
}

/// Another process's parameters (x64): `PEB.ProcessParameters` at 0x20; in
/// `RTL_USER_PROCESS_PARAMETERS` the working folder (`CurrentDirectory.DosPath`) at 0x38 and the
/// command line at 0x70, each a `UNICODE_STRING`.
enum ProcessMemory {
    typealias QueryInformation = @convention(c) (HANDLE?, Int32, UnsafeMutableRawPointer?, ULONG, UnsafeMutablePointer<ULONG>?) -> LONG

    static let queryInformation: QueryInformation? = {
        let ntdll = "ntdll.dll".withCString(encodedAs: UTF16.self) { GetModuleHandleW($0) }
        guard let ntdll, let fn = GetProcAddress(ntdll, "NtQueryInformationProcess") else { return nil }
        return unsafeBitCast(fn, to: QueryInformation.self)
    }()

    static func bytes(_ h: HANDLE, _ address: UInt64, _ count: Int) -> [UInt8]? {
        guard count > 0, address != 0 else { return count == 0 ? [] : nil }
        var buffer = [UInt8](repeating: 0, count: count)
        var got: SIZE_T = 0
        let ok = buffer.withUnsafeMutableBytes { raw in
            ReadProcessMemory(h, UnsafeRawPointer(bitPattern: UInt(address)), raw.baseAddress, SIZE_T(count), &got)
        }
        guard ok, Int(got) == count else { return nil }
        return buffer
    }

    static func u64(_ b: [UInt8], _ at: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[at + $1]) << (8 * UInt64($1)) } }
    static func u16(_ b: [UInt8], _ at: Int) -> UInt16 { UInt16(b[at]) | UInt16(b[at + 1]) << 8 }

    /// `RTL_USER_PROCESS_PARAMETERS`, its first 0x80 bytes.
    static func parameters(_ h: HANDLE) -> [UInt8]? {
        guard let queryInformation else { return nil }
        // PROCESS_BASIC_INFORMATION (x64): PebBaseAddress at 8.
        var basic = [UInt8](repeating: 0, count: 48)
        var length: ULONG = 0
        let status = basic.withUnsafeMutableBytes { queryInformation(h, 0, $0.baseAddress, 48, &length) }
        guard status == 0, let peb = bytes(h, u64(basic, 8), 0x28) else { return nil }
        return bytes(h, u64(peb, 0x20), 0x80)
    }

    /// A `UNICODE_STRING` (x64: Length, MaximumLength, padding, Buffer) inside `params`.
    static func unicodeString(_ h: HANDLE, _ params: [UInt8], at offset: Int) -> String? {
        let length = Int(u16(params, offset))
        guard let raw = bytes(h, u64(params, offset + 8), length) else { return nil }
        let units = stride(from: 0, to: raw.count - 1, by: 2).map { UInt16(raw[$0]) | UInt16(raw[$0 + 1]) << 8 }
        return String(decoding: units, as: UTF16.self)
    }
}

enum WindowsPaths {
    /// The real path of what's there (links followed, real case), else the full path of `path`.
    static func resolved(_ path: String) -> String {
        let h = path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, 0, DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE), nil,
                        DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS), nil)
        }
        if let h, h != INVALID_HANDLE_VALUE {
            defer { CloseHandle(h) }
            var buffer = [WCHAR](repeating: 0, count: 32_768)
            let n = GetFinalPathNameByHandleW(h, &buffer, DWORD(buffer.count), DWORD(FILE_NAME_NORMALIZED))
            if n > 0, Int(n) < buffer.count {
                return PathRules.native(withoutPrefix(String(decoding: buffer.prefix(Int(n)), as: UTF16.self)))
            }
        }
        var buffer = [WCHAR](repeating: 0, count: 32_768)
        let n = path.withCString(encodedAs: UTF16.self) { GetFullPathNameW($0, DWORD(buffer.count), &buffer, nil) }
        guard n > 0, Int(n) < buffer.count else { return PathRules.native(path) }
        return PathRules.native(String(decoding: buffer.prefix(Int(n)), as: UTF16.self))
    }

    /// Without the `\\?\` that long paths and `GetFinalPathNameByHandleW` carry (`\\?\UNC\` → `\\`).
    static func withoutPrefix(_ path: String) -> String {
        if path.hasPrefix("\\\\?\\UNC\\") { return "\\\\" + path.dropFirst(8) }
        if path.hasPrefix("\\\\?\\") { return String(path.dropFirst(4)) }
        return path
    }

    /// A command line split the way programs split their own.
    static func splitCommandLine(_ commandLine: String) -> [String] {
        var count: Int32 = 0
        guard let argv = commandLine.withCString(encodedAs: UTF16.self, { CommandLineToArgvW($0, &count) }) else { return [] }
        defer { LocalFree(argv) }
        return (0..<Int(count)).compactMap { argv[$0].map { String(decodingCString: $0, as: UTF16.self) } }
    }
}
#endif
