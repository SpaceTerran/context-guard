# Tool logos

Each session in the menu, its popups and its notices shows the mark of the tool it runs in, so sessions from
different tools are told apart at a glance:

| Tool        | Mark                          | File            |
| ----------- | ----------------------------- | --------------- |
| Claude Code | Anthropic                     | `anthropic.svg` |
| Codex       | OpenAI                        | `openai.svg`    |
| Cursor      | Cursor                        | `cursor.svg`    |

The SVGs are the monochrome marks as [Simple Icons](https://simpleicons.org) draws them from each brand's own
assets (Anthropic and Cursor from 16.37.0, OpenAI from 15.22.0, the last release with it): one path on a 24-unit
square. Simple Icons' path data is CC0. The marks themselves are trademarks of Anthropic, OpenAI and Anysphere
(Cursor); Context Guard uses them only to show which tool a session belongs to, and isn't affiliated with or
endorsed by any of them.

Both apps draw the same shapes. `ToolLogoTests` reads these files and writes the path data each app uses:

- `Sources/ContextGuardCore/Presentation/ToolLogo.g.swift` (the Mac app);
- `windows/ContextGuard.Feed/ToolLogos.g.cs` (the Windows app, as XAML path markup).

After changing a file here, `CONTEXT_GUARD_UPDATE_CONTRACT=1 swift test --filter ToolLogoTests` rewrites them; read
the diff before committing it.
