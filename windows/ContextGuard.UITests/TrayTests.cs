using System.Diagnostics;
using System.Text.Json;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using Xunit;

// One app per Windows session: every test in one collection, so they take turns.
[assembly: CollectionBehavior(CollectionBehavior.CollectionPerAssembly)]

namespace ContextGuard.UITests;

/// <summary>
/// The tray icon, its flyout and its right-click menu, in the published app, against the contract's boards.
/// Esc in the flyout needs a real key press, so it is checked by hand with a real keyboard, not here.
/// </summary>
public sealed class TrayTests
{
    const string First = "00000000-0000-4000-8000-000000000001";
    const string Second = "00000000-0000-4000-8000-000000000002";
    const string NotRunning = "Context Guard's program isn't running.";

    [Fact]
    public void TheIconOpensTheMenuWithTheBoardsRows()
    {
        using var app = new RunningApp("asking");
        var flyout = app.OpenFlyout();
        var menu = app.Board.GetProperty("menu");

        Assert.Equal(ToggleState.On, app.Find(flyout, "On").Patterns.Toggle.Pattern.ToggleState.Value);
        Assert.Equal(menu.GetProperty("on").GetProperty("label").GetString(), app.Find(flyout, "On").Name);
        Assert.Equal(string.Join("\n", menu.GetProperty("lines").EnumerateArray().Select(l => l.GetString())), app.Find(flyout, "Lines").Name);
        Assert.Equal(menu.GetProperty("heading").GetString(), app.Find(flyout, "Heading").Name);
        foreach (var session in menu.GetProperty("sessions").EnumerateArray())
        {
            var id = session.GetProperty("id").GetString();
            var row = app.Find(flyout, $"Session-{id}");
            Assert.Equal($"{session.GetProperty("title").GetString()}, {session.GetProperty("tokens").GetString()}", row.Name);
            // Closed: its actions aren't shown.
            Assert.False(RunningApp.Has(flyout, $"CompactNow-{id}"));
        }
        Assert.False(RunningApp.Has(flyout, "Empty"));
        Assert.False(RunningApp.Has(flyout, "NotRunning"));
        Assert.True(app.Find(flyout, "Settings").IsEnabled);
        Assert.Equal(menu.GetProperty("quit").GetString(), app.Find(flyout, "Quit").Name);
        Assert.Empty(app.Intents());

        // What you see of it sits 12 DIP from the work area's right and bottom edges.
        var scale = RunningApp.Scale;
        var area = RunningApp.WorkArea();
        RunningApp.Until(() =>
        {
            var seen = RunningApp.VisibleBounds(flyout);
            return Math.Abs(area.Right - seen.Right - 12 * scale) <= 2 && Math.Abs(area.Bottom - seen.Bottom - 12 * scale) <= 2;
        }, $"the flyout in the corner (work area {area}, seen at {RunningApp.VisibleBounds(flyout)})");
    }

    [Fact]
    public void ASessionOpensInPlaceOneAtATime()
    {
        using var app = new RunningApp("asking");
        var flyout = app.OpenFlyout();

        RunningApp.Press(app.Find(flyout, $"Session-{First}"));
        Assert.True(app.Find(flyout, $"CompactNow-{First}").IsEnabled);
        Assert.Equal("Wait until 500k", app.Find(flyout, $"Deferral-{First}").Name);
        Assert.Equal("Show the Question", app.Find(flyout, $"ShowQuestion-{First}").Name);
        Assert.Equal(ToggleState.On, app.Find(flyout, $"Watch-{First}").Patterns.Toggle.Pattern.ToggleState.Value);

        RunningApp.Press(app.Find(flyout, $"Session-{Second}"));
        app.Find(flyout, $"CompactNow-{Second}");
        Assert.False(RunningApp.Has(flyout, $"Deferral-{Second}"));
        RunningApp.Until(() => !RunningApp.Has(flyout, $"CompactNow-{First}"), "the first session closed");
        Assert.True(RunningApp.IsVisible(flyout));
        Assert.Empty(app.Intents());
    }

    [Fact]
    public void CompactNowAsksTheSessionToSaveAndClosesTheMenu()
    {
        using var app = new RunningApp("asking");
        var flyout = app.OpenFlyout();
        RunningApp.Press(app.Find(flyout, $"Session-{First}"));
        RunningApp.Press(app.Find(flyout, $"CompactNow-{First}"));

        var sent = app.Sent("answer");
        Assert.Equal(First, sent.GetProperty("session").GetString());
        Assert.Equal("yes", sent.GetProperty("action").GetString());
        Assert.Equal("menu", sent.GetProperty("source").GetString());
        RunningApp.Until(() => !RunningApp.IsVisible(flyout), "the flyout hidden");
    }

    [Fact]
    public void WaitAndShowTheQuestionAnswerFromTheMenu()
    {
        using var app = new RunningApp("asking");
        var flyout = app.OpenFlyout();
        RunningApp.Press(app.Find(flyout, $"Session-{First}"));
        RunningApp.Press(app.Find(flyout, $"Deferral-{First}"));
        var sent = app.Sent("answer");
        Assert.Equal("later", sent.GetProperty("action").GetString());
        Assert.Equal("menu", sent.GetProperty("source").GetString());
        RunningApp.Until(() => !RunningApp.IsVisible(flyout), "the flyout hidden");

        // It opens again with every session closed.
        flyout = app.OpenFlyout();
        Assert.False(RunningApp.Has(flyout, $"ShowQuestion-{First}"));
        RunningApp.Press(app.Find(flyout, $"Session-{First}"));
        RunningApp.Press(app.Find(flyout, $"ShowQuestion-{First}"));
        Assert.Equal(First, app.Sent("show").GetProperty("session").GetString());
        RunningApp.Until(() => !RunningApp.IsVisible(flyout), "the flyout hidden");
    }

    [Fact]
    public void CompactNowIsOffWhileASaveIsUnderWay()
    {
        using var app = new RunningApp("answered");
        var flyout = app.OpenFlyout();
        RunningApp.Press(app.Find(flyout, $"Session-{First}"));
        Assert.False(app.Find(flyout, $"CompactNow-{First}").IsEnabled);
        Assert.False(RunningApp.Has(flyout, $"Deferral-{First}"));
    }

    [Fact]
    public void TheSwitchTurnsItOffAndLeavesTheMenuOpen()
    {
        using var app = new RunningApp("asking");
        var flyout = app.OpenFlyout();
        RunningApp.Press(app.Find(flyout, "On"));

        Assert.False(app.Sent("enable").GetProperty("on").GetBoolean());
        Assert.True(RunningApp.IsVisible(flyout));
    }

    [Fact]
    public void WatchStopsWatchingTheSessionAndLeavesTheMenuOpen()
    {
        using var app = new RunningApp("asking");
        var flyout = app.OpenFlyout();
        RunningApp.Press(app.Find(flyout, $"Session-{First}"));
        RunningApp.Press(app.Find(flyout, $"Watch-{First}"));

        var sent = app.Sent("watch");
        Assert.Equal(First, sent.GetProperty("session").GetString());
        Assert.False(sent.GetProperty("on").GetBoolean());
        Assert.True(RunningApp.IsVisible(flyout));
    }

    [Fact]
    public void NoSessionsSaysSo()
    {
        using var app = new RunningApp("empty");
        var flyout = app.OpenFlyout();
        Assert.Equal(app.Board.GetProperty("menu").GetProperty("empty").GetString(), app.Find(flyout, "Empty").Name);
        Assert.False(RunningApp.Has(flyout, "Heading"));
    }

    [Fact]
    public void TheMenuHidesWhenItLosesFocusOrTheIconIsClickedAgain()
    {
        using var app = new RunningApp("asking");
        var flyout = app.OpenFlyout();

        // Opening the overflow takes the focus.
        RunningApp.Press(app.Chevron());
        RunningApp.Until(() => !RunningApp.IsVisible(flyout), "the flyout hidden after losing focus");
        app.CloseOverflow();

        flyout = app.OpenFlyout();
        // Focus starts inside, on the first control.
        RunningApp.Until(() => app.Find(flyout, "On").Properties.HasKeyboardFocus.ValueOrDefault, "focus on the On switch");
        app.ClickIcon();
        RunningApp.Until(() => !RunningApp.IsVisible(flyout), "the flyout hidden by a second click");
    }

    [Fact]
    public void TheRightClickMenuTurnsItOff()
    {
        using var app = new RunningApp("asking");
        app.OpenFlyout();   // the board has arrived
        var at = app.Chevron().BoundingRectangle;
        app.RightClickIcon(at.X + at.Width / 2, at.Y);

        var items = RunningApp.Until(() =>
        {
            var found = app.Menu().FindAllDescendants(cf => cf.ByControlType(ControlType.MenuItem));
            return found.Length >= 3 ? found : null;
        }, "the menu's items");
        Assert.Equal(new[] { "Context Guard On", "Settings…", "Quit Context Guard" }, items.Select(i => i.Name).ToArray());
        Assert.True(items[1].IsEnabled);
        RunningApp.Press(items[0]);

        Assert.False(app.Sent("enable").GetProperty("on").GetBoolean());
    }

    [Fact]
    public void QuitEndsTheAppAndItsProgram()
    {
        using var app = new RunningApp("asking");
        var flyout = app.OpenFlyout();
        var standIn = Process.GetProcessById(app.StandIn);
        RunningApp.Press(app.Find(flyout, "Quit"));

        Assert.True(app.Process.WaitForExit(10_000), "the app is still running");
        Assert.True(standIn.WaitForExit(10_000), "the stand-in is still running");
    }

    [Fact]
    public void WmCloseOnTheTrayWindowQuits()
    {
        using var app = new RunningApp("asking");
        app.OpenFlyout();
        var standIn = Process.GetProcessById(app.StandIn);

        Assert.True(app.Close(), "the app is still running");
        Assert.True(standIn.WaitForExit(10_000), "the stand-in is still running");
        Assert.Equal(0, app.Process.ExitCode);
    }

    [Fact]
    public void WithoutItsProgramItSaysSo()
    {
        using var app = new RunningApp(program: @"C:\nowhere\context-guard.exe");
        var flyout = app.OpenFlyout(board: false);

        Assert.Equal(NotRunning, app.Find(flyout, "NotRunning").Name);
        // Focus starts on its only control, even on this first open, when the flyout's content isn't loaded yet.
        RunningApp.Until(() => app.Find(flyout, "Quit").Properties.HasKeyboardFocus.ValueOrDefault, "focus on Quit");
        Assert.Equal("Quit Context Guard", app.Find(flyout, "Quit").Name);
        Assert.False(RunningApp.Has(flyout, "On"));
        RunningApp.Until(() => app.Icon().Name.Contains(NotRunning, StringComparison.Ordinal), "the icon's tooltip");
    }

    [Fact]
    public void ASecondCopyLeavesAtOnce()
    {
        using var app = new RunningApp("asking");
        using var second = Process.Start(app.Start("asking"))!;

        Assert.True(second.WaitForExit(10_000), "the second copy is still running");
        Assert.False(app.Process.HasExited);
        app.OpenFlyout();
    }
}
