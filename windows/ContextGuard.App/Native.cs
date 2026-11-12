using System.Runtime.InteropServices;

namespace ContextGuard.App;

// The Win32 calls the app makes, written by hand (spike W9): blittable, LibraryImport only, so
// they work under Native AOT.
static unsafe partial class Native
{
    public const uint WM_NULL = 0, WM_CLOSE = 0x0010, WM_SETTINGCHANGE = 0x001A, WM_DISPLAYCHANGE = 0x007E,
        WM_CONTEXTMENU = 0x007B, WM_APP = 0x8000, NIN_SELECT = 0x0400, NIN_KEYSELECT = 0x0401;
    public const uint NIM_ADD = 0, NIM_MODIFY = 1, NIM_DELETE = 2, NIM_SETVERSION = 4;
    public const uint NIF_MESSAGE = 1, NIF_ICON = 2, NIF_TIP = 4, NIF_SHOWTIP = 0x80;
    public const uint MF_STRING = 0, MF_CHECKED = 0x8, MF_SEPARATOR = 0x800;
    public const uint TPM_RIGHTBUTTON = 0x2, TPM_BOTTOMALIGN = 0x20, TPM_RETURNCMD = 0x100;
    public const int SM_CXSMICON = 49;
    public const uint MB_OK = 0;

    [StructLayout(LayoutKind.Sequential)]
    public struct NOTIFYICONDATAW
    {
        public uint cbSize;
        public nint hWnd;
        public uint uID;
        public uint uFlags;
        public uint uCallbackMessage;
        public nint hIcon;
        public fixed char szTip[128];
        public uint dwState;
        public uint dwStateMask;
        public fixed char szInfo[256];
        public uint uVersion;
        public fixed char szInfoTitle[64];
        public uint dwInfoFlags;
        public Guid guidItem;
        public nint hBalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WNDCLASSEXW
    {
        public uint cbSize;
        public uint style;
        public delegate* unmanaged<nint, uint, nint, nint, nint> lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public nint hInstance;
        public nint hIcon;
        public nint hCursor;
        public nint hbrBackground;
        public char* lpszMenuName;
        public char* lpszClassName;
        public nint hIconSm;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAPINFOHEADER
    {
        public uint biSize;
        public int biWidth;
        public int biHeight;
        public ushort biPlanes;
        public ushort biBitCount;
        public uint biCompression;
        public uint biSizeImage;
        public int biXPelsPerMeter;
        public int biYPelsPerMeter;
        public uint biClrUsed;
        public uint biClrImportant;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct ICONINFO
    {
        public int fIcon;
        public uint xHotspot;
        public uint yHotspot;
        public nint hbmMask;
        public nint hbmColor;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left, Top, Right, Bottom;
    }

    // Windows and messages

    [LibraryImport("user32.dll", EntryPoint = "RegisterWindowMessageW", StringMarshalling = StringMarshalling.Utf16)]
    public static partial uint RegisterWindowMessage(string name);

    [LibraryImport("user32.dll", EntryPoint = "RegisterClassExW")]
    public static partial ushort RegisterClassEx(WNDCLASSEXW* wc);

    [LibraryImport("user32.dll", EntryPoint = "CreateWindowExW", StringMarshalling = StringMarshalling.Utf16)]
    public static partial nint CreateWindowEx(uint exStyle, string className, string windowName, uint style,
        int x, int y, int width, int height, nint parent, nint menu, nint instance, nint param);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool DestroyWindow(nint hwnd);

    [LibraryImport("user32.dll", EntryPoint = "DefWindowProcW")]
    public static partial nint DefWindowProc(nint hwnd, uint msg, nint wParam, nint lParam);

    [LibraryImport("user32.dll", EntryPoint = "PostMessageW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool PostMessage(nint hwnd, uint msg, nint wParam, nint lParam);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SetForegroundWindow(nint hwnd);

    [LibraryImport("kernel32.dll", EntryPoint = "GetModuleHandleW")]
    public static partial nint GetModuleHandle(nint name);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool MessageBeep(uint type);

    [LibraryImport("user32.dll", EntryPoint = "FindWindowW", StringMarshalling = StringMarshalling.Utf16)]
    public static partial nint FindWindow(string? className, string? title);

    // The notification area

    [LibraryImport("shell32.dll", EntryPoint = "Shell_NotifyIconW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool Shell_NotifyIcon(uint message, NOTIFYICONDATAW* data);

    [LibraryImport("user32.dll")]
    public static partial nint CreatePopupMenu();

    [LibraryImport("user32.dll", EntryPoint = "AppendMenuW", StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool AppendMenu(nint menu, uint flags, nuint id, string? text);

    [LibraryImport("user32.dll")]
    public static partial int TrackPopupMenuEx(nint menu, uint flags, int x, int y, nint hwnd, nint tpm);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool DestroyMenu(nint menu);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool DestroyIcon(nint icon);

    [LibraryImport("user32.dll")]
    public static partial nint CreateIconIndirect(ICONINFO* info);

    // DPI

    [LibraryImport("user32.dll")]
    public static partial int GetSystemMetricsForDpi(int index, uint dpi);

    [LibraryImport("user32.dll")]
    public static partial nint MonitorFromWindow(nint hwnd, uint flags);

    [LibraryImport("shcore.dll")]
    public static partial int GetDpiForMonitor(nint monitor, int type, uint* dpiX, uint* dpiY);

    /// <summary>
    /// The effective DPI of the monitor a window is on (the primary one if none). Windows doesn't update a
    /// hidden window's own DPI on a live scale change (W9), so sizes come from the monitor.
    /// </summary>
    public static uint MonitorDpi(nint hwnd)
    {
        uint x, y;
        var monitor = MonitorFromWindow(hwnd, 1);   // MONITOR_DEFAULTTOPRIMARY
        return GetDpiForMonitor(monitor, 0, &x, &y) == 0 ? x : 96;   // MDT_EFFECTIVE_DPI
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X, Y;
    }

    [LibraryImport("user32.dll")]
    public static partial nint MonitorFromPoint(POINT point, uint flags);

    /// <summary>The primary monitor's effective DPI, where the popups stack.</summary>
    public static uint PrimaryMonitorDpi()
    {
        uint x, y;
        var monitor = MonitorFromPoint(default, 1);   // (0, 0) is on the primary monitor; MONITOR_DEFAULTTOPRIMARY
        return GetDpiForMonitor(monitor, 0, &x, &y) == 0 ? x : 96;
    }

    [LibraryImport("dwmapi.dll")]
    public static partial int DwmSetWindowAttribute(nint hwnd, uint attribute, void* value, uint size);

    [LibraryImport("dwmapi.dll")]
    public static partial int DwmGetWindowAttribute(nint hwnd, uint attribute, void* value, uint size);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetWindowRect(nint hwnd, RECT* rect);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetClientRect(nint hwnd, RECT* rect);

    /// <summary>How much bigger a window is than its client area, in pixels (none for a <see cref="Frameless"/> one).</summary>
    public static (int Width, int Height) FrameSize(nint hwnd)
    {
        RECT window, client;
        if (!GetWindowRect(hwnd, &window) || !GetClientRect(hwnd, &client)) return (0, 0);
        return (Math.Max(0, window.Right - window.Left - client.Right), Math.Max(0, window.Bottom - window.Top - client.Bottom));
    }

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool IsWindowVisible(nint hwnd);

    /// <summary>
    /// How far a window's rect reaches past what you see of it, on each side: Windows draws a 1 px edge and keeps
    /// the rest of a frame invisible (7 px left, right and below at 100 %; none without a frame, see
    /// <see cref="Frameless"/>). Windows are placed by what you see.
    /// Until a window is shown DWM can't say, so then it's worked out from the frame (all of it but the 1 px edge on
    /// the left, right and bottom; none on top), and the window is placed again once shown.
    /// </summary>
    public static RECT InvisibleFrame(nint hwnd, int frameWidth, int frameHeight)
    {
        RECT window, visible;
        if (IsWindowVisible(hwnd) && GetWindowRect(hwnd, &window) && DwmGetWindowAttribute(hwnd, 9, &visible, (uint)sizeof(RECT)) == 0)   // DWMWA_EXTENDED_FRAME_BOUNDS
        {
            return new RECT
            {
                Left = visible.Left - window.Left, Top = visible.Top - window.Top,
                Right = window.Right - visible.Right, Bottom = window.Bottom - visible.Bottom,
            };
        }
        var side = Math.Max(0, (frameWidth - 2) / 2);
        return new RECT { Left = side, Top = 0, Right = side, Bottom = Math.Max(0, frameHeight - 1) };
    }

    /// <summary>Windows 11 rounds captioned windows by itself; a window without a caption has to ask.</summary>
    public static int RoundCorners(nint hwnd)
    {
        var round = 2;   // DWMWA_WINDOW_CORNER_PREFERENCE (33) = DWMWCP_ROUND
        return DwmSetWindowAttribute(hwnd, 33, &round, sizeof(int));
    }

    /// <summary>The 1 px edge Windows 11 draws round a window, in a color of ours (0x00BBGGRR).</summary>
    public static int BorderColor(nint hwnd, uint colorRef)
    {
        var color = colorRef;   // DWMWA_BORDER_COLOR (34)
        return DwmSetWindowAttribute(hwnd, 34, &color, sizeof(uint));
    }

    public const int COLOR_WINDOWTEXT = 8;

    /// <summary>A system color as a COLORREF: in high contrast, the theme's.</summary>
    [LibraryImport("user32.dll")]
    public static partial uint GetSysColor(int index);

    /// <summary>0xRRGGBB as a COLORREF (0x00BBGGRR).</summary>
    public static uint ColorRef(uint rgb) => ((rgb & 0xFF) << 16) | (rgb & 0xFF00) | ((rgb >> 16) & 0xFF);

    // Popups that never take focus (spike W9)

    public const int GWL_EXSTYLE = -20;
    public const nint WS_EX_NOACTIVATE = 0x08000000;
    public const uint WM_MOUSEACTIVATE = 0x0021, WM_NCDESTROY = 0x0082, WM_NCCALCSIZE = 0x0083;
    public const nint MA_NOACTIVATE = 3;
    public const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOZORDER = 0x4, SWP_NOACTIVATE = 0x10, SWP_FRAMECHANGED = 0x20, SWP_NOOWNERZORDER = 0x200;

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SetWindowPos(nint hwnd, nint insertAfter, int x, int y, int cx, int cy, uint flags);

    [LibraryImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    public static partial nint GetWindowLongPtr(nint hwnd, int index);

    [LibraryImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    public static partial nint SetWindowLongPtr(nint hwnd, int index, nint value);

    [LibraryImport("comctl32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SetWindowSubclass(nint hwnd, delegate* unmanaged<nint, uint, nint, nint, nuint, nuint, nint> proc, nuint id, nuint data);

    [LibraryImport("comctl32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool RemoveWindowSubclass(nint hwnd, delegate* unmanaged<nint, uint, nint, nint, nuint, nuint, nint> proc, nuint id);

    [LibraryImport("comctl32.dll")]
    public static partial nint DefSubclassProc(nint hwnd, uint msg, nint wParam, nint lParam);

    // The chime

    public const uint SND_ASYNC = 0x1, SND_NODEFAULT = 0x2, SND_ALIAS = 0x10000;

    [LibraryImport("winmm.dll", EntryPoint = "PlaySoundW", StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool PlaySound(string sound, nint module, uint flags);

    // High contrast

    [StructLayout(LayoutKind.Sequential)]
    public struct HIGHCONTRASTW
    {
        public uint cbSize;
        public uint dwFlags;
        public nint lpszDefaultScheme;
    }

    [LibraryImport("user32.dll", EntryPoint = "SystemParametersInfoW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SystemParametersInfo(uint action, uint param, void* value, uint winIni);

    /// <summary>Whether a high contrast theme is on (then the system's colors win).</summary>
    public static bool HighContrast()
    {
        var hc = new HIGHCONTRASTW { cbSize = (uint)sizeof(HIGHCONTRASTW) };
        return SystemParametersInfo(0x0042, hc.cbSize, &hc, 0) && (hc.dwFlags & 1) != 0;   // SPI_GETHIGHCONTRAST, HCF_HIGHCONTRASTON
    }

    // GDI: the tray icon is drawn from the icon font

    public const int FW_NORMAL = 400;
    public const uint ANTIALIASED_QUALITY = 4, TRANSPARENT = 1, DIB_RGB_COLORS = 0;
    public const uint DT_CENTER = 0x1, DT_VCENTER = 0x4, DT_SINGLELINE = 0x20, DT_NOPREFIX = 0x800, DT_NOCLIP = 0x100;

    [LibraryImport("gdi32.dll")]
    public static partial nint CreateCompatibleDC(nint hdc);

    [LibraryImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool DeleteDC(nint hdc);

    [LibraryImport("gdi32.dll")]
    public static partial nint CreateDIBSection(nint hdc, BITMAPINFOHEADER* info, uint usage, void** bits, nint section, uint offset);

    [LibraryImport("gdi32.dll")]
    public static partial nint CreateBitmap(int width, int height, uint planes, uint bitsPerPixel, void* bits);

    [LibraryImport("gdi32.dll")]
    public static partial nint SelectObject(nint hdc, nint obj);

    [LibraryImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool DeleteObject(nint obj);

    [LibraryImport("gdi32.dll", EntryPoint = "CreateFontW", StringMarshalling = StringMarshalling.Utf16)]
    public static partial nint CreateFont(int height, int width, int escapement, int orientation, int weight,
        uint italic, uint underline, uint strikeOut, uint charSet, uint outPrecision, uint clipPrecision,
        uint quality, uint pitchAndFamily, string face);

    [LibraryImport("gdi32.dll")]
    public static partial uint SetTextColor(nint hdc, uint color);

    [LibraryImport("gdi32.dll")]
    public static partial int SetBkMode(nint hdc, int mode);

    [LibraryImport("user32.dll", EntryPoint = "DrawTextW", StringMarshalling = StringMarshalling.Utf16)]
    public static partial int DrawText(nint hdc, string text, int length, RECT* rect, uint format);

    [LibraryImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GdiFlush();
}

/// <summary>
/// The tray's right-click menu in dark mode when apps are dark, like the flyout. Win32 menus are light unless
/// the app opts in through uxtheme's unnamed exports, which Explorer, PowerToys and Notepad++ use the same
/// way (ordinals stable since Windows 10 1903). If any is missing, the menu stays light.
/// </summary>
static unsafe partial class MenuTheme
{
    const int AllowDark = 1;   // PreferredAppMode: follow AppsUseLightTheme
    static delegate* unmanaged<int, int> setPreferredAppMode;
    static delegate* unmanaged<nint, int, int> allowDarkModeForWindow;
    static delegate* unmanaged<void> refreshImmersiveColorPolicyState;
    static delegate* unmanaged<void> flushMenuThemes;

    [LibraryImport("kernel32.dll", EntryPoint = "LoadLibraryExW", StringMarshalling = StringMarshalling.Utf16)]
    private static partial nint LoadLibraryEx(string name, nint file, uint flags);

    [LibraryImport("kernel32.dll")]
    private static partial nint GetProcAddress(nint module, nint ordinal);

    /// <summary>Once, before the tray's window is made.</summary>
    public static void Start()
    {
        var uxtheme = LoadLibraryEx("uxtheme.dll", 0, 0x800);   // LOAD_LIBRARY_SEARCH_SYSTEM32
        if (uxtheme == 0) return;
        setPreferredAppMode = (delegate* unmanaged<int, int>)GetProcAddress(uxtheme, 135);
        allowDarkModeForWindow = (delegate* unmanaged<nint, int, int>)GetProcAddress(uxtheme, 133);
        refreshImmersiveColorPolicyState = (delegate* unmanaged<void>)GetProcAddress(uxtheme, 104);
        flushMenuThemes = (delegate* unmanaged<void>)GetProcAddress(uxtheme, 136);
        if (setPreferredAppMode == null || allowDarkModeForWindow == null || refreshImmersiveColorPolicyState == null || flushMenuThemes == null)
        {
            setPreferredAppMode = null;
            Log.Write("dark menus: uxtheme has no such exports; menus stay light");
            return;
        }
        setPreferredAppMode(AllowDark);
        refreshImmersiveColorPolicyState();
    }

    /// <summary>The window that owns the menu.</summary>
    public static void Allow(nint hwnd)
    {
        if (setPreferredAppMode != null) allowDarkModeForWindow(hwnd, 1);
    }

    /// <summary>On <c>ImmersiveColorSet</c>: the next menu takes the new mode.</summary>
    public static void Refresh()
    {
        if (setPreferredAppMode == null) return;
        refreshImmersiveColorPolicyState();
        flushMenuThemes();
    }
}
