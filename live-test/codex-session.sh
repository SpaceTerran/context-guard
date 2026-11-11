#!/bin/bash
# Live test harness for Codex: a real interactive `codex` (gpt-6-luna, in a pseudo-terminal) on your
# own Codex app server, guarded by a test `context-guard codex` that keeps its files in a scratch
# home and looks only at sessions in the test's folder (--only-cwd). Your other Codex sessions, your
# Codex settings and Context Guard's real files are left alone.
#
#   live-test/codex-session.sh start <name> [ask%] [later%]   start codex and the test link in
#       $CG_TEST_CODEX_DIR/<name> (default 10% and 15% of the window)
#       CG_TEST_CODEX_DIR=<folder> where test folders go (default .scratch/codex-live at the repo
#         root). Codex asks whether to trust a folder it doesn't know, and saves the answer in
#         ~/.codex/config.toml; pick a folder inside a project Codex already trusts, and not in a
#         git repo of its own (each repo is trusted separately), so it doesn't ask.
#       CG_TEST_AUTO_YES=<seconds> without an answer before it compacts by itself (default 60)
#       CG_TEST_MESSAGE=<text> the save message (default: a request to reply with set words). The
#         test folder isn't a repo of its own, so don't ask it to commit or push.
#       CG_TEST_PROMPT=<text> the session's first prompt, given on the command line
#       CG_TEST_AUTO_COMPACT=<tokens> where Codex compacts by itself (model_auto_compact_token_limit)
#       The test folder gets Codex settings of its own (<folder>/.codex/config.toml, read only for
#       sessions there): gpt-6-luna, so /new keeps it; no update check; and CG_TEST_AUTO_COMPACT.
#   live-test/codex-session.sh send <name> <text>       type a prompt and press Enter
#   live-test/codex-session.sh type <name> <text>       type without pressing Enter
#   live-test/codex-session.sh key <name> enter|esc|ctrl-c|ctrl-u|backspace|up|down
#   live-test/codex-session.sh screen <name>            print the rendered terminal
#   live-test/codex-session.sh state <name>             context-guard status for the scratch home
#   live-test/codex-session.sh answer <name> yes|later|skip   answer as the popup would (yes before
#                                                       a question = Compact Now)
#   live-test/codex-session.sh rollout <name> [lines]   turns, messages, sizes and compactions from the
#                                                       session's rollout (default the last 30)
#   live-test/codex-session.sh link <name> start|stop|kill   the test link (kill = SIGKILL, like a crash)
#   live-test/codex-session.sh log <name> [lines]       the test link's log
#   live-test/codex-session.sh quit <name>              close the terminal (the session stays loaded)
#   live-test/codex-session.sh resume <name>            open it again in a new terminal (codex resume <id>)
#   live-test/codex-session.sh restart-server <name>    restart Codex's app server; refused while it
#                                                       has sessions loaded that aren't this test's
#   live-test/codex-session.sh stop <name>              close it, stop the link, delete the test's Codex
#                                                       sessions, stop the app server if the test
#                                                       started it and nothing else is loaded, and show
#                                                       what changed in ~/.codex/config.toml
#
# It refuses to start while an installed link (or any link without --only-cwd) runs: two links would
# both act on the test session. If Codex offers an update anyway, the driver passes on only esc
# (skip) and quit: never update from a test. Needs `uv` (for pyte and websockets) and a debug build.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
pkg="$(cd "$here/.." && pwd -P)"
repo="$(git -C "$pkg" rev-parse --show-toplevel)"
bin="$pkg/.build/debug/context-guard"
cmd="${1:?command}"
name="${2:?session name}"
base="${CG_TEST_CODEX_DIR:-$repo/.scratch/codex-live}"
mkdir -p "$base"
dir="$(cd "$base" && pwd -P)/$name"
home="$dir/home"
codex_home="${CODEX_HOME:-$HOME/.codex}"
agent="gui/$(id -u)/com.spaceterran.ContextGuard.codex"

cg() { CONTEXT_GUARD_HOME="$home" "$bin" "$@"; }

# The loaded sessions, one JSON object each; exits 3 when no app server is running.
loaded() { uv run -q --with websockets python3 "$here/codex_rpc.py" loaded; }

# Loaded sessions that aren't this test's: anything kept outside its folder, except throwaway
# (ephemeral) ones such as the judge's.
others() {
  local all
  all="$(loaded)" || return 0
  jq -r --arg d "$dir" 'select(.ephemeral | not) | select((.cwd // "") | startswith($d) | not) | "\(.id) \(.cwd)"' <<<"$all"
}

# The test's rollouts, newest first: Codex sessions created since start in the test's folder.
rollouts() {
  [ -f "$dir/started" ] || return 0
  local f found=""
  while read -r f; do
    [ "$(head -1 "$f" | jq -r '.payload.cwd // empty' 2>/dev/null)" = "$dir" ] && found+="$f"$'\n'
  done < <(find "$codex_home/sessions" -name 'rollout-*.jsonl' -newer "$dir/started" 2>/dev/null)
  [ -n "$found" ] || return 0
  # Paths under ~/.codex/sessions have no spaces.
  # shellcheck disable=SC2086
  ls -t $found
}

session_id() {
  local f
  f="$(rollouts | head -1)"
  [ -n "$f" ] || { echo "no Codex session in $dir yet" >&2; exit 1; }
  basename "$f" .jsonl | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

running() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

terminal() {
  running "$dir/driver.pid" && { echo "a terminal is already open for $name" >&2; exit 1; }
  [ -p "$dir/control" ] || mkfifo "$dir/control"
  nohup uv run -q --with pyte python3 "$here/pty_driver.py" \
    --cwd "$dir" --fifo "$dir/control" --screen "$dir/screen.txt" --log "$dir/raw.log" -- "$@" \
    >> "$dir/driver.out" 2>&1 &
  echo $! > "$dir/driver.pid"
}

start_link() {
  running "$dir/link.pid" && { echo "the test link is already running" >&2; exit 1; }
  CONTEXT_GUARD_HOME="$home" nohup "$bin" codex --only-cwd "$dir" --verbose >> "$dir/link.out" 2>&1 &
  echo $! > "$dir/link.pid"
}

stop_pid() {
  running "$1" || return 0
  local pid; pid="$(cat "$1")"
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.1; done
  kill -9 "$pid" 2>/dev/null || true
}

case "$cmd" in send|type|key)
  running "$dir/driver.pid" || { echo "no terminal is open for $name" >&2; exit 1; } ;;
esac

case "$cmd" in
  start)
    ask="${3:-10}"; later="${4:-15}"
    [ -x "$bin" ] || { echo "build first: swift build" >&2; exit 1; }
    if launchctl print "$agent" >/dev/null 2>&1; then
      echo "the installed Codex link is running ($agent); stop it first: launchctl bootout $agent" >&2; exit 1
    fi
    if pgrep -lf 'context-guard codex' | grep -v -- '--only-cwd' | grep -q .; then
      echo "a Context Guard link without --only-cwd is running; stop it first" >&2; exit 1
    fi
    running "$dir/link.pid" && { echo "$name is running; stop it first" >&2; exit 1; }
    auto_compact="${CG_TEST_AUTO_COMPACT:-}"
    [[ -z "$auto_compact" || "$auto_compact" =~ ^[0-9]+$ ]] || { echo "CG_TEST_AUTO_COMPACT: a number of tokens" >&2; exit 1; }
    rm -rf "$dir"; mkdir -p "$home" "$dir/.codex"
    # Codex settings for this folder only; your own config files are never touched. No update
    # check: its prompt's default is "Update now", and a test's Enter would pick it.
    { echo 'model = "gpt-6-luna"'
      echo 'check_for_update_on_startup = false'
      [ -z "$auto_compact" ] || echo "model_auto_compact_token_limit = $auto_compact"
    } > "$dir/.codex/config.toml"
    # Whether Codex's app server was running before, so stop can leave it as it was.
    if loaded >/dev/null 2>&1; then echo yes > "$dir/server-was-running"; else echo no > "$dir/server-was-running"; fi
    # A copy of your Codex settings, so stop can show what the test changed in them.
    if [ -f "$codex_home/config.toml" ]; then (umask 077; cp "$codex_home/config.toml" "$dir/config.before.toml"); fi
    # Filler files: reading one adds roughly 10k tokens of context.
    for i in 1 2 3 4 5 6; do
      python3 -c "import random; random.seed($i); w=['alpha','bravo','charlie','delta','echo','foxtrot','golf','hotel','india','juliet']; print('\n'.join(' '.join(random.choice(w) for _ in range(16)) for _ in range(600)))" > "$dir/filler-$i.txt"
    done
    # On since a minute ago, so a question's countdown starts when it's asked.
    jq -n --argjson ask "$ask" --argjson later "$later" \
      --argjson auto "${CG_TEST_AUTO_YES:-60}" --arg on "$(date -u -v-1M +%Y-%m-%dT%H:%M:%SZ)" \
      --arg msg "${CG_TEST_MESSAGE:-LIVE TEST: reply with exactly the words SAVE MESSAGE RECEIVED and nothing else.}" \
      '{schemaVersion: 1, enabled: true, enabledAt: $on, codexAskPercent: $ask, codexLaterPercent: $later,
        autoYesSeconds: $auto} + (if $msg == "real" then {} else {message: $msg} end)' > "$home/config.json"
    touch "$dir/started"
    start_link
    # gpt-6-luna on the command line: a current model, so Codex shows no model-migration prompt.
    terminal codex -m gpt-6-luna ${CG_TEST_PROMPT:+"$CG_TEST_PROMPT"}
    echo "started $name in $dir (Codex app server was running before: $(cat "$dir/server-was-running"))"
    ;;
  send)   printf 'send %s\n' "${3:?text}" > "$dir/control" ;;
  type)   printf 'type %s\n' "${3:?text}" > "$dir/control" ;;
  key)    printf '%s\n' "${3:?key}" > "$dir/control" ;;
  screen) grep -v '^ *$' "$dir/screen.txt" ;;
  state)  cg status ;;
  answer) cg answer "$(session_id)" "${3:?yes|later|skip}" ;;
  rollout)
    f="$(rollouts | head -1)"
    [ -n "$f" ] || { echo "no Codex session in $dir yet" >&2; exit 1; }
    jq -r '
      def clip: if length > 110 then .[:110] + "…" else . end;
      (.timestamp[11:19]) as $t
      | if .type == "compacted" then "\($t) COMPACTED"
        elif .type != "event_msg" then empty
        else .payload as $p
          | if $p.type == "task_started" then "\($t) turn started"
            elif $p.type == "task_complete" then "\($t) turn complete"
            elif $p.type == "turn_aborted" then "\($t) turn aborted (\($p.reason))"
            elif $p.type == "token_count" and $p.info != null then
              "\($t) size \($p.info.last_token_usage.total_tokens) of \($p.info.model_context_window)"
            elif $p.type == "item_completed" and $p.item.type == "UserMessage" then
              "\($t) you: \([$p.item.content[]? | .text? // empty] | join(" ") | clip)\(if $p.item.client_id then "  (client id \($p.item.client_id[:8])…)" else "" end)"
            elif $p.type == "item_completed" and $p.item.type == "AgentMessage" then
              "\($t) codex: \([$p.item.content[]? | .text? // empty] | join(" ") | clip)"
            else empty end
        end' "$f" | tail -n "${3:-30}"
    ;;
  link)
    case "${3:?start|stop|kill}" in
      start) start_link ;;
      stop) stop_pid "$dir/link.pid" ;;
      kill) running "$dir/link.pid" && kill -9 "$(cat "$dir/link.pid")" ;;
      *) echo "link start|stop|kill" >&2; exit 1 ;;
    esac
    ;;
  log) tail -n "${3:-40}" "$home/codex-link.log" ;;
  quit)
    running "$dir/driver.pid" || { echo "no terminal is open for $name" >&2; exit 1; }
    printf 'quit\n' > "$dir/control"
    stop_pid "$dir/driver.pid"
    ;;
  resume) terminal codex resume "$(session_id)" ;;
  restart-server)
    busy="$(others)"
    [ -z "$busy" ] || { printf 'not restarting: Codex has other sessions loaded:\n%s\n' "$busy" >&2; exit 1; }
    codex app-server daemon restart
    ;;
  stop)
    if running "$dir/driver.pid"; then printf 'quit\n' > "$dir/control" || true; stop_pid "$dir/driver.pid"; fi
    stop_pid "$dir/link.pid"
    for f in $(rollouts); do
      id="$(basename "$f" .jsonl | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')"
      codex delete --force "$id" >/dev/null && echo "deleted Codex session $id" || echo "couldn't delete Codex session $id" >&2
    done
    if [ "$(cat "$dir/server-was-running" 2>/dev/null)" = no ] && loaded >/dev/null 2>&1; then
      busy="$(others)"
      if [ -z "$busy" ]; then
        codex app-server daemon stop >/dev/null && echo "stopped Codex's app server (it wasn't running before)"
      else
        printf 'left Codex app server running: it has other sessions loaded:\n%s\n' "$busy"
      fi
    fi
    if [ -f "$dir/config.before.toml" ] && ! cmp -s "$dir/config.before.toml" "$codex_home/config.toml"; then
      echo "note: $codex_home/config.toml changed during the test (Codex writes first-run flags there):" >&2
      diff -u "$dir/config.before.toml" "$codex_home/config.toml" >&2 || true
    fi
    ;;
  *) echo "unknown command $cmd" >&2; exit 1 ;;
esac
