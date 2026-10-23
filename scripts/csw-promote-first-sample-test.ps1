# csw-promote-first-sample-test.ps1 -- a run with no state behind it must not pretend to
# have a baseline, and must not promote anything from one.
#
# The state directory is NOT created before run 1: the script has to make it, and it has
# to treat the missing state file as the first sample rather than as an error.
#   run 1  fresh state, -Simulate (a healthy drive only reaches the alert that way). It
#          must say "no previous sample", explain its empty cache and growth sections as
#          a first sample, carry no promotion lines, and write a state with empty
#          promoted/cooldown/history but with the history policy in force.
#   run 2  600 MB lands in an UNWATCHED sibling. Only now can a drop be measured, so this
#          is the first promotion the state has ever held -- and the first-timer must not
#          be called a repeat offender.
#   run 3  another 300 MB there: the promotion from run 2 is what measures it, proving the
#          first sample's baseline is the thing the whole chain rests on.
$ErrorActionPreference = 'Stop'
$watch = (Join-Path $PSScriptRoot 'c-space-watch.ps1')
$stamp = Get-Date -Format 'HHmmss'
$base = Join-Path $env:TEMP "csw-first-$stamp"
$watched = Join-Path $base 'watched'
$loose = Join-Path $base 'loose'
$state = Join-Path $base 'state'
$logPath = Join-Path $state 'c-space-watch.log'
$statePath = Join-Path $state 'c-space-state.json'
$alertPath = Join-Path $state 'C-SPACE-ALERT.txt'
New-Item -ItemType Directory -Force -Path (Join-Path $watched 'keep'), $loose | Out-Null
Set-Content -LiteralPath (Join-Path $watched 'keep\file.txt') -Value 'steady' -Encoding ASCII
$watchedFull = (Resolve-Path -LiteralPath (Join-Path $watched 'keep')).Path
$looseFull = (Resolve-Path -LiteralPath $loose).Path
$stateExistedBefore = Test-Path -LiteralPath $state
$stateJsonBefore = Test-Path -LiteralPath $statePath

function Invoke-Watch([string[]]$Switches = @('-Simulate')) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watch,
        '-NoToast', '-NoSweep', '-StateDir', $state,
        '-WatchRoot', (Join-Path $watched '*'),
        '-CorrelateRoot', $base,
        '-TimeBudgetSeconds', '40')
    foreach ($s in $Switches) { $a += $s }
    return (& powershell.exe @a 2>&1 | Out-String)
}
function Log { if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Raw } else { '' } }
function Alert { if (Test-Path -LiteralPath $alertPath) { Get-Content -LiteralPath $alertPath -Raw } else { '' } }
function State { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json }
function Tail([int]$skip) { @(Get-Content -LiteralPath $logPath | Select-Object -Skip $skip) -join "`n" }
function Promoted($s) { @($s.promoted | Where-Object { $_ } | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.path } }) }
# Wrapped at the call site: a one-element array unrolls on return, and then .Count is
# whatever the object happens to expose rather than the number of entries.
function HistoryEntry($s, [string]$path) { @($s.history) | Where-Object { $_ -and $_.path -eq $path } }

"state fresh      : dir exists=$stateExistedBefore file exists=$stateJsonBefore"
if ($stateExistedBefore -or $stateJsonBefore) { throw 'the fixture is not a fresh state' }

# --- run 1: the first sample
$null = Invoke-Watch
$log1 = Log
$alert1 = Alert
$s1 = State
"run 1 log first  : $([bool]($log1 -match 'first sample -- growth ranking starts with the next run'))"
"run 1 no growth  : $(-not ($log1 -match '  grew:'))"
"run 1 no walk    : $(-not ($log1 -match 'written:|next run also measures'))"
"run 1 alert      : change=$([bool]($alert1 -match 'change      : no previous sample')) why=$([bool]($alert1 -match 'why         : simulated'))"
"run 1 alert cache: $([bool]($alert1 -match 'cleared     : nothing -- this is the first sample'))"
"run 1 alert grow : $([bool]($alert1 -match '\(none -- this is the first sample'))"
"run 1 alert prom : $(-not ($alert1 -match 'promoted    :|repeat      :|cooling     :|written in this window'))"
"run 1 alert adv  : $([bool]($alert1 -match 'what to do: this is the first sample'))"
"run 1 why no fall: $(-not ((($alert1 -split \"`n\") | Where-Object { $_ -match '^why ' }) -join '') -match 'fell'))"
"run 1 state      : promoted=$(@($s1.promoted).Count) cooldown=$(@($s1.cooldown).Count) history=$(@($s1.history).Count)"
"run 1 policy     : max=$($s1.historyPolicy.maxEntries) days=$($s1.historyPolicy.forgetAfterDays) cutoff=$([bool]$s1.historyPolicy.forgetBefore)"
"run 1 measured   : $([bool]($s1.paths.PSObject.Properties.Name -contains $watchedFull))"
"run 1 sampledAt  : $([bool]([datetime]$s1.sampledAt))"

# --- run 2: the leak, and the first promotion this state has ever held
fsutil file createnew (Join-Path $loose 'a.bin') (600MB) | Out-Null
$len = (Get-Content -LiteralPath $logPath).Count
$null = Invoke-Watch
$log2 = Tail $len
$alert2 = Alert
$s2 = State
$h2 = @(HistoryEntry $s2 $looseFull)
"run 2 walked     : $([bool]($log2 -match 'written:.*loose'))"
"run 2 promoted   : $([bool](Promoted $s2 -contains $looseFull))"
"run 2 log note   : $([bool]($log2 -match 'next run also measures.*loose'))"
"run 2 not repeat : $(-not ($log2 -match 'repeat promotion'))"
"run 2 history    : count=$($h2.Count) promoted=$($h2[0].promoted) cooled=$($h2[0].cooled) expires=$([bool]$h2[0].expiresAt)"
"run 2 alert prom : $([bool]($alert2 -match 'promoted    : .*loose'))"

# --- run 3: the promotion is what measures the next growth
fsutil file createnew (Join-Path $loose 'b.bin') (300MB) | Out-Null
$len = (Get-Content -LiteralPath $logPath).Count
$null = Invoke-Watch
$log3 = Tail $len
$s3 = State
$h3 = @(HistoryEntry $s3 $looseFull)
"run 3 no walk    : $(-not ($log3 -match 'written:'))"
"run 3 ranked     : $([bool]($log3 -match 'grew:.*loose'))"
"run 3 measured   : $([bool]($s3.paths.PSObject.Properties.Name -contains $looseFull))"
"run 3 counts kept: promoted=$($h3[0].promoted) cooled=$($h3[0].cooled)"

$fail = @()
# run 1 -- the first sample says so everywhere it has to, and promotes nothing
if ($log1 -notmatch 'first sample -- growth ranking starts with the next run') { $fail += 'run 1 log does not mark the first sample' }
if ($log1 -match '  grew:') { $fail += 'run 1 ranked growth against a baseline it does not have' }
if ($log1 -match 'written:|next run also measures') { $fail += 'run 1 walked or promoted with no previous sample' }
if ($alert1 -notmatch 'change      : no previous sample') { $fail += 'run 1 alert does not say there is no previous sample' }
if ($alert1 -notmatch 'why         : simulated') { $fail += 'run 1 alert does not report its reason' }
if ($alert1 -match '^why .*fell') { $fail += 'run 1 alert invents a fall with no previous sample to fall from' }
if ($alert1 -notmatch 'cleared     : nothing -- this is the first sample') { $fail += 'run 1 alert does not explain its empty cache section' }
if ($alert1 -notmatch '\(none -- this is the first sample') { $fail += 'run 1 alert does not explain its empty growth section' }
if ($alert1 -match 'promoted    :|repeat      :|cooling     :|written in this window') { $fail += 'run 1 alert claims a promotion or a walk it did not do' }
if ($alert1 -notmatch 'what to do: this is the first sample') { $fail += 'run 1 alert does not give first-sample advice' }
if ($alert1 -match 'nothing grew enough to name') { $fail += 'run 1 alert claims nothing grew against a baseline it does not have' }
if (@($s1.promoted).Count -ne 0) { $fail += 'run 1 wrote a promoted root' }
if (@($s1.cooldown).Count -ne 0) { $fail += 'run 1 wrote a cooldown' }
if (@($s1.history).Count -ne 0) { $fail += 'run 1 wrote promotion history' }
if ($s1.historyPolicy.maxEntries -ne 64 -or $s1.historyPolicy.forgetAfterDays -ne 30) { $fail += 'run 1 state does not record the history policy' }
if (-not $s1.historyPolicy.forgetBefore) { $fail += 'run 1 state has no aging cutoff' }
if (-not ($s1.paths.PSObject.Properties.Name -contains $watchedFull)) { $fail += 'run 1 did not measure its watched root' }
if (-not $s1.sampledAt) { $fail += 'run 1 wrote no sampledAt, so run 2 has nothing to compare against' }
# run 2 -- the first promotion, counted as one
if ($log2 -notmatch 'written:.*loose') { $fail += 'run 2 did not walk for the drop the first sample makes measurable' }
if (-not ((Promoted $s2) -contains $looseFull)) { $fail += 'run 2 did not promote the directory it named' }
if ($log2 -notmatch 'next run also measures.*loose') { $fail += 'run 2 log does not say what it will measure next' }
if ($log2 -match 'repeat promotion') { $fail += 'run 2 called a first-time directory a repeat offender' }
if ($h2.Count -ne 1) { $fail += "run 2 wrote $($h2.Count) history entries for the promoted directory, not 1" }
else {
    if ($h2[0].promoted -ne 1) { $fail += "run 2 history says promoted=$($h2[0].promoted), not 1" }
    if ($h2[0].cooled -ne 0) { $fail += "run 2 history says cooled=$($h2[0].cooled), not 0" }
    if (-not $h2[0].expiresAt) { $fail += 'run 2 history entry has no expiry' }
}
if ($alert2 -notmatch 'promoted    : .*loose') { $fail += 'run 2 alert does not say what it will measure next' }
# run 3 -- the chain holds
if ($log3 -match 'written:') { $fail += 'run 3 walked again instead of using the promotion' }
if ($log3 -notmatch 'grew:.*loose') { $fail += 'run 3 did not rank the promoted root' }
if (-not ($s3.paths.PSObject.Properties.Name -contains $looseFull)) { $fail += 'run 3 did not measure the promoted root' }
if ($h3.Count -ne 1 -or $h3[0].promoted -ne 1 -or $h3[0].cooled -ne 0) { $fail += 'run 3 changed counts that belong to run 2' }

'---'
if ($fail.Count -gt 0) {
    "run 1 alert:"
    $alert1
    $fail | ForEach-Object { "FAIL: $_" }
    exit 1
}
Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
'PASS'
