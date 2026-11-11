#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import WinSDK
#endif
import Foundation

/// Reading files other programs own (Claude Code transcripts, Codex rollouts) without getting in
/// their way. On Windows a plain `FileHandle(forReadingAtPath:)` stops anyone renaming or deleting
/// the file while it's open (`codex archive` moves rollouts); this one doesn't, as on the Mac.
public enum SharedFile {
    public struct Identity: Equatable, Sendable {
        /// The inode, or on Windows the NTFS file index: a file replaced under the same name has a new one.
        public var id: UInt64
        public var size: UInt64
    }

    public static func openForReading(_ path: String) -> FileHandle? {
        #if os(Windows)
        let h = path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE),
                        nil, DWORD(OPEN_EXISTING), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let h, h != INVALID_HANDLE_VALUE else { return nil }
        // FileHandle on Windows takes a C runtime descriptor; closing it closes the handle too.
        let fd = _open_osfhandle(Int(bitPattern: h), _O_RDONLY)
        guard fd >= 0 else {
            CloseHandle(h)
            return nil
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        #else
        return FileHandle(forReadingAtPath: path)
        #endif
    }

    /// The open file's identity and size, from the handle itself (not the path, which may already
    /// name a newer file).
    public static func identity(_ handle: FileHandle) -> Identity? {
        #if os(Windows)
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle._handle, &info) else { return nil }
        return Identity(id: UInt64(info.nFileIndexHigh) << 32 | UInt64(info.nFileIndexLow),
                        size: UInt64(info.nFileSizeHigh) << 32 | UInt64(info.nFileSizeLow))
        #else
        var st = stat()
        guard fstat(handle.fileDescriptor, &st) == 0 else { return nil }
        return Identity(id: UInt64(st.st_ino), size: UInt64(max(0, st.st_size)))
        #endif
    }
}
