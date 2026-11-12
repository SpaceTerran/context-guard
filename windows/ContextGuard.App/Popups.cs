using Microsoft.UI.Windowing;
using Windows.Graphics;
using Feed = ContextGuard.Feed;

namespace ContextGuard.App;

/// <summary>
/// The board's popups and notices, a window each, kept while the board keeps its key and closed when it drops it.
/// They stack at the bottom right of the primary screen, above the taskbar, in the board's order: the newest nearest
/// the corner, as Windows' notifications stack (the Mac stacks down from the top right, under the menu bar).
/// </summary>
sealed class Popups(Action<Feed.Intent> act)
{
    const double MarginDip = 12, GapDip = 10;

    readonly Dictionary<string, PopupWindow> windows = new(StringComparer.Ordinal);
    List<PopupWindow> order = [];

    /// <summary>The board's popups, top to bottom; none closes them all.</summary>
    public void Show(IReadOnlyList<Feed.Popup> popups)
    {
        var keep = popups.Select(p => p.Key).ToHashSet(StringComparer.Ordinal);
        foreach (var gone in windows.Keys.Where(key => !keep.Contains(key)).ToList())
        {
            windows[gone].Close();
            windows.Remove(gone);
        }
        var next = new List<PopupWindow>(popups.Count);
        foreach (var popup in popups)
        {
            if (!windows.TryGetValue(popup.Key, out var window)) windows[popup.Key] = window = new PopupWindow(act, Restack);
            window.Show(popup);
            if (!next.Contains(window)) next.Add(window);
        }
        order = next;
        // Placed before a new one shows, so it appears where it belongs; placed again once shown, when Windows can
        // say how much of its frame is invisible.
        Restack();
        foreach (var window in order) window.Appear();
        Restack();
    }

    /// <summary>A setting changed (theme, high contrast, the work area, the display): edges and places again.</summary>
    public void SettingsChanged()
    {
        foreach (var window in order) window.SettingsChanged();
        Restack();
    }

    /// <summary>
    /// Bottom up from the corner: the last popup nearest it, what you see of each 12 DIP from the edges of the work
    /// area (which leaves out the taskbar) and 10 DIP from the next. Sized from the primary monitor's DPI: a window
    /// that hasn't been shown yet has no DPI of its own worth reading (W9).
    /// </summary>
    void Restack()
    {
        if (order.Count == 0) return;
        var scale = Native.PrimaryMonitorDpi() / 96.0;
        int Px(double dip) => (int)Math.Round(dip * scale);
        var area = DisplayArea.Primary.WorkArea;
        var right = area.X + area.Width - Px(MarginDip);
        var bottom = area.Y + area.Height - Px(MarginDip);
        for (var i = order.Count - 1; i >= 0; i--)
        {
            var (rect, top) = order[i].At(scale, right, bottom);
            order[i].Place(rect);
            bottom = top - Px(GapDip);
        }
    }
}
