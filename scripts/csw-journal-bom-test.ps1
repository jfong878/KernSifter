$ErrorActionPreference = 'Stop'
$script = (Join-Path $PSScriptRoot 'c-space-watch.ps1')
$root = Join-Path $env:LOCALAPPDATA 'Temp\maktabat-rehearse-release'
$stamp = Get-Date -Format 'HHmmss'
$journal = Join-Path $env:TEMP "csw-journal-$stamp.jsonl"
$fail = @()

if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
$runDir = Join-Path $root "t-bom-$stamp"
New-Item -ItemType Directory -Force -Path (Join-Path $runDir 'sandbox\repo') | Out-Null
[ordered]@{ pid = 999999; startedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); root = $null; dir = (Resolve-Path -LiteralPath $runDir).Path; keep = $false } |
    ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $runDir '.owner.json') -Encoding UTF8

$env:REHEARSE_JOURNAL = $journal
$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -NoToast -NoState -SandboxRoot $root -WatchRoot "$root\*" -TimeBudgetSeconds 30 2>&1
Remove-Item Env:\REHEARSE_JOURNAL
"exit=$LASTEXITCODE  journal created=$(Test-Path -LiteralPath $journal)"

if (-not (Test-Path -LiteralPath $journal)) {
    $fail += 'the watchdog did not write to REHEARSE_JOURNAL'
} else {
    $bytes = [System.IO.File]::ReadAllBytes($journal)
    "first bytes: $($bytes[0..2] -join ' ')"
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $fail += 'the journal was created with a BOM' }
    $first = (Get-Content -LiteralPath $journal -TotalCount 1)
    "line: $first"
    try {
        $e = $first | ConvertFrom-Json
        if ($e.event -ne 'swept' -or $e.by -ne 'c-space-watch') { $fail += "unexpected first event: $first" }
    } catch { $fail += "PowerShell cannot parse its own line: $_" }
}

"--- reader sees it ---"
$repo = (Get-ChildItem 'C:\Users\jfong\F-Recovered\Projects' -Directory -Filter 'Maktabat-Abee*' | Select-Object -First 1).FullName
Push-Location $repo
$env:REHEARSE_JOURNAL = $journal
$summary = & node .freebuff/rehearse-release/journal.mjs 2>&1
Pop-Location
$summary | ForEach-Object { "  $_" }
if (-not ($summary -join "`n" -match 'swept 1')) { $fail += 'the reader did not see the watchdog event' }

Remove-Item Env:\REHEARSE_JOURNAL -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $journal -Force -ErrorAction SilentlyContinue
"---"
if ($fail.Count -gt 0) { $fail | ForEach-Object { "FAIL: $_" }; exit 1 }
'PASS'
