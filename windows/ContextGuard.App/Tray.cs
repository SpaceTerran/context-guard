using Microsoft.Win32;

namespace ContextGuard.App;

/// <summary>
/// The notification-area icon, straight on Win32 (spike W9): a hidden top-level window (a message-only window
/// doesn't get the <c>TaskbarCreated</c> broadcast), <c>Shell_NotifyIcon</c> version 4, and a native menu on
/// right click. It comes back after Explorer restarts, redraws itself at the taskbar's DPI after a scale change,
/// and swaps to the other color when the taskbar turns light or dark. <c>WM_CLOSE</c> on its window quits the
/// app (<c>--quit</c> and the tests use it), and <see cref="OpenSettingsMessage"/> opens Settings.
/// </summary>
sealed unsafe class Tray
{
    const uint WM_TRAY = Native.WM_APP + 1;
    /// <summary>The tray window's class: how another copy of the app (<see cref="Commands"/>) finds this one.</summary>
    internal const string ClassName = "ContextGuardTray";

    /// <summary>Posted to the tray window by a second launch (<see cref="Commands.OpenSettingsInRunningCopy"/>): open Settings.</summary>
    internal const string OpenSettingsMessage = "ContextGuard.OpenSettings";
    static Tray? instance;
    readonly App app;
    readonly nint hwnd;
    readonly uint taskbarCreated, openSettings;
    bool added, lightTaskbar;
    uint iconDpi;
    nint icon;
    string state = "on", tip = "Context Guard";

    public Tray(App app)
    {
        this.app = app;
        instance = this;
        var module = Native.GetModuleHandle(0);
        fixed (char* name = ClassName)
        {
            var wc = new Native.WNDCLASSEXW
            {
                cbSize = (uint)sizeof(Native.WNDCLASSEXW),
                lpfnWndProc = &WndProc,
                hInstance = module,
                lpszClassName = name,
            };
            Native.RegisterClassEx(&wc);
        }
        MenuTheme.Start();
        hwnd = Native.CreateWindowEx(0, ClassName, ClassName, 0, 0, 0, 0, 0, 0, 0, module, 0);
        MenuTheme.Allow(hwnd);
        taskbarCreated = Native.RegisterWindowMessage("TaskbarCreated");
        openSettings = Native.RegisterWindowMessage(OpenSettingsMessage);
        lightTaskbar = ReadLightTaskbar();
    }

    /// <summary>Shows the icon in a state (<c>on</c>, <c>asking</c>, <c>off</c>) with its tooltip, or updates it.</summary>
    public void Show(string newState, string newTip)
    {
        var redraw = !added || newState != state;
        state = newState;
        tip = newTip;
        if (redraw) MakeIcon();
        if (added) Modify(Native.NIF_ICON | Native.NIF_TIP | Native.NIF_SHOWTIP);
        else Add();
    }

    public void Remove()
    {
        var d = Data();
        Native.Shell_NotifyIcon(Native.NIM_DELETE, &d);
        added = false;
        if (icon != 0) Native.DestroyIcon(icon);
        icon = 0;
        Native.DestroyWindow(hwnd);
        instance = null;
    }

    /// <summary>A native menu at the pointer; returns the chosen item's id, 0 for none.</summary>
    public int Menu(int x, int y, IReadOnlyList<TrayMenuItem> items)
    {
        var menu = Native.CreatePopupMenu();
        foreach (var item in items)
        {
            if (item.Id == 0) Native.AppendMenu(menu, Native.MF_SEPARATOR, 0, null);
            else Native.AppendMenu(menu, Native.MF_STRING | (item.Checked ? Native.MF_CHECKED : 0) | (item.Enabled ? 0 : 0x3u), (nuint)item.Id, item.Text);
        }
        // In front, so the menu closes when you click elsewhere; the empty message after it is what
        // Microsoft's docs ask for, so a second click on the icon works.
        Native.SetForegroundWindow(hwnd);
        var chosen = Native.TrackPopupMenuEx(menu, Native.TPM_RIGHTBUTTON | Native.TPM_BOTTOMALIGN | Native.TPM_RETURNCMD, x, y, hwnd, 0);
        Native.PostMessage(hwnd, Native.WM_NULL, 0, 0);
        Native.DestroyMenu(menu);
        return chosen;
    }

    Native.NOTIFYICONDATAW Data() => new() { cbSize = (uint)sizeof(Native.NOTIFYICONDATAW), hWnd = hwnd, uID = 1 };

    void Add()
    {
        var d = Data();
        d.uFlags = Native.NIF_MESSAGE | Native.NIF_ICON | Native.NIF_TIP | Native.NIF_SHOWTIP;
        d.uCallbackMessage = WM_TRAY;
        d.hIcon = icon;
        CopyTip(&d);
        added = Native.Shell_NotifyIcon(Native.NIM_ADD, &d);
        if (!added)
        {
            // Still there from before (a second TaskbarCreated): replace it.
            Native.Shell_NotifyIcon(Native.NIM_DELETE, &d);
            added = Native.Shell_NotifyIcon(Native.NIM_ADD, &d);
        }
        d.uVersion = 4;
        Native.Shell_NotifyIcon(Native.NIM_SETVERSION, &d);
        Log.Write($"tray icon added: {added}");
    }

    void Modify(uint flags)
    {
        var d = Data();
        d.uFlags = flags;
        d.hIcon = icon;
        CopyTip(&d);
        Native.Shell_NotifyIcon(Native.NIM_MODIFY, &d);
    }

    void CopyTip(Native.NOTIFYICONDATAW* d)
    {
        var text = tip.Length > 127 ? tip[..127] : tip;
        var span = new Span<char>(d->szTip, 128);
        span.Clear();
        text.AsSpan().CopyTo(span);
    }

    /// <summary>The taskbar's DPI: this hidden window's own is fixed when it's made (W9).</summary>
    static uint TaskbarDpi() => Native.MonitorDpi(Native.FindWindow("Shell_TrayWnd", null));

    void MakeIcon()
    {
        iconDpi = TaskbarDpi();
        var size = Native.GetSystemMetricsForDpi(Native.SM_CXSMICON, iconDpi);
        var old = icon;
        icon = TrayIcons.Make(state, lightTaskbar, size);
        if (old != 0) Native.DestroyIcon(old);
    }

    static bool ReadLightTaskbar() =>
        Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "SystemUsesLightTheme", 0) is int v && v != 0;

    [System.Runtime.InteropServices.UnmanagedCallersOnly]
    static nint WndProc(nint h, uint msg, nint wParam, nint lParam)
    {
        try
        {
            if (instance is { } tray && tray.Handle(msg, wParam, lParam)) return 0;
        }
        catch (Exception e)
        {
            Log.Write($"tray message 0x{msg:X}: {e}");
        }
        return Native.DefWindowProc(h, msg, wParam, lParam);
    }

    bool Handle(uint msg, nint wParam, nint lParam)
    {
        if (msg == WM_TRAY)
        {
            var ev = (uint)(lParam & 0xFFFF);
            if (ev == Native.NIN_SELECT || ev == Native.NIN_KEYSELECT) app.ToggleFlyout(keyboard: ev == Native.NIN_KEYSELECT);
            else if (ev == Native.WM_CONTEXTMENU) app.ShowTrayMenu((short)(wParam & 0xFFFF), (short)((wParam >> 16) & 0xFFFF));
            return true;
        }
        if (msg == taskbarCreated && taskbarCreated != 0)
        {
            Log.Write("TaskbarCreated: adding the icon again");
            added = false;
            MakeIcon();
            Add();
            return true;
        }
        if (msg == openSettings && openSettings != 0)
        {
            Log.Write("a second launch: opening Settings");
            app.OpenSettings();
            return true;
        }
        if (msg is Native.WM_SETTINGCHANGE or Native.WM_DISPLAYCHANGE) app.SettingsChanged();
        if (msg == Native.WM_DISPLAYCHANGE && added && TaskbarDpi() != iconDpi)
        {
            MakeIcon();
            Modify(Native.NIF_ICON);
            return false;
        }
        if (msg == Native.WM_SETTINGCHANGE && lParam != 0 && new string((char*)lParam) == "ImmersiveColorSet")
        {
            MenuTheme.Refresh();
            var light = ReadLightTaskbar();
            if (light != lightTaskbar && added)
            {
                lightTaskbar = light;
                MakeIcon();
                Modify(Native.NIF_ICON);
            }
            return false;
        }
        if (msg == Native.WM_CLOSE)
        {
            app.Quit();
            return true;
        }
        return false;
    }
}

/// <summary>An item of the tray's menu; <see cref="Id"/> 0 is a separator.</summary>
readonly record struct TrayMenuItem(int Id, string Text = "", bool Checked = false, bool Enabled = true)
{
    public static TrayMenuItem Separator => new(0);
}
