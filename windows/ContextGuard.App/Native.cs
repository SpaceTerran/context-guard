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

    [LibraryImport("dwmapi.dll")]
    public static partial int DwmSetWindowAttribute(nint hwnd, uint attribute, void* value, uint size);

    /// <summary>Windows 11 rounds captioned windows by itself; a window without a caption has to ask.</summary>
    public static int RoundCorners(nint hwnd)
    {
        var round = 2;   // DWMWA_WINDOW_CORNER_PREFERENCE (33) = DWMWCP_ROUND
        return DwmSetWindowAttribute(hwnd, 33, &round, sizeof(int));
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
