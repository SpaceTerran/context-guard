namespace ContextGuard.App;

/// <summary>
/// The app's command line.
/// <para>
/// What it runs for its board: <c>context-guard.exe ui</c> from where the installer puts it, unless
/// <c>CONTEXT_GUARD_PROGRAM</c> names another program, or <c>--program &lt;exe&gt;</c> and
/// <c>--program-arg &lt;argument&gt;</c> (repeated, in order) are given (the UI tests run a stand-in this way).
/// <c>--login-key &lt;key&gt;</c> puts Open at login under another key of the user's registry than Windows' own
/// (<see cref="LoginItem.DefaultBaseKey"/>), so the tests never change what starts at sign-in.
/// </para>
/// <para>
/// A command does one thing and exits, with nothing shown (<see cref="Commands"/>): <c>--login-item on|off</c>,
/// <c>--render-icon &lt;file.ico&gt;</c>, <c>--quit</c>.
/// </para>
/// </summary>
sealed record Options(string Program, IReadOnlyList<string> Arguments, string LoginKey, Command? Command)
{
    public static Options Parse(IReadOnlyList<string> args, Func<string, string?> environment)
    {
        string? program = null;
        var loginKey = LoginItem.DefaultBaseKey;
        var arguments = new List<string>();
        Command? command = null;
        for (var i = 0; i < args.Count; i++)
        {
            var name = args[i];
            if ((name is "--program" or "--program-arg" or "--login-key" or "--login-item" or "--render-icon") && i + 1 < args.Count)
            {
                var value = args[++i];
                switch (name)
                {
                    case "--program": program = value; break;
                    case "--program-arg": arguments.Add(value); break;
                    case "--login-key": loginKey = value; break;
                    default: command ??= new Command(name, value); break;
                }
            }
            else if (name == "--quit")
            {
                command ??= new Command(name, null);
            }
            else
            {
                Log.Write($"ignored argument: {name}");
            }
        }
        program ??= environment("CONTEXT_GUARD_PROGRAM") is { Length: > 0 } fromEnvironment
            ? fromEnvironment
            : Path.Combine(environment("USERPROFILE") ?? "", ".claude", "hooks", "context-guard", "context-guard.exe");
        return new Options(program, arguments.Count > 0 ? arguments : ["ui"], loginKey, command);
    }
}

/// <summary>A command from the command line (<c>--quit</c>, …) and its value, if it takes one.</summary>
sealed record Command(string Name, string? Value);
