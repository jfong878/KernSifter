<#
.SYNOPSIS
    Run a cargo build on the F: volume and detect corrupt-artifact failures.

.DESCRIPTION
    F: is a USB volume that still emits `disk` Event Id 11 controller errors
    (hardware/transport level — the 2026-09-27 Repair-Volume fixed the
    filesystem, not this). rustc reads .rmeta dependency metadata straight back
    off disk and trusts it, so an artifact that lands on a bad sector panics
    the compiler with

        invalid enum variant tag while decoding `TyKind`, expected 0..29, actual N

    and then reports thousands of bogus trait-bound errors. That reads like a
    source regression but is corrupt build input; no compiler flag fixes it.

    This wrapper exists so that failure is reported as what it is. It runs the
    real cargo command, watches the output for corruption signatures, and on a
    hit purges the target dir via `cargo clean` so the next build starts from
    clean input. It also reports any Id 11 events that landed during the build,
    because those are the upstream cause even when the build happens to
    succeed.

.PARAMETER CargoArgs
    Arguments forwarded to cargo, verbatim. Defaults to `build`.

    IMPORTANT: this script deliberately does NOT use [CmdletBinding()] or a
    param() block. Doing so makes PowerShell try to bind anything shaped like
    `-name` to a parameter, which silently swallows cargo's own flags —
    `check -p core-engine` was observed to arrive as plain `cargo check`,
    quietly building the whole workspace instead of one crate. Everything is
    forwarded through $args untouched, and only the literal token `-NoPurge`
    is intercepted.

.EXAMPLE
    .\scripts\invoke-build.ps1
    .\scripts\invoke-build.ps1 check --workspace
    .\scripts\invoke-build.ps1 check -p core-engine
    .\scripts\invoke-build.ps1 build --release -p core-engine
    .\scripts\invoke-build.ps1 check -p core-engine -NoPurge   # diagnose only

.NOTES
    Exit codes:
      0  build succeeded
      N  cargo's own exit code (build genuinely failed, no corruption detected)
     90  corruption detected; cache purged; rerun the build
     91  corruption detected, -NoPurge given; rerun after `cargo clean`
#>

# Verbatim argument forwarding: strip only our own flag, pass the rest to cargo.
$NoPurge = $false
$CargoArgs = @()
foreach ($a in $args) {
    if ($a -eq '-NoPurge' -or $a -eq '--no-purge') { $NoPurge = $true } else { $CargoArgs += $a }
}
if ($CargoArgs.Count -eq 0) { $CargoArgs = @('build') }

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot

# Build logs are throwaway diagnostics -> .freebuff\scratch\, per AGENTS.md.
$scratch = Join-Path $repoRoot '.freebuff\scratch'
if (-not (Test-Path $scratch)) {
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null
}
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $scratch "build-$stamp.log"

# Id 11 = disk controller error. Counted before the build so the delta is
# attributable to this run. Returns -1 only if the query genuinely failed.
#
# Note: "No events were found that match the specified selection criteria" is
# the *normal* result on a healthy volume, and -ErrorAction Stop promotes it to
# a terminating error. Treating that as a failure would report -1 whenever F:
# is quiet -- i.e. exactly when you most want the guard to keep working -- so it
# is mapped to 0 here and only real faults fall through to -1.
function Get-DiskErrorCount {
    try {
        $since = (Get-Date).AddHours(-1)
        @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 11; StartTime = $since } `
            -ErrorAction Stop).Count
    } catch {
        if ($_.Exception.Message -match 'No events were found') { return 0 }
        -1
    }
}

$errorsBefore = Get-DiskErrorCount

Write-Host "kernsifter: cargo $($CargoArgs -join ' ')" -ForegroundColor Cyan
Write-Host "kernsifter: log -> $logFile"
if ($errorsBefore -ge 0) {
    Write-Host "kernsifter: disk Id 11 events in the last hour: $errorsBefore"
}
Write-Host 'kernsifter: --- cargo output ---'

# cargo reports progress on stderr. With $ErrorActionPreference = 'Stop' (set
# above, and wanted for the rest of this script) PowerShell promotes every such
# line to a terminating NativeCommandError and kills the run on the first
# "Compiling ..." — so relax it for the duration of the call only, and flatten
# each record to its message with "$_" so the log holds plain cargo text rather
# than PowerShell error formatting.
$prevErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& cargo @CargoArgs 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $logFile
$cargoExit = $LASTEXITCODE
$ErrorActionPreference = $prevErrorActionPreference

Write-Host 'kernsifter: --- end cargo output ---'

$errorsAfter = Get-DiskErrorCount
$newDiskErrors = if ($errorsAfter -ge 0 -and $errorsBefore -ge 0) { $errorsAfter - $errorsBefore } else { -1 }

# --- Corruption signatures -------------------------------------------------
# High confidence: these can only mean the bytes we just read back are wrong.
$corruptPatterns = @(
    'invalid enum variant tag while decoding',
    'failed to parse fingerprint',
    'Checksum verification failed',
    'bad CRC'
)

# Low confidence: often a real problem, but not always corruption. Report only.
$warnPatterns = @(
    'failed to read',
    'os error 5',
    'Incorrect function',
    'The system cannot find the file specified'
)

$output = Get-Content $logFile -Raw -ErrorAction SilentlyContinue
if ($null -eq $output) { $output = '' }

$corruptHits = @($corruptPatterns | Where-Object { $output -match [regex]::Escape($_) })
$warnHits    = @($warnPatterns    | Where-Object { $output -match [regex]::Escape($_) })

if ($newDiskErrors -gt 0) {
    Write-Host ''
    Write-Host "kernsifter: WARNING - $newDiskErrors new disk Id 11 controller error(s) during this build." -ForegroundColor Yellow
    Write-Host 'kernsifter: F: is dropping reads/writes. Artifacts written now may be silently bad.' -ForegroundColor Yellow
}

if ($warnHits.Count -gt 0 -and $corruptHits.Count -eq 0) {
    Write-Host ''
    Write-Host 'kernsifter: WARNING - read-failure patterns in output, corruption not confirmed:' -ForegroundColor Yellow
    $warnHits | ForEach-Object { Write-Host "kernsifter:   matched: $_" -ForegroundColor DarkYellow }
    Write-Host 'kernsifter: if the errors look bogus, re-run with --no-purge off and check `cargo clean`.' -ForegroundColor Yellow
}

if ($corruptHits.Count -gt 0) {
    Write-Host ''
    Write-Host 'kernsifter: CORRUPT BUILD CACHE DETECTED' -ForegroundColor Red
    $corruptHits | ForEach-Object { Write-Host "kernsifter:   matched: $_" -ForegroundColor Red }
    Write-Host 'kernsifter: This is corrupt build INPUT on F:, not a source regression.' -ForegroundColor Red
    Write-Host 'kernsifter: The trait-bound errors above are downstream noise; ignore them.' -ForegroundColor Red

    if ($NoPurge) {
        Write-Host 'kernsifter: --no-purge given, cache left in place. Run `cargo clean` then rebuild.' -ForegroundColor Red
        Pop-Location
        exit 91
    }

    Write-Host 'kernsifter: running `cargo clean` to purge the cache...' -ForegroundColor Red
    & cargo clean
    if ($LASTEXITCODE -ne 0) {
        Write-Host "kernsifter: cargo clean failed (exit $LASTEXITCODE)." -ForegroundColor Red
        Write-Host "kernsifter: remove the target dir manually: Remove-Item -Recurse -Force '$repoRoot\target'" -ForegroundColor Red
        Pop-Location
        exit 91
    }
    Write-Host 'kernsifter: cache purged. Rerun this command to rebuild from clean input.' -ForegroundColor Green
    Pop-Location
    exit 90
}

if ($cargoExit -ne 0) {
    Write-Host ''
    Write-Host "kernsifter: build FAILED (cargo exit $cargoExit), no corruption signature detected." -ForegroundColor Red
    Write-Host 'kernsifter: treating this as a genuine source/build error.' -ForegroundColor Red
    Pop-Location
    exit $cargoExit
}

Write-Host ''
Write-Host 'kernsifter: build OK, no corruption detected.' -ForegroundColor Green
Pop-Location
exit 0
