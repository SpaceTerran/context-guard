#!/bin/bash
# Installs Context Guard for this Mac user:
#   - builds it (build.sh)
#   - puts the hook program at ~/.claude/hooks/context-guard/context-guard
#   - adds its hooks to ~/.claude/settings.json (`context-guard setup`: backed up first; other hooks
#     are left alone)
#   - puts the mod (mod/, the part that compacts once the session has saved) at ~/.claude/hooks/context-guard/mod
#     and installs it as a Claude Code plugin for this user
#   - adds a LaunchAgent that keeps `context-guard codex` running, which guards Codex sessions
#     (macOS says "Background Items Added")
#   - puts the app in ~/Applications, sets it to open at login, and starts it
#
#   ./install.sh               install, or update in place (run it again after changing the code)
#   ./install.sh --no-codex    the same, without the Codex link (and removes one installed before)
#   ./install.sh --uninstall   remove the hooks, the hook program, the mod, the Codex link and the
#                              app; keeps your settings and session records in ~/.claude/context-guard
set -euo pipefail

pkg="$(cd "$(dirname "$0")" && pwd)"
dist="$pkg/dist"
claude="$HOME/.claude"
settings="$claude/settings.json"
hook_dir="$claude/hooks/context-guard"
hook_bin="$hook_dir/context-guard"
mod_dir="$hook_dir/mod"
# The plugin and the marketplace (the mod's own folder) are both named context-guard.
plugin="context-guard@context-guard"
app="$HOME/Applications/Context Guard.app"
exe="$app/Contents/MacOS/ContextGuard"
# Every Context Guard hook command contains this path.
marker="hooks/context-guard/context-guard"
# The LaunchAgent that runs `context-guard codex`. The app looks for this file to tell whether the
# Codex link is installed.
agent_label="com.spaceterran.ContextGuard.codex"
agent_plist="$HOME/Library/LaunchAgents/$agent_label.plist"
agent="gui/$(id -u)/$agent_label"
state="${CONTEXT_GUARD_HOME:-${CLAUDE_CONFIG_DIR:-$claude}/context-guard}"

say() { printf '%s\n' "$*"; }

app_running() { pgrep -qf "^$exe" ; }

quit_app() {
  app_running || return 0
  osascript -e 'quit app id "com.spaceterran.ContextGuard"' >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do app_running || return 0; sleep 0.1; done
  pkill -f "^$exe" || true
}

# Takes Context Guard's hooks out of settings.json, with the program that put them there: the
# installed one, or this checkout's build when that's gone.
remove_hooks() {
  [ -f "$settings" ] && grep -q "$marker" "$settings" || return 0
  local prog="$hook_bin"
  if [ ! -x "$prog" ]; then
    swift build -c release --product context-guard --package-path "$pkg" >/dev/null
    prog="$(swift build -c release --show-bin-path --package-path "$pkg")/context-guard"
  fi
  "$prog" setup --uninstall
}

# Tells the hooks waiting in the background after each turn to stop, so none sends a save message
# once Context Guard is gone. Stdin is empty: a program from before `hook --stop` reads it as a hook
# would, finds nothing and exits.
stop_waiters() {
  [ -x "$hook_bin" ] || return 0
  "$hook_bin" hook --stop </dev/null || true
}

# Copies the mod's files (not its tests) and swaps the folder in whole. Claude Code reads the
# plugin from this folder in place, so a copy is all an update needs.
copy_mod() {
  local new="$hook_dir/.mod.new" old="$hook_dir/.mod.old"
  rm -rf "$new" "$old"
  mkdir -p "$new/.claude-plugin"
  cp "$pkg/mod/.claude-plugin/plugin.json" "$pkg/mod/.claude-plugin/marketplace.json" "$new/.claude-plugin/"
  cp -R "$pkg/mod/hooks" "$new/hooks"
  [ -d "$mod_dir" ] && mv "$mod_dir" "$old"
  mv "$new" "$mod_dir"
  rm -rf "$old"
  say "installed $mod_dir"
}

# Registers the mod's folder as a marketplace and installs the plugin from it, once; running it
# again changes nothing.
install_mod() {
  if ! command -v claude >/dev/null; then
    say "warning: no claude command, so the mod isn't installed; run this again where claude is on PATH" >&2
    return
  fi
  local out
  if ! out="$(claude plugin validate "$mod_dir" 2>&1)"; then
    printf '%s\n' "$out" >&2
    say "error: the mod didn't validate" >&2
    exit 1
  fi
  claude plugin marketplace add "$mod_dir" >/dev/null
  claude plugin install "$plugin" --scope user >/dev/null
  say "installed the Claude Code plugin $plugin (running sessions load it at /reload-plugins or a restart)"
}

uninstall_mod() {
  if command -v claude >/dev/null; then
    claude plugin uninstall "$plugin" --scope user >/dev/null 2>&1 || true
    claude plugin marketplace remove context-guard >/dev/null 2>&1 || true
    say "removed the Claude Code plugin $plugin"
  fi
  rm -rf "$mod_dir"
}

xml() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }

# Stops the link (it says so in codex-link.json) and waits until launchd has let it go, so it can
# be loaded again right away.
stop_codex_link() {
  launchctl bootout "$agent" >/dev/null 2>&1 || return 0
  for _ in $(seq 1 100); do launchctl print "$agent" >/dev/null 2>&1 || return 0; sleep 0.1; done
}

# Writes the LaunchAgent and (re)starts it, so it runs the program just installed. It inherits no
# shell variables, so the folders Context Guard and Codex use are written into it.
install_codex_link() {
  local env="" key
  for key in CODEX_HOME CLAUDE_CONFIG_DIR CONTEXT_GUARD_HOME; do
    [ -n "${!key:-}" ] && env+="        <key>$key</key><string>$(xml "${!key}")</string>"$'\n'
  done
  mkdir -p "$(dirname "$agent_plist")" "$state"
  local tmp
  tmp="$(mktemp "$(dirname "$agent_plist")/.$agent_label.XXXXXX")"
  cat > "$tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$agent_label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(xml "$hook_bin")</string>
        <string>codex</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
$env    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardErrorPath</key>
    <string>$(xml "$state/codex-link.stderr")</string>
</dict>
</plist>
PLIST
  plutil -lint "$tmp" >/dev/null
  chmod 644 "$tmp"
  mv -f "$tmp" "$agent_plist"
  stop_codex_link
  launchctl bootstrap "gui/$(id -u)" "$agent_plist"
  say "installed $agent_plist (runs \`context-guard codex\`; macOS may say \"Background Items Added\")"
  # Its first report, so the status below shows it.
  for _ in $(seq 1 30); do [ -f "$state/codex-link.json" ] && break; sleep 0.1; done
}

# Removes the LaunchAgent and what the link last said, so the app and `status` go back to showing
# Claude Code alone. Its log stays with the session records.
uninstall_codex_link() {
  [ -f "$agent_plist" ] || launchctl print "$agent" >/dev/null 2>&1 || [ -f "$state/codex-link.json" ] || return 0
  stop_codex_link
  rm -f "$agent_plist" "$state/codex-link.json" "$state/codex-link.lock" "$state/codex-link.stderr"
  say "removed the Codex link ($agent_plist)"
}

uninstall() {
  uninstall_codex_link
  quit_app
  if [ -x "$exe" ]; then "$exe" --login-item off 2>/dev/null || true; fi
  rm -rf "$app"
  say "removed $app"
  remove_hooks
  uninstall_mod
  stop_waiters
  rm -f "$hook_bin"
  rmdir "$hook_dir" 2>/dev/null || true
  say "removed $hook_bin and $mod_dir"
  say "kept your settings and session records in $claude/context-guard"
}

install() {
  local codex="$1"
  "$pkg/build.sh"

  # The hook program first, so the hooks never point at a missing file. Renamed into place:
  # hooks already waiting keep running the old copy until they finish.
  mkdir -p "$hook_dir"
  local tmp
  tmp="$(mktemp "$hook_dir/.context-guard.XXXXXX")"
  cp "$dist/context-guard" "$tmp"
  chmod 755 "$tmp"
  mv -f "$tmp" "$hook_bin"
  say "installed $hook_bin"

  # Backs up settings.json, then removes and adds the hooks, so running this again leaves exactly
  # one copy of each. Other hooks and settings stay as they are.
  "$hook_bin" setup

  copy_mod
  install_mod

  if [ "$codex" = yes ]; then install_codex_link; else uninstall_codex_link; fi

  quit_app
  mkdir -p "$(dirname "$app")"
  rm -rf "$app.new"
  ditto "$dist/Context Guard.app" "$app.new"
  rm -rf "$app"
  mv "$app.new" "$app"
  say "installed $app"

  if "$exe" --login-item on; then
    say "Context Guard opens at login (change it in its Settings)"
  else
    say "warning: couldn't set Context Guard to open at login; turn it on in its Settings" >&2
  fi
  open "$app"

  "$hook_bin" status
}

case "${1:-}" in
  "") install yes ;;
  --no-codex) install no ;;
  --uninstall) uninstall ;;
  *) say "usage: $0 [--no-codex | --uninstall]" >&2; exit 1 ;;
esac
