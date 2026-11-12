using System.Diagnostics;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.Foundation;
using Windows.Graphics;
using Windows.System;
using Feed = ContextGuard.Feed;

namespace ContextGuard.App;

/// <summary>
/// The left-click flyout: the Mac's menu (On, the settings in a line, the sessions, Settings…, Quit) in a
/// window above the notification area. It takes focus while open and hides when it loses it or on Esc, as
/// Windows' own flyouts do. A click on a session opens it in place; buttons act and hide the flyout,
/// switches act and leave it open. A board that arrives while it's open redraws it, keeping the open session.
/// </summary>
public sealed partial class FlyoutWindow : Window
{
    const double WidthDip = 360, MarginDip = 12, MaxShareOfWorkArea = 0.7;
    /// <summary>A click on the icon that closed the flyout (by taking focus from it) arrives this soon after.</summary>
    const double ReopenGuardMs = 300;

    readonly App app;
    readonly nint hwnd;
    readonly Dictionary<string, SessionRowView> rows = new(StringComparer.Ordinal);
    Feed.Board? board;
    bool programDown, visible, rendering, closingForQuit;
    string? expanded;
    /// <summary>How the first control is to show focus, until it has it (see <see cref="FocusFirst"/>).</summary>
    FocusState? pendingFocus;
    long hiddenAt;
    RectInt32 placed;

    public FlyoutWindow(App app)
    {
        this.app = app;
        InitializeComponent();
        hwnd = Win32Interop.GetWindowFromWindowId(AppWindow.Id);
        Chrome();
        Activated += (_, e) =>
        {
            if (e.WindowActivationState != WindowActivationState.Deactivated) FocusFirst();
            else if (visible) Hide();
        };
        AppWindow.Closing += (_, e) =>
        {
            // Alt+F4 hides it like Esc; only Quit closes it.
            if (closingForQuit) return;
            e.Cancel = true;
            Hide();
        };
        Body.SizeChanged += (_, _) => { if (visible) Fit(); };
        Root.Loaded += (_, _) =>
        {
            Root.XamlRoot.Changed += (_, _) => { if (visible) Fit(); };
            FocusFirst();
        };
    }

    /// <summary>
    /// No caption or frame, a fixed size, always on top, not in the taskbar or Alt+Tab, rounded. Its own presenter:
    /// under Native AOT <c>AppWindow.Presenter</c> comes back as the base type, so settings made through an
    /// <c>is OverlappedPresenter</c> check are skipped (W9).
    /// </summary>
    void Chrome()
    {
        var presenter = OverlappedPresenter.Create();
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.IsAlwaysOnTop = true;
        presenter.SetBorderAndTitleBar(true, false);
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;
        var result = Native.RoundCorners(hwnd);   // after SetPresenter, which sets its own frame
        if (result != 0) Log.Write($"flyout: round corners 0x{result:X}");
        Frameless.Apply(hwnd, noActivate: false);
    }

    /// <summary>
    /// A click on the icon: shows the flyout, or hides it if it's showing. Opened from the keyboard, its first
    /// control shows that it has focus, as in Windows' own flyouts; opened with a click, it doesn't.
    /// </summary>
    internal void Toggle(Feed.Board? newBoard, bool down, bool keyboard)
    {
        if (visible)
        {
            Hide();
            return;
        }
        if (hiddenAt != 0 && Stopwatch.GetElapsedTime(hiddenAt).TotalMilliseconds < ReopenGuardMs) return;
        // As a menu does, it opens with every session closed.
        expanded = null;
        Render(newBoard, down);
        visible = true;
        Fit();
        pendingFocus = keyboard ? FocusState.Keyboard : FocusState.Pointer;
        AppWindow.Show(true);
        Fit();   // shown, Windows can say how much of its frame is invisible
        Activate();
        Native.SetForegroundWindow(hwnd);
        FocusFirst();
    }

    /// <summary>
    /// Focus on the first control, so Esc, Tab and a screen reader start inside the flyout. The first time it
    /// opens, its content isn't loaded yet when it's shown and <c>Focus</c> fails, so this runs again once it
    /// has loaded and once the window is active.
    /// </summary>
    void FocusFirst()
    {
        if (pendingFocus is not { } state || !visible || !Root.IsLoaded) return;
        Control first = BoardPart.Visibility == Visibility.Visible ? OnSwitch : QuitButton;
        if (first.Focus(state)) pendingFocus = null;
    }

    internal void Hide()
    {
        if (!visible) return;
        visible = false;
        pendingFocus = null;
        hiddenAt = Stopwatch.GetTimestamp();
        AppWindow.Hide();
    }

    internal void CloseForQuit()
    {
        closingForQuit = true;
        visible = false;
        Close();
    }

    /// <summary>Draws a board, or says the program isn't running when there's none to draw.</summary>
    internal void Render(Feed.Board? newBoard, bool down)
    {
        board = newBoard;
        programDown = down;
        rendering = true;
        try
        {
            var menu = board is { } b && !programDown ? b.Menu : null;
            NotRunningText.Text = App.NotRunning;
            NotRunningText.Visibility = menu is null ? Visibility.Visible : Visibility.Collapsed;
            BoardPart.Visibility = menu is null ? Visibility.Collapsed : Visibility.Visible;
            QuitButton.Content = board?.Menu.Quit ?? App.QuitFallback;
            if (menu is null) return;

            OnLabel.Text = menu.On.Label;
            OnSwitch.IsOn = menu.On.On;
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(OnSwitch, menu.On.Label);
            LinesText.Text = string.Join("\n", menu.Lines);
            LinesText.Visibility = menu.Lines.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

            // As on the Mac: "No sessions running" in place of the heading and the list.
            var empty = menu.Sessions.Count == 0;
            HeadingText.Text = menu.Heading;
            HeadingText.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
            EmptyText.Text = menu.Empty ?? "";
            EmptyText.Visibility = empty && menu.Empty is not null ? Visibility.Visible : Visibility.Collapsed;
            RenderSessions(menu.Sessions);

            SettingsButton.Content = menu.Settings;
        }
        finally
        {
            rendering = false;
        }
    }

    /// <summary>The list in the board's order, reusing each session's row, so the pointer and focus stay put.</summary>
    void RenderSessions(IReadOnlyList<Feed.Session> sessions)
    {
        if (expanded is not null && !sessions.Any(s => s.Id == expanded)) expanded = null;
        var keep = new HashSet<string>(sessions.Select(s => s.Id), StringComparer.Ordinal);
        foreach (var gone in rows.Keys.Where(id => !keep.Contains(id)).ToList()) rows.Remove(gone);
        for (var i = 0; i < sessions.Count; i++)
        {
            var s = sessions[i];
            if (!rows.TryGetValue(s.Id, out var row))
            {
                row = new SessionRowView();
                row.RowClicked += OnRowClicked;
                row.Acted += OnActed;
                rows[s.Id] = row;
            }
            row.Show(s, s.Id == expanded);
            var at = SessionList.Children.IndexOf(row);
            if (at == i) continue;
            if (at >= 0) SessionList.Children.RemoveAt(at);
            SessionList.Children.Insert(i, row);
        }
        while (SessionList.Children.Count > sessions.Count) SessionList.Children.RemoveAt(SessionList.Children.Count - 1);
    }

    void OnRowClicked(SessionRowView row)
    {
        expanded = row.Expanded ? null : row.Id;
        if (board is not null) RenderSessions(board.Menu.Sessions);
    }

    void OnActed(Feed.Intent intent, bool hide)
    {
        app.Send(intent);
        if (hide) Hide();
    }

    void OnToggled(object sender, RoutedEventArgs e)
    {
        // Only you, never a new board, switches it.
        if (!rendering) app.Send(Feed.Intent.Enable(OnSwitch.IsOn));
    }

    void OnQuit(object sender, RoutedEventArgs e) => app.Quit();

    void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Escape) return;
        e.Handled = true;
        Hide();
    }

    /// <summary>
    /// Bottom right of the primary work area, above the taskbar, what you see of it 12 DIP from the edges: as wide
    /// as a Windows 11 flyout and as tall as what it shows, up to 70 % of the work area (then it scrolls). Sized from the monitor's DPI: a window
    /// that was hidden keeps a stale DPI of its own (W9).
    /// </summary>
    void Fit()
    {
        var scale = Native.MonitorDpi(hwnd) / 96.0;
        var area = DisplayArea.Primary.WorkArea;
        Body.Measure(new Size(WidthDip, double.PositiveInfinity));
        var heightDip = Math.Min(Body.DesiredSize.Height, area.Height * MaxShareOfWorkArea / scale);
        var margin = (int)Math.Round(MarginDip * scale);
        var (rect, _) = Placement.BottomRight(hwnd, (int)Math.Round(WidthDip * scale), (int)Math.Ceiling(heightDip * scale),
            area.X + area.Width - margin, area.Y + area.Height - margin);
        if (Placement.Same(rect, placed)) return;
        placed = rect;
        AppWindow.MoveAndResize(rect);
    }
}
