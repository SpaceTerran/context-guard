using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace ContextGuard.Feed;

/// <summary>
/// Runs <c>context-guard ui</c> and talks to it over its stdin and stdout, one JSON object per line.
/// The program does the work and says what to show; this reads its lines into events and writes
/// intents. If the program exits, it starts again after a moment (longer each time it exits soon
/// after starting); its first board then replaces the last one. Settings' draft is the program's,
/// so after <see cref="Exited"/> an app with Settings open sends <see cref="Intent.SettingsOpen"/> again.
/// </summary>
/// <remarks>
/// Events are raised on the synchronization context that called <see cref="Start"/> (the UI thread in
/// the app), or on a thread-pool thread when there is none.
/// </remarks>
public sealed class FeedClient : IAsyncDisposable
{
    /// <summary>The version of the lines this reads and writes.</summary>
    public const int Version = 1;

    /// <summary>How long a run must last for the next exit to count as the first.</summary>
    static readonly TimeSpan StableAfter = TimeSpan.FromSeconds(60);
    static readonly TimeSpan[] Backoff =
        [TimeSpan.FromSeconds(0.5), TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(15), TimeSpan.FromSeconds(30)];
    static readonly UTF8Encoding Utf8 = new(encoderShouldEmitUTF8Identifier: false);

    readonly string program;
    readonly IReadOnlyList<string> arguments;
    readonly IReadOnlyDictionary<string, string?> environment;
    readonly ConcurrentDictionary<string, TaskCompletionSource<FeedResult>> pending = new();
    readonly CancellationTokenSource stopping = new();
    readonly Lock gate = new();
    SynchronizationContext? context;
    Process? process;
    Task? runner;
    bool disposed;
    long lastId;

    /// <param name="program">context-guard.exe.</param>
    /// <param name="environment">Variables to set (or, with null, remove) for it, on top of this process's own.</param>
    /// <param name="arguments">Its arguments; <c>ui</c> unless a test runs something else.</param>
    public FeedClient(string program, IReadOnlyDictionary<string, string?>? environment = null, IReadOnlyList<string>? arguments = null)
    {
        this.program = program;
        this.environment = environment ?? new Dictionary<string, string?>();
        this.arguments = arguments ?? ["ui"];
    }

    /// <summary>The whole board, at start and whenever it changes.</summary>
    public event Action<Board>? BoardChanged;
    /// <summary>A question popup just opened: play the sound.</summary>
    public event Action? Chime;
    /// <summary>What became of an intent (also what <see cref="SendAsync"/> returns), or a problem at start (no id).</summary>
    public event Action<FeedResult>? Result;
    /// <summary>A line the program couldn't read, one this couldn't read, or why the program couldn't start.</summary>
    public event Action<string>? Error;
    /// <summary>The program exited with this code; it starts again after a moment.</summary>
    public event Action<int>? Exited;

    /// <summary>The latest board, or null before the first.</summary>
    public Board? Board { get; private set; }

    public void Start()
    {
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (runner is not null) throw new InvalidOperationException("Already started.");
            context = SynchronizationContext.Current;
            runner = Task.Run(() => RunAsync(stopping.Token));
        }
    }

    /// <summary>
    /// Sends what you did and returns its result. While the program isn't running (it's starting
    /// again), the result says so.
    /// </summary>
    public Task<FeedResult> SendAsync(Intent intent)
    {
        var id = Interlocked.Increment(ref lastId).ToString(CultureInfo.InvariantCulture);
        var line = JsonSerializer.Serialize(intent with { Id = id }, FeedJson.Default.Intent);
        var reply = new TaskCompletionSource<FeedResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        pending[id] = reply;
        lock (gate)
        {
            try
            {
                if (process is null) throw new IOException("not running");
                process.StandardInput.WriteLine(line);
            }
            catch (Exception e) when (e is IOException or ObjectDisposedException or InvalidOperationException)
            {
                pending.TryRemove(id, out _);
                return Task.FromResult(new FeedResult(id, "Context Guard's program isn't running."));
            }
        }
        return reply.Task;
    }

    /// <summary>
    /// Closes the program's stdin, which ends it; ends it by force if it hasn't gone after 3 seconds.
    /// Calling it again does nothing.
    /// </summary>
    public async ValueTask DisposeAsync()
    {
        Task? running;
        lock (gate)
        {
            if (disposed) return;
            disposed = true;
            running = runner;
        }
        // Cancelled first, so a program starting from now on closes its own input (RunOnceAsync).
        await stopping.CancelAsync().ConfigureAwait(false);
        lock (gate)
        {
            if (process is { } p) CloseInput(p);
        }
        if (running is not null)
        {
            if (await Task.WhenAny(running, Task.Delay(TimeSpan.FromSeconds(3))).ConfigureAwait(false) != running)
            {
                Process? p;
                lock (gate) p = process;
                try { p?.Kill(entireProcessTree: true); }
                catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception) { }
            }
            await running.ConfigureAwait(false);
        }
        FailPending();
        stopping.Dispose();
    }

    static void CloseInput(Process p)
    {
        try { p.StandardInput.Close(); }
        catch (Exception e) when (e is IOException or InvalidOperationException or ObjectDisposedException) { }
    }

    async Task RunAsync(CancellationToken stop)
    {
        var quickExits = 0;
        while (!stop.IsCancellationRequested)
        {
            var ran = Stopwatch.StartNew();
            int code;
            try
            {
                code = await RunOnceAsync().ConfigureAwait(false);
            }
            catch (Exception e) when (e is System.ComponentModel.Win32Exception or IOException or InvalidOperationException)
            {
                Raise(Error, $"Couldn't run {program}: {e.Message}");
                code = -1;
            }
            FailPending();
            if (stop.IsCancellationRequested) return;
            Raise(Exited, code);
            quickExits = ran.Elapsed >= StableAfter ? 0 : quickExits + 1;
            try
            {
                await Task.Delay(Backoff[Math.Min(quickExits, Backoff.Length - 1)], stop).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    /// <summary>Runs the program until its stdout closes; returns its exit code.</summary>
    async Task<int> RunOnceAsync()
    {
        var info = new ProcessStartInfo(program)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardInputEncoding = Utf8,
            StandardOutputEncoding = Utf8,
            StandardErrorEncoding = Utf8,
        };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        foreach (var (name, value) in environment)
        {
            if (value is null) info.Environment.Remove(name);
            else info.Environment[name] = value;
        }

        using var p = Process.Start(info) ?? throw new InvalidOperationException("no process");
        p.StandardInput.NewLine = "\n";
        p.StandardInput.AutoFlush = true;
        lock (gate)
        {
            process = p;
            // Disposed while it started: ended as DisposeAsync ends one that was running.
            if (stopping.IsCancellationRequested) CloseInput(p);
        }
        // Its stderr is read so it can't fill up and stall it; the program writes nothing there in use.
        var errors = p.StandardError.ReadToEndAsync();
        try
        {
            while (await p.StandardOutput.ReadLineAsync().ConfigureAwait(false) is { } line)
            {
                if (line.Length > 0) Read(line);
            }
        }
        finally
        {
            lock (gate) process = null;
        }
        await p.WaitForExitAsync().ConfigureAwait(false);
        await errors.ConfigureAwait(false);
        return p.ExitCode;
    }

    void Read(string line)
    {
        FeedMessage? message;
        try
        {
            message = JsonSerializer.Deserialize(line, FeedJson.Default.FeedMessage);
        }
        catch (JsonException e)
        {
            Raise(Error, $"Not a message ({e.Message}): {Shorten(line)}");
            return;
        }
        if (message is null || message.V != Version)
        {
            Raise(Error, $"Not a version {Version} message: {Shorten(line)}");
            return;
        }
        switch (message.Type)
        {
            case "board" when message.Board is { } board:
                Board = board;
                Raise(BoardChanged, board);
                break;
            case "chime":
                Raise(Chime);
                break;
            case "result":
                var result = new FeedResult(message.Id, message.Problem);
                if (message.Id is { } id && pending.TryRemove(id, out var reply)) reply.TrySetResult(result);
                Raise(Result, result);
                break;
            case "error":
                Raise(Error, message.Message ?? "");
                break;
            default:
                Raise(Error, $"Not a message this knows: {Shorten(line)}");
                break;
        }
    }

    /// <summary>Intents the program can no longer answer: it exited before it did.</summary>
    void FailPending()
    {
        foreach (var id in pending.Keys)
        {
            if (pending.TryRemove(id, out var reply)) reply.TrySetResult(new FeedResult(id, "Context Guard's program stopped before it answered."));
        }
    }

    static string Shorten(string line) => line.Length <= 200 ? line : line[..200];

    void Raise(Action? handler)
    {
        if (handler is null) return;
        if (context is { } c) c.Post(_ => handler(), null);
        else handler();
    }

    void Raise<T>(Action<T>? handler, T value)
    {
        if (handler is null) return;
        if (context is { } c) c.Post(_ => handler(value), null);
        else handler(value);
    }
}
