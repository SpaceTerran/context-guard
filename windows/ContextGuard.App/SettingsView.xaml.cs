using ContextGuard.Feed;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.Foundation;
using Windows.System;

namespace ContextGuard.App;

/// <summary>
/// The Settings window's content, drawn from <see cref="Board.Settings"/>: a tab per board tab (Ctrl+1, Ctrl+2…, as
/// the Mac's ⌘1…), each a page of cards and notes. A board with the same tabs and blocks updates the pages in place
/// (cards update their rows in place too), so what has focus keeps it.
/// </summary>
public sealed partial class SettingsView : UserControl
{
    /// <summary>The Mac's Settings width less its 24-point margins.</summary>
    const double PageWidth = 552;
    /// <summary>The Mac's spacing: 10 between blocks, 14 more before a card under a note, 10 more between two cards.</summary>
    const double BlockGap = 10, CardAfterNote = 14, CardAfterCard = 10;

    readonly List<RadioButton> tabs = [];
    readonly List<string> tabIds = [];
    readonly List<StackPanel> pages = [];
    readonly List<string> pageShapes = [];
    /// <summary>Per page, a view per block (null for a kind this build doesn't know).</summary>
    readonly List<List<FrameworkElement?>> blocks = [];
    string tabsShape = "";
    string? selected;
    bool selecting;

    public SettingsView()
    {
        InitializeComponent();
    }

    internal ISettingsHost Host { private get; init; } = null!;

    /// <summary>Where you drag the window; Windows' caption buttons are drawn over its right end.</summary>
    internal FrameworkElement TitleBarPart => TitleBar;

    internal void Show(Settings settings)
    {
        TitleText.Text = settings.Title;
        var shape = string.Join("|", settings.Tabs.Select(t => t.Id + ":" + t.Title));
        if (shape != tabsShape)
        {
            BuildTabs(settings.Tabs);
            tabsShape = shape;
        }
        for (var i = 0; i < settings.Tabs.Count; i++) ShowPage(i, settings.Tabs[i]);
        Select(selected is { } id && tabIds.Contains(id) ? id : tabIds.FirstOrDefault());
    }

    /// <summary>A fresh open starts on the first tab, as on the Mac.</summary>
    internal void SelectFirst() => Select(tabIds.FirstOrDefault());

    /// <summary>The title in the inactive color while another window is active, as Windows' own title bars.</summary>
    internal void SetActive(bool active) => VisualStateManager.GoToState(this, active ? "Active" : "Inactive", false);

    /// <summary>Open at login as Windows has it now.</summary>
    internal void Refresh()
    {
        foreach (var page in blocks)
            foreach (var view in page) (view as CardView)?.Refresh();
    }

    /// <summary>
    /// How tall the content is at a width, every page measured and the tallest kept, so a tab switch never changes
    /// the window's height.
    /// </summary>
    internal double Measure(double width)
    {
        double tallest = 0;
        foreach (var page in pages)
        {
            var was = page.Visibility;
            page.Visibility = Visibility.Visible;
            page.Measure(new Size(PageWidth, double.PositiveInfinity));
            tallest = Math.Max(tallest, page.DesiredSize.Height);
            page.Visibility = was;
        }
        Pages.MinHeight = tallest;
        Body.Measure(new Size(width, double.PositiveInfinity));
        return TitleBar.Height + Body.DesiredSize.Height;
    }

    /// <summary>Its layout settled at a new size (fonts loaded, a new board laid out).</summary>
    internal event SizeChangedEventHandler BodySizeChanged
    {
        add => Body.SizeChanged += value;
        remove => Body.SizeChanged -= value;
    }

    void BuildTabs(IReadOnlyList<Tab> list)
    {
        TabBar.Children.Clear();
        Pages.Children.Clear();
        tabs.Clear();
        tabIds.Clear();
        pages.Clear();
        pageShapes.Clear();
        blocks.Clear();
        selected = null;
        for (var i = 0; i < list.Count; i++)
        {
            var id = list[i].Id;
            // Styled by the implicit style in SettingsView.xaml.
            var tab = new RadioButton { Content = list[i].Title, GroupName = "SettingsTabs" };
            AutomationProperties.SetAutomationId(tab, "Tab." + id);
            tab.Checked += (_, _) =>
            {
                if (!selecting) Select(id);
            };
            if (i < 9)
            {
                var key = new KeyboardAccelerator { Key = (VirtualKey)((int)VirtualKey.Number1 + i), Modifiers = VirtualKeyModifiers.Control };
                key.Invoked += (_, e) =>
                {
                    e.Handled = true;
                    if (selected == id) return;
                    Select(id);
                    // As a click on it: the tab has focus (else focus would leave a hidden page for the first tab).
                    tab.Focus(FocusState.Keyboard);
                };
                tab.KeyboardAccelerators.Add(key);
                // The tooltip says it, as the Mac's ⌘1; WinUI would add it to the tooltip a second time.
                tab.KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
                ToolTipService.SetToolTip(tab, $"Ctrl+{i + 1}");
            }
            TabBar.Children.Add(tab);
            tabs.Add(tab);
            tabIds.Add(id);
            var page = new StackPanel { Visibility = Visibility.Collapsed };
            Pages.Children.Add(page);
            pages.Add(page);
            pageShapes.Add("");
            blocks.Add([]);
        }
    }

    void Select(string? id)
    {
        if (id is null) return;
        selected = id;
        selecting = true;
        try
        {
            for (var i = 0; i < tabIds.Count; i++)
            {
                var shown = tabIds[i] == id;
                tabs[i].IsChecked = shown;
                pages[i].Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
            }
        }
        finally
        {
            selecting = false;
        }
    }

    void ShowPage(int index, Tab tab)
    {
        var shape = string.Join(",", tab.Blocks.Select(b => b.Card is not null ? "card" : b.Note is not null ? "note" : "?"));
        if (shape != pageShapes[index])
        {
            BuildPage(index, tab);
            pageShapes[index] = shape;
        }
        int cards = 0, notes = 0;
        for (var i = 0; i < tab.Blocks.Count; i++)
        {
            switch (blocks[index][i])
            {
                case CardView view when tab.Blocks[i].Card is { } card:
                    view.Show(card, $"{tab.Id}.Card{++cards}");
                    break;
                case ToneLabel view when tab.Blocks[i].Note is { } note:
                    view.ShowNote(note);
                    view.Id = $"{tab.Id}.Note{++notes}";
                    break;
            }
        }
    }

    /// <summary>A page's cards and notes, spaced as the Mac's; a note sits 2 in from the cards' edges.</summary>
    void BuildPage(int index, Tab tab)
    {
        var page = pages[index];
        page.Children.Clear();
        blocks[index].Clear();
        string? before = null;
        foreach (var block in tab.Blocks)
        {
            FrameworkElement? view = block switch
            {
                { Card: not null } => new CardView { Host = Host },
                { Note: not null } => new ToneLabel(),
                _ => null,
            };
            blocks[index].Add(view);
            if (view is null)
            {
                Log.Write($"settings: a block this build doesn't know, on '{tab.Title}'");
                continue;
            }
            var card = block.Card is not null;
            var top = before is null ? 0 : BlockGap + (card ? before == "note" ? CardAfterNote : CardAfterCard : 0);
            view.Margin = new Thickness(card ? 0 : 2, top, card ? 0 : 2, 0);
            page.Children.Add(view);
            before = card ? "card" : "note";
        }
    }
}
