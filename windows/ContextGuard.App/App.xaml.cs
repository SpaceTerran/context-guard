using ContextGuard.Feed;
using Microsoft.UI.Xaml;

namespace ContextGuard.App;

/// <summary>
/// The tray app. It runs <c>context-guard ui</c> (<see cref="FeedClient"/>), draws each board it sends, and
/// sends back what you click. Everything it shows comes from the board, except what it says while the
/// program isn't running. One per Windows session; it runs with no window open until you quit it.
/// </summary>
public partial class App : Application
{
    /// <summary>The words the app has before (or without) a board.</summary>
    internal const string Name = "Context Guard";
    internal const string NotRunning = "Context Guard's program isn't running.";
    internal const string QuitFallback = "Quit Context Guard";

    const int MenuOn = 1, MenuSettings = 2, MenuQuit = 3;

    static Mutex? single;
    Tray? tray;
    FeedClient? client;
    FlyoutWindow? flyout;
    Board? board;
    bool programDown, quitting;

    public App()
    {
        InitializeComponent();
        // A tray app: it keeps running with no window open, until Quit.
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;
        UnhandledException += (_, e) => Log.Write($"unhandled: {e.Exception}");
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        single = new Mutex(true, @"Local\ContextGuard.App", out var first);
        if (!first)
        {
            Log.Write("already running in this session; leaving");
            Exit();
            return;
        }
        var options = Options.Parse(Environment.GetCommandLineArgs().Skip(1).ToArray(), Environment.GetEnvironmentVariable);
        Log.Write($"started: {options.Program} {string.Join(' ', options.Arguments)}");

        tray = new Tray(this);
        tray.Show("on", Name);

        client = new FeedClient(options.Program, null, options.Arguments);
        client.BoardChanged += OnBoard;
        client.Exited += code =>
        {
            Log.Write($"the program exited ({code}); it starts again in a moment");
            programDown = true;
            tray?.Show("off", NotRunning);
            flyout?.Render(board, programDown);
        };
        client.Error += message => Log.Write($"program: {message}");
        client.Result += result =>
        {
            if (result.Id is null && result.Problem is { } problem) Log.Write($"program: {problem}");
        };
        // Started on the UI thread, so its events arrive here.
        client.Start();
    }

    void OnBoard(Board newBoard)
    {
        board = newBoard;
        programDown = false;
        tray?.Show(newBoard.Tray.State, newBoard.Tray.Label);
        flyout?.Render(newBoard, programDown);
    }

    /// <summary>Sends what you clicked; beeps if it couldn't be done.</summary>
    internal async void Send(Intent intent)
    {
        if (client is null) return;
        var result = await client.SendAsync(intent);
        if (result.Problem is { } problem)
        {
            Log.Write($"{intent.Do}: {problem}");
            Native.MessageBeep(Native.MB_OK);
        }
    }

    /// <summary>A left click on the icon, or Enter or Space on it.</summary>
    internal void ToggleFlyout(bool keyboard)
    {
        if (quitting) return;
        flyout ??= new FlyoutWindow(this);
        flyout.Toggle(board, programDown, keyboard);
    }

    /// <summary>A right click on the icon: On, Settings… and Quit.</summary>
    internal void ShowTrayMenu(int x, int y)
    {
        if (tray is null || quitting) return;
        flyout?.Hide();
        var menu = board is { } b && !programDown ? b.Menu : null;
        var items = new List<TrayMenuItem>();
        if (menu is not null)
        {
            items.Add(new(MenuOn, menu.On.Label, Checked: menu.On.On));
            // Settings opens in 6c.
            items.Add(new(MenuSettings, menu.Settings, Enabled: false));
            items.Add(TrayMenuItem.Separator);
        }
        items.Add(new(MenuQuit, menu?.Quit ?? QuitFallback));
        switch (tray.Menu(x, y, items))
        {
            case MenuOn when menu is not null:
                Send(Intent.Enable(!menu.On.On));
                break;
            case MenuQuit:
                Quit();
                break;
        }
    }

    /// <summary>Quit, from the menu, the flyout or <c>WM_CLOSE</c> on the tray window: ends the program too.</summary>
    internal async void Quit()
    {
        if (quitting) return;
        quitting = true;
        Log.Write("quit");
        flyout?.CloseForQuit();
        tray?.Remove();
        if (client is not null) await client.DisposeAsync();
        single?.ReleaseMutex();
        Exit();
    }
}
