$ErrorActionPreference = 'Stop'
$script = (Join-Path $PSScriptRoot 'c-space-watch.ps1')
$root = Join-Path $env:LOCALAPPDATA 'Temp\maktabat-rehearse-release'
$state = Join-Path $env:TEMP 'csw-sweep-test-state'
$journal = Join-Path $env:LOCALAPPDATA 'maktabat-rehearse\sandbox-journal.jsonl'

if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
if (-not (Test-Path -LiteralPath $state)) { New-Item -ItemType Directory -Force -Path $state | Out-Null }

$now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$stamp = Get-Date -Format 'HHmmss'
$made = @()

function New-Run([string]$name, $marker, [int]$ageHours = 0, [switch]$NoMarker) {
    $runDir = Join-Path $root "$name-$stamp"
    $repo = Join-Path $runDir 'sandbox\repo'
    New-Item -ItemType Directory -Force -Path $repo | Out-Null
    Set-Content -LiteralPath (Join-Path $repo 'HEAD.txt') -Value 'clone' -Encoding ASCII
    if (-not $NoMarker) {
        $json = $marker | ConvertTo-Json -Compress
        Set-Content -LiteralPath (Join-Path $runDir '.owner.json') -Value $json -Encoding UTF8
    }
    if ($ageHours -gt 0) {
        (Get-Item -LiteralPath $runDir).LastWriteTime = (Get-Date).AddHours(-$ageHours)
    }
    return $runDir
}

# A live process stands in for a running rehearsal.
$live = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 120' -PassThru -WindowStyle Hidden

# A real directory the junction points at: it must survive the delete.
$junctionTarget = Join-Path $env:TEMP "csw-sweep-test-junction-$stamp"
New-Item -ItemType Directory -Force -Path $junctionTarget | Out-Null
Set-Content -LiteralPath (Join-Path $junctionTarget 'installed.txt') -Value 'real dependency' -Encoding ASCII

$dead = New-Run 't-dead' @{ pid = 999999; startedAt = $now - 60000; dir = $null; keep = $false } -ageHours 0
# Point the marker at its own directory, exactly as markSandboxOwner does.
$m = Get-Content -LiteralPath (Join-Path $dead '.owner.json') -Raw | ConvertFrom-Json
$m.dir = (Resolve-Path -LiteralPath $dead).Path
$m | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $dead '.owner.json') -Encoding UTF8
$made += $dead
$null = New-Item -ItemType Junction -Path (Join-Path $dead 'sandbox\repo\node_modules') -Target $junctionTarget

New-Run 't-live' @{ pid = $live.Id; startedAt = $now - 60000; dir = $null; keep = $false } | ForEach-Object {
    $x = Get-Content -LiteralPath (Join-Path $_ '.owner.json') -Raw | ConvertFrom-Json
    $x.dir = (Resolve-Path -LiteralPath $_).Path
    $x | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $_ '.owner.json') -Encoding UTF8
    $script:live1 = $_
}
$made += $live1

function New-OwnedRun([string]$name, $pidValue, [int]$startedAgoMs, [bool]$keep) {
    $runDir = New-Run $name @{ pid = $pidValue; startedAt = $now - $startedAgoMs; dir = $null; keep = $keep } -NoMarker
    $obj = [ordered]@{ pid = $pidValue; startedAt = $now - $startedAgoMs; root = $null; dir = (Resolve-Path -LiteralPath $runDir).Path; keep = $keep }
    $obj | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $runDir '.owner.json') -Encoding UTF8
    return $runDir
}

$keptNew = New-OwnedRun 't-kept-new' 999998 ($now - ($now - 3600000)) $true   # started 1 h ago
$keptOld = New-OwnedRun 't-kept-old' 999997 ($now - ($now - 90000000)) $true  # started 25 h ago
$unownedOld = New-Run 't-unowned-old' $null -ageHours 25 -NoMarker
$unownedNew = New-Run 't-unowned-new' $null -ageHours 0 -NoMarker
$foreign = New-OwnedRun 't-foreign' 999996 0 $false
$f = Get-Content -LiteralPath (Join-Path $foreign '.owner.json') -Raw | ConvertFrom-Json
$f.dir = 'C:\somewhere\else'
$f | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $foreign '.owner.json') -Encoding UTF8

$made += $keptNew, $keptOld, $unownedOld, $unownedNew, $foreign

$before = (Get-Volume -DriveLetter C).SizeRemaining
$journalBefore = if (Test-Path -LiteralPath $journal) { (Get-Content -LiteralPath $journal).Count } else { 0 }

$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -NoToast -StateDir $state -SandboxRoot $root -TimeBudgetSeconds 40 2>&1
$code = $LASTEXITCODE
$after = (Get-Volume -DriveLetter C).SizeRemaining

Start-Sleep -Milliseconds 300
$survivors = @(Get-ChildItem -LiteralPath $root -Directory -Force | Where-Object { $_.Name -like "*-$stamp" } | ForEach-Object { $_.Name })
$journalLines = if (Test-Path -LiteralPath $journal) { Get-Content -LiteralPath $journal | Select-Object -Skip $journalBefore } else { @() }
$sweepEvents = @($journalLines | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_.by -eq 'c-space-watch' })

"exit=$code  free delta=$([math]::Round(($after - $before) / 1MB, 2)) MB"
"survivors: $($survivors -join ', ')"
"journal events from the watchdog:"
$sweepEvents | ForEach-Object { "  {0}  {1}  {2}  {3}" -f $_.run, $_.event, $_.reason, $_.ms }
"watchdog output:"
$out | ForEach-Object { "  $_" }
"junction target intact: $(Test-Path -LiteralPath (Join-Path $junctionTarget 'installed.txt'))"

# --- assertions
$fail = @()
foreach ($gone in @($dead, $keptOld, $unownedOld)) { if (Test-Path -LiteralPath $gone) { $fail += "not swept: $(Split-Path -Leaf $gone)" } }
foreach ($alive in @($live1, $keptNew, $unownedNew, $foreign)) { if (-not (Test-Path -LiteralPath $alive)) { $fail += "wrongly swept: $(Split-Path -Leaf $alive)" } }
if (-not (Test-Path -LiteralPath (Join-Path $junctionTarget 'installed.txt'))) { $fail += 'junction target was deleted' }
if ($sweepEvents.Count -ne 3) { $fail += "expected 3 journal events, got $($sweepEvents.Count)" }
if (-not ($out -match 'swept 3 stale sandbox\(es\)')) { $fail += 'summary line does not report the sweep' }
if (-not (@($sweepEvents | Where-Object { $_.reason -like 'pid 999999*' }).Count -eq 1)) { $fail += 'dead-owner reason missing' }

# guard expression, asserted rather than run against a real drive root
if (-not ('C:\' -match '^[A-Za-z]:\\?$')) { $fail += 'drive-root guard does not match C:\' }
if (('C:\Users' -match '^[A-Za-z]:\\?$')) { $fail += 'drive-root guard matches a subdirectory' }

"---"
if ($fail.Count -gt 0) { $fail | ForEach-Object { "FAIL: $_" }; Stop-Process -Id $live.Id -Force -ErrorAction SilentlyContinue; exit 1 }
'PASS'

# cleanup: the survivors the sweep was right to leave, plus test scaffolding
Stop-Process -Id $live.Id -Force -ErrorAction SilentlyContinue
foreach ($d in $survivors) { Remove-Item -LiteralPath (Join-Path $root $d) -Recurse -Force -ErrorAction SilentlyContinue }
Remove-Item -LiteralPath $junctionTarget -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $state -Recurse -Force -ErrorAction SilentlyContinue
