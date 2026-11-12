namespace ContextGuard.App;

/// <summary>
/// The entry point (the XAML compiler's own is turned off with <c>DISABLE_XAML_GENERATED_MAIN</c>). A command
/// (<see cref="Options"/>) runs and exits before anything is shown. Otherwise one copy runs per Windows session: a
/// second launch (from Start, or the exe again) asks the running copy to open Settings, as opening the Mac app again
/// does, and exits.
/// </summary>
static class Program
{
    /// <summary>Held while this copy runs; <see cref="App.Quit"/> lets go of it so a new copy can start at once.</summary>
    internal static Mutex? Single { get; private set; }

    internal static Options Options { get; private set; } = null!;

    [STAThread]
    static int Main(string[] args)
    {
        Options = Options.Parse(args, Environment.GetEnvironmentVariable);
        if (Options.Command is { } command) return Commands.Run(command, Options);
        Single = new Mutex(true, @"Local\ContextGuard.App", out var first);
        if (!first)
        {
            Log.Write("already running in this session: asking it to open Settings");
            return Commands.OpenSettingsInRunningCopy();
        }
        XamlGeneratedProgram.XamlGeneratedMain();
        return 0;
    }
}
