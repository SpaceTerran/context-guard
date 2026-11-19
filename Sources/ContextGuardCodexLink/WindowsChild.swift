#if os(Windows)
import ContextGuardCore
import Foundation
import WinSDK

/// A program run with its standard input and output piped to this one and no console window.
/// Windows' background link (`context-guard-link.exe`) has no console, so a console program it
/// starts the usual way (Foundation's `Process`) gets a window of its own on your screen. This one
/// also hands the child only its three standard handles, not every handle this process could share.
final class WindowsChild: ChildRunning, @unchecked Sendable {
    /// `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`: the handles the child may have.
    static let handleList = DWORD_PTR(0x0002_0002)

    private let process: HANDLE
    /// Its standard input, to write to.
    let input: FileHandle
    /// Its standard output, to read from.
    let output: FileHandle

    private init(process: HANDLE, input: FileHandle, output: FileHandle) {
        self.process = process
        self.input = input
        self.output = output
    }

    var isRunning: Bool { WaitForSingleObject(process, 0) == DWORD(WAIT_TIMEOUT) }

    func terminate() { _ = TerminateProcess(process, 1) }

    deinit { CloseHandle(process) }

    /// Its standard error goes nowhere (`NUL`).
    static func start(executable: String, arguments: [String], environment: [String: String],
                      directory: String) throws -> WindowsChild {
        // The child's ends are closed here once it has them. This process's ends become
        // FileHandles, which hold copies of their own that no child inherits.
        var childEnds: [HANDLE] = []
        defer { childEnds.forEach { CloseHandle($0) } }
        var toChild: (read: HANDLE?, write: HANDLE?), fromChild: (read: HANDLE?, write: HANDLE?)
        guard CreatePipe(&toChild.read, &toChild.write, nil, 0), let inRead = toChild.read, let inWrite = toChild.write else {
            throw failure("a pipe")
        }
        childEnds.append(inRead)
        let input = try fileHandle(owning: inWrite)
        guard CreatePipe(&fromChild.read, &fromChild.write, nil, 0), let outRead = fromChild.read, let outWrite = fromChild.write else {
            throw failure("a pipe")
        }
        childEnds.append(outWrite)
        let output = try fileHandle(owning: outRead)
        let nul = "NUL".withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_WRITE), DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE), nil, DWORD(OPEN_EXISTING), 0, nil)
        }
        guard let nul, nul != INVALID_HANDLE_VALUE else { throw failure("NUL") }
        childEnds.append(nul)
        // A handle list names only inheritable handles; these are open only until the child has them.
        for end in childEnds { SetHandleInformation(end, DWORD(HANDLE_FLAG_INHERIT), DWORD(HANDLE_FLAG_INHERIT)) }
        let process = try create(executable: executable, commandLine: commandLine([executable] + arguments),
                                 environment: environment, directory: directory, stdin: inRead, stdout: outWrite, stderr: nul)
        return WindowsChild(process: process, input: input, output: output)
    }

    /// Foundation on Windows takes a handle only as a C runtime descriptor, which it copies and
    /// closes. The FileHandle owns `handle` from here on; so does a failure, which closes it.
    static func fileHandle(owning handle: HANDLE) throws -> FileHandle {
        let fd = _open_osfhandle(Int(bitPattern: handle), 0)
        guard fd >= 0 else {
            CloseHandle(handle)
            throw CodexLinkError.unavailable("couldn't make a file handle for a child process")
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static func create(executable: String, commandLine: String, environment: [String: String], directory: String,
                               stdin: HANDLE, stdout: HANDLE, stderr: HANDLE) throws -> HANDLE {
        var size: SIZE_T = 0
        _ = InitializeProcThreadAttributeList(nil, 1, 0, &size)
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { list.deallocate() }
        let attributes = OpaquePointer(list)
        guard InitializeProcThreadAttributeList(attributes, 1, 0, &size) else { throw failure("its handle list") }
        defer { DeleteProcThreadAttributeList(attributes) }
        // The list must stay where it is until the child has been made.
        let handles = UnsafeMutablePointer<HANDLE?>.allocate(capacity: 3)
        defer { handles.deallocate() }
        handles.initialize(from: [stdin, stdout, stderr], count: 3)
        guard UpdateProcThreadAttribute(attributes, 0, handleList, handles, SIZE_T(3 * MemoryLayout<HANDLE?>.size), nil, nil) else {
            throw failure("its handle list")
        }

        var info = STARTUPINFOEXW()
        info.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
        info.StartupInfo.dwFlags = DWORD(STARTF_USESTDHANDLES)
        info.StartupInfo.hStdInput = stdin
        info.StartupInfo.hStdOutput = stdout
        info.StartupInfo.hStdError = stderr
        info.lpAttributeList = attributes
        var made = PROCESS_INFORMATION()
        var line = Array(commandLine.utf16) + [0]
        let block = environmentBlock(environment)
        let flags = DWORD(CREATE_NO_WINDOW) | DWORD(CREATE_UNICODE_ENVIRONMENT) | DWORD(EXTENDED_STARTUPINFO_PRESENT)
        // The program named, not one found by searching for the command line's first word.
        let ok = block.withUnsafeBufferPointer { env in
            executable.withCString(encodedAs: UTF16.self) { program in
                directory.withCString(encodedAs: UTF16.self) { dir in
                    withUnsafeMutablePointer(to: &info) { ex in
                        ex.withMemoryRebound(to: STARTUPINFOW.self, capacity: 1) { startup in
                            CreateProcessW(program, &line, nil, nil, true, flags, UnsafeMutableRawPointer(mutating: env.baseAddress),
                                           dir, startup, &made)
                        }
                    }
                }
            }
        }
        guard ok, let process = made.hProcess else {
            throw CodexLinkError.unavailable("couldn't start \(executable): \(SocketStream.message(for: Int32(bitPattern: GetLastError())))")
        }
        CloseHandle(made.hThread)
        return process
    }

    static func failure(_ what: String) -> CodexLinkError {
        .unavailable("couldn't make \(what) for a child process: \(SocketStream.message(for: Int32(bitPattern: GetLastError())))")
    }

    /// `NAME=value` pairs, each ending in a 0, then one more: sorted by name without case, as
    /// Windows keeps them.
    static func environmentBlock(_ environment: [String: String]) -> [WCHAR] {
        let pairs = environment.filter { !$0.key.isEmpty && !$0.key.contains("=") }
            .sorted { $0.key.uppercased() < $1.key.uppercased() }
        var block: [WCHAR] = []
        for (name, value) in pairs { block += Array("\(name)=\(value)".utf16) + [0] }
        if block.isEmpty { block.append(0) }
        return block + [0]
    }

    /// A command line Windows programs split back into `arguments` (`CommandLineToArgvW` rules).
    static func commandLine(_ arguments: [String]) -> String {
        arguments.map(quoted).joined(separator: " ")
    }

    static func quoted(_ argument: String) -> String {
        guard argument.isEmpty || argument.contains(where: { " \t\n\u{0B}\"".contains($0) }) else { return argument }
        var out = "\""
        var backslashes = 0
        for c in argument {
            if c == "\\" {
                backslashes += 1
                continue
            }
            // Backslashes before a quote are doubled, and the quote escaped.
            out += String(repeating: "\\", count: c == "\"" ? backslashes * 2 + 1 : backslashes)
            backslashes = 0
            out.append(c)
        }
        // And before the closing quote.
        return out + String(repeating: "\\", count: backslashes * 2) + "\""
    }
}
#endif
