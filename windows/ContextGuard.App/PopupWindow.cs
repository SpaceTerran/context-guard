using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.Foundation;
using Windows.Graphics;
using Feed = ContextGuard.Feed;

namespace ContextGuard.App;

/// <summary>
/// One popup or notice in a window of its own that never takes focus, so a click on its buttons leaves the
/// terminal you're typing in active (spike W9): <c>WS_EX_NOACTIVATE</c>, <c>MA_NOACTIVATE</c> for a click, shown
/// without activating, buttons that don't take focus. No caption, always on top, not in the taskbar or Alt+Tab (no
/// <c>WS_EX_TOOLWINDOW</c>: Windows skips tool windows on a live scale change). The brand's panel inside Windows 11's
/// rounded corners, its 1 px edge in the brand's strong border color (the theme's text color in high contrast).
/// </summary>
sealed class PopupWindow
{
    /// <summary>As wide as the Mac's popups.</summary>
    public const double WidthDip = 400;

    readonly Window window;
    readonly PopupView view;
    readonly nint hwnd;
    bool shown, closed;
    RectInt32 placed;

    /// <param name="act">Sends what was clicked.</param>
    /// <param name="restack">Its size changed (new words, a new DPI): the stack is placed again.</param>
    public PopupWindow(Action<Feed.Intent> act, Action restack)
    {
        view = new PopupView();
        view.Acted += act;
        window = new Window { Content = view };
        hwnd = Win32Interop.GetWindowFromWindowId(window.AppWindow.Id);
        Chrome();
        view.Body.SizeChanged += (_, _) => restack();
        view.Loaded += (_, _) => view.XamlRoot.Changed += (_, _) => restack();
        view.ActualThemeChanged += (_, _) => Edge();
        Edge();
    }

    public nint Handle => hwnd;

    /// <summary>
    /// No caption, a fixed size, always on top, out of the switchers; its own presenter (under Native AOT
    /// <c>AppWindow.Presenter</c> comes back as the base type, W9). Then no frame, and never activated.
    /// </summary>
    void Chrome()
    {
        var presenter = OverlappedPresenter.Create();
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.IsAlwaysOnTop = true;
        presenter.SetBorderAndTitleBar(true, false);
        window.AppWindow.SetPresenter(presenter);
        window.AppWindow.IsShownInSwitchers = false;
        var round = Native.RoundCorners(hwnd);   // after SetPresenter, which sets its own frame
        if (round != 0) Log.Write($"popup: round corners 0x{round:X}");

        var ex = Native.GetWindowLongPtr(hwnd, Native.GWL_EXSTYLE);
        Native.SetWindowLongPtr(hwnd, Native.GWL_EXSTYLE, ex | Native.WS_EX_NOACTIVATE);
        Frameless.Apply(hwnd, noActivate: true);
    }

    /// <summary>The edge's color for the theme it's drawn in; the theme's text color in high contrast.</summary>
    void Edge()
    {
        if (closed) return;
        var dark = view.ActualTheme switch
        {
            ElementTheme.Dark => true,
            ElementTheme.Light => false,
            _ => Application.Current.RequestedTheme == ApplicationTheme.Dark,
        };
        // In high contrast the theme's text color, as the brand's strong border there (Windows' own would be black).
        var color = Native.HighContrast()
            ? Native.GetSysColor(Native.COLOR_WINDOWTEXT)
            : Native.ColorRef(dark ? BrandColors.BorderStrong.Dark : BrandColors.BorderStrong.Light);
        var result = Native.BorderColor(hwnd, color);
        if (result != 0) Log.Write($"popup: border color 0x{result:X}");
    }

    /// <summary>A setting changed (high contrast, say): the edge again.</summary>
    public void SettingsChanged() => Edge();

    /// <summary>Draws the board's popup; the window's title is what a screen reader calls it.</summary>
    public void Show(Feed.Popup popup)
    {
        view.Show(popup);
        window.Title = view.Title;
    }

    /// <summary>
    /// Where its window goes, in pixels at a scale, for what you see of it to end at (right, bottom): 400 DIP wide
    /// and as tall as its words. Also where its visible top edge is then, for the next one up.
    /// </summary>
    public (RectInt32 Window, int VisibleTop) At(double scale, int right, int bottom)
    {
        view.Body.Measure(new Size(WidthDip, double.PositiveInfinity));
        var width = (int)Math.Round(WidthDip * scale);
        var height = (int)Math.Ceiling(view.Body.DesiredSize.Height * scale);
        return Placement.BottomRight(hwnd, width, height, right, bottom);
    }

    public void Place(RectInt32 rect)
    {
        if (closed || Placement.Same(rect, placed)) return;
        placed = rect;
        window.AppWindow.MoveAndResize(rect);
    }

    /// <summary>Shows it the first time, without activating it; after that it stays shown until it's closed.</summary>
    public void Appear()
    {
        if (shown || closed) return;
        shown = true;
        window.AppWindow.Show(false);
    }

    public void Close()
    {
        if (closed) return;
        closed = true;
        window.Close();
    }
}
