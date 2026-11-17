import Darwin
import Foundation

/// The processes above a hook: which one runs the chat.
public protocol ProcessLineage: Sendable {
    func parent(of pid: Int32) -> Int32?
    /// The name it was started as (`argv[0]`'s last part): `cursor-agent` is a script that starts
    /// Node under that name.
    func name(of pid: Int32) -> String?
    /// Its program file.
    func executable(of pid: Int32) -> String?
}

extension ProcessLineage {
    /// The nearest process above `pid` (itself excluded) that `matches`, within a few levels.
    public func ancestor(of pid: Int32, depth: Int = 16, where matches: (Int32) -> Bool) -> Int32? {
        var p = pid
        for _ in 0..<depth {
            guard let up = parent(of: p), up > 1, up != p else { return nil }
            if matches(up) { return up }
            p = up
        }
        return nil
    }
}

/// The Mac's process table (`sysctl`, `proc_pidpath`). Reads only a process's first argument, never
/// the rest (they can hold keys).
public struct SystemProcessLineage: ProcessLineage {
    public init() {}

    public func parent(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard pid > 0, sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0,
              info.kp_proc.p_pid == pid else { return nil }
        return info.kp_eproc.e_ppid
    }

    public func name(of pid: Int32) -> String? {
        // KERN_PROCARGS2: argc, the program's path, padding, then argv[0].
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard pid > 0, sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }
        while i < size, buf[i] == 0 { i += 1 }
        var j = i
        while j < size, buf[j] != 0 { j += 1 }
        guard j > i, let arg0 = String(bytes: buf[i..<j], encoding: .utf8) else { return nil }
        return (arg0 as NSString).lastPathComponent
    }

    public func executable(of pid: Int32) -> String? {
        var buf = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = pid > 0 ? proc_pidpath(pid, &buf, UInt32(buf.count)) : 0
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix(Int(n)), as: UTF8.self)
    }
}
