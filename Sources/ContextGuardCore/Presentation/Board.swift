import Foundation

/// What `context-guard ui` gives the Windows app to draw: the tray icon, its menu, the popups and
/// notices, and Settings while it's open. Every word is worked out here, so both apps say the same
/// thing; the app maps `symbol` and `tone` names to its icons and colors and sends back what you
/// clicked (`FeedIntent`).
///
/// Where something is one of several kinds, it is an object with exactly one of its kinds' keys
/// (a popup has `question` or `notice`), so a reader needs no type field.
public struct Board: Encodable, Equatable, Sendable {
    public var tray: Tray
    public var menu: Menu
    /// Popups and notices, top to bottom.
    public var popups: [Popup]
    /// Only while Settings is open.
    public var settings: Settings?

    public struct Tray: Encodable, Equatable, Sendable {
        /// `on`, `asking` (a question waits for an answer) or `off`.
        public var state: String
        /// What a screen reader says for the icon.
        public var label: String
    }

    public struct Toggle: Encodable, Equatable, Sendable {
        public var label: String
        public var on: Bool
    }

    /// A button: its words and its tooltip.
    public struct Action: Encodable, Equatable, Sendable {
        public var label: String
        public var help: String?
    }

    /// The question's second answer, Wait or Not Now, and what it sends.
    public struct Deferral: Encodable, Equatable, Sendable {
        public var label: String
        public var help: String?
        /// `later` or `skip`.
        public var answer: Answer.Action
    }

    /// An icon and a line of text in one color.
    public struct Status: Encodable, Equatable, Sendable {
        public var text: String
        public var symbol: Symbol
        public var tone: Tone

        public init(_ line: StatusLine) {
            text = line.text
            symbol = line.symbol
            tone = line.tone
        }
    }

    public struct Note: Encodable, Equatable, Sendable {
        public var text: String
        public var tone: Tone

        public init(_ note: SettingsNote) {
            text = note.text
            tone = note.tone
        }
    }

    // MARK: The menu

    /// What a click on the tray icon shows: the Mac's menu under the gauge.
    public struct Menu: Encodable, Equatable, Sendable {
        public var on: Toggle
        /// The settings in a line or two ("Asks at 300k · Wait until 500k").
        public var lines: [String]
        public var heading: String
        /// When no session runs, what it says instead of the list.
        public var empty: String?
        /// Terminal sessions that are running, largest context first.
        public var sessions: [Session]
        public var settings: String
        public var quit: String
    }

    public struct Session: Encodable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var symbol: Symbol
        /// Its size ("302k").
        public var tokens: String
        /// Where it stands, then where its save stands, then its tool and folder.
        public var status: String
        public var followUp: String?
        public var subtitle: String?
        /// Asks it to save, then compacts it, even with Context Guard off or the tab unwatched.
        public var compactNow: MenuItem
        /// While it asks: Wait or Not Now, and Show the Question.
        public var deferral: Deferral?
        public var showQuestion: String?
        public var watch: Toggle
    }

    public struct MenuItem: Encodable, Equatable, Sendable {
        public var label: String
        public var enabled: Bool
    }

    // MARK: Popups and notices

    public struct Popup: Encodable, Equatable, Sendable {
        /// `question:<session id>` or `notice:…`: what an intent about it names.
        public var key: String
        public var question: Question?
        public var notice: Notice?
    }

    /// "Context at 302k … Compact this session?" with Turn Off, Wait and Compact; once answered, how
    /// that is going.
    public struct Question: Encodable, Equatable, Sendable {
        public var session: String
        public var heading: String
        public var title: String
        public var subtitle: String
        /// Until it's answered.
        public var ask: Ask?
        /// Once it's answered.
        public var progress: Progress?
    }

    public struct Ask: Encodable, Equatable, Sendable {
        public var text: String
        /// The question's tooltip: the save message.
        public var help: String
        /// "Compacts in 45 seconds unless you answer", once a second while it counts down.
        public var countdown: String?
        /// ✕, which hides it until it asks again. None while it counts down: it would hide that.
        public var hide: Action?
        public var turnOff: Action
        public var deferral: Deferral
        /// The default button.
        public var compact: Action
    }

    public struct Progress: Encodable, Equatable, Sendable {
        /// `working` (something turning), `icon` (`symbol` in `tone`) or `none`.
        public var mark: String
        public var symbol: Symbol?
        public var tone: Tone?
        public var text: String
    }

    /// A short message that closes by itself (`context-guard ui` closes it), or with its ✕.
    public struct Notice: Encodable, Equatable, Sendable {
        public var symbol: Symbol
        public var tone: Tone
        public var title: String
        public var detail: String
        public var caption: String
        /// A reason wraps; a name and folder stays on one line, cut in the middle.
        public var captionWraps: Bool
        public var close: String
    }

    // MARK: Settings

    public struct Settings: Encodable, Equatable, Sendable {
        public var title: String
        public var tabs: [Tab]
    }

    public struct Tab: Encodable, Equatable, Sendable {
        /// `general`, `asking` or `messages`.
        public var id: String
        public var title: String
        public var blocks: [Block]
    }

    /// A card, or a note under one.
    public struct Block: Encodable, Equatable, Sendable {
        public var card: Card?
        public var note: Note?

        public static func card(_ title: String, status: Status? = nil, _ rows: [Row]) -> Block {
            Block(card: Card(title: title, status: status, rows: rows))
        }

        public static func note(_ note: SettingsNote) -> Block { Block(note: Note(note)) }
    }

    public struct Card: Encodable, Equatable, Sendable {
        public var title: String
        /// In its header: whether its changes are saved.
        public var status: Status?
        public var rows: [Row]
    }

    /// One row of a card.
    public struct Row: Encodable, Equatable, Sendable {
        /// A switch: `id` `enabled` is Context Guard itself.
        public var toggle: ToggleRow?
        /// Where the app puts its own Open at login switch.
        public var login: LoginRow?
        /// A label and how it stands (installed, connected).
        public var status: StatusRow?
        public var note: Note?
        public var field: Field?
        public var text: TextRow?
    }

    public struct ToggleRow: Encodable, Equatable, Sendable {
        public var id: String
        public var label: String
        public var on: Bool
    }

    public struct LoginRow: Encodable, Equatable, Sendable {
        public var label: String
    }

    public struct StatusRow: Encodable, Equatable, Sendable {
        public var label: String
        public var help: String
        public var status: Status
    }

    /// A number with − and + buttons; it saves as you type.
    public struct Field: Encodable, Equatable, Sendable {
        public var id: SettingsForm.Field
        public var label: String
        public var unit: String
        public var value: Int
        /// The value as the field shows it: empty while it holds no number.
        public var text: String
        /// Marked as the one to fix.
        public var invalid: Bool
    }

    /// A message box, the note under it and Restore Default.
    public struct TextRow: Encodable, Equatable, Sendable {
        public var id: SettingsForm.Field
        /// What a screen reader calls the box.
        public var label: String
        public var text: String
        public var note: Note
        public var restore: RestoreButton
    }

    public struct RestoreButton: Encodable, Equatable, Sendable {
        public var label: String
        public var help: String
        public var enabled: Bool
    }
}

extension Symbol: Encodable {}
extension Tone: Encodable {}
