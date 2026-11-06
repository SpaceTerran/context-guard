# Context Guard

![Context Guard asking whether to compact a session](docs/popup.png)

A small Mac menu bar app for [Claude Code](https://code.claude.com/docs/en/overview). When a
session's context gets big, it asks before compacting. If you say yes, the session saves its work
first, then it's compacted and told to carry on.

There are about a thousand ways to handle context in Claude Code: `/compact` by hand, auto-compact,
and plenty of other tools. This is just the one I like. The story behind it is on the blog:
**[Context Guard: ask before compacting](https://spaceterran.com/posts/context-guard-claude-code/)**.

## What it does

When a session reaches **300k** tokens of context, a popup asks whether to compact it. Compacting
starts by asking the session to save its work, with this message (you can change it):

> I'm about to compact this conversation. Check in, push, or save anything else you need before I
> complete compaction, and then I will let you know when to resume.

- **Compact** sends that message now. A working session gets it at its next step. An idle one is
  woken with it.
- **No answer in 60 seconds** counts as Compact. The popup counts down.
- **Wait until 500k** does nothing now. The session is asked to save, then compacted, when it
  reaches 500k.
- **Turn Off** stops all asking and compacting by itself until you turn it back on from the gauge in
  the menu bar.

Once the session has the message (from these, or **Compact Now** in its menu), Context Guard
finishes the job:

1. Every 10 seconds while the session is idle, Haiku reads what it did after the message and decides
   whether it has finished saving. A question to you, or a session still waiting on a push or CI,
   holds it; so does a session that ignored the message.
2. Once it's ready, the session is compacted, as `/compact` does it. Text in the prompt box holds it.
3. When the compaction is done and the session is idle, **continue now** goes in as your words. If
   you typed or sent something first, it's left to you.

A notice says when it needs you, when it compacts and how it went. After a session compacts, it's
asked again the next time it reaches 300k.

Haiku needs no sign-in or key: the mod asks it through the Claude Code session it runs in, with that
session's account.

Each session's menu has **Watch This Session**. Turned off, that tab gets no questions and isn't
compacted by itself until it closes or you turn it back on. **Compact Now** always works, even there
and with Context Guard off.

Settings has three tabs: **General** (on or off, open at login, what's installed), **When to Ask**
(the thresholds, and how long a question waits before it compacts by itself; 0 for never) and
**Messages** (the save message and the continue message).

| The session's menu | Settings |
|---|---|
| ![A session's menu with Compact Now](docs/menu.png) | ![Settings, the messages it sends](docs/settings.png) |

It doesn't care which terminal you use (tested in Warp, Terminal and Ghostty): everything goes
through Claude Code's own hooks and plugins.

## Requirements

- macOS 14 or newer.
- Xcode Command Line Tools 16.4 or newer (Swift 6.1 or newer): `xcode-select --install`.
- `jq`: built into macOS 15 and later; on macOS 14, `brew install jq`.
- Claude Code with plugin support (tested with 2.1.318), signed in as usual.

## Install, update, uninstall

```
git clone https://github.com/SpaceTerran/context-guard.git
cd context-guard
./install.sh                 # install, or update after a git pull
./install.sh --uninstall     # remove the hooks, the hook program, the mod and the app
```

It builds on your Mac (about a minute), so there's nothing to download and nothing for Gatekeeper to
block. `install.sh` does the following:

- builds everything (`build.sh`);
- puts the hook program at `~/.claude/hooks/context-guard/context-guard`;
- adds the hooks to `~/.claude/settings.json`, after backing it up next to itself. Other hooks are
  left alone, and running it again doesn't add the hooks twice;
- copies the mod to `~/.claude/hooks/context-guard/mod` and installs it as the user plugin
  `context-guard@context-guard`. Claude Code reads it from that folder, so an update is a copy;
- installs `~/Applications/Context Guard.app`, sets it to open at login, and starts it.

Running sessions pick up the hooks within a few seconds, and the mod at `/reload-plugins` or their
next start. Uninstalling keeps your settings and session records in `~/.claude/context-guard`.

## How it works

Claude Code has no way for another app to type into a session, so the message goes in through
Claude Code's own hooks:

| Hook | What it does |
|---|---|
| `PostToolBatch` | Runs after each step (about 7 ms). It reads the new part of the transcript for the context size, asks at 300k, and adds a waiting save message to the session's next step. |
| `Stop` (`asyncRewake`) | Stays in the background after every turn, until the next turn replaces it (up to 12 hours). When you click Compact or Compact Now, or the session reaches 500k, it exits 2, which wakes the idle session with the save message. |
| `SessionStart`, `SessionEnd`, `StopFailure` | Note compactions, `/clear`, exits and failed turns. |

Nothing outside a session can run `/compact` in it, so compacting after the save message is done by a
**mod** (`mod/`): a Claude Code plugin whose code runs inside each interactive terminal session. It
holds no rules. Every 10 seconds it runs `context-guard mod tick` with the session's id, its running
subagents and whether the prompt box has text. The program reads the transcript and answers with one
step: ask Haiku (with the prompt to send), compact, send the continue message, or nothing. The mod
does it and reports back with `context-guard mod report`.

- **Delivery:** a save message goes out exactly once, by whichever path comes first. It counts as sent
  only once it shows up in the transcript.
- **Mid-turn:** a session is never woken in the middle of a turn. A wake there would land inside a
  tool result, where the model treats it as a prompt injection.
- **Which sessions:** only interactive terminal sessions are guarded. Subagents, `claude -p` and SDK
  runs are left alone.

| File | Written by |
|---|---|
| `~/.claude/context-guard/config.json` | the app and `context-guard on/off`: on/off, thresholds, messages, the wait before a question compacts by itself |
| `~/.claude/context-guard/sessions/<id>.json` | the hook and `context-guard mod`: each session's size, where its save message stands, and how compacting is going |
| `~/.claude/context-guard/answers/<id>.json` | the app and `context-guard answer`: your answer to a popup |
| `~/.claude/context-guard/muted/<pid>-<start>.json` | the app and `context-guard watch`: a tab you stopped watching, by its Claude process |

The hook program also works from a terminal. `install.sh` doesn't put it on your PATH, so give it a
short name first:

```
alias context-guard=~/.claude/hooks/context-guard/context-guard
context-guard status                  # every session and where it stands
context-guard answer <id> yes|later|skip
context-guard watch <id> on|off       # watch a session's tab, or stop
context-guard on | off
```

## Development

```
swift test                                     # the rules, transcript reading, hook runs
claude plugin test mod                         # the mod, against a mocked clock and program
live-test/ui-demo.sh start dark                # the app on four staged sessions, to look at it
live-test/session.sh start <name> 60 75        # a real Haiku session with low thresholds
CG_TEST_PLUGIN_DIR=$PWD/mod CG_TEST_AUTO_YES=5 live-test/session.sh start <name> 60 75
                                               # the same, with the mod and a 5 s countdown
CG_TEST_TERMINAL=terminal CG_TEST_PROMPT="Read filler-1.txt" live-test/session.sh start <name> 60 75
                                               # the same in a Terminal.app window (or ghostty)
```

The live tests keep their files in `.scratch/` at the repo root. They never touch your real
sessions or settings. Without `CG_TEST_TERMINAL`, `session.sh` runs Claude Code in a hidden terminal
that needs [`uv`](https://docs.astral.sh/uv/).

## License

MIT. See [LICENSE](LICENSE).
