# csw-cache-action-test.ps1 -- a regenerable cache is cleared when it is the top grower.
#
# Six runs against a throwaway tree under %TEMP%:
#   run 1  baseline over three directories: a "browser cache", an "updater payload", and
#          one that is neither;
#   run 2  the cache grows 300 MB -> must be cleared, re-read, and reported;
#   run 3  the updater grows 300 MB with -CacheMaxClearGB 0.1 -> only about the cap may
#          go, and the note must say the cap stopped it;
#   run 4  -DryRun -> nothing may be deleted, and the log must say what it would clear;
#   run 5  the non-cache grows 400 MB -> must be left alone;
#   run 6  -NoSweep -> clears nothing at all, caches included;
#   run 7  no growth at all -> a breach with no grower: the alert must explain both the
#          empty cache line and the empty growth list instead of leaving them out;
#   run 8  a fresh state, so the same breach is a FIRST sample: the explanation has to
#          differ, because "nothing grew" is not true of a run with nothing to compare;
#   run 9  space is consumed OUTSIDE the watched roots, so free space falls with nothing
#          to rank: the advice must name what this scan cannot see instead of a directory.
#
# The directories are passed with -CacheRoot, so the real browser caches are never in
# play, and -SandboxRoot points at an empty root so the sweep has nothing to do.
$ErrorActionPreference = 'Stop'
$watch = (Join-Path $PSScriptRoot 'c-space-watch.ps1')
$stamp = Get-Date -Format 'HHmmss'
$base = Join-Path $env:TEMP "csw-cache-$stamp"
$cache1 = Join-Path $base 'browser-cache'
$cache2 = Join-Path $base 'updater'
$other = Join-Path $base 'other'
$empty = Join-Path $env:TEMP "csw-cache-sweep-$stamp"
$state = Join-Path $env:TEMP "csw-cache-state-$stamp"
$logPath = Join-Path $state 'c-space-watch.log'
$alertPath = Join-Path $state 'C-SPACE-ALERT.txt'
New-Item -ItemType Directory -Force -Path $cache1, $cache2, $other, $empty | Out-Null
foreach ($d in @($cache1, $cache2, $other)) {
    Set-Content -LiteralPath (Join-Path $d 'seed.txt') -Value 'seed' -Encoding ASCII
}

function Size($p) { [long](@(Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue) | Measure-Object -Property Length -Sum).Sum }
function Grow($p, [int]$mb) { fsutil file createnew (Join-Path $p ("blob-{0}.bin" -f [guid]::NewGuid().ToString('N'))) ($mb * 1MB) | Out-Null }

# -File binds a parameter to ONE string, so an array cannot be passed that way: each run
# names the single directory it is about.
function Invoke-Watch([hashtable]$Opts = @{}, [string[]]$Switches = @(), [string]$Cache = $cache1, [string]$StateDir = $state) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watch,
        '-NoToast', '-StateDir', $StateDir,
        '-WatchRoot', (Join-Path $base '*'),
        '-SandboxRoot', $empty,
        '-CacheRoot', $Cache,
        '-CorrelateRoot', $base,
        '-TimeBudgetSeconds', '40')
    foreach ($s in $Switches) { $a += "-$s" }
    foreach ($k in $Opts.Keys) { $a += @("-$k", [string]$Opts[$k]) }
    return (& powershell.exe @a 2>&1 | Out-String)
}
function LogLen { (Get-Content -LiteralPath $logPath).Count }
function Tail([int]$skip) { @(Get-Content -LiteralPath $logPath | Select-Object -Skip $skip) -join "`n" }

# --- run 1: baseline
$null = Invoke-Watch
$s1 = Get-Content -LiteralPath (Join-Path $state 'c-space-state.json') -Raw | ConvertFrom-Json
"baseline paths   : $(@($s1.paths.PSObject.Properties).Count)"

# --- run 2: the cache is the top grower and is cleared
Grow $cache1 300
$before = [long](Get-Volume -DriveLetter C).SizeRemaining
$len = LogLen
$null = Invoke-Watch -Switches 'Simulate'
$log2 = Tail $len
$alert2 = if (Test-Path -LiteralPath $alertPath) { Get-Content -LiteralPath $alertPath -Raw } else { '' }
$freeDelta2 = ([long](Get-Volume -DriveLetter C).SizeRemaining - $before) / 1MB
"run 2 size       : {0:N0} MB (was 300 MB), free delta {1:N0} MB" -f ((Size $cache1) / 1MB), $freeDelta2
"run 2 kept dir   : $(Test-Path -LiteralPath $cache1)"
"run 2 note       : $((($log2 -split "`n") | Where-Object { $_ -match 'cleared' } | Select-Object -First 1).Trim())"
"run 2 alert      : $([bool]($alert2 -match 'cleared\s+:'))"
# Captured here: run 6 deliberately re-grows this cache and asks for it to be kept.
$size2 = Size $cache1

# --- run 3: the cap stops a bigger clear halfway
$len = LogLen
1..6 | ForEach-Object { Grow $cache2 50 }
$beforeSize = Size $cache2
$null = Invoke-Watch -Opts @{ CacheMaxClearGB = '0.1' } -Switches 'Simulate' -Cache $cache2
$log3 = Tail $len
$afterSize = Size $cache2
"run 3 updater    : {0:N0} MB -> {1:N0} MB (cap 0.1 GB)" -f ($beforeSize / 1MB), ($afterSize / 1MB)
"run 3 capped     : $([bool]($log3 -match 'cap'))"

# --- run 4: dry run deletes nothing
$len = LogLen
Grow $cache2 100
$dryBefore = Size $cache2
$null = Invoke-Watch -Switches 'Simulate', 'DryRun' -Cache $cache2
$log4 = Tail $len
$alert4 = if (Test-Path -LiteralPath $alertPath) { Get-Content -LiteralPath $alertPath -Raw } else { '' }
"run 4 unchanged  : $((Size $cache2) -eq $dryBefore) ($([math]::Round($dryBefore / 1MB)) MB)"
"run 4 planned    : $([bool]($log4 -match 'would clear .*-DryRun'))"
"run 4 alert      : $([bool]($alert4 -match 'would clear : \d+\.\d+ of \d+\.\d+ GB from .*updater'))"

# --- run 5: something that is not a cache is left alone
$len = LogLen
Grow $other 400
$null = Invoke-Watch -Switches 'Simulate'
$log5 = Tail $len
$alert5 = if (Test-Path -LiteralPath $alertPath) { Get-Content -LiteralPath $alertPath -Raw } else { '' }
"run 5 other kept : $([bool]((Size $other) -ge 400MB))"
"run 5 alert      : $([bool]($alert5 -match 'cleared\s+: nothing -- the top grower .*other is not one of the -CacheRoot'))"

# --- run 6: -NoSweep clears nothing at all
$len = LogLen
Grow $cache1 300
$null = Invoke-Watch -Switches 'Simulate', 'NoSweep'
$log6 = Tail $len
"run 6 cache kept : $([bool]((Size $cache1) -ge 300MB))"

# --- run 7: the drive is called short with nothing growing
$len = LogLen
$null = Invoke-Watch -Switches 'Simulate'
$log7 = Tail $len
$alert7 = if (Test-Path -LiteralPath $alertPath) { Get-Content -LiteralPath $alertPath -Raw } else { '' }
$a7cache = (@($alert7 -split "`n") | Where-Object { $_ -match 'cleared|would clear' } | Select-Object -First 1)
$a7none = (@($alert7 -split "`n") | Where-Object { $_ -like '*(none*' } | Select-Object -First 1)
"run 7 cache line: $($a7cache.Trim())"
"run 7 growth    : $($a7none.Trim())"

# --- run 8: the same breach on a first sample
$state8 = Join-Path $env:TEMP "csw-cache-first-$stamp"
$null = Invoke-Watch -Switches 'Simulate' -StateDir $state8
$alert8 = Get-Content -LiteralPath (Join-Path $state8 'C-SPACE-ALERT.txt') -Raw
$a8cache = (@($alert8 -split "`n") | Where-Object { $_ -match 'cleared|would clear' } | Select-Object -First 1)
$a8none = (@($alert8 -split "`n") | Where-Object { $_ -like '*(none*' } | Select-Object -First 1)
"run 8 cache line: $($a8cache.Trim())"
"run 8 growth    : $($a8none.Trim())"

# --- run 9: the space goes where the scan does not look, so the fall has no grower
$hidden = Join-Path $env:TEMP "csw-hidden-$stamp"
New-Item -ItemType Directory -Force -Path $hidden | Out-Null
fsutil file createnew (Join-Path $hidden 'fall.bin') (400MB) | Out-Null
$len = LogLen
$null = Invoke-Watch -Switches 'Simulate'
$log9 = Tail $len
$alert9 = Get-Content -LiteralPath $alertPath -Raw
Remove-Item -LiteralPath $hidden -Recurse -Force -ErrorAction SilentlyContinue
$a9change = (@($alert9 -split "`n") | Where-Object { $_ -match '^change' } | Select-Object -First 1)
$a9advice = (@($alert9 -split "`n") | Where-Object { $_ -match '^what to do:' } | Select-Object -First 1)
$a9shadow = (@($alert9 -split "`n") | Where-Object { $_ -match '^not ranked' } | Select-Object -First 1)
"run 9 change    : $($a9change.Trim())"
"run 9 unranked  : $($a9shadow.Trim())"
"run 9 advice    : $($a9advice.Trim())"

$fail = @()
if ($size2 -ge 50MB) { $fail += "the growing cache was not cleared ($([math]::Round($size2 / 1MB)) MB left)" }
if (-not (Test-Path -LiteralPath $cache1)) { $fail += 'the cache directory itself was removed (contents only, please)' }
if ($log2 -notmatch 'cleared .* from .*browser-cache') { $fail += 'the summary does not report the clear' }
if ($alert2 -notmatch 'cleared\s+:') { $fail += 'the alert has no cleared line' }
if ($freeDelta2 -lt 250) { $fail += "free space was not re-read after the clear (only $([math]::Round($freeDelta2)) MB)" }
if ($afterSize -gt 250MB) { $fail += "the cap did not bound the clear: $([math]::Round($afterSize / 1MB)) MB left" }
if ($afterSize -lt 150MB) { $fail += "the cap cleared the whole updater instead of stopping at 0.1 GB: $([math]::Round($afterSize / 1MB)) MB left" }
if ($log3 -notmatch 'cap') { $fail += 'the note does not say the cap stopped it' }
if ((Size $cache2) -ne $dryBefore) { $fail += '-DryRun deleted files' }
if ($log4 -notmatch 'would clear') { $fail += '-DryRun did not report what it would clear' }
# The alert body has to label a plan as a plan, in the present tense of the proposal and
# not the past tense of a deletion that did not happen.
if ($alert4 -notmatch 'would clear : \d+\.\d+ of \d+\.\d+ GB from .*updater') { $fail += 'the dry-run alert does not label the cache plan as a plan' }
if ($alert4 -match 'would clear : would clear') { $fail += 'the cache plan says "would clear" twice' }
if ($alert4 -match 'cleared\s+:') { $fail += 'a dry run reported a cache as cleared' }
if ((Size $other) -lt 400MB) { $fail += 'a directory that is not a cache was cleared' }
if ($log5 -match 'cleared .* from .*other') { $fail += 'the non-cache was reported as cleared' }
# An empty cache section reads as an omission, so the alert has to say it looked and the
# grower is not something it may empty -- in the past tense of what happened, and without
# the advice that belongs to a cache that was cleared.
if ($alert5 -notmatch 'cleared\s+: nothing -- the top grower .*other is not one of the -CacheRoot directories') { $fail += 'an alert whose top grower is not a cache does not say so' }
if ($alert5 -match 'what the notes above report as cleared') { $fail += 'a non-cache top grower got the advice meant for a cleared cache' }
if ($alert5 -notmatch 'what to do: start with the top grower') { $fail += 'the non-cache alert lost its generic advice' }
if ((Size $cache1) -lt 300MB) { $fail += '-NoSweep still cleared a cache' }
if ($log6 -match 'cleared .* from .*browser-cache') { $fail += '-NoSweep still reported a cache clear' }
# A breach with no grower: both empty sections have to say why they are empty, and the
# advice cannot tell the reader to start with a grower the document does not name.
if ($alert7 -notmatch 'cleared\s+: nothing -- nothing grew by 1 MB or more, so there is no top grower') { $fail += 'a breach with nothing growing leaves the cache section unexplained' }
if ($alert7 -notmatch '\(none -- no directory changed by 1 MB or more since the previous sample\)') { $fail += 'the growth section does not say nothing changed (rather than "no directory grew, or first sample")' }
if ($alert7 -match 'or this is the first sample') { $fail += 'the growth section still conflates a first sample with a flat one' }
# Which advice is right depends on whether free space actually fell during run 7: a flat
# sample cannot be told to look for what took the missing space.
if ($alert7 -match 'change      : -0\.00') {
    if ($alert7 -notmatch 'what to do: nothing grew enough to name') { $fail += 'a flat no-grower alert does not say where to start' }
} elseif ($alert7 -notmatch 'what to do: free space fell') {
    $fail += 'a falling no-grower alert does not offer the causes a scan cannot see'
}
if ($alert7 -match 'what to do: start with the top grower') { $fail += 'the no-grower alert kept the advice meant for a named grower' }
if ($alert7 -notmatch 'biggest growth since the previous sample:') { $fail += 'the no-grower alert lost its growth section entirely' }
if ($alert8 -notmatch 'cleared\s+: nothing -- this is the first sample, so there is no growth ranking to name a top grower from') { $fail += 'a first-sample breach does not explain that there is no ranking yet' }
if ($alert8 -notmatch '\(none -- this is the first sample, so there is no earlier size to compare against\)') { $fail += 'a first-sample growth section does not say there is nothing to compare' }
# A first sample made no comparison, so its advice cannot say what that comparison found.
if ($alert8 -notmatch 'what to do: this is the first sample, so there is no growth ranking yet') { $fail += 'a first-sample alert does not say the sizes are the baseline' }
if ($alert8 -match 'nothing grew enough to name') { $fail += 'a first-sample alert claims nothing grew, which it never checked' }
if ($alert8 -match 'what to do: start with the top grower') { $fail += 'a first-sample alert points at a grower it never named' }
if ($log7 -notmatch 'nothing -- nothing grew by 1 MB or more') { $fail += 'the log summary does not carry the no-grower verdict' }
# Run 9: a measured fall with nothing to name. The advice has to be about the fall and about
# the things outside the scan, not about a directory the document does not contain.
if ($alert9 -match 'change      : -0\.00') { $fail += 'run 9 recorded no fall (the fixture, not the advice)' }
if ($alert9 -notmatch 'what to do: free space fell \d+\.\d\d GB with nothing in the watch roots') { $fail += 'a fall with no grower does not say the watch roots cannot explain it' }
if ($alert9 -notmatch 'shadow copies and restore points') { $fail += 'the no-grower advice does not name shadow copies' }
if ($alert9 -notmatch 'pagefile or\s+hibernation file') { $fail += 'the no-grower advice does not name the pagefile and hibernation file' }
if ($alert9 -notmatch 'deleted\s+file a process still holds open') { $fail += 'the no-grower advice does not name deleted files still held open' }
if ($alert9 -notmatch '-WatchRoot does not cover') { $fail += 'the no-grower advice does not name trees outside the watched roots' }
if ($alert9 -match 'nothing grew enough to name') { $fail += 'the falling alert used the advice meant for a flat sample' }
if ($alert9 -match 'what to do: start with the top grower') { $fail += 'the falling alert points at a grower it never named' }
if ($alert9 -notmatch '\(none -- no directory changed by 1 MB or more') { $fail += 'run 9 lost its flat growth line' }
if ($alert9 -notmatch 'cleared\s+: nothing -- nothing grew by 1 MB or more') { $fail += 'run 9 lost its empty-cache explanation' }
if ($log9 -notmatch 'nothing -- nothing grew by 1 MB or more') { $fail += 'run 9 log summary lost the no-grower verdict' }
# The one cause no walk can see has to be measured or explicitly unmeasurable -- an absent
# line would be the guess this is meant to replace, and a bare zero would read as "none".
if (-not [regex]::IsMatch($alert9, '(?m)^not ranked  : .*pagefile (\d+\.\d\d GB on C:|none -- \S)')) {
    $fail += 'a fall with no grower does not size the pagefile'
}
if ($alert9 -notmatch 'hibernation file (none -- \S|\d+\.\d\d GB on C:)') {
    $fail += 'the same line does not size the hibernation file'
}
if ($alert9 -notmatch 'shadow (unknown -- \S|none -- no shadow copies|\d+\.\d\d GB on C:)') {
    $fail += 'the same line does not report shadow-copy storage (or say why not)'
}
if ($log9 -notmatch '\[pagefile (\d+\.\d\d GB|none)\]') { $fail += 'the log summary does not carry the pagefile size' }
if ($log9 -notmatch '\[hibernation (none|\d+\.\d\d GB)\]') { $fail += 'the log summary does not carry the hibernation file' }
if ($log9 -notmatch '\[shadow (unknown|none|\d+\.\d\d GB)\]') { $fail += 'the log summary does not carry the shadow verdict' }
# Scoped to the case it exists for: an alert with a grower, and a first sample, get no line.
if ($alert2 -match '(?m)^not ranked') { $fail += 'a normal grower alert grew a not-ranked line it has no reason to compute' }
if ($alert8 -match '(?m)^not ranked') { $fail += 'a first-sample alert sizes the pagefile with no fall to explain' }

"---"
if ($fail.Count -gt 0) {
    "run 9 alert:"; $alert9
    $fail | ForEach-Object { "FAIL: $_" }
    Remove-Item -LiteralPath $base, $empty, $state, $state8, $hidden -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}
'PASS'
Remove-Item -LiteralPath $base, $empty, $state, $state8, $hidden -Recurse -Force -ErrorAction SilentlyContinue
