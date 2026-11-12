namespace ContextGuard.Feed;

/// <summary>
/// The tones a board names (<see cref="Notice.Tone"/>, <see cref="Progress.Tone"/>, <see cref="Status.Tone"/>): each
/// is one of the brand's status colors, the same as the Mac's <c>Theme.color(_ tone:)</c>. contract/ui/names.json
/// lists them; a test checks this knows them all.
/// </summary>
public static class Tones
{
    public const string Accent = "accent", Success = "success", Warning = "warning", Danger = "danger", Muted = "muted";

    static readonly HashSet<string> Known = new(StringComparer.Ordinal) { Accent, Success, Warning, Danger, Muted };

    /// <summary>The tones this build has a color for.</summary>
    public static IReadOnlyCollection<string> All => Known;

    /// <summary>The tone; muted for none, or for one a newer program names that this build doesn't know.</summary>
    public static string For(string? tone) => tone is not null && Known.Contains(tone) ? tone : Muted;
}
