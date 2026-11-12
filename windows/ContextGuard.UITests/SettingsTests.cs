using System.Text.Json;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using Microsoft.Win32;
using Xunit;

namespace ContextGuard.UITests;

/// <summary>
/// The Settings window against the contract's settings boards (the stand-in prints one after the app's
/// <c>settingsOpen</c>), and once with the real program, which saves to a scratch config. Ctrl+1…3, typing and
/// Alt+F4 need real keys, so they are checked by hand (QMP on win-build).
/// </summary>
public sealed class SettingsTests
{
    const string ProgramName = "Context Guard";

    static string? Program => Environment.GetEnvironmentVariable("CONTEXT_GUARD_PROGRAM") is { Length: > 0 } p ? p : null;

    [Fact]
    public void TheRightClickMenuOpensSettingsOnGeneral()
    {
        using var app = new RunningApp("asking", next: ["settings"]);
        var window = OpenFromMenu(app);

        app.Sent("settingsOpen");
        RunningApp.Until(() => RunningApp.Foreground == window.Properties.NativeWindowHandle.Value, "Settings in front");
        Assert.True(Selected(app.Find(window, "Tab.general")));
        Assert.False(Selected(app.Find(window, "Tab.asking")));
        Assert.Equal("When to Ask", app.Find(window, "Tab.asking").Name);

        var watch = app.Find(window, "Toggle.enabled");
        Assert.Equal("Watch Claude Code sessions", watch.Name);
        Assert.Equal(ToggleState.On, watch.Patterns.Toggle.Pattern.ToggleState.Value);
        Assert.Equal("Open at login", app.Find(window, "Login").Name);
        Assert.Equal(ToggleState.Off, app.Find(window, "Login").Patterns.Toggle.Pattern.ToggleState.Value);
        Assert.Equal("Context Guard", app.Find(window, "general.Card1").Name);
        Assert.Equal("Claude Code", app.Find(window, "general.Card2").Name);
        Assert.Equal("Installed", app.Find(window, "general.Card2.Hooks").Name);
        Assert.Equal("Installed", app.Find(window, "general.Card2.Mod").Name);
        Assert.Equal("Haiku", app.Find(window, "general.Card2.Judge").Name);
        Assert.StartsWith("When off, nothing pops up", app.Find(window, "general.Note1").Name, StringComparison.Ordinal);
        Assert.Equal("No API key: the judge uses your Claude Code sign-in.", app.Find(window, "general.Note2").Name);
        // Another tab's rows aren't there until it's chosen; nor is a Codex card on this board.
        Assert.False(RunningApp.Has(window, "askK"));
        Assert.False(RunningApp.Has(window, "general.Card3"));
        Assert.Empty(app.Popups());
    }

    [Fact]
    public void TheFlyoutOpensSettingsAndHides()
    {
        using var app = new RunningApp("asking", next: ["settings"]);
        var flyout = app.OpenFlyout();
        var button = app.Find(flyout, "Settings");
        Assert.True(button.IsEnabled);
        RunningApp.Press(button);

        app.Sent("settingsOpen");
        RunningApp.Until(() => !RunningApp.IsVisible(flyout), "the flyout hidden");
        var window = app.Settings();
        Assert.True(Selected(app.Find(window, "Tab.general")));
    }

    [Fact]
    public void SettingsWhileOpenBringsItToTheFrontWithoutOpeningItAgain()
    {
        using var app = new RunningApp("asking", next: ["settings"]);
        var window = OpenFromMenu(app);
        app.Sent("settingsOpen");

        RunningApp.Press(app.Find(app.OpenFlyout(), "Settings"));
        RunningApp.Until(() => RunningApp.Foreground == window.Properties.NativeWindowHandle.Value, "Settings in front again");
        Thread.Sleep(500);
        Assert.Single(app.Intents(), i => Does(i, "settingsOpen"));
    }

    [Fact]
    public void WatchTurnsContextGuardOff()
    {
        using var app = new RunningApp("asking", next: ["settings"]);
        var window = OpenFromMenu(app);
        RunningApp.Press(app.Find(window, "Toggle.enabled"));

        Assert.False(app.Sent("enable").GetProperty("on").GetBoolean());
    }

    [Fact]
    public void TabsSwitchAndTheWindowKeepsItsHeight()
    {
        using var app = new RunningApp("asking", next: ["settings"]);
        var window = OpenFromMenu(app);
        var height = window.BoundingRectangle.Height;

        Select(app.Find(window, "Tab.asking"));
        Assert.Equal("300", Value(app.Find(window, "askK")));
        Assert.Equal("60", Value(app.Find(window, "autoYes")));
        Assert.Equal("500", Value(app.Find(window, "laterK")));
        Assert.Equal("Ask at", app.Find(window, "askK").Name);
        Assert.Equal("Saved", app.Find(window, "asking.Card1.Status").Name);
        Assert.StartsWith("When a session reaches 300k tokens", app.Find(window, "asking.Note1").Name, StringComparison.Ordinal);
        RunningApp.Until(() => !RunningApp.Has(window, "Toggle.enabled"), "General's rows gone");
        Assert.True(Selected(app.Find(window, "Tab.asking")));
        Assert.Equal(height, window.BoundingRectangle.Height);

        Select(app.Find(window, "Tab.messages"));
        var message = app.Find(window, "message");
        Assert.Equal("Before compacting, send", message.Name);
        Assert.StartsWith("I'm about to compact this conversation.", Value(message), StringComparison.Ordinal);
        Assert.Equal("continue now", Value(app.Find(window, "continueMessage")));
        Assert.False(app.Find(window, "message.Restore").IsEnabled);
        Assert.Equal("Asks the session to save its work first.", app.Find(window, "message.Note").Name);
        Assert.Equal(height, window.BoundingRectangle.Height);
        Assert.DoesNotContain(app.Intents(), i => !Does(i, "settingsOpen"));
    }

    [Fact]
    public void ANumberSavesAsItIsTypedAndTheStepsStepIt()
    {
        using var app = new RunningApp("asking", next: ["settings"]);
        var window = OpenFromMenu(app);
        Select(app.Find(window, "Tab.asking"));

        app.Find(window, "askK").Patterns.Value.Pattern.SetValue("200");
        var set = app.Sent("set");
        Assert.Equal("askK", set.GetProperty("field").GetString());
        Assert.Equal("200", set.GetProperty("value").GetString());

        RunningApp.Press(app.Find(window, "autoYes.More"));
        RunningApp.Press(app.Find(window, "laterK.Less"));
        var steps = RunningApp.Until(() => app.Intents().Where(i => Does(i, "step")).ToList() is { Count: 2 } s ? s : null, "two steps");
        Assert.Equal("autoYes", steps[0].GetProperty("field").GetString());
        Assert.True(steps[0].GetProperty("up").GetBoolean());
        Assert.Equal("laterK", steps[1].GetProperty("field").GetString());
        Assert.False(steps[1].GetProperty("up").GetBoolean());
        Assert.Equal("More: If you don't answer, compact after", app.Find(window, "autoYes.More").Name);
    }

    [Fact]
    public void AnEditedBoardSaysWhatIsNotSavedAndRestoreSendsRestore()
    {
        using var app = new RunningApp("asking", next: ["settings-edited"]);
        var window = OpenFromMenu(app);

        Select(app.Find(window, "Tab.asking"));
        Assert.Equal("Not saved", app.Find(window, "asking.Card1.Status").Name);
        Assert.Equal("“If you choose Wait, compact at” has to be more than “Ask at”.", app.Find(window, "asking.Note1").Name);
        Assert.Equal("250", Value(app.Find(window, "laterK")));

        Select(app.Find(window, "Tab.messages"));
        Assert.Equal("", Value(app.Find(window, "message")));
        Assert.Equal("Empty, so it sends the default.", app.Find(window, "message.Note").Name);
        Assert.Equal("Saved 3:41 PM", app.Find(window, "messages.Card1.Status").Name);
        var restore = app.Find(window, "message.Restore");
        Assert.True(restore.IsEnabled);
        Assert.Equal("Restore Default", restore.Name);
        RunningApp.Press(restore);

        Assert.Equal("message", app.Sent("restore").GetProperty("field").GetString());
    }

    [Fact]
    public void WithCodexEachToolHasItsCard()
    {
        using var app = new RunningApp("asking", next: ["settings-codex"]);
        var window = OpenFromMenu(app);

        Assert.Equal("Codex", app.Find(window, "general.Card3").Name);
        Assert.True(RunningApp.Has(window, "general.Card3.Link"));
        Assert.True(RunningApp.Has(window, "general.Card3.Judge"));
        Assert.True(RunningApp.Has(window, "general.Card3.Note1"));
        Assert.Equal("Watch sessions", app.Find(window, "Toggle.enabled").Name);

        Select(app.Find(window, "Tab.asking"));
        Assert.Equal("Claude Code", app.Find(window, "asking.Card1").Name);
        Assert.Equal("Not saved", app.Find(window, "asking.Card1.Status").Name);
        Assert.Equal("“Ask at” needs a number, like 300.", app.Find(window, "asking.Note1").Name);
        Assert.Equal("Codex", app.Find(window, "asking.Card2").Name);
        Assert.True(RunningApp.Has(window, "codexAsk"));
        Assert.True(RunningApp.Has(window, "codexLater"));
        Assert.Equal("If you don't answer", app.Find(window, "asking.Card3").Name);
    }

    [Fact]
    public void OpenAtLoginWritesTheRunValueAndTakesItAway()
    {
        using var app = new RunningApp("asking", next: ["settings"]);
        var window = OpenFromMenu(app);
        var login = app.Find(window, "Login");
        Assert.Equal(ToggleState.Off, login.Patterns.Toggle.Pattern.ToggleState.Value);

        RunningApp.Press(login);
        RunningApp.Until(() => RunningApp.LoginCommand() == Quoted(RunningApp.App), "the Run value");
        Assert.Equal(ToggleState.On, login.Patterns.Toggle.Pattern.ToggleState.Value);
        Assert.Null(RunningApp.StartupApproved());
        Assert.False(RunningApp.Has(window, "Login.Error"));

        RunningApp.Press(login);
        RunningApp.Until(() => RunningApp.LoginCommand() is null, "no Run value");
        Assert.Equal(ToggleState.Off, login.Patterns.Toggle.Pattern.ToggleState.Value);
        // It's the app's own switch: the program hears nothing of it.
        Assert.DoesNotContain(app.Intents(), i => !Does(i, "settingsOpen"));
    }

    [Fact]
    public void TurnedOffInStartupAppsItShowsOffAndTurningItOnWins()
    {
        using var app = new RunningApp("asking", next: ["settings"]);
        using (var run = Registry.CurrentUser.CreateSubKey(RunningApp.LoginKey + @"\Run"))
            run.SetValue(ProgramName, Quoted(RunningApp.App));
        using (var approved = Registry.CurrentUser.CreateSubKey(RunningApp.LoginKey + @"\Explorer\StartupApproved\Run"))
            approved.SetValue(ProgramName, new byte[] { 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, RegistryValueKind.Binary);

        var window = OpenFromMenu(app);
        var login = app.Find(window, "Login");
        Assert.Equal(ToggleState.Off, login.Patterns.Toggle.Pattern.ToggleState.Value);

        RunningApp.Press(login);
        RunningApp.Until(() => RunningApp.StartupApproved() is null, "Windows' switch for it gone");
        Assert.Equal(Quoted(RunningApp.App), RunningApp.LoginCommand());
        Assert.Equal(ToggleState.On, login.Patterns.Toggle.Pattern.ToggleState.Value);
    }

    [Fact]
    public void ClosingHidesItTellsTheProgramAndItOpensAgainOnGeneral()
    {
        using var app = new RunningApp("asking", next: ["settings"]);
        var window = OpenFromMenu(app);
        Select(app.Find(window, "Tab.messages"));

        window.Patterns.Window.Pattern.Close();
        app.Sent("settingsClose");
        RunningApp.Until(() => !RunningApp.IsVisible(window), "Settings hidden");
        Assert.False(app.Process.WaitForExit(500), "the app quit");

        // The stand-in's board still has Settings, so it shows on the result.
        RunningApp.Press(app.Find(app.OpenFlyout(), "Settings"));
        RunningApp.Until(() => app.Intents().Count(i => Does(i, "settingsOpen")) == 2, "a second settingsOpen");
        window = app.Settings();
        Assert.True(Selected(app.Find(window, "Tab.general")));
        Assert.True(app.Find(window, "Toggle.enabled").IsEnabled);
    }

    [Fact]
    public void WithTheRealProgramANumberIsSavedAndAPairThatDoesntMakeSenseIsNot()
    {
        Assert.SkipWhen(Program is null, "CONTEXT_GUARD_PROGRAM isn't set");
        var root = Path.Combine(Path.GetTempPath(), "cg-uitest-real-" + Guid.NewGuid().ToString("N")[..8]);
        var home = Path.Combine(root, "home");
        Directory.CreateDirectory(home);
        try
        {
            using var app = new RunningApp(program: Program, programArgs: ["ui"], environment: new Dictionary<string, string>
            {
                ["CONTEXT_GUARD_HOME"] = home,
                ["CLAUDE_CONFIG_DIR"] = Path.Combine(root, "claude"),
            });
            var window = OpenFromMenu(app);
            Select(app.Find(window, "Tab.asking"));
            var config = Path.Combine(home, "config.json");

            app.Find(window, "askK").Patterns.Value.Pattern.SetValue("200");
            RunningApp.Until(() => Number(config, "askAt") == 200_000, "askAt 200000 in config.json");
            RunningApp.Until(() => app.Find(window, "asking.Card1.Status").Name.StartsWith("Saved", StringComparison.Ordinal), "Saved");

            // Wait at 150k, under Ask at: not saved, and the note says why.
            app.Find(window, "laterK").Patterns.Value.Pattern.SetValue("150");
            RunningApp.Until(() => app.Find(window, "asking.Card1.Status").Name == "Not saved", "Not saved");
            Assert.Contains("has to be more than", app.Find(window, "asking.Note1").Name, StringComparison.Ordinal);
            Thread.Sleep(500);
            Assert.Equal(500_000, Number(config, "laterAt") ?? 500_000);
            Assert.Equal(200_000, Number(config, "askAt"));
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); }
            catch (IOException) { }
        }
    }

    // Helpers

    /// <summary>Settings… from the right-click menu, once the board has arrived; then its window.</summary>
    static AutomationElement OpenFromMenu(RunningApp app)
    {
        app.OpenFlyout();   // the board has arrived
        var at = app.Chevron().BoundingRectangle;
        app.RightClickIcon(at.X + at.Width / 2, at.Y);
        var items = RunningApp.Until(() =>
        {
            var found = app.Menu().FindAllDescendants(cf => cf.ByControlType(ControlType.MenuItem));
            return found.Length >= 3 ? found : null;
        }, "the menu's items");
        Assert.Equal("Settings…", items[1].Name);
        RunningApp.Press(items[1]);
        return app.Settings();
    }

    static bool Selected(AutomationElement tab) => tab.Patterns.SelectionItem.Pattern.IsSelected.Value;

    static void Select(AutomationElement tab) => tab.Patterns.SelectionItem.Pattern.Select();

    /// <summary>
    /// A box's text: a number box has the Value pattern; a message box (a RichEditBox, for the Mac's line spacing) has
    /// only the Text pattern, as screen readers read it, with each line break as a carriage return and a final one.
    /// </summary>
    static string Value(AutomationElement box) =>
        box.Patterns.Value.TryGetPattern(out var value)
            ? value.Value.Value
            : box.Patterns.Text.Pattern.DocumentRange.GetText(-1).TrimEnd('\r').Replace('\r', '\n');

    static bool Does(JsonElement intent, string what) => intent.GetProperty("do").GetString() == what;

    static string Quoted(string exe) => $"\"{Path.GetFullPath(exe)}\"";

    /// <summary>A number in a JSON file, or null while it isn't there (or is being written).</summary>
    static int? Number(string file, string name)
    {
        try
        {
            using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var doc = JsonDocument.Parse(stream);
            return doc.RootElement.TryGetProperty(name, out var n) ? n.GetInt32() : null;
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            return null;
        }
    }
}
