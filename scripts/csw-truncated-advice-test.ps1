# csw-truncated-advice-test.ps1 -- a scan that ran out of time must not claim nothing grew.
#
# Four runs against a throwaway tree under %TEMP%:
#   run 1  a complete scan, so there is a previous sample to fall against;
#   run 2  the same fall, measured with -TimeBudgetSeconds 0: the scan truncates, names no
#          grower, and the advice has to be about the budget -- not about shadow copies and
#          not "nothing grew", because it may never have reached the directory that did;
#   run 3  a truncated FIRST sample: the budget still explains it, so the first-sample
#          wording ("the sizes above are the baseline") must not win, and the growth list
#          -- which has nothing to show -- has to say the scan stopped rather than that
#          nothing changed;
#   run 4  the control, on its own state: a complete baseline, a fall, a complete scan --
#          the same shape of fall keeps the fall advice, which is what makes run 2 evidence
#          about truncation and not about the fall.
$ErrorActionPreference = 'Stop'
$watch = (Join-Path $PSScriptRoot 'c-space-watch.ps1')
$stamp = Get-Date -Format 'HHmmss'
$base = Join-Path $env:TEMP "csw-trunc-$stamp"
$watched = Join-Path $base 'watched'
$state = Join-Path $base 'state'
$state3 = Join-Path $base 'state-first'
$state4 = Join-Path $base 'state-control'
$empty = Join-Path $base 'no-sandboxes'
$hidden = Join-Path $env:TEMP "csw-trunc-hidden-$stamp"
$logPath = Join-Path $state 'c-space-watch.log'
New-Item -ItemType Directory -Force -Path (Join-Path $watched 'a'), (Join-Path $watched 'b'), $state, $state3, $state4, $empty, $hidden | Out-Null
foreach ($d in @('a', 'b')) { fsutil file createnew (Join-Path $watched "$d\blob.bin") (20MB) | Out-Null }

function Invoke-Watch([string[]]$Switches = @(), [string]$StateDir = $state, [int]$Budget = 40) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watch,
        '-NoToast', '-NoSweep', '-NoCorrelate',
        '-StateDir', $StateDir,
        '-WatchRoot', (Join-Path $watched '*'),
        '-SandboxRoot', $empty,
        '-TimeBudgetSeconds', [string]$Budget)
    foreach ($s in $Switches) { $a += "-$s" }
    return (& powershell.exe @a 2>&1 | Out-String)
}
function Alert([string]$StateDir) { Get-Content -LiteralPath (Join-Path $StateDir 'C-SPACE-ALERT.txt') -Raw }
# The advice is a paragraph: its first line starts at column 0 and the rest are indented.
function Advice([string]$Text) {
    $out = @()
    $in = $false
    foreach ($l in ($Text -split "`n")) {
        if ($l -match '^what to do:') { $in = $true }
        elseif ($in -and $l.Trim() -eq '') { break }
        if ($in) { $out += $l.Trim() }
    }
    return ($out -join ' ')
}
# Only the growth section's own placeholder lines: a "(none ..." at two spaces. Matching
# the words instead would catch the cache line, which has a first-sample wording of its own
# that this test has no business calling a growth list.
function GrowthList([string]$Text) { (@($Text -split "`n") | Where-Object { $_ -match '^  \(none' }) -join ' / ' }

# --- run 1: a complete sample, and a fall it cannot explain
$null = Invoke-Watch
fsutil file createnew (Join-Path $hidden 'fall1.bin') (400MB) | Out-Null
$len = @(Get-Content -LiteralPath $logPath).Count

# --- run 2: the same fall, truncated
$null = Invoke-Watch -Switches 'Simulate' -Budget 0
$log2 = @(Get-Content -LiteralPath $logPath | Select-Object -Skip $len) -join "`n"
$alert2 = Alert $state
$advice2 = Advice $alert2

# --- run 3: truncated on a first sample
$null = Invoke-Watch -Switches 'Simulate' -StateDir $state3 -Budget 0
$alert3 = Alert $state3
$advice3 = Advice $alert3
$growth3 = GrowthList $alert3

# --- run 4: control -- its own baseline, another fall, a complete scan
$null = Invoke-Watch -StateDir $state4
fsutil file createnew (Join-Path $hidden 'fall2.bin') (400MB) | Out-Null
$null = Invoke-Watch -Switches 'Simulate' -StateDir $state4
$alert4 = Alert $state4
$advice4 = Advice $alert4

Remove-Item -LiteralPath $hidden -Recurse -Force -ErrorAction SilentlyContinue

"run 2 advice  : $advice2"
"run 3 advice  : $advice3"
"run 3 growth  : $growth3"
"run 4 advice  : $advice4"
"run 2 log     : $((($log2 -split "`n") | Where-Object { $_ -match 'sized only|scan truncated' }) -join ' | ')"

$fail = @()
# run 2: the budget is the explanation, and it is the only one offered
if ($log2 -notmatch 'sized only \d+ director\(ies\)') { $fail += 'the fixture did not truncate the scan (no log note)' }
if ($log2 -notmatch '\[scan truncated at 0s\]') { $fail += 'the log summary does not mark the scan truncated' }
if ($advice2 -notmatch 'ran out of its time budget') { $fail += 'a truncated no-grower alert has no budget advice' }
if ($advice2 -notmatch 'may simply not have been measured') { $fail += 'the budget advice does not say the directory may have been missed' }
if ($advice2 -notmatch 'cannot say that nothing grew') { $fail += 'the budget advice does not say the empty ranking proves nothing' }
if ($advice2 -match 'free space fell') { $fail += 'a truncated alert got the fall advice, which names causes it cannot rule out' }
if ($advice2 -match 'shadow copies and restore points') { $fail += 'a truncated alert points at shadow copies as if the roots had been fully scanned' }
if ($advice2 -match 'first sample') { $fail += 'a truncated alert used the first-sample wording' }
if ($advice2 -match 'nothing grew enough') { $fail += 'a truncated alert still says nothing grew' }
# run 3: truncation outranks "first sample", including in the growth list
if ($advice3 -notmatch 'ran out of its time budget') { $fail += 'a truncated first sample did not get the budget advice' }
if ($advice3 -match 'baseline the next run measures against') { $fail += 'a truncated first sample calls partial sizes a baseline' }
if ($growth3 -notmatch 'none ranked -- the scan stopped at its time budget') { $fail += "the growth list still claims nothing changed ($growth3)" }
if ($growth3 -match 'no directory changed by 1 MB or more') { $fail += 'the growth list makes a comparison the truncated scan did not finish' }
if ($growth3 -match 'this is the first sample') { $fail += 'a truncated first sample explains the empty list as a baseline' }
# run 4: the same shape of fall, fully measured, keeps the fall advice
if ($advice4 -notmatch 'free space fell') { $fail += 'a complete scan with a fall lost its fall advice (the fixture, not the branch, explains run 2)' }
if ($advice4 -match 'ran out of its time budget') { $fail += 'a complete scan got the budget advice' }

'---'
if ($fail.Count -gt 0) {
    $fail | ForEach-Object { "FAIL: $_" }
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}
Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
'PASS'
