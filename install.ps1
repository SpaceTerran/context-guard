# Installs Context Guard for this Windows user:
#   - puts the hook program (context-guard.exe, with the Swift runtime DLLs it runs on) in
#     %USERPROFILE%\.claude\hooks\context-guard
#   - adds its hooks to %USERPROFILE%\.claude\settings.json (`context-guard setup`: backed up first;
#     other hooks are left alone)
#   - puts the mod (the part that compacts once the session has saved) in
#     %USERPROFILE%\.claude\hooks\context-guard\mod and installs it as a Claude Code plugin for
#     this user
#
# It installs what build.ps1 made, so run it from that folder (dist\context-guard) or next to it:
#
#   powershell -ExecutionPolicy Bypass -File install.ps1              install, or update in place
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall   remove the hooks, the hook
#       program and the mod; keeps your settings and session records in
#       %USERPROFILE%\.claude\context-guard
#
# Windows PowerShell 5.1 and PowerShell 7 both run it. ASCII only: 5.1 reads a file without a BOM
# as ANSI.
param([switch]$Uninstall)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$from = $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $from 'context-guard.exe'))) { $from = Join-Path $PSScriptRoot 'dist\context-guard' }
$fromExe = Join-Path $from 'context-guard.exe'
$claude = Join-Path $env:USERPROFILE '.claude'
$settings = Join-Path $claude 'settings.json'
$hookDir = Join-Path $claude 'hooks\context-guard'
$hookExe = Join-Path $hookDir 'context-guard.exe'
$modDir = Join-Path $hookDir 'mod'
# The plugin and the marketplace (the mod's own folder) are both named context-guard.
$plugin = 'context-guard@context-guard'
# Every Context Guard hook command contains one of these (as JSON writes it).
$markers = @('hooks/context-guard/context-guard', 'hooks\\context-guard\\context-guard')
if ($env:CONTEXT_GUARD_HOME) { $state = $env:CONTEXT_GUARD_HOME }
elseif ($env:CLAUDE_CONFIG_DIR) { $state = Join-Path $env:CLAUDE_CONFIG_DIR 'context-guard' }
else { $state = Join-Path $claude 'context-guard' }

function Say([string]$Text) { Write-Host $Text }

function Fail([string]$Text) {
    [Console]::Error.WriteLine("error: $Text")
    exit 1
}

# Runs a program and returns its exit code; its output lines are left in $script:output, and
# shown unless -Quiet. Windows PowerShell turns a program's stderr lines into errors, so they're
# collected as text.
function Invoke-Program {
    param([string]$Program, [string[]]$Arguments, [switch]$Quiet)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $script:output = @(& $Program @Arguments 2>&1 | ForEach-Object {
            $line = "$_"
            if (-not $Quiet) { Write-Host $line }
            $line
        })
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
    }
}

function Find-Claude {
    Get-Command claude -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
}

# Moves a file or folder out of the way and deletes it if it can. A running hook keeps the program
# and its DLLs open, and Windows lets an open program be renamed but not deleted; the next run
# deletes what's left (Remove-SetAside).
function Set-Aside([string]$Path) {
    $name = '.{0}.{1}.old' -f (Split-Path $Path -Leaf), [Guid]::NewGuid().ToString('N').Substring(0, 8)
    Rename-Item -LiteralPath $Path -NewName $name
    try { Remove-Item -LiteralPath (Join-Path (Split-Path $Path) $name) -Recurse -Force } catch { }
}

function Remove-SetAside {
    if (-not (Test-Path -LiteralPath $hookDir)) { return }
    Get-ChildItem -LiteralPath $hookDir -Force -Filter '.*.old' | ForEach-Object {
        try { Remove-Item -LiteralPath $_.FullName -Recurse -Force } catch { }
    }
}

# Copies a file into place unless it's already there: the new copy goes in beside it, then takes
# its name.
function Install-File([string]$Source, [string]$Target) {
    if ((Test-Path -LiteralPath $Target) -and (Get-FileHash -LiteralPath $Source).Hash -eq (Get-FileHash -LiteralPath $Target).Hash) { return }
    $new = Join-Path (Split-Path $Target) ('.{0}.new' -f (Split-Path $Target -Leaf))
    Copy-Item -LiteralPath $Source -Destination $new -Force
    if (Test-Path -LiteralPath $Target) { Set-Aside $Target }
    Rename-Item -LiteralPath $new -NewName (Split-Path $Target -Leaf)
}

# The program and its DLLs: the DLLs first, so the program never starts with half of them.
function Install-Program {
    New-Item -ItemType Directory -Path $hookDir -Force | Out-Null
    Remove-SetAside
    foreach ($dll in @(Get-ChildItem -LiteralPath $from -Filter '*.dll')) {
        Install-File $dll.FullName (Join-Path $hookDir $dll.Name)
    }
    # Any an earlier version needed and this one doesn't.
    foreach ($dll in @(Get-ChildItem -LiteralPath $hookDir -Filter '*.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $from $dll.Name))) { Set-Aside $dll.FullName }
    }
    Install-File $fromExe $hookExe
    Say "installed $hookExe"
}

# Copies the mod and swaps the folder in whole. Claude Code reads the plugin from this folder in
# place, so a copy is all an update needs.
function Copy-Mod {
    $new = Join-Path $hookDir '.mod.new'
    if (Test-Path -LiteralPath $new) { Remove-Item -LiteralPath $new -Recurse -Force }
    Copy-Item -LiteralPath (Join-Path $from 'mod') -Destination $new -Recurse
    if (Test-Path -LiteralPath $modDir) { Set-Aside $modDir }
    Rename-Item -LiteralPath $new -NewName 'mod'
    Say "installed $modDir"
}

# Registers the mod's folder as a marketplace and installs the plugin from it, once; running it
# again changes nothing.
function Install-Mod {
    $cli = Find-Claude
    if (-not $cli) {
        [Console]::Error.WriteLine("warning: no claude command, so the mod isn't installed; run this again where claude is on PATH")
        return
    }
    if ((Invoke-Program $cli.Source @('plugin', 'validate', $modDir) -Quiet) -ne 0) {
        $script:output | ForEach-Object { [Console]::Error.WriteLine($_) }
        Fail "the mod didn't validate"
    }
    foreach ($step in @(@('plugin', 'marketplace', 'add', $modDir), @('plugin', 'install', $plugin, '--scope', 'user'))) {
        if ((Invoke-Program $cli.Source $step -Quiet) -ne 0) {
            $script:output | ForEach-Object { [Console]::Error.WriteLine($_) }
            Fail "claude $($step -join ' ') failed"
        }
    }
    Say "installed the Claude Code plugin $plugin (running sessions load it at /reload-plugins or a restart)"
}

function Uninstall-Mod {
    $cli = Find-Claude
    if ($cli) {
        $null = Invoke-Program $cli.Source @('plugin', 'uninstall', $plugin, '--scope', 'user') -Quiet
        $null = Invoke-Program $cli.Source @('plugin', 'marketplace', 'remove', 'context-guard') -Quiet
        Say "removed the Claude Code plugin $plugin"
    }
    if (Test-Path -LiteralPath $modDir) { Set-Aside $modDir }
}

# Takes Context Guard's hooks out of settings.json, with the program that put them there: the
# installed one, or the one next to this script when that's gone.
function Remove-Hooks {
    if (-not (Test-Path -LiteralPath $settings)) { return }
    $text = [IO.File]::ReadAllText($settings)
    if (-not ($markers | Where-Object { $text.Contains($_) })) { return }
    if (Test-Path -LiteralPath $hookExe) { $program = $hookExe }
    elseif (Test-Path -LiteralPath $fromExe) { $program = $fromExe }
    else { Fail "$settings still has Context Guard's hooks, and there's no context-guard.exe to take them out; run this from the folder build.ps1 made" }
    if ((Invoke-Program $program @('setup', '--uninstall')) -ne 0) { exit 1 }
}

function Uninstall-All {
    Remove-Hooks
    Uninstall-Mod
    if (Test-Path -LiteralPath $hookDir) {
        foreach ($file in @(Get-ChildItem -LiteralPath $hookDir -File | Where-Object { $_.Name -eq 'context-guard.exe' -or $_.Extension -eq '.dll' })) {
            Set-Aside $file.FullName
        }
        Remove-SetAside
        $left = @(Get-ChildItem -LiteralPath $hookDir -Force)
        if ($left.Count -eq 0) { Remove-Item -LiteralPath $hookDir }
    }
    Say "removed $hookExe and $modDir"
    if ((Test-Path -LiteralPath $hookDir) -and @(Get-ChildItem -LiteralPath $hookDir -Force -Filter '.*.old').Count -gt 0) {
        Say "a running hook still has some of their files open; they're renamed *.old in $hookDir, and the next install or uninstall deletes them"
    }
    Say "kept your settings and session records in $state"
}

function Install-All {
    if (-not (Test-Path -LiteralPath $fromExe)) { Fail "no context-guard.exe next to install.ps1 or in dist\context-guard; run build.ps1 first" }
    # The program first, so the hooks never point at a missing file.
    Install-Program
    # Backs up settings.json, then removes and adds the hooks, so running this again leaves exactly
    # one copy of each. Other hooks and settings stay as they are.
    if ((Invoke-Program $hookExe @('setup')) -ne 0) { exit 1 }
    Copy-Mod
    Install-Mod
    $null = Invoke-Program $hookExe @('status')
}

# The program writes UTF-8; read it as that.
$savedEncoding = $null
try {
    $savedEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
} catch { }
try {
    if ($Uninstall) { Uninstall-All } else { Install-All }
} finally {
    if ($savedEncoding) { try { [Console]::OutputEncoding = $savedEncoding } catch { } }
}
