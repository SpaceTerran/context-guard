namespace ContextGuard.App;

/// <summary>
/// What the app runs for its board: <c>context-guard.exe ui</c> from where the installer puts it, unless
/// <c>CONTEXT_GUARD_PROGRAM</c> names another program, or <c>--program &lt;exe&gt;</c> and
/// <c>--program-arg &lt;argument&gt;</c> (repeated, in order) are given (the UI tests run a stand-in this way).
/// <c>--login-key &lt;key&gt;</c> puts Open at login under another key of the user's registry than Windows' own
/// (<see cref="LoginItem.DefaultBaseKey"/>), so the UI tests never change what starts at sign-in.
/// </summary>
sealed record Options(string Program, IReadOnlyList<string> Arguments, string LoginKey)
{
    public static Options Parse(IReadOnlyList<string> args, Func<string, string?> environment)
    {
        string? program = null;
        var loginKey = LoginItem.DefaultBaseKey;
        var arguments = new List<string>();
        for (var i = 0; i < args.Count; i++)
        {
            var name = args[i];
            if ((name == "--program" || name == "--program-arg" || name == "--login-key") && i + 1 < args.Count)
            {
                var value = args[++i];
                if (name == "--program") program = value;
                else if (name == "--login-key") loginKey = value;
                else arguments.Add(value);
            }
            else
            {
                Log.Write($"ignored argument: {name}");
            }
        }
        program ??= environment("CONTEXT_GUARD_PROGRAM") is { Length: > 0 } fromEnvironment
            ? fromEnvironment
            : Path.Combine(environment("USERPROFILE") ?? "", ".claude", "hooks", "context-guard", "context-guard.exe");
        return new Options(program, arguments.Count > 0 ? arguments : ["ui"], loginKey);
    }
}
