import Foundation

/// How paths compare and show on this platform. On the Mac a path is compared as it is. On Windows
/// case doesn't count and either separator works, and Foundation hands paths back with a mix of
/// `/` and `\` (`homeDirectoryForCurrentUser` uses `/`, `NSHomeDirectory()` uses `\`).
///
/// The `windows` parameters exist so both sets of rules are tested on both platforms.
public enum PathRules {
    #if os(Windows)
    public static let isWindows = true
    #else
    public static let isWindows = false
    #endif

    /// Windows: `\` only, no trailing separator except a drive's root (`C:\`). Elsewhere unchanged.
    public static func native(_ path: String, windows: Bool = isWindows) -> String {
        guard windows else { return path }
        var s = path.replacingOccurrences(of: "/", with: "\\")
        while s.count > 1, s.hasSuffix("\\"), !isDriveRoot(s) { s.removeLast() }
        return s
    }

    /// The form two paths are compared in. Windows: `native`, lowercased. Elsewhere unchanged.
    public static func key(_ path: String, windows: Bool = isWindows) -> String {
        windows ? native(path, windows: true).lowercased() : path
    }

    /// `path` is `folder` or somewhere inside it.
    public static func isSameOrInside(_ path: String, _ folder: String, windows: Bool = isWindows) -> Bool {
        guard windows else {
            return path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
        }
        let p = key(path, windows: true), f = key(folder, windows: true)
        return p == f || p.hasPrefix(f.hasSuffix("\\") ? f : f + "\\")
    }

    /// The path with your home folder at its front shown as `~`.
    public static func abbreviatingHome(_ path: String) -> String {
        #if os(Windows)
        return abbreviating(path, home: NSHomeDirectory(), windows: true)
        #else
        return (path as NSString).abbreviatingWithTildeInPath
        #endif
    }

    /// Windows' `~` rule: `C:\Users\you\code` → `~\code`. A path outside `home` is unchanged.
    static func abbreviating(_ path: String, home: String, windows: Bool) -> String {
        let p = key(path, windows: windows), h = key(home, windows: windows)
        guard !h.isEmpty else { return path }
        if p == h { return "~" }
        let separator = windows ? "\\" : "/"
        guard p.hasPrefix(h.hasSuffix(separator) ? h : h + separator) else { return path }
        let rest = components(path, windows: windows).dropFirst(components(home, windows: windows).count)
        return (["~"] + rest.map(String.init)).joined(separator: separator)
    }

    static func components(_ path: String, windows: Bool) -> [Substring] {
        windows ? path.split(whereSeparator: { $0 == "/" || $0 == "\\" }) : path.split(separator: "/")
    }

    private static func isDriveRoot(_ s: String) -> Bool {
        let c = Array(s)
        return c.count == 3 && c[0].isLetter && c[1] == ":" && c[2] == "\\"
    }
}
