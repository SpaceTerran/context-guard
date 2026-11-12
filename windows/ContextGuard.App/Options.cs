namespace ContextGuard.App;

/// <summary>
/// What the app runs for its board: <c>context-guard.exe ui</c> from where the installer puts it, unless
/// <c>CONTEXT_GUARD_PROGRAM</c> names another program, or <c>--program &lt;exe&gt;</c> and
/// <c>--program-arg &lt;argument&gt;</c> (repeated, in order) are given (the UI tests run a stand-in this way).
/// </summary>
sealed record Options(string Program, IReadOnlyList<string> Arguments)
{
    public static Options Parse(IReadOnlyList<string> args, Func<string, string?> environment)
    {
        string? program = null;
        var arguments = new List<string>();
        for (var i = 0; i < args.Count; i++)
        {
            var name = args[i];
            if ((name == "--program" || name == "--program-arg") && i + 1 < args.Count)
            {
                var value = args[++i];
                if (name == "--program") program = value;
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
        return new Options(program, arguments.Count > 0 ? arguments : ["ui"]);
    }
}
