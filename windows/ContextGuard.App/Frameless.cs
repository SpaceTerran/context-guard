using System.Runtime.InteropServices;

namespace ContextGuard.App;

/// <summary>
/// A window whose frame is only its 1 px edge, drawn by Windows (in the color asked for with
/// <c>DWMWA_BORDER_COLOR</c>), with its round corners. A captioned window's frame is
/// otherwise 7 px more on the left, right and bottom, invisible yet part of its rect, and drawn in full (grey) in
/// high contrast. A popup is also never activated by a click (spike W9).
/// </summary>
static unsafe class Frameless
{
    const nuint NoActivate = 1;
    const int Edge = 1;

    /// <summary>After the presenter is set (it sets its own frame).</summary>
    public static void Apply(nint hwnd, bool noActivate)
    {
        if (!Native.SetWindowSubclass(hwnd, &Proc, 1, noActivate ? NoActivate : 0))
        {
            Log.Write("window: no subclass; it keeps its frame" + (noActivate ? " and a click may activate it" : ""));
            return;
        }
        // The frame is worked out again now: just the edge.
        Native.SetWindowPos(hwnd, 0, 0, 0, 0, 0,
            Native.SWP_FRAMECHANGED | Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOZORDER | Native.SWP_NOOWNERZORDER | Native.SWP_NOACTIVATE);
    }

    [UnmanagedCallersOnly]
    static nint Proc(nint hwnd, uint msg, nint wParam, nint lParam, nuint id, nuint data)
    {
        switch (msg)
        {
            // The proposed client rect is the window rect: 1 px in from it, for the edge.
            case Native.WM_NCCALCSIZE when wParam != 0:
                var client = (Native.RECT*)lParam;
                client->Left += Edge;
                client->Top += Edge;
                client->Right -= Edge;
                client->Bottom -= Edge;
                return 0;
            // A click asks the top-level window whether to activate it (the XAML island's own window passes it up).
            case Native.WM_MOUSEACTIVATE when data == NoActivate:
                return Native.MA_NOACTIVATE;
            case Native.WM_NCDESTROY:
                Native.RemoveWindowSubclass(hwnd, &Proc, id);
                break;
        }
        return Native.DefSubclassProc(hwnd, msg, wParam, lParam);
    }
}
