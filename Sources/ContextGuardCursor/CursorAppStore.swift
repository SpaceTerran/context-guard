import ContextGuardCore
import Foundation

/// A Cursor chat as Cursor's own store has it.
public struct CursorStoredChat: Equatable, Sendable {
    /// Its context now and its window, as Cursor counts them (nil before its first model call).
    public var tokens: Int?
    public var window: Int?
    /// Its name, as Cursor shows it.
    public var name: String?
    /// A subagent's chat, or a background agent's.
    public var helper: Bool

    public init(tokens: Int? = nil, window: Int? = nil, name: String? = nil, helper: Bool = false) {
        self.tokens = tokens
        self.window = window
        self.name = name
        self.helper = helper
    }
}

/// The Cursor app's chats: `composerData:<conversation id>` in the `cursorDiskKV` table of its global
/// `state.vscdb`. One primary-key lookup per hook call; the chat's JSON (often megabytes) is read by
/// SQLite, never loaded whole.
public struct CursorAppStore: Sendable {
    public var file: URL

    public init(file: URL = CursorAppStore.defaultFile()) {
        self.file = file
    }

    public static func defaultFile(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    /// The chat, or nil if the app has no such chat (or its store can't be read).
    public func chat(_ id: String) -> CursorStoredChat? {
        guard Paths.isValidSessionID(id), let db = ReadOnlyDatabase(file) else { return nil }
        let sql = """
            SELECT json_extract(v, '$.contextTokensUsed'), json_extract(v, '$.contextTokenLimit'),
                   json_extract(v, '$.name'), json_type(v, '$.subagentInfo'),
                   json_type(v, '$.createdFromBackgroundAgent')
            FROM (SELECT CAST(value AS TEXT) AS v FROM cursorDiskKV WHERE key = ?1)
            """
        guard let row = db.row(sql, ["composerData:" + id]), row.count == 5 else { return nil }
        let name = row[2].text.flatMap { $0.isEmpty ? nil : $0 }
        // Background agents' chats are named "bc-…" and carry where they came from.
        let helper = row[3].text == "object" || row[4].text == "object" || id.hasPrefix("bc-")
        return CursorStoredChat(tokens: row[0].int.flatMap { $0 >= 0 ? $0 : nil },
                                window: row[1].int.flatMap { $0 > 0 ? $0 : nil }, name: name, helper: helper)
    }

    /// Whether the app still lists the chat. Archiving one sets `isArchived` on its row of the
    /// `composerHeaders` table (Cursor 3.30); deleting one takes its `composerData` away. nil when the
    /// store can't be read. A chat is only held once `chat(_:)` found it, so a store laid out some
    /// other way never reads as every chat deleted.
    public func standing(_ id: String) -> CursorChatStanding? {
        guard Paths.isValidSessionID(id), let db = ReadOnlyDatabase(file),
              let kept = db.row("SELECT count(*) FROM cursorDiskKV WHERE key = ?1", ["composerData:" + id])?.first?.int
        else { return nil }
        guard kept > 0 else { return .deleted }
        // No row, or no such table (a Cursor before 3.30): nothing says it's archived.
        let archived = db.row("SELECT isArchived FROM composerHeaders WHERE composerId = ?1", [id])?.first?.int ?? 0
        return archived != 0 ? .archived : .open
    }
}

extension CursorAppStore: CursorChatChecking {
    /// App chats only: a CLI chat ends when its `cursor-agent` does.
    public func standing(_ chat: CursorChatRef) -> CursorChatStanding? {
        chat.surface == .app ? standing(chat.id) : nil
    }
}
