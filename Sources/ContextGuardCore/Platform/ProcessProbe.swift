#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import WinSDK
#endif
import Foundation

/// Whether a process is running and when it started (`sysctl` on the Mac, `GetProcessTimes` on Windows).
#if os(Windows)
public struct SystemProcessProbe: ProcessProbing {
    public init() {}

    public func identity(of pid: Int32) -> ProcessIdentity? {
        guard pid > 0,
              let h = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION) | DWORD(SYNCHRONIZE), false, DWORD(pid)) else { return nil }
        defer { CloseHandle(h) }
        // A process that has exited can still be opened while anything holds a handle to it.
        guard WaitForSingleObject(h, 0) == DWORD(WAIT_TIMEOUT) else { return nil }
        var created = FILETIME(), exited = FILETIME(), kernel = FILETIME(), user = FILETIME()
        guard GetProcessTimes(h, &created, &exited, &kernel, &user) else { return nil }
        let ticks = UInt64(created.dwHighDateTime) << 32 | UInt64(created.dwLowDateTime)
        return ProcessIdentity(start: ProcessStart(windowsFileTime: ticks), hasTTY: nil)
    }
}
#else
public struct SystemProcessProbe: ProcessProbing {
    public init() {}

    public func identity(of pid: Int32) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        let tdev = info.kp_eproc.e_tdev
        return ProcessIdentity(
            start: ProcessStart(seconds: Int(tv.tv_sec), microseconds: Int(tv.tv_usec)),
            hasTTY: tdev != -1 && tdev != 0)
    }
}
#endif

extension ProcessStart {
    /// From a Windows FILETIME (100 ns ticks since 1601), on the same Unix clock as the Mac's.
    public init(windowsFileTime ticks: UInt64) {
        let unix = ticks &- 116_444_736_000_000_000
        self.init(seconds: Int(unix / 10_000_000), microseconds: Int(unix % 10_000_000 / 10))
    }
}
