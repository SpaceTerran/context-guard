# Live test harness for Codex on Windows (codex-session.sh's twin): a real interactive `codex`
# (gpt-6-luna, in a pseudo console) on your own Codex app server, guarded by a test
# `context-guard.exe codex` that keeps its files in a scratch home and looks only at sessions in the
# test's folder (--only-cwd). Your other Codex sessions, your Codex settings and Context Guard's real
# files are left alone.
#
# Run it on the test PC as the user who is signed in there (over SSH is fine). Codex and the test
# link run in that user's desktop session, not elevated, started by one-shot scheduled tasks: Codex
# won't start its app server from an elevated or remote shell, and a stop request reaches only a
# link in the same session. The console is session.ps1's (start, send, type, key and screen go
# through it).
#
#   codex-session.ps1 start <name> -Program <context-guard.exe> [-AskPercent 10] [-LaterPercent 15]
#       [-AutoYes 60] [-Message real|<text>] [-Prompt <text>] [-AutoCompact <tokens>]
#       starts codex and the test link in %USERPROFILE%\cg-live\<name>. The folder gets Codex
#       settings of its own (<folder>\.codex\config.toml, read only for sessions there): gpt-6-luna,
#       so /new keeps it; no update check; no Codex hooks; -AutoCompact as
#       model_auto_compact_token_limit. -Message real keeps Context Guard's own message (default: a
#       request to reply with set words; the folder isn't a repo, so don't ask it to commit).
#   codex-session.ps1 send <name> <text>          type a prompt and press Enter
#   codex-session.ps1 type <name> <text>          type without pressing Enter
#   codex-session.ps1 key <name> enter|esc|ctrl-c|ctrl-u|backspace|up|down|tab
#   codex-session.ps1 screen <name>               print what the console shows
#   codex-session.ps1 state <name>                context-guard status for the scratch home
#   codex-session.ps1 answer <name> yes|later|skip   answer as the popup would (yes before a
#                                                 question = Compact Now)
#   codex-session.ps1 rollout <name> [-Lines 30]  turns, messages, sizes and compactions from the
#                                                 session's rollout
#   codex-session.ps1 link <name> start|stop|kill the test link (kill = ended at once, like a crash)
#   codex-session.ps1 log <name> [-Lines 40]      the test link's log
#   codex-session.ps1 quit <name>                 close the console (the session stays loaded)
#   codex-session.ps1 resume <name>               open it again in a new console (codex resume <id>)
#   codex-session.ps1 restart-server <name>       restart Codex's app server; refused while another
#                                                 Codex session runs
#   codex-session.ps1 stop <name>                 close it, stop the link, delete the test's Codex
#                                                 sessions, stop the app server if the test started
#                                                 it and no other Codex session runs, and show what
#                                                 changed in %USERPROFILE%\.codex\config.toml
#
# It refuses to start while the installed link (or any link without --only-cwd) runs: two links
# would both act on the test session. If Codex offers an update anyway, the console passes on only
# esc (skip) and quit: never update from a test.
#
# Windows PowerShell 5.1 runs it. ASCII only: 5.1 reads a file without a BOM as ANSI.
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Command,
    [Parameter(Mandatory = $true, Position = 1)][string]$Name,
    [Parameter(Position = 2)][string]$Text,
    [string]$Program,
    [int]$AskPercent = 10,
    [int]$LaterPercent = 15,
    [int]$AutoYes = 60,
    [string]$Message = 'LIVE TEST: reply with exactly the words SAVE MESSAGE RECEIVED and nothing else.',
    [string]$Prompt,
    [int]$AutoCompact = 0,
    [int]$Lines = 0
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$dir = Join-Path $env:USERPROFILE "cg-live\$Name"
$home2 = Join-Path $dir 'home'
$session = Join-Path $PSScriptRoot 'session.ps1'
if ($env:CODEX_HOME) { $codexHome = $env:CODEX_HOME } else { $codexHome = Join-Path $env:USERPROFILE '.codex' }
$utf8 = New-Object System.Text.UTF8Encoding $false

function Write-Utf8([string]$Path, [string]$Content) { [IO.File]::WriteAllText($Path, $Content, $utf8) }
function Read-Text([string]$Path) { if (Test-Path -LiteralPath $Path) { return [IO.File]::ReadAllText($Path).Trim() } return '' }
# The lines of a file another program has open for writing (a rollout Codex is writing to).
function Read-SharedLines([string]$Path) {
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
    $reader = New-Object IO.StreamReader($stream, $utf8)
    try { while ($null -ne ($line = $reader.ReadLine())) { $line } } finally { $reader.Close() }
}

# One argument as CreateProcess's command line parser reads it back.
function ConvertTo-Arg([string]$Arg) {
    if ($Arg -and $Arg -notmatch '[\s"]') { return $Arg }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($c in $Arg.ToCharArray()) {
        if ($c -eq '\') { $slashes++; continue }
        if ($c -eq '"') { [void]$sb.Append('\' * (2 * $slashes + 1)); [void]$sb.Append('"'); $slashes = 0; continue }
        if ($slashes) { [void]$sb.Append('\' * $slashes); $slashes = 0 }
        [void]$sb.Append($c)
    }
    [void]$sb.Append('\' * (2 * $slashes))
    [void]$sb.Append('"')
    return $sb.ToString()
}

# The program under test, as start was given it.
function Get-Program {
    $p = Read-Text (Join-Path $dir 'program.txt')
    if (-not $p) { throw "$Name wasn't started here" }
    return $p
}

# How to run codex: its own exe, or the npm package's script under node (what `codex` runs).
function Get-CodexArgv {
    $exe = Get-Command codex.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exe) { return @($exe.Source) }
    $cmd = Get-Command codex.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) {
        $js = Join-Path (Split-Path $cmd.Source) 'node_modules\@openai\codex\bin\codex.js'
        $node = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($node -and (Test-Path -LiteralPath $js)) { return @($node.Source, $js) }
    }
    throw "can't find codex"
}

function Get-Processes { return @(Get-CimInstance Win32_Process) }

function Test-Running([string]$PidFile) {
    $id = Read-Text $PidFile
    return [bool]($id -and (Get-Process -Id ([int]$id) -ErrorAction SilentlyContinue))
}

# Whether Codex's shared app server is running.
function Test-CodexServer {
    return [bool](Get-Processes | Where-Object { $_.Name -eq 'codex.exe' -and [string]$_.CommandLine -match '--managed-daemon' })
}

# Codex sessions running in terminals other than this test's: codex.exe processes that aren't a
# server (the shared one, the desktop app's) and aren't under this test's console host.
function Get-OtherCodexSessions {
    $all = Get-Processes
    $byId = @{}
    foreach ($p in $all) { $byId[[int]$p.ProcessId] = $p }
    $hostId = [int](Read-Text (Join-Path $dir 'host.pid'))
    foreach ($p in $all) {
        if ($p.Name -ne 'codex.exe' -or [string]$p.CommandLine -match '\s(app-server|exec-server)(\s|$)') { continue }
        $up = $p
        $ours = $false
        for ($i = 0; $up -and $i -lt 20; $i++) {
            if ($hostId -and [int]$up.ProcessId -eq $hostId) { $ours = $true; break }
            $up = $byId[[int]$up.ParentProcessId]
        }
        if (-not $ours) { '{0} {1}' -f $p.ProcessId, $p.CommandLine }
    }
}

# Runs one of this script's in-session commands in the signed-in user's desktop session, not
# elevated, from a one-shot task under conhost --headless (a console with no window). -Wait waits
# for it to end and removes the task.
function Invoke-InSession([string]$Inner, [switch]$Wait, [int]$Minutes = 10) {
    $task = "cg-live-$Name-$Inner"
    $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\conhost.exe') `
        -Argument ('--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" {1} "{2}"' -f $PSCommandPath, $Inner, $Name)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes $Minutes) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $task
    if (-not $Wait) { return }
    do {
        Start-Sleep -Milliseconds 500
        $info = Get-ScheduledTaskInfo -TaskName $task
    } while ((Get-ScheduledTask -TaskName $task).State -eq 'Running' -or $info.LastTaskResult -in 267009, 267011)
    Unregister-ScheduledTask -TaskName $task -Confirm:$false
}

# codex commands for the in-session runner, one per line, arguments split by tabs; returns what
# they printed.
function Invoke-Codex([string[][]]$Commands) {
    Write-Utf8 (Join-Path $dir 'codex-run.txt') (($Commands | ForEach-Object { $_ -join "`t" }) -join "`n")
    $out = Join-Path $dir 'codex-run.out'
    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out }
    Invoke-InSession 'codex-run' -Wait
    return Read-Text $out
}

function Start-Link {
    if (Test-Running (Join-Path $dir 'link.pid')) { throw 'the test link is already running' }
    Remove-Item -LiteralPath (Join-Path $dir 'link.pid') -ErrorAction SilentlyContinue
    Invoke-InSession 'link-host' -Minutes 240
    for ($i = 0; $i -lt 40 -and -not (Test-Running (Join-Path $dir 'link.pid')); $i++) { Start-Sleep -Milliseconds 250 }
    if (-not (Test-Running (Join-Path $dir 'link.pid'))) { throw "the test link didn't start; see $dir\link.out" }
}

function Stop-Link {
    $pidFile = Join-Path $dir 'link.pid'
    if (-not (Test-Running $pidFile)) { return }
    Invoke-InSession 'link-stop' -Wait
    $said = Read-Text (Join-Path $dir 'link-stop.out')
    if ($said) { Write-Host $said }
    if (Test-Running $pidFile) { Stop-Process -Id ([int](Read-Text $pidFile)) -Force; Write-Host 'the test link was still running; ended it' }
    if (Get-ScheduledTask -TaskName "cg-live-$Name-link-host" -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName "cg-live-$Name-link-host" -Confirm:$false
    }
}

# The test's rollouts, newest first: Codex sessions created since start in the test's folder.
function Get-Rollouts {
    $started = Join-Path $dir 'started'
    if (-not (Test-Path -LiteralPath $started)) { return @() }
    $since = (Get-Item -LiteralPath $started).LastWriteTimeUtc
    $root = Join-Path $codexHome 'sessions'
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    $found = foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File -Filter 'rollout-*.jsonl') {
        if ($f.LastWriteTimeUtc -le $since) { continue }
        $first = Get-Content -LiteralPath $f.FullName -TotalCount 1 -Encoding UTF8
        try { $cwd = ($first | ConvertFrom-Json).payload.cwd } catch { continue }
        if ($cwd -and $cwd.TrimEnd('\') -eq $dir) { $f }
    }
    return @($found | Sort-Object LastWriteTimeUtc -Descending)
}

function Get-SessionId([IO.FileInfo]$Rollout) {
    if ($Rollout.BaseName -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$') { return $Matches[1] }
    throw "no session id in $($Rollout.Name)"
}

function Get-TestSessionId {
    $r = @(Get-Rollouts)
    if (-not $r.Count) { throw "no Codex session in $dir yet" }
    return Get-SessionId $r[0]
}

# Opens the console on codex with these arguments.
function Open-Codex([string[]]$Arguments) {
    $argv = @(Get-CodexArgv) + $Arguments
    $launch = [ordered]@{
        commandLine = (($argv | ForEach-Object { ConvertTo-Arg $_ }) -join ' ')
        cwd = $dir
        env = [ordered]@{}
    }
    Write-Utf8 (Join-Path $dir 'launch.json') ($launch | ConvertTo-Json -Depth 5)
    & $session open $Name
}

function Start-Test {
    if (-not $Program) { throw 'start needs -Program <context-guard.exe>' }
    $exe = (Resolve-Path -LiteralPath $Program).Path
    $procs = Get-Processes
    if ($procs | Where-Object { $_.Name -eq 'context-guard-link.exe' }) {
        throw 'the installed Codex link (context-guard-link.exe) is running; stop it first: context-guard codex --stop'
    }
    $unscoped = @($procs | Where-Object { $_.Name -eq 'context-guard.exe' -and [string]$_.CommandLine -match '\scodex(\s|$)' -and [string]$_.CommandLine -notmatch '--only-cwd|--stop' })
    if ($unscoped.Count) { throw "a Context Guard link without --only-cwd is running (pid $($unscoped[0].ProcessId)); stop it first" }
    if ((Test-Path -LiteralPath $dir) -and (Test-Running (Join-Path $dir 'link.pid'))) { throw "$Name is running; stop it first" }

    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Path $home2, (Join-Path $dir '.codex') | Out-Null
    Write-Utf8 (Join-Path $dir 'program.txt') $exe
    # Codex settings for this folder only; your own config files are never touched. No update
    # check: its prompt's default is "Update now", and a test's Enter would pick it.
    $toml = @('model = "gpt-6-luna"', 'check_for_update_on_startup = false')
    if ($AutoCompact) { $toml += "model_auto_compact_token_limit = $AutoCompact" }
    $toml += '', '[features]', 'hooks = false'
    Write-Utf8 (Join-Path $dir '.codex\config.toml') (($toml -join "`n") + "`n")
    # Whether Codex's app server was running before, so stop can leave it as it was.
    Write-Utf8 (Join-Path $dir 'server-was-running') $(if (Test-CodexServer) { 'yes' } else { 'no' })
    # A copy of your Codex settings, so stop can show what the test changed in them.
    $config = Join-Path $codexHome 'config.toml'
    if (Test-Path -LiteralPath $config) { Copy-Item -LiteralPath $config -Destination (Join-Path $dir 'config.before.toml') }
    # Filler files: reading one adds roughly 10k tokens of context.
    $words = 'alpha', 'bravo', 'charlie', 'delta', 'echo', 'foxtrot', 'golf', 'hotel', 'india', 'juliet'
    foreach ($i in 1..6) {
        $random = New-Object System.Random $i
        $sb = New-Object System.Text.StringBuilder
        for ($l = 0; $l -lt 600; $l++) {
            for ($w = 0; $w -lt 16; $w++) { if ($w) { [void]$sb.Append(' ') }; [void]$sb.Append($words[$random.Next(10)]) }
            [void]$sb.Append("`n")
        }
        Write-Utf8 (Join-Path $dir "filler-$i.txt") $sb.ToString()
    }
    # On since a minute ago, so a question's countdown starts when it's asked.
    $cg = [ordered]@{
        schemaVersion = 1; enabled = $true
        enabledAt = [DateTime]::UtcNow.AddMinutes(-1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        codexAskPercent = $AskPercent; codexLaterPercent = $LaterPercent; autoYesSeconds = $AutoYes
    }
    if ($Message -ne 'real') { $cg.message = $Message }
    Write-Utf8 (Join-Path $home2 'config.json') ($cg | ConvertTo-Json)
    Write-Utf8 (Join-Path $dir 'started') ''
    Start-Link
    # gpt-6-luna on the command line: a current model, so Codex shows no model-migration prompt.
    $codexArgs = @('-m', 'gpt-6-luna')
    if ($Prompt) { $codexArgs += $Prompt }
    Open-Codex $codexArgs
    Write-Host "started $Name in $dir (Codex app server was running before: $(Read-Text (Join-Path $dir 'server-was-running')))"
}

function Stop-Test {
    & $session close $Name
    Stop-Link
    $deletes = @(Get-Rollouts | ForEach-Object { , @('delete', '--force', (Get-SessionId $_)) })
    if ($deletes.Count) { Write-Host (Invoke-Codex $deletes) }
    if ((Read-Text (Join-Path $dir 'server-was-running')) -eq 'no' -and (Test-CodexServer)) {
        $others = @(Get-OtherCodexSessions)
        if ($others.Count) {
            Write-Host "left Codex's app server running: other Codex sessions run:"
            $others | ForEach-Object { Write-Host "  $_" }
        } else {
            $null = Invoke-Codex @(, @('app-server', 'daemon', 'stop'))
            Write-Host "stopped Codex's app server (it wasn't running before): $(if (Test-CodexServer) { 'still running' } else { 'done' })"
            # Its pid watcher can outlive it (seen on the Mac).
            Start-Sleep -Seconds 2
            foreach ($p in @(Get-Processes | Where-Object { $_.Name -eq 'codex.exe' -and [string]$_.CommandLine -match 'daemon\s+pid-update-loop' })) {
                Stop-Process -Id $p.ProcessId -Force
                Write-Host "ended Codex's leftover pid-update-loop (pid $($p.ProcessId))"
            }
        }
    }
    $before = Join-Path $dir 'config.before.toml'
    $now = Join-Path $codexHome 'config.toml'
    if ((Test-Path -LiteralPath $before) -and [IO.File]::ReadAllText($before) -cne [IO.File]::ReadAllText($now)) {
        [Console]::Error.WriteLine("note: $now changed during the test (Codex writes first-run flags there):")
        Compare-Object (Get-Content -LiteralPath $before) (Get-Content -LiteralPath $now) | ForEach-Object {
            [Console]::Error.WriteLine(('{0} {1}' -f $(if ($_.SideIndicator -eq '<=') { '-' } else { '+' }), $_.InputObject))
        }
    }
}

# The test's newest rollout as lines: turns, messages, sizes and compactions.
function Show-Rollout {
    $r = @(Get-Rollouts)
    if (-not $r.Count) { throw "no Codex session in $dir yet" }
    function Clip([string]$s) { if ($s.Length -gt 110) { return $s.Substring(0, 110) + '...' } return $s }
    function Texts($item) { return (@($item.content | Where-Object { $_ -and $_.PSObject.Properties['text'] } | ForEach-Object { $_.text }) -join ' ') }
    $out = foreach ($line in (Read-SharedLines $r[0].FullName)) {
        $head = $line.Substring(0, [Math]::Min(200, $line.Length))
        if ($head -notmatch '"timestamp":"[^"]*T(\d\d:\d\d:\d\d)') { continue }
        $t = $Matches[1]
        # A compaction's line holds the whole replacement history; its type is all that's needed.
        if ($head -match '"type":"compacted"') { "$t COMPACTED"; continue }
        if ($head -notmatch '"type":"event_msg"') { continue }
        $p = ($line | ConvertFrom-Json).payload
        switch ($p.type) {
            'task_started' { "$t turn started" }
            'task_complete' { "$t turn complete" }
            'turn_aborted' { "$t turn aborted ($(if ($p.PSObject.Properties['reason']) { $p.reason }))" }
            'token_count' { if ($p.PSObject.Properties['info'] -and $p.info) { "$t size $($p.info.last_token_usage.total_tokens) of $($p.info.model_context_window)" } }
            'item_completed' {
                $item = $p.item
                if ($item.type -eq 'UserMessage') {
                    $client = ''
                    if ($item.PSObject.Properties['client_id'] -and $item.client_id) { $client = "  (client id $($item.client_id.Substring(0, [Math]::Min(8, $item.client_id.Length)))...)" }
                    "$t you: $(Clip (Texts $item))$client"
                } elseif ($item.type -eq 'AgentMessage') {
                    "$t codex: $(Clip (Texts $item))"
                }
            }
        }
    }
    $n = $(if ($Lines) { $Lines } else { 30 })
    @($out) | Select-Object -Last $n
}

# In-session commands (Invoke-InSession runs them in the user's desktop session).
function Start-LinkHost {
    $exe = Get-Program
    $env:CONTEXT_GUARD_HOME = $home2
    $p = Start-Process -FilePath $exe -ArgumentList ('codex --only-cwd {0} --verbose' -f (ConvertTo-Arg $dir)) `
        -NoNewWindow -PassThru -RedirectStandardError (Join-Path $dir 'link.out')
    Write-Utf8 (Join-Path $dir 'link.pid') "$($p.Id)"
    $p.WaitForExit()
}

function Stop-LinkInSession {
    $env:CONTEXT_GUARD_HOME = $home2
    $exe = Get-Program
    $ErrorActionPreference = 'Continue'
    $said = @(& $exe codex --stop 2>&1 | ForEach-Object { "$_" })
    Write-Utf8 (Join-Path $dir 'link-stop.out') ($said -join "`n")
}

function Invoke-CodexInSession {
    $argv = @(Get-CodexArgv)
    $ErrorActionPreference = 'Continue'
    $out = foreach ($line in [IO.File]::ReadAllLines((Join-Path $dir 'codex-run.txt'), $utf8)) {
        if (-not $line) { continue }
        $a = $line -split "`t"
        "> codex $($a -join ' ')"
        $rest = @($argv | Select-Object -Skip 1) + $a
        & $argv[0] @rest 2>&1 | ForEach-Object { "$_" }
        "exit $LASTEXITCODE"
    }
    Write-Utf8 (Join-Path $dir 'codex-run.out') (@($out) -join "`n")
}

switch ($Command) {
    'start' { Start-Test }
    { $_ -in 'send', 'type', 'key' } { & $session $Command $Name $Text }
    'screen' { & $session screen $Name }
    'state' { $env:CONTEXT_GUARD_HOME = $home2; & (Get-Program) status }
    'answer' {
        if ($Text -notin 'yes', 'later', 'skip') { throw 'answer <name> yes|later|skip' }
        $env:CONTEXT_GUARD_HOME = $home2
        & (Get-Program) answer (Get-TestSessionId) $Text
    }
    'rollout' { Show-Rollout }
    'link' {
        switch ($Text) {
            'start' { Start-Link }
            'stop' { Stop-Link }
            'kill' { if (Test-Running (Join-Path $dir 'link.pid')) { Stop-Process -Id ([int](Read-Text (Join-Path $dir 'link.pid'))) -Force } }
            default { throw 'link <name> start|stop|kill' }
        }
    }
    'log' { Get-Content -LiteralPath (Join-Path $home2 'codex-link.log') -Tail $(if ($Lines) { $Lines } else { 40 }) }
    'quit' { & $session close $Name }
    'resume' { Open-Codex @('resume', (Get-TestSessionId)) }
    'restart-server' {
        $others = @(Get-OtherCodexSessions)
        if ($others.Count) { throw "not restarting: other Codex sessions run:`n$($others -join "`n")" }
        Write-Host (Invoke-Codex @(, @('app-server', 'daemon', 'restart')))
    }
    'stop' { Stop-Test }
    'link-host' { Start-LinkHost }
    'link-stop' { Stop-LinkInSession }
    'codex-run' { Invoke-CodexInSession }
    default { throw "unknown command $Command" }
}
