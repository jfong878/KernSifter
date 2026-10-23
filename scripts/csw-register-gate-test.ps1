# csw-register-gate-test.ps1 -- -Register installs only a file whose suites have passed.
#
# -Register is elevated, and several suites cannot pass with an admin token by design (an
# elevated run declines the collector), so the check it makes is a receipt left by the
# runner rather than a test run of its own. That makes the gate liftable: the function is
# taken out of the script and fed receipts, so every refusal can be exercised without an
# administrator prompt and without installing anything.
#
# Checked here:
#   - no receipt, unreadable receipt, receipt for another file, a short sha256;
#   - a run that never finished, a failed run, a receipt with no suites;
#   - a receipt from an elevated run, which is not evidence;
#   - a matching green receipt, the only case that may install;
#   - and in the script itself, that the gate is consulted before anything is copied, that
#     it exits 4, and that -SkipTestGate is the documented way past it.
$ErrorActionPreference = 'Stop'
$watch = Join-Path $PSScriptRoot 'c-space-watch.ps1'
$src = Get-Content -LiteralPath $watch -Raw

$m = [regex]::Match($src, '(?ms)^function Test-TestReceipt.*?^}')
if (-not $m.Success) { throw 'could not lift Test-TestReceipt out of the script' }
Invoke-Expression $m.Value

$base = Join-Path $env:TEMP ("csw-gate-" + (Get-Date -Format 'HHmmss'))
New-Item -ItemType Directory -Force -Path $base | Out-Null
$subject = Join-Path $base 'subject.ps1'
$other = Join-Path $base 'other.ps1'
[System.IO.File]::WriteAllText($subject, "# the file under test`n", (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($other, "# a different file`n", (New-Object System.Text.UTF8Encoding($false)))
$hash = (Get-FileHash -LiteralPath $subject -Algorithm SHA256).Hash
$otherHash = (Get-FileHash -LiteralPath $other -Algorithm SHA256).Hash

function New-Receipt($fields) {
    $path = Join-Path $base ("receipt-" + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
    [System.IO.File]::WriteAllText($path, ($fields | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    return $path
}
function Receipt([hashtable]$over = @{}) {
    $r = @{ schema = 1; state = 'finished'; sha256 = $hash; suites = 24; passed = $true; failed = 0; elevated = $false }
    foreach ($k in $over.Keys) { $r[$k] = $over[$k] }
    return $r
}

$fail = New-Object System.Collections.Generic.List[string]
$cases = New-Object System.Collections.Generic.List[object]

function Check([string]$name, [bool]$expectAllowed, [string]$receipt, [string]$reasonPattern) {
    $r = Test-TestReceipt -scriptPath $subject -receiptPath $receipt
    $ok = ($r.Allowed -eq $expectAllowed)
    if ($ok -and $reasonPattern -and ($r.Reason -notmatch $reasonPattern)) { $ok = $false }
    $cases.Add([pscustomobject]@{ Name = $name; Allowed = $r.Allowed; Reason = $r.Reason; Ok = $ok })
    if (-not $ok) { $fail.Add("$name : allowed=$($r.Allowed) reason=$($r.Reason)") }
}

# --- the refusals
Check 'no receipt' $false (Join-Path $base 'nothing-here.json') 'no test receipt'
Check 'receipt for another file' $false (New-Receipt (Receipt @{ sha256 = $otherHash })) 'were not run against this file'
Check 'run never finished' $false (New-Receipt (Receipt @{ state = 'running' })) 'never finished'
Check 'failed run' $false (New-Receipt (Receipt @{ passed = $false; failed = 2 })) 'failed: 2 of 24'
Check 'no suites' $false (New-Receipt (Receipt @{ suites = 0 })) 'records no suites'
Check 'elevated run' $false (New-Receipt (Receipt @{ elevated = $true })) 'elevated run'
Check 'no sha256' $false (New-Receipt @{ state = 'finished'; suites = 24; passed = $true }) 'which file it tested'
Check 'short sha256' $false (New-Receipt (Receipt @{ sha256 = 'abc' })) 'were not run against this file'

$broken = Join-Path $base 'broken.json'
[System.IO.File]::WriteAllText($broken, '{ not json', (New-Object System.Text.UTF8Encoding($false)))
Check 'unreadable receipt' $false $broken 'cannot be read'

# --- the one that may install
Check 'matching green receipt' $true (New-Receipt (Receipt)) $null

$cases | ForEach-Object { '{0,-28} allowed={1,-5} {2}' -f $_.Name, $_.Allowed, $_.Reason }

# --- the wiring, read from the script itself: the gate must be consulted before the copy
$callAt = $src.IndexOf('Test-TestReceipt -scriptPath $PSCommandPath')
$copyAt = $src.IndexOf('Copy-Item -LiteralPath $PSCommandPath -Destination $installedPath')
$registerAt = $src.IndexOf('if ($Register) {')
"wiring           : call=$callAt  copy=$copyAt  register block=$registerAt"
if ($callAt -lt 0) { $fail.Add('the -Register block does not call Test-TestReceipt') }
if ($copyAt -lt 0) { $fail.Add('the install copy is gone, so this test proves nothing about ordering') }
if ($callAt -ge 0 -and $copyAt -ge 0 -and $callAt -gt $copyAt) { $fail.Add('the gate is consulted after the copy is installed') }
if ($registerAt -lt 0 -or $callAt -lt $registerAt) { $fail.Add('the gate call is outside the -Register block') }
if ($src -notmatch 'not registered -- \$\(\$gate\.Reason\)') { $fail.Add('the refusal does not print the receipt''s reason') }
if ($src -notmatch 'Join-Path \$StateDir ''test-receipt\.json''') { $fail.Add('the gate does not read the receipt the runner writes') }
if ($src -notmatch '(?m)^\s*exit 4\s*$') { $fail.Add('the refusal does not exit 4') }
if ($src -notmatch '\[switch\]\$SkipTestGate') { $fail.Add('-SkipTestGate is not a parameter') }
if ($src -notmatch 'installing without the suites') { $fail.Add('-SkipTestGate does not say what it is doing') }

Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
'---'
if ($fail.Count -gt 0) { $fail | ForEach-Object { "FAIL: $_" }; exit 1 }
'PASS'
