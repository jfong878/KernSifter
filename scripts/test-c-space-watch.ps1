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
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$tests = @(
    'csw-alert-test', 'csw-both-floor-reasons-test', 'csw-cache-action-test',
    'csw-cache-unreadable-test', 'csw-correlate-test',
    'csw-dryrun-plan-test', 'csw-dryrun-record-test', 'csw-elevated-collector-test',
    'csw-grower-action-test', 'csw-incomplete-baseline-test', 'csw-journal-bom-test',
    'csw-nosweep-test', 'csw-partial-delta-test', 'csw-promote-bound-test',
    'csw-promote-cooldown-test', 'csw-promote-first-sample-test', 'csw-promote-test',
    'csw-shadow-parse-test', 'csw-sweep-test', 'csw-truncated-advice-test',
    'csw-unranked-grow-test', 'csw-unranked-line-test', 'csw-unreadable-test'
)
if (-not (Test-Path -LiteralPath (Join-Path $here 'c-space-watch.ps1'))) {
    "no c-space-watch.ps1 beside $here"
    exit 1
}
$bad = 0
foreach ($t in $tests) {
    $path = Join-Path $here "$t.ps1"
    if (-not (Test-Path -LiteralPath $path)) { "$t  MISSING"; $bad += 1; continue }
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path 2>&1 | Out-String
    $code = $LASTEXITCODE
    $last = (@($out -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 1)
    '{0,-32} exit={1,-3} {2}' -f $t, $code, $last
    if ($code -ne 0) {
        $bad += 1
        @($out -split "`r?`n" | Where-Object { $_ -match 'FAIL|Exception|error' } | Select-Object -First 8) | ForEach-Object { "    $_" }
    }
}
'---'
"$bad suite(s) with a non-zero exit"
if ($bad -gt 0) { exit 1 }
