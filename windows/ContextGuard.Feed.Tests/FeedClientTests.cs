using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading.Channels;
using Xunit;

namespace ContextGuard.Feed.Tests;

/// <summary>
/// The client with the real program, when CONTEXT_GUARD_PROGRAM names it (CI: the build's
/// context-guard.exe), and with stand-ins that exit or say things it can't read.
/// </summary>
public sealed class FeedClientTests
{
    static readonly TimeSpan Wait = TimeSpan.FromSeconds(20);

    static string? Program => Environment.GetEnvironmentVariable("CONTEXT_GUARD_PROGRAM") is { Length: > 0 } p ? p : null;

    static CancellationToken Token => TestContext.Current.CancellationToken;

    [Fact]
    public async Task TheProgramsBoardsAndResults()
    {
        Assert.SkipWhen(Program is null, "CONTEXT_GUARD_PROGRAM isn't set");
        using var folder = new TempFolder();
        await using var client = new FeedClient(Program!, folder.Environment);
        var boards = Channel.CreateUnbounded<Board>();
        client.BoardChanged += b => boards.Writer.TryWrite(b);
        client.Start();

        var first = await Next(boards);
        Assert.Equal("on", first.Tray.State);
        Assert.Equal("No sessions running", first.Menu.Empty);
        Assert.Same(first, client.Board);

        var result = await client.SendAsync(Intent.Enable(false)).WaitAsync(Wait, Token);
        Assert.True(result.Succeeded, result.Problem);
        Assert.Equal("1", result.Id);
        while ((await Next(boards)).Tray.State != "off") { }
        var config = JsonNode.Parse(File.ReadAllText(Path.Combine(folder.Home, "config.json")))!;
        Assert.False(config["enabled"]!.GetValue<bool>());

        var refused = await client.SendAsync(Intent.Set(SettingsField.AskK, "200")).WaitAsync(Wait, Token);
        Assert.Equal(new FeedResult("2", "Settings isn't open."), refused);

        // Its input closed, it ends by itself, well before it would be ended by force.
        var ending = Stopwatch.StartNew();
        await client.DisposeAsync();
        Assert.True(ending.Elapsed < TimeSpan.FromSeconds(2.5), $"took {ending.Elapsed}");
        Assert.Equal(new FeedResult("3", "Context Guard's program isn't running."), await client.SendAsync(Intent.TurnOff()));
    }

    [Fact]
    public async Task TheProgramEndsWhenItsInputCloses()
    {
        Assert.SkipWhen(Program is null, "CONTEXT_GUARD_PROGRAM isn't set");
        using var folder = new TempFolder();
        var info = new ProcessStartInfo(Program!)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            ArgumentList = { "ui" },
        };
        foreach (var (name, value) in folder.Environment) info.Environment[name] = value;
        using var p = Process.Start(info)!;
        var first = await p.StandardOutput.ReadLineAsync(Token).AsTask().WaitAsync(Wait, Token);
        Assert.Contains("\"type\":\"board\"", first, StringComparison.Ordinal);
        p.StandardInput.Close();
        await p.WaitForExitAsync(Token).WaitAsync(Wait, Token);
        Assert.Equal(0, p.ExitCode);
    }

    [Fact]
    public async Task BeforeItRunsAnIntentSaysSo()
    {
        await using var client = new FeedClient(Path.Combine(Path.GetTempPath(), "no-such-context-guard.exe"));
        Assert.Equal(new FeedResult("1", "Context Guard's program isn't running."), await client.SendAsync(Intent.TurnOff()));
    }

    [Fact]
    public async Task AProgramThatIsntThereIsAnError()
    {
        await using var client = new FeedClient(Path.Combine(Path.GetTempPath(), "no-such-context-guard.exe"));
        var errors = Channel.CreateUnbounded<string>();
        var exits = Channel.CreateUnbounded<int>();
        client.Error += e => errors.Writer.TryWrite(e);
        client.Exited += code => exits.Writer.TryWrite(code);
        client.Start();
        Assert.StartsWith("Couldn't run ", await Next(errors), StringComparison.Ordinal);
        Assert.Equal(-1, await Next(exits));
    }

    [Fact]
    public async Task AProgramThatExitsStartsAgain()
    {
        await using var client = StandIn(["{\"v\":1,\"type\":\"chime\"}"]);
        var exits = Channel.CreateUnbounded<int>();
        var chimes = Channel.CreateUnbounded<bool>();
        client.Exited += code => exits.Writer.TryWrite(code);
        client.Chime += () => chimes.Writer.TryWrite(true);
        client.Start();
        Assert.True(await Next(chimes));
        Assert.Equal(3, await Next(exits));
        Assert.True(await Next(chimes), "it ran again");
        Assert.Equal(3, await Next(exits));
    }

    [Fact]
    public async Task DisposingWhileItWaitsToStartAgain()
    {
        await using var client = StandIn(["{\"v\":1,\"type\":\"chime\"}"]);
        var exits = Channel.CreateUnbounded<int>();
        client.Exited += code => exits.Writer.TryWrite(code);
        client.Start();
        Assert.Equal(3, await Next(exits));

        var ending = Stopwatch.StartNew();
        await client.DisposeAsync();
        Assert.True(ending.Elapsed < TimeSpan.FromSeconds(2.5), $"took {ending.Elapsed}");
        await client.DisposeAsync();
        Assert.Throws<ObjectDisposedException>(client.Start);
    }

    [Fact]
    public async Task AProgramThatKeepsRunningIsEndedByForce()
    {
        await using var client = Stubborn();
        var errors = Channel.CreateUnbounded<string>();
        client.Error += e => errors.Writer.TryWrite(e);
        client.Start();
        using var program = Process.GetProcessById(int.Parse(await Next(errors), System.Globalization.CultureInfo.InvariantCulture));

        var ending = Stopwatch.StartNew();
        await client.DisposeAsync().AsTask().WaitAsync(Wait, Token);
        Assert.InRange(ending.Elapsed, TimeSpan.FromSeconds(2.9), TimeSpan.FromSeconds(10));
        Assert.True(program.WaitForExit(TimeSpan.FromSeconds(5)), "it was ended");
    }

    [Fact]
    public async Task LinesItCantReadAreErrors()
    {
        await using var client = StandIn([
            "nonsense",
            "{\"v\":2,\"type\":\"chime\"}",
            "{\"v\":1,\"type\":\"fly\"}",
            "{\"v\":1,\"type\":\"error\",\"message\":\"not an intent: x\"}",
            "{\"v\":1,\"type\":\"result\",\"problem\":\"couldn't write the settings file.\"}",
        ]);
        var errors = Channel.CreateUnbounded<string>();
        var results = Channel.CreateUnbounded<FeedResult>();
        client.Error += e => errors.Writer.TryWrite(e);
        client.Result += r => results.Writer.TryWrite(r);
        client.Start();
        Assert.StartsWith("Not a message (", await Next(errors), StringComparison.Ordinal);
        Assert.Equal("Not a version 1 message: {\"v\":2,\"type\":\"chime\"}", await Next(errors));
        Assert.Equal("Not a message this knows: {\"v\":1,\"type\":\"fly\"}", await Next(errors));
        Assert.Equal("not an intent: x", await Next(errors));
        Assert.Equal(new FeedResult(null, "couldn't write the settings file."), await Next(results));
    }

    static async Task<T> Next<T>(Channel<T> channel) => await channel.Reader.ReadAsync(Token).AsTask().WaitAsync(Wait, Token);

    /// <summary>A program that writes these lines (ASCII) and exits with 3.</summary>
    static FeedClient StandIn(string[] lines)
    {
        if (OperatingSystem.IsWindows())
        {
            var script = string.Concat(lines.Select(l => $"[Console]::Out.WriteLine('{l.Replace("'", "''", StringComparison.Ordinal)}'); ")) + "exit 3";
            var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
            return new FeedClient("powershell.exe", null, ["-NoProfile", "-NonInteractive", "-EncodedCommand", encoded]);
        }
        var sh = string.Concat(lines.Select(l => $"printf '%s\\n' '{l.Replace("'", "'\\''", StringComparison.Ordinal)}'; ")) + "exit 3";
        return new FeedClient("/bin/sh", null, ["-c", sh]);
    }

    /// <summary>A program that says its process id in an error line and then runs on, its input closed or not.</summary>
    static FeedClient Stubborn()
    {
        if (OperatingSystem.IsWindows())
        {
            const string script = "[Console]::Out.WriteLine('{\"v\":1,\"type\":\"error\",\"message\":\"' + $PID + '\"}'); Start-Sleep -Seconds 600";
            var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
            return new FeedClient("powershell.exe", null, ["-NoProfile", "-NonInteractive", "-EncodedCommand", encoded]);
        }
        return new FeedClient("/bin/sh", null, ["-c", "printf '{\"v\":1,\"type\":\"error\",\"message\":\"%s\"}\\n' $$; exec sleep 600"]);
    }

    /// <summary>A scratch Context Guard folder and Claude Code folder, removed afterwards.</summary>
    sealed class TempFolder : IDisposable
    {
        public string Root { get; } = Path.Combine(Path.GetTempPath(), "cg-feed-tests-" + Guid.NewGuid().ToString("N"));

        public TempFolder() => Directory.CreateDirectory(Root);

        public string Home => Path.Combine(Root, "home");

        public IReadOnlyDictionary<string, string?> Environment => new Dictionary<string, string?>
        {
            ["CONTEXT_GUARD_HOME"] = Home,
            ["CLAUDE_CONFIG_DIR"] = Path.Combine(Root, "claude"),
        };

        public void Dispose()
        {
            try { Directory.Delete(Root, recursive: true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
