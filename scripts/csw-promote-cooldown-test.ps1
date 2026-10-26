# csw-promote-cooldown-test.ps1 -- an expired promotion cannot be re-promoted at once.
#
# One throwaway tree under %TEMP%: watched\keep is steady, loose\ is nobody's watch root
# and is the "churning cache" -- it grows by 32 MB before every run, so each walk names
# it again. The state's own promoted entry therefore has to do the refusing.
#
#   run 1  baseline
#   32 MB -> run 2  the walk names loose; promoted (runs 0, not measured yet)
#   +32   -> run 3  carried, measured, runs 1
#   +32   -> run 4  -PromotedMaxRuns 2: expired, and put on a 6 h cooldown
#   +32   -> run 5  the walk names it again: must NOT be re-promoted (the old bug),
#                   must be reported as cooling, must not be measured
#   +32   -> run 6  -PromotionCooldownHours 0: the cooldown is off, so promoted again
#   +32   -> run 7  carried once
#   +32   -> run 8  expired again, fresh cooldown
#   +32   -> run 9  cooldown's `until` backdated: promotable again, entry cleared
#   +32   -> run 10 history's `seenAt` backdated 40 days: the counts have aged out,
#                   so the walk naming it again is a new finding, not a repeat -- and
#                   the log says the history forgot it
#   +32   -> run 11 the same backdated entry with -PromotionHistoryDays 0: nothing
#                   ages, so it IS a repeat. Proves the aging, not the fixture.
#
# Every run is -Simulate (so a walk is always allowed) with -CorrelateMinGB 0.1 over the
# test's own small parent directory, and -NoSweep so no sandbox or collector is involved.
#
# The walk is triggered by the fall since the previous sample, and the watcher reads that
# fall from the previous sample's free bytes. Racing the host for that number is what made
# this suite flaky: it runs on the drive it watches, so anything else freeing space in the
# window -- the installed watcher clearing a cache, a build's temp files -- can cancel the
# small fall the test's own growth makes, the walk never runs, and the run that should have
# promoted is just an ordinary sample. The fall is therefore stated rather than raced: Invoke-Watch records the
# previous sample as having seen the whole volume free before each run. That is the only
# fall another process cannot cancel, because free space cannot exceed the volume: whatever
# else is freed can only add to it. A smaller, plausible bump was tried first and is not
# enough -- one cache clear or one finished build frees more than any fixed number the test
# could pick. This is also why the grow can be 32 MB and not 600 MB: the planted file only
# has to clear -CorrelateMinMB (set to 8 MB below) and the 1 MB growth bar, and 6.6 GB of
# churn over eleven runs on the drive being watched was a hazard of its own -- it walked the
# very volume toward the floor the watcher is there to warn about.
#
# The two clock checks ("6 h left", and the minutes in "1 h 30 min left") are computed
# from the summary timestamp of the run that wrote them, not from the test's clock after
# the process exits: every "time left" is counted from that instant, so a stalled machine
# changes the number the log is checked against instead of failing the run.
$ErrorActionPreference = 'Stop'
$watch = (Join-Path $PSScriptRoot 'c-space-watch.ps1')
$stamp = Get-Date -Format 'HHmmss'
$parent = Join-Path $env:TEMP "csw-cool-$stamp"
$watched = Join-Path $parent 'watched'
$keep = Join-Path $watched 'keep'
$loose = Join-Path $parent 'loose'
$state = Join-Path $parent 'state'
$logPath = Join-Path $state 'c-space-watch.log'
$statePath = Join-Path $state 'c-space-state.json'
$alertPath = Join-Path $state 'C-SPACE-ALERT.txt'
# 4x the -CorrelateMinMB bar below: the walk names a directory by what was written in it
# during the window, so the file has to be comfortably larger than the threshold or the
# promotion on run 2 depends on how the walk rounds.
$GrowBytes = 32MB
New-Item -ItemType Directory -Force -Path $keep, $loose, $state | Out-Null
Set-Content -LiteralPath (Join-Path $keep 'file.txt') -Value 'steady' -Encoding ASCII
$looseFull = (Resolve-Path -LiteralPath $loose).Path
# The ceiling for a stated fall: free bytes can never exceed the volume's own size.
$script:VolumeSize = [long]0
try { $script:VolumeSize = [long](Get-Volume -DriveLetter C -ErrorAction Stop).Size } catch { }

function Bump-FreeSpace {
    # The watcher walks only when the fall since the last sample is more than the measured
    # roots explain, and "the fall" is the difference between the previous sample's
    # freeBytes and this one's reading. Recording the previous sample as having seen the
    # whole volume free makes that fall as large as it can possibly be, so no concurrent
    # deletion can cancel it. The figure it produces is the volume size minus the real
    # reading; the suite asserts nothing about it.
    # The watcher overwrites freeBytes with the real reading, so this is a per-run
    # statement, not an accumulating lie.
    if (-not (Test-Path -LiteralPath $statePath)) { return }
    $r = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ($null -eq $r.freeBytes) { return }
    $r.freeBytes = if ($script:VolumeSize -gt 0) { [long]$script:VolumeSize } else { [long]$r.freeBytes + 8GB }
    [System.IO.File]::WriteAllText($statePath, ($r | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-Watch([hashtable]$Opts = @{}, [string[]]$Switches = @()) {
    Bump-FreeSpace
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watch,
        '-NoToast', '-NoSweep', '-StateDir', $state,
        '-WatchRoot', (Join-Path $watched '*'), '-CorrelateRoot', $parent,
        '-CorrelateMinGB', '0.1', '-CorrelateMinMB', '8', '-Top', '3',
        '-TimeBudgetSeconds', '40', '-PromotedMaxRuns', '2', '-MaxPromotedRoots', '4')
    foreach ($s in $Switches) { $a += "-$s" }
    foreach ($k in $Opts.Keys) { $a += @("-$k", [string]$Opts[$k]) }
    return (& powershell.exe @a 2>&1 | Out-String)
}
function LogLen { if (Test-Path -LiteralPath $logPath) { @(Get-Content -LiteralPath $logPath).Count } else { 0 } }
function LogTail([int]$skip) { @(Get-Content -LiteralPath $logPath | Select-Object -Skip $skip) -join "`n" }
function State { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json }
function Promoted($s) { @($s.promoted | Where-Object { $_ } | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.path } }) }
function Runs($s, [string]$p) { $e = @($s.promoted | Where-Object { $_ -and $_ -isnot [string] -and $_.path -eq $p }); if ($e.Count) { [int]$e[0].runs } else { -1 } }
function Cooled($s) { @($s.cooldown | Where-Object { $_ } | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.path } }) }
function CooledUntil($s, [string]$p) { $e = @($s.cooldown | Where-Object { $_ -and $_ -isnot [string] -and $_.path -eq $p }); if ($e.Count) { [datetime]$e[0].until } else { $null } }
function Hist($s, [string]$p) { $e = @($s.history | Where-Object { $_ -and $_.path -eq $p }); if ($e.Count) { $e[0] } else { $null } }
function HistText($s) { $h = Hist $s $looseFull; if ($h) { "promoted=$($h.promoted) cooled=$($h.cooled)" } else { '(none)' } }
function Grow { fsutil file createnew (Join-Path $loose ((New-Guid).ToString('N') + '.bin')) $GrowBytes | Out-Null }
function Sample-Time([string]$log) {
    # The run's own clock, from the summary line it writes: every "time left" in the log
    # and the alert is counted from this instant, so the expected wording has to be too.
    $m = [regex]::Match($log, '(?m)^\uFEFF?(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)  ')
    if (-not $m.Success) { return $null }
    return [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss',
        [System.Globalization.CultureInfo]::InvariantCulture)
}
function Cooldown-Left([datetime]$Until, [datetime]$At) {
    # The same arithmetic the watcher's Format-CooldownLeft does. Duplicating it is the
    # point: the expectation is what the reader should see for the time that was actually
    # left, so a rounding or unit mistake still fails, while a slow start no longer does.
    $minutes = [int][math]::Ceiling(($Until - $At).TotalMinutes)
    if ($minutes -le 1) { return 'under a minute left' }
    $hours = [int][math]::Floor($minutes / 60)
    $rest = $minutes % 60
    if ($hours -le 0) { return "$minutes min left" }
    if ($rest -eq 0) { return "$hours h left" }
    return "$hours h $rest min left"
}

# --- run 1: baseline, no walk needed
$null = Invoke-Watch -Switches @('Simulate', 'NoCorrelate')

# --- run 2: the walk names the churning directory
Grow
$len = LogLen; $null = Invoke-Watch -Switches @('Simulate'); $log2 = LogTail $len; $s2 = State
"run 2 promoted : $((Promoted $s2).Count) runs=$((Runs $s2 $looseFull)) history=$(HistText $s2)"
"run 2 repeat   : alert=$([bool]((Get-Content -LiteralPath $alertPath -Raw) -match 'repeat\s+:'))"

# --- run 3: carried and measured once
Grow
$len = LogLen; $null = Invoke-Watch -Switches @('Simulate'); $log3 = LogTail $len; $s3 = State
"run 3 carried  : $((Promoted $s3).Count) runs=$((Runs $s3 $looseFull)) walked=$([bool]($log3 -match 'written:'))"

# --- run 4: out of runs -> expired and cooled
Grow
$len = LogLen; $null = Invoke-Watch -Switches @('Simulate'); $log4 = LogTail $len; $s4 = State
$until4 = CooledUntil $s4 $looseFull
$at4 = Sample-Time $log4
$left4 = if ($until4 -and $at4) { [math]::Round(($until4 - $at4).TotalHours, 2) } else { -1 }
"run 4 expired  : promoted=$((Promoted $s4).Count) cooled=$((Cooled $s4).Count) until=+$left4 h history=$(HistText $s4)"
"run 4 log      : $([bool]($log4 -match 'expired after 2 run\(s\), not sampled again for 6 h'))"

# --- run 5: named again, must stay out
# The cooldown is shortened to 90 minutes first, so the remaining-time wording has to
# use minutes and not just a whole number of hours.
$until5 = (Get-Date).AddMinutes(90)
$raw5 = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
foreach ($c in @($raw5.cooldown)) { if ($c.path -eq $looseFull) { $c.until = $until5.ToString('o') } }
[System.IO.File]::WriteAllText($statePath, ($raw5 | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
Grow
$len = LogLen; $null = Invoke-Watch -Switches @('Simulate'); $log5 = LogTail $len; $s5 = State
$alert5 = if (Test-Path -LiteralPath $alertPath) { Get-Content -LiteralPath $alertPath -Raw } else { '' }
$at5 = Sample-Time $log5
$left5 = if ($at5) { Cooldown-Left $until5 $at5 } else { $null }
"run 5 walked   : $([bool]($log5 -match 'written:.*loose'))  promoted=$((Promoted $s5).Count)  measured=$([bool]($s5.paths.PSObject.Properties.Name -contains $looseFull))"
"run 5 left     : $left5  (at $($at5.ToString('HH:mm:ss')))"
"run 5 cooling  : log=$([bool]($log5 -match ('promotion cooling, named again but not re-promoted: .*\(' + [regex]::Escape($left5) + '; promoted 1x, cooled 1x\)'))) alert=$([bool]($alert5 -match ('cooling\s+: .*loose \(' + [regex]::Escape($left5) + '; promoted 1x, cooled 1x\)')))"

# --- run 6: the cooldown switched off
Grow
$len = LogLen; $null = Invoke-Watch -Opts @{ PromotionCooldownHours = '0' } -Switches @('Simulate'); $log6 = LogTail $len; $s6 = State
$alert6 = if (Test-Path -LiteralPath $alertPath) { Get-Content -LiteralPath $alertPath -Raw } else { '' }
"run 6 off      : promoted=$((Promoted $s6).Count) cooled=$((Cooled $s6).Count) first=$([bool]($log6 -match 'next run also measures')) history=$(HistText $s6)"
"run 6 repeat   : log=$([bool]($log6 -match 'repeat promotion, this directory has churned before: .*\(promoted 2x, cooled 1x\)')) alert=$([bool]($alert6 -match 'repeat\s+: .*loose \(promoted 2x, cooled 1x\)'))"

# --- run 7: carried once more
Grow
$null = Invoke-Watch -Switches @('Simulate'); $s7 = State
"run 7 carried  : runs=$((Runs $s7 $looseFull))"

# --- run 8: expired again
Grow
$len = LogLen; $null = Invoke-Watch -Switches @('Simulate'); $s8 = State
"run 8 expired  : promoted=$((Promoted $s8).Count) cooled=$((Cooled $s8).Count)"

# --- run 9: the cooldown has served its time
$raw = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
foreach ($c in @($raw.cooldown)) { if ($c.path -eq $looseFull) { $c.until = (Get-Date).AddMinutes(-1).ToString('o') } }
$json = $raw | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($statePath, $json, (New-Object System.Text.UTF8Encoding($false)))
Grow
$len = LogLen; $null = Invoke-Watch -Switches @('Simulate'); $log9 = LogTail $len; $s9 = State
"run 9 back     : promoted=$((Promoted $s9).Count) runs=$((Runs $s9 $looseFull)) cooled=$((Cooled $s9).Count) recooled=$([bool]($log9 -match 'promotion cooling')) history=$(HistText $s9)"
"run 9 repeat   : log=$([bool]($log9 -match 'repeat promotion, this directory has churned before: .*\(promoted 3x, cooled 2x\)'))"

# --- a state with no promotion to explain the next drop, and a history that went quiet
# 40 days ago. Without that promotion the walk has to name the directory again.
function Age-History([int]$Days) {
    $r = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $r.promoted = @()
    $r.cooldown = @()
    foreach ($h in @($r.history)) { if ($h.path -eq $looseFull) { $h.seenAt = (Get-Date).AddDays(-$Days).ToString('o') } }
    [System.IO.File]::WriteAllText($statePath, ($r | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
}

# --- run 10: 40 days of quiet, the default 30-day history
Age-History 40
Grow
$len = LogLen; $null = Invoke-Watch -Switches @('Simulate'); $log10 = LogTail $len; $s10 = State
$alert10 = if (Test-Path -LiteralPath $alertPath) { Get-Content -LiteralPath $alertPath -Raw } else { '' }
"run 10 aged    : promoted=$((Promoted $s10).Count) history=$(HistText $s10)"
"run 10 repeat  : log=$([bool]($log10 -match 'repeat promotion')) alert=$([bool]($alert10 -match 'repeat\s+:')) forgot=$([bool]($log10 -match 'promotion history: forgot 1 directory not seen for 30\+ days'))"

# --- run 11: the same quiet history, aging switched off
Age-History 40
Grow
$len = LogLen; $null = Invoke-Watch -Opts @{ PromotionHistoryDays = '0' } -Switches @('Simulate'); $log11 = LogTail $len; $s11 = State
$alert11 = if (Test-Path -LiteralPath $alertPath) { Get-Content -LiteralPath $alertPath -Raw } else { '' }
"run 11 kept    : promoted=$((Promoted $s11).Count) history=$(HistText $s11)"
"run 11 repeat  : log=$([bool]($log11 -match 'repeat promotion, this directory has churned before: .*\(promoted 2x, cooled 0x\)')) alert=$([bool]($alert11 -match 'repeat\s+:')) forgot=$([bool]($log11 -match 'promotion history: forgot'))"

$fail = @()
if ((Promoted $s2).Count -ne 1 -or (Runs $s2 $looseFull) -ne 0) { $fail += 'run 2 did not promote the directory the walk named' }
if ((Promoted $s3).Count -ne 1 -or (Runs $s3 $looseFull) -ne 1) { $fail += 'run 3 did not carry the promotion forward, or miscounted its runs' }
if ((Promoted $s4).Count -ne 0) { $fail += 'run 4 kept a promotion that had spent its runs' }
# @() because a one-element array comes back from a function as a scalar, and indexing
# that gives the first character of the path.
if (@(Cooled $s4).Count -ne 1 -or @(Cooled $s4)[0] -ne $looseFull) { $fail += 'run 4 did not put the expired promotion on cooldown' }
if (-not $at4) { $fail += 'run 4 wrote no summary line, so its cooldown has no clock to be checked against' }
elseif ([math]::Abs($left4 - 6) -gt 0.02) { $fail += "the cooldown is not the default 6 h (saw +$left4 h at the sample)" }
if ($log4 -notmatch 'expired after 2 run\(s\), not sampled again for 6 h') { $fail += 'the log does not say the expiry is cooling, or for how long' }
if ((Promoted $s5).Count -ne 0) { $fail += 'a walk re-promoted a directory that was still cooling' }
if ($s5.paths.PSObject.Properties.Name -contains $looseFull) { $fail += 'a cooling directory was measured anyway' }
if (-not $at5) { $fail += 'run 5 wrote no summary line, so the time left has no clock to be checked against' }
elseif ($left5 -notmatch '^\d+ h \d+ min left$') { $fail += "the run sampled $left5 into the cooldown: too late to prove the minutes wording" }
if (-not $at5 -or $log5 -notmatch ('promotion cooling, named again but not re-promoted: .*\(' + [regex]::Escape($left5) + '; promoted 1x, cooled 1x\)')) { $fail += 'the log does not report the walk naming a cooling directory, or its time left and history' }
if (-not $at5 -or $alert5 -notmatch ('cooling\s+: .*loose \(' + [regex]::Escape($left5) + '; promoted 1x, cooled 1x\) -- named again, not re-promoted')) { $fail += 'the alert does not report the cooling directory with the time left and history' }
if ($alert5 -match 'until \d\d:\d\d') { $fail += 'the alert reports a clock time instead of the time left' }
if ((Promoted $s6).Count -ne 1 -or (Cooled $s6).Count -ne 0) { $fail += '-PromotionCooldownHours 0 did not disable the cooldown' }
if ((Runs $s7 $looseFull) -ne 1) { $fail += 'the re-promoted directory was not carried (runs should be 1)' }
if ((Promoted $s8).Count -ne 0 -or (Cooled $s8).Count -ne 1) { $fail += 'the second expiry did not cool the directory again' }
if ((Promoted $s9).Count -ne 1 -or (Runs $s9 $looseFull) -ne 0) { $fail += 'a served cooldown still blocked re-promotion' }
if ((Cooled $s9).Count -ne 0) { $fail += 'the served cooldown was not removed from the state' }
if ($log9 -match 'promotion cooling') { $fail += 'a served cooldown is still reported as cooling' }
# The history is the only thing that remembers a directory across its cooldowns, so the
# counts are checked at each stage rather than only at the end.
if ((HistText $s2) -ne 'promoted=1 cooled=0') { $fail += "the first promotion was not counted (saw $(HistText $s2))" }
if ($alert2 -match 'repeat\s+:') { $fail += 'a first promotion was reported as a repeat' }
if ((HistText $s4) -ne 'promoted=1 cooled=1') { $fail += "the cool-off was not counted (saw $(HistText $s4))" }
if ((HistText $s6) -ne 'promoted=2 cooled=1') { $fail += "the second promotion was not counted (saw $(HistText $s6))" }
if ($log6 -notmatch 'repeat promotion, this directory has churned before: .*\(promoted 2x, cooled 1x\)') { $fail += 'the log does not call the second promotion a repeat' }
if ($alert6 -notmatch 'repeat\s+: .*loose \(promoted 2x, cooled 1x\)') { $fail += 'the alert does not call the second promotion a repeat' }
if ((HistText $s9) -ne 'promoted=3 cooled=2') { $fail += "the third promotion and second cool-off were not counted (saw $(HistText $s9))" }
if ($log9 -notmatch 'repeat promotion, this directory has churned before: .*\(promoted 3x, cooled 2x\)') { $fail += 'the third promotion is not reported as a repeat' }
# Aging: an entry not seen churning for longer than -PromotionHistoryDays must not make
# a returning directory look like a repeat offender, and -PromotionHistoryDays 0 must
# keep it -- otherwise the first check could pass because the fixture failed to promote.
if ((HistText $s10) -ne 'promoted=1 cooled=0') { $fail += "a 40-day-old history entry was still counted (saw $(HistText $s10))" }
if ($log10 -match 'repeat promotion') { $fail += 'an aged-out history entry was reported as a repeat' }
if ($alert10 -match 'repeat\s+:') { $fail += 'the alert calls an aged-out history entry a repeat' }
if ($log10 -notmatch 'promotion history: forgot 1 directory not seen for 30\+ days') { $fail += 'the log does not say the history entry aged out' }
if ((HistText $s11) -ne 'promoted=2 cooled=0') { $fail += "-PromotionHistoryDays 0 did not keep the counts (saw $(HistText $s11))" }
if ($log11 -notmatch 'repeat promotion, this directory has churned before: .*\(promoted 2x, cooled 0x\)') { $fail += 'with aging off the kept history entry is not reported as a repeat' }
if ($alert11 -notmatch 'repeat\s+: .*loose \(promoted 2x, cooled 0x\)') { $fail += 'the alert does not carry the kept history counts' }
if ($log11 -match 'promotion history: forgot') { $fail += 'aging was off and the history was forgotten anyway' }

"---"
if ($fail.Count -gt 0) {
    "state (kept at $state):"
    Get-Content -LiteralPath $statePath -Raw
    $fail | ForEach-Object { "FAIL: $_" }
    exit 1
}
Remove-Item -LiteralPath $parent -Recurse -Force -ErrorAction SilentlyContinue
'PASS'
