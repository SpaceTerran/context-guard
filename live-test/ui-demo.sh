#!/bin/bash
# Run the app against staged sessions, to look at it without real Claude Code sessions.
#
#   live-test/ui-demo.sh start [light|dark]   stage four sessions and launch the debug app on them
#   live-test/ui-demo.sh phase <A|B|C|D> <phase> [tokens]   change a staged session (as the hook would)
#   live-test/ui-demo.sh followup <A|B|C|D> <stage> [note] [compacted]  set where compacting stands after
#                                             the save message (continuing, done and tookOver are always compacted)
#   live-test/ui-demo.sh followup <A|B|C|D> background [minutes]  done saving, held by two background
#                                             agents for that long (default 1); from 10, the app asks you
#   live-test/ui-demo.sh watch <A|B|C|D> on|off             watch a staged session's tab, or stop
#   live-test/ui-demo.sh settings             open Settings (from the menu, through accessibility)
#   live-test/ui-demo.sh tab <General|When to Ask|Messages>  show a Settings tab (pressed through accessibility)
#   live-test/ui-demo.sh press "<label>"      press a button or switch in the app's windows, by its label
#   live-test/ui-demo.sh controls             list the controls in the app's windows and their labels
#   live-test/ui-demo.sh type "<field>" <text> replace a Settings field's text, typed key by key
#   live-test/ui-demo.sh windows              list the app's windows (id, bounds) for screenshots
#   live-test/ui-demo.sh stop
#
# Each staged session is "run" by a placeholder `sleep`, and a scratch registry says which are busy.
# Everything lives in .scratch/ui at the repo root; nothing touches real sessions.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
pkg="$(cd "$here/.." && pwd)"
repo="$(git -C "$pkg" rev-parse --show-toplevel)"
dir="$repo/.scratch/ui"
home="$dir/home"
reg="$dir/registry"
app="$pkg/.build/debug/ContextGuardApp"
cmd="${1:?command}"

# Finds controls by label through accessibility (live-test/ax.swift), compiled once.
ax() {
  [ -x "$pkg/.build/ax" ] && [ "$pkg/.build/ax" -nt "$here/ax.swift" ] || swiftc -O -o "$pkg/.build/ax" "$here/ax.swift"
  "$pkg/.build/ax" "$(cat "$dir/app.pid")" "$@"
}

stage() {
  python3 - "$home" "$reg" "$dir" "$@" <<'EOF'
import json, os, sys, datetime, subprocess
home, reg, d = sys.argv[1:4]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
H = os.path.expanduser("~")
sessions = {
  # Made-up projects, so screenshots show nothing real. The debug app has its own menu bar gauge.
  "A": dict(title="Refactor the billing API", name="api-server-4c", cwd=f"{H}/code/api-server", tokens=302_517, phase="asking", status="idle", waiter=True),
  "B": dict(title="Write the 2.0 release notes", name="docs-site-9e", cwd=f"{H}/code/docs-site", tokens=412_090, phase="later", status="busy", waiter=False),
  "C": dict(title="Fix the flaky login test", name="web-app-21", cwd=f"{H}/code/web-app", tokens=188_400, phase="watching", status="idle", waiter=False),
  "D": dict(title="Move the jobs to Postgres", name="pipeline-b7", cwd=f"{H}/code/pipeline", tokens=341_250, phase="sent", status="idle", waiter=False),
}
pids = json.load(open(f"{d}/pids.json"))

def start(pid):
    """The process's start time, as the hook records it (the mute mark is keyed to it)."""
    import ctypes, ctypes.util
    libc = ctypes.CDLL(ctypes.util.find_library("c"))
    buf = ctypes.create_string_buffer(648)  # sizeof(struct kinfo_proc) on macOS
    size = ctypes.c_size_t(len(buf))
    mib = (ctypes.c_int * 4)(1, 14, 1, pid)  # CTL_KERN, KERN_PROC, KERN_PROC_PID
    assert libc.sysctl(mib, 4, buf, ctypes.byref(size), None, 0) == 0 and size.value
    sec, usec = ctypes.c_long.from_buffer(buf, 0).value, ctypes.c_int.from_buffer(buf, 8).value
    return {"seconds": sec, "microseconds": usec}
for key, s in sessions.items():
    sid = f"00000000-0000-4000-8000-00000000000{'ABCD'.index(key) + 1}"
    state = {
      "schemaVersion": 1, "sessionId": sid, "cwd": s["cwd"], "title": s["title"], "name": s["name"],
      "tokens": s["tokens"], "tokensAt": now, "updatedAt": now, "lastEvent": "Stop",
      "claudePid": pids[key], "claudeStart": start(pids[key]), "guarded": True, "phase": s["phase"], "cycle": 1,
      "stopsSinceSent": 0, "resendCount": 0, "awaitingCompactionRecord": False, "ended": False,
    }
    if s["phase"] in ("asking", "later", "sent"):
        state.update(askedAt=now, askedTokens=300_420)
    if s["phase"] == "sent":
        state.update(sendReason="yes", sentAt=now, sentNonce="cg-demo00000d", sentVia="wake", sentTokens=341_250, confirmedAt=now)
    if s["waiter"]:
        state.update(waiterToken="DEMO", waiterPid=pids["waiter"], waiterSince=now)
    json.dump(state, open(f"{home}/sessions/{sid}.json", "w"), indent=2)
    json.dump({"pid": pids[key], "sessionId": sid, "kind": "interactive", "entrypoint": "cli", "name": s["name"],
               "cwd": s["cwd"], "status": s["status"]}, open(f"{reg}/{pids[key]}.json", "w"))
EOF
}

case "$cmd" in
  start)
    "$0" stop >/dev/null 2>&1 || true
    rm -rf "$dir"; mkdir -p "$home/sessions" "$home/answers" "$reg"
    printf '{"schemaVersion":1,"enabled":true,"askAt":300000,"laterAt":500000}\n' > "$home/config.json"
    echo "{" > "$dir/pids.json"
    for k in A B C D waiter; do
      nohup sleep 86400 >/dev/null 2>&1 &
      printf '"%s": %d,\n' "$k" $! >> "$dir/pids.json"
    done
    printf '"_": 0}\n' >> "$dir/pids.json"
    stage
    # Launch arguments set the appearance for this app only: Aqua-only for light, Dark for dark.
    if [ "${2:-light}" = dark ]; then look=(-AppleInterfaceStyle Dark); else look=(-NSRequiresAquaSystemAppearance YES); fi
    CONTEXT_GUARD_HOME="$home" CONTEXT_GUARD_REGISTRY="$reg" nohup "$app" "${look[@]}" > "$dir/app.log" 2>&1 &
    echo $! > "$dir/app.pid"
    echo "app pid $(cat "$dir/app.pid"), home $home"
    ;;
  phase)
    key="${2:?A|B|C|D}"; phase="${3:?phase}"; tokens="${4:-}"
    f="$home/sessions/00000000-0000-4000-8000-00000000000$(( $(printf '%d' "'$key") - 64 )).json"
    jq --arg p "$phase" --arg t "$tokens" '.phase = $p | (if $t != "" then .tokens = ($t | tonumber) else . end)' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    ;;
  followup)
    key="${2:?A|B|C|D}"; stage="${3:?stage}"; note="${4:-}"; compacted="${5:-}"
    f="$home/sessions/00000000-0000-4000-8000-00000000000$(( $(printf '%d' "'$key") - 64 )).json"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    case "$stage" in continuing|done|tookOver) compacted=compacted ;; esac
    wait="{}"
    if [ "$stage" = background ]; then
      minutes="${note:-1}"; note=""
      since="$(date -u -v-"${minutes}"M +%Y-%m-%dT%H:%M:%SZ)"
      wait="$(jq -n --arg since "$since" --arg now "$now" --argjson m "$minutes" \
        '{verdict: "ready", background: {agents: 2, shells: false}, backgroundSince: $since}
         + (if $m >= 10 then {backgroundAskedAt: $now} else {} end)')"
    fi
    jq --arg s "$stage" --arg n "$note" --arg c "$compacted" --arg now "$now" --argjson w "$wait" '.followUp = {
        nonce: (.sentNonce // ("cg-demo-" + .name)), stage: $s, startedAt: $now, stageAt: $now,
        tokensBefore: .tokens, tokensAfter: 24100} + (if $n != "" then {note: $n} else {} end)
        + (if $c != "" then {compactedAt: $now} else {} end) + $w' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    ;;
  watch)
    key="${2:?A|B|C|D}"
    CONTEXT_GUARD_HOME="$home" CONTEXT_GUARD_REGISTRY="$reg" "$pkg/.build/debug/context-guard" watch \
      "00000000-0000-4000-8000-00000000000$(( $(printf '%d' "'$key") - 64 ))" "${3:?on|off}"
    ;;
  settings)
    osascript -e 'tell application "System Events" to tell process "ContextGuardApp"' \
      -e 'click menu bar item 1 of menu bar 2' -e 'delay 0.4' \
      -e 'click menu item "Settings…" of menu 1 of menu bar item 1 of menu bar 2' -e 'end tell' >/dev/null
    ;;
  type)
    # Never System Events keystrokes: those go to the app in front, which may be someone's terminal.
    # Clear the field through accessibility (that alone doesn't count as typing), then send each key
    # to the app's pid only. ⌘A can't be used: a window opened by script isn't active, so the app
    # ignores its menu shortcuts.
    field="${2:?field label}"; text="${3?text}"
    [ -x "$pkg/.build/typeto" ] || swiftc -O -o "$pkg/.build/typeto" "$here/type.swift"
    ax clear "$field"
    "$pkg/.build/typeto" "$(cat "$dir/app.pid")" "$text"
    ;;
  tab|press)
    ax press "${2:?label}"
    ;;
  controls)
    ax list
    ;;
  windows)
    swift "$here/windows.swift" ContextGuardApp
    ;;
  stop)
    [ -f "$dir/app.pid" ] && kill "$(cat "$dir/app.pid")" 2>/dev/null || true
    [ -f "$dir/pids.json" ] && jq -r 'to_entries[] | select(.key != "_") | .value' "$dir/pids.json" | xargs kill 2>/dev/null || true
    ;;
  *) echo "unknown command $cmd" >&2; exit 1 ;;
esac
