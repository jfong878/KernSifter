# csw-partial-delta-test.ps1 -- a scan cut short must not report its cutoff as growth.
#
# Fixture under %TEMP%: two watch roots measured as separate specs, so the order is fixed.
#   run 1  normal budget      -> A is 40 MB, B is a few KB; both sizes go into the state;
#   run 2  -TimeBudgetSeconds 0 -> the budget is spent before A's first directory is walked,
#                                so A is 0 bytes and B is never reached. The alert must not
#                                rank A (its delta would be -0.04 GB: a phantom fall), must
#                                name it as cut short, and the state must keep A's 40 MB and
#                                B's size rather than the partial 0;
#   run 3  normal budget, +30 MB in A -> the delta must be +0.03 GB, not +0.07 GB, which is
#                                what a poisoned baseline would produce.
$ErrorActionPreference = 'Stop'
$watch = (Join-Path $PSScriptRoot 'c-space-watch.ps1')
$stamp = Get-Date -Format 'HHmmss'
$base = Join-Path $env:TEMP "csw-partial-$stamp"
$a = Join-Path $base 'watched\A'
$b = Join-Path $base 'watched\B'
$state = Join-Path $base 'state'
$empty = Join-Path $base 'no-sandboxes'
$statePath = Join-Path $state 'c-space-state.json'
$logPath = Join-Path $state 'c-space-watch.log'
$alertPath = Join-Path $state 'C-SPACE-ALERT.txt'
New-Item -ItemType Directory -Force -Path $a, $b, $state, $empty | Out-Null
Set-Content -LiteralPath (Join-Path $b 'b.txt') -Value 'steady' -Encoding ASCII
1..8 | ForEach-Object { fsutil file createnew (Join-Path $a "a$_.bin") (5MB) | Out-Null }

function Invoke-Watch([string]$Budget) {
    $call = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watch,
        '-NoToast', '-NoSweep', '-NoCorrelate', '-Simulate',
        '-StateDir', $state, '-SandboxRoot', $empty,
        '-WatchRoot', $a,
        '-TimeBudgetSeconds', $Budget)
    return (& powershell.exe @call 2>&1 | Out-String)
}
function Read-State { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json }
function Growth-Section {
    if (-not (Test-Path -LiteralPath $alertPath)) { return '' }
    $lines = (Get-Content -LiteralPath $alertPath -Raw) -split "`n"
    $start = -1; $stop = $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($start -lt 0 -and $lines[$i] -match '^biggest growth') { $start = $i }
        elseif ($start -ge 0 -and $lines[$i] -match '^largest directories now') { $stop = $i; break }
    }
    if ($start -lt 0) { return '' }
    return (($lines[$start..($stop - 1)]) -join "`n")
}
function Log-Tail([int]$skip) { @(Get-Content -LiteralPath $logPath | Select-Object -Skip $skip) -join "`n" }

$fail = New-Object System.Collections.Generic.List[string]

# --- run 1: a complete baseline
$null = Invoke-Watch '40'
$s1 = Read-State
$realA = [long]$s1.paths.$a
# A path that exists in the state but that the truncated scan will never reach, so the
# "unmeasured paths keep their baseline" half is tested without needing two watch roots
# (the -File argument parser hands a comma-joined list through as one string).
$seededB = [long]25165824
$s1.paths | Add-Member -NotePropertyName $b -NotePropertyValue $seededB -Force
$s1 | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding UTF8
"baseline A      : $([math]::Round($realA / 1MB, 1)) MB   B (seeded): $seededB bytes"
if ($realA -lt 30MB) { $fail.Add("the fixture did not measure A fully ($realA bytes)") }

# --- run 2: the scan is cut short before A's first directory is walked
Remove-Item -LiteralPath $alertPath -ErrorAction SilentlyContinue
$len = @(Get-Content -LiteralPath $logPath).Count
$null = Invoke-Watch '0'
$log2 = Log-Tail $len
$alert2 = if (Test-Path -LiteralPath $alertPath) { Get-Content -LiteralPath $alertPath -Raw } else { '' }
$growth2 = Growth-Section
$s2 = Read-State
$ranked2 = @($growth2 -split "`n" | Where-Object { $_ -match '[+-]\d+\.\d\d GB' })
"growth section  : $($growth2.Trim() -replace "`n", ' | ')"
"ranked entries  : $($ranked2.Count)"
"cut-short note  : $([bool]($alert2 -match '\(cut short inside .*A -- its size is partial, so it is not ranked\)'))"
"baseline kept A : $([long]$s2.paths.$a -eq $realA)  B kept: $([long]$s2.paths.$b -eq $seededB)"
"log note        : $(($log2 -split "`n") | Where-Object { $_ -match 'sized only' } | ForEach-Object { $_.Trim() })"
if (-not ($alert2 -match 'scan hit its 0s budget|NOTE: the scan hit')) { $fail.Add('run 2 did not report a truncated scan') }
if ($ranked2.Count -ne 0) { $fail.Add("a truncated scan ranked $($ranked2.Count) entr(ies): $($ranked2 -join ' | ')") }
if ($growth2 -match [regex]::Escape($a)) { $fail.Add('the cut-short directory appears in the growth section') }
if ($alert2 -notmatch '\(cut short inside .*A -- its size is partial, so it is not ranked\)') { $fail.Add('the alert does not name the directory it cut short') }
# The row in the list has to say the same thing the note above it does: a 0.00 GB entry
# for a tree the scan stopped inside reads as a measurement otherwise.
$largest2 = if ($alert2 -match '(?s)largest directories now:(.*?)(\r?\n\s*\r?\n|what to do)') { $Matches[1] } else { '' }
"largest row     : $(($largest2 -split "`n" | Where-Object { $_ -match 'GB' }) -join ' | ')"
if ($largest2 -notmatch '\(floor, not a size -- the scan stopped inside it\)') { $fail.Add('the cut-short row in largest directories does not say its figure is a floor') }
if (-not ($alert2 -match '\(none ranked -- the scan stopped at its time budget')) { $fail.Add('the empty ranking does not say the budget is why it is empty') }
if ([long]$s2.paths.$a -ne $realA) { $fail.Add("the partial size ($([long]$s2.paths.$a)) replaced A's baseline ($realA)") }
if ([long]$s2.paths.$b -ne $seededB) { $fail.Add('a path the truncated scan never reached lost its baseline in the state') }
if ($log2 -notmatch 'sized only 1 director\(ies\)') { $fail.Add('the log does not say only one directory was sized') }
if ($log2 -notmatch '\(cut short inside .*A\)') { $fail.Add('the log does not name the directory the scan cut short') }

# --- run 3: a complete scan sees only the real 30 MB, not the whole tree again
1..6 | ForEach-Object { fsutil file createnew (Join-Path $a "g$_.bin") (5MB) | Out-Null }
Remove-Item -LiteralPath $alertPath -ErrorAction SilentlyContinue
$null = Invoke-Watch '40'
$alert3 = if (Test-Path -LiteralPath $alertPath) { Get-Content -LiteralPath $alertPath -Raw } else { '' }
$growth3 = Growth-Section
$delta3 = if ($growth3 -match '([+-])(\d+\.\d\d) GB\s+') { "$($Matches[1])$($Matches[2])" } else { 'none' }
"run 3 growth    : $(($growth3 -split "`n" | Where-Object { $_ -match 'GB' }) -join ' | ')"
"run 3 delta     : $delta3 GB"
if ($delta3 -ne '+0.03') { $fail.Add("the complete scan reported $delta3 GB for a 30 MB write (expected +0.03)") }
if ($alert3 -match 'cut short inside') { $fail.Add('a complete scan carried a cut-short note') }

Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
'---'
if ($fail.Count -gt 0) { $fail | ForEach-Object { "FAIL: $_" }; exit 1 }
'PASS'
