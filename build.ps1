# Builds Context Guard for Windows into dist\context-guard\: the hook program (context-guard.exe),
# the Codex link the background task runs (context-guard-link.exe), the Swift runtime DLLs they run
# on, the mod, the app (app\ContextGuard.exe and the Windows App SDK files it runs on), and
# install.ps1, which installs them from there. That folder is also zipped, as
# dist\context-guard-windows-x64-<build>.zip. The app's debugging symbols go to dist\symbols\.
# Needs Swift, Visual Studio's C++ build tools (their dumpbin finds the DLLs) and the .NET 10 SDK.
#
#   powershell -ExecutionPolicy Bypass -File build.ps1
#
# Windows PowerShell 5.1 and PowerShell 7 both run it. ASCII only: 5.1 reads a file without a BOM
# as ANSI.
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$pkg = $PSScriptRoot
$dist = Join-Path $pkg 'dist'
$out = Join-Path $dist 'context-guard'
$symbols = Join-Path $dist 'symbols'
$appProject = Join-Path $pkg 'windows\ContextGuard.App\ContextGuard.App.csproj'

# Build number: when it was built (UTC), as build.sh, so each install is newer than the last. A file
# version's four parts are 16-bit, so there it's split: 2026.1112.1430.0 for 20261112.1430.
$now = [DateTime]::UtcNow
$build = $now.ToString('yyyyMMdd.HHmm', [Globalization.CultureInfo]::InvariantCulture)
$fileVersion = '{0}.{1}.{2}.0' -f $now.Year, [int]$now.ToString('MMdd', [Globalization.CultureInfo]::InvariantCulture), [int]$now.ToString('HHmm', [Globalization.CultureInfo]::InvariantCulture)
$productVersion = "1.0 ($build)"

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

if (-not (Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue)) { throw "can't find dotnet: install the .NET 10 SDK" }

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

foreach ($old in @($out, $symbols) + @(Get-ChildItem -LiteralPath $dist -Filter 'context-guard-windows-*.zip' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })) {
    if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force }
}
New-Item -ItemType Directory -Path $out | Out-Null
foreach ($program in $programs) { Copy-Item -LiteralPath (Join-Path $bin $program) -Destination $out }
foreach ($path in $ship.Values) { Copy-Item -LiteralPath $path -Destination $out }
# The mod's manifests and hooks, not its tests.
$plugin = Join-Path $out 'mod\.claude-plugin'
New-Item -ItemType Directory -Path $plugin | Out-Null
Copy-Item -LiteralPath (Join-Path $pkg 'mod\.claude-plugin\plugin.json'), (Join-Path $pkg 'mod\.claude-plugin\marketplace.json') -Destination $plugin
Copy-Item -LiteralPath (Join-Path $pkg 'mod\hooks') -Destination (Join-Path $out 'mod\hooks') -Recurse
Copy-Item -LiteralPath (Join-Path $pkg 'install.ps1') -Destination $out

# The app. Built once so it can draw its icon (the Mac's, as an .ico), then published as it ships
# (Native AOT, self-contained) with that icon and this build's version in the exe. From windows\,
# where global.json is.
$appOut = Join-Path $out 'app'
$icon = Join-Path $pkg 'windows\ContextGuard.App\obj\AppIcon.ico'
Push-Location (Join-Path $pkg 'windows')
try {
    Invoke-Program 'dotnet' @('build', $appProject, '-c', 'Release', '-nologo', '-v:minimal') -Show | Out-Null
    $built = (Invoke-Program 'dotnet' @('msbuild', $appProject, '-nologo', '-p:Configuration=Release', '-getProperty:TargetDir') | Where-Object { $_.Trim() } | Select-Object -Last 1).Trim()
    Invoke-Program (Join-Path $built 'ContextGuard.exe') @('--render-icon', $icon) | Out-Null
    Invoke-Program 'dotnet' @('publish', $appProject, '-c', 'Release', '-nologo', '-v:minimal', '-o', $appOut,
        "-p:ApplicationIcon=$icon", "-p:FileVersion=$fileVersion", "-p:InformationalVersion=$productVersion") -Show | Out-Null
} finally {
    Pop-Location
}
# Its symbols stay here, for reading a crash report from this build; they don't ship.
New-Item -ItemType Directory -Path $symbols | Out-Null
Get-ChildItem -LiteralPath $appOut -Filter '*.pdb' | Move-Item -Destination $symbols

# All three run from the folder alone, with nothing on PATH but Windows. The link has no console, so
# it is given an argument it refuses: it says so in its log (in a scratch folder) and exits 1, which
# it can only do once its DLLs have loaded. The app draws its icon again, which it can only do once
# the Windows App SDK's DLLs have loaded too.
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
    $appExe = Join-Path $appOut 'ContextGuard.exe'
    $drawn = Join-Path $scratch 'AppIcon.ico'
    Invoke-Program $appExe @('--render-icon', $drawn) | Out-Null
    if (-not (Test-Path -LiteralPath $drawn)) { throw "app\ContextGuard.exe didn't run from $out" }
} finally {
    $env:Path = $savedPath
    $env:CONTEXT_GUARD_HOME = $savedHome
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}

# What Windows shows for the app: its icon and this build's version.
$version = (Get-Item -LiteralPath $appExe).VersionInfo
if ($version.ProductVersion -ne $productVersion -or $version.FileVersion -ne $fileVersion) {
    throw "app\ContextGuard.exe has version $($version.FileVersion) ($($version.ProductVersion)), not $fileVersion ($productVersion)"
}
Add-Type -Namespace ContextGuardBuild -Name Shell -MemberDefinition '[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern uint ExtractIconExW(string file, int index, IntPtr[] large, IntPtr[] small, uint count);'
if ([ContextGuardBuild.Shell]::ExtractIconExW($appExe, -1, $null, $null, 0) -lt 1) { throw "app\ContextGuard.exe has no icon" }

# The folder as one zip (context-guard\... inside), entries named with / so any unzip reads them.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zipPath = Join-Path $dist "context-guard-windows-x64-$build.zip"
$zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in @(Get-ChildItem -LiteralPath $out -Recurse -File -Force)) {
        $name = 'context-guard/' + $file.FullName.Substring($out.Length + 1).Replace('\', '/')
        $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $name, [IO.Compression.CompressionLevel]::Optimal)
    }
} finally {
    $zip.Dispose()
}

$mb = [math]::Round(((Get-ChildItem -LiteralPath $out -Recurse -File -Force | Measure-Object Length -Sum).Sum / 1MB), 1)
$zipMb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 1)
Write-Host "built $out (context-guard.exe, context-guard-link.exe, $($ship.Count) DLLs, the mod, the app; $mb MB)"
Write-Host "and $zipPath ($zipMb MB), build $build"
