# csw-correlate-test.ps1 -- name a grower the watch roots do not cover.
#
# Layout under %TEMP%:
#   corr-parent\watch\...      watched root  (4 MB written -> must NOT be listed)
#   corr-parent\outside\nested 300 MB written in the window -> must be named
#   corr-parent\outside\old    250 MB whose mtime predates the window -> must NOT be
#
# Four runs: baseline, the correlation, a budget-truncated walk, and -NoCorrelate.
$ErrorActionPreference = 'Stop'
$watch = (Join-Path $PSScriptRoot 'c-space-watch.ps1')
$stamp = Get-Date -Format 'HHmmss'
$parent = Join-Path $env:TEMP "csw-corr-$stamp"
$watchDir = Join-Path $parent 'watch'
$outside = Join-Path $parent 'outside'
$nested = Join-Path $outside 'nested'
$old = Join-Path $outside 'old'
$sweepRoot = Join-Path $env:TEMP "csw-corr-sweep-$stamp"
$state = Join-Path $env:TEMP "csw-corr-state-$stamp"
$logPath = Join-Path $state 'c-space-watch.log'
$alertFile = Join-Path $state 'C-SPACE-ALERT.txt'
New-Item -ItemType Directory -Force -Path $watchDir, $nested, $old, $sweepRoot | Out-Null
$env:REHEARSE_JOURNAL = Join-Path $state 'journal.jsonl'

# 250 MB that predates the window: created before the baseline, aged out afterwards.
fsutil file createnew (Join-Path $old 'ancient.bin') (250MB) | Out-Null
(Get-Item -LiteralPath (Join-Path $old 'ancient.bin')).LastWriteTime = (Get-Date).AddHours(-2)
Set-Content -LiteralPath (Join-Path $watchDir 'seed.txt') -Value 'seed' -Encoding ASCII

# Switches are passed alone and options as name/value pairs: "-Switch true" leaves a
# stray token that binds positionally to an unrelated [int] parameter.
function Invoke-Watch([hashtable]$Opts = @{}, [string[]]$Switches = @()) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watch,
        '-NoToast', '-StateDir', $state,
        '-WatchRoot', (Join-Path $watchDir '*'),
        '-SandboxRoot', $sweepRoot,
        '-CorrelateRoot', $parent,
        '-TimeBudgetSeconds', '40')
    foreach ($s in $Switches) { $a += "-$s" }
    foreach ($k in $Opts.Keys) { $a += @("-$k", [string]$Opts[$k]) }
    return (& powershell.exe @a 2>&1 | Out-String)
}
function State { Get-Content -LiteralPath (Join-Path $state 'c-space-state.json') -Raw | ConvertFrom-Json }
function LogLen { (Get-Content -LiteralPath $logPath).Count }

# --- run 1: baseline
$null = Invoke-Watch
$s1 = State
if (-not $s1.paths) { throw 'baseline did not record the watch root children' }

# --- the leak happens outside the watched roots
fsutil file createnew (Join-Path $nested 'big.bin') (300MB) | Out-Null
fsutil file createnew (Join-Path $watchDir 'small.bin') (4MB) | Out-Null

# --- run 2: the drop must be correlated
$null = Invoke-Watch -Opts @{ CorrelateMinGB = '0.1' } -Switches 'Simulate'
$s2 = State
$alert2 = Get-Content -LiteralPath $alertFile -Raw
$log2 = Get-Content -LiteralPath $logPath -Raw
$dirs2 = @($s2.correlation.dirs | ForEach-Object { $_.path })

"correlation dirs   : $($dirs2.Count)"
$dirs2 | ForEach-Object { "  $_" }
"written total      : {0:N0} MB (walked {1:N0} files in {2:N1}s)" -f ($s2.correlation.totalBytes / 1MB), $s2.correlation.walked, $s2.correlation.seconds

# --- run 3: same shape, no time to walk
# A NEW directory, because run 2 promoted `nested` into the watch roots: growth there is
# now explained by the sample, and an explained drop is (correctly) not walked for.
$fresh3 = Join-Path $outside 'fresh3'
New-Item -ItemType Directory -Force -Path $fresh3 | Out-Null
fsutil file createnew (Join-Path $nested 'big2.bin') (300MB) | Out-Null
fsutil file createnew (Join-Path $fresh3 'big.bin') (300MB) | Out-Null
# A negative budget is out of time before the first directory: the same code path a
# real exhausted budget takes, without needing a tree big enough to time out.
$null = Invoke-Watch -Opts @{ CorrelateMinGB = '0.1'; CorrelateBudgetSeconds = '-1' } -Switches 'Simulate'
$s3 = State
$alert3 = Get-Content -LiteralPath $alertFile -Raw
"truncated flag     : $($s3.correlation.truncated)"

# --- run 4: -NoCorrelate must not walk at all
fsutil file createnew (Join-Path $nested 'big3.bin') (300MB) | Out-Null
$len = LogLen
$null = Invoke-Watch -Opts @{ CorrelateMinGB = '0.1' } -Switches 'Simulate', 'NoCorrelate'
$log4 = @(Get-Content -LiteralPath $logPath | Select-Object -Skip $len) -join "`n"
"no-correlate line  : $([bool]($log4 -match 'outside the watched roots'))"

# --- run 5: the walk follows the alert's own 6 h rhythm, not every tick
# Pretend the last alert was 7 h ago so this run is allowed to alert.
$raw = Get-Content -LiteralPath (Join-Path $state 'c-space-state.json') -Raw | ConvertFrom-Json
$raw.lastAlert = (Get-Date).AddHours(-7).ToString('o')
$raw | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $state 'c-space-state.json') -Encoding UTF8

# Another new directory: `nested` and `fresh3` are watched by now, so their growth would
# explain the drop and skip the walk this scenario is about.
$fresh5 = Join-Path $outside 'fresh5'
New-Item -ItemType Directory -Force -Path $fresh5 | Out-Null
fsutil file createnew (Join-Path $fresh5 'big.bin') (200MB) | Out-Null
$len5a = LogLen
$null = Invoke-Watch -Opts @{ CorrelateMinGB = '0.1'; MinFreeGB = '999' }
$s5a = State
$log5a = @(Get-Content -LiteralPath $logPath | Select-Object -Skip $len5a) -join "`n"

$fresh5b = Join-Path $outside 'fresh5b'
New-Item -ItemType Directory -Force -Path $fresh5b | Out-Null
fsutil file createnew (Join-Path $fresh5b 'big.bin') (200MB) | Out-Null
$len5b = LogLen
$null = Invoke-Watch -Opts @{ CorrelateMinGB = '0.1'; MinFreeGB = '999' }
$s5b = State
$log5b = @(Get-Content -LiteralPath $logPath | Select-Object -Skip $len5b) -join "`n"
"alert-path walk    : $([bool]($log5a -match 'outside the watched roots'))"
"throttled walk     : $([bool]($log5b -match 'outside the watched roots')) / suppressed=$([bool]($log5b -match 'alert suppressed'))"

$fail = @()
if ($log5a -notmatch 'outside the watched roots') { $fail += 'a non-throttled alert did not correlate' }
if ($log5b -match 'outside the watched roots') { $fail += 'a throttled tick walked the tree again' }
if ($log5b -notmatch 'alert suppressed') { $fail += 'run 5b was not actually throttled (test proves nothing)' }
if ("$($s5b.correlation.at)" -ne "$($s5a.correlation.at)") { $fail += 'the throttled run replaced the stored correlation' }
if ($dirs2.Count -eq 0) { $fail += 'nothing was correlated' }
if (-not ($dirs2 -match 'nested$')) { $fail += 'the 300 MB directory outside the watch roots was not named' }
if ($dirs2 -match '\\watch') { $fail += 'a watched root was listed as outside' }
if ($dirs2 -match '\\old$') { $fail += 'a file older than the window was counted' }
if ($s2.correlation.totalBytes -lt 250MB -or $s2.correlation.totalBytes -gt 360MB) { $fail += "written total is wrong: $([math]::Round($s2.correlation.totalBytes / 1MB)) MB (expected ~300)" }
if ($alert2 -notmatch 'written in this window outside the watched roots:') { $fail += 'alert has no correlation section' }
if ($alert2 -notmatch 'nested') { $fail += 'alert does not name the directory' }
if ($log2 -notmatch 'outside the watched roots: \+\d') { $fail += 'summary line does not carry the correlation' }
if (-not $s3.correlation.truncated) { $fail += 'an exhausted budget did not report truncation' }
if ($alert3 -notmatch 'truncated at budget') { $fail += 'alert does not admit the truncated walk' }
if ($log4 -match 'outside the watched roots') { $fail += '-NoCorrelate still correlated' }

Remove-Item -LiteralPath $parent, $sweepRoot, $state -Recurse -Force -ErrorAction SilentlyContinue
"---"
if ($fail.Count -gt 0) { $fail | ForEach-Object { "FAIL: $_" }; exit 1 }
'PASS'
