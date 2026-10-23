# csw-dryrun-plan-test.ps1 -- -DryRun must report the sweep and the collector, not skip them.
#
# Layout under %TEMP%:
#   dryrun\scratch\corpse   dead pid, 1 MB then +300 MB  -> the sweep would remove it, and
#                           its growth makes the scratch root the top grower the
#                           collector is asked about
#   dryrun\scratch\live     this test's own pid, 1 MB    -> must be kept, in both reports
#
# Run 1 -NoSweep  : baseline only (a real sweep would collect the corpse before it can
#                   be reported).
# Run 2 -DryRun   : both plans must be named, and nothing may be deleted or journalled.
# Run 3 (real)    : the same fixture, collected -- proof the dry run was the difference.
$ErrorActionPreference = 'Stop'
$watch = (Join-Path $PSScriptRoot 'c-space-watch.ps1')
$stamp = Get-Date -Format 'HHmmss'
$parent = Join-Path $env:TEMP "csw-dryrun-$stamp"
$scratch = Join-Path $parent 'scratch'
$corpse = Join-Path $scratch 'corpse'
$live = Join-Path $scratch 'live'
$state = Join-Path $parent 'state'
$journal = Join-Path $state 'journal.jsonl'
New-Item -ItemType Directory -Force -Path $corpse, $live, $state | Out-Null

# A pid that is certainly gone: a process that has already exited.
$exited = Start-Process -FilePath $env:ComSpec -ArgumentList '/c', 'exit' -PassThru -WindowStyle Hidden
$exited.WaitForExit()
$deadPid = $exited.Id

function Write-Marker([string]$dir, [int]$ownerPid, [long]$startedAt) {
    # No BOM: Set-Content -Encoding UTF8 writes one on PS 5.1, and the harness reads the
    # marker with JSON.parse, which refuses it -- the sandbox then looks unowned.
    $json = [ordered]@{ pid = $ownerPid; startedAt = $startedAt; dir = $dir } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText((Join-Path $dir '.owner.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
}
$nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
Write-Marker $corpse $deadPid ($nowMs - 3600 * 1000)
Write-Marker $live $PID $nowMs
fsutil file createnew (Join-Path $corpse 'sandbox.bin') (1MB) | Out-Null
fsutil file createnew (Join-Path $live 'sandbox.bin') (1MB) | Out-Null

$env:REHEARSE_JOURNAL = $journal
$logPath = Join-Path $state 'c-space-watch.log'
$alertPath = Join-Path $state 'C-SPACE-ALERT.txt'

function Invoke-Watch([string[]]$Switches = @()) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watch,
        '-NoToast', '-StateDir', $state, '-WatchRoot', $scratch,
        '-SandboxRoot', $scratch, '-CorrelateRoot', $parent, '-CorrelateMinGB', '999',
        '-Simulate')
    foreach ($s in $Switches) { $a += "-$s" }
    return (& powershell.exe @a 2>&1 | Out-String)
}
function LogLen { @(Get-Content -LiteralPath $logPath).Count }
function LogTail([int]$skip) { @(Get-Content -LiteralPath $logPath | Select-Object -Skip $skip) -join "`n" }

# --- run 1: baseline, nothing swept
$null = Invoke-Watch @('NoSweep')
if (-not (Test-Path -LiteralPath $corpse)) { throw 'the baseline collected the corpse (test proves nothing)' }

# --- the corpse grows by 300 MB, so the scratch root becomes the top grower
fsutil file createnew (Join-Path $corpse 'big.bin') (300MB) | Out-Null

# --- run 2: the dry run must report both plans
$len = LogLen
$null = Invoke-Watch @('DryRun')
$log2 = LogTail $len
$alert2 = Get-Content -LiteralPath $alertPath -Raw
$corpseThere = Test-Path -LiteralPath $corpse
$liveThere = Test-Path -LiteralPath $live
$journalled = Test-Path -LiteralPath $journal

"plan line      : $([bool]($log2 -match 'would sweep 1 stale sandbox'))"
"collector line : $([bool]($log2 -match '--sweep --dry-run would clear corpse'))"
"alert lines    : $([bool]($alert2 -match 'would sweep : 1 stale sandbox')) / $([bool]($alert2 -match 'would act   : .*corpse'))"
"survived dry   : corpse=$corpseThere live=$liveThere journal=$journalled"

# --- run 3: the same fixture, actually collected
$len3 = LogLen
$null = Invoke-Watch
$log3 = LogTail $len3
"real sweep     : $([bool]($log3 -match 'swept 1 stale sandbox'))  corpse gone=$(-not (Test-Path -LiteralPath $corpse))  live kept=$(Test-Path -LiteralPath $live)"

$fail = @()
if ($log2 -notmatch 'would sweep 1 stale sandbox\(es\) \(~\d+\.\d+ GB\)') { $fail += '-DryRun did not report the sandbox the pre-sample sweep would clear' }
if ($log2 -match 'swept 1 stale sandbox') { $fail += '-DryRun claimed a sweep it did not do' }
if ($log2 -notmatch '--sweep --dry-run would clear corpse \(pid \d+ is gone') { $fail += 'the collector was not asked what it would clear (or its verdict was not reported)' }
if ($log2 -notmatch 'would keep live|would clear corpse') { $fail += 'the collector report is missing its verdicts' }
if ($log2 -match 'would clear live') { $fail += 'the collector would have cleared the live sandbox' }
if ($alert2 -notmatch 'would sweep : 1 stale sandbox') { $fail += 'the alert has no "would sweep" line' }
if ($alert2 -notmatch 'would act   : the rehearsal''s collector would clear corpse') { $fail += 'the alert has no "would act" line' }
if (-not $corpseThere) { $fail += '-DryRun deleted the stale sandbox' }
if (-not $liveThere) { $fail += '-DryRun deleted the live sandbox' }
if ($journalled) { $fail += '-DryRun wrote a sweep to the journal' }
if ($log3 -notmatch 'swept 1 stale sandbox') { $fail += 'the real run did not sweep the same sandbox (the fixture, not the switch, explains the dry run)' }
if (Test-Path -LiteralPath $corpse) { $fail += 'the real run left the corpse behind' }
if (-not (Test-Path -LiteralPath $live)) { $fail += 'the real run swept the live sandbox' }

Remove-Item Env:\REHEARSE_JOURNAL -ErrorAction SilentlyContinue
'---'
if ($fail.Count -gt 0) {
    "dry-run log (kept at $state):"
    $log2
    $fail | ForEach-Object { "FAIL: $_" }
    exit 1
}
Remove-Item -LiteralPath $parent -Recurse -Force -ErrorAction SilentlyContinue
'PASS'
