using ContextGuard.Feed;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.Graphics;

namespace ContextGuard.App;

/// <summary>What Settings' rows send through, and the app's own Open at login.</summary>
interface ISettingsHost
{
    /// <summary>Sends a change; the result says whether the program could make it (it beeps if not).</summary>
    Task<FeedResult> Send(Intent intent);

    LoginItem Login { get; }
}

/// <summary>
/// The Settings window, the Mac's in the brand's look: a normal window (it activates, it's on the taskbar with the
/// app's icon), 600 DIP wide and as tall as its tallest tab, not resizable, centered on the screen under the pointer
/// when it opens. It shows once the program has opened Settings (<see cref="Intent.SettingsOpen"/>) and its board has
/// them; closing it hides it and tells the program (<see cref="Intent.SettingsClose"/>). While the program is down
/// its content is off; when the program is back it is asked for Settings again.
/// </summary>
sealed class SettingsWindow : ISettingsHost
{
    const double WidthDip = 600;

    readonly App app;
    readonly Window window;
    readonly SettingsView view;
    readonly OverlappedPresenter presenter;
    readonly nint hwnd;
    nint smallIcon, bigIcon;
    uint iconDpi;
    /// <summary>Opened (shown, or waiting for the board that has Settings) and not closed since.</summary>
    bool wanted;
    bool shown, askAgain, closingForQuit, closed;
    RectInt32 placed;

    public SettingsWindow(App app, LoginItem login)
    {
        this.app = app;
        Login = login;
        view = new SettingsView { Host = this };
        window = new Window { Content = view };
        hwnd = Win32Interop.GetWindowFromWindowId(window.AppWindow.Id);

        // Its own presenter: under Native AOT AppWindow.Presenter comes back as the base type (W9).
        presenter = OverlappedPresenter.Create();
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = true;
        presenter.SetBorderAndTitleBar(true, true);
        window.AppWindow.SetPresenter(presenter);
        window.ExtendsContentIntoTitleBar = true;
        window.SetTitleBar(view.TitleBarPart);
        window.AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Standard;

        window.AppWindow.Closing += (_, e) =>
        {
            // ✕ and Alt+F4 hide it; only Quit closes it.
            if (closingForQuit) return;
            e.Cancel = true;
            Hide();
        };
        window.Activated += (_, e) =>
        {
            var active = e.WindowActivationState != WindowActivationState.Deactivated;
            view.SetActive(active);
            // It may have been changed in Windows' Startup apps meanwhile.
            if (active) view.Refresh();
        };
        view.BodySizeChanged += (_, _) =>
        {
            if (shown) Fit(center: false);
        };
        view.Loaded += (_, _) => view.XamlRoot.Changed += (_, _) =>
        {
            if (!shown) return;
            Fit(center: false);
            Icons();
        };
        view.ActualThemeChanged += (_, _) =>
        {
            CaptionColors();
            FocusBox.Redraw(view.XamlRoot);
        };
        CaptionColors();
        Icons();
    }

    public LoginItem Login { get; }

    public Task<FeedResult> Send(Intent intent) => app.SendAsync(intent);

    /// <summary>Opened and not closed since: Settings… brings it to the front rather than opening it again.</summary>
    internal bool Wanted => wanted;

    /// <summary>The program has opened Settings: shows the window once a board has them (maybe this one).</summary>
    internal void Open(Board? board, bool programDown)
    {
        if (closed || wanted) return;
        wanted = true;
        Render(board, programDown);
    }

    /// <summary>Draws a board's Settings while it's open; with the program down (or a board without them), its content is off.</summary>
    internal void Render(Board? board, bool programDown)
    {
        if (!wanted || closed) return;
        if (programDown)
        {
            view.IsEnabled = false;
            askAgain = true;
            return;
        }
        if (board?.Settings is not { } settings)
        {
            view.IsEnabled = false;
            if (askAgain)
            {
                // The program started again: a new one has no Settings open.
                askAgain = false;
                _ = Send(Intent.SettingsOpen());
            }
            return;
        }
        askAgain = false;
        view.IsEnabled = true;
        view.Show(settings);
        window.Title = settings.Title;
        if (shown)
        {
            Fit(center: false);
            return;
        }
        view.SelectFirst();
        Appear();
    }

    /// <summary>Settings… while it's open: to the front, restored if it was minimized.</summary>
    internal void Front()
    {
        if (!shown || closed) return;
        if (presenter.State == OverlappedPresenterState.Minimized) presenter.Restore();
        window.AppWindow.Show(true);
        window.Activate();
        Native.SetForegroundWindow(hwnd);
    }

    internal void CloseForQuit()
    {
        if (closed) return;
        closed = true;
        closingForQuit = true;
        wanted = shown = false;
        window.Close();
        if (smallIcon != 0) Native.DestroyIcon(smallIcon);
        if (bigIcon != 0) Native.DestroyIcon(bigIcon);
        smallIcon = bigIcon = 0;
    }

    /// <summary>The theme, high contrast or the display changed.</summary>
    internal void SettingsChanged()
    {
        CaptionColors();
        if (shown) Fit(center: false);
    }

    void Appear()
    {
        shown = true;
        Fit(center: true);
        window.AppWindow.Show(true);
        if (presenter.State == OverlappedPresenterState.Minimized) presenter.Restore();
        window.Activate();
        Native.SetForegroundWindow(hwnd);
        Fit(center: true);   // shown, Windows can say how much of its frame is invisible
        Icons();
    }

    void Hide()
    {
        if (!wanted) return;
        wanted = shown = askAgain = false;
        window.AppWindow.Hide();
        _ = Send(Intent.SettingsClose());
    }

    /// <summary>
    /// 600 DIP wide and as tall as the tallest tab plus the title bar, at most the work area (then it scrolls).
    /// Opening, it is centered on the screen under the pointer; after that its top-left stays put, unless that would
    /// take its bottom off the screen. Sized from the monitor's DPI: a hidden window keeps a stale DPI of its own (W9).
    /// </summary>
    void Fit(bool center)
    {
        if (closed) return;
        RectInt32 area;
        uint dpi;
        if (center)
        {
            Native.GetCursorPos(out var pointer);
            area = DisplayArea.GetFromPoint(new PointInt32(pointer.X, pointer.Y), DisplayAreaFallback.Nearest).WorkArea;
            dpi = Native.MonitorDpiAt(pointer);
        }
        else
        {
            area = DisplayArea.GetFromWindowId(window.AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea;
            dpi = Native.MonitorDpi(hwnd);
        }
        var scale = dpi / 96.0;
        var heightDip = view.Measure(WidthDip);
        var (frameWidth, frameHeight) = Native.FrameSize(hwnd);
        var invisible = Native.InvisibleFrame(hwnd, frameWidth, frameHeight);
        var width = (int)Math.Round(WidthDip * scale) + frameWidth;
        var visibleFrameHeight = frameHeight - invisible.Top - invisible.Bottom;
        var height = Math.Min((int)Math.Ceiling(heightDip * scale), area.Height - visibleFrameHeight) + frameHeight;
        var seenWidth = width - invisible.Left - invisible.Right;
        var seenHeight = height - invisible.Top - invisible.Bottom;

        int x, y;
        if (center)
        {
            x = area.X + (area.Width - seenWidth) / 2 - invisible.Left;
            y = area.Y + (area.Height - seenHeight) / 2 - invisible.Top;
        }
        else
        {
            var at = window.AppWindow.Position;
            x = at.X;
            y = Math.Max(area.Y - invisible.Top, Math.Min(at.Y, area.Y + area.Height - seenHeight - invisible.Top));
        }
        var rect = new RectInt32(x, y, width, height);
        if (Placement.Same(rect, placed) && Placement.Same(rect, Current())) return;
        placed = rect;
        window.AppWindow.MoveAndResize(rect);
    }

    RectInt32 Current()
    {
        var at = window.AppWindow.Position;
        var size = window.AppWindow.Size;
        return new RectInt32(at.X, at.Y, size.Width, size.Height);
    }

    /// <summary>The app's icon on the title bar's menu, the taskbar and Alt+Tab, drawn for the monitor's DPI.</summary>
    void Icons()
    {
        if (closed) return;
        var dpi = Native.MonitorDpi(hwnd);
        if (dpi == iconDpi) return;
        iconDpi = dpi;
        var small = AppIcon.Make(Native.GetSystemMetricsForDpi(Native.SM_CXSMICON, dpi));
        var big = AppIcon.Make(Native.GetSystemMetricsForDpi(Native.SM_CXICON, dpi));
        Native.SendMessage(hwnd, Native.WM_SETICON, Native.ICON_SMALL, small);
        Native.SendMessage(hwnd, Native.WM_SETICON, Native.ICON_BIG, big);
        if (smallIcon != 0) Native.DestroyIcon(smallIcon);
        if (bigIcon != 0) Native.DestroyIcon(bigIcon);
        smallIcon = small;
        bigIcon = big;
    }

    /// <summary>
    /// Windows' caption buttons in the brand's colors over its background (Close keeps Windows' red); in high
    /// contrast, Windows' own.
    /// </summary>
    void CaptionColors()
    {
        if (closed) return;
        var bar = window.AppWindow.TitleBar;
        if (Native.HighContrast())
        {
            bar.ButtonBackgroundColor = bar.ButtonInactiveBackgroundColor = null;
            bar.ButtonForegroundColor = bar.ButtonInactiveForegroundColor = null;
            bar.ButtonHoverBackgroundColor = bar.ButtonHoverForegroundColor = null;
            bar.ButtonPressedBackgroundColor = bar.ButtonPressedForegroundColor = null;
            return;
        }
        var dark = view.ActualTheme switch
        {
            ElementTheme.Dark => true,
            ElementTheme.Light => false,
            _ => Application.Current.RequestedTheme == ApplicationTheme.Dark,
        };
        Windows.UI.Color Of((uint Dark, uint Light) color)
        {
            var rgb = dark ? color.Dark : color.Light;
            return ColorHelper.FromArgb(0xFF, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);
        }
        bar.ButtonBackgroundColor = bar.ButtonInactiveBackgroundColor = Colors.Transparent;
        bar.ButtonForegroundColor = Of(BrandColors.Heading);
        bar.ButtonInactiveForegroundColor = Of(BrandColors.Disabled);
        bar.ButtonHoverBackgroundColor = Of(BrandColors.Hover);
        bar.ButtonHoverForegroundColor = Of(BrandColors.Heading);
        bar.ButtonPressedBackgroundColor = Of(BrandColors.Border);
        bar.ButtonPressedForegroundColor = Of(BrandColors.Heading);
    }
}
