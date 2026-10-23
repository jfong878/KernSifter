# csw-grower-action-test.ps1 -- the top grower is cleared by the REHEARSAL'S collector.
#
# Four runs of the watchdog against a throwaway scratch root under %TEMP%:
#   run 1  baseline sample (no previous state, so nothing is ranked);
#   grow   one dead-owner sandbox by 400 MB;
#   run 2  must name it as the top grower, have the real `--sweep` collector clear it,
#          and re-read free space;
#   run 3  the same shape with -NoSweep: the collector must not be invoked at all;
#   run 4  a sandbox is the top grower but -RehearsalCli points at nothing: NOTHING may
#          be deleted. That is what pins "the watchdog has no delete of its own" -- if
#          the old in-process path were still there, this run would clear the sandbox.
#
# -SandboxRoot is pointed at an EMPTY root on purpose: the pre-sample sweep must not be
# what removes the sandbox, or this would pass on the old code. The only deleter left is
# the collector, and the journal says which one acted: the collector's event carries no
# `by` field, the watchdog's own sweep event carries by = c-space-watch.
$ErrorActionPreference = 'Stop'
$watch = (Join-Path $PSScriptRoot 'c-space-watch.ps1')
$stamp = Get-Date -Format 'HHmmss'
$sandboxRoot = Join-Path $env:TEMP "csw-grower-test-$stamp"
$sweepRoot = Join-Path $env:TEMP "csw-grower-sweeproot-$stamp"
$state = Join-Path $env:TEMP "csw-grower-state-$stamp"
$logPath = Join-Path $state 'c-space-watch.log'
$alertFile = Join-Path $state 'C-SPACE-ALERT.txt'
$journalPath = Join-Path $state 'journal.jsonl'
New-Item -ItemType Directory -Force -Path $sandboxRoot, $sweepRoot | Out-Null
$env:REHEARSE_JOURNAL = $journalPath

$now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$sleep = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 300' -PassThru -WindowStyle Hidden

function New-Run([string]$name, [int]$pidValue, [int]$payloadMB) {
    $dir = Join-Path $sandboxRoot $name
    $repo = Join-Path $dir 'sandbox\repo'
    New-Item -ItemType Directory -Force -Path $repo | Out-Null
    Set-Content -LiteralPath (Join-Path $repo 'HEAD.txt') -Value 'clone' -Encoding ASCII
    if ($payloadMB -gt 0) { fsutil file createnew (Join-Path $repo 'blob.bin') ($payloadMB * 1MB) | Out-Null }
    # No BOM: the harness writes its own markers with fs.writeFileSync and JSON.parse
    # refuses a BOM, so such a marker reads as 'no owner marker' to the collector.
    $marker = [ordered]@{
        pid       = $pidValue
        startedAt = $now
        dir       = (Resolve-Path -LiteralPath $dir).Path
        keep      = $false
    } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText((Join-Path $dir '.owner.json'), $marker, (New-Object System.Text.UTF8Encoding($false)))
    return $dir
}

$dead = New-Run 'run-dead' 999999 1
$liveDir = New-Run 'run-live' $sleep.Id 1

function Invoke-Watch([switch]$Simulate, [switch]$NoSweep, [string]$Cli) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watch,
        '-NoToast', '-StateDir', $state,
        '-WatchRoot', (Join-Path $sandboxRoot '*'),
        '-SandboxRoot', $sweepRoot,
        '-TimeBudgetSeconds', '40')
    if ($Simulate) { $a += '-Simulate' }
    if ($NoSweep) { $a += '-NoSweep' }
    if ($Cli) { $a += @('-RehearsalCli', $Cli) }
    return (& powershell.exe @a 2>&1 | Out-String)
}
function Log { if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Raw } else { '' } }
function Journal { @(Get-Content -LiteralPath $journalPath -ErrorAction SilentlyContinue |
        ForEach-Object { try { $_ | ConvertFrom-Json } catch { } }) }

# --- run 1: baseline
$null = Invoke-Watch
$state1 = Get-Content -LiteralPath (Join-Path $state 'c-space-state.json') -Raw | ConvertFrom-Json
if (@($state1.paths.PSObject.Properties).Count -lt 2) { throw 'baseline sample did not record both sandboxes' }

# --- the leak: 400 MB lands in the dead sandbox
fsutil file createnew (Join-Path $dead 'sandbox\repo\blob-2.bin') (400MB) | Out-Null

# --- run 2: name it, have the collector clear it, re-read the volume
$before = [long](Get-Volume -DriveLetter C).SizeRemaining
$out2 = Invoke-Watch -Simulate
$state2 = Get-Content -LiteralPath (Join-Path $state 'c-space-state.json') -Raw | ConvertFrom-Json
$log2 = Log
$alert = if (Test-Path -LiteralPath $alertFile) { Get-Content -LiteralPath $alertFile -Raw } else { '' }
Start-Sleep -Milliseconds 300
$journal = @(Journal)
$event = $journal | Where-Object { $_.event -eq 'swept' -and $_.run -eq (Split-Path -Leaf $dead) } | Select-Object -First 1
$watchEvents = @($journal | Where-Object { $_.by -eq 'c-space-watch' })
$reRead = [long]$state2.freeBytes - $before

"run 2 free delta  : {0:N0} MB (state holds {1:N0} MB more than the pre-run reading)" -f (([long](Get-Volume -DriveLetter C).SizeRemaining - $before) / 1MB), ($reRead / 1MB)
"dead sandbox gone : $(-not (Test-Path -LiteralPath $dead))"
"live sandbox kept : $(Test-Path -LiteralPath $liveDir)"
"journal event     : $(if ($event) { "$($event.event) / $($event.reason) / by $($event.by)" } else { 'none' })"
"watchdog events   : $($watchEvents.Count) (must be 0: the pre-sample sweep is aimed elsewhere)"
($log2 -split "`n" | Where-Object { $_ -match '--sweep|collector' }) -join "`n"

# --- run 3: -NoSweep must leave the next one alone, and must not call the collector
$noSweep = New-Run 'run-nosweep' 999998 0
fsutil file createnew (Join-Path $noSweep 'sandbox\repo\blob.bin') (300MB) | Out-Null
$logLen = (Get-Content -LiteralPath $logPath).Count
$null = Invoke-Watch -Simulate -NoSweep
$log3 = @(Get-Content -LiteralPath $logPath | Select-Object -Skip $logLen) -join "`n"
"no-sweep kept    : $(Test-Path -LiteralPath $noSweep)"
"no-sweep named   : $([bool]($log3 -match 'grew:.*run-nosweep'))"
"no-sweep quiet   : $(-not ($log3 -match '--sweep|collector'))"

# --- run 4: the collector cannot be found -- nothing may be deleted
$orphan = New-Run 'run-orphan' 999997 0
fsutil file createnew (Join-Path $orphan 'sandbox\repo\blob.bin') (300MB) | Out-Null
$logLen = (Get-Content -LiteralPath $logPath).Count
$null = Invoke-Watch -Simulate -Cli (Join-Path $sandboxRoot 'no-such-collector.mjs')
$log4 = @(Get-Content -LiteralPath $logPath | Select-Object -Skip $logLen) -join "`n"
"orphan kept      : $(Test-Path -LiteralPath $orphan)"
"orphan reported  : $([bool]($log4 -match 'collector could not run'))"

$fail = @()
if (Test-Path -LiteralPath $dead) { $fail += 'stale top grower was NOT cleared' }
if (-not (Test-Path -LiteralPath $liveDir)) { $fail += 'live sandbox was wrongly deleted' }
if (-not $event) { $fail += 'no swept event for the deletion' }
if ($event -and $event.by) { $fail += "the deletion was journalled by $($event.by), not by the collector" }
if ($event -and $event.reason -notlike '*999999*') { $fail += "unexpected reason: $($event.reason)" }
if ($watchEvents.Count -ne 0) { $fail += 'the watchdog journalled a sweep of its own (pre-sample sweep should be aimed elsewhere)' }
if ($log2 -notmatch '--sweep cleared the top-grower sandbox') { $fail += 'summary does not credit the collector' }
if ($log2 -notmatch '--sweep cleared run-dead') { $fail += 'log does not name what the collector cleared' }
if ($alert -notmatch 'acted\s+:') { $fail += 'alert body has no acted line' }
if ("$($state2.paths.PSObject.Properties.Name)" -match 'run-dead') { $fail += 'cleared sandbox still in the next sample' }
if ($reRead -lt 250MB) { $fail += "free space was not re-read after the collection (only $([math]::Round($reRead / 1MB)) MB for a 400 MB sandbox)" }
if (-not (Test-Path -LiteralPath $noSweep)) { $fail += '-NoSweep still cleared the sandbox' }
if ($log3 -notmatch 'grew:.*run-nosweep') { $fail += 'run 3 did not rank the -NoSweep sandbox (test would prove nothing)' }
if ($log3 -match '--sweep|collector') { $fail += '-NoSweep still invoked the collector' }
if (-not (Test-Path -LiteralPath $orphan)) { $fail += 'the watchdog deleted a sandbox by itself when the collector was missing' }
if ($log4 -notmatch 'collector could not run') { $fail += 'run 4 did not report the missing collector' }

"---"
if ($fail.Count -gt 0) { $fail | ForEach-Object { "FAIL: $_" }; Stop-Process -Id $sleep.Id -Force -ErrorAction SilentlyContinue; exit 1 }
'PASS'
Stop-Process -Id $sleep.Id -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $sandboxRoot, $sweepRoot, $state -Recurse -Force -ErrorAction SilentlyContinue
