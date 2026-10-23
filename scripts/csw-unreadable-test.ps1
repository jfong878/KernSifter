# csw-unreadable-test.ps1 -- a directory the scan cannot read is unmeasured, not smaller.
#
# Three fixtures under %TEMP%, each with its own state directory, all run unelevated:
#   A  a subtree inside a sample is denied after the baseline. The walk coming back with
#      the readable part only must not be ranked (its delta would be a phantom -0.04 GB),
#      must not replace the 40 MB baseline, and must be named in the alert.
#   B  a watch root's own listing is denied. Its children are absent from this run's
#      samples; their last figures must survive in the state, and the alert must say the
#      root was not enumerated instead of "no directory changed".
#   C  a directory first seen while denied, then made readable. Its first measurement
#      must become a baseline rather than rank as +0.06 GB of growth.
# Run against the checkout by default; pass -Watch to exercise the installed copy instead.
param([string]$Watch = (Join-Path $PSScriptRoot 'c-space-watch.ps1'))
$ErrorActionPreference = 'Stop'
$watch = $Watch
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$stamp = Get-Date -Format 'HHmmss'
$base = Join-Path $env:TEMP "csw-unreadable-$stamp"
$empty = Join-Path $base 'no-sandboxes'
New-Item -ItemType Directory -Force -Path $base, $empty | Out-Null
$denied = New-Object System.Collections.Generic.List[string]

function Deny-Read([string]$dir) {
    & icacls.exe $dir /deny "$($user):(OI)(CI)(RX)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls deny failed on $dir" }
    $denied.Add($dir)
    # The fixture is only meaningful if the walk really is refused.
    try { $null = [System.IO.Directory]::EnumerateFileSystemEntries($dir); throw "the deny on $dir does not block enumeration" }
    catch [System.UnauthorizedAccessException] { }
}
function Allow-Read([string]$dir) {
    & icacls.exe $dir /remove:d $user | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls /remove:d failed on $dir" }
}
function Invoke-Watch([string]$state, [string]$root) {
    $call = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watch,
        '-NoToast', '-NoSweep', '-NoCorrelate', '-Simulate',
        '-StateDir', $state, '-SandboxRoot', $empty,
        '-WatchRoot', $root,
        '-TimeBudgetSeconds', '60')
    return (& powershell.exe @call 2>&1 | Out-String)
}
function Read-State([string]$state) { Get-Content -LiteralPath (Join-Path $state 'c-space-state.json') -Raw | ConvertFrom-Json }
function Growth-Section([string]$state) {
    $alertPath = Join-Path $state 'C-SPACE-ALERT.txt'
    if (-not (Test-Path -LiteralPath $alertPath)) { return '' }
    $lines = (Get-Content -LiteralPath $alertPath -Raw) -split "`n"
    $start = -1; $stop = $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($start -lt 0 -and $lines[$i] -match '^biggest growth') { $start = $i }
        elseif ($start -ge 0 -and $lines[$i] -match '^largest directories now') { $stop = $i; break }
    }
    if ($start -lt 0) { return '' }
    return (($lines[$start..($stop - 1)]) -join "`n")
}
function Largest-Section([string]$state) {
    $alertPath = Join-Path $state 'C-SPACE-ALERT.txt'
    if (-not (Test-Path -LiteralPath $alertPath)) { return '' }
    $lines = (Get-Content -LiteralPath $alertPath -Raw) -split "`n"
    $start = -1; $stop = $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($start -lt 0 -and $lines[$i] -match '^largest directories now') { $start = $i }
        elseif ($start -ge 0 -and $lines[$i] -match '^(what to do|NOTE:)') { $stop = $i; break }
    }
    if ($start -lt 0) { return '' }
    return (($lines[$start..($stop - 1)]) -join "`n")
}
function Alert-Text([string]$state) {
    $alertPath = Join-Path $state 'C-SPACE-ALERT.txt'
    if (-not (Test-Path -LiteralPath $alertPath)) { return '' }
    return (Get-Content -LiteralPath $alertPath -Raw)
}
function Shown([string]$text) { ($text.Trim() -replace "`r?`n", ' | ') }

$fail = New-Object System.Collections.Generic.List[string]

try {
    # ------------------------------------------------------------ A: a denied subtree
    $a = Join-Path $base 'a\watched\A'
    $b = Join-Path $base 'a\watched\B'
    $stateA = Join-Path $base 'a\state'
    New-Item -ItemType Directory -Force -Path (Join-Path $a 'locked'), $b, $stateA | Out-Null
    1..8 | ForEach-Object { fsutil file createnew (Join-Path $a "locked\a$_.bin") (5MB) | Out-Null }
    fsutil file createnew (Join-Path $b 'b.bin') (1MB) | Out-Null

    $null = Invoke-Watch $stateA (Join-Path $base 'a\watched\*')
    $s1 = Read-State $stateA
    $realA = [long]$s1.paths.$a
    "A baseline       : $([math]::Round($realA / 1MB, 1)) MB"
    if ($realA -lt 39MB) { $fail.Add("fixture A did not baseline fully ($realA bytes)") }

    Deny-Read (Join-Path $a 'locked')
    $null = Invoke-Watch $stateA (Join-Path $base 'a\watched\*')
    $s2 = Read-State $stateA
    $alert2 = Alert-Text $stateA
    $growth2 = Growth-Section $stateA
    "A after deny     : $(Shown $growth2)"
    "A state kept     : $([long]$s2.paths.$a -eq $realA)  unmeasured: $(@($s2.unmeasured) -join ',')"
    "A alert note     : $([bool]($alert2 -match 'could not read all of'))"
    if ([long]$s2.paths.$a -ne $realA) { $fail.Add("the readable part ($([long]$s2.paths.$a)) replaced A's baseline ($realA)") }
    if ($growth2 -match [regex]::Escape($a)) { $fail.Add('the unreadable tree appears in the growth section') }
    if ($growth2 -match '\-\d+\.\d\d GB') { $fail.Add('a phantom fall was ranked from the unreadable part') }
    if ($alert2 -notmatch 'could not read all of .*A -- 1 directory inside denied access') { $fail.Add('the alert does not name the tree it could not read') }
    if ($alert2 -notmatch 'so its size is a floor and it is not ranked; its last figure is kept') { $fail.Add('the alert does not say the figure is a floor') }
    if ($alert2 -notmatch '\(none ranked -- 1 directory could not be read in full') { $fail.Add('the empty ranking blames the disk instead of the refusal') }
    if (@($s2.unmeasured) -notcontains $a) { $fail.Add('the state does not record A as unmeasured') }
    $largest2 = Largest-Section $stateA
    $floorRow = @($largest2 -split "`n" | Where-Object { $_ -match 'A\s+\(floor' } | ForEach-Object { $_.TrimEnd() })
    "A floor row      : $($floorRow -join ' | ')"
    if ($floorRow.Count -ne 1) { $fail.Add('the largest-directories row does not say its figure is a floor') }
    elseif ($floorRow[0] -notmatch '\(floor, not a size -- part of this tree could not be read\)$') { $fail.Add('the floor row carries the wrong reason') }

    Allow-Read (Join-Path $a 'locked')
    $null = Invoke-Watch $stateA (Join-Path $base 'a\watched\*')
    $s3 = Read-State $stateA
    $growth3 = Growth-Section $stateA
    "A read again     : $(Shown $growth3)"
    "A state now      : $([math]::Round([long]$s3.paths.$a / 1MB, 1)) MB  unmeasured: $(@($s3.unmeasured).Count)"
    if ([math]::Abs([long]$s3.paths.$a - $realA) -gt 1MB) { $fail.Add('a readable re-measurement did not settle on the same size') }
    if ($growth3 -match [regex]::Escape($a)) { $fail.Add('the restored tree was ranked as growth against the kept baseline') }
    if (@($s3.unmeasured).Count -ne 0) { $fail.Add('the state still lists A as unmeasured after a full read') }
    if ((Largest-Section $stateA) -match 'floor, not a size') { $fail.Add('a fully read tree still carries a floor marker') }

    # ------------------------------------------------------------ B: a denied root
    $star = Join-Path $base 'b\star'
    $root = Join-Path $star 'root'
    $stateB = Join-Path $base 'b\state'
    New-Item -ItemType Directory -Force -Path $root, $stateB | Out-Null
    1..3 | ForEach-Object { fsutil file createnew (Join-Path $root "r$_.bin") (4MB) | Out-Null }

    $null = Invoke-Watch $stateB (Join-Path $base 'b\star\*')
    $b1 = Read-State $stateB
    $realR = [long]$b1.paths.$root
    "B baseline       : $([math]::Round($realR / 1MB, 1)) MB"

    Deny-Read $star
    $null = Invoke-Watch $stateB (Join-Path $base 'b\star\*')
    $b2 = Read-State $stateB
    $alertB = Alert-Text $stateB
    $growthB = Growth-Section $stateB
    "B after deny     : $(Shown $growthB)"
    "B state kept     : $([long]$b2.paths.$root -eq $realR)"
    if ([long]$b2.paths.$root -ne $realR) { $fail.Add('a denied root dropped its children from the state') }
    if ($alertB -notmatch 'could not enumerate .*star -- its children keep their last figures') { $fail.Add('the alert does not say the root was not enumerated') }
    if ($alertB -notmatch '\(none ranked -- a watch root could not be enumerated') { $fail.Add('an empty ranking beside a denied root reads as a quiet disk') }
    if ($alertB -match '\(none -- no directory changed by 1 MB or more') { $fail.Add('the alert claims nothing changed while a root was unreadable') }
    if (@($b2.unmeasured) -notcontains $root) { $fail.Add('the state does not record the denied root''s children as unmeasured') }

    Allow-Read $star
    $null = Invoke-Watch $stateB (Join-Path $base 'b\star\*')
    $b3 = Read-State $stateB
    $growthB3 = Growth-Section $stateB
    "B read again     : $(Shown $growthB3)"
    if ([long]$b3.paths.$root -ne $realR) { $fail.Add('the restored root did not re-measure to its kept figure') }
    if ($growthB3 -match [regex]::Escape($root)) { $fail.Add('a restored root was ranked as growth against the kept figure') }

    # ------------------------------------------------------------ C: first seen denied
    $late = Join-Path $base 'c\late'
    $f = Join-Path $late 'F'
    $e = Join-Path $late 'E'
    $stateC = Join-Path $base 'c\state'
    New-Item -ItemType Directory -Force -Path $f, $stateC | Out-Null
    fsutil file createnew (Join-Path $f 'f.bin') (2MB) | Out-Null

    $null = Invoke-Watch $stateC (Join-Path $base 'c\late\*')
    $c1 = Read-State $stateC
    "C baseline       : F $([math]::Round([long]$c1.paths.$f / 1MB, 1)) MB"

    New-Item -ItemType Directory -Force -Path $e | Out-Null
    1..2 | ForEach-Object { fsutil file createnew (Join-Path $e "e$_.bin") (3MB) | Out-Null }
    Deny-Read $e
    $null = Invoke-Watch $stateC (Join-Path $base 'c\late\*')
    $c2 = Read-State $stateC
    $alertC = Alert-Text $stateC
    "C after deny     : unmeasured: $(@($c2.unmeasured) -join ',')  in paths: $($null -ne $c2.paths.$e)"
    if ($null -ne $c2.paths.$e) { $fail.Add('a tree first seen while denied was given a figure') }
    if (@($c2.unmeasured) -notcontains $e) { $fail.Add('a tree first seen while denied was not recorded as unmeasured') }
    if ($alertC -notmatch 'could not read all of .*E') { $fail.Add('the alert does not name the tree it could not read') }

    Allow-Read $e
    $null = Invoke-Watch $stateC (Join-Path $base 'c\late\*')
    $c3 = Read-State $stateC
    $growthC3 = Growth-Section $stateC
    "C read again     : $(Shown $growthC3)"
    "C state now      : E $([math]::Round([long]$c3.paths.$e / 1MB, 1)) MB  unmeasured: $(@($c3.unmeasured).Count)"
    if ([long]$c3.paths.$e -lt 6MB) { $fail.Add("E's first readable figure was not recorded ($([long]$c3.paths.$e) bytes)") }
    if ($growthC3 -match [regex]::Escape($e)) { $fail.Add("a first measurement was ranked as growth: $(Shown $growthC3)") }
    if ($growthC3 -notmatch '1 directory had no earlier figure') { $fail.Add('the alert does not say why E has no earlier figure') }
    if ($growthC3 -notmatch 'could not be read\s+last run') { $fail.Add('the alert does not say E was unreadable last run') }
    if ($growthC3 -match 'no directory changed by 1 MB or more') { $fail.Add('an unmeasured first sighting reads as a quiet disk') }
    if (@($c3.unmeasured).Count -ne 0) { $fail.Add('E is still listed as unmeasured after a full read') }
} finally {
    foreach ($d in $denied) { & icacls.exe $d /remove:d $user 2>&1 | Out-Null }
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

'---'
if ($fail.Count -gt 0) { $fail | ForEach-Object { "FAIL: $_" }; exit 1 }
'PASS'
