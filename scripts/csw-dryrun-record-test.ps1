# csw-dryrun-record-test.ps1 -- a manual -DryRun leaves its plan in the alert file.
#
# The preview is only useful if it is somewhere a person looks, and the alert file is
# where they look. So a dry run on a HEALTHY drive -- no breach, no drop -- must still
# write a body, headed as a plan, and must still not be an alert: exit 0, no toast, and
# the state's alert clock untouched.
#
# Layout under %TEMP%: scratch\corpse (dead pid, 1 MB) so the plan has something to name.
#   run 1  -DryRun on a healthy drive  -> C: SPACE PLAN, "would sweep", a cache line that
#                                         says why there is no cache plan, exit 0, nothing gone
#   run 2  -Simulate                   -> still C: SPACE ALERT, exit 1 (control: the same
#                                         file carries real alerts, unchanged)
#   run 3  plain run, no alert         -> writes nothing at all (the gate did not leak)
$ErrorActionPreference = 'Stop'
$watch = (Join-Path $PSScriptRoot 'c-space-watch.ps1')
$stamp = Get-Date -Format 'HHmmss'
$parent = Join-Path $env:TEMP "csw-record-$stamp"
$scratch = Join-Path $parent 'scratch'
$corpse = Join-Path $scratch 'corpse'
$state = Join-Path $parent 'state'
$logPath = Join-Path $state 'c-space-watch.log'
$statePath = Join-Path $state 'c-space-state.json'
$alertPath = Join-Path $state 'C-SPACE-ALERT.txt'
New-Item -ItemType Directory -Force -Path $corpse, $state | Out-Null

$exited = Start-Process -FilePath $env:ComSpec -ArgumentList '/c', 'exit' -PassThru -WindowStyle Hidden
$exited.WaitForExit()
$deadPid = $exited.Id
$marker = [ordered]@{ pid = $deadPid; startedAt = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - 3600 * 1000); dir = $corpse } | ConvertTo-Json -Compress
# No BOM: the harness parses this with JSON.parse.
[System.IO.File]::WriteAllText((Join-Path $corpse '.owner.json'), $marker, (New-Object System.Text.UTF8Encoding($false)))
fsutil file createnew (Join-Path $corpse 'sandbox.bin') (1MB) | Out-Null

# -MinFreeGB 0 and -DropGB 9999 keep this drive healthy no matter what it holds, so
# neither run 1 nor run 3 can alert on its own numbers.
function Invoke-Watch([string[]]$Switches = @()) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watch,
        '-NoToast', '-StateDir', $state, '-WatchRoot', $scratch, '-SandboxRoot', $scratch,
        '-CorrelateRoot', $parent, '-CorrelateMinGB', '999',
        '-MinFreeGB', '0', '-DropGB', '9999')
    foreach ($s in $Switches) { $a += "-$s" }
    return (& powershell.exe @a 2>&1 | Out-String)
}
function LogLen { if (Test-Path -LiteralPath $logPath) { @(Get-Content -LiteralPath $logPath).Count } else { 0 } }
function LogTail([int]$skip) { @(Get-Content -LiteralPath $logPath | Select-Object -Skip $skip) -join "`n" }

# --- run 1: the dry run on a healthy drive
$len = LogLen
$out1 = Invoke-Watch @('DryRun')
$code1 = $LASTEXITCODE
$log1 = LogTail $len
$alert1 = if (Test-Path -LiteralPath $alertPath) { Get-Content -LiteralPath $alertPath -Raw } else { '' }
$corpseThere = Test-Path -LiteralPath $corpse
$state1 = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json

"run 1 exit     : $code1"
"run 1 header   : $((($alert1 -split "`r?`n") | Select-Object -First 1))"
"run 1 why      : $([bool]($alert1 -match 'why\s+: no alert would be raised'))"
"run 1 plan     : $([bool]($alert1 -match 'would sweep : 1 stale sandbox')) / $([bool]($alert1 -match 'what to do: this was a dry run'))"
"run 1 cache    : $([bool]($alert1 -match 'would clear : nothing -- the drive is not short'))"
"run 1 advice   : $([bool]($alert1 -match 'nothing was deleted'))"
"run 1 logged   : $([bool]($log1 -match 'plan written to .*C-SPACE-ALERT\.txt'))"
"run 1 left     : corpse=$corpseThere lastAlert=$($state1.lastAlert)"

# --- run 2: the control -- the same file still carries a real alert
$len = LogLen
$null = Invoke-Watch @('Simulate', 'NoSweep')
$code2 = $LASTEXITCODE
$alert2 = Get-Content -LiteralPath $alertPath -Raw
$log2 = LogTail $len

"run 2 exit     : $code2"
"run 2 header   : $((($alert2 -split "`r?`n") | Select-Object -First 1))"

# --- run 3: no dry run, no alert -- the file must be left alone
Remove-Item -LiteralPath $alertPath -Force
$len = LogLen
$null = Invoke-Watch @('NoSweep')
$code3 = $LASTEXITCODE
$wrote3 = Test-Path -LiteralPath $alertPath

"run 3 exit     : $code3  wrote=$wrote3"

$fail = @()
if ($code1 -ne 0) { $fail += "a dry run on a healthy drive exited $code1, not 0" }
if (-not (Test-Path -LiteralPath $alertPath) -and $alert1 -eq '') { $fail += '-DryRun wrote no plan to the alert file' }
if ($alert1 -notmatch 'C: SPACE PLAN \(dry run\)') { $fail += 'the body is not headed as a plan' }
if ($alert1 -match 'C: SPACE ALERT') { $fail += 'the plan is headed as an alert' }
if ($alert1 -notmatch 'why\s+: no alert would be raised') { $fail += 'the plan does not say why it is not an alert' }
if ($alert1 -notmatch 'would sweep : 1 stale sandbox') { $fail += 'the plan does not carry the sweep it would do' }
if ($alert1 -notmatch 'what to do: this was a dry run') { $fail += 'the plan lost its closing dry-run advice' }
if ($alert1 -notmatch 'would clear : nothing -- the drive is not short') { $fail += 'the plan does not say why no cache is in it' }
if ($alert2 -match 'would clear :') { $fail += 'an alerting run labelled a cache line as a plan' }
if (-not $corpseThere) { $fail += '-DryRun deleted the stale sandbox' }
if ($state1.lastAlert) { $fail += 'the plan moved the alert clock in the state file' }
if ($log1 -notmatch 'plan written to .*C-SPACE-ALERT\.txt \(no alert would have been raised\)') { $fail += 'the log does not record that the plan was written' }
if ($code2 -ne 1) { $fail += "the simulated alert exited $code2, not 1" }
if ($alert2 -notmatch 'C: SPACE ALERT') { $fail += 'an alert is no longer headed as an alert' }
if ($wrote3) { $fail += 'a run that neither alerts nor is a dry run wrote the alert file' }
if ($code3 -ne 0) { $fail += "the quiet run exited $code3, not 0" }

"---"
if ($fail.Count -gt 0) {
    "run 1 body (state kept at $state):"
    $alert1
    $fail | ForEach-Object { "FAIL: $_" }
    exit 1
}
Remove-Item -LiteralPath $parent -Recurse -Force -ErrorAction SilentlyContinue
'PASS'
