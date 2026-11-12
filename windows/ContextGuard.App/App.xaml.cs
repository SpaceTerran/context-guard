using ContextGuard.Feed;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace ContextGuard.App;

/// <summary>
/// The tray app. It runs <c>context-guard ui</c> (<see cref="FeedClient"/>), draws each board it sends, and
/// sends back what you click. Everything it shows comes from the board, except what it says while the
/// program isn't running. One per Windows session (<see cref="Program"/>); it runs with no window open until
/// you quit it.
/// </summary>
public partial class App : Application
{
    /// <summary>The words the app has before (or without) a board.</summary>
    internal const string Name = "Context Guard";
    internal const string NotRunning = "Context Guard's program isn't running.";
    internal const string QuitFallback = "Quit Context Guard";

    const int MenuOn = 1, MenuSettings = 2, MenuQuit = 3;

    Tray? tray;
    FeedClient? client;
    FlyoutWindow? flyout;
    Popups? popups;
    SettingsWindow? settings;
    LoginItem? login;
    DispatcherQueue? queue;
    Board? board;
    bool programDown, quitting, openingSettings;

    public App()
    {
        InitializeComponent();
        // A tray app: it keeps running with no window open, until Quit.
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;
        UnhandledException += (_, e) => Log.Write($"unhandled: {e.Exception}");
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // One copy per session and the command line are seen to before this (Program).
        var options = Program.Options;
        Log.Write($"started: {options.Program} {string.Join(' ', options.Arguments)}");

        queue = DispatcherQueue.GetForCurrentThread();
        login = new LoginItem(options.LoginKey, Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "ContextGuard.exe"));
        tray = new Tray(this);
        tray.Show("on", Name);
        popups = new Popups(Send);

        client = new FeedClient(options.Program, null, options.Arguments);
        client.BoardChanged += OnBoard;
        client.Exited += code =>
        {
            Log.Write($"the program exited ({code}); it starts again in a moment");
            programDown = true;
            tray?.Show("off", NotRunning);
            flyout?.Render(board, programDown);
            settings?.Render(board, programDown);
            // Its questions can't be answered until it's back; the next board brings them again.
            popups?.Show([]);
        };
        client.Chime += Chime;
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
        try
        {
            board = newBoard;
            programDown = false;
            tray?.Show(newBoard.Tray.State, newBoard.Tray.Label);
            flyout?.Render(newBoard, programDown);
            popups?.Show(newBoard.Popups);
            settings?.Render(newBoard, programDown);
        }
        catch (Exception e)
        {
            // It runs from the dispatcher, where an exception ends the app without UnhandledException: say what it was.
            Log.Write($"drawing a board: {e}");
            throw;
        }
    }

    /// <summary>A question popup just opened: Windows' notification sound (the Mac plays Glass).</summary>
    static void Chime()
    {
        if (!Native.PlaySound("Notification.Default", 0, Native.SND_ALIAS | Native.SND_ASYNC | Native.SND_NODEFAULT))
            Log.Write("chime: Windows has no notification sound set");
    }

    /// <summary>
    /// The theme, high contrast, the work area or the display changed (the tray's window hears it): the popups'
    /// edges and places, once Windows has finished telling every window.
    /// </summary>
    internal void SettingsChanged() => queue?.TryEnqueue(() =>
    {
        popups?.SettingsChanged();
        settings?.SettingsChanged();
    });

    /// <summary>Sends what you clicked; beeps if it couldn't be done.</summary>
    internal async void Send(Intent intent) => await SendAsync(intent);

    /// <summary>Sends what you did and returns what became of it; beeps if it couldn't be done.</summary>
    internal async Task<FeedResult> SendAsync(Intent intent)
    {
        var result = client is null ? new FeedResult(null, NotRunning) : await client.SendAsync(intent);
        if (result.Problem is { } problem)
        {
            Log.Write($"{intent.Do}: {problem}");
            Native.MessageBeep(Native.MB_OK);
        }
        return result;
    }

    /// <summary>
    /// Settings…, from the flyout or the right-click menu: the program opens a fresh draft and the window shows
    /// on its board; if Settings is open already, it comes to the front.
    /// </summary>
    internal async void OpenSettings()
    {
        if (quitting || login is null || openingSettings) return;
        flyout?.Hide();
        settings ??= new SettingsWindow(this, login);
        if (settings.Wanted)
        {
            settings.Front();
            return;
        }
        openingSettings = true;
        try
        {
            var result = await SendAsync(Intent.SettingsOpen());
            // The board that has Settings follows its result; it may be the one shown now.
            if (result.Succeeded && !quitting) settings.Open(board, programDown);
        }
        finally
        {
            openingSettings = false;
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
            items.Add(new(MenuSettings, menu.Settings));
            items.Add(TrayMenuItem.Separator);
        }
        items.Add(new(MenuQuit, menu?.Quit ?? QuitFallback));
        switch (tray.Menu(x, y, items))
        {
            case MenuOn when menu is not null:
                Send(Intent.Enable(!menu.On.On));
                break;
            case MenuSettings when menu is not null:
                OpenSettings();
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
        settings?.CloseForQuit();
        popups?.Show([]);
        tray?.Remove();
        if (client is not null) await client.DisposeAsync();
        Program.Single?.ReleaseMutex();
        Exit();
    }
}
