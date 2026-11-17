#!/bin/bash
# Live test harness for the Cursor CLI: a real interactive `cursor-agent` in a tmux server of the
# test's own (or in a herdr session of the test's own, run inside that tmux server), guarded by test
# hooks in the test folder's `.cursor/hooks.json` that run the debug build with a scratch home.
# Cursor's user hooks file (~/.cursor/hooks.json), your other Cursor chats, your own herdr sessions
# and Context Guard's real files are left alone, and nothing is typed anywhere but the test's pane.
#
#   live-test/cursor-session.sh start <name> [ask%] [later%]   start cursor-agent in
#       $CG_TEST_CURSOR_DIR/<name> (default 10% and 15% of the chat's window)
#       CG_TEST_CURSOR_DIR=<folder> where test folders go (default .scratch/cursor-live at the repo
#         root). Each test folder is a git repo of its own: Cursor reads a project's hooks at the
#         root of its repo.
#       CG_TEST_MODEL=<model> the chat's model (default auto)
#       CG_TEST_AUTO_YES=<seconds> without an answer before it compacts by itself (default 60)
#       CG_TEST_MESSAGE=<text> the save message (default: a request to reply with set words; "real"
#         keeps Context Guard's own)
#       CG_TEST_CONTINUE=<text> the continue message after a summary (default: a request to reply
#         with set words; "real" keeps Context Guard's own)
#       CG_TEST_TERMINAL=herdr  run it in a herdr pane: herdr session `cg-cursor-<name>`, whose TUI
#         runs in the test's tmux server (default: straight in the tmux server)
#       CG_TEST_TERMINAL=plain  in the tmux server, but without tmux's variables and as Terminal.app
#         names itself: Context Guard has nothing to type with, as in a plain terminal app
#   live-test/cursor-session.sh send <name> <text>     type a prompt and press Enter
#   live-test/cursor-session.sh type <name> <text>     type without pressing Enter (a draft)
#   live-test/cursor-session.sh key <name> enter|esc|ctrl-c|ctrl-u
#   live-test/cursor-session.sh screen <name>          print the pane
#   live-test/cursor-session.sh state <name>           context-guard status for the scratch home
#   live-test/cursor-session.sh session <name>         the chat's Context Guard file
#   live-test/cursor-session.sh answer <name> yes|later|skip   answer as the popup would
#   live-test/cursor-session.sh answer <name> now      Compact Now, as the menu sends it
#   live-test/cursor-session.sh stop <name>            stop cursor-agent, the test's herdr session and
#                                                      tmux server, and delete the test's chats and
#                                                      their transcripts in ~/.cursor
#
# Filler files in the test folder: asking the chat to read one adds about 10k tokens of context.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
pkg="$(cd "$here/.." && pwd -P)"
repo="$(git -C "$pkg" rev-parse --show-toplevel)"
bin="$pkg/.build/debug/context-guard"
cmd="${1:?command}"
name="${2:?session name}"
base="${CG_TEST_CURSOR_DIR:-$repo/.scratch/cursor-live}"
mkdir -p "$base"
dir="$(cd "$base" && pwd -P)/$name"
home="$dir/home"
# The test's own tmux server: its socket is all the hooks and Context Guard's typing ever use.
tmx=(tmux -L "cg-cursor-$name" -f /dev/null)
# In herdr mode: the test's own herdr session, never the default one.
hsession="cg-cursor-$name"
hdr=(herdr --session "$hsession")

cg() { CONTEXT_GUARD_HOME="$home" "$bin" "$@"; }

# Which terminal runs the chat (tmux or herdr) and, for herdr, its pane: saved by `start`.
terminal() { cat "$dir/.terminal" 2>/dev/null || echo tmux; }
pane() { cat "$dir/.pane"; }

send_text() {
  if [ "$(terminal)" = herdr ]; then "${hdr[@]}" pane send-text "$(pane)" "$1" >/dev/null
  else "${tmx[@]}" send-keys -t test -l "$1"; fi
}

# enter | esc | ctrl-c | ctrl-u
send_key() {
  if [ "$(terminal)" = herdr ]; then
    "${hdr[@]}" pane send-keys "$(pane)" "$(printf '%s' "$1" | tr - +)" >/dev/null
  else
    case "$1" in enter) k=Enter ;; esc) k=Escape ;; ctrl-c) k=C-c ;; ctrl-u) k=C-u ;; esac
    "${tmx[@]}" send-keys -t test "$k"
  fi
}

read_screen() {
  if [ "$(terminal)" = herdr ]; then "${hdr[@]}" pane read "$(pane)" --source visible 2>/dev/null
  else "${tmx[@]}" capture-pane -p -t test 2>/dev/null; fi
}

# The chat Context Guard follows: the newest one in the scratch home that hasn't ended.
session_id() {
  local f
  for f in "$home"/sessions/*.json; do
    [ -f "$f" ] && jq -r 'select(.ended != true) | "\(.updatedAt) \(.sessionId)"' "$f"
  done | sort | tail -1 | cut -d' ' -f2
}

case "$cmd" in
  start)
    ask="${3:-10}"; later="${4:-15}"
    "${tmx[@]}" kill-server 2>/dev/null || true
    herdr session stop "$hsession" >/dev/null 2>&1 || true
    herdr session delete "$hsession" >/dev/null 2>&1 || true
    rm -rf "$dir"; mkdir -p "$home"
    git -C "$dir" init -q && git -C "$dir" commit -q --allow-empty -m "test repo"
    for i in 1 2 3 4 5 6; do
      python3 -c "import random; random.seed($i); w=['alpha','bravo','charlie','delta','echo','foxtrot','golf','hotel','india','juliet']; print('\n'.join(' '.join(random.choice(w) for _ in range(16)) for _ in range(600)))" > "$dir/filler-$i.txt"
    done
    # On since a minute ago, so a question's countdown starts when it's asked.
    jq -n --argjson ask "$ask" --argjson later "$later" \
      --argjson auto "${CG_TEST_AUTO_YES:-60}" --arg on "$(date -u -v-1M +%Y-%m-%dT%H:%M:%SZ)" \
      --arg msg "${CG_TEST_MESSAGE:-LIVE TEST: reply with exactly the words SAVE MESSAGE RECEIVED and nothing else.}" \
      --arg cont "${CG_TEST_CONTINUE:-LIVE TEST: reply with exactly the word CONTINUED and nothing else.}" \
      '{schemaVersion: 1, enabled: true, enabledAt: $on, cursorAskPercent: $ask, cursorLaterPercent: $later,
        autoYesSeconds: $auto} + (if $msg == "real" then {} else {message: $msg} end)
        + (if $cont == "real" then {} else {continueMessage: $cont} end)' > "$home/config.json"
    # Context Guard's hooks as install.sh adds them, but running the debug build on the scratch home.
    hc="$(printf '/bin/sh -c %q' "CONTEXT_GUARD_HOME=$home CONTEXT_GUARD_WAITER_POLL=0.5 exec $bin cursor hook")"
    mkdir -p "$dir/.cursor"
    jq -n --arg c "$hc" '{version: 1, hooks: ({} | .beforeSubmitPrompt = [{command: $c, timeout: 5}]
      | .postToolUse = [{command: $c, timeout: 5}] | .preCompact = [{command: $c, timeout: 5}]
      | .stop = [{command: $c, timeout: 43800}] | .sessionEnd = [{command: $c, timeout: 5}])}' > "$dir/.cursor/hooks.json"
    agent="cursor-agent --trust --model ${CG_TEST_MODEL:-auto}"
    if [ "${CG_TEST_TERMINAL:-tmux}" = herdr ]; then
      echo herdr > "$dir/.terminal"
      "${tmx[@]}" new-session -d -s test -x 200 -y 50 -c "$dir" herdr --session "$hsession"
      for _ in $(seq 1 40); do "${hdr[@]}" pane list >/dev/null 2>&1 && break; sleep 0.5; done
      "${hdr[@]}" pane list | jq -r '.result.panes[0].pane_id' > "$dir/.pane"
      "${hdr[@]}" pane run "$(pane)" "cd $(printf '%q' "$dir") && exec $agent" >/dev/null
    elif [ "${CG_TEST_TERMINAL:-tmux}" = plain ]; then
      echo plain > "$dir/.terminal"
      "${tmx[@]}" new-session -d -s test -x 160 -y 48 -c "$dir" \
        env -u TMUX -u TMUX_PANE TERM_PROGRAM=Apple_Terminal $agent
    else
      echo tmux > "$dir/.terminal"
      "${tmx[@]}" new-session -d -s test -x 160 -y 48 -c "$dir" $agent
    fi
    for _ in $(seq 1 60); do
      read_screen | grep -q 'Plan, search, build anything' && break
      sleep 0.5
    done
    echo "started $name in $dir ($(terminal))"
    ;;
  send)
    send_text "${3:?text}"
    sleep 0.3
    send_key enter
    ;;
  type) send_text "${3:?text}" ;;
  key)
    case "${3:?key}" in
      enter|esc|ctrl-c|ctrl-u) send_key "$3" ;;
      *) echo "unknown key $3" >&2; exit 1 ;;
    esac
    ;;
  screen) read_screen | grep -v '^ *$' ;;
  state) cg status ;;
  session) jq . "$home/sessions/$(session_id).json" ;;
  answer)
    case "${3:?yes|later|skip|now}" in
      now) cg answer "$(session_id)" yes --source menu ;;
      *) cg answer "$(session_id)" "$3" ;;
    esac
    ;;
  stop)
    if [ "$(terminal)" = herdr ]; then
      herdr session stop "$hsession" >/dev/null 2>&1 || true
      herdr session delete "$hsession" >/dev/null 2>&1 && echo "deleted herdr session $hsession"
    fi
    "${tmx[@]}" kill-server 2>/dev/null || true
    # The CLI files a folder's chats under the MD5 of its path: only this test's go, with their
    # transcripts (`~/.cursor/projects/<folder>/agent-transcripts/<chat>`), and then the project
    # folder that held them if nothing but Cursor's own bookkeeping is left in it.
    chats="$HOME/.cursor/chats/$(printf '%s' "$dir" | md5 -q)"
    [ -d "$chats" ] || exit 0
    for chat in "$chats"/*/; do
      chat="$(basename "$chat")"
      for t in "$HOME"/.cursor/projects/*/agent-transcripts/"$chat"; do
        [ -d "$t" ] || continue
        rm -rf "$t" && echo "deleted $t"
        project="$(dirname "$(dirname "$t")")"
        rmdir "$project/agent-transcripts" 2>/dev/null || continue
        others="$(ls -A "$project" | grep -v -x -e repo.json -e worker.log -e worker.sock -e .workspace-trusted || true)"
        [ -z "$others" ] && rm -rf "$project" && echo "deleted $project"
      done
    done
    rm -rf "$chats" && echo "deleted $chats"
    ;;
  *) echo "unknown command $cmd" >&2; exit 1 ;;
esac
