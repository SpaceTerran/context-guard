using System.Diagnostics;

namespace ContextGuard.App;

/// <summary>
/// What the command line can ask for besides running the app (<see cref="Options"/>), each done before anything is
/// shown. Exit code 0 when done, 1 when not (why: in the app's log and on stderr), 2 for a command it doesn't know.
/// <list type="bullet">
/// <item><c>--login-item on|off</c>: Open at login (install.ps1 turns it on, and off before an uninstall).</item>
/// <item><c>--render-icon &lt;file.ico&gt;</c>: the app's icon as an .ico (build.ps1 puts it in the exe).</item>
/// <item><c>--quit</c>: quits the copy running in this session and waits for it to end (install.ps1, before it
/// replaces the app).</item>
/// </list>
/// </summary>
static class Commands
{
    const int WaitMs = 5000;

    public static int Run(Command command, Options options)
    {
        Log.Write($"command: {command.Name} {command.Value}".TrimEnd());
        return command switch
        {
            { Name: "--login-item", Value: "on" or "off" } => SetLoginItem(command.Value == "on", options.LoginKey),
            { Name: "--render-icon", Value: { Length: > 0 } path } => RenderIcon(path),
            { Name: "--quit" } => Quit(),
            _ => Fail(2, $"{command.Name} {command.Value}: usage: ContextGuard.exe [--login-item on|off | --render-icon <file.ico> | --quit]"),
        };
    }

    /// <summary>A second launch: the running copy opens Settings (or brings it to the front).</summary>
    public static int OpenSettingsInRunningCopy()
    {
        var message = Native.RegisterWindowMessage(Tray.OpenSettingsMessage);
        // The running copy may be starting: its tray window comes a moment after it takes the session.
        var tray = Find(found => found != 0);
        if (tray == 0) return Fail(1, "another copy is running in this session, but it has no tray window");
        Native.GetWindowThreadProcessId(tray, out var pid);
        // You just started this launch, so it may bring a window to the front; the running copy is let do it.
        Native.AllowSetForegroundWindow(pid);
        return Native.PostMessage(tray, message, 0, 0) ? 0 : Fail(1, $"couldn't reach the running copy (pid {pid})");
    }

    static int SetLoginItem(bool on, string baseKey)
    {
        var exe = Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "ContextGuard.exe");
        try
        {
            new LoginItem(baseKey, exe).Set(on);
            return 0;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            return Fail(1, $"couldn't turn open at login {(on ? "on" : "off")}: {e.Message}");
        }
    }

    static int RenderIcon(string path)
    {
        try
        {
            AppIcon.WriteIco(path);
            return 0;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return Fail(1, $"couldn't write {path}: {e.Message}");
        }
    }

    /// <summary>As Quit in its menu (<c>WM_CLOSE</c> on its tray window), then waits for it to end.</summary>
    static int Quit()
    {
        var tray = Native.FindWindow(Tray.ClassName, null);
        if (tray == 0) return 0;
        Native.GetWindowThreadProcessId(tray, out var pid);
        var process = Native.OpenProcess(Native.SYNCHRONIZE, false, pid);
        try
        {
            Native.PostMessage(tray, Native.WM_CLOSE, 0, 0);
            var ended = process != 0
                ? Native.WaitForSingleObject(process, WaitMs) == 0
                : Find(found => found == 0) == 0;   // can't wait on it: its tray window going is the next best
            return ended ? 0 : Fail(1, $"the running copy (pid {pid}) didn't quit within {WaitMs / 1000} s");
        }
        finally
        {
            if (process != 0) Native.CloseHandle(process);
        }
    }

    /// <summary>Looks for the running copy's tray window until <paramref name="done"/> says so, for up to 5 s.</summary>
    static nint Find(Func<nint, bool> done)
    {
        var waited = Stopwatch.StartNew();
        while (true)
        {
            var tray = Native.FindWindow(Tray.ClassName, null);
            if (done(tray) || waited.ElapsedMilliseconds >= WaitMs) return tray;
            Thread.Sleep(100);
        }
    }

    static int Fail(int code, string message)
    {
        Log.Write(message);
        try
        {
            Console.Error.WriteLine(message);
        }
        catch (IOException)
        {
            // No stderr to write to: the log has it.
        }
        return code;
    }
}
