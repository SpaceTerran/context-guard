# Builds Context Guard for Windows into dist\context-guard\: the hook program (context-guard.exe),
# the Codex link the background task runs (context-guard-link.exe), the Swift runtime DLLs they run
# on, the mod, and install.ps1, which installs them from there.
# Needs Swift and Visual Studio's C++ build tools (their dumpbin finds the DLLs).
#
#   powershell -ExecutionPolicy Bypass -File build.ps1
#
# Windows PowerShell 5.1 and PowerShell 7 both run it. ASCII only: 5.1 reads a file without a BOM
# as ANSI.
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$pkg = $PSScriptRoot
$out = Join-Path $pkg 'dist\context-guard'

# Runs a program and returns its output lines; stops the build when it fails. Windows PowerShell
# turns a program's stderr lines into errors, so they're collected as text.
function Invoke-Program {
    param([string]$Program, [string[]]$Arguments, [switch]$Show)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& $Program @Arguments 2>&1 | ForEach-Object {
            $line = "$_"
            if ($Show) { Write-Host $line }
            $line
        })
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
    }
    if ($code -ne 0) {
        if (-not $Show) { $lines | ForEach-Object { Write-Host $_ } }
        throw "$Program $($Arguments -join ' ') failed (exit $code)"
    }
    return $lines
}

$programs = @('context-guard.exe', 'context-guard-link.exe')
foreach ($product in $programs) {
    Invoke-Program 'swift' @('build', '-c', 'release', '--product', [IO.Path]::GetFileNameWithoutExtension($product), '--package-path', $pkg) -Show | Out-Null
}
$bin = (Invoke-Program 'swift' @('build', '-c', 'release', '--show-bin-path', '--package-path', $pkg) | Select-Object -Last 1).Trim()

# The Swift runtime: the folder on PATH that has swiftCore.dll.
$runtime = $null
foreach ($dir in ($env:Path -split ';')) {
    if (-not $dir) { continue }
    try { if (Test-Path -LiteralPath (Join-Path $dir 'swiftCore.dll')) { $runtime = $dir; break } } catch { }
}
if (-not $runtime) { throw "can't find the Swift runtime: no folder on PATH has swiftCore.dll" }

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$dumpbin = Invoke-Program $vswhere @('-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
    '-find', 'VC\Tools\MSVC\**\bin\Hostx64\x64\dumpbin.exe') | Select-Object -Last 1
if (-not $dumpbin) { throw "can't find dumpbin: install Visual Studio's C++ build tools" }

# Every DLL the programs load, and theirs in turn: those in the Swift runtime folder ship with it
# (the C++ runtime among them, so no redistributable is needed); the rest must be part of Windows.
$system32 = Join-Path $env:SystemRoot 'System32'
$ship = New-Object 'System.Collections.Generic.SortedDictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
$seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$queue = New-Object 'System.Collections.Generic.Queue[string]'
foreach ($program in $programs) { $queue.Enqueue((Join-Path $bin $program)) }
while ($queue.Count -gt 0) {
    $file = $queue.Dequeue()
    foreach ($line in (Invoke-Program $dumpbin @('/nologo', '/dependents', $file))) {
        if ($line -notmatch '^\s+(\S+\.dll)\s*$') { continue }
        $dll = $Matches[1]
        if (-not $seen.Add($dll)) { continue }
        $path = Join-Path $runtime $dll
        if (Test-Path -LiteralPath $path) {
            $ship[$dll] = $path
            $queue.Enqueue($path)
        } elseif (-not ($dll -like 'api-ms-win-*' -or $dll -like 'ext-ms-*' -or (Test-Path -LiteralPath (Join-Path $system32 $dll)))) {
            throw "$([IO.Path]::GetFileName($file)) needs $dll, which is neither in the Swift runtime ($runtime) nor part of Windows"
        }
    }
}

if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
New-Item -ItemType Directory -Path $out | Out-Null
foreach ($program in $programs) { Copy-Item -LiteralPath (Join-Path $bin $program) -Destination $out }
foreach ($path in $ship.Values) { Copy-Item -LiteralPath $path -Destination $out }
# The mod's manifests and hooks, not its tests.
$plugin = Join-Path $out 'mod\.claude-plugin'
New-Item -ItemType Directory -Path $plugin | Out-Null
Copy-Item -LiteralPath (Join-Path $pkg 'mod\.claude-plugin\plugin.json'), (Join-Path $pkg 'mod\.claude-plugin\marketplace.json') -Destination $plugin
Copy-Item -LiteralPath (Join-Path $pkg 'mod\hooks') -Destination (Join-Path $out 'mod\hooks') -Recurse
Copy-Item -LiteralPath (Join-Path $pkg 'install.ps1') -Destination $out

# Both run from the folder alone, with nothing on PATH but Windows. The link has no console, so it
# is given an argument it refuses: it says so in its log (in a scratch folder) and exits 1, which it
# can only do once its DLLs have loaded.
$savedPath = $env:Path
$savedHome = $env:CONTEXT_GUARD_HOME
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('context-guard-build-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$env:Path = "$system32;$env:SystemRoot"
$env:CONTEXT_GUARD_HOME = $scratch
try {
    Invoke-Program (Join-Path $out 'context-guard.exe') @('--help') | Out-Null
    $link = Start-Process -FilePath (Join-Path $out 'context-guard-link.exe') -ArgumentList '--env', 'BUILD_CHECK=1' -Wait -PassThru
    $log = Join-Path $scratch 'codex-link.log'
    $said = if (Test-Path -LiteralPath $log) { (Get-Content -LiteralPath $log) -join ' ' } else { '' }
    if ($link.ExitCode -ne 1 -or $said -notlike '*not started: --env BUILD_CHECK*') {
        throw "context-guard-link.exe didn't run from $out (exit $($link.ExitCode); log: $said)"
    }
} finally {
    $env:Path = $savedPath
    $env:CONTEXT_GUARD_HOME = $savedHome
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}

$mb = [math]::Round(((Get-ChildItem -LiteralPath $out -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 1)
Write-Host "built $out (context-guard.exe, context-guard-link.exe, $($ship.Count) DLLs, the mod; $mb MB)"
