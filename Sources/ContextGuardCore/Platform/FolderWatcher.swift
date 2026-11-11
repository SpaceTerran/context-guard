#if os(Windows)
import WinSDK
#endif
import Foundation

/// Calls back when a folder's contents change: a file created, renamed into place, written or
/// removed. On the Mac a vnode source; on Windows `ReadDirectoryChangesW` on a thread of its own.
/// A folder that can't be opened is never watched (callers poll as well).
public final class FolderWatcher: @unchecked Sendable {
    #if os(Windows)
    /// The handles the watching thread uses; it closes the folder, `deinit` the stop event.
    private final class Handles: @unchecked Sendable {
        let folder: HANDLE
        let stop: HANDLE
        let finished = DispatchSemaphore(value: 0)
        init(folder: HANDLE, stop: HANDLE) {
            self.folder = folder
            self.stop = stop
        }
    }

    private var handles: Handles?
    private var thread: Thread?

    public init(_ url: URL, _ changed: @escaping @Sendable () -> Void) {
        let folder = url.path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(FILE_LIST_DIRECTORY), DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE),
                        nil, DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS) | DWORD(FILE_FLAG_OVERLAPPED), nil)
        }
        guard let folder, folder != INVALID_HANDLE_VALUE else { return }
        guard let stop = CreateEventW(nil, true, false, nil) else {
            CloseHandle(folder)
            return
        }
        let h = Handles(folder: folder, stop: stop)
        let thread = Thread {
            Self.watch(h, changed)
            CloseHandle(h.folder)
            h.finished.signal()
        }
        thread.name = "FolderWatcher"
        handles = h
        self.thread = thread
        thread.start()
    }

    private static func watch(_ h: Handles, _ changed: @Sendable () -> Void) {
        let size = 16 << 10
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buffer.deallocate() }
        // The system writes to it after the call returns, so it can't live in a Swift variable.
        let overlapped = UnsafeMutablePointer<OVERLAPPED>.allocate(capacity: 1)
        defer { overlapped.deallocate() }
        guard let ready = CreateEventW(nil, true, false, nil) else { return }
        defer { CloseHandle(ready) }
        let filter = DWORD(FILE_NOTIFY_CHANGE_FILE_NAME) | DWORD(FILE_NOTIFY_CHANGE_DIR_NAME) | DWORD(FILE_NOTIFY_CHANGE_LAST_WRITE)
            | DWORD(FILE_NOTIFY_CHANGE_SIZE) | DWORD(FILE_NOTIFY_CHANGE_ATTRIBUTES)
        while true {
            overlapped.initialize(to: OVERLAPPED())
            overlapped.pointee.hEvent = ready
            ResetEvent(ready)
            guard ReadDirectoryChangesW(h.folder, buffer, DWORD(size), false, filter, nil, overlapped, nil) else { return }
            var events: [HANDLE?] = [ready, h.stop]
            let woke = WaitForMultipleObjects(2, &events, false, INFINITE)
            var bytes: DWORD = 0
            guard woke == WAIT_OBJECT_0 else {
                // Stopping: cancel the read and wait until it's over, so the buffer can go.
                CancelIoEx(h.folder, overlapped)
                _ = GetOverlappedResult(h.folder, overlapped, &bytes, true)
                return
            }
            guard GetOverlappedResult(h.folder, overlapped, &bytes, false) else { return }
            // What changed doesn't matter (0 bytes: more than the buffer held); only that something did.
            changed()
        }
    }

    deinit {
        guard let handles, let thread else { return }
        SetEvent(handles.stop)
        if Thread.current !== thread { handles.finished.wait() }
        CloseHandle(handles.stop)
    }
    #else
    private var source: DispatchSourceFileSystemObject?

    public init(_ url: URL, _ changed: @escaping @Sendable () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend, .attrib],
                                                            queue: .global(qos: .utility))
        src.setEventHandler(handler: changed)
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    deinit { source?.cancel() }
    #endif
}
