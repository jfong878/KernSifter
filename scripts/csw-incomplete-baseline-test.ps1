# csw-incomplete-baseline-test.ps1 -- a missing path in a cut-short sample is not a new one.
#
# Three runs plus a seeded variant:
#   run 1  -TimeBudgetSeconds 0  -> the first sample dies before it sizes A's tree, so the
#                                   state holds no paths at all and baselineComplete=false;
#   run 2  complete              -> every directory now has a size but no earlier figure.
#                                   The ranking must stay empty, the alert must say the
#                                   previous sample was cut short, and the tag must count
#                                   the directories that became the baseline;
#   run 3  complete, +30 MB in A -> only the real 30 MB may rank (the state is complete now);
#   seeded                       -> a state with A's figure but NOT B's, baselineComplete
#                                   false: A must still rank (it has a baseline), B must be
#                                   counted and left out.
$ErrorActionPreference = 'Stop'
$watch = (Join-Path $PSScriptRoot 'c-space-watch.ps1')
$stamp = Get-Date -Format 'HHmmss'
$base = Join-Path $env:TEMP "csw-baseline-$stamp"
$watched = Join-Path $base 'watched'
$a = Join-Path $watched 'A'
$b = Join-Path $watched 'B'
$state = Join-Path $base 'state'
$empty = Join-Path $base 'no-sandboxes'
$statePath = Join-Path $state 'c-space-state.json'
$logPath = Join-Path $state 'c-space-watch.log'
$alertPath = Join-Path $state 'C-SPACE-ALERT.txt'
New-Item -ItemType Directory -Force -Path $a, $b, $state, $empty | Out-Null
1..8 | ForEach-Object { fsutil file createnew (Join-Path $a "a$_.bin") (5MB) | Out-Null }
fsutil file createnew (Join-Path $b 'b.bin') (2MB) | Out-Null

function Invoke-Watch([string]$Budget) {
    $call = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watch,
        '-NoToast', '-NoSweep', '-NoCorrelate', '-Simulate',
        '-StateDir', $state, '-SandboxRoot', $empty,
        '-WatchRoot', (Join-Path $watched '*'),
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
function Reset-Alert { Remove-Item -LiteralPath $alertPath -ErrorAction SilentlyContinue }

$fail = New-Object System.Collections.Generic.List[string]

# --- run 1: the first sample is cut short before A's tree is sized
$null = Invoke-Watch '0'
$s1 = Read-State
"run 1 state : paths=$(@($s1.paths.PSObject.Properties).Count) complete=$($s1.baselineComplete) truncated=$($s1.truncated)"
if ($s1.baselineComplete -ne $false) { $fail.Add('a cut-short first sample recorded itself as a complete baseline') }
if (@($s1.paths.PSObject.Properties).Count -ne 0) { $fail.Add('the cut-short first sample stored a path (the partial size leaked into the baseline)') }

# --- run 2: complete, but with nothing to compare against
Reset-Alert
$len = @(Get-Content -LiteralPath $logPath).Count
$null = Invoke-Watch '40'
$s2 = Read-State
$log2 = Log-Tail $len
$growth2 = Growth-Section
$ranked2 = @($growth2 -split "`n" | Where-Object { $_ -match '^\s+[+-]\d+\.\d\d GB' })
"run 2 growth: $(($growth2 -split "`n" | Where-Object { $_ -match 'ranked|baseline|GB' }) -join ' | ')"
"run 2 state : A=$([math]::Round([long]$s2.paths.$a / 1MB, 1)) MB B=$([math]::Round([long]$s2.paths.$b / 1MB, 1)) MB complete=$($s2.baselineComplete)"
"run 2 tag   : $(($log2 -split "`n") | Where-Object { $_ -match 'baseline:' } | ForEach-Object { $_.Trim() })"
if ($ranked2.Count -ne 0) { $fail.Add("run 2 ranked $($ranked2.Count) entr(ies) against an incomplete baseline: $($ranked2 -join ' | ')") }
if ($growth2 -notmatch 'none ranked -- the previous sample was cut short') { $fail.Add('run 2 does not say the previous sample was cut short') }
if ($growth2 -match 'no directory changed by 1 MB') { $fail.Add('run 2 claims nothing changed instead of naming the missing baseline') }
if ([long]$s2.paths.$a -lt 30MB) { $fail.Add("run 2 did not store A's measured size as the baseline ($([long]$s2.paths.$a) bytes)") }
if ([long]$s2.paths.$b -lt 1MB) { $fail.Add('run 2 did not store B (a path the cut-short sample never reached)') }
if ($s2.baselineComplete -ne $true) { $fail.Add('a complete run did not record a complete baseline') }
if ($log2 -notmatch '\[baseline: 2 dir\(s\) had no earlier figure\]') { $fail.Add('the log does not count the directories that became the baseline') }
if ($log2 -notmatch 'no directory had an earlier figure to grow from') { $fail.Add('the cache line blames "nothing grew" where there was no baseline to grow from') }

# --- run 3: the baseline is complete, so only the real 30 MB ranks
Reset-Alert
1..6 | ForEach-Object { fsutil file createnew (Join-Path $a "g$_.bin") (5MB) | Out-Null }
$null = Invoke-Watch '40'
$growth3 = Growth-Section
$ranked3 = @($growth3 -split "`n" | Where-Object { $_ -match '^\s+[+-]\d+\.\d\d GB' })
$delta3 = if ($growth3 -match '([+-])(\d+\.\d\d) GB\s+') { "$($Matches[1])$($Matches[2])" } else { 'none' }
"run 3 growth: $(($growth3 -split "`n" | Where-Object { $_ -match 'GB' }) -join ' | ')"
if ($delta3 -ne '+0.03') { $fail.Add("run 3 reported $delta3 GB for a 30 MB write (expected +0.03)") }
if ($ranked3.Count -ne 1) { $fail.Add("run 3 ranked $($ranked3.Count) entries (only the 30 MB in A should rank)") }
$alert3 = if (Test-Path -LiteralPath $alertPath) { Get-Content -LiteralPath $alertPath -Raw } else { '' }
if ($alert3 -match 'previous sample was cut short') { $fail.Add('run 3 still describes the previous sample as cut short') }
$s3 = Read-State
if ($s3.baselineComplete -ne $true) { $fail.Add('run 3 lost the complete-baseline flag') }

# --- seeded: A has a baseline, B does not, and the state says the baseline is incomplete
Reset-Alert
$seeded = [ordered]@{
    sampledAt        = (Get-Date).AddMinutes(-5).ToString('o')
    baselineComplete = $false
    truncated        = $true
    paths            = [ordered]@{ $a = 10485760 }
    promoted         = @()
    cooldown         = @()
    history          = @()
} | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($statePath, $seeded, (New-Object System.Text.UTF8Encoding($false)))
$null = Invoke-Watch '40'
$growth4 = Growth-Section
$alert4 = Get-Content -LiteralPath $alertPath -Raw
$s4 = Read-State
$ranked4 = @($growth4 -split "`n" | Where-Object { $_ -match '^\s+[+-]\d+\.\d\d GB' })
"seeded     : $(($growth4 -split "`n" | Where-Object { $_ -match 'GB|earlier' }) -join ' | ')"
if ($ranked4.Count -ne 1) { $fail.Add("the seeded run ranked $($ranked4.Count) entries (A has a baseline; B does not)") }
if ($ranked4.Count -eq 1 -and $ranked4[0] -notmatch 'A\r?$') { $fail.Add('the seeded run ranked the directory without a baseline instead of the one with it') }
if ($alert4 -notmatch '\(1 directory had no earlier figure -- the previous sample was cut short\)') { $fail.Add('the seeded run does not count the one directory it could not compare') }
if ([long]$s4.paths.$b -lt 1MB) { $fail.Add('the seeded run did not record B after establishing its baseline') }
if ($s4.baselineComplete -ne $true) { $fail.Add('the seeded complete run did not clear the incomplete flag') }

Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
'---'
if ($fail.Count -gt 0) { $fail | ForEach-Object { "FAIL: $_" }; exit 1 }
'PASS'
