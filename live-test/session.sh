#!/bin/bash
# Live test harness: a real interactive Claude Code session (Haiku, in a pseudo-terminal) whose
# Context Guard hooks point at a scratch home, so nothing touches real sessions or settings.
#
#   live-test/session.sh start <name> [ask_k] [later_k]   start a session in .scratch/live/<name>
#       CG_TEST_MODEL=opus (default haiku), CG_TEST_MESSAGE=real (default: a test reply request),
#       CG_TEST_POLL=<seconds> between the waiter's checks (default 0.5)
#       CG_TEST_PLUGIN_DIR=<folder> loads that mod into the session (the Context Guard mod, say),
#       CG_TEST_AUTO_YES=<seconds> without an answer before it compacts by itself (default 60)
#       CG_TEST_PROMPT=<text> the session's first prompt, given on the command line
#       CG_TEST_TERMINAL=terminal|ghostty runs it in a new Terminal.app or Ghostty window instead of a
#         hidden pseudo-terminal. send and key don't apply; screen works in Terminal.app. Ghostty can't
#         answer Claude Code's "trust this folder?" question, so start that name once in Terminal.app first.
#   live-test/session.sh send  <name> <text>              type a prompt and press Enter
#   live-test/session.sh key   <name> enter|esc|ctrl-c|ctrl-u|backspace|up|down
#   live-test/session.sh screen <name>                    print the rendered terminal
#   live-test/session.sh state <name>                     context-guard status for that home
#   live-test/session.sh answer <name> yes|later|skip     answer as the popup would
#   live-test/session.sh stop  <name>
#
# Keeps everything in .scratch/live/<name> at the repo root. Claude Code must already trust a folder
# above it (otherwise it asks first), and the hidden pseudo-terminal needs `uv` (for pyte).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
pkg="$(cd "$here/.." && pwd)"
repo="$(git -C "$pkg" rev-parse --show-toplevel)"
bin="$pkg/.build/debug/context-guard"
cmd="${1:?command}"
name="${2:?session name}"
dir="$repo/.scratch/live/$name"
home="$dir/home"

hook_cmd() {
  # shellcheck disable=SC2016  # $PPID is for the hook's own shell
  printf 'CONTEXT_GUARD_HOME=%q CONTEXT_GUARD_WAITER_POLL=%s CG_CLAUDE_PID=$PPID exec %q hook' "$home" "${CG_TEST_POLL:-0.5}" "$bin"
}

# What the Terminal.app window shows (CG_TEST_TERMINAL=terminal).
terminal_screen() {
  osascript -e "tell application \"Terminal\" to get contents of selected tab of (first window whose id is $(cat "$dir/window.id"))"
}

case "$cmd" in send|key)
  [ -p "$dir/control" ] || { echo "$cmd only works without CG_TEST_TERMINAL" >&2; exit 1; } ;;
esac

case "$cmd" in
  start)
    ask_k="${3:-60}"; later_k="${4:-75}"
    model="${CG_TEST_MODEL:-haiku}"
    rm -rf "$dir"; mkdir -p "$home"
    # A throwaway repo with no remote, so a real "commit and push" request has nothing real to touch.
    git -C "$dir" init -q && git -C "$dir" commit -q --allow-empty -m "test repo"
    # Filler files: each Read adds roughly 10k tokens of context.
    for i in 1 2 3 4 5 6; do
      python3 -c "import random; random.seed($i); w=['alpha','bravo','charlie','delta','echo','foxtrot','golf','hotel','india','juliet']; print('\n'.join(' '.join(random.choice(w) for _ in range(16)) for _ in range(600)))" > "$dir/filler-$i.txt"
    done
    # CG_TEST_MESSAGE=real keeps Context Guard's real default message.
    # On since a minute ago, so a question's countdown starts when it's asked.
    jq -n --argjson ask "$((ask_k * 1000))" --argjson later "$((later_k * 1000))" \
      --argjson auto "${CG_TEST_AUTO_YES:-60}" --arg on "$(date -u -v-1M +%Y-%m-%dT%H:%M:%SZ)" \
      --arg msg "${CG_TEST_MESSAGE:-LIVE TEST: reply with exactly the words SAVE MESSAGE RECEIVED and nothing else.}" \
      '{schemaVersion: 1, enabled: true, enabledAt: $on, askAt: $ask, laterAt: $later, autoYesSeconds: $auto} + (if $msg == "real" then {} else {message: $msg} end)' \
      > "$home/config.json"
    hc="$(hook_cmd)"
    jq -n --arg c "$hc" '{
      hooks: {
        PostToolBatch: [{hooks: [{type: "command", command: $c, timeout: 5}]}],
        Stop: [{hooks: [{type: "command", command: $c, asyncRewake: true, timeout: 43500,
                         rewakeSummary: "Context Guard: save before compacting",
                         rewakeMessage: "Stop hook message:"}]}],
        StopFailure: [{hooks: [{type: "command", command: $c, timeout: 5}]}],
        SessionStart: [{hooks: [{type: "command", command: $c, timeout: 5}]}],
        SessionEnd: [{hooks: [{type: "command", command: $c, timeout: 5}]}]
      }
    }' > "$dir/settings.json"
    # Run from inside Claude Code, the inherited session variables are cleared so the test session
    # saves its transcript like a fresh terminal tab.
    # shellcheck disable=SC2054  # `project,local` is one argument
    session=(env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_EXECPATH
      -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_SESSION_ATTENDED
      -u CLAUDE_CODE_SESSION_ID -u CLAUDE_EFFORT -u CLAUDE_PID
      CONTEXT_GUARD_HOME="$home" CONTEXT_GUARD_PROGRAM="$bin"
      claude ${CG_TEST_PROMPT:+"$CG_TEST_PROMPT"}
      --model "$model" --permission-mode default --setting-sources project,local --settings "$dir/settings.json"
      ${CG_TEST_PLUGIN_DIR:+--plugin-dir "$CG_TEST_PLUGIN_DIR"}
      --strict-mcp-config --mcp-config '{"mcpServers":{}}'
      --allowedTools "Read" "Bash(echo *)" "Bash(sleep *)" "Bash(git status*)" "Bash(git log*)"
      --disallowedTools "Bash(git commit*)" "Bash(git push*)" "Write" "Edit")
    case "${CG_TEST_TERMINAL:-}" in
      "")
        mkfifo "$dir/control"
        nohup uv run -q --with pyte python3 "$here/pty_driver.py" \
          --cwd "$dir" --fifo "$dir/control" --screen "$dir/screen.txt" --log "$dir/raw.log" -- \
          "${session[@]}" > "$dir/driver.out" 2>&1 &
        echo $! > "$dir/driver.pid"
        ;;
      terminal|ghostty)
        # A new window of a real terminal app runs the same command, so nothing is typed on anyone's
        # screen: the first prompt goes on the command line (CG_TEST_PROMPT).
        { echo '#!/bin/bash'
          printf 'export PATH=%q\n' "$PATH"
          printf 'cd %q\n' "$dir"
          printf 'exec'; printf ' %q' "${session[@]}"; echo
        } > "$dir/run.sh"
        chmod +x "$dir/run.sh"
        if [ "$CG_TEST_TERMINAL" = terminal ]; then
          # Its window, found by its tab's tty: a Terminal that wasn't running opens a window of its own too.
          osascript -e 'on run argv' -e 'tell application "Terminal"' \
            -e 'set t to do script ("exec " & quoted form of item 1 of argv)' -e 'set y to tty of t' \
            -e 'repeat 25 times' -e 'repeat with w in windows' -e 'try' \
            -e 'if tty of selected tab of w is y then return id of w' -e 'end try' -e 'end repeat' -e 'delay 0.2' -e 'end repeat' \
            -e 'end tell' -e 'end run' "$dir/run.sh" > "$dir/window.id"
          # A folder Claude Code hasn't seen asks whether to trust it ("No, exit" is selected). The answer
          # goes to that tab only, through Terminal's own scripting, never as a keystroke to the screen.
          for _ in $(seq 1 30); do
            if terminal_screen | grep -q 'Yes, I trust this folder'; then
              osascript -e "tell application \"Terminal\" to do script ((character id 27) & \"[B\") in selected tab of (first window whose id is $(cat "$dir/window.id"))" >/dev/null
              break
            fi
            terminal_screen | grep -q 'Claude Code v' && break
            sleep 0.5
          done
        else
          # --command=, not -e <path>: macOS hands a bare path argument to the app as a file to open,
          # and Ghostty then asks whether to run it in a second tab.
          open -na Ghostty.app --args --quit-after-last-window-closed=true --command="$dir/run.sh"
        fi
        echo "$CG_TEST_TERMINAL" > "$dir/terminal"
        ;;
      *) echo "CG_TEST_TERMINAL is terminal or ghostty" >&2; exit 1 ;;
    esac
    echo "started $name in $dir"
    ;;
  send)   printf 'send %s\n' "${3:?text}" > "$dir/control" ;;
  key)    printf '%s\n' "${3:?key}" > "$dir/control" ;;
  screen)
    if [ -f "$dir/window.id" ]; then terminal_screen; elif [ -p "$dir/control" ]; then cat "$dir/screen.txt"
    else echo "screen doesn't work in Ghostty" >&2; exit 1; fi ;;
  state)  CONTEXT_GUARD_HOME="$home" "$bin" status ;;
  answer)
    # The live conversation: /clear leaves the old one's file behind, marked ended.
    sid="$(for f in "$home"/sessions/*.json; do jq -r 'select(.ended != true) | "\(.updatedAt) \(.sessionId)"' "$f"; done | sort | tail -1 | cut -d' ' -f2)"
    CONTEXT_GUARD_HOME="$home" "$bin" answer "${sid:?no live session}" "${3:?yes|later|skip}" ;;
  stop)
    if [ -f "$dir/terminal" ]; then
      pkill -f -- "--settings $dir/settings.json" || true
      sleep 1
      [ -f "$dir/window.id" ] && osascript -e "tell application \"Terminal\" to close (every window whose id is $(cat "$dir/window.id"))" >/dev/null 2>&1 || true
    else
      printf 'quit\n' > "$dir/control" || true
      sleep 1
      kill "$(cat "$dir/driver.pid")" 2>/dev/null || true
    fi
    ;;
  *) echo "unknown command $cmd" >&2; exit 1 ;;
esac
