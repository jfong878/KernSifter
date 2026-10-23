# csw-unranked-grow-test.ps1 -- the not-ranked line says which of the three grew.
#
# A size on its own cannot tell a fall that is the pagefile growing from one that is not, so
# the three figures are carried in the state and compared. Fixture under %TEMP%, five runs:
#   1. baseline                         -> state records the three verdicts;
#   A. pagefile baseline 0.5 GB lower   -> the line says "grew since HH:mm: pagefile +0.50 GB"
#                                          and the log tags it;
#   B. pagefile baseline at the real    -> "none of them grew since HH:mm", with the shadow
#      size, shadow unreadable             figure named as not compared instead of unchanged;
#   C. no notRanked in the state        -> "no earlier figures to compare with";
#   D. shadow baseline seeded, run      -> the unreadable shadow keeps its old figure and time
#      unelevated (shadow unknown)        while the pagefile's is refreshed.
$ErrorActionPreference = 'Stop'
$watch = (Join-Path $PSScriptRoot 'c-space-watch.ps1')
$stamp = Get-Date -Format 'HHmmss'
$base = Join-Path $env:TEMP "csw-grow-$stamp"
$watched = Join-Path $base 'watched\keep'
$state = Join-Path $base 'state'
$empty = Join-Path $base 'no-sandboxes'
$statePath = Join-Path $state 'c-space-state.json'
$logPath = Join-Path $state 'c-space-watch.log'
$alertPath = Join-Path $state 'C-SPACE-ALERT.txt'
New-Item -ItemType Directory -Force -Path $watched, $state, $empty | Out-Null
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
function Read-State { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json }
function Save-State($s) { $s | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding UTF8 }
function Free-Bytes { (Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace }
function Seed-Fall($s, [double]$gb) { $s.freeBytes = [long]((Free-Bytes) + ($gb * 1GB)) }
function NotRanked-Line {
    if (-not (Test-Path -LiteralPath $alertPath)) { return $null }
    $a = Get-Content -LiteralPath $alertPath -Raw
    return (@($a -split "`n") | Where-Object { $_ -match '^not ranked' } | Select-Object -First 1)
}
function Log-Tail([int]$skip) { @(Get-Content -LiteralPath $logPath | Select-Object -Skip $skip) -join "`n" }

$fail = New-Object System.Collections.Generic.List[string]

# --- 1. baseline: the figures are recorded even though nothing is printed for them
$null = Invoke-Watch
$s1 = Read-State
$realPf = [long]$s1.notRanked.pagefile.bytes
"baseline pf     : $([math]::Round($realPf / 1GB, 2)) GB (state=$($s1.notRanked.pagefile.state))"
"baseline hb     : state=$($s1.notRanked.hibernation.state)"
"baseline shadow : state=$($s1.notRanked.shadow.state)"
if ($s1.notRanked.pagefile.state -ne 'size') { $fail.Add('the baseline did not record a pagefile size') }
if ($realPf -lt 100MB) { $fail.Add("the recorded pagefile size is $realPf bytes") }
if ($s1.notRanked.hibernation.state -notin @('size', 'none', 'unknown')) { $fail.Add('the hibernation verdict is missing from the state') }
if ($s1.notRanked.shadow.state -notin @('size', 'none', 'unknown')) { $fail.Add('the shadow verdict is missing from the state') }

# --- A. the pagefile grew by 0.5 GB since the last measurement
$s2 = Read-State
$s2.notRanked.pagefile.bytes = [long]($realPf - 0.5GB)
$s2.notRanked.pagefile.at = (Get-Date).AddMinutes(-10).ToString('o')
Seed-Fall $s2 0.4
Save-State $s2
Remove-Item -LiteralPath $alertPath -ErrorAction SilentlyContinue
$len = @(Get-Content -LiteralPath $logPath).Count
$null = Invoke-Watch @('Simulate')
$lineA = NotRanked-Line
$logA = Log-Tail $len
"grew line       : $($lineA)"
"grew tag        : $([bool]($logA -match '\[grew pagefile \+0\.50 GB\]'))"
if (-not $lineA) { $fail.Add('case A: no not-ranked line') }
if ($lineA -and $lineA -notmatch 'grew since \d\d:\d\d: pagefile \+0\.50 GB') { $fail.Add('case A: the line does not say the pagefile grew by 0.50 GB') }
if ($lineA -and $lineA -match 'none of them grew') { $fail.Add('case A: the line claims nothing grew while the pagefile did') }
if ($lineA -and $lineA.IndexOf('grew since') -lt $lineA.IndexOf('shadow')) { $fail.Add('case A: the comparison is not after the three figures') }
if ($logA -notmatch '\[grew pagefile \+0\.50 GB\]') { $fail.Add('case A: the log summary does not tag the growth') }

# --- B. nothing grew, and the unreadable shadow is named rather than counted as unchanged
$s3 = Read-State
$s3.notRanked.pagefile.bytes = $realPf
$s3.notRanked.pagefile.at = (Get-Date).AddMinutes(-10).ToString('o')
Seed-Fall $s3 0.4
Save-State $s3
Remove-Item -LiteralPath $alertPath -ErrorAction SilentlyContinue
$len = @(Get-Content -LiteralPath $logPath).Count
$null = Invoke-Watch @('Simulate')
$lineB = NotRanked-Line
$logB = Log-Tail $len
"none line       : $($lineB)"
if (-not $lineB) { $fail.Add('case B: no not-ranked line') }
if ($lineB -and $lineB -notmatch 'none of them grew since \d\d:\d\d') { $fail.Add('case B: the line does not say nothing grew') }
if ($lineB -and $lineB -notmatch 'shadow storage not compared') { $fail.Add('case B: the shadow figure was counted as unchanged instead of not compared') }
if ($logB -notmatch '\[nothing grew\]') { $fail.Add('case B: the log summary does not say nothing grew') }

# --- C. no baseline at all
$s4 = Read-State
$s4.PSObject.Properties.Remove('notRanked')
Seed-Fall $s4 0.4
Save-State $s4
Remove-Item -LiteralPath $alertPath -ErrorAction SilentlyContinue
$null = Invoke-Watch @('Simulate')
$lineC = NotRanked-Line
"baseline line   : $($lineC)"
if (-not $lineC) { $fail.Add('case C: no not-ranked line') }
if ($lineC -and $lineC -notmatch 'no earlier figures to compare with') { $fail.Add('case C: a first comparison did not say it had no earlier figures') }
if ($lineC -and $lineC -match 'grew since|none of them grew') { $fail.Add('case C: a first comparison claimed a comparison') }

# --- D. a carried figure keeps its value and its time; a fresh one gets this run's time
$s5 = Read-State
$oldAt = (Get-Date).AddHours(-5).ToString('o')
$s5.notRanked.shadow = [pscustomobject]@{ state = 'size'; bytes = [long]1234567890; at = $oldAt }
$s5.notRanked.pagefile.at = (Get-Date).AddHours(-5).ToString('o')
Save-State $s5
$null = Invoke-Watch
$s6 = Read-State
"carried shadow  : bytes=$($s6.notRanked.shadow.bytes) at-kept=$($s6.notRanked.shadow.at -eq $oldAt)"
"pagefile time   : refreshed=$($s6.notRanked.pagefile.at -ne $s5.notRanked.pagefile.at)"
"pagefile size   : $($s6.notRanked.pagefile.bytes -eq $realPf)"
if ([long]$s6.notRanked.shadow.bytes -ne 1234567890) { $fail.Add('the unreadable shadow figure was overwritten by a run that could not read it') }
if ($s6.notRanked.shadow.at -ne $oldAt) { $fail.Add('the carried shadow figure lost the time it was measured') }
if ($s6.notRanked.pagefile.at -eq $s5.notRanked.pagefile.at) { $fail.Add('the pagefile figure was not refreshed') }
if ([long]$s6.notRanked.pagefile.bytes -ne $realPf) { $fail.Add('the pagefile figure changed when nothing did') }

Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
'---'
if ($fail.Count -gt 0) { $fail | ForEach-Object { "FAIL: $_" }; exit 1 }
'PASS'
