using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Feed = ContextGuard.Feed;

namespace ContextGuard.App;

/// <summary>
/// What a popup window shows: a board's question (until it's answered, then how that is going) or a notice. It
/// draws the board's words and says what was clicked; <see cref="Popups"/> sends it.
/// </summary>
public sealed partial class PopupView : UserControl
{
    /// <summary>The gauge, cut out of the planet's disc as on the tray's asking icon: the Mac's <c>gauge.with.needle.fill</c>.</summary>
    const string Gauge = "\uEC4A";

    readonly MiddleTrim small;
    Feed.Popup popup = null!;
    string badgeState = "BadgePlanet", markState = "MarkMuted";

    public PopupView()
    {
        InitializeComponent();
        small = new MiddleTrim(SmallText, TextColumn);
        // The whole title, when the line cuts it short.
        LineText.IsTextTrimmedChanged += (_, _) => ToolTipService.SetToolTip(LineText, LineText.IsTextTrimmed ? LineText.Text : null);
        Loaded += (_, _) => GoToStates();
    }

    /// <summary>A button was clicked: what to send.</summary>
    internal event Action<Feed.Intent>? Acted;

    /// <summary>What a screen reader calls the popup's window.</summary>
    internal string Title { get; private set; } = "";

    internal void Show(Feed.Popup p)
    {
        popup = p;
        if (p.Question is { } question) Show(question);
        else if (p.Notice is { } notice) Show(notice);
        GoToStates();
    }

    /// <summary>The Mac's QuestionView: the session, then the question and its answers, or how the answer is going.</summary>
    void Show(Feed.Question q)
    {
        Title = $"{q.Heading}, {q.Title}";
        BadgeGlyph.Glyph = Gauge;
        badgeState = "BadgePlanet";
        HeadingText.Text = q.Heading;
        Line(q.Title, lines: 1, "Title");
        Small(q.Subtitle, "Subtitle");
        Show(CaptionText, null);
        // Hiding a question that's about to compact by itself would hide that: no ✕ while it counts down.
        Close(q.Ask?.Hide?.Label, q.Ask?.Hide?.Help);

        var ask = q.Ask;
        AskPart.Visibility = Answers.Visibility = ask is null ? Visibility.Collapsed : Visibility.Visible;
        if (ask is not null)
        {
            AskText.Text = ask.Text;
            // The save message the session gets, as the Mac's tooltip.
            ToolTipService.SetToolTip(AskText, ask.Help);
            CountdownRow.Visibility = ask.Countdown is null ? Visibility.Collapsed : Visibility.Visible;
            CountdownText.Text = ask.Countdown ?? "";
            Answer(TurnOffButton, ask.TurnOff.Label, ask.TurnOff.Help);
            Answer(DeferralButton, ask.Deferral.Label, ask.Deferral.Help);
            Answer(CompactButton, ask.Compact.Label, ask.Compact.Help);
        }

        var progress = ask is null ? q.Progress : null;
        ProgressPart.Visibility = progress is null ? Visibility.Collapsed : Visibility.Visible;
        var working = progress?.Mark == "working";
        Spinner.IsActive = working;
        Spinner.Visibility = working ? Visibility.Visible : Visibility.Collapsed;
        var icon = progress is { Mark: "icon", Symbol: { } symbol } ? Feed.Glyphs.For(symbol) : null;
        MarkGlyph.Glyph = icon ?? "";
        MarkGlyph.Visibility = icon is null ? Visibility.Collapsed : Visibility.Visible;
        markState = "Mark" + Pascal(Feed.Tones.For(progress?.Tone));
        ProgressText.Text = progress?.Text ?? "";
    }

    /// <summary>The Mac's NoticeView: its symbol in its tone, what happened, to which session, and why or where.</summary>
    void Show(Feed.Notice n)
    {
        Title = $"{n.Title}, {n.Detail}";
        BadgeGlyph.Glyph = Feed.Glyphs.For(n.Symbol);
        badgeState = "Badge" + Pascal(Feed.Tones.For(n.Tone));
        HeadingText.Text = n.Title;
        Line(n.Detail, lines: 2, "Detail");
        // A reason wraps; a name and folder stays on one line, cut in the middle.
        Small(n.CaptionWraps ? null : n.Caption, "Caption");
        Show(CaptionText, n.CaptionWraps ? n.Caption : null);
        Close(n.Close, n.Close);
        AskPart.Visibility = Answers.Visibility = ProgressPart.Visibility = Visibility.Collapsed;
        Spinner.IsActive = false;
    }

    void Line(string text, int lines, string automationId)
    {
        LineText.Text = text;
        LineText.MaxLines = lines;
        LineText.TextWrapping = lines == 1 ? TextWrapping.NoWrap : TextWrapping.Wrap;
        AutomationProperties.SetAutomationId(LineText, automationId);
    }

    void Small(string? text, string automationId)
    {
        small.Text = text ?? "";
        SmallText.Visibility = string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;
        AutomationProperties.SetAutomationId(SmallText, automationId);
    }

    static void Show(TextBlock block, string? text)
    {
        block.Text = text ?? "";
        block.Visibility = string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;
    }

    /// <summary>The ✕, when there is one: what a screen reader calls it, and its tooltip.</summary>
    void Close(string? label, string? help)
    {
        CloseButton.Visibility = label is null ? Visibility.Collapsed : Visibility.Visible;
        AutomationProperties.SetName(CloseButton, label ?? "");
        ToolTipService.SetToolTip(CloseButton, help);
    }

    static void Answer(Button button, string label, string? help)
    {
        button.Content = label;
        ToolTipService.SetToolTip(button, help);
    }

    void GoToStates()
    {
        VisualStateManager.GoToState(this, badgeState, false);
        VisualStateManager.GoToState(this, markState, false);
    }

    static string Pascal(string name) => char.ToUpperInvariant(name[0]) + name[1..];

    void OnCompact(object sender, RoutedEventArgs e)
    {
        if (popup.Question is { } q) Acted?.Invoke(Feed.Intent.Answer(q.Session, Feed.AnswerAction.Yes, Feed.AnswerSource.Popup));
    }

    void OnDeferral(object sender, RoutedEventArgs e)
    {
        if (popup.Question is { Ask: { } ask } q) Acted?.Invoke(Feed.Intent.Answer(q.Session, ask.Deferral.Answer, Feed.AnswerSource.Popup));
    }

    void OnTurnOff(object sender, RoutedEventArgs e) => Acted?.Invoke(Feed.Intent.TurnOff());

    /// <summary>✕: a question hides until it asks again; a notice closes.</summary>
    void OnClose(object sender, RoutedEventArgs e) =>
        Acted?.Invoke(popup.Question is { } q ? Feed.Intent.Hide(q.Session) : Feed.Intent.Close(popup.Key));
}
