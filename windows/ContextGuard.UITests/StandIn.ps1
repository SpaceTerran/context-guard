# A stand-in for `context-guard ui`, for the app's UI tests and screenshots: it prints one board (a file
# from contract/ui/boards), then appends each line the app writes to a log and answers it with a result.
# It ends when the app closes its input. Windows PowerShell 5.1; ASCII only.
param(
    [Parameter(Mandatory = $true)][string]$Board,
    [Parameter(Mandatory = $true)][string]$Log
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$out = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), $utf8)
$out.NewLine = "`n"
$out.AutoFlush = $true
$in = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), $utf8)
# Its process id next to the log, so a test can see it end with the app.
[System.IO.File]::WriteAllText($Log + '.pid', [string]$PID)

# The file as one line: JSON strings hold no line breaks, so joining its trimmed lines keeps every value.
$line = (Get-Content -LiteralPath $Board -Encoding UTF8 | ForEach-Object { $_.Trim() }) -join ''
$out.WriteLine($line)

while ($null -ne ($intent = $in.ReadLine())) {
    [System.IO.File]::AppendAllText($Log, $intent + "`n", $utf8)
    $id = ($intent | ConvertFrom-Json).id
    $out.WriteLine('{"v":1,"type":"result","id":"' + $id + '"}')
}
