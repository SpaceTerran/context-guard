using ContextGuard.Feed;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;

namespace ContextGuard.App;

/// <summary>
/// A message that saves as you type: each change sends the box's whole text (<see cref="Intent.Set"/>); Restore
/// Default sends <see cref="Intent.Restore"/>. As with a number (<see cref="FieldRowView"/>), what you type is never
/// overwritten by a board that answers an older keystroke: while a <c>set</c> from this box is unanswered the
/// board's text is ignored, and after that a box you're typing in keeps its text while the board's is the same.
/// The box is a RichEditBox kept to plain text, for the Mac's line spacing (a TextBox can't space lines).
/// </summary>
public sealed partial class MessageRowView : UserControl
{
    /// <summary>
    /// The Mac's editor lines, 19 apart (its 13-point line plus <c>lineSpacing(3)</c>), in the points RichEdit takes.
    /// </summary>
    const float LinePoints = 19 * 72f / 96;

    string id = "";
    /// <summary>The box's text as last shown or sent, so a change made here isn't sent back.</summary>
    string lastText = "";
    int unanswered;
    /// <summary>Show is putting the board's text in the box: its own change events aren't typing.</summary>
    bool showing;

    public MessageRowView()
    {
        InitializeComponent();
        var format = Box.Document.GetDefaultParagraphFormat();
        format.SetLineSpacing(LineSpacingRule.Exactly, LinePoints);
        Box.Document.SetDefaultParagraphFormat(format);
        Space();
    }

    internal ISettingsHost Host { private get; init; } = null!;

    internal void Show(TextRow row)
    {
        id = row.Id;
        AutomationProperties.SetAutomationId(Box, row.Id);
        AutomationProperties.SetName(Box, row.Label);
        Note.ShowNote(row.Note);
        Note.Id = row.Id + ".Note";
        Restore.Content = row.Restore.Label;
        Restore.IsEnabled = row.Restore.Enabled;
        ToolTipService.SetToolTip(Restore, row.Restore.Help);
        AutomationProperties.SetAutomationId(Restore, row.Id + ".Restore");
        AutomationProperties.SetHelpText(Restore, row.Restore.Help);

        var typing = Box.FocusState != FocusState.Unfocused;
        if (typing && unanswered > 0) return;
        if (Lines(BoxText) == row.Text) return;
        showing = true;
        try
        {
            Box.Document.SetText(TextSetOptions.None, row.Text);
            Space();
            lastText = BoxText;
            if (typing) Box.Document.Selection.SetRange(TextConstants.MaxUnitCount, TextConstants.MaxUnitCount);
        }
        finally
        {
            showing = false;
        }
    }

    /// <summary>
    /// The text with the Mac's line breaks: a message is sent to the session as typed, so it is saved with <c>\n</c>,
    /// as the Mac saves it (RichEdit keeps a line break as a carriage return).
    /// </summary>
    internal static string Lines(string boxText) => boxText.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n');

    /// <summary>The box's text, without RichEdit's final paragraph mark.</summary>
    string BoxText
    {
        get
        {
            Box.Document.GetText(TextGetOptions.UseLf, out var text);
            return text;
        }
    }

    /// <summary>Every line 19 apart; lines typed or pasted later take their paragraph's spacing.</summary>
    void Space()
    {
        var all = Box.Document.GetRange(0, TextConstants.MaxUnitCount);
        var format = all.ParagraphFormat;
        format.SetLineSpacing(LineSpacingRule.Exactly, LinePoints);
        all.ParagraphFormat = format;
    }

    async void OnTextChanged(object sender, RoutedEventArgs e)
    {
        // Raised after the change, also for one made by Show, and for a change of format.
        if (showing) return;
        var text = BoxText;
        if (text == lastText) return;
        lastText = text;
        unanswered++;
        try
        {
            await Host.Send(Intent.Set(id, Lines(text)));
        }
        finally
        {
            unanswered--;
        }
    }

    /// <summary>Pastes words only: a message goes to the session as text, so a pasted font or color would only show here.</summary>
    async void OnPaste(object sender, TextControlPasteEventArgs e)
    {
        e.Handled = true;
        var content = Clipboard.GetContent();
        if (!content.Contains(StandardDataFormats.Text)) return;
        var text = await content.GetTextAsync();
        var selection = Box.Document.Selection;
        selection.SetText(TextSetOptions.None, text);
        selection.Collapse(false);
    }

    void OnRestore(object sender, RoutedEventArgs e) => _ = Host.Send(Intent.Restore(id));
}
