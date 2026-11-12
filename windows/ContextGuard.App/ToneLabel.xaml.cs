using ContextGuard.Feed;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace ContextGuard.App;

/// <summary>
/// Words in a tone's color: a note (12, wrapping, with the Mac's 4 extra points between lines) or a status
/// ("✓ Installed": the symbol at a point smaller than the words, 6 apart).
/// </summary>
public sealed partial class ToneLabel : UserControl
{
    /// <summary>
    /// The Mac's note lines: its 12-point line is 15 high, plus <c>lineSpacing(4)</c> between lines, so 19 apart.
    /// </summary>
    const double NoteLineHeight = 19;

    /// <summary>
    /// A block of 19-high lines puts the first baseline 15 down (19 × the font's ascent share) and ends 19 × n down;
    /// the Mac's first baseline is 12 down and its note ends at 19 × n − 4 (no spacing after the last line).
    /// </summary>
    static readonly Thickness NoteTrim = new(0, -3, 0, -1);

    public ToneLabel()
    {
        InitializeComponent();
    }

    /// <summary>Its words as a screen reader and the UI tests find them.</summary>
    public string Id
    {
        set => AutomationProperties.SetAutomationId(Words, value);
    }

    /// <summary>A note: words that wrap.</summary>
    public void ShowNote(Note note, double size = 12)
    {
        Words.Text = note.Text;
        Words.FontSize = size;
        Words.TextWrapping = TextWrapping.Wrap;
        Words.LineHeight = NoteLineHeight;
        Words.LineStackingStrategy = LineStackingStrategy.BlockLineHeight;
        Words.Margin = NoteTrim;
        Glyph.Visibility = Visibility.Collapsed;
        Tone(note.Tone);
    }

    /// <summary>A status: its symbol and words on one line.</summary>
    public void ShowStatus(Status status, double size = 13)
    {
        Words.Text = status.Text;
        Words.FontSize = size;
        Words.TextWrapping = TextWrapping.NoWrap;
        Words.ClearValue(TextBlock.LineHeightProperty);
        Words.ClearValue(TextBlock.LineStackingStrategyProperty);
        Words.Margin = default;
        Glyph.Glyph = Glyphs.For(status.Symbol);
        Glyph.FontSize = size - 1;
        Glyph.Visibility = Visibility.Visible;
        Tone(status.Tone);
    }

    /// <summary>Words in danger red, as the Mac shows a login item it couldn't change.</summary>
    public void ShowProblem(string text) => ShowNote(new Note { Text = text, Tone = Tones.Danger });

    void Tone(string? tone)
    {
        var name = Tones.For(tone);
        VisualStateManager.GoToState(this, char.ToUpperInvariant(name[0]) + name[1..], false);
    }
}
