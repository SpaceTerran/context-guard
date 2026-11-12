namespace ContextGuard.App;

/// <summary>
/// The app's log, <c>%LOCALAPPDATA%\Context Guard\app.log</c>: what it started with, the program's
/// errors and exits, and anything that went wrong. Past 1 MB it moves to <c>app.log.old</c> and starts again.
/// </summary>
static class Log
{
    const long Limit = 1024 * 1024;
    static readonly Lock Gate = new();
    static readonly string Folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Context Guard");
    static readonly string File = Path.Combine(Folder, "app.log");

    public static void Write(string message)
    {
        var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} [{Environment.ProcessId}] {message}{Environment.NewLine}";
        lock (Gate)
        {
            try
            {
                Directory.CreateDirectory(Folder);
                var info = new FileInfo(File);
                if (info.Exists && info.Length > Limit) System.IO.File.Move(File, File + ".old", overwrite: true);
                System.IO.File.AppendAllText(File, line);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                // Nowhere else to say it; the app keeps going.
            }
        }
    }
}
