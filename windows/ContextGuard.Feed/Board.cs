namespace ContextGuard.Feed;

// What `context-guard ui` gives the app to draw, as Core's Board.swift writes it: the tray icon, its
// menu, the popups and notices, and Settings while it's open. Every word comes from there; the app
// maps `Symbol` and `Tone` names to its icons and colors and sends back what you clicked (`Intent`).
//
// Where something is one of several kinds, it has exactly one of its kinds' members set (a popup has
// `Question` or `Notice`). contract/ui/boards/ holds examples; the tests read each one.

public sealed record Board
{
    public required Tray Tray { get; init; }
    public required Menu Menu { get; init; }
    /// <summary>Popups and notices, top to bottom.</summary>
    public required IReadOnlyList<Popup> Popups { get; init; }
    /// <summary>Only while Settings is open.</summary>
    public Settings? Settings { get; init; }
}

public sealed record Tray
{
    /// <summary><c>on</c>, <c>asking</c> (a question waits for an answer) or <c>off</c>.</summary>
    public required string State { get; init; }
    /// <summary>What a screen reader says for the icon.</summary>
    public required string Label { get; init; }
}

public sealed record Toggle
{
    public required string Label { get; init; }
    public required bool On { get; init; }
}

/// <summary>A button: its words and its tooltip.</summary>
public sealed record Button
{
    public required string Label { get; init; }
    public string? Help { get; init; }
}

/// <summary>The question's second answer, Wait or Not Now, and what it sends.</summary>
public sealed record Deferral
{
    public required string Label { get; init; }
    public string? Help { get; init; }
    /// <summary><c>later</c> or <c>skip</c> (an <see cref="AnswerAction"/>).</summary>
    public required string Answer { get; init; }
}

/// <summary>An icon and a line of text in one color.</summary>
public sealed record Status
{
    public required string Text { get; init; }
    public required string Symbol { get; init; }
    public required string Tone { get; init; }
}

public sealed record Note
{
    public required string Text { get; init; }
    public required string Tone { get; init; }
}

// The menu

/// <summary>What a click on the tray icon shows: the Mac's menu under its gauge.</summary>
public sealed record Menu
{
    public required Toggle On { get; init; }
    /// <summary>The settings in a line or two ("Asks at 300k · Wait until 500k").</summary>
    public required IReadOnlyList<string> Lines { get; init; }
    public required string Heading { get; init; }
    /// <summary>When no session runs, what it says instead of the list.</summary>
    public string? Empty { get; init; }
    /// <summary>Terminal sessions that are running, largest context first.</summary>
    public required IReadOnlyList<Session> Sessions { get; init; }
    public required string Settings { get; init; }
    public required string Quit { get; init; }
}

public sealed record Session
{
    public required string Id { get; init; }
    /// <summary>In full: the app shortens it to fit.</summary>
    public required string Title { get; init; }
    public required string Symbol { get; init; }
    /// <summary>Its size ("302k").</summary>
    public required string Tokens { get; init; }
    /// <summary>Where it stands; then where its save stands, and its tool and folder.</summary>
    public required string Status { get; init; }
    public string? FollowUp { get; init; }
    public string? Subtitle { get; init; }
    /// <summary>Asks it to save, then compacts it: <see cref="Intent.Answer"/> yes from the menu.</summary>
    public required MenuItem CompactNow { get; init; }
    /// <summary>While it asks: Wait or Not Now, and Show the Question.</summary>
    public Deferral? Deferral { get; init; }
    public string? ShowQuestion { get; init; }
    public required Toggle Watch { get; init; }
}

public sealed record MenuItem
{
    public required string Label { get; init; }
    public required bool Enabled { get; init; }
}

// Popups and notices

public sealed record Popup
{
    /// <summary><c>question:&lt;session id&gt;</c> or <c>notice:…</c>: what an intent about it names.</summary>
    public required string Key { get; init; }
    public Question? Question { get; init; }
    public Notice? Notice { get; init; }
}

/// <summary>"Context at 302k … Compact this session?"; once answered, how that is going.</summary>
public sealed record Question
{
    public required string Session { get; init; }
    public required string Heading { get; init; }
    public required string Title { get; init; }
    public required string Subtitle { get; init; }
    /// <summary>Until it's answered.</summary>
    public Ask? Ask { get; init; }
    /// <summary>Once it's answered.</summary>
    public Progress? Progress { get; init; }
}

public sealed record Ask
{
    public required string Text { get; init; }
    /// <summary>The question's tooltip: the save message.</summary>
    public required string Help { get; init; }
    /// <summary>"Compacts in 45 seconds unless you answer", once a second while it counts down.</summary>
    public string? Countdown { get; init; }
    /// <summary>✕, which hides it until it asks again. None while it counts down.</summary>
    public Button? Hide { get; init; }
    public required Button TurnOff { get; init; }
    public required Deferral Deferral { get; init; }
    /// <summary>The default button.</summary>
    public required Button Compact { get; init; }
}

public sealed record Progress
{
    /// <summary><c>working</c> (something turning), <c>icon</c> (<see cref="Symbol"/> in <see cref="Tone"/>) or <c>none</c>.</summary>
    public required string Mark { get; init; }
    public string? Symbol { get; init; }
    public string? Tone { get; init; }
    public required string Text { get; init; }
}

/// <summary>A short message that closes by itself (the program closes it), or with its ✕.</summary>
public sealed record Notice
{
    public required string Symbol { get; init; }
    public required string Tone { get; init; }
    public required string Title { get; init; }
    public required string Detail { get; init; }
    public required string Caption { get; init; }
    /// <summary>A reason wraps; a name and folder stays on one line, cut in the middle.</summary>
    public required bool CaptionWraps { get; init; }
    public required string Close { get; init; }
}

// Settings

public sealed record Settings
{
    public required string Title { get; init; }
    public required IReadOnlyList<Tab> Tabs { get; init; }
}

public sealed record Tab
{
    /// <summary><c>general</c>, <c>asking</c> or <c>messages</c>.</summary>
    public required string Id { get; init; }
    public required string Title { get; init; }
    public required IReadOnlyList<Block> Blocks { get; init; }
}

/// <summary>A card, or a note under one.</summary>
public sealed record Block
{
    public Card? Card { get; init; }
    public Note? Note { get; init; }
}

public sealed record Card
{
    public required string Title { get; init; }
    /// <summary>In its header: whether its changes are saved.</summary>
    public Status? Status { get; init; }
    public required IReadOnlyList<Row> Rows { get; init; }
}

/// <summary>One row of a card.</summary>
public sealed record Row
{
    /// <summary>A switch: <c>Id</c> <c>enabled</c> is Context Guard itself (<see cref="Intent.Enable"/>).</summary>
    public ToggleRow? Toggle { get; init; }
    /// <summary>Where the app puts its own Open at login switch.</summary>
    public LoginRow? Login { get; init; }
    /// <summary>A label and how it stands (installed, connected).</summary>
    public StatusRow? Status { get; init; }
    public Note? Note { get; init; }
    public Field? Field { get; init; }
    public TextRow? Text { get; init; }
}

public sealed record ToggleRow
{
    public required string Id { get; init; }
    public required string Label { get; init; }
    public required bool On { get; init; }
}

public sealed record LoginRow
{
    public required string Label { get; init; }
}

public sealed record StatusRow
{
    public required string Label { get; init; }
    public required string Help { get; init; }
    public required Status Status { get; init; }
}

/// <summary>A number with − and + buttons; it saves as you type.</summary>
public sealed record Field
{
    /// <summary>A <see cref="SettingsField"/>.</summary>
    public required string Id { get; init; }
    public required string Label { get; init; }
    public required string Unit { get; init; }
    public required int Value { get; init; }
    /// <summary>The value as the field shows it: empty while it holds no number. A box you're typing in keeps its own text.</summary>
    public required string Text { get; init; }
    /// <summary>Marked as the one to fix.</summary>
    public required bool Invalid { get; init; }
}

/// <summary>A message box, the note under it and Restore Default.</summary>
public sealed record TextRow
{
    /// <summary>A <see cref="SettingsField"/>.</summary>
    public required string Id { get; init; }
    /// <summary>What a screen reader calls the box.</summary>
    public required string Label { get; init; }
    public required string Text { get; init; }
    public required Note Note { get; init; }
    public required RestoreButton Restore { get; init; }
}

public sealed record RestoreButton
{
    public required string Label { get; init; }
    public required string Help { get; init; }
    public required bool Enabled { get; init; }
}
