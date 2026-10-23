# csw-both-floor-reasons-test.ps1 -- one alert carrying both floor reasons at once.
#
# The largest-directories list marks a figure as a floor for two different reasons: part of
# the tree was refused ("could not be read"), or the clock stopped the walk inside it
# ("the scan stopped inside it"). Each reason has its own suite already; no document had
# ever carried both, so the pair was only ever read apart. This produces one.
#
# It needs two things in the same run, in this order:
#   A-locked  a subtree denied to this account, so its figure is a floor by rights;
#   B-bulky   thousands of empty directories, still being walked when the budget expires,
#             so its figure is a floor by time.
# A comes first alphabetically, which is the order the wildcard hands the children over.
#
# Timing, and why the numbers are what they are: the deadline is set before the pre-walk
# work, so the budget also pays for roughly 3-4 s of startup on this machine (measured;
# a one-file tree is already truncated at -TimeBudgetSeconds 3 and fine at 4). With a 6 s
# budget the walk starts ~2.5 s before the deadline, and 6000 directories take ~6 s to
# walk, so the cutoff lands inside B-bulky with room either side. A machine slow enough to
# spend 6 s before the first walk would truncate inside A-locked instead, and the suite
# fails saying so rather than reporting a pass it did not earn.
# Run against the checkout by default; pass -Watch to exercise another copy.
param([string]$Watch = (Join-Path $PSScriptRoot 'c-space-watch.ps1'), [int]$Budget = 6, [int]$Dirs = 6000)
$ErrorActionPreference = 'Stop'
$watch = $Watch
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$stamp = Get-Date -Format 'HHmmss'
$base = Join-Path $env:TEMP "csw-both-floors-$stamp"
$watched = Join-Path $base 'watched'
$a = Join-Path $watched 'A-locked'
$b = Join-Path $watched 'B-bulky'
$state = Join-Path $base 'state'
$empty = Join-Path $base 'no-sandboxes'
New-Item -ItemType Directory -Force -Path (Join-Path $a 'locked'), $b, $state, $empty | Out-Null
1..2 | ForEach-Object { fsutil file createnew (Join-Path $a "a$_.bin") (1MB) | Out-Null }
1..2 | ForEach-Object { fsutil file createnew (Join-Path $a "locked\l$_.bin") (1MB) | Out-Null }

$build = [System.Diagnostics.Stopwatch]::StartNew()
for ($i = 1; $i -le $Dirs; $i++) { [void][System.IO.Directory]::CreateDirectory((Join-Path $b ("d{0:D5}" -f $i))) }
"fixture          : $Dirs directories built in $([math]::Round($build.Elapsed.TotalSeconds, 1)) s"

& icacls.exe (Join-Path $a 'locked') /deny "$($user):(OI)(CI)(RX)" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'icacls deny failed' }
try { $null = [System.IO.Directory]::EnumerateFileSystemEntries((Join-Path $a 'locked')); throw 'the deny does not block enumeration' }
catch [System.UnauthorizedAccessException] { }

try {
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $watch `
        -NoToast -NoSweep -NoCorrelate -Simulate -StateDir $state -SandboxRoot $empty `
        -WatchRoot (Join-Path $watched '*') -TimeBudgetSeconds $Budget 2>&1
    $code = $LASTEXITCODE
    $doc = Get-Content -LiteralPath (Join-Path $state 'C-SPACE-ALERT.txt') -Raw
    $log = Get-Content -LiteralPath (Join-Path $state 'c-space-watch.log') -Raw
} finally {
    & icacls.exe (Join-Path $a 'locked') /remove:d $user | Out-Null
}

$lines = @($doc -split "`r?`n")
function Section([string]$from, [string]$to) {
    $start = -1; $stop = $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($start -lt 0 -and $lines[$i] -match $from) { $start = $i }
        elseif ($start -ge 0 -and $lines[$i] -match $to) { $stop = $i; break }
    }
    if ($start -lt 0) { return '' }
    return (($lines[$start..($stop - 1)]) -join "`n")
}
$growth = Section '^biggest growth' '^largest directories now'
$largest = @($lines | Where-Object { $_ -match '^\s+\d+\.\d\d GB\s' })
$rowA = @($largest | Where-Object { $_ -match 'A-locked' })
$rowB = @($largest | Where-Object { $_ -match 'B-bulky' })

"exit             : $code"
"growth section   : $($growth -replace "`r?`n", ' | ')"
"largest rows     : $($rowA -join ' | ') /// $($rowB -join ' | ')"

$fail = New-Object System.Collections.Generic.List[string]
if (-not (Test-Path -LiteralPath (Join-Path $state 'C-SPACE-ALERT.txt'))) { $fail.Add('no alert document') }
if ($doc -notmatch 'C: SPACE ALERT') { $fail.Add('the document is not an alert') }
if ($log -notmatch 'scan truncated') { $fail.Add('the scan was not truncated, so there is no cut-short floor to show') }
if ($log -match 'scan truncated at .*\n.*cut short inside .*A-locked') { $fail.Add('the budget ran out inside A-locked, before B-bulky was reached (raise -Dirs or lower -Budget)') }

# --- the two notes, side by side in the same growth section
if ($growth -notmatch 'cut short inside .*B-bulky') { $fail.Add('the alert does not say the scan was cut short inside B-bulky') }
if ($growth -notmatch 'could not read all of .*A-locked -- 1 directory inside denied access') { $fail.Add('the alert does not say A-locked was refused') }
if ($growth -match 'cut short inside .*A-locked') { $fail.Add('the cut-short note names A-locked, so its floor is the clock and not the refusal') }
if ($growth -notmatch 'none ranked') { $fail.Add('the growth section ranked something despite both floors') }

# --- the two rows, each with its own reason, both in this one list
if ($rowA.Count -ne 1) { $fail.Add("expected one row for A-locked, found $($rowA.Count)") }
elseif ($rowA[0] -notmatch '\(floor, not a size -- part of this tree could not be read\)$') { $fail.Add("A-locked carries the wrong floor reason: $($rowA[0])") }
if ($rowB.Count -ne 1) { $fail.Add("expected one row for B-bulky, found $($rowB.Count)") }
elseif ($rowB[0] -notmatch '\(floor, not a size -- the scan stopped inside it\)$') { $fail.Add("B-bulky carries the wrong floor reason: $($rowB[0])") }

Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
'---'
if ($fail.Count -gt 0) { $fail | ForEach-Object { "FAIL: $_" }; exit 1 }
'PASS'
