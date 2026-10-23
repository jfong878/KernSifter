# csw-shadow-parse-test.ps1 -- the reading of vssadmin's answer, without needing the answer.
#
# The command itself needs an elevated prompt, so the two functions are lifted out of the
# script and the parser is fed the shapes vssadmin prints: a normal association, an
# unbounded maximum, a second volume ahead of C:, "no shadow copies", and rubbish.
$ErrorActionPreference = 'Stop'
$watch = (Join-Path $PSScriptRoot 'c-space-watch.ps1')
$src = Get-Content -LiteralPath $watch -Raw
# Test-Elevated comes along: Get-ShadowStorage now asks whether the caller is elevated to
# decide how to word a refusal, and a lifted function needs the helper it calls.
foreach ($name in @('Test-Elevated', 'ConvertFrom-ShadowStorageText', 'Get-ShadowStorage')) {
    $m = [regex]::Match($src, "(?ms)^function $name.*?^}")
    if (-not $m.Success) { throw "could not lift $name out of the script" }
    Invoke-Expression $m.Value
}

$header = @'
vssadmin 1.1 - Volume Shadow Copy Service administrative command-line tool
(C) Copyright 2001-2013 Microsoft Corp.

Shadow Copy Storage association
'@
$normal = $header + @'
   For volume: (C:)\\?\Volume{11111111-2222-3333-4444-555555555555}\
   Shadow Copy Storage volume: (C:)\\?\Volume{11111111-2222-3333-4444-555555555555}\
   Used Shadow Copy Storage space: 2.34 GB (1%)
   Allocated Shadow Copy Storage space: 3.34 GB (1%)
   Maximum Shadow Copy Storage space: 24.2 GB (10%)
'@
$unbounded = $header + @'
   For volume: (C:)\\?\Volume{11111111-2222-3333-4444-555555555555}\
   Shadow Copy Storage volume: (C:)\\?\Volume{11111111-2222-3333-4444-555555555555}\
   Used Shadow Copy Storage space: 900 MB (1%)
   Allocated Shadow Copy Storage space: 1.5 GB (2%)
   Maximum Shadow Copy Storage space: UNBOUNDED (100%)
'@
$twoVolumes = $header + @'
   For volume: (D:)\\?\Volume{aaaaaaaa-2222-3333-4444-555555555555}\
   Shadow Copy Storage volume: (D:)\\?\Volume{aaaaaaaa-2222-3333-4444-555555555555}\
   Used Shadow Copy Storage space: 1.00 GB (1%)
   Allocated Shadow Copy Storage space: 1.50 GB (1%)
   Maximum Shadow Copy Storage space: 10 GB (10%)

   For volume: (C:)\\?\Volume{bbbbbbbb-2222-3333-4444-555555555555}\
   Shadow Copy Storage volume: (C:)\\?\Volume{bbbbbbbb-2222-3333-4444-555555555555}\
   Used Shadow Copy Storage space: 2.00 GB (1%)
   Allocated Shadow Copy Storage space: 4.00 GB (1%)
   Maximum Shadow Copy Storage space: 20 GB (10%)
'@
$none = "`nvssadmin 1.1 - Volume Shadow Copy Service administrative command-line tool`n`nNo shadow copies were found.`n"
$rubbish = "vssadmin 1.1`n`nError: something nobody has seen before.`n"

$r1 = ConvertFrom-ShadowStorageText -Text $normal -DriveLetter C
$r2 = ConvertFrom-ShadowStorageText -Text $unbounded -DriveLetter C
$r3 = ConvertFrom-ShadowStorageText -Text $twoVolumes -DriveLetter C
$r4 = ConvertFrom-ShadowStorageText -Text $none -DriveLetter C
$r5 = ConvertFrom-ShadowStorageText -Text $rubbish -DriveLetter C
$r6 = ConvertFrom-ShadowStorageText -Text '' -DriveLetter C

"normal      : measured=$($r1.Measured) used=$([math]::Round($r1.Used/1GB,2)) alloc=$([math]::Round($r1.Allocated/1GB,2)) max=$([math]::Round($r1.Max/1GB,2))"
"unbounded   : measured=$($r2.Measured) alloc=$([math]::Round($r2.Allocated/1GB,2)) used=$([math]::Round($r2.Used/1GB,2)) max-null=$($null -eq $r2.Max)"
"two volumes : measured=$($r3.Measured) alloc=$([math]::Round($r3.Allocated/1GB,2)) max=$([math]::Round($r3.Max/1GB,2))"
"none        : measured=$($r4.Measured) alloc=$($r4.Allocated) reason=$($r4.Reason)"
"rubbish     : measured=$($r5.Measured) reason=$($r5.Reason)"
"empty       : measured=$($r6.Measured) reason=$($r6.Reason)"

# The real query on this machine: it may measure (elevated) or explain the refusal, but it
# must never come back silent -- the alert prints whatever verdict it gets.
$real = Get-ShadowStorage -DriveLetter C
"real query  : measured=$($real.Measured) alloc=$($real.Allocated) reason=$($real.Reason)"

$fail = @()
if (-not $r1.Measured) { $fail += 'a normal association was not read' }
if ([math]::Round($r1.Used / 1GB, 2) -ne 2.34) { $fail += "used space wrong (saw $($r1.Used))" }
if ([math]::Round($r1.Allocated / 1GB, 2) -ne 3.34) { $fail += "allocated space wrong (saw $($r1.Allocated))" }
if ([math]::Round($r1.Max / 1GB, 2) -ne 24.2) { $fail += "maximum wrong (saw $($r1.Max))" }
if (-not $r2.Measured) { $fail += 'an unbounded maximum stopped the reading' }
if ([math]::Round($r2.Allocated / 1GB, 2) -ne 1.5) { $fail += "allocated space wrong when unbounded (saw $($r2.Allocated))" }
if ([math]::Round($r2.Used / 1MB, 0) -ne 900) { $fail += "used space wrong in MB (saw $($r2.Used))" }
if ($null -ne $r2.Max) { $fail += 'an unbounded maximum was turned into a number' }
if (-not $r3.Measured) { $fail += 'two associations stopped the reading' }
if ([math]::Round($r3.Allocated / 1GB, 2) -ne 4) { $fail += "the D: association was read instead of C: (saw $($r3.Allocated))" }
if (-not $r4.Measured) { $fail += '"no shadow copies" was treated as unreadable' }
if ($r4.Allocated -ne 0) { $fail += '"no shadow copies" produced a non-zero allocation' }
if ($r5.Measured) { $fail += 'unreadable output was reported as measured' }
if ($r5.Reason -notmatch 'could not be read') { $fail += "unreadable output has no reason (saw '$($r5.Reason)')" }
if ($r6.Measured -or -not $r6.Reason) { $fail += 'empty output has no verdict' }
if (-not $real.Measured -and -not $real.Reason) { $fail += 'the real query returned neither a measurement nor a reason' }

'---'
if ($fail.Count -gt 0) { $fail | ForEach-Object { "FAIL: $_" }; exit 1 }
'PASS'
