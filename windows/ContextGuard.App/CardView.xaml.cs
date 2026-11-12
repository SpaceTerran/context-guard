using ContextGuard.Feed;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace ContextGuard.App;

/// <summary>
/// One card of a Settings tab. A board with the same rows (by kind and id) updates them in place, so a box you're
/// typing in keeps its focus and caret; a board with other rows builds them again.
/// </summary>
public sealed partial class CardView : UserControl
{
    /// <summary>A view per row, in the board's order (null for a kind of row this build doesn't know).</summary>
    readonly List<FrameworkElement?> views = [];
    string shape = "";

    public CardView()
    {
        InitializeComponent();
    }

    internal ISettingsHost Host { private get; init; } = null!;

    /// <summary>What the card is made of: its title and its rows' kinds and ids.</summary>
    internal static string Shape(Card card) => card.Title + "|" + string.Join(",", card.Rows.Select(RowKey));

    static string RowKey(Row row) => row switch
    {
        { Toggle: { } toggle } => "toggle:" + toggle.Id,
        { Login: not null } => "login",
        { Status: { } status } => "status:" + status.Label,
        { Note: not null } => "note",
        { Field: { } field } => "field:" + field.Id,
        { Text: { } text } => "text:" + text.Id,
        _ => "?",
    };

    /// <param name="id">Where the AutomationIds of its parts start: <c>&lt;tab&gt;.Card&lt;n&gt;</c>.</param>
    internal void Show(Card card, string id)
    {
        Title.Text = card.Title.ToUpperInvariant();
        AutomationProperties.SetName(Title, card.Title);
        AutomationProperties.SetAutomationId(Title, id);
        if (card.Status is { } status)
        {
            SaveStatus.ShowStatus(status, 12);
            SaveStatus.Id = id + ".Status";
            SaveStatus.Visibility = Visibility.Visible;
        }
        else
        {
            SaveStatus.Visibility = Visibility.Collapsed;
        }

        var newShape = Shape(card);
        if (newShape != shape)
        {
            Build(card);
            shape = newShape;
        }
        var notes = 0;
        for (var i = 0; i < card.Rows.Count; i++)
        {
            var row = card.Rows[i];
            switch (views[i])
            {
                case SwitchRowView view:
                    view.Show(row);
                    break;
                case StatusRowView view when row.Status is { } statusRow:
                    view.Show(statusRow, id);
                    break;
                case ToneLabel view when row.Note is { } note:
                    view.ShowNote(note);
                    view.Id = $"{id}.Note{++notes}";
                    break;
                case FieldRowView view when row.Field is { } field:
                    view.Show(field);
                    break;
                case MessageRowView view when row.Text is { } text:
                    view.Show(text);
                    break;
            }
        }
    }

    /// <summary>Open at login as Windows has it now, in each switch row that shows it.</summary>
    internal void Refresh()
    {
        foreach (var view in views) (view as SwitchRowView)?.Refresh();
    }

    void Build(Card card)
    {
        Rows.Children.Clear();
        views.Clear();
        foreach (var row in card.Rows)
        {
            FrameworkElement? view = row switch
            {
                { Toggle: not null } or { Login: not null } => new SwitchRowView { Host = Host },
                { Status: not null } => new StatusRowView(),
                { Note: not null } => new ToneLabel { Margin = new Thickness(16, 12, 16, 12) },
                { Field: not null } => new FieldRowView { Host = Host },
                { Text: not null } => new MessageRowView { Host = Host },
                _ => null,
            };
            views.Add(view);
            if (view is null)
            {
                Log.Write($"settings: a row this build doesn't know, in '{card.Title}'");
                continue;
            }
            if (Rows.Children.Count > 0) Rows.Children.Add(new RuleView());
            Rows.Children.Add(view);
        }
    }
}
