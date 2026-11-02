# test-c-space-watch.ps1 -- run every C: space watcher suite, one line each.
#
# The suites live beside this file. Each of them resolves c-space-watch.ps1 from its own
# directory, so this works from any checkout and from any working directory:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-c-space-watch.ps1
#
# Exit code 0 means every suite passed; 1 means at least one did not, or a suite named
# here is missing. Suites write their fixtures to %TEMP% and clean up after themselves;
# the ones that need a real ACL deny use icacls for the current account, so no elevation
# is required. Two of them also accept -Watch <path> to be pointed at the installed copy.
#
# The run leaves a receipt at %LOCALAPPDATA%\c-space-watch\test-receipt.json (override with
# -ReceiptPath). -Register reads it and refuses to install a watcher whose own SHA-256 the
# receipt does not cover, or whose last run failed -- so editing the script after a green
# run sends you back here. Run this from an ordinary prompt: an elevated run declines the
# collector, so the grower and dry-run suites cannot pass there, and the receipt records
# that it was elevated so -Register can tell the difference.
param([string]$ReceiptPath = (Join-Path $env:LOCALAPPDATA 'c-space-watch\test-receipt.json'))
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$watchPath = Join-Path $here 'c-space-watch.ps1'
$tests = @(
    'csw-alert-test', 'csw-both-floor-reasons-test', 'csw-cache-action-test',
    'csw-cache-unreadable-test', 'csw-correlate-test',
    'csw-dryrun-plan-test', 'csw-dryrun-record-test', 'csw-elevated-collector-test',
    'csw-grower-action-test', 'csw-incomplete-baseline-test', 'csw-journal-bom-test',
    'csw-nosweep-test', 'csw-partial-delta-test', 'csw-promote-bound-test',
    'csw-promote-cooldown-test', 'csw-promote-first-sample-test', 'csw-promote-test',
    'csw-register-gate-test', 'csw-shadow-parse-test', 'csw-sweep-test',
    'csw-truncated-advice-test', 'csw-unranked-grow-test', 'csw-unranked-line-test',
    'csw-unreadable-test'
)
$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

function Write-Receipt($fields) {
    if (-not $ReceiptPath) { return }
    try {
        $dir = Split-Path -Parent $ReceiptPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        [System.IO.File]::WriteAllText($ReceiptPath, ($fields | ConvertTo-Json -Depth 4),
            (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        "could not write the receipt at ${ReceiptPath}: $($_.Exception.Message)"
    }
}

if (-not (Test-Path -LiteralPath $watchPath)) {
    "no c-space-watch.ps1 beside $here"
    exit 1
}
$started = Get-Date
$hash = (Get-FileHash -LiteralPath $watchPath -Algorithm SHA256).Hash
# Written before the first suite runs, so a run that dies half way cannot leave an earlier
# green receipt standing next to a file it no longer describes.
# Plain hashtable, not [ordered]: ConvertTo-Json on 5.1 throws "argument types do not match"
# for an ordered dictionary holding an array of objects, which is what the finished receipt
# is. Key order in the receipt means nothing; the parseable content is the point.
Write-Receipt (@{
    schema = 1; state = 'running'; sha256 = $hash; watchPath = $watchPath; runnerPath = $PSCommandPath
    elevated = $elevated; suites = $tests.Count; passed = $false; failed = $null
    startedAt = $started.ToString('o'); finishedAt = $null; seconds = $null; failures = @(); results = @()
})

$bad = 0
$failures = New-Object System.Collections.Generic.List[string]
$results = New-Object System.Collections.Generic.List[object]
foreach ($t in $tests) {
    $path = Join-Path $here "$t.ps1"
    if (-not (Test-Path -LiteralPath $path)) {
        "$t  MISSING"
        $bad += 1
        $failures.Add("$t is missing")
        $results.Add([pscustomobject]@{ suite = $t; code = $null; missing = $true; seconds = $null })
        continue
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path 2>&1 | Out-String
    $sw.Stop()
    $secs = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $code = $LASTEXITCODE
    $last = (@($out -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 1)
    # Wall time per suite: a suite that grew slow is the first sign of a fixture that no
    # longer fits its budget, and the number belongs next to the verdict it produced.
    '{0,-32} exit={1,-3} {2,7:N1}s  {3}' -f $t, $code, $secs, $last
    $results.Add([pscustomobject]@{ suite = $t; code = $code; seconds = $secs })
    if ($code -ne 0) {
        $bad += 1
        $failures.Add($t)
        @($out -split "`r?`n" | Where-Object { $_ -match 'FAIL|Exception|error' } | Select-Object -First 8) | ForEach-Object { "    $_" }
    }
}
# The slowest few, so the suites that cost the run its time are visible without reading
# every line. Only suites that actually ran are ranked; a missing one has no seconds.
$ranked = @($results | Where-Object { $null -ne $_.seconds } | Sort-Object seconds -Descending | Select-Object -First 5)
if ($ranked.Count -gt 0) {
    'slowest     : ' + (($ranked | ForEach-Object { '{0} {1:N1}s' -f $_.suite, $_.seconds }) -join ', ')
}
'---'
"$bad suite(s) with a non-zero exit"

$finished = Get-Date
Write-Receipt (@{
    schema = 1; state = 'finished'; sha256 = $hash; watchPath = $watchPath; runnerPath = $PSCommandPath
    elevated = $elevated; suites = $tests.Count; passed = ($bad -eq 0); failed = $bad
    startedAt = $started.ToString('o'); finishedAt = $finished.ToString('o')
    seconds = [math]::Round(($finished - $started).TotalSeconds, 1)
    # .ToArray(), not @($list): in 5.1 the array subexpression over a List[object] holding
    # PSCustomObjects throws "Argument types do not match", and it throws while the receipt
    # literal is being built, which would lose the whole receipt after the suites finished.
    failures = $failures.ToArray(); results = $results.ToArray()
})
"receipt: $ReceiptPath  ($(if ($bad -eq 0) { 'passed' } else { "failed: $($failures -join ', ')" })$(if ($elevated) { ', run ELEVATED -- -Register refuses this' }))"

if ($bad -gt 0) { exit 1 }
