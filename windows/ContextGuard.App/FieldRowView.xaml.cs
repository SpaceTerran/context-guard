using ContextGuard.Feed;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace ContextGuard.App;

/// <summary>
/// A number that saves as you type: each change sends the box's whole text (<see cref="Intent.Set"/>); − and +
/// send <see cref="Intent.Step"/>. What you type is never overwritten by a board that answers an older keystroke:
/// while a <c>set</c> from this box is unanswered the board's text is ignored, and after that the box keeps its own
/// text while the board's number agrees with it ("0300" is 300), as the Mac's NumberField does.
/// </summary>
public sealed partial class FieldRowView : UserControl
{
    /// <summary>The app's words for − and +, as the Mac's NumberField's help.</summary>
    internal const string LessWord = "Less", MoreWord = "More";

    string id = "";
    /// <summary>The text last shown or sent, so a change made here isn't sent back.</summary>
    string lastText = "";
    int unanswered;

    public FieldRowView()
    {
        InitializeComponent();
        ToolTipService.SetToolTip(Less, LessWord);
        ToolTipService.SetToolTip(More, MoreWord);
    }

    internal ISettingsHost Host { private get; init; } = null!;

    internal void Show(Field field)
    {
        id = field.Id;
        Label.Text = field.Label;
        Unit.Text = field.Unit;
        AutomationProperties.SetAutomationId(Box, field.Id);
        AutomationProperties.SetName(Box, field.Label);
        AutomationProperties.SetAutomationId(Less, field.Id + ".Less");
        AutomationProperties.SetName(Less, $"{LessWord}: {field.Label}");
        AutomationProperties.SetAutomationId(More, field.Id + ".More");
        AutomationProperties.SetName(More, $"{MoreWord}: {field.Label}");
        VisualStateManager.GoToState(this, field.Invalid ? "Invalid" : "Valid", false);

        var typing = Box.FocusState != FocusState.Unfocused;
        if (typing && (unanswered > 0 || Parse(Box.Text) == field.Value)) return;
        if (Box.Text == field.Text) return;
        lastText = field.Text;
        Box.Text = field.Text;
        if (typing) Box.SelectionStart = Box.Text.Length;
    }

    /// <summary>A number as Core reads what was typed: <c>max(Int(trimmed) ?? 0, 0)</c>.</summary>
    internal static int Parse(string typed) =>
        int.TryParse(TrimSpaces(typed), System.Globalization.NumberStyles.AllowLeadingSign, System.Globalization.CultureInfo.InvariantCulture, out var n)
            ? Math.Max(n, 0)
            : 0;

    /// <summary>Swift's <c>trimmingCharacters(in: .whitespaces)</c>: tabs and space separators, not line breaks.</summary>
    static string TrimSpaces(string s)
    {
        static bool Space(char c) => c == '\t' || char.GetUnicodeCategory(c) == System.Globalization.UnicodeCategory.SpaceSeparator;
        int start = 0, end = s.Length;
        while (start < end && Space(s[start])) start++;
        while (end > start && Space(s[end - 1])) end--;
        return s[start..end];
    }

    async void OnTextChanged(object sender, TextChangedEventArgs e)
    {
        // Raised after the change, also for one made by Show.
        if (Box.Text == lastText) return;
        lastText = Box.Text;
        unanswered++;
        try
        {
            await Host.Send(Intent.Set(id, Box.Text));
        }
        finally
        {
            unanswered--;
        }
    }

    void OnLess(object sender, RoutedEventArgs e) => _ = Host.Send(Intent.Step(id, up: false));

    void OnMore(object sender, RoutedEventArgs e) => _ = Host.Send(Intent.Step(id, up: true));
}
