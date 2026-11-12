import Foundation

/// The fixed words in the menu, popups and Settings, so both apps say the same thing. Words that
/// depend on a session or a setting are made where that's known (`SessionInfo`, `SettingsText`).
public enum Words {
    public static let appName = "Context Guard"
    public static let appOff = "Context Guard (off)"

    /// Where you run the installer: Settings says to run it when something is missing.
    public static let installer = installer(windows: PathRules.isWindows)

    public static func installer(windows: Bool) -> String { windows ? "install.ps1" : "install.sh" }

    public enum Menu {
        public static let on = "Context Guard On"
        public static let noSessions = "No sessions running"
        public static let sessions = "Sessions"
        public static let settings = "Settings…"
        public static let quit = "Quit Context Guard"
        public static let compactNow = "Compact Now"
        public static let showQuestion = "Show the Question"
        public static let watchThisSession = "Watch This Session"
    }

    public enum Popup {
        public static let turnOff = "Turn Off"
        public static let turnOffHelp = "Stop asking and stop compacting by itself until you turn Context Guard back on"
        public static let notNow = "Not Now"
        public static let notNowHelp = "Don't ask again until this session compacts"
        public static let compact = "Compact"
        public static let hideHelp = "Hide until it asks again (the menu can show it)"
        public static let close = "Close"
        public static let question = "Compact this session? It saves its work first."

        /// The Compact button's help: what it sends first.
        public static func compactHelp(_ message: String) -> String {
            "Asks it to save first: \u{201C}\(message)\u{201D}"
        }
    }

    public enum Notice {
        public static let off = "Context Guard is off"
        public static let turnBackOn = turnBackOn(windows: PathRules.isWindows)

        public static func turnBackOn(windows: Bool) -> String {
            windows ? "Turn it back on from its icon on the taskbar." : "Turn it back on from the gauge in the menu bar."
        }
        public static let saving = "Saving, then compacting"
    }

    public enum Settings {
        public static let windowTitle = "Context Guard Settings"
        public static let general = "General"
        public static let whenToAsk = "When to Ask"
        public static let messages = "Messages"

        public static let contextGuard = "Context Guard"
        public static let openAtLogin = "Open at login"
        public static let offNote = "When off, nothing pops up and nothing compacts by itself. Compact Now in a session's menu still works."
        public static let hooks = "Hooks"
        public static let hooksHelp = "Follow each Claude Code session and send it the save and continue messages"
        public static let mod = "Mod"
        public static let modHelp = "Compacts each Claude Code session once it has saved"
        public static let judge = "Judge"
        public static let judgeHelp = "Reads what the session does after the save message and says when it has saved"
        public static let link = "Link"
        public static let linkHelp = "Follows each Codex session, sends it the save and continue messages and compacts it. It connects to Codex while a Codex session runs in a terminal."

        public static let whenToAskCard = "When to ask"
        public static let ifYouDontAnswer = "If you don't answer"
        public static let askAt = "Ask at"
        public static let compactAtIfWait = "If you choose Wait, compact at"
        public static let compactAfter = "Compact after"
        public static let ifYouDontAnswerCompactAfter = "If you don't answer, compact after"
        public static let kTokens = "k tokens"
        public static let percent = "%"
        public static let seconds = "seconds"

        public static let beforeCompacting = "Before compacting, send"
        public static let beforeCompactingAbout = "Asks the session to save its work first."
        public static let saveMessage = "save message"
        public static let afterCompacting = "After compacting, send"
        public static let afterCompactingAbout = "Tells the session to carry on."
        public static let continueMessage = "continue message"
        public static let restoreDefault = "Restore Default"
        public static let emptySendsDefault = "Empty, so it sends the default."
    }
}
