using Microsoft.Win32;

namespace ContextGuard.App;

/// <summary>
/// Open at login: the app's command in the signed-in user's Run key, which Windows starts at sign-in (an unpackaged
/// app has no StartupTask). Windows' Startup apps page can turn it off without removing it (a value under
/// <c>Explorer\StartupApproved\Run</c> whose first byte is odd); that counts as off here, and turning it on here
/// clears it, so the latest choice wins wherever it was made. The Mac's counterpart is its login item.
/// </summary>
sealed class LoginItem(string baseKey, string exe)
{
    /// <summary>Where Windows looks; the UI tests pass another key (<c>--login-key</c>).</summary>
    public const string DefaultBaseKey = @"Software\Microsoft\Windows\CurrentVersion";
    const string ValueName = "Context Guard";

    string RunKey => baseKey + @"\Run";
    string ApprovedKey => baseKey + @"\Explorer\StartupApproved\Run";

    /// <summary>The command Windows runs: this app, quoted (its folder can hold spaces).</summary>
    public string Command => $"\"{exe}\"";

    /// <summary>Whether Windows starts this app at sign-in.</summary>
    public bool IsOn
    {
        get
        {
            try
            {
                using var run = Registry.CurrentUser.OpenSubKey(RunKey);
                if (run?.GetValue(ValueName) is not string command || !Same(command, exe)) return false;
                using var approved = Registry.CurrentUser.OpenSubKey(ApprovedKey);
                return approved?.GetValue(ValueName) is not byte[] { Length: > 0 } flags || (flags[0] & 1) == 0;
            }
            catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException)
            {
                Log.Write($"login item: couldn't read it: {e.Message}");
                return false;
            }
        }
    }

    /// <summary>Starts this app at sign-in, or stops; throws when Windows won't change it.</summary>
    public void Set(bool on)
    {
        using (var approved = Registry.CurrentUser.OpenSubKey(ApprovedKey, writable: true))
            approved?.DeleteValue(ValueName, throwOnMissingValue: false);
        if (on)
        {
            using var run = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
            run.SetValue(ValueName, Command, RegistryValueKind.String);
        }
        else
        {
            using var run = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            run?.DeleteValue(ValueName, throwOnMissingValue: false);
        }
        Log.Write($"login item: {(on ? "on" : "off")}");
    }

    /// <summary>A Run command that starts this exe (quoted or not; Windows paths ignore case).</summary>
    static bool Same(string command, string exe) =>
        string.Equals(command.Trim().Trim('"'), exe, StringComparison.OrdinalIgnoreCase);
}
