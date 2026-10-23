# csw-promote-test.ps1 -- what the correlation names is watched from then on.
#
# Four runs against a throwaway tree under %TEMP%:
#   run 1  baseline over a watched root that holds one quiet directory;
#   leak   600 MB lands in an UNWATCHED sibling (that is the fall the roots cannot
#          explain), so:
#   run 2  must fall back to the windowed walk, name the sibling, and record it as a
#          promoted root for the next run -- but must NOT have measured it this run;
#   run 3  another 600 MB into the same sibling: the promoted root explains the drop,
#          so the walk must not run at all and the growth ranking must name it;
#   run 4  nothing new: the promotion must drop out instead of being carried forever.
#
# -CorrelateRoot is the test's own parent directory and -CorrelateMinMB stays at its
# default, so the walk is the real one, just aimed at a tree small enough to finish.
$ErrorActionPreference = 'Stop'
$watch = (Join-Path $PSScriptRoot 'c-space-watch.ps1')
$stamp = Get-Date -Format 'HHmmss'
$base = Join-Path $env:TEMP "csw-promote-$stamp"
$watched = Join-Path $base 'watched'
$loose = Join-Path $base 'loose'
$state = Join-Path $env:TEMP "csw-promote-state-$stamp"
$logPath = Join-Path $state 'c-space-watch.log'
$statePath = Join-Path $state 'c-space-state.json'
New-Item -ItemType Directory -Force -Path (Join-Path $watched 'keep'), $loose | Out-Null
Set-Content -LiteralPath (Join-Path $watched 'keep\file.txt') -Value 'steady' -Encoding ASCII
$looseFull = (Resolve-Path -LiteralPath $loose).Path

function Invoke-Watch([switch]$Simulate) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watch,
        '-NoToast', '-NoSweep', '-StateDir', $state,
        '-WatchRoot', (Join-Path $watched '*'),
        '-CorrelateRoot', $base,
        '-TimeBudgetSeconds', '40')
    if ($Simulate) { $a += '-Simulate' }
    return (& powershell.exe @a 2>&1 | Out-String)
}
function Log { if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Raw } else { '' } }
function State { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json }
function Promoted($s) { @($s.promoted | Where-Object { $_ } | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.path } }) }
function Tail([int]$skip) { @(Get-Content -LiteralPath $logPath | Select-Object -Skip $skip) -join "`n" }

# --- run 1: baseline
$null = Invoke-Watch
$state1 = State
"run 1 sampled    : $((@($state1.paths.PSObject.Properties) | ForEach-Object { Split-Path -Leaf $_.Name }) -join ', ')"

# --- the leak, in a directory nobody is watching
fsutil file createnew (Join-Path $loose 'a.bin') (600MB) | Out-Null

# --- run 2: the walk names it and hands it to the next run
$len = (Get-Content -LiteralPath $logPath).Count
$null = Invoke-Watch -Simulate
$log2 = Tail $len
$state2 = State
$promoted2 = Promoted $state2
"run 2 named      : $([bool]($log2 -match 'written:'))"
"run 2 promoted   : $(($promoted2 | ForEach-Object { Split-Path -Leaf $_ }) -join ', ')"
"run 2 promoted log: $((($log2 -split "`n") | Where-Object { $_ -match 'next run also measures' }) -join '')"
"run 2 measured it: $([bool]($state2.paths.PSObject.Properties.Name -contains $looseFull))"

# --- run 3: the promotion does the work, no walk
fsutil file createnew (Join-Path $loose 'b.bin') (600MB) | Out-Null
$len = (Get-Content -LiteralPath $logPath).Count
$null = Invoke-Watch -Simulate
$log3 = Tail $len
$state3 = State
"run 3 walked     : $([bool]($log3 -match 'written:|\bfell, .* written'))"
"run 3 ranked     : $([bool]($log3 -match 'grew:.*loose'))"
"run 3 measured it: $([bool]($state3.paths.PSObject.Properties.Name -contains $looseFull))"
"run 3 promoted   : $((Promoted $state3).Count)"
$grewLine = (($log3 -split "`n") | Where-Object { $_ -match 'grew:.*loose' } | Select-Object -First 1)
$delta = if ($grewLine -match '([\d.]+) GB\s+.*loose') { [double]$Matches[1] } else { 0 }
"run 3 delta      : $delta GB since promotion (not the whole directory)"
$alert3 = if (Test-Path -LiteralPath (Join-Path $state 'C-SPACE-ALERT.txt')) { Get-Content -LiteralPath (Join-Path $state 'C-SPACE-ALERT.txt') -Raw } else { '' }
"alert names it   : $([bool]($alert3 -match 'promoted\s+:'))"

# --- run 4: nothing new, the promotion goes
$len = (Get-Content -LiteralPath $logPath).Count
$null = Invoke-Watch -Simulate
$state4 = State
"run 4 promoted   : $((Promoted $state4).Count)"

$fail = @()
if (-not ($log2 -match 'written:')) { $fail += 'run 2 did not fall back to the walk' }
if (-not ($promoted2 -contains $looseFull)) { $fail += "run 2 did not promote $looseFull" }
if ($log2 -notmatch 'next run also measures') { $fail += 'run 2 log does not say what it will measure next' }
if ($state2.paths.PSObject.Properties.Name -contains $looseFull) { $fail += 'run 2 measured the promoted root in the same run (it is for the NEXT run)' }
if ($log3 -match 'written:') { $fail += 'run 3 walked the profile again instead of using the promotion' }
if (-not ($log3 -match 'grew:.*loose')) { $fail += 'run 3 did not rank the promoted root' }
if (-not ($state3.paths.PSObject.Properties.Name -contains $looseFull)) { $fail += 'run 3 did not measure the promoted root' }
if ((Promoted $state3).Count -eq 0) { $fail += 'the promotion was not carried while the directory kept growing' }
if ((Promoted $state4).Count -ne 0) { $fail += 'the promotion outlived the directory growing' }
if ($delta -lt 0.5 -or $delta -gt 0.8) { $fail += "the promoted root's growth is not measured from its promotion baseline (saw $delta GB for a 0.59 GB write)" }
if ($alert3 -notmatch 'promoted\s+:') { $fail += 'the alert does not say what the next run will measure' }

"---"
if ($fail.Count -gt 0) { $fail | ForEach-Object { "FAIL: $_" }; Remove-Item -LiteralPath $base, $state -Recurse -Force -ErrorAction SilentlyContinue; exit 1 }
'PASS'
Remove-Item -LiteralPath $base, $state -Recurse -Force -ErrorAction SilentlyContinue
