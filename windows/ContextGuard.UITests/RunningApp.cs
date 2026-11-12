using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Exceptions;
using FlaUI.UIA3;

namespace ContextGuard.UITests;

/// <summary>
/// The published app (<c>CONTEXT_GUARD_APP</c>), started with StandIn.ps1 printing a contract board, and what
/// it sent back. Everything goes through UI Automation and the app's own window messages: no synthesized
/// mouse or keyboard input. Quits the app when disposed.
/// </summary>
sealed partial class RunningApp : IDisposable
{
    public const string TrayClass = "ContextGuardTray";
    const string WinUIWindowClass = "WinUIDesktopWin32WindowClass";
    const uint WM_CLOSE = 0x0010, WM_TRAY = 0x8001, NIN_SELECT = 0x0400, WM_CONTEXTMENU = 0x007B;

    readonly string folder = Path.Combine(Path.GetTempPath(), "cg-uitest-" + Guid.NewGuid().ToString("N")[..8]);

    /// <param name="board">A file in contract/ui/boards (no extension).</param>
    /// <param name="program">In place of the stand-in: a program that isn't there, say.</param>
    /// <param name="next">Boards the stand-in prints after each intent, in turn.</param>
    /// <param name="chime">A chime after the first board, as the program sends when a question opens.</param>
    public RunningApp(string board = "asking", string? program = null, string[]? next = null, bool chime = false)
    {
        // Left over from a test that failed: one app per session, so it would stop this one.
        foreach (var old in System.Diagnostics.Process.GetProcessesByName("ContextGuard")) Quit(old);
        Directory.CreateDirectory(folder);
        IntentLog = Path.Combine(folder, "intents.log");
        Board = ReadBoard(board);
        Process = System.Diagnostics.Process.Start(Start(board, program, next, chime))!;
        TrayWindow = Until(() => Native.FindWindow(TrayClass, null) is var h && h != 0 ? (nint?)h : null, "the tray window");
    }

    public static string App => Environment.GetEnvironmentVariable("CONTEXT_GUARD_APP") is { Length: > 0 } app
        ? app
        : throw new InvalidOperationException("Set CONTEXT_GUARD_APP to the published ContextGuard.exe.");

    public static string Contract { get; } = FindContract();

    public Process Process { get; }
    public UIA3Automation Automation { get; } = new();
    public string IntentLog { get; }
    /// <summary>The board the stand-in printed.</summary>
    public JsonElement Board { get; }
    public nint TrayWindow { get; }

    /// <summary>A board in contract/ui/boards.</summary>
    public static JsonElement ReadBoard(string name) =>
        JsonDocument.Parse(File.ReadAllText(Path.Combine(Contract, "boards", name + ".json"))).RootElement.GetProperty("board").Clone();

    /// <summary>The app's command line for a board (or for another program in place of the stand-in).</summary>
    public ProcessStartInfo Start(string board, string? program = null, string[]? next = null, bool chime = false)
    {
        var info = new ProcessStartInfo(App) { UseShellExecute = false };
        if (program is not null)
        {
            info.ArgumentList.Add("--program");
            info.ArgumentList.Add(program);
            return info;
        }
        info.ArgumentList.Add("--program");
        info.ArgumentList.Add(Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"));
        var args = new List<string>
        {
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", Path.Combine(AppContext.BaseDirectory, "StandIn.ps1"),
            "-Board", Path.Combine(Contract, "boards", board + ".json"), "-Log", IntentLog,
        };
        if (next is { Length: > 0 }) args.AddRange(["-Next", string.Join(',', next)]);
        if (chime) args.Add("-Chime");
        foreach (var arg in args)
        {
            info.ArgumentList.Add("--program-arg");
            info.ArgumentList.Add(arg);
        }
        return info;
    }

    /// <summary>The stand-in's process id, once it has started.</summary>
    public int StandIn => Until(() => File.Exists(IntentLog + ".pid") && int.TryParse(File.ReadAllText(IntentLog + ".pid"), out var id) ? (int?)id : null, "the stand-in");

    // The notification area

    AutomationElement Desktop => Automation.GetDesktop();

    AutomationElement Taskbar => Until(() => Desktop.FindFirstChild(cf => cf.ByClassName("Shell_TrayWnd")), "the taskbar");

    /// <summary>The app's icon, on the taskbar or (where Windows 11 puts a new one) in the overflow, opened for it.</summary>
    public AutomationElement Icon() => Until(() =>
    {
        if (FindIcon(Taskbar) is { } shown) return shown;
        var overflow = Overflow();
        if (overflow is null || overflow.IsOffscreen)
        {
            Press(Chevron());
            overflow = Until(() => Overflow() is { IsOffscreen: false } o ? o : null, "the overflow", 5);
        }
        return FindIcon(overflow);
    }, "the icon");

    static AutomationElement? FindIcon(AutomationElement within) =>
        within.FindAllDescendants(cf => cf.ByAutomationId("NotifyItemIcon")).FirstOrDefault(e => e.Name.Contains("Context Guard", StringComparison.Ordinal));

    AutomationElement? Overflow() => Desktop.FindFirstChild(cf => cf.ByClassName("TopLevelWindowForOverflowXamlIsland"));

    public AutomationElement Chevron() => Until(() => Taskbar.FindFirstDescendant(cf => cf.ByAutomationId("SystemTrayIcon")), "the overflow chevron");

    public void CloseOverflow()
    {
        if (Overflow() is { IsOffscreen: false }) Press(Chevron());
    }

    // The flyout

    /// <summary>The flyout, shown or hidden (null before it was first opened).</summary>
    public AutomationElement? Flyout() =>
        Desktop.FindFirstChild(cf => cf.ByProcessId(Process.Id).And(cf.ByName("Context Guard")));

    /// <summary>A click on the icon, then the flyout once it shows the board (the stand-in takes a moment to start).</summary>
    public AutomationElement OpenFlyout(bool board = true) => Until(() =>
    {
        Press(Icon());
        var flyout = Until(() => Flyout() is { } f && IsVisible(f) ? f : null, "the flyout", 5);
        if (board) Until(() => flyout.FindFirstDescendant(cf => cf.ByAutomationId("On")), "the board in the flyout", 10);
        return flyout;
    }, "the flyout with its board", 30);

    public static bool IsVisible(AutomationElement window) => Native.IsWindowVisible(window.Properties.NativeWindowHandle.Value);

    public AutomationElement Find(AutomationElement within, string automationId) =>
        Until(() => within.FindFirstDescendant(cf => cf.ByAutomationId(automationId)), automationId, 5);

    public static bool Has(AutomationElement within, string automationId) =>
        within.FindFirstDescendant(cf => cf.ByAutomationId(automationId)) is not null;

    // Popups and notices

    /// <summary>The popups and notices showing: the app's windows but the flyout.</summary>
    public AutomationElement[] Popups() =>
        Desktop.FindAllChildren(cf => cf.ByProcessId(Process.Id).And(cf.ByClassName(WinUIWindowClass)))
            .Where(w => w.Name != "Context Guard" && IsVisible(w)).ToArray();

    /// <summary>A popup by its window's name (what a screen reader calls it), once it shows.</summary>
    public AutomationElement Popup(string name) =>
        Until(() => Popups().FirstOrDefault(w => w.Name == name), $"the popup '{name}'");

    /// <summary>What a board's popup is called: a question's heading and session, a notice's title and session.</summary>
    public static string PopupName(JsonElement popup) =>
        popup.TryGetProperty("question", out var q)
            ? $"{q.GetProperty("heading").GetString()}, {q.GetProperty("title").GetString()}"
            : $"{popup.GetProperty("notice").GetProperty("title").GetString()}, {popup.GetProperty("notice").GetProperty("detail").GetString()}";

    /// <summary>The primary screen's work area (the taskbar left out), in this process's pixels.</summary>
    public static unsafe System.Drawing.Rectangle WorkArea()
    {
        Native.RECT r;
        if (!Native.SystemParametersInfo(0x0030, 0, &r, 0)) throw new InvalidOperationException("No work area.");   // SPI_GETWORKAREA
        return System.Drawing.Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom);
    }

    /// <summary>What you see of a window, in pixels: its rect less the frame Windows keeps invisible.</summary>
    public static unsafe System.Drawing.Rectangle VisibleBounds(AutomationElement window)
    {
        Native.RECT r;
        var hr = Native.DwmGetWindowAttribute(window.Properties.NativeWindowHandle.Value, 9, &r, (uint)sizeof(Native.RECT));   // DWMWA_EXTENDED_FRAME_BOUNDS
        if (hr != 0) throw new InvalidOperationException($"No visible bounds (0x{hr:X}).");
        return System.Drawing.Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom);
    }

    /// <summary>Pixels per DIP on the primary screen, as this process sees it.</summary>
    public static double Scale => Native.GetDpiForSystem() / 96.0;

    public static nint Foreground => Native.GetForegroundWindow();

    // The app's own messages, as the shell sends them

    /// <summary>A click on the icon: what the shell sends the tray window.</summary>
    public void ClickIcon() => Native.PostMessage(TrayWindow, WM_TRAY, 0, (nint)NIN_SELECT);

    /// <summary>A right click on the icon at a point: what the shell sends (the point in wParam).</summary>
    public void RightClickIcon(int x, int y) => Native.PostMessage(TrayWindow, WM_TRAY, (nint)((y << 16) | (x & 0xFFFF)), (nint)WM_CONTEXTMENU);

    /// <summary>The native menu a right click opened.</summary>
    public AutomationElement Menu() => Until(() => Desktop.FindFirstChild(cf => cf.ByClassName("#32768")), "the right-click menu");

    // What the app sent

    /// <summary>The intents the stand-in got, oldest first.</summary>
    public IReadOnlyList<JsonElement> Intents()
    {
        if (!File.Exists(IntentLog)) return [];
        using var stream = new FileStream(IntentLog, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd().Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(line => JsonDocument.Parse(line).RootElement.Clone()).ToList();
    }

    /// <summary>The first intent that does <paramref name="what"/>, once the app has sent it.</summary>
    public JsonElement Sent(string what) =>
        Until(() => Intents().Where(i => i.GetProperty("do").GetString() == what).Select(i => (JsonElement?)i).FirstOrDefault(), $"a '{what}' intent");

    // Quitting

    /// <summary>WM_CLOSE to the tray window, as the tests quit it; true when it ended within 10 seconds.</summary>
    public bool Close()
    {
        Native.PostMessage(TrayWindow, WM_CLOSE, 0, 0);
        return Process.WaitForExit(10_000);
    }

    static void Quit(Process p)
    {
        var tray = Native.FindWindow(TrayClass, null);
        if (tray != 0) Native.PostMessage(tray, WM_CLOSE, 0, 0);
        if (!p.WaitForExit(10_000)) p.Kill(entireProcessTree: true);
    }

    public void Dispose()
    {
        try
        {
            CloseOverflow();
        }
        catch (Exception e) when (e is COMException or FlaUIException or TimeoutException)
        {
        }
        if (!Process.HasExited && !Close()) Process.Kill(entireProcessTree: true);
        Automation.Dispose();
        Process.Dispose();
        try
        {
            Directory.Delete(folder, recursive: true);
        }
        catch (IOException)
        {
        }
    }

    // Helpers

    public static void Press(AutomationElement e)
    {
        if (e.Patterns.Invoke.TryGetPattern(out var invoke)) invoke.Invoke();
        else if (e.Patterns.Toggle.TryGetPattern(out var toggle)) toggle.Toggle();
        else if (e.Patterns.ExpandCollapse.TryGetPattern(out var expand)) expand.Expand();
        else throw new InvalidOperationException($"{e.AutomationId} '{e.Name}' can't be pressed");
    }

    /// <summary>Asks until it answers (UI Automation errors count as no answer yet).</summary>
    public static T Until<T>(Func<T?> probe, string what, double seconds = 10) where T : class
    {
        var end = Stopwatch.StartNew();
        Exception? last = null;
        while (true)
        {
            try
            {
                if (probe() is { } found) return found;
            }
            catch (Exception e) when (e is COMException or FlaUIException or TimeoutException)
            {
                last = e;
            }
            if (end.Elapsed.TotalSeconds > seconds) throw new TimeoutException($"No {what} after {seconds} s.", last);
            Thread.Sleep(100);
        }
    }

    public static T Until<T>(Func<T?> probe, string what, double seconds = 10) where T : struct =>
        Until(() => probe() is { } v ? new Box<T>(v) : null, what, seconds).Value;

    public static void Until(Func<bool> probe, string what, double seconds = 10) =>
        Until(() => probe() ? new Box<bool>(true) : null, what, seconds);

    sealed record Box<T>(T Value);

    static string FindContract()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            var contract = Path.Combine(dir.FullName, "contract", "ui");
            if (Directory.Exists(contract)) return contract;
        }
        throw new DirectoryNotFoundException($"No contract/ui above {AppContext.BaseDirectory}");
    }

    static partial class Native
    {
        [LibraryImport("user32.dll", EntryPoint = "FindWindowW", StringMarshalling = StringMarshalling.Utf16)]
        public static partial nint FindWindow(string? className, string? title);

        [LibraryImport("user32.dll", EntryPoint = "PostMessageW")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static partial bool PostMessage(nint hwnd, uint msg, nint wParam, nint lParam);

        [LibraryImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static partial bool IsWindowVisible(nint hwnd);

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT
        {
            public int Left, Top, Right, Bottom;
        }

        [LibraryImport("user32.dll", EntryPoint = "SystemParametersInfoW")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static unsafe partial bool SystemParametersInfo(uint action, uint param, void* value, uint winIni);

        [LibraryImport("user32.dll")]
        public static partial uint GetDpiForSystem();

        [LibraryImport("user32.dll")]
        public static partial nint GetForegroundWindow();

        [LibraryImport("dwmapi.dll")]
        public static unsafe partial int DwmGetWindowAttribute(nint hwnd, uint attribute, void* value, uint size);
    }
}
