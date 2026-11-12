# Waits until no Windows Installer installation is running, for up to -Minutes. Swift's installer
# stops with exit code 1618 when another installation runs at the same time, as one sometimes does on
# a new GitHub-hosted runner. Windows Installer holds the mutex Global\_MSIExecute while it installs.
#   pwsh .github/wait-for-installer.ps1 [-Minutes 10] [-Mutex <name>]
param([int]$Minutes = 10, [string]$Mutex = 'Global\_MSIExecute')
$deadline = (Get-Date).AddMinutes($Minutes)
while ($true) {
    $handle = $null
    try {
        $busy = [Threading.Mutex]::TryOpenExisting($Mutex, [ref]$handle)
    } catch {
        # It exists, but this user may not open it.
        $busy = $true
    }
    if ($handle) { $handle.Dispose() }
    if (-not $busy) { 'Windows Installer is free'; break }
    if ((Get-Date) -gt $deadline) { "Windows Installer is still busy after $Minutes minutes"; break }
    Start-Sleep -Seconds 5
}
