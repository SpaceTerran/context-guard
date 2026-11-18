import Foundation

/// `context-guard status` as text: the settings for each tool, the Codex link (and its connection
/// to the Codex app, on the Mac), and each running session. Until the Codex link has run (no `codex-link.json`), with Cursor's hooks out and no
/// Cursor chats, it reads as it always has.
public enum StatusText {
    /// - Parameter cursorHooks: whether Cursor runs Context Guard's hooks. Cursor's line shows once
    ///   they're in or a chat has run, as in the app.
    public static func lines(config: Config, sessions: [SessionInfo], link: CodexLinkStatus?, cursorHooks: Bool = false,
                             now: Date = Date()) -> [String] {
        let codex = link != nil
        let cursor = cursorHooks || sessions.contains { $0.host == .cursor }
        let onOff = "Context Guard is \(config.enabled ? "on" : "off")"
        let claude = "asks at \(Format.tokens(config.askAt)) · compacts at \(Format.tokens(config.laterAt)) when told to wait"
        var out: [String] = []
        if codex || cursor {
            out.append(onOff)
            out.append("  Claude Code: \(claude)")
            if codex {
                out.append("  Codex: asks at \(config.codexAskPercent)% · compacts at \(config.codexLaterPercent)% of each session's window when told to wait")
                out.append("  Codex link: \(linkState(link, now: now))")
                if let link, link.isRunning(now: now), let app = link.app {
                    out.append("  Codex app: \(appState(app))")
                }
            }
            if cursor {
                out.append("  Cursor: asks at \(config.cursorAskPercent)% · compacts at \(config.cursorLaterPercent)% of each chat's window when told to wait")
            }
        } else {
            out.append("\(onOff) · \(claude)")
        }
        let live = sessions.filter(\.isLive)
        if live.isEmpty {
            out.append("No running sessions seen yet.")
            return out
        }
        out += live.map { row($0, tools: codex || cursor) }
        return out
    }

    /// One session: id, tool (with Codex in the picture), size, phase, title, then what's notable.
    static func row(_ s: SessionInfo, tools: Bool) -> String {
        var line = "\(s.id.prefix(8))  "
        if tools { line += pad(s.host == .claude ? "Claude" : s.host.name, 6) + " " }
        line += pad(Format.tokens(s.state.tokens), 6) + " " + pad(s.effectivePhase.rawValue, 9) + " " + s.title
        if !s.state.guarded { line += " (not guarded)" }
        if s.muted { line += " (not watching)" }
        if let window = s.state.window {
            line += " · \(s.state.tokens * 100 / window)% of \(Format.tokens(window))"
        }
        if s.host == .codex, s.state.codex?.surface == .app {
            line += " · Codex app"
            if s.state.codex?.attached == false { line += " · only watching" }
        } else if s.host == .codex, s.state.codex?.attached == false {
            line += " · no terminal shows it"
        }
        if s.waiterAlive { line += " · waiting in background" }
        if let f = s.state.followUp {
            line += " · compacting: \(f.stage.rawValue)\(f.note.map { " (\($0))" } ?? "")"
        }
        return line
    }

    /// How the Codex link stands, from `codex-link.json`.
    static func linkState(_ link: CodexLinkStatus?, now: Date) -> String {
        guard let link else { return "not running" }
        let age = now.timeIntervalSince(link.at)
        guard !link.stopped else { return "not running (stopped \(ago(age)))" }
        guard link.isRunning(now: now) else { return "not running (last heard from \(ago(age)))" }
        var parts: [String] = []
        if link.connected {
            parts.append("connected" + (link.serverVersion.map { " to \(codexVersion($0))" } ?? ""))
            parts.append("judge: \(link.judgeModel ?? "each session's own model")")
            if let why = link.observeOnly { parts.append("only watching: \(why)") }
        } else {
            // With the Codex app's line below, this one is about terminals.
            parts.append(link.app == nil ? "waiting for Codex" : "waiting for a Codex terminal")
            if let e = link.lastError { parts.append("last error: \(e)") }
        }
        return parts.joined(separator: " · ")
    }

    /// How the link's connection to the Codex app stands (the Mac).
    static func appState(_ app: CodexAppLinkStatus) -> String {
        guard app.connected else {
            return (["waiting for the Codex app"] + (app.lastError.map { ["last error: \($0)"] } ?? [])).joined(separator: " · ")
        }
        var parts = ["connected", app.chats == 1 ? "1 chat open" : "\(app.chats) chats open"]
        if let model = app.judgeModel { parts.append("judge: \(model)") }
        if let why = app.unsupported { parts.append("only watching: \(why)") }
        return parts.joined(separator: " · ")
    }

    /// "codex-tui/0.167.1 (Mac OS 27.2.0; arm64)" → "Codex 0.167.1".
    static func codexVersion(_ userAgent: String) -> String {
        guard let product = userAgent.split(separator: " ").first, let slash = product.firstIndex(of: "/") else { return userAgent }
        let version = product[product.index(after: slash)...]
        return version.isEmpty ? userAgent : "Codex \(version)"
    }

    static func ago(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 120 { return "\(s) s ago" }
        if s < 7_200 { return "\(s / 60) min ago" }
        return "\(s / 3_600) h ago"
    }

    static func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: max(n, s.count), withPad: " ", startingAt: 0) }
}
