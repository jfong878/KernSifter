$ErrorActionPreference = 'Stop'
$script = (Join-Path $PSScriptRoot 'c-space-watch.ps1')
$root = Join-Path $env:LOCALAPPDATA 'Temp\maktabat-rehearse-release'
$state = Join-Path $env:TEMP ("csw-alert-test-" + (Get-Date -Format 'HHmmss'))
$stamp = Get-Date -Format 'HHmmss'
$fail = @()

if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
$runDir = Join-Path $root "t-alert-$stamp"
New-Item -ItemType Directory -Force -Path (Join-Path $runDir 'sandbox\repo') | Out-Null
[ordered]@{ pid = 999999; startedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); root = $null; dir = (Resolve-Path -LiteralPath $runDir).Path; keep = $false } |
    ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $runDir '.owner.json') -Encoding UTF8

$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -NoToast -Simulate -StateDir $state -SandboxRoot $root -WatchRoot "$root\*" -TimeBudgetSeconds 30 2>&1
$code = $LASTEXITCODE
"exit=$code"
$alert = Join-Path $state 'C-SPACE-ALERT.txt'
if (-not (Test-Path -LiteralPath $alert)) { $fail += 'no alert file' } else {
    $body = Get-Content -LiteralPath $alert -Raw
    "--- alert body ---"
    $body
    "------------------"
    if ($body -notmatch 'swept\s+: swept 1 stale sandbox\(es\)') { $fail += 'alert body has no sweep line' }
    if ($body -notmatch 'why\s+: simulated') { $fail += 'alert body lost its why line' }
}
if (Test-Path -LiteralPath $runDir) { $fail += 'sandbox not swept on the alert path' }

Remove-Item -LiteralPath $state -Recurse -Force -ErrorAction SilentlyContinue
"---"
if ($fail.Count -gt 0) { $fail | ForEach-Object { "FAIL: $_" }; exit 1 }
'PASS'
