$ErrorActionPreference = 'Stop'
$script = (Join-Path $PSScriptRoot 'c-space-watch.ps1')
$root = Join-Path $env:LOCALAPPDATA 'Temp\maktabat-rehearse-release'
$stamp = Get-Date -Format 'HHmmss'
$fail = @()

if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
$runDir = Join-Path $root "t-nosweep-$stamp"
New-Item -ItemType Directory -Force -Path (Join-Path $runDir 'sandbox\repo') | Out-Null
[ordered]@{ pid = 999999; startedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); root = $null; dir = (Resolve-Path -LiteralPath $runDir).Path; keep = $false } |
    ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $runDir '.owner.json') -Encoding UTF8

$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -NoToast -NoState -NoSweep -SandboxRoot $root -WatchRoot "$root\*" -TimeBudgetSeconds 30 2>&1
"no-sweep exit=$LASTEXITCODE  output: $(($out | Where-Object { $_ -notmatch '^\s*$' }) -join ' / ')"
if (-not (Test-Path -LiteralPath $runDir)) { $fail += '-NoSweep still deleted the sandbox' }

$out2 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -NoToast -NoState -SandboxRoot $root -WatchRoot "$root\*" -TimeBudgetSeconds 30 2>&1
"with-sweep exit=$LASTEXITCODE  output: $(($out2 | Where-Object { $_ -notmatch '^\s*$' }) -join ' / ')"
if (Test-Path -LiteralPath $runDir) { $fail += 'the sweep did not delete the sandbox' }

# a missing root is not an error
$out3 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -NoToast -NoState -SandboxRoot (Join-Path $env:TEMP "does-not-exist-$stamp") -WatchRoot "$root\*" -TimeBudgetSeconds 30 2>&1
"missing-root exit=$LASTEXITCODE"
if ($LASTEXITCODE -ne 0) { $fail += "missing root changed the exit code ($LASTEXITCODE)" }

"---"
if ($fail.Count -gt 0) { $fail | ForEach-Object { "FAIL: $_" }; exit 1 }
'PASS'
