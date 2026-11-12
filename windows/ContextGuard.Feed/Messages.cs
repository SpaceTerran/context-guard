using System.Text.Json.Serialization;

namespace ContextGuard.Feed;

/// <summary>
/// One line <c>context-guard ui</c> writes. <see cref="Type"/> says which:
/// <c>board</c> (<see cref="Board"/>: the whole board, at start and whenever it changes),
/// <c>chime</c> (a question popup just opened),
/// <c>result</c> (one for each intent: its <see cref="Id"/>, and <see cref="Problem"/> when it couldn't be done;
/// one with no id at start means the settings couldn't be updated), or
/// <c>error</c> (<see cref="Message"/>: a line it couldn't read).
/// </summary>
public sealed record FeedMessage
{
    /// <summary>The format's version: <see cref="FeedClient.Version"/>.</summary>
    public required int V { get; init; }
    public required string Type { get; init; }
    public Board? Board { get; init; }
    public string? Id { get; init; }
    public string? Problem { get; init; }
    public string? Message { get; init; }
}

/// <summary>What became of an intent: <see cref="Problem"/> says why it couldn't be done (the app beeps).</summary>
public sealed record FeedResult(string? Id, string? Problem)
{
    public bool Succeeded => Problem is null;
}

/// <summary>
/// One line the app writes: what you did, named by <see cref="Do"/>, with an <see cref="Id"/> its result
/// carries. Make one with the static methods; <see cref="FeedClient.SendAsync"/> gives it an id.
/// contract/ui/intents/ holds one of each.
/// </summary>
public sealed record Intent
{
    public required string Do { get; init; }
    public string? Id { get; init; }
    public string? Session { get; init; }
    public string? Action { get; init; }
    public string? Source { get; init; }
    public bool? On { get; init; }
    public string? Key { get; init; }
    public string? Field { get; init; }
    public string? Value { get; init; }
    public bool? Up { get; init; }

    /// <summary>A popup's or the menu's answer to a session's question. Yes from the menu is Compact Now.</summary>
    public static Intent Answer(string session, string action, string source) =>
        new() { Do = "answer", Session = session, Action = action, Source = source };

    /// <summary>Turn Off in a popup: off, and a notice says how to turn it back on.</summary>
    public static Intent TurnOff() => new() { Do = "turnOff" };

    /// <summary>The menu's or Settings' switch.</summary>
    public static Intent Enable(bool on) => new() { Do = "enable", On = on };

    /// <summary>Watch This Session.</summary>
    public static Intent Watch(string session, bool on) => new() { Do = "watch", Session = session, On = on };

    /// <summary>✕ on a question: hidden until it asks again.</summary>
    public static Intent Hide(string session) => new() { Do = "hide", Session = session };

    /// <summary>Show the Question, in the menu.</summary>
    public static Intent Show(string session) => new() { Do = "show", Session = session };

    /// <summary>✕ on a notice.</summary>
    public static Intent Close(string key) => new() { Do = "close", Key = key };

    /// <summary>Settings opened: it starts from the settings as they are now.</summary>
    public static Intent SettingsOpen() => new() { Do = "settingsOpen" };

    public static Intent SettingsClose() => new() { Do = "settingsClose" };

    /// <summary>A field as typed: a number field's text is read as a number.</summary>
    public static Intent Set(string field, string value) => new() { Do = "set", Field = field, Value = value };

    /// <summary>A number field's − or + button.</summary>
    public static Intent Step(string field, bool up) => new() { Do = "step", Field = field, Up = up };

    /// <summary>Restore Default under a message.</summary>
    public static Intent Restore(string field) => new() { Do = "restore", Field = field };
}

/// <summary>An answer's action.</summary>
public static class AnswerAction
{
    public const string Yes = "yes";
    public const string Later = "later";
    public const string Skip = "skip";
}

/// <summary>Where an answer came from.</summary>
public static class AnswerSource
{
    public const string Popup = "popup";
    public const string Menu = "menu";
}

/// <summary>Settings' fields, as <see cref="Field.Id"/>, <see cref="TextRow.Id"/> and intents name them.</summary>
public static class SettingsField
{
    /// <summary>Claude Code's thresholds, in thousands of tokens.</summary>
    public const string AskK = "askK";
    public const string LaterK = "laterK";
    /// <summary>Codex's thresholds, in percent of a session's window.</summary>
    public const string CodexAsk = "codexAsk";
    public const string CodexLater = "codexLater";
    /// <summary>The question's countdown, in seconds.</summary>
    public const string AutoYes = "autoYes";
    public const string Message = "message";
    public const string ContinueMessage = "continueMessage";
}

/// <summary>
/// The lines as JSON, without reflection (so it works trimmed and with Native AOT). Names are camel case;
/// members that are null aren't written, as the program leaves them out. Members it doesn't know are skipped.
/// </summary>
[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull)]
[JsonSerializable(typeof(FeedMessage))]
[JsonSerializable(typeof(Intent))]
public sealed partial class FeedJson : JsonSerializerContext
{
}

/// <summary>The same, refusing members it doesn't know: the tests read the contract files with it.</summary>
[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow)]
[JsonSerializable(typeof(FeedMessage))]
[JsonSerializable(typeof(Intent))]
internal sealed partial class StrictFeedJson : JsonSerializerContext
{
}
