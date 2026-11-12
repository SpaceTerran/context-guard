using Windows.Graphics;

namespace ContextGuard.App;

/// <summary>
/// Places a window by what you see of it. A framed window's rect reaches past its visible edge by the part of the
/// frame Windows keeps invisible (7 px left, right and below at 100 %), so a rect put 12 px from the screen's edge
/// would look 19 px away. The app's windows are <see cref="Frameless"/>, so what you see is their rect, unless
/// Windows refused the subclass that takes the frame away.
/// </summary>
static class Placement
{
    /// <summary>
    /// The window rect that shows a client area of this size (pixels) with its visible right and bottom edges at
    /// <paramref name="right"/> and <paramref name="bottom"/>, and where its visible top edge then is.
    /// </summary>
    public static (RectInt32 Window, int VisibleTop) BottomRight(nint hwnd, int clientWidth, int clientHeight, int right, int bottom)
    {
        var (frameWidth, frameHeight) = Native.FrameSize(hwnd);
        var invisible = Native.InvisibleFrame(hwnd, frameWidth, frameHeight);
        var width = clientWidth + frameWidth;
        var height = clientHeight + frameHeight;
        var x = right + invisible.Right - width;
        var y = bottom + invisible.Bottom - height;
        return (new RectInt32(x, y, width, height), y + invisible.Top);
    }

    public static bool Same(RectInt32 a, RectInt32 b) => a.X == b.X && a.Y == b.Y && a.Width == b.Width && a.Height == b.Height;
}
