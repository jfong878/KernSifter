# csw-promote-bound-test.ps1 -- the promoted list is bounded in time and in count.
#
# A. expiry (one directory that never stops growing):
#    run 1 baseline; 600 MB into an unwatched sibling;
#    run 2 the walk names it -> promoted with runs=0;
#    run 3 it grows again -> sampled, runs=1 (-PromotedMaxRuns 2);
#    run 4 it grows again -> sampled once more, then expired: the state no longer holds
#          it and the log says why;
#    run 5 -NoCorrelate -> it stays gone.
#
# B. the count cap (four leaks named at once, -MaxPromotedRoots 2):
#    run 2 must keep only two and say it dropped the rest;
#    run 3 must still measure exactly two.
$ErrorActionPreference = 'Stop'
$watch = (Join-Path $PSScriptRoot 'c-space-watch.ps1')
$stamp = Get-Date -Format 'HHmmss'
$base = Join-Path $env:TEMP "csw-bound-$stamp"
$state = Join-Path $env:TEMP "csw-bound-state-$stamp"
$statePath = Join-Path $state 'c-space-state.json'
$logPath = Join-Path $state 'c-space-watch.log'
$alertPath = Join-Path $state 'C-SPACE-ALERT.txt'
New-Item -ItemType Directory -Force -Path (Join-Path $base 'watched\keep') | Out-Null
Set-Content -LiteralPath (Join-Path $base 'watched\keep\file.txt') -Value 'steady' -Encoding ASCII

function Invoke-Watch([hashtable]$Opts = @{}, [string[]]$Switches = @()) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watch,
        '-NoToast', '-NoSweep', '-StateDir', $state,
        '-WatchRoot', (Join-Path $base 'watched\*'),
        '-CorrelateRoot', $base, '-TimeBudgetSeconds', '40',
        '-PromotedMaxRuns', '2')
    foreach ($s in $Switches) { $a += "-$s" }
    foreach ($k in $Opts.Keys) { $a += @("-$k", [string]$Opts[$k]) }
    return (& powershell.exe @a 2>&1 | Out-String)
}
function Log { if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Raw } else { '' } }
function LogLen { if (Test-Path -LiteralPath $logPath) { @(Get-Content -LiteralPath $logPath).Count } else { 0 } }
function Tail([int]$skip) { @(Get-Content -LiteralPath $logPath | Select-Object -Skip $skip) -join "`n" }
function State { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json }
function Promoted($s) { @($s.promoted | Where-Object { $_ } | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.path } }) }
function Runs($s, [string]$path) { @($s.promoted | Where-Object { $_ -and $_.path -eq $path } | ForEach-Object { [int]$_.runs }) }

# ---------------------------------------------------------------- A: expiry
$loose = Join-Path $base 'loose'
New-Item -ItemType Directory -Force -Path $loose | Out-Null
$looseFull = (Resolve-Path -LiteralPath $loose).Path

$null = Invoke-Watch
fsutil file createnew (Join-Path $loose 'a.bin') (600MB) | Out-Null
$null = Invoke-Watch -Switches @('Simulate')
$s2 = State
"run 2 promoted   : $(($(Promoted $s2) | ForEach-Object { Split-Path -Leaf $_ }) -join ', ') (runs $(Runs $s2 $looseFull))"

fsutil file createnew (Join-Path $loose 'b.bin') (300MB) | Out-Null
$len = LogLen
$null = Invoke-Watch -Opts @{ CorrelateMinGB = '0.1' } -Switches @('Simulate')
$log3 = Tail $len
$s3 = State
"run 3 runs       : $(Runs $s3 $looseFull)"
"run 3 sampled it : $([bool]($log3 -match 'grew:.*loose'))"

fsutil file createnew (Join-Path $loose 'c.bin') (300MB) | Out-Null
$len = LogLen
# -CorrelateMinGB high: no walk may re-promote it on the run that retires it.
$null = Invoke-Watch -Opts @{ CorrelateMinGB = '999' } -Switches @('Simulate')
$log4 = Tail $len
$s4 = State
$alert4 = if (Test-Path -LiteralPath $alertPath) { Get-Content -LiteralPath $alertPath -Raw } else { '' }
"run 4 promoted   : $((Promoted $s4).Count)"
"run 4 expired    : $([bool]($log4 -match 'promotion expired after 2 run\(s\), not sampled again for 6 h: .*loose'))"

$len = LogLen
$null = Invoke-Watch -Opts @{} -Switches @('Simulate', 'NoCorrelate')
$log5 = Tail $len
$s5 = State
"run 5 promoted   : $((Promoted $s5).Count)"
"run 5 measured it: $([bool]($log5 -match 'grew:.*loose'))"

# ---------------------------------------------------------------- B: the count cap
$base2 = Join-Path $env:TEMP "csw-bound-cap-$stamp"
$state2 = Join-Path $env:TEMP "csw-bound-cap-state-$stamp"
$statePath = Join-Path $state2 'c-space-state.json'
$logPath = Join-Path $state2 'c-space-watch.log'
$alertPath = Join-Path $state2 'C-SPACE-ALERT.txt'
New-Item -ItemType Directory -Force -Path (Join-Path $base2 'watched\keep') | Out-Null
Set-Content -LiteralPath (Join-Path $base2 'watched\keep\file.txt') -Value 'steady' -Encoding ASCII
$leaks = @()
foreach ($n in 1..4) {
    $d = Join-Path $base2 "leak$n"
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    $leaks += (Resolve-Path -LiteralPath $d).Path
}

function Invoke-Cap([hashtable]$Opts = @{}, [string[]]$Switches = @()) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watch,
        '-NoToast', '-NoSweep', '-StateDir', $state2,
        '-WatchRoot', (Join-Path $base2 'watched\*'),
        '-CorrelateRoot', $base2, '-TimeBudgetSeconds', '40',
        '-MaxPromotedRoots', '2', '-Top', '4')
    foreach ($s in $Switches) { $a += "-$s" }
    foreach ($k in $Opts.Keys) { $a += @("-$k", [string]$Opts[$k]) }
    return (& powershell.exe @a 2>&1 | Out-String)
}

$null = Invoke-Cap
foreach ($d in $leaks) { fsutil file createnew (Join-Path $d 'blob.bin') (400MB) | Out-Null }
$len = LogLen
$null = Invoke-Cap -Opts @{ CorrelateMinGB = '0.1' } -Switches @('Simulate')
$logCap = Tail $len
$sCap = State
$alertCap = if (Test-Path -LiteralPath $alertPath) { Get-Content -LiteralPath $alertPath -Raw } else { '' }
"cap promoted     : $((Promoted $sCap).Count) of $($leaks.Count) named"
"cap reported     : $([bool]($logCap -match 'promotion cap of 2 reached, not sampled this run'))"

# The two kept roots must still be growing for the carry rule to keep them; no walk
# is allowed, so the two the cap dropped cannot come back in this run.
foreach ($d in $leaks) { fsutil file createnew (Join-Path $d 'more.bin') (200MB) | Out-Null }
$len = LogLen
$null = Invoke-Cap -Opts @{ CorrelateMinGB = '999' } -Switches @('Simulate')
$logCap2 = Tail $len
$sCap2 = State
"cap after 1 run  : $((Promoted $sCap2).Count)"
"cap sampled two  : $((@($sCap2.paths.PSObject.Properties.Name) | Where-Object { $_ -like "$base2\leak*" }).Count)"

$fail = @()
# A
if (-not (@(Promoted $s2) -contains $looseFull)) { $fail += 'run 2 did not promote the directory the walk named' }
if ((Runs $s2 $looseFull) -ne 0) { $fail += "a fresh promotion already counts a sample (runs=$(Runs $s2 $looseFull))" }
if ((Runs $s3 $looseFull) -ne 1) { $fail += "run 3 did not record one spent sample (got $(Runs $s3 $looseFull))" }
if ($log3 -notmatch 'grew:.*loose') { $fail += 'run 3 did not sample the promoted root (test proves nothing about expiry)' }
if ((Promoted $s4).Count -ne 0) { $fail += 'the promotion outlived -PromotedMaxRuns' }
# The wording carries the cooldown as well now: an expiry that said only "no longer
# sampled" would leave a reader expecting it back next run.
if ($log4 -notmatch 'promotion expired after 2 run\(s\), not sampled again for 6 h: .*loose') { $fail += 'the log does not say the promotion expired and is cooling, or does not name it' }
if ($alert4 -match 'promoted\s+:') { $fail += 'the alert still promises to measure an expired root' }
if ((Promoted $s5).Count -ne 0) { $fail += 'the expired promotion came back without a correlation' }
if ($log5 -match 'grew:.*loose') { $fail += 'run 5 still sampled an expired promotion' }
# B
if ((Promoted $sCap).Count -ne 2) { $fail += "the state kept $((Promoted $sCap).Count) of 4 named roots, not 2" }
if ($logCap -notmatch 'promotion cap of 2 reached, not sampled this run') { $fail += 'the log does not report the cap trimming the list' }
if ($alertCap -notmatch 'not sampled : .*promotion cap 2') { $fail += 'the alert does not report the roots the cap left unsampled' }
if ((Promoted $sCap2).Count -ne 2) { $fail += "run 3 carried $((Promoted $sCap2).Count) promoted roots past the cap" }
if ((@($sCap2.paths.PSObject.Properties.Name) | Where-Object { $_ -like "$base2\leak*" }).Count -gt 2) { $fail += 'run 3 measured more than two promoted roots' }

"---"
if ($fail.Count -gt 0) {
    $fail | ForEach-Object { "FAIL: $_" }
    "run 3 log:"; $log3
    "run 4 log:"; $log4
    "cap log:"; $logCap
    exit 1
}
Remove-Item -LiteralPath $base, $state, $base2, $state2 -Recurse -Force -ErrorAction SilentlyContinue
'PASS'
