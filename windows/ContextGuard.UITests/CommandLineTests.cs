using System.Diagnostics;
using Microsoft.Win32;
using Xunit;

namespace ContextGuard.UITests;

/// <summary>
/// The app's command line, as the installer and the Start menu use it: a second launch opens Settings in the copy
/// that runs, <c>--quit</c> ends it, <c>--login-item on|off</c> sets Open at login, <c>--render-icon</c> writes
/// the icon build.ps1 puts in the exe.
/// </summary>
public sealed class CommandLineTests
{
    [Fact]
    public void ASecondLaunchOpensSettingsInTheCopyThatRuns()
    {
        using var app = new RunningApp("asking", next: ["settings"]);
        app.OpenFlyout();   // the board has arrived

        var second = Run("--login-key", RunningApp.LoginKey);
        Assert.Equal(0, second.Code);

        app.Sent("settingsOpen");
        var window = app.Settings();
        RunningApp.Until(() => RunningApp.Foreground == window.Properties.NativeWindowHandle.Value, "Settings in front");
        Assert.False(app.Process.HasExited);
        Assert.Single(System.Diagnostics.Process.GetProcessesByName("ContextGuard"));
    }

    [Fact]
    public void ASecondLaunchBringsSettingsToTheFrontWhenItsOpen()
    {
        using var app = new RunningApp("asking", next: ["settings"]);
        RunningApp.Press(app.Find(app.OpenFlyout(), "Settings"));
        var window = app.Settings();
        // The flyout takes the front from it.
        var flyout = app.OpenFlyout();
        RunningApp.Until(() => RunningApp.Foreground == flyout.Properties.NativeWindowHandle.Value, "the flyout in front");

        Assert.Equal(0, Run("--login-key", RunningApp.LoginKey).Code);

        RunningApp.Until(() => RunningApp.Foreground == window.Properties.NativeWindowHandle.Value, "Settings in front");
        Assert.False(RunningApp.IsVisible(flyout));
        // Already open: the program isn't asked again.
        Thread.Sleep(500);
        Assert.Single(app.Intents(), i => i.GetProperty("do").GetString() == "settingsOpen");
    }

    [Fact]
    public void QuitEndsTheCopyThatRunsAndItsProgram()
    {
        using var app = new RunningApp("asking");
        var standIn = System.Diagnostics.Process.GetProcessById(app.StandIn);

        var quit = Run("--quit");

        Assert.Equal(0, quit.Code);
        Assert.True(app.Process.HasExited, "the app still runs");
        Assert.True(standIn.WaitForExit(5_000), "the stand-in still runs");
        Assert.Equal(0, Run("--quit").Code);   // nothing to quit
    }

    [Fact]
    public void LoginItemOnAndOffWriteAndRemoveTheRunValue()
    {
        Registry.CurrentUser.DeleteSubKeyTree(RunningApp.LoginKey, throwOnMissingSubKey: false);
        try
        {
            // Turned off in Windows' Startup apps: turning it on here wins.
            using (var approved = Registry.CurrentUser.CreateSubKey(RunningApp.LoginKey + @"\Explorer\StartupApproved\Run"))
                approved.SetValue("Context Guard", new byte[] { 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, RegistryValueKind.Binary);

            Assert.Equal(0, Run("--login-key", RunningApp.LoginKey, "--login-item", "on").Code);
            Assert.Equal($"\"{Path.GetFullPath(RunningApp.App)}\"", RunningApp.LoginCommand());
            Assert.Null(RunningApp.StartupApproved());

            Assert.Equal(0, Run("--login-key", RunningApp.LoginKey, "--login-item", "off").Code);
            Assert.Null(RunningApp.LoginCommand());
            Assert.Empty(System.Diagnostics.Process.GetProcessesByName("ContextGuard"));
        }
        finally
        {
            Registry.CurrentUser.DeleteSubKeyTree(RunningApp.LoginKey, throwOnMissingSubKey: false);
        }
    }

    [Fact]
    public void ACommandItDoesntKnowExitsWith2AndSaysHowToUseIt()
    {
        var run = Run("--login-item", "maybe");
        Assert.Equal(2, run.Code);
        Assert.Contains("usage: ContextGuard.exe [--login-item on|off | --render-icon <file.ico> | --quit]", run.Error, StringComparison.Ordinal);
        Assert.Empty(System.Diagnostics.Process.GetProcessesByName("ContextGuard"));
    }

    [Fact]
    public void RenderIconWritesAnIcoWithEverySizeWindowsAsksFor()
    {
        var file = Path.Combine(Path.GetTempPath(), "cg-uitest-" + Guid.NewGuid().ToString("N")[..8] + ".ico");
        try
        {
            Assert.Equal(0, Run("--render-icon", file).Code);
            var bytes = File.ReadAllBytes(file);
            Assert.Equal(0, BitConverter.ToUInt16(bytes, 0));
            Assert.Equal(1, BitConverter.ToUInt16(bytes, 2));   // an icon
            int[] sizes = [16, 20, 24, 32, 40, 48, 64, 256];
            Assert.Equal(sizes.Length, BitConverter.ToUInt16(bytes, 4));
            var next = 6 + 16 * sizes.Length;
            for (var i = 0; i < sizes.Length; i++)
            {
                var entry = 6 + 16 * i;
                Assert.Equal(sizes[i] % 256, bytes[entry]);   // 0 means 256
                Assert.Equal(sizes[i] % 256, bytes[entry + 1]);
                Assert.Equal(32, BitConverter.ToUInt16(bytes, entry + 6));
                var size = (int)BitConverter.ToUInt32(bytes, entry + 8);
                Assert.Equal(next, (int)BitConverter.ToUInt32(bytes, entry + 12));
                // A 32-bit bitmap twice as tall (its AND mask, a bit a pixel in rows of 4 bytes, follows).
                Assert.Equal(40, BitConverter.ToInt32(bytes, next));
                Assert.Equal(sizes[i], BitConverter.ToInt32(bytes, next + 4));
                Assert.Equal(sizes[i] * 2, BitConverter.ToInt32(bytes, next + 8));
                Assert.Equal(40 + sizes[i] * sizes[i] * 4 + (sizes[i] + 31) / 32 * 4 * sizes[i], size);
                next += size;
            }
            Assert.Equal(next, bytes.Length);
        }
        finally
        {
            File.Delete(file);
        }
    }

    /// <summary>The app with these arguments, to its end: its exit code and what it wrote to stderr.</summary>
    static (int Code, string Error) Run(params string[] args)
    {
        var info = new ProcessStartInfo(RunningApp.App) { UseShellExecute = false, RedirectStandardError = true };
        foreach (var arg in args) info.ArgumentList.Add(arg);
        using var process = System.Diagnostics.Process.Start(info)!;
        var error = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(15_000))
        {
            process.Kill(entireProcessTree: true);
            throw new TimeoutException($"ContextGuard.exe {string.Join(' ', args)} still runs after 15 s.");
        }
        return (process.ExitCode, error.Result);
    }
}
