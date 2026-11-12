namespace ContextGuard.Feed;

/// <summary>
/// The icon the app draws for each symbol a board names (<see cref="Session.Symbol"/>, <see cref="Status.Symbol"/>):
/// a Segoe Fluent Icons glyph, the Windows counterpart of the SF Symbol the Mac draws for it (Icons.swift).
/// contract/ui/names.json lists every symbol; a test checks this covers them all.
/// </summary>
public static class Glyphs
{
    /// <summary>The icon font, part of Windows 11.</summary>
    public const string Font = "Segoe Fluent Icons";

    // The Mac's SF Symbol after each.
    static readonly Dictionary<string, string> BySymbol = new(StringComparer.Ordinal)
    {
        ["watching"] = "\uEA3A",     // CircleRing: circle
        ["asking"] = "\uE9CE",       // Unknown: questionmark.circle
        ["waiting"] = "\uE917",      // Clock: clock
        ["sending"] = "\uE724",      // Send: paperplane
        ["sent"] = "\uE930",         // Completed: checkmark.circle
        ["skipped"] = "\uECC9",      // RemoveFrom: minus.circle
        ["notWatching"] = "\uED1A",  // Hide: eye.slash
        ["needsYou"] = "\uE8BD",     // Message: questionmark.bubble.fill
        ["compacting"] = "\uE73F",   // BackToWindow: arrow.down.right.and.arrow.up.left.circle.fill
        ["success"] = "\uEC61",      // CompletedSolid: checkmark.circle.fill
        ["saved"] = "\uE930",        // Completed: checkmark.circle
        ["warning"] = "\uF736",      // WarningSolid: exclamationmark.triangle.fill
        ["failed"] = "\uEB90",       // StatusErrorFull: xmark.octagon.fill
        ["off"] = "\uF2D9",          // CirclePause: pause.circle.fill
        ["saving"] = "\uE896",       // Download: tray.and.arrow.down.fill
    };

    /// <summary>The symbols this build has an icon for.</summary>
    public static IReadOnlyCollection<string> Symbols => BySymbol.Keys;

    /// <summary>The glyph for a symbol; a newer program's symbol this build doesn't know gets the plain circle.</summary>
    public static string For(string symbol) => BySymbol.TryGetValue(symbol, out var glyph) ? glyph : BySymbol["watching"];
}
