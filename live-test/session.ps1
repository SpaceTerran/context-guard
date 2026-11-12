# Live test harness for Windows (session.sh's twin): a real interactive Claude Code session (Haiku,
# in a pseudo console) whose Context Guard hooks run the program under test with a scratch home, so
# nothing touches real sessions or settings.
#
# Run it on the test PC as the user who is signed in there (over SSH is fine). The session itself
# runs in that user's desktop session, not elevated, started by a one-shot scheduled task: that is
# where a person's Claude Code runs, and where its sign-in can be read.
#
#   session.ps1 start <name> -Program <context-guard.exe> [-AskK 60] [-LaterK 75] [-PluginDir <mod>]
#       [-Model haiku] [-Message real|<text>] [-Poll 0.5] [-AutoYes 60] [-Prompt <text>]
#       starts a session in %USERPROFILE%\cg-live\<name>. -Program also goes in the session's
#       CONTEXT_GUARD_PROGRAM, for the mod (-PluginDir, the Context Guard mod, say).
#       -Message real keeps Context Guard's own message (default: a test reply request).
#   session.ps1 send <name> <text>              type a prompt and press Enter
#   session.ps1 type <name> <text>              type without Enter
#   session.ps1 key <name> enter|esc|ctrl-c|ctrl-u|backspace|up|down|tab
#   session.ps1 screen <name>                   print what the console shows
#   session.ps1 state <name>                    context-guard status for that home
#   session.ps1 answer <name> yes|later|skip    answer as the popup would
#   session.ps1 stop <name>
#   session.ps1 open <name>     start the console host for a folder another script set up (its
#                               launch.json: commandLine, cwd, env), as codex-session.ps1 does
#   session.ps1 close <name>    end the console host and its task, and the program in it
#
# Keeps everything in %USERPROFILE%\cg-live\<name>: home\ (CONTEXT_GUARD_HOME), settings.json (the
# hooks, given with --settings), screen.txt, raw.log (everything the session wrote), host.log.
# Claude Code may first ask whether to trust the folder: read the screen and answer with key.
#
# Windows PowerShell 5.1 runs it. ASCII only: 5.1 reads a file without a BOM as ANSI.
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Command,
    [Parameter(Mandatory = $true, Position = 1)][string]$Name,
    [Parameter(Position = 2)][string]$Text,
    [string]$Program,
    [int]$AskK = 60,
    [int]$LaterK = 75,
    [string]$PluginDir,
    [string]$Model = 'haiku',
    [string]$Message = 'LIVE TEST: reply with exactly the words SAVE MESSAGE RECEIVED and nothing else.',
    [double]$Poll = 0.5,
    [int]$AutoYes = 60,
    [string]$Prompt
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$dir = Join-Path $env:USERPROFILE "cg-live\$Name"
$home2 = Join-Path $dir 'home'
$task = "cg-live-$Name"
$utf8 = New-Object System.Text.UTF8Encoding $false

function Write-Utf8([string]$Path, [string]$Content) { [IO.File]::WriteAllText($Path, $Content, $utf8) }

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

# Runs a program, its stderr lines counted as output (Windows PowerShell would make them errors).
function Invoke-Native([string]$Program, [string[]]$Arguments) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $lines = @(& $Program @Arguments 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE } finally { $ErrorActionPreference = $saved }
    if ($code -ne 0) { throw "$Program $($Arguments -join ' ') failed (exit $code): $($lines -join ' / ')" }
    return $lines
}

function Get-HostPid {
    $file = Join-Path $dir 'host.pid'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $id = [int]([IO.File]::ReadAllText($file).Trim())
    if (Get-Process -Id $id -ErrorAction SilentlyContinue) { return $id }
    return $null
}

# A command for the host, which runs them in the order they were written.
function Send-Control([string]$Line) {
    if (-not (Get-HostPid)) { throw "$Name isn't running" }
    $control = Join-Path $dir 'control'
    $file = Join-Path $control ('{0:D20}-{1}.cmd' -f [DateTime]::UtcNow.Ticks, [Guid]::NewGuid().ToString('N').Substring(0, 6))
    Write-Utf8 "$file.tmp" $Line
    Move-Item -LiteralPath "$file.tmp" -Destination $file
}

function Get-Launch { return [IO.File]::ReadAllText((Join-Path $dir 'launch.json')) | ConvertFrom-Json }

function Start-Session {
    if (-not $Program) { throw 'start needs -Program <context-guard.exe>' }
    $Program = (Resolve-Path -LiteralPath $Program).Path
    if ($PluginDir) { $PluginDir = (Resolve-Path -LiteralPath $PluginDir).Path }
    if (Get-HostPid) { throw "$Name is running; stop it first" }
    $claude = (Get-Command claude -CommandType Application).Source | Select-Object -First 1
    Assert-SignedIn

    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Path $home2, (Join-Path $dir 'control') | Out-Null
    # A throwaway repo with no remote, so a real "commit and push" request has nothing real to touch.
    $null = Invoke-Native 'git' @('-C', $dir, 'init', '-q')
    $null = Invoke-Native 'git' @('-C', $dir, '-c', 'user.name=test', '-c', 'user.email=test@localhost', 'commit', '-q', '--allow-empty', '-m', 'test repo')
    # Filler files: each Read adds roughly 10k tokens of context.
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
    $config = [ordered]@{
        schemaVersion = 1; enabled = $true
        enabledAt = [DateTime]::UtcNow.AddMinutes(-1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        askAt = $AskK * 1000; laterAt = $LaterK * 1000; autoYesSeconds = $AutoYes
    }
    if ($Message -ne 'real') { $config.message = $Message }
    Write-Utf8 (Join-Path $home2 'config.json') ($config | ConvertTo-Json)
    # The hooks as `context-guard setup` writes them on Windows: the program itself, no shell.
    function Hook([hashtable]$More) {
        $h = [ordered]@{ type = 'command'; command = $Program; args = @('hook'); timeout = 5 }
        foreach ($k in $More.Keys) { $h[$k] = $More[$k] }
        return @{ hooks = @($h) }
    }
    $hooks = [ordered]@{
        PostToolBatch = @(Hook @{})
        Stop = @(Hook @{ timeout = 43500; asyncRewake = $true; rewakeSummary = 'Context Guard: save before compacting'; rewakeMessage = 'Stop hook message:' })
        StopFailure = @(Hook @{})
        SessionStart = @(Hook @{})
        SessionEnd = @(Hook @{})
    }
    Write-Utf8 (Join-Path $dir 'settings.json') (@{ hooks = $hooks } | ConvertTo-Json -Depth 10)

    $argv = @($claude)
    if ($Prompt) { $argv += $Prompt }
    $argv += '--model', $Model, '--permission-mode', 'default', '--setting-sources', 'project,local', '--settings', (Join-Path $dir 'settings.json')
    if ($PluginDir) { $argv += '--plugin-dir', $PluginDir }
    $argv += '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}',
        '--allowedTools', 'Read', 'Bash(echo *)', 'Bash(sleep *)', 'Bash(git status*)', 'Bash(git log*)',
        '--disallowedTools', 'Bash(git commit*)', 'Bash(git push*)', 'Write', 'Edit'
    $launch = [ordered]@{
        commandLine = (($argv | ForEach-Object { ConvertTo-Arg $_ }) -join ' ')
        cwd = $dir
        env = [ordered]@{ CONTEXT_GUARD_HOME = $home2; CONTEXT_GUARD_PROGRAM = $Program; CONTEXT_GUARD_WAITER_POLL = "$Poll" }
    }
    Write-Utf8 (Join-Path $dir 'launch.json') ($launch | ConvertTo-Json -Depth 5)
    Open-Session
}

function Assert-SignedIn {
    $saved = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $signedIn = @(quser 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match "^\W?$([regex]::Escape($env:USERNAME))\s" })
    $ErrorActionPreference = $saved
    if (-not $signedIn) { throw "$env:USERNAME isn't signed in to a desktop session here" }
}

# Starts the host for $dir (its launch.json and control folder in place).
function Open-Session {
    if (Get-HostPid) { throw "$Name is running; stop it first" }
    Assert-SignedIn
    foreach ($f in 'screen.txt', 'host.pid') { $p = Join-Path $dir $f; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p } }
    New-Item -ItemType Directory -Path (Join-Path $dir 'control') -Force | Out-Null
    # The host runs in the signed-in user's desktop session, not elevated. conhost --headless gives
    # it a console without a window (any other way, Windows Terminal may open one).
    $script = $PSCommandPath
    $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\conhost.exe') `
        -Argument ('--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" host "{1}"' -f $script, $Name)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 4) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $task
    for ($i = 0; $i -lt 60 -and -not (Test-Path -LiteralPath (Join-Path $dir 'screen.txt')); $i++) { Start-Sleep -Milliseconds 500 }
    if (-not (Get-HostPid)) {
        $log = Join-Path $dir 'host.log'
        if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log | Write-Host }
        throw "$Name didn't start"
    }
    Write-Host "started $Name in $dir"
}

# Ends the host (closing its console ends the program in it) and removes its task.
function Close-Session {
    $id = Get-HostPid
    if ($id) {
        Send-Control 'quit'
        for ($i = 0; $i -lt 40 -and (Get-Process -Id $id -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 250 }
        if (Get-Process -Id $id -ErrorAction SilentlyContinue) { Stop-Process -Id $id -Force }
    }
    if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $task -Confirm:$false }
}

function Stop-Session {
    Close-Session
    $settings = Join-Path $dir 'settings.json'
    $left = @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($settings) })
    foreach ($p in $left) { Stop-Process -Id $p.ProcessId -Force }
    Write-Host "stopped $Name$(if ($left.Count) { " ($($left.Count) claude process killed)" })"
}

# The session's console: claude in a pseudo console whose input this writes and whose screen it
# copies to screen.txt. It reads the screen from the console itself (attached to it), so what's
# shown is what a terminal would show. Commands arrive as files in control\.
$hostCode = @'
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class CgLiveHost {
    [StructLayout(LayoutKind.Sequential)] struct COORD { public short X; public short Y; }
    [StructLayout(LayoutKind.Sequential)] struct SMALL_RECT { public short Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct CONSOLE_SCREEN_BUFFER_INFO {
        public COORD Size; public COORD Cursor; public short Attributes; public SMALL_RECT Window; public COORD MaxWindow;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct STARTUPINFO {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)] struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }
    [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CreatePipe(out SafeFileHandle read, out SafeFileHandle write, IntPtr sa, int size);
    [DllImport("kernel32.dll")] static extern int CreatePseudoConsole(COORD size, SafeFileHandle input, SafeFileHandle output, uint flags, out IntPtr pc);
    [DllImport("kernel32.dll")] static extern void ClosePseudoConsole(IntPtr pc);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attr, IntPtr value, IntPtr size, IntPtr prev, IntPtr ret);
    [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr h, uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AttachConsole(int pid);
    [DllImport("kernel32.dll")] static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CONSOLE_SCREEN_BUFFER_INFO info);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool ReadConsoleOutputCharacterW(IntPtr h, [Out] char[] buffer, int length, COORD at, out int read);

    static string dir;
    static void Log(string line) {
        File.AppendAllText(Path.Combine(dir, "host.log"), DateTime.UtcNow.ToString("HH:mm:ss.fff") + " " + line + "\r\n");
    }

    // What the console shows: the rows of its window, trailing spaces trimmed.
    static string ReadScreen() {
        IntPtr h = CreateFileW("CONOUT$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (h == new IntPtr(-1)) return null;
        try {
            CONSOLE_SCREEN_BUFFER_INFO info;
            if (!GetConsoleScreenBufferInfo(h, out info)) return null;
            int width = info.Window.Right - info.Window.Left + 1;
            char[] buffer = new char[width];
            StringBuilder sb = new StringBuilder();
            for (int y = info.Window.Top; y <= info.Window.Bottom; y++) {
                int read;
                COORD at = new COORD { X = info.Window.Left, Y = (short)y };
                if (!ReadConsoleOutputCharacterW(h, buffer, width, at, out read)) return null;
                sb.Append(new string(buffer, 0, read).TrimEnd()).Append('\n');
            }
            return sb.ToString();
        } finally {
            CloseHandle(h);
        }
    }

    static void SaveScreen(string text) {
        string screen = Path.Combine(dir, "screen.txt"), tmp = screen + ".tmp";
        try {
            File.WriteAllText(tmp, text, new UTF8Encoding(false));
            if (File.Exists(screen)) File.Replace(tmp, screen, null); else File.Move(tmp, screen);
        } catch (IOException) {
            // Being read just now; the next copy goes in.
        }
    }

    static readonly string[] UpdateOffer = { "Update now", "Skip until next version" };

    public static int Run(string commandLine, string cwd, string folder, short cols, short rows) {
        dir = folder;
        // The host's own console (conhost --headless) goes; it reads the session's instead.
        FreeConsole();
        SafeFileHandle inRead, inWrite, outRead, outWrite;
        if (!CreatePipe(out inRead, out inWrite, IntPtr.Zero, 0) || !CreatePipe(out outRead, out outWrite, IntPtr.Zero, 0))
            throw new Exception("CreatePipe failed: " + Marshal.GetLastWin32Error());
        IntPtr pc;
        int hr = CreatePseudoConsole(new COORD { X = cols, Y = rows }, inRead, outWrite, 0, out pc);
        if (hr != 0) throw new Exception("CreatePseudoConsole failed: 0x" + hr.ToString("X"));
        inRead.Dispose();
        outWrite.Dispose();

        IntPtr size = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
        IntPtr attributes = Marshal.AllocHGlobal(size);
        if (!InitializeProcThreadAttributeList(attributes, 1, 0, ref size)) throw new Exception("InitializeProcThreadAttributeList failed: " + Marshal.GetLastWin32Error());
        // PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
        if (!UpdateProcThreadAttribute(attributes, 0, new IntPtr(0x20016), pc, new IntPtr(IntPtr.Size), IntPtr.Zero, IntPtr.Zero))
            throw new Exception("UpdateProcThreadAttribute failed: " + Marshal.GetLastWin32Error());
        STARTUPINFOEX si = new STARTUPINFOEX();
        si.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
        // STARTF_USESTDHANDLES with none, so the session never gets the host's handles.
        si.StartupInfo.dwFlags = 0x100;
        si.lpAttributeList = attributes;
        PROCESS_INFORMATION pi;
        // EXTENDED_STARTUPINFO_PRESENT
        if (!CreateProcessW(null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false, 0x80000, IntPtr.Zero, cwd, ref si, out pi))
            throw new Exception("CreateProcess failed: " + Marshal.GetLastWin32Error());
        Log("started pid " + pi.dwProcessId + ": " + commandLine);

        FileStream output = new FileStream(outRead, FileAccess.Read);
        FileStream input = new FileStream(inWrite, FileAccess.Write);
        Thread reader = new Thread(delegate () {
            byte[] buffer = new byte[65536];
            using (FileStream raw = new FileStream(Path.Combine(dir, "raw.log"), FileMode.Append, FileAccess.Write, FileShare.ReadWrite)) {
                try {
                    int n;
                    while ((n = output.Read(buffer, 0, buffer.Length)) > 0) { raw.Write(buffer, 0, n); raw.Flush(); }
                } catch (IOException) { }
            }
        });
        reader.IsBackground = true;
        reader.Start();

        // Attached to the session's console, to read its screen. A ctrl-c typed there doesn't stop
        // the host.
        Thread.Sleep(500);
        bool attached = AttachConsole(pi.dwProcessId);
        if (!attached) Log("AttachConsole failed: " + Marshal.GetLastWin32Error());
        SetConsoleCtrlHandler(IntPtr.Zero, true);

        string control = Path.Combine(dir, "control");
        string shown = "";
        DateTime nextScreen = DateTime.MinValue;
        bool quit = false;
        while (true) {
            bool exited = WaitForSingleObject(pi.hProcess, 0) == 0;
            if (attached && DateTime.UtcNow >= nextScreen) {
                string text = ReadScreen();
                if (text != null) { shown = text; SaveScreen(text); }
                nextScreen = DateTime.UtcNow.AddMilliseconds(500);
            }
            if (exited || quit) break;
            string[] files = Directory.GetFiles(control, "*.cmd");
            Array.Sort(files, StringComparer.Ordinal);
            foreach (string file in files) {
                string line = File.ReadAllText(file, Encoding.UTF8).TrimEnd('\r', '\n');
                File.Delete(file);
                int space = line.IndexOf(' ');
                string verb = space < 0 ? line : line.Substring(0, space), rest = space < 0 ? "" : line.Substring(space + 1);
                if (verb == "quit") { quit = true; break; }
                byte[] key = Key(verb);
                if (verb != "esc" && Array.Exists(UpdateOffer, w => shown.Contains(w))) {
                    Log("refused " + verb + ": the screen offers an update; press esc to skip it");
                    continue;
                }
                if (verb == "type" || verb == "send") {
                    Write(input, Encoding.UTF8.GetBytes(rest));
                    if (verb == "send") { Thread.Sleep(300); Write(input, new byte[] { 13 }); }
                } else if (key != null) {
                    Write(input, key);
                } else {
                    Log("unknown command: " + line);
                    continue;
                }
                Log(line);
            }
            Thread.Sleep(100);
        }

        uint code = 0;
        if (WaitForSingleObject(pi.hProcess, 0) != 0) {
            Log("quit: closing the console");
            FreeConsole();
            attached = false;
            ClosePseudoConsole(pc);
            pc = IntPtr.Zero;
            if (WaitForSingleObject(pi.hProcess, 5000) != 0) { Log("still running; ending it"); TerminateProcess(pi.hProcess, 1); }
        }
        GetExitCodeProcess(pi.hProcess, out code);
        Log("session ended, exit code " + code);
        if (attached) FreeConsole();
        if (pc != IntPtr.Zero) ClosePseudoConsole(pc);
        input.Dispose();
        reader.Join(2000);
        DeleteProcThreadAttributeList(attributes);
        Marshal.FreeHGlobal(attributes);
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        return (int)code;
    }

    static void Write(FileStream input, byte[] data) { input.Write(data, 0, data.Length); input.Flush(); }

    static byte[] Key(string name) {
        switch (name) {
            case "enter": return new byte[] { 13 };
            case "esc": return new byte[] { 27 };
            case "tab": return new byte[] { 9 };
            case "ctrl-c": return new byte[] { 3 };
            case "ctrl-u": return new byte[] { 21 };
            case "backspace": return new byte[] { 127 };
            case "up": return Encoding.ASCII.GetBytes("\u001b[A");
            case "down": return Encoding.ASCII.GetBytes("\u001b[B");
            default: return null;
        }
    }
}
'@

function Start-Host {
    [IO.File]::WriteAllText((Join-Path $dir 'host.pid'), "$PID")
    try {
        Add-Type -TypeDefinition $hostCode
        $launch = Get-Launch
        foreach ($p in $launch.env.PSObject.Properties) { [Environment]::SetEnvironmentVariable($p.Name, [string]$p.Value, 'Process') }
        # Started from a Claude Code session, the session would count as its child.
        foreach ($k in 'CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_SESSION_ID', 'CLAUDE_PID') { [Environment]::SetEnvironmentVariable($k, $null, 'Process') }
        [void][CgLiveHost]::Run($launch.commandLine, $launch.cwd, $dir, 150, 45)
    } catch {
        [IO.File]::AppendAllText((Join-Path $dir 'host.log'), "host failed: $($_.Exception.Message)`r`n")
    }
}

switch ($Command) {
    'start' { Start-Session }
    'host' { Start-Host }
    'send' { Send-Control "send $Text" }
    'type' { Send-Control "type $Text" }
    'key' { Send-Control $Text }
    'screen' {
        # As UTF-8 (the console's own code page would turn its box drawing into question marks).
        try { [Console]::OutputEncoding = $utf8 } catch { }
        [IO.File]::ReadAllText((Join-Path $dir 'screen.txt'), $utf8)
    }
    'state' {
        $env:CONTEXT_GUARD_HOME = $home2
        & (Get-Launch).env.CONTEXT_GUARD_PROGRAM status
    }
    'answer' {
        # The live conversation: /clear leaves the old one's file behind, marked ended.
        $live = Get-ChildItem -LiteralPath (Join-Path $home2 'sessions') -Filter '*.json' |
            ForEach-Object { [IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json } |
            Where-Object { -not ($_.PSObject.Properties['ended'] -and $_.ended) } |
            Sort-Object { [string]$_.updatedAt } | Select-Object -Last 1
        if (-not $live) { throw 'no live session' }
        $env:CONTEXT_GUARD_HOME = $home2
        & (Get-Launch).env.CONTEXT_GUARD_PROGRAM answer $live.sessionId $Text
    }
    'stop' { Stop-Session }
    'open' { Open-Session }
    'close' { Close-Session }
    default { throw "unknown command $Command" }
}
