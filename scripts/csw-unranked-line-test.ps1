# csw-unranked-line-test.ps1 -- the one line that sizes what a fall left behind.
#
# Two halves:
#   A. the readers themselves -- the pagefile and the hibernation file are sized off the
#      volume root (FileInfo, because Windows hides both from Get-Item) and the hibernation
#      reason comes from the power key, so each verdict is checked against this machine;
#   B. an alert whose fall has nothing growing in the watch roots -- the line must size the
#      pagefile and the hibernation file AND carry the shadow verdict, in that order, with
#      the log summary tagging all three. The point of one line is that the unreadable half
#      (shadow, unelevated) cannot cost the readable two.
$ErrorActionPreference = 'Stop'
$watch = (Join-Path $PSScriptRoot 'c-space-watch.ps1')
$stamp = Get-Date -Format 'HHmmss'

# --- A. the readers
$src = Get-Content -LiteralPath $watch -Raw
foreach ($name in @('Get-PageFileInfo', 'Get-HibernationFileInfo')) {
    $m = [regex]::Match($src, "(?ms)^function $name.*?^}")
    if (-not $m.Success) { throw "could not lift $name out of the script" }
    Invoke-Expression $m.Value
}
$pf = Get-PageFileInfo -DriveLetter C
$hb = Get-HibernationFileInfo -DriveLetter C
"pagefile      : measured=$($pf.Measured) size=$([math]::Round($pf.Bytes / 1GB, 2)) GB max=$(if ($null -ne $pf.Max) { '{0:N2} GB' -f ($pf.Max / 1GB) } else { 'none' }) reason=$($pf.Reason)"
"hibernation   : measured=$($hb.Measured) size=$([math]::Round($hb.Bytes / 1GB, 2)) GB reason=$($hb.Reason)"

# --- B. the line an alert carries
$base = Join-Path $env:TEMP "csw-unranked-$stamp"
$watched = Join-Path $base 'watched\keep'
$state = Join-Path $base 'state'
$empty = Join-Path $base 'no-sandboxes'
$hidden = Join-Path $env:TEMP "csw-unranked-hidden-$stamp"
$logPath = Join-Path $state 'c-space-watch.log'
$alertPath = Join-Path $state 'C-SPACE-ALERT.txt'
New-Item -ItemType Directory -Force -Path $watched, $state, $empty, $hidden | Out-Null
Set-Content -LiteralPath (Join-Path $watched 'file.txt') -Value 'steady' -Encoding ASCII

function Invoke-Watch([string[]]$Switches = @()) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watch,
        '-NoToast', '-NoSweep', '-NoCorrelate',
        '-StateDir', $state,
        '-WatchRoot', (Join-Path $base 'watched\*'),
        '-SandboxRoot', $empty,
        '-TimeBudgetSeconds', '40')
    foreach ($s in $Switches) { $a += "-$s" }
    return (& powershell.exe @a 2>&1 | Out-String)
}

$null = Invoke-Watch
fsutil file createnew (Join-Path $hidden 'fall.bin') (400MB) | Out-Null
$len = @(Get-Content -LiteralPath $logPath).Count
$null = Invoke-Watch @('Simulate')
$log9 = @(Get-Content -LiteralPath $logPath | Select-Object -Skip $len) -join "`n"
$alert = Get-Content -LiteralPath $alertPath -Raw
Remove-Item -LiteralPath $hidden -Recurse -Force -ErrorAction SilentlyContinue

$line = (@($alert -split "`n") | Where-Object { $_ -match '^not ranked' } | Select-Object -First 1)
"line          : $($line.Trim())"
"summary       : $(($log9 -split "`n") | Where-Object { $_ -match 'ALERT' } | Select-Object -First 1)"

$fail = @()
# A. the readers answer about this machine
if (-not $pf.Measured) { $fail += "the pagefile was not sized ($($pf.Reason))" }
if ($pf.Measured -and $pf.Bytes -lt 100MB) { $fail += "the pagefile came back as $($pf.Bytes) bytes" }
if ($pf.Measured -and $null -ne $pf.Max -and $pf.Max -le 0) { $fail += 'the pagefile maximum came back as a non-positive number' }
if (-not $hb.Measured -and -not $hb.Reason) { $fail += 'the hibernation file came back silent' }
if ($hb.Measured -and $hb.Bytes -le 0) { $fail += 'a hibernation file was measured as empty' }

# B. one line, three parts, in the order that puts the readable ones first
if (-not $line) { $fail += 'the alert has no "not ranked" line' }
if ($line) {
    if ($line -notmatch 'pagefile (\d+\.\d\d GB on C:|none -- \S)') { $fail += "the line does not size the pagefile ($($line.Trim()))" }
    if ($line -notmatch 'hibernation file (none -- \S|\d+\.\d\d GB on C:)') { $fail += 'the line does not size the hibernation file' }
    if ($line -notmatch 'shadow (unknown -- \S|none -- no shadow copies|\d+\.\d\d GB on C:)') { $fail += 'the line does not carry the shadow verdict' }
    if ($line.IndexOf('pagefile') -gt $line.IndexOf('hibernation')) { $fail += 'the pagefile is not the first clause' }
    if ($line.IndexOf('hibernation') -gt $line.IndexOf('shadow')) { $fail += 'the shadow verdict is not the last clause' }
    if ($line -match 'pagefile unknown') { $fail += 'the pagefile was reported unreadable on a run that can read it' }
    if ($line -match 'hibernation file unknown') { $fail += 'the hibernation file was reported unreadable on a run that can read it' }
}
if ($alert -match '(?m)^shadow') { $fail += 'a separate shadow line survived the merge' }
if ($log9 -notmatch '\[pagefile (\d+\.\d\d GB|none)\]') { $fail += 'the log summary does not tag the pagefile' }
if ($log9 -notmatch '\[hibernation (none|\d+\.\d\d GB)\]') { $fail += 'the log summary does not tag the hibernation file' }
if ($log9 -notmatch '\[shadow (unknown|none|\d+\.\d\d GB)\]') { $fail += 'the log summary does not tag the shadow verdict' }

'---'
if ($fail.Count -gt 0) {
    $fail | ForEach-Object { "FAIL: $_" }
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}
Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
'PASS'
