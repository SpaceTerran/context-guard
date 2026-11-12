using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Feed = ContextGuard.Feed;

namespace ContextGuard.App;

/// <summary>
/// A session's row in the flyout. It draws the board's session and says what was clicked; the flyout
/// decides which row is open and sends the intents.
/// </summary>
public sealed partial class SessionRowView : UserControl
{
    const string ChevronDown = "\uE70D", ChevronUp = "\uE70E";

    Feed.Session session = null!;

    public SessionRowView()
    {
        InitializeComponent();
        // The full title, when the row cuts it short.
        TitleText.IsTextTrimmedChanged += (_, _) => ToolTipService.SetToolTip(Row, TitleText.IsTextTrimmed ? TitleText.Text : null);
    }

    /// <summary>The row was clicked: open it, or close it if it's open.</summary>
    internal event Action<SessionRowView>? RowClicked;
    /// <summary>A button or the Watch box: what to send, and whether the flyout closes (buttons) or stays (Watch).</summary>
    internal event Action<Feed.Intent, bool>? Acted;

    internal string Id => session.Id;

    internal bool Expanded { get; private set; }

    internal void Show(Feed.Session s, bool expanded)
    {
        session = s;
        Expanded = expanded;
        Glyph.Glyph = Feed.Glyphs.For(s.Symbol);
        TitleText.Text = s.Title;
        TokensText.Text = s.Tokens;
        Chevron.Glyph = expanded ? ChevronUp : ChevronDown;
        AutomationProperties.SetAutomationId(Row, $"Session-{s.Id}");
        AutomationProperties.SetName(Row, $"{s.Title}, {s.Tokens}");
        AutomationProperties.SetHelpText(Row, s.Status);

        Details.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
        SetText(StatusText, s.Status);
        SetText(FollowUpText, s.FollowUp);
        SetText(SubtitleText, s.Subtitle);

        CompactNow.Content = s.CompactNow.Label;
        CompactNow.IsEnabled = s.CompactNow.Enabled;
        AutomationProperties.SetAutomationId(CompactNow, $"CompactNow-{s.Id}");

        Deferral.Visibility = s.Deferral is null ? Visibility.Collapsed : Visibility.Visible;
        Deferral.Content = s.Deferral?.Label;
        ToolTipService.SetToolTip(Deferral, s.Deferral?.Help);
        AutomationProperties.SetAutomationId(Deferral, $"Deferral-{s.Id}");

        ShowQuestion.Visibility = s.ShowQuestion is null ? Visibility.Collapsed : Visibility.Visible;
        ShowQuestion.Content = s.ShowQuestion;
        AutomationProperties.SetAutomationId(ShowQuestion, $"ShowQuestion-{s.Id}");

        Watch.Content = s.Watch.Label;
        Watch.IsChecked = s.Watch.On;
        AutomationProperties.SetAutomationId(Watch, $"Watch-{s.Id}");
    }

    static void SetText(TextBlock block, string? text)
    {
        block.Text = text ?? "";
        block.Visibility = string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;
    }

    void OnRowClick(object sender, RoutedEventArgs e) => RowClicked?.Invoke(this);

    void OnCompactNow(object sender, RoutedEventArgs e) =>
        Acted?.Invoke(Feed.Intent.Answer(session.Id, Feed.AnswerAction.Yes, Feed.AnswerSource.Menu), true);

    void OnDeferral(object sender, RoutedEventArgs e)
    {
        if (session.Deferral is { } deferral) Acted?.Invoke(Feed.Intent.Answer(session.Id, deferral.Answer, Feed.AnswerSource.Menu), true);
    }

    void OnShowQuestion(object sender, RoutedEventArgs e) => Acted?.Invoke(Feed.Intent.Show(session.Id), true);

    // Click, not Checked: only what you do, never a new board, sends it.
    void OnWatch(object sender, RoutedEventArgs e) => Acted?.Invoke(Feed.Intent.Watch(session.Id, Watch.IsChecked == true), false);
}
