# csw-elevated-collector-test.ps1 -- an elevated run must not start the collector.
#
# The scheduled task runs with highest privileges and the collector is a .mjs in the
# library checkout, writable by this account. The gate therefore has to be on the
# process, not on the path: this test lifts the two functions that launch it, points
# them at a fake collector that records being run, and checks both halves:
#   A. $script:Elevated = true  -> Blocked, no node started, no marker, a note that
#                                  names the elevated run and the normal-prompt way out;
#   B. $script:Elevated = false -> the collector runs, its verdict is parsed, and the
#                                  top-grower action reports what it cleared.
# Lifting rather than running the script twice: the harness has to be able to say
# "elevated" without the test asking for an administrator token.
$ErrorActionPreference = 'Stop'
$watch = (Join-Path $PSScriptRoot 'c-space-watch.ps1')
$stamp = Get-Date -Format 'HHmmss'
$base = Join-Path $env:TEMP "csw-elevated-$stamp"
$scratch = Join-Path $base 'sandboxes'
$run = Join-Path $scratch 'run-dead'
$fake = Join-Path $base 'fake-collector.mjs'
$marker = Join-Path $base 'collector-ran.txt'
New-Item -ItemType Directory -Force -Path $run | Out-Null

$node = @(Get-Command node -CommandType Application -ErrorAction SilentlyContinue)
if ($node.Count -eq 0) { throw 'node is not on PATH, so the collector half cannot be tested' }

# A dead pid: the collector is only reached for a directory that looks like a sandbox.
$exited = Start-Process -FilePath $env:ComSpec -ArgumentList '/c', 'exit' -PassThru -WindowStyle Hidden
$exited.WaitForExit()
$deadPid = $exited.Id
$nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$json = [ordered]@{ pid = $deadPid; startedAt = $nowMs; dir = $run } | ConvertTo-Json -Compress
[System.IO.File]::WriteAllText((Join-Path $run '.owner.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
fsutil file createnew (Join-Path $run 'sandbox.bin') (2MB) | Out-Null

# The fake collector: proves whether it ran, and speaks the report format the real one
# uses so the parsed verdict can be checked too.
@'
import { writeFileSync } from 'node:fs';
writeFileSync(process.env.CSW_FAKE_MARKER, 'ran');
console.log('  scratch  ' + (process.env.REHEARSE_SCRATCH || ''));
console.log('  2.00 MB  run-dead  swept (dead owner)');
'@ | Set-Content -LiteralPath $fake -Encoding ASCII

# Never import code from the thing under test: lift the functions out of it.
$src = Get-Content -LiteralPath $watch -Raw
foreach ($name in @('Test-UnderRoot', 'Test-OwnerMarker', 'Test-ScratchRoot', 'Resolve-SandboxGrower', 'Invoke-RehearsalSweep', 'Invoke-GrowerSweep')) {
    $m = [regex]::Match($src, "(?ms)^function $name.*?^}")
    if (-not $m.Success) { throw "could not lift $name out of the script" }
    Invoke-Expression $m.Value
}
if ($src -notmatch '(?ms)if \(\$script:Elevated\) \{\r?\n\s+\$report\.Blocked = \$true') {
    throw 'the elevated gate is not in Invoke-RehearsalSweep where this test expects it'
}

$SandboxRoot = @($scratch)
$env:CSW_FAKE_MARKER = $marker
$grower = [pscustomobject]@{ Path = $run; Delta = [long](5MB) }
$fail = New-Object System.Collections.Generic.List[string]

# --- A. elevated: refuse before anything is started
$script:Elevated = $true
$a = Invoke-GrowerSweep -grower $grower -clientPath $fake
$ranMarker = Test-Path -LiteralPath $marker
"elevated  : blocked=$($a.Blocked) ran=$($a.Ran) swept=$(@($a.Swept).Count) collectorStarted=$ranMarker"
"  log     : $($a.Log)"
"  tag     : $($a.Tag)"
if (-not $a.Blocked) { $fail.Add('an elevated run did not report the collector as blocked') }
if ($a.Ran) { $fail.Add('an elevated run reported the collector as run') }
if ($ranMarker) { $fail.Add('an elevated run started the collector') }
if (@($a.Swept).Count -ne 0) { $fail.Add('an elevated run reported a sweep') }
if ($a.Log -notmatch 'elevated run does not execute the collector out of the checkout') { $fail.Add('the note does not name the elevated run as the reason') }
if ($a.Log -notmatch 'run c-space-watch\.ps1 from a normal prompt') { $fail.Add('the note does not say how to get the sweep') }
if ($a.Tag -notmatch 'an elevated run does not start the collector') { $fail.Add('the summary tag does not name the refusal') }
if ($a.BlockedNote -notmatch 'the top grower run-dead') { $fail.Add('the note does not name the sandbox it left') }

# --- B. not elevated: the same call still sweeps, through the same gate
$script:Elevated = $false
Remove-Item -LiteralPath $marker -ErrorAction SilentlyContinue
$b = Invoke-GrowerSweep -grower $grower -clientPath $fake
$ranMarkerB = Test-Path -LiteralPath $marker
"normal    : blocked=$($b.Blocked) ran=$($b.Ran) swept=$(@($b.Swept).Count) collectorStarted=$ranMarkerB"
"  log     : $($b.Log)"
if ($b.Blocked) { $fail.Add('an unelevated run was blocked') }
if (-not $b.Ran) { $fail.Add("an unelevated run did not start the collector ($($b.Log))") }
if (-not $ranMarkerB) { $fail.Add('an unelevated run did not reach the collector') }
if (@($b.Swept).Count -ne 1 -or $b.Swept[0].Name -ne 'run-dead') { $fail.Add('an unelevated run did not report the verdict it parsed') }
if ($b.Log -notmatch '--sweep cleared run-dead') { $fail.Add('an unelevated run did not log what it cleared') }

Remove-Item Env:\CSW_FAKE_MARKER -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
'---'
if ($fail.Count -gt 0) { $fail | ForEach-Object { "FAIL: $_" }; exit 1 }
'PASS'
