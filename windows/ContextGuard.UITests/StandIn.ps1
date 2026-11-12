# A stand-in for `context-guard ui`, for the app's UI tests and screenshots: it prints one board (a file
# from contract/ui/boards), then appends each line the app writes to a log and answers it with a result.
# With -Next, it prints the next of those boards after each answer, so a test can see the app follow a change
# (Compact, then the answered board). It ends when the app closes its input. Windows PowerShell 5.1; ASCII only.
param(
    [Parameter(Mandatory = $true)][string]$Board,
    [Parameter(Mandatory = $true)][string]$Log,
    # Board names in the same folder as -Board, comma-separated: one after each intent, in turn.
    [string]$Next = '',
    # A chime after the first board, as the program sends one when a question popup opens.
    [switch]$Chime
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$out = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), $utf8)
$out.NewLine = "`n"
$out.AutoFlush = $true
$in = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), $utf8)
# Its process id next to the log, so a test can see it end with the app.
[System.IO.File]::WriteAllText($Log + '.pid', [string]$PID)

# A board file as one line: JSON strings hold no line breaks, so joining its trimmed lines keeps every value.
function Write-Board([string]$Path) {
    $line = (Get-Content -LiteralPath $Path -Encoding UTF8 | ForEach-Object { $_.Trim() }) -join ''
    $out.WriteLine($line)
}

Write-Board $Board
if ($Chime) { $out.WriteLine('{"v":1,"type":"chime"}') }

$folder = Split-Path -Parent $Board
$queue = @($Next -split ',' | Where-Object { $_ -ne '' })
$turn = 0
while ($null -ne ($intent = $in.ReadLine())) {
    [System.IO.File]::AppendAllText($Log, $intent + "`n", $utf8)
    $id = ($intent | ConvertFrom-Json).id
    $out.WriteLine('{"v":1,"type":"result","id":"' + $id + '"}')
    if ($turn -lt $queue.Count) {
        Write-Board (Join-Path $folder ($queue[$turn] + '.json'))
        $turn++
    }
}
