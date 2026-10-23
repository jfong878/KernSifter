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
# Timing: the deadline is set before the pre-walk work, so the budget also pays for the
# startup between that line and the first walk. On this machine that startup measured 3-4 s
# (a one-file tree is truncated at -TimeBudgetSeconds 3 and fine at 4), but it is not a
# constant: under load it has been seen past 6 s, which is longer than a fixed budget would
# survive. So the budget is not fixed. The suite tries -Budget first, and when the run comes
# back cut inside A-locked -- meaning the deadline passed before the walk began -- it tries
# again three seconds larger, up to four times. What it needs is only that the first walk
# starts before the deadline and B-bulky outlasts what is left, and B-bulky's walk is several
# seconds even warm, so a few seconds of margin either way are enough. If a run is not
# truncated at all, the walk finished inside the budget and a larger one would only weaken
# the test, so the attempt that shows that is the one reported.
#
# The bulky tree is built once and reused. Building it is the expensive part (tens of
# seconds for 20000 directories); a run that finds it intact spends its time on the scan
# alone. It lives at %TEMP%\csw-both-floors-fixture, is checked by directory count and a
# marker file, and is rebuilt when anything is missing. Pass -Reset to force that, or delete
# the directory by hand; the suite never removes it, which is what makes the next run quick.
# A run that finds the count wrong rebuilds rather than trusting a half-deleted tree -- a
# short B-bulky would finish inside the budget and the suite would report a truncation that
# never happened.
param(
    [string]$Watch = (Join-Path $PSScriptRoot 'c-space-watch.ps1'),
    [int]$Budget = 6,
    [int]$Dirs = 20000,
    [string]$FixtureRoot = (Join-Path $env:TEMP 'csw-both-floors-fixture'),
    [switch]$Reset
)
$ErrorActionPreference = 'Stop'
$watch = $Watch
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$stamp = Get-Date -Format 'HHmmss'
$total = [System.Diagnostics.Stopwatch]::StartNew()

$watched = Join-Path $FixtureRoot 'watched'
$a = Join-Path $watched 'A-locked'
$b = Join-Path $watched 'B-bulky'
$empty = Join-Path $FixtureRoot 'no-sandboxes'
New-Item -ItemType Directory -Force -Path $empty | Out-Null

# ---------------------------------------------------------------- the cached fixture
$marker = Join-Path $FixtureRoot 'fixture.json'
$present = 0
if (-not $Reset -and (Test-Path -LiteralPath $marker) -and (Test-Path -LiteralPath (Join-Path $a 'locked\l1.bin'))) {
    $present = [System.IO.Directory]::GetDirectories($b).Length
}
if ($present -ne $Dirs) {
    if (Test-Path -LiteralPath $FixtureRoot) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force }
    New-Item -ItemType Directory -Force -Path (Join-Path $a 'locked'), $b, $empty | Out-Null
    1..2 | ForEach-Object { fsutil file createnew (Join-Path $a "a$_.bin") (1MB) | Out-Null }
    1..2 | ForEach-Object { fsutil file createnew (Join-Path $a "locked\l$_.bin") (1MB) | Out-Null }
    $build = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 1; $i -le $Dirs; $i++) { [void][System.IO.Directory]::CreateDirectory((Join-Path $b ("d{0:D5}" -f $i))) }
    [ordered]@{ dirs = $Dirs; builtAt = (Get-Date).ToString('o') } | ConvertTo-Json -Compress |
        Set-Content -LiteralPath $marker -Encoding ASCII
    "fixture          : built $Dirs directories in $([math]::Round($build.Elapsed.TotalSeconds, 1)) s (reused from now on: $FixtureRoot)"
} else {
    "fixture          : reused $present directories from $FixtureRoot"
}

& icacls.exe (Join-Path $a 'locked') /deny "$($user):(OI)(CI)(RX)" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'icacls deny failed' }
try { $null = [System.IO.Directory]::EnumerateFileSystemEntries((Join-Path $a 'locked')); throw 'the deny does not block enumeration' }
catch [System.UnauthorizedAccessException] { }

# ---------------------------------------------------------------- the run, with retries
# Parenthesised: in PowerShell the comma binds tighter than +, so @($B, $B + 3) is
# ($B, $B) + 3 -- an array of three budgets, not two.
$attempts = @($Budget, ($Budget + 3), ($Budget + 6), ($Budget + 9))
$states = New-Object System.Collections.Generic.List[string]
$notes = New-Object System.Collections.Generic.List[string]
$chosen = $null
$doc = $null
$log = $null
$code = $null
$state = $null
$scanSeconds = $null

try {
    foreach ($budget in $attempts) {
        $state = Join-Path $env:TEMP "csw-both-floors-state-$stamp-$budget"
        New-Item -ItemType Directory -Force -Path $state | Out-Null
        $states.Add($state)
        $scan = [System.Diagnostics.Stopwatch]::StartNew()
        $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $watch `
            -NoToast -NoSweep -NoCorrelate -Simulate -StateDir $state -SandboxRoot $empty `
            -WatchRoot (Join-Path $watched '*') -TimeBudgetSeconds $budget 2>&1
        $code = $LASTEXITCODE
        $scanSeconds = [math]::Round($scan.Elapsed.TotalSeconds, 1)
        $doc = Get-Content -LiteralPath (Join-Path $state 'C-SPACE-ALERT.txt') -Raw
        $log = Get-Content -LiteralPath (Join-Path $state 'c-space-watch.log') -Raw
        # Truncated inside A-locked means the deadline passed before the first walk: the
        # startup, not the fixture, ate the budget. Larger is the only useful direction.
        $truncated = [bool]($log -match 'scan truncated')
        $insideA = [bool]($log -match 'cut short inside .*A-locked')
        $notes.Add("budget ${budget}s -> truncated=$truncated insideA=$insideA ($scanSeconds s)")
        if ($truncated -and -not $insideA) { $chosen = $budget; break }
        # Not truncated: B-bulky was walked to the end before the deadline, so more time
        # would only make that easier. Report this attempt rather than hiding it.
        if (-not $truncated) { break }
    }
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

"attempts         : $($notes -join ' | ')"
"budget used      : $(if ($chosen) { "${chosen}s" } else { 'none -- see the attempts above' })"
"exit             : $code  (suite $([math]::Round($total.Elapsed.TotalSeconds, 1)) s)"
"growth section   : $($growth -replace "`r?`n", ' | ')"
"largest rows     : $($rowA -join ' | ') /// $($rowB -join ' | ')"

$fail = New-Object System.Collections.Generic.List[string]
if (-not (Test-Path -LiteralPath (Join-Path $state 'C-SPACE-ALERT.txt'))) { $fail.Add('no alert document') }
if ($doc -notmatch 'C: SPACE ALERT') { $fail.Add('the document is not an alert') }
if (-not $chosen) {
    if ($log -notmatch 'scan truncated') { $fail.Add('every budget let the walk finish inside it: B-bulky is too small (raise -Dirs)') }
    else { $fail.Add('every budget was spent before the first walk, so the startup is longer than the largest attempt (raise -Budget)') }
}

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

foreach ($s in $states) { Remove-Item -LiteralPath $s -Recurse -Force -ErrorAction SilentlyContinue }
'---'
if ($fail.Count -gt 0) { $fail | ForEach-Object { "FAIL: $_" }; exit 1 }
'PASS'
