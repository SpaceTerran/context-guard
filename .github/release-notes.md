## Windows

Download `context-guard-windows-x64.zip`, extract it, and run the `install.ps1` in its
`context-guard` folder, as the
[README](https://github.com/SpaceTerran/context-guard#install-update-uninstall-on-windows) shows.
Doing the same with a newer release updates it. It needs Windows 11 on x64, Claude Code 2.1.287 or
newer, and for Codex sessions the Codex CLI 0.154 or newer.

`context-guard-windows-x64.zip.sha256` has the zip's SHA-256, which `Get-FileHash` shows too.

Context Guard isn't signed yet, so Smart App Control blocks it where it's on (Windows Security >
App & browser control).

## Mac

There's nothing to download: `install.sh` builds it from a clone of this repo, as the
[README](https://github.com/SpaceTerran/context-guard#install-update-uninstall) shows.
