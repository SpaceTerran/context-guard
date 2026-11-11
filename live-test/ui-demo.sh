#!/bin/bash
# Run the app against staged sessions, to look at it without real Claude Code sessions.
#
#   live-test/ui-demo.sh start [light|dark] [no-codex]   stage four Claude Code sessions and a Codex one (E),
#                                             with a stand-in for `context-guard codex`, and launch the debug app
#   live-test/ui-demo.sh phase <A-E> <phase> [tokens]   change a staged session (as the hook or the link would)
#   live-test/ui-demo.sh followup <A-E> <stage> [note] [compacted]  set where compacting stands after
#                                             the save message (continuing, done and tookOver are always compacted)
#   live-test/ui-demo.sh watch <A-D> on|off   watch a staged Claude Code session's tab, or stop
#   live-test/ui-demo.sh link connected|waiting|watching|stopped   what the stand-in link says
#   live-test/ui-demo.sh settings             open Settings (from the menu, through accessibility)
#   live-test/ui-demo.sh tab <General|When to Ask|Messages>  show a Settings tab (pressed through accessibility)
#   live-test/ui-demo.sh press "<label>" [n]  press a button or switch in the app's windows, by its label
#                                             (n: the nth with that label, in `controls` order)
#   live-test/ui-demo.sh controls             list the controls in the app's windows and their labels
#   live-test/ui-demo.sh type "<field>" <text> [n]  replace a Settings field's text, typed key by key
#   live-test/ui-demo.sh windows              list the app's windows (id, bounds) for screenshots
#   live-test/ui-demo.sh snap <folder> <name>  have the app draw each window to <folder>/<name>-<n>.png
#                                             and write its menu to <folder>/<name>-menu.txt
#                                             (works with the display asleep or the screen locked)
#   live-test/ui-demo.sh capture <general|asking|messages> <file.png>  screen-capture a Settings window on
#                                             that tab, behind your windows and never focused (display awake)
#   live-test/ui-demo.sh stop
#
# Each staged Claude Code session is "run" by a placeholder `sleep`, and a scratch registry says which
# are busy. The Codex session is live while the stand-in link keeps codex-link.json fresh. Everything
# lives in .scratch/ui at the repo root; nothing touches real sessions.
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
codex = "no-codex" not in sys.argv[4:]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
H = os.path.expanduser("~")
sessions = {
  # Made-up projects, so screenshots show nothing real. The debug app has its own menu bar gauge.
  "A": dict(title="Refactor the billing API", name="api-server-4c", cwd=f"{H}/code/api-server", tokens=302_517, phase="asking", status="idle", waiter=True),
  "B": dict(title="Write the 2.0 release notes", name="docs-site-9e", cwd=f"{H}/code/docs-site", tokens=412_090, phase="later", status="busy", waiter=False),
  "C": dict(title="Fix the flaky login test", name="web-app-21", cwd=f"{H}/code/web-app", tokens=188_400, phase="watching", status="idle", waiter=False),
  "D": dict(title="Move the jobs to Postgres", name="pipeline-b7", cwd=f"{H}/code/pipeline", tokens=341_250, phase="sent", status="idle", waiter=False),
}
if codex:
    # 51% of its window: it asks at 60% (155k).
    sessions["E"] = dict(title="Add retries to the sync job", cwd=f"{H}/code/sync-service", tokens=131_800, phase="watching", codex=True)
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
    sid = f"00000000-0000-4000-8000-00000000000{'ABCDE'.index(key) + 1}"
    if s.get("codex"):
        state = {
          "schemaVersion": 1, "sessionId": sid, "host": "codex", "cwd": s["cwd"], "title": s["title"],
          "tokens": s["tokens"], "tokensAt": now, "updatedAt": now, "guarded": True, "phase": s["phase"], "cycle": 1,
          "stopsSinceSent": 0, "resendCount": 0, "awaitingCompactionRecord": False, "ended": False,
          "codex": {"window": 258_400, "model": "gpt-6.1-codex", "originator": "codex-tui", "terminal": True,
                    "status": "idle", "statusAt": now, "loaded": True, "attached": True},
        }
        json.dump(state, open(f"{home}/sessions/{sid}.json", "w"), indent=2)
        continue
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
    rm -rf "$dir"; mkdir -p "$home/sessions" "$home/answers" "$reg" "$dir/LaunchAgents"
    printf '{"schemaVersion":1,"enabled":true,"askAt":300000,"laterAt":500000}\n' > "$home/config.json"
    echo "{" > "$dir/pids.json"
    for k in A B C D waiter; do
      nohup sleep 86400 >/dev/null 2>&1 &
      printf '"%s": %d,\n' "$k" $! >> "$dir/pids.json"
    done
    if [ "${3:-}" != no-codex ]; then
      # The Codex link counts as installed (the app looks here, not in ~/Library/LaunchAgents).
      : > "$dir/LaunchAgents/com.spaceterran.ContextGuard.codex.plist"
      "$0" link connected
      # The stand-in for `context-guard codex`: keeps codex-link.json fresh, saying what link.json says.
      # shellcheck disable=SC2016  # the inner bash expands these
      nohup bash -c 'while :; do jq --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ".at = \$at" "$1/link.json" > "$2.tmp" && mv "$2.tmp" "$2"; sleep 4; done' \
        _ "$dir" "$home/codex-link.json" >/dev/null 2>&1 &
      printf '"link": %d,\n' $! >> "$dir/pids.json"
    fi
    printf '"_": 0}\n' >> "$dir/pids.json"
    stage "${3:-}"
    # Launch arguments set the appearance for this app only: Aqua-only for light, Dark for dark.
    if [ "${2:-light}" = dark ]; then look=(-AppleInterfaceStyle Dark); else look=(-NSRequiresAquaSystemAppearance YES); fi
    CONTEXT_GUARD_HOME="$home" CONTEXT_GUARD_REGISTRY="$reg" CONTEXT_GUARD_SNAPSHOTS="$dir/snaps" \
      CONTEXT_GUARD_LAUNCH_AGENTS="$dir/LaunchAgents" \
      nohup "$app" "${look[@]}" > "$dir/app.log" 2>&1 &
    echo $! > "$dir/app.pid"
    echo "app pid $(cat "$dir/app.pid"), home $home"
    ;;
  phase)
    key="${2:?A-E}"; phase="${3:?phase}"; tokens="${4:-}"
    f="$home/sessions/00000000-0000-4000-8000-00000000000$(( $(printf '%d' "'$key") - 64 )).json"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # A question starts its countdown when it's asked.
    jq --arg p "$phase" --arg t "$tokens" --arg now "$now" '.phase = $p | (if $t != "" then .tokens = ($t | tonumber) else . end)
        | (if $p == "asking" and .askedAt == null then .askedAt = $now | .askedTokens = .tokens else . end)' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    ;;
  followup)
    key="${2:?A-E}"; stage="${3:?stage}"; note="${4:-}"; compacted="${5:-}"
    f="$home/sessions/00000000-0000-4000-8000-00000000000$(( $(printf '%d' "'$key") - 64 )).json"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    case "$stage" in continuing|done|tookOver) compacted=compacted ;; esac
    jq --arg s "$stage" --arg n "$note" --arg c "$compacted" --arg now "$now" '.followUp = {
        nonce: (.sentNonce // ("cg-demo-" + .name)), stage: $s, startedAt: $now, stageAt: $now,
        tokensBefore: .tokens, tokensAfter: 24100} + (if $n != "" then {note: $n} else {} end)
        + (if $c != "" then {compactedAt: $now} else {} end)' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    ;;
  link)
    agent='"serverVersion": "codex-tui/0.167.1 (Mac OS 27.2.0; arm64)", "judgeModel": "gpt-6-luna"'
    case "${2:?connected|waiting|watching|stopped}" in
      connected) body="\"connected\": true, $agent" ;;
      waiting) body='"connected": false' ;;
      watching) body="\"connected\": true, $agent, \"observeOnly\": \"this Codex has no thread/queue/add\"" ;;
      stopped) body='"connected": false, "stopped": true' ;;
      *) echo "unknown link state $2" >&2; exit 1 ;;
    esac
    printf '{"at": "%s", %s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$body" > "$dir/link.json"
    cp "$dir/link.json" "$home/codex-link.json"
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
    ax clear "$field" "${4:-1}"
    "$pkg/.build/typeto" "$(cat "$dir/app.pid")" "$text"
    ;;
  tab|press)
    ax press "${2:?label}" "${3:-1}"
    ;;
  controls)
    ax list
    ;;
  windows)
    swift "$here/windows.swift" ContextGuardApp
    ;;
  snap)
    out="${2:?folder}"; name="${3:?name}"
    rm -rf "$dir/snaps"; mkdir -p "$out"
    kill -USR1 "$(cat "$dir/app.pid")"
    for _ in $(seq 50); do [ -f "$dir/snaps/index.txt" ] && break; sleep 0.1; done
    [ -f "$dir/snaps/index.txt" ] || { echo "the app wrote nothing (a debug build started by this script?)" >&2; exit 1; }
    n=0
    while IFS=$'\t' read -r file kind title frame; do
      n=$((n + 1)); cp "$dir/snaps/$file" "$out/$name-$n.png"
      echo "$out/$name-$n.png  $kind  ${title:-(no title)}  $frame"
    done < "$dir/snaps/index.txt"
    cp "$dir/snaps/menu.txt" "$out/$name-menu.txt" && echo "$out/$name-menu.txt  the menu"
    ;;
  capture)
    # The Settings window on one tab, as docs/settings.png shows it. Needs the display awake.
    tab="${2:?general|asking|messages}"; out="${3:?file.png}"
    mkdir -p "$dir/snaps"; rm -f "$dir/snaps/shown"
    echo "$tab" > "$dir/snaps/show"
    kill -USR2 "$(cat "$dir/app.pid")"
    for _ in $(seq 50); do [ -s "$dir/snaps/shown" ] && break; sleep 0.1; done
    [ -s "$dir/snaps/shown" ] || { echo "no window for $tab (a debug build started by this script?)" >&2; exit 1; }
    sleep 0.5
    screencapture -o -x -l "$(cat "$dir/snaps/shown")" "$out"
    rm -f "$dir/snaps/show"; kill -USR2 "$(cat "$dir/app.pid")"
    # Only the picture and its color profile: no screenshot metadata in a checked-in image.
    python3 -I - "$out" <<'EOF'
import struct, sys
p = sys.argv[1]; d = open(p, "rb").read(); i = 8; out = [d[:8]]
while i < len(d):
    n = struct.unpack(">I", d[i:i + 4])[0]
    if d[i + 4:i + 8] in (b"IHDR", b"iCCP", b"IDAT", b"IEND"): out.append(d[i:i + 12 + n])
    i += 12 + n
open(p, "wb").write(b"".join(out))
EOF
    echo "$out"
    ;;
  stop)
    [ -f "$dir/app.pid" ] && kill "$(cat "$dir/app.pid")" 2>/dev/null || true
    [ -f "$dir/pids.json" ] && jq -r 'to_entries[] | select(.key != "_") | .value' "$dir/pids.json" | xargs kill 2>/dev/null || true
    ;;
  *) echo "unknown command $cmd" >&2; exit 1 ;;
esac
