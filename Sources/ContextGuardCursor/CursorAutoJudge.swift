import ContextGuardCore
import CryptoKit
import Foundation

/// Asks Cursor's Auto model whether a chat has finished saving, through the Cursor CLI and your
/// Cursor sign-in (no API key): the counterpart of Haiku for Claude Code and the small OpenAI model
/// for Codex. Each question is one `cursor-agent -p` run in ask mode (read-only) in an empty folder
/// of Context Guard's, with the question on its standard input, so the chat's words never show in
/// the process list. Context Guard's hooks know the run by `CONTEXT_GUARD_JUDGE` and leave it
/// alone; its chat and transcript are deleted once it answers.
public struct CursorAutoJudge: CursorJudging {
    /// Under `Compactor.judgeAbandoned`, so a question is never asked twice at once.
    public static let timeout: TimeInterval = 60
    /// A judge's chat untouched for this long was left by a run that was stopped: it goes too.
    static let leftOver: TimeInterval = 600

    public var environment: [String: String]
    /// Where Cursor keeps its files (`~/.cursor`).
    var cursorDir: URL
    /// The judge's empty folder: never inside a project, so no project rules are read.
    var folder: URL
    var runner: @Sendable (URL, [String], [String: String], URL, Data) -> Command.Output? = { program, args, env, dir, input in
        Command.run(program, args, environment: env, directory: dir, input: input, timeout: CursorAutoJudge.timeout)
    }
    var clock: @Sendable () -> Date = { Date() }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        let home = environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        cursorDir = home.appendingPathComponent(".cursor", isDirectory: true)
        folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("context-guard-cursor-judge", isDirectory: true)
    }

    /// Whether there's a Cursor CLI to judge with, where the judge looks for it (Settings shows it).
    public static func cliFound(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        Command.find("cursor-agent", environment: environment) != nil
    }

    public func judge(_ prompt: String) -> Result<String, CursorJudgeFailure> {
        guard let cli = Command.find("cursor-agent", environment: environment) else {
            return .failure(CursorJudgeFailure("no Cursor CLI to judge it (cursor-agent)", asksYou: true))
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Cursor files a folder's chats under its real path (/private/var/…, not /var/…).
        let workspace = Self.realPath(folder)
        var env = environment
        env[CursorIdentify.judgeMarker] = "1"
        env["NO_OPEN_BROWSER"] = "1"
        let args = ["-p", "--model", "auto", "--mode", "ask", "--output-format", "json", "--trust", "--workspace", workspace.path]
        let out = runner(cli, args, env, workspace, Data(prompt.utf8))
        let answer = out.flatMap { Self.parse($0.text) }
        sweep(workspace, own: answer?.sessionId)
        guard let out else { return .failure(CursorJudgeFailure("no reply in \(Int(Self.timeout)) seconds")) }
        return Self.result(out, answer)
    }

    struct Answer: Equatable {
        var sessionId: String?
        var isError: Bool
        var text: String
    }

    /// The run's result object (`--output-format json`): the last line that is one.
    static func parse(_ output: String) -> Answer? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  obj["type"] as? String == "result" else { continue }
            return Answer(sessionId: obj["session_id"] as? String, isError: obj["is_error"] as? Bool ?? false,
                          text: (obj["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    static func result(_ out: Command.Output, _ answer: Answer?) -> Result<String, CursorJudgeFailure> {
        guard out.status == 0, let answer else {
            let said = out.errorText.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
            if said.contains("Authentication required") || said.contains("agent login") {
                return .failure(CursorJudgeFailure("the Cursor CLI isn't signed in (cursor-agent login)", asksYou: true))
            }
            let why = said.hasPrefix("Error: ") ? String(said.dropFirst(7)) : said
            if !why.isEmpty { return .failure(CursorJudgeFailure("cursor-agent: \(why.prefix(120))")) }
            return .failure(CursorJudgeFailure(out.status == 0 ? "no answer in its output" : "cursor-agent stopped (status \(out.status))"))
        }
        guard !answer.isError else {
            return .failure(CursorJudgeFailure(answer.text.isEmpty ? "it reported an error" : String(answer.text.prefix(120))))
        }
        guard !answer.text.isEmpty else { return .failure(CursorJudgeFailure("an empty reply")) }
        return .success(answer.text)
    }

    /// Deletes the judge's chats, its own just now and any a stopped run left, with their
    /// transcripts: they hold the chat's words. Only chats of the judge's own folder, filed under
    /// the MD5 of its path; a run still going elsewhere keeps its own.
    func sweep(_ workspace: URL, own: String?) {
        let fm = FileManager.default
        let chats = cursorDir.appendingPathComponent("chats", isDirectory: true)
            .appendingPathComponent(Self.md5(workspace.path), isDirectory: true)
        let now = clock()
        var gone: [String] = []
        for dir in (try? fm.contentsOfDirectory(at: chats, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let id = dir.lastPathComponent
            guard Paths.isValidSessionID(id) else { continue }
            let changed = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            guard id == own || now.timeIntervalSince(changed) > Self.leftOver else { continue }
            if (try? fm.removeItem(at: dir)) != nil { gone.append(id) }
        }
        guard !gone.isEmpty else { return }
        let projects = cursorDir.appendingPathComponent("projects", isDirectory: true)
        for project in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
            for id in gone {
                let transcript = project.appendingPathComponent("agent-transcripts", isDirectory: true).appendingPathComponent(id)
                if fm.fileExists(atPath: transcript.path) { try? fm.removeItem(at: transcript) }
            }
        }
    }

    static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func realPath(_ url: URL) -> URL {
        guard let p = realpath(url.path, nil) else { return url }
        defer { free(p) }
        return URL(fileURLWithPath: String(cString: p), isDirectory: true)
    }
}
