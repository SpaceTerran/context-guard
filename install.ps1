# Installs Context Guard for this Windows user:
#   - puts the hook program (context-guard.exe, with the Swift runtime DLLs it runs on) in
#     %USERPROFILE%\.claude\hooks\context-guard
#   - adds its hooks to %USERPROFILE%\.claude\settings.json (`context-guard setup`: backed up first;
#     other hooks are left alone)
#   - puts the mod (the part that compacts once the session has saved) in
#     %USERPROFILE%\.claude\hooks\context-guard\mod and installs it as a Claude Code plugin for
#     this user
#   - adds a scheduled task, "Context Guard Codex link", that keeps the Codex link
#     (context-guard-link.exe, no window) running while you're signed in; it guards Codex sessions
#   - puts the app in %LOCALAPPDATA%\Programs\Context Guard, with a Start menu shortcut and an entry
#     in Settings > Apps (which uninstalls it), sets it to open at sign-in, and starts it
#
# It installs what build.ps1 made, so run it from that folder (dist\context-guard, or the zip's
# context-guard folder) or next to it:
#
#   powershell -ExecutionPolicy Bypass -File install.ps1              install, or update in place
#   powershell -ExecutionPolicy Bypass -File install.ps1 -NoCodex     the same, without the Codex
#       link (and removes one installed before)
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall   remove the hooks, the hook
#       program, the mod, the Codex link and the app; keeps your settings and session records in
#       %USERPROFILE%\.claude\context-guard
#
# For tests, CONTEXT_GUARD_TASK_NAME names another scheduled task and CONTEXT_GUARD_REGISTRY_KEY
# another key under HKEY_CURRENT_USER in place of Software\Microsoft\Windows\CurrentVersion (open at
# sign-in, the Apps entry), so neither touches the real ones.
#
# Windows PowerShell 5.1 and PowerShell 7 both run it. ASCII only: 5.1 reads a file without a BOM
# as ANSI.
param([switch]$Uninstall, [switch]$NoCodex)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
if ($Uninstall -and $NoCodex) {
    [Console]::Error.WriteLine('usage: install.ps1 [-NoCodex | -Uninstall]')
    exit 1
}

$from = $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $from 'context-guard.exe'))) { $from = Join-Path $PSScriptRoot 'dist\context-guard' }
$fromExe = Join-Path $from 'context-guard.exe'
$fromLink = Join-Path $from 'context-guard-link.exe'
$fromApp = Join-Path $from 'app'
$fromAppExe = Join-Path $fromApp 'ContextGuard.exe'
$claude = Join-Path $env:USERPROFILE '.claude'
$settings = Join-Path $claude 'settings.json'
$hookDir = Join-Path $claude 'hooks\context-guard'
$hookExe = Join-Path $hookDir 'context-guard.exe'
$linkExe = Join-Path $hookDir 'context-guard-link.exe'
$modDir = Join-Path $hookDir 'mod'
# The plugin and the marketplace (the mod's own folder) are both named context-guard.
$plugin = 'context-guard@context-guard'
# Every Context Guard hook command contains one of these (as JSON writes it).
$markers = @('hooks/context-guard/context-guard', 'hooks\\context-guard\\context-guard')
if ($env:CONTEXT_GUARD_HOME) { $state = $env:CONTEXT_GUARD_HOME }
elseif ($env:CLAUDE_CONFIG_DIR) { $state = Join-Path $env:CLAUDE_CONFIG_DIR 'context-guard' }
else { $state = Join-Path $claude 'context-guard' }
$linkStatus = Join-Path $state 'codex-link.json'
# The task that keeps the Codex link running. CONTEXT_GUARD_TASK_NAME names another one, so tests
# never touch the real task.
if ($env:CONTEXT_GUARD_TASK_NAME) { $taskName = $env:CONTEXT_GUARD_TASK_NAME }
else { $taskName = 'Context Guard Codex link' }
# The app's own folder, always this one: Windows keeps a notification-area icon's settings (shown on
# the taskbar or not) by the program's path.
$programs = Join-Path $env:LOCALAPPDATA 'Programs'
$appDir = Join-Path $programs 'Context Guard'
$appExe = Join-Path $appDir 'ContextGuard.exe'
$shortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Context Guard.lnk'
# Where open at sign-in (Run) and the Apps entry (Uninstall) go; see CONTEXT_GUARD_REGISTRY_KEY above.
if ($env:CONTEXT_GUARD_REGISTRY_KEY) {
    $registryBase = $env:CONTEXT_GUARD_REGISTRY_KEY
    $loginKey = @('--login-key', $registryBase)
} else {
    $registryBase = 'Software\Microsoft\Windows\CurrentVersion'
    $loginKey = @()
}
$appsKey = "$registryBase\Uninstall\ContextGuard"

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

# The programs and their DLLs: the DLLs first, so a program never starts with half of them; then the
# Codex link (unless -NoCodex), then the hook program.
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
    if (-not $NoCodex) {
        Install-File $fromLink $linkExe
        Say "installed $linkExe"
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

# One argument as a Windows program reads it back (quotes around it when it needs them, and the
# backslashes before a quote doubled).
function ConvertTo-Argument([string]$Text) {
    if ($Text -and $Text -notmatch '[\s"]') { return $Text }
    $quoted = '"'
    $slashes = 0
    foreach ($c in $Text.ToCharArray()) {
        if ($c -eq [char]'\') { $slashes++; continue }
        if ($c -eq [char]'"') { $quoted += ('\' * (2 * $slashes + 1)) + '"' }
        else { $quoted += ('\' * $slashes) + $c }
        $slashes = 0
    }
    return $quoted + ('\' * (2 * $slashes)) + '"'
}

# Task Scheduler through its COM API: a standard user can use it, where the ScheduledTasks cmdlets
# need more.
function Get-TaskService {
    $service = New-Object -ComObject Schedule.Service
    $service.Connect()
    return $service
}

function Get-LinkTask {
    try { return (Get-TaskService).GetFolder('\').GetTask($taskName) } catch { return $null }
}

# Registers the task, or updates it to run the link with this run's settings. It runs the link in
# your own session, unelevated, while you're signed in: started at sign-in, and every minute
# when it isn't running (after a crash, a kill or a stop), never two at once.
function Register-LinkTask {
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $service = Get-TaskService
    $task = $service.NewTask(0)
    $task.RegistrationInfo.Description = "Keeps Context Guard's Codex link running (context-guard-link.exe), which guards Codex sessions. Installed by Context Guard's install.ps1."
    $task.Principal.UserId = $me
    $task.Principal.LogonType = 3              # interactive token: your own session
    $task.Principal.RunLevel = 0               # least privilege
    $options = $task.Settings
    $options.MultipleInstances = 2             # a start while it runs is ignored
    $options.ExecutionTimeLimit = 'PT0S'       # no time limit
    $options.DisallowStartIfOnBatteries = $false
    $options.StopIfGoingOnBatteries = $false
    $options.StartWhenAvailable = $true
    $options.RestartCount = 999
    $options.RestartInterval = 'PT1M'
    $options.Priority = 5                      # normal, as the Mac's LaunchAgent
    $logon = $task.Triggers.Create(9)          # at sign-in
    $logon.UserId = $me
    $every = $task.Triggers.Create(1)          # from now on, every minute
    $every.StartBoundary = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    $every.Repetition.Interval = 'PT1M'
    $action = $task.Actions.Create(0)
    $action.Path = $linkExe
    $action.WorkingDirectory = $hookDir
    # A task has no environment of its own: the folders set for this run go to the link.
    $arguments = @()
    foreach ($name in @('CODEX_HOME', 'CLAUDE_CONFIG_DIR', 'CONTEXT_GUARD_HOME')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { $arguments += @('--env', (ConvertTo-Argument "$name=$value")) }
    }
    $action.Arguments = $arguments -join ' '
    # 6: create or update; 3: run as the signed-in user, no password.
    $null = $service.GetFolder('\').RegisterTaskDefinition($taskName, $task, 6, $null, $null, 3)
}

# Asks the running link to stop (deleting or updating its task doesn't), with the program that is
# here: the installed one, or the one next to this script.
function Stop-Link {
    if (Test-Path -LiteralPath $hookExe) { $program = $hookExe }
    elseif (Test-Path -LiteralPath $fromExe) { $program = $fromExe }
    else { return }
    if ((Invoke-Program $program @('codex', '--stop') -Quiet) -ne 0) {
        $script:output | ForEach-Object { [Console]::Error.WriteLine("warning: $_") }
    }
}

# Ends the link the task is running: asked first (so it says so in codex-link.json), then ended by
# Task Scheduler if it's still running two seconds later. One installed with other settings keeps
# its files in another folder, and doesn't hear a request for this one.
function Stop-LinkTask($Task) {
    Stop-Link
    if (-not $Task) { return }
    for ($i = 0; $i -lt 20 -and $Task.State -eq 4; $i++) { Start-Sleep -Milliseconds 100 }
    if ($Task.State -eq 4) { $Task.Stop(0) }
}

# Registers the task, then restarts the link on the program just installed, and waits a moment
# for its first report so the status below shows it.
function Install-Link {
    try { Register-LinkTask } catch { Fail "couldn't register the scheduled task `"$taskName`": $($_.Exception.Message)" }
    Stop-LinkTask (Get-LinkTask)
    Remove-SetAside
    $started = [DateTime]::UtcNow
    $null = (Get-LinkTask).Run($null)
    Say "installed the scheduled task `"$taskName`" (runs context-guard-link.exe while you're signed in)"
    for ($i = 0; $i -lt 30; $i++) {
        if ((Test-Path -LiteralPath $linkStatus) -and (Get-Item -LiteralPath $linkStatus).LastWriteTimeUtc -ge $started) { break }
        Start-Sleep -Milliseconds 100
    }
}

# Removes the task, stops the link and removes what it last said, so `status` goes back to showing
# Claude Code alone. Its log stays with the session records.
function Uninstall-Link {
    $task = Get-LinkTask
    if (-not $task -and -not (Test-Path -LiteralPath $linkExe) -and -not (Test-Path -LiteralPath $linkStatus)) { return }
    # Disabled first, so it can't start the link again while it's being removed.
    if ($task) { $task.Enabled = $false }
    Stop-LinkTask $task
    if ($task) { (Get-TaskService).GetFolder('\').DeleteTask($taskName, 0) }
    foreach ($file in @($linkStatus, (Join-Path $state 'codex-link.lock'))) {
        if (Test-Path -LiteralPath $file) { try { Remove-Item -LiteralPath $file -Force } catch { } }
    }
    if (Test-Path -LiteralPath $linkExe) { Set-Aside $linkExe }
    Say "removed the Codex link (the scheduled task `"$taskName`")"
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

# Asks the app running in this session to quit, as Quit in its menu does (its program ends with it),
# with whichever copy of it is here; it waits up to 5 seconds for that. One still running from the
# installed folder after that is ended.
function Stop-App {
    $exe = @($fromAppExe, $appExe) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($exe) {
        if ((Invoke-Program $exe @('--quit') -Quiet) -ne 0) {
            $script:output | ForEach-Object { [Console]::Error.WriteLine("warning: $_") }
        }
    }
    $session = (Get-Process -Id $PID).SessionId
    foreach ($p in @(Get-Process -Name 'ContextGuard' -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session -and $_.Path -eq $appExe })) {
        try { $p.Kill(); $null = $p.WaitForExit(5000) } catch { }
    }
}

function Remove-AppSetAside {
    if (-not (Test-Path -LiteralPath $programs)) { return }
    Get-ChildItem -LiteralPath $programs -Force -Directory -Filter '.Context Guard.*' | ForEach-Object {
        try { Remove-Item -LiteralPath $_.FullName -Recurse -Force } catch { }
    }
}

# Copies the app and swaps its folder in whole, with a copy of this script beside it for the Apps
# entry's Uninstall.
function Install-App {
    New-Item -ItemType Directory -Path $programs -Force | Out-Null
    Remove-AppSetAside
    $new = Join-Path $programs '.Context Guard.new'
    Copy-Item -LiteralPath $fromApp -Destination $new -Recurse
    Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $new 'install.ps1')
    if (Test-Path -LiteralPath $appDir) {
        $old = '.Context Guard.{0}.old' -f [Guid]::NewGuid().ToString('N').Substring(0, 8)
        try { Rename-Item -LiteralPath $appDir -NewName $old }
        catch { Fail "couldn't replace $appDir (is Context Guard still running from it?): $($_.Exception.Message)" }
    }
    Rename-Item -LiteralPath $new -NewName (Split-Path $appDir -Leaf)
    Remove-AppSetAside
    Say "installed $appExe"
}

# A zip downloaded from the internet marks every file in it as such, and Windows then asks before
# running them; you chose to run this installer, so what it installs isn't marked.
function Unblock-Folder([string]$Path) {
    if (Test-Path -LiteralPath $Path) { Get-ChildItem -LiteralPath $Path -Recurse -File -Force | Unblock-File }
}

function Install-Shortcut {
    New-Item -ItemType Directory -Path (Split-Path $shortcut) -Force | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($shortcut)
    $link.TargetPath = $appExe
    $link.WorkingDirectory = $appDir
    $link.IconLocation = "$appExe,0"
    $link.Description = 'Asks before a Claude Code or Codex session is compacted'
    $link.Save()
    Say "installed $shortcut"
}

# The entry in Settings > Apps > Installed apps: its version is the app's, and Uninstall runs the
# copy of this script in the app's folder.
function Install-AppsEntry {
    $bytes = 0
    foreach ($dir in @($appDir, $hookDir)) {
        if (Test-Path -LiteralPath $dir) { $bytes += (Get-ChildItem -LiteralPath $dir -Recurse -File -Force | Measure-Object Length -Sum).Sum }
    }
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($appsKey)
    try {
        $key.SetValue('DisplayName', 'Context Guard')
        $key.SetValue('DisplayVersion', [string](Get-Item -LiteralPath $appExe).VersionInfo.ProductVersion)
        $key.SetValue('Publisher', 'SpaceTerran')
        $key.SetValue('DisplayIcon', $appExe)
        $key.SetValue('InstallLocation', $appDir)
        $key.SetValue('UninstallString', ('"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -Uninstall' -f $powershell, (Join-Path $appDir 'install.ps1')))
        $key.SetValue('NoModify', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
        $key.SetValue('NoRepair', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
        $key.SetValue('EstimatedSize', [int][math]::Ceiling($bytes / 1KB), [Microsoft.Win32.RegistryValueKind]::DWord)
        $key.SetValue('InstallDate', (Get-Date).ToString('yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture))
    } finally {
        $key.Close()
    }
    Say "added Context Guard to Settings > Apps > Installed apps"
}

function Test-Elevated {
    $principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-App {
    if (Test-Elevated) {
        Say "Context Guard isn't started: this installer runs as administrator, and the app runs as you. It starts when you sign in, or from Start."
        return
    }
    if ($loginKey.Count -gt 0) { Start-Process -FilePath $appExe -ArgumentList $loginKey -WorkingDirectory $appDir }
    else { Start-Process -FilePath $appExe -WorkingDirectory $appDir }
    Say "started Context Guard: its icon is in the notification area, at the right of the taskbar (under ^ until you pin it)"
}

function Install-AppAll {
    Install-App
    Unblock-Folder $appDir
    Install-Shortcut
    Install-AppsEntry
    if ((Invoke-Program $appExe ($loginKey + @('--login-item', 'on')) -Quiet) -eq 0) {
        Say "Context Guard opens at sign-in (change it in its Settings)"
    } else {
        $script:output | ForEach-Object { [Console]::Error.WriteLine("warning: $_") }
        [Console]::Error.WriteLine("warning: couldn't set Context Guard to open at sign-in; turn it on in its Settings")
    }
    Start-App
}

# Removes the app, its shortcut, its Apps entry and open at sign-in. A copy of this script run from
# the app's folder (the Apps entry's Uninstall) steps out of it first, so the folder can go.
function Uninstall-App {
    Stop-App
    if (Test-Path -LiteralPath $appExe) {
        if ((Invoke-Program $appExe ($loginKey + @('--login-item', 'off')) -Quiet) -ne 0) {
            $script:output | ForEach-Object { [Console]::Error.WriteLine("warning: $_") }
        }
    }
    if (Test-Path -LiteralPath $shortcut) { Remove-Item -LiteralPath $shortcut -Force }
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($appsKey, $false)
    if (Test-Path -LiteralPath $appDir) {
        $outside = [IO.Path]::GetTempPath()
        Set-Location -LiteralPath $outside
        [Environment]::CurrentDirectory = $outside
        $old = '.Context Guard.{0}.old' -f [Guid]::NewGuid().ToString('N').Substring(0, 8)
        try { Rename-Item -LiteralPath $appDir -NewName $old }
        catch { Fail "couldn't remove $appDir (is Context Guard still running from it?): $($_.Exception.Message)" }
    }
    Remove-AppSetAside
    Say "removed $appDir, its Start menu shortcut and its Apps entry"
}

function Uninstall-All {
    Uninstall-Link
    Uninstall-App
    Remove-Hooks
    Uninstall-Mod
    if (Test-Path -LiteralPath $hookDir) {
        foreach ($file in @(Get-ChildItem -LiteralPath $hookDir -File | Where-Object { $_.Name -eq 'context-guard.exe' -or $_.Name -eq 'context-guard-link.exe' -or $_.Extension -eq '.dll' })) {
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
    if (-not $NoCodex -and -not (Test-Path -LiteralPath $fromLink)) { Fail "no context-guard-link.exe next to context-guard.exe; run build.ps1 again, or install with -NoCodex" }
    if (-not (Test-Path -LiteralPath $fromAppExe)) { Fail "no app\ContextGuard.exe next to context-guard.exe; run build.ps1 again" }
    # The app first lets go of the program (it runs `context-guard ui`); it's started again at the end.
    Stop-App
    # The program first, so the hooks never point at a missing file.
    Install-Program
    # Backs up settings.json, then removes and adds the hooks, so running this again leaves exactly
    # one copy of each. Other hooks and settings stay as they are.
    if ((Invoke-Program $hookExe @('setup')) -ne 0) { exit 1 }
    Copy-Mod
    Unblock-Folder $hookDir
    Install-Mod
    if ($NoCodex) { Uninstall-Link } else { Install-Link }
    Install-AppAll
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
