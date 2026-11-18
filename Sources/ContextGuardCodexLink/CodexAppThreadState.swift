import Foundation

/// One Codex app chat as its owner streams it to a follower (`thread-stream-state-changed`): a
/// snapshot of the conversation, then patches against it, each `{op, path, value}` (`add`,
/// `replace`, `remove`, as the app's state library makes them). Only the parts Context Guard reads
/// are kept; patches to the rest (the turns and their items) are passed over.
public struct CodexAppThreadState: Equatable, Sendable {
    /// The conversation's fields Context Guard reads.
    public static let kept: Set<String> = [
        "threadRuntimeStatus", "latestTokenUsageInfo", "title", "cwd", "latestModel", "source", "threadSource",
        "rolloutPath", "ephemeral",
    ]

    /// The revision the fields are at. nil: no snapshot yet, or patches were missed since the last one.
    public private(set) var revision: Int?
    public private(set) var fields: [String: JSONValue] = [:]

    public init() {}

    public enum Outcome: Equatable, Sendable {
        case applied
        /// Patches that don't follow the revision held (one was missed), or that don't fit the
        /// state: everything is dropped until the next snapshot.
        case outOfStep
        /// Not a change Context Guard knows.
        case ignored
    }

    /// One change from a `thread-stream-state-changed` broadcast (its `params.change`).
    public mutating func apply(_ change: JSONValue) -> Outcome {
        switch change["type"]?.string {
        case "snapshot":
            guard let state = change["conversationState"]?.object else { return .ignored }
            fields = state.filter { Self.kept.contains($0.key) }
            revision = change["revision"]?.int
            return .applied
        case "patches":
            guard let revision, let base = change["baseRevision"]?.int, base == revision,
                  let patches = change["patches"]?.array else {
                drop()
                return .outOfStep
            }
            var next = fields
            for p in patches {
                guard let op = p["op"]?.string, let path = p["path"]?.array, let first = path.first?.string else {
                    drop()
                    return .outOfStep
                }
                guard Self.kept.contains(first) else { continue }
                if path.count == 1 {
                    switch op {
                    case "add", "replace": next[first] = p["value"] ?? .null
                    case "remove": next.removeValue(forKey: first)
                    default:
                        drop()
                        return .outOfStep
                    }
                } else {
                    guard let current = next[first],
                          let patched = Self.patch(current, op, path.dropFirst(), p["value"]) else {
                        drop()
                        return .outOfStep
                    }
                    next[first] = patched
                }
            }
            fields = next
            self.revision = change["revision"]?.int
            return .applied
        default:
            return .ignored
        }
    }

    mutating func drop() {
        revision = nil
        fields = [:]
    }

    /// Has a snapshot, and every patch since.
    public var isCurrent: Bool { revision != nil }

    /// `idle` or `active` (a turn running).
    public var status: String? { fields["threadRuntimeStatus"]?["type"]?.string }
    public var activeFlags: [String] { fields["threadRuntimeStatus"]?["activeFlags"]?.array?.compactMap(\.string) ?? [] }
    /// The context's size as last sent, in tokens.
    public var tokens: Int? { fields["latestTokenUsageInfo"]?["last"]?["totalTokens"]?.int }
    /// The model's context window, in tokens.
    public var window: Int? { fields["latestTokenUsageInfo"]?["modelContextWindow"]?.int }
    public var title: String? { fields["title"]?.string }
    public var cwd: String? { fields["cwd"]?.string }
    public var model: String? { fields["latestModel"]?.string }
    /// Where the chat started: `vscode` for the app's own, `exec`/`cli` for a CLI chat it opened.
    public var source: String? { fields["source"]?.string }
    /// Its rollout file, where Codex writes the conversation.
    public var rolloutPath: String? { fields["rolloutPath"]?.string }
    /// Codex keeps no rollout for it. Not saying is read as ephemeral: nothing is done to a chat
    /// that may be a helper's.
    public var ephemeral: Bool { fields["ephemeral"]?.bool ?? true }

    /// `value` with one patch applied at `path` (below the top-level field), or nil if the path
    /// doesn't lead anywhere in it.
    static func patch(_ value: JSONValue, _ op: String, _ path: ArraySlice<JSONValue>, _ new: JSONValue?) -> JSONValue? {
        guard let key = path.first else { return nil }
        let rest = path.dropFirst()
        switch value {
        case .object(var o):
            guard let k = key.string else { return nil }
            if rest.isEmpty {
                switch op {
                case "add", "replace": o[k] = new ?? .null
                case "remove": o.removeValue(forKey: k)
                default: return nil
                }
            } else {
                guard let child = o[k], let patched = patch(child, op, rest, new) else { return nil }
                o[k] = patched
            }
            return .object(o)
        case .array(var a):
            if rest.isEmpty {
                if key.string == "length" {
                    guard op == "replace", let n = new?.int, n >= 0 else { return nil }
                    if n < a.count {
                        a.removeLast(a.count - n)
                    } else {
                        a.append(contentsOf: Array(repeating: .null, count: n - a.count))
                    }
                    return .array(a)
                }
                let i: Int
                if key.string == "-" {
                    i = a.count
                } else {
                    guard let n = key.int else { return nil }
                    i = n
                }
                switch op {
                case "add":
                    guard i >= 0, i <= a.count else { return nil }
                    a.insert(new ?? .null, at: i)
                case "replace":
                    guard a.indices.contains(i) else { return nil }
                    a[i] = new ?? .null
                case "remove":
                    guard a.indices.contains(i) else { return nil }
                    a.remove(at: i)
                default:
                    return nil
                }
            } else {
                guard let i = key.int, a.indices.contains(i), let patched = patch(a[i], op, rest, new) else { return nil }
                a[i] = patched
            }
            return .array(a)
        default:
            return nil
        }
    }
}
