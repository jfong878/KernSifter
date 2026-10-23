# csw-cache-unreadable-test.ps1 -- the cache line when a refusal is why no grower was ranked.
#
# The alert carries a cache line even when there is no top grower to check. With a tree
# that could not be read, "nothing grew by 1 MB or more" states the one thing the run did
# not find out, so the line must name the refusal instead. The branch needs both halves at
# once: an alert with no ranked grower, and an unreadable tree. csw-unreadable-test.ps1
# produces such a document in its case A but asserts the growth section and the floor row,
# never the cache line -- so this suite isolates the line, with a fixture where nothing
# grew at all and the refusal is therefore the only reason no grower was ranked.
#
# The deny is a real icacls deny (no elevation needed) and -Simulate forces the alert on a
# drive that is not actually short; the line reads the trigger, not the free-space figure.
# Run against the checkout by default; pass -Watch to exercise the installed copy instead.
param([string]$Watch = (Join-Path $PSScriptRoot 'c-space-watch.ps1'))
$ErrorActionPreference = 'Stop'
$watch = $Watch
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$stamp = Get-Date -Format 'HHmmss'
$base = Join-Path $env:TEMP "csw-cache-unreadable-$stamp"
$watched = Join-Path $base 'watched'
$a = Join-Path $watched 'A'
$b = Join-Path $watched 'B'
$state = Join-Path $base 'state'
$empty = Join-Path $base 'no-sandboxes'
New-Item -ItemType Directory -Force -Path (Join-Path $a 'locked'), $b, $state, $empty | Out-Null
1..8 | ForEach-Object { fsutil file createnew (Join-Path $a "locked\a$_.bin") (5MB) | Out-Null }
1..3 | ForEach-Object { fsutil file createnew (Join-Path $b "b$_.bin") (1MB) | Out-Null }

function Invoke-Watch {
    $call = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watch,
        '-NoToast', '-NoSweep', '-NoCorrelate', '-Simulate',
        '-StateDir', $state, '-SandboxRoot', $empty,
        '-WatchRoot', (Join-Path $watched '*'), '-TimeBudgetSeconds', '60')
    return (& powershell.exe @call 2>&1 | Out-String)
}

$null = Invoke-Watch
$s1 = Get-Content -LiteralPath (Join-Path $state 'c-space-state.json') -Raw | ConvertFrom-Json
"baseline A       : $([math]::Round([long]$s1.paths.$a / 1MB)) MB"

$null = & icacls.exe (Join-Path $a 'locked') /deny "$($user):(OI)(CI)(RX)"
if ($LASTEXITCODE -ne 0) { throw 'icacls deny failed' }
try { $null = [System.IO.Directory]::EnumerateFileSystemEntries((Join-Path $a 'locked')); throw 'the deny does not block enumeration' }
catch [System.UnauthorizedAccessException] { }

try {
    $null = Invoke-Watch
    $doc = Get-Content -LiteralPath (Join-Path $state 'C-SPACE-ALERT.txt') -Raw
} finally {
    & icacls.exe (Join-Path $a 'locked') /remove:d $user | Out-Null
}

$cacheLine = (@(($doc -split "`r?`n") | Where-Object { $_ -match '^(cleared|would clear)\s+:' }) -join ' | ')
$growth = (@(($doc -split "`r?`n") | Where-Object { $_ -match 'none ranked' }) -join ' ')
"carried          : $(@(($doc -split "`r?`n") | Where-Object { $_ -match 'could not read all of' }).Count) refusal line(s)"
"growth           : $growth"
"cache line       : $cacheLine"

$fail = New-Object System.Collections.Generic.List[string]
if ($doc -notmatch 'could not read all of') { $fail.Add('no refusal line, so the fixture did not reproduce the case') }
if ($doc -notmatch '(?m)^biggest growth') { $fail.Add('no growth section') }
if ($growth -notmatch 'none ranked') { $fail.Add('a grower was ranked, so the empty-ranking branch was not taken') }
if (-not $cacheLine) { $fail.Add('the alert has no cache line at all') }
if ($cacheLine -notmatch 'a directory could not be read in full, so there is no ranked grower to check for a cache') {
    $fail.Add('the cache line does not name the refusal as the reason there is no grower')
}
if ($cacheLine -match 'nothing grew by 1 MB or more') {
    $fail.Add('the cache line says nothing grew, which this run did not find out')
}

Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
'---'
if ($fail.Count -gt 0) { $fail | ForEach-Object { "FAIL: $_" }; exit 1 }
'PASS'
