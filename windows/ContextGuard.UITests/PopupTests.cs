using System.Text.Json;
using FlaUI.Core.AutomationElements;
using Xunit;

namespace ContextGuard.UITests;

/// <summary>
/// The question popups and notices, in the published app, against the contract's boards: their words, what their
/// buttons send, how they follow a new board, where they stack, and that they never take the foreground. A real
/// click while you type in a terminal needs real input, so that is checked by hand with a real mouse, not here.
/// </summary>
public sealed class PopupTests
{
    const string First = "00000000-0000-4000-8000-000000000001";

    static JsonElement Popup(JsonElement board, int i) => board.GetProperty("popups")[i];

    static string? Text(JsonElement e, string name) => e.TryGetProperty(name, out var v) ? v.GetString() : null;

    [Theory]
    [InlineData("asking")]
    [InlineData("asking-no-countdown")]
    [InlineData("codex")]
    public void AQuestionShowsTheBoardsWords(string board)
    {
        using var app = new RunningApp(board, chime: true);
        var popup = Popup(app.Board, 0);
        var question = popup.GetProperty("question");
        var ask = question.GetProperty("ask");
        var window = app.Popup(RunningApp.PopupName(popup));

        Assert.Equal(Text(question, "heading"), app.Find(window, "Heading").Name);
        Assert.Equal(Text(question, "title"), app.Find(window, "Title").Name);
        // Whole, though the line may be cut in the middle.
        Assert.Equal(Text(question, "subtitle"), app.Find(window, "Subtitle").Name);
        Assert.Equal(Text(ask, "text"), app.Find(window, "Text").Name);
        if (Text(ask, "countdown") is { } countdown) Assert.Equal(countdown, app.Find(window, "Countdown").Name);
        else Assert.False(RunningApp.Has(window, "Countdown"));
        Assert.Equal(Text(ask.GetProperty("turnOff"), "label"), app.Find(window, "TurnOff").Name);
        Assert.Equal(Text(ask.GetProperty("deferral"), "label"), app.Find(window, "Deferral").Name);
        Assert.Equal(Text(ask.GetProperty("compact"), "label"), app.Find(window, "Compact").Name);
        // ✕ only when the board gives it: never while it counts down.
        if (ask.TryGetProperty("hide", out var hide)) Assert.Equal(Text(hide, "label"), app.Find(window, "Dismiss").Name);
        else Assert.False(RunningApp.Has(window, "Dismiss"));
        Assert.False(RunningApp.Has(window, "Progress"));
        Assert.Empty(app.Intents());
    }

    [Fact]
    public void CompactAnswersFromThePopupThenItSaysHowThatIsGoing()
    {
        using var app = new RunningApp("asking", next: ["answered"]);
        var window = app.Popup(RunningApp.PopupName(Popup(app.Board, 0)));
        RunningApp.Press(app.Find(window, "Compact"));

        var sent = app.Sent("answer");
        Assert.Equal(First, sent.GetProperty("session").GetString());
        Assert.Equal("yes", sent.GetProperty("action").GetString());
        Assert.Equal("popup", sent.GetProperty("source").GetString());

        // The answered board: each question says how its answer is going, in place of the question.
        foreach (var popup in RunningApp.ReadBoard("answered").GetProperty("popups").EnumerateArray())
        {
            var answered = app.Popup(RunningApp.PopupName(popup));
            var progress = popup.GetProperty("question").GetProperty("progress");
            RunningApp.Until(() => RunningApp.Has(answered, "Progress"), "the progress line");
            Assert.Equal(Text(progress, "text"), app.Find(answered, "Progress").Name);
            Assert.False(RunningApp.Has(answered, "Compact"));
            Assert.False(RunningApp.Has(answered, "Dismiss"));
        }
        Assert.Equal(3, app.Popups().Length);
    }

    [Fact]
    public void WaitAndTurnOffAnswerFromThePopup()
    {
        using var app = new RunningApp("asking");
        var window = app.Popup(RunningApp.PopupName(Popup(app.Board, 0)));

        RunningApp.Press(app.Find(window, "Deferral"));
        var sent = app.Sent("answer");
        Assert.Equal(First, sent.GetProperty("session").GetString());
        Assert.Equal("later", sent.GetProperty("action").GetString());
        Assert.Equal("popup", sent.GetProperty("source").GetString());

        RunningApp.Press(app.Find(window, "TurnOff"));
        app.Sent("turnOff");
    }

    [Fact]
    public void NotNowAndTheCrossWithoutACountdown()
    {
        using var app = new RunningApp("asking-no-countdown");
        var window = app.Popup(RunningApp.PopupName(Popup(app.Board, 0)));

        RunningApp.Press(app.Find(window, "Deferral"));
        Assert.Equal("skip", app.Sent("answer").GetProperty("action").GetString());

        // ✕ hides the question until it asks again.
        RunningApp.Press(app.Find(window, "Dismiss"));
        Assert.Equal(First, app.Sent("hide").GetProperty("session").GetString());
    }

    [Fact]
    public void NoticesShowTheirWordsAndStackAtTheBottomRightInTheBoardsOrder()
    {
        using var app = new RunningApp("notices");
        var popups = app.Board.GetProperty("popups").EnumerateArray().ToList();
        var windows = popups.Select(p => app.Popup(RunningApp.PopupName(p))).ToList();

        foreach (var (popup, window) in popups.Zip(windows))
        {
            var notice = popup.GetProperty("notice");
            Assert.Equal(Text(notice, "title"), app.Find(window, "Heading").Name);
            Assert.Equal(Text(notice, "detail"), app.Find(window, "Detail").Name);
            Assert.Equal(Text(notice, "caption"), app.Find(window, "Caption").Name);
            Assert.Equal(Text(notice, "close"), app.Find(window, "Dismiss").Name);
        }

        // Bottom up from the corner, the board's last nearest it: what you see of each 12 DIP from the work area's
        // edges and 10 DIP from the next, 400 DIP wide (and the 1 px edge Windows draws round each).
        var scale = RunningApp.Scale;
        var area = RunningApp.WorkArea();
        RunningApp.Until(() =>
        {
            var seen = windows.Select(RunningApp.VisibleBounds).ToList();
            return Near(area.Bottom - seen[^1].Bottom, 12 * scale)
                && seen.All(r => Near(area.Right - r.Right, 12 * scale) && r.Width >= 400 * scale && r.Width <= 400 * scale + 4)
                && seen.Zip(seen.Skip(1)).All(pair => Near(pair.Second.Top - pair.First.Bottom, 10 * scale));
        }, $"the notices stacked (work area {area}, seen at {string.Join(" ", windows.Select(RunningApp.VisibleBounds))})");
    }

    static bool Near(double actual, double expected) => Math.Abs(actual - expected) <= 2;

    [Fact]
    public void TheCrossClosesANotice()
    {
        using var app = new RunningApp("notices");
        var popup = Popup(app.Board, 1);
        var window = app.Popup(RunningApp.PopupName(popup));
        RunningApp.Press(app.Find(window, "Dismiss"));
        Assert.Equal(popup.GetProperty("key").GetString(), app.Sent("close").GetProperty("key").GetString());
    }

    [Fact]
    public void APopupClosesWhenTheBoardDropsIt()
    {
        using var app = new RunningApp("asking", next: ["empty"]);
        var window = app.Popup(RunningApp.PopupName(Popup(app.Board, 0)));
        RunningApp.Press(app.Find(window, "Compact"));
        app.Sent("answer");
        RunningApp.Until(() => app.Popups().Length == 0, "no popups");
    }

    [Fact]
    public void PopupsNeverTakeTheForeground()
    {
        using var app = new RunningApp("notices");
        var windows = app.Board.GetProperty("popups").EnumerateArray().Select(p => app.Popup(RunningApp.PopupName(p))).ToList();
        var handles = windows.Select(w => w.Properties.NativeWindowHandle.Value).ToHashSet();
        Assert.DoesNotContain(RunningApp.Foreground, handles);

        RunningApp.Press(app.Find(windows[0], "Dismiss"));
        app.Sent("close");
        Thread.Sleep(300);
        Assert.DoesNotContain(RunningApp.Foreground, handles);
    }
}
