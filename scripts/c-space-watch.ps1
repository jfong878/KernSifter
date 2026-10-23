<#
.SYNOPSIS
  Watches C: free space, and when it falls too low -- or drops too fast -- says which
  directory grew.

.DESCRIPTION
  C: went from 47 GB to single digits twice by silent accumulation: killed rehearsal
  runs left ~1.6 GB clones in %TEMP%, browser caches refilled, telemetry grew. Nothing
  reported it; the first sign was a refused write.

  This is the tripwire. Each run:
    - reads free space (one Get-Volume call -- no scanning);
    - sizes the watch roots' immediate children, which is where that growth lands;
    - compares each directory with the previous sample to rank the growers;
    - alerts on a breach of -MinFreeGB, on a drop of -DropGB or more since the last
      sample, or when forced with -Simulate.

  An alert means: a desktop toast (best effort -- Focus Assist can suppress it), a
  durable C-SPACE-ALERT.txt next to the state file, and the append-only log. The exit
  code is 1 while the drive is breaching, so Task Scheduler's "Last Run Result" shows
  it too. Re-alerts are throttled to one per -ReAlertHours.

  It does not stop at describing the leak. A sandbox whose owner is gone is deleted
  before the sample -- the fallback for the kill that outran both the reaper and the
  next rehearsal -- and if the top grower is still a rehearsal sandbox this run asks
  the harness's own collector (`node .freebuff/rehearse-release.mjs --sweep`) to clear
  that root and re-reads free space, so the alert carries the number AFTER the fix
  rather than asking you to go and do it. The grower half keeps no copy of the rule:
  the collector decides (a dead owner, a 'keep' flag, the 24 h cap that breaks a
  recycled pid, a marker naming some other directory) and this run reports its
  verdict. -NoSweep turns both halves off.

  The collector is never started by an elevated run. It is not installed with this
  script: it is a file in the library checkout, under the profile, where anything
  running as this account can rewrite it, so starting it from the highest-privileges
  task would run that file -- and the node found on PATH -- as administrator. The task
  still sweeps stale sandboxes with its own installed code, but a grown sandbox that
  only the collector may judge is named and left, with the command to run from a normal
  prompt to clear it.

  Only immediate children of each root are measured: that names the culprit
  (`...\Temp\maktabat-rehearse-release`, `...\Local\Google`) without walking the whole
  volume, which a 15-minute watchdog cannot afford. A run is bounded by
  -TimeBudgetSeconds; a truncated scan is reported as such rather than trusted.

  A short root list can miss the real grower -- a build, a clone, a library import
  lands in a project tree nobody listed. So when an alert's fall is not explained by
  the roots, the run also walks -CorrelateRoot (the profile by default) for files
  WRITTEN in the window since the previous sample and names the directories holding
  them, with the dropped/written totals side by side. That walk is the expensive half
  (~60 s over 300k files): it runs only on an unexplained drop, honours
  -CorrelateBudgetSeconds, and says when it truncated. -NoCorrelate turns it off.

  What the walk names is carried into the next run's watch roots (the state file), and
  kept there while that directory keeps growing, so a leak that continues is ranked by
  the cheap sample instead of walking the profile again. A promotion drops out after
  the first run that sees nothing new there -- and, because a permanently churning
  directory is "still growing" forever, after -PromotedMaxRuns runs regardless, with
  at most -MaxPromotedRoots measured in any one run. Expiry is a cooling-off, not a
  blacklist: the directory is kept out of the measure set for -PromotionCooldownHours
  afterwards, so the very next walk cannot promote it straight back. Without that, the
  per-entry bound and the count bound would only take turns, and a cache that churns
  all day would be sampled every other run indefinitely. How often each directory has
  been promoted and cooled is kept in the state (-PromotionHistoryMax directories,
  longest-unseen first out), so a grower that returns after its cooldown is reported as
  a repeat rather than as a new discovery. Those counts age: an entry not seen churning
  for -PromotionHistoryDays (30 by default) is forgotten, so a directory that settled
  down after a bad week is a new finding if it ever comes back, not a repeat offender.
  Both halves travel with the file: each entry carries expiresAt, and `historyPolicy`
  records the cutoff and bounds in force, so the numbers are readable without the
  command line that wrote them.

  Caches are the other half of that: Chrome's and Edge's cache directories and the
  desktop updater's downloaded payload are regenerable, so when one of them is the top
  grower AND the drive is actually short, its contents are cleared here -- the
  directory stays -- and free space is re-read. A cache is performance rather than
  garbage, so the clear stops at -CacheMaxClearGB and reports what it left. When the
  top grower is not one of those directories the alert says so, rather than leaving its
  cache section empty -- and likewise when there is no top grower at all (a first sample,
  a scan that ran out of budget, or a fall with nothing growing to explain it), which is
  also why its growth list says which of those happened instead of conflating them. In
  the last case the advice does not invent a directory to start with: it names what can
  consume space without growing anything down -WatchRoot -- shadow copies, the pagefile
  and hibernation file, deleted files still held open, trees outside the watched roots --
  and the alert measures the three that are one thing on a volume. They share a single
  `not ranked` line: the pagefile and the hibernation file are sized straight off the
  volume root, which needs no elevation, and the shadow figure comes from vssadmin, which
  answers a figure, "none", or "unknown" with the reason -- so one unreadable measurement
  never hides the two that are readable. The figures are also carried between samples and
  compared: the line says which of the three grew since they were last measured, or that
  none did -- which is itself the answer, the fall being something other than these -- and
  names any of the three it could not compare, so one that went unmeasured is never read as
  unchanged. Only the shadow half needs elevation, which is
  why the scheduled task is registered with highest privileges (-Register): a sample
  started by hand from an unelevated prompt still says "unknown" for it. A first sample
  gets a third wording -- there is no ranking yet, and the sizes above are what the next
  run will measure against -- and a scan that ran out of its time budget gets a fourth:
  an empty ranking is what the budget left, not a finding, because the directory that
  grew may never have been reached. A directory the budget cut through is named in the
  alert and left out of the ranking entirely: its size is a fraction of its tree, so a
  delta from it measures the cutoff rather than the disk, and that fraction is not
  carried into the next sample's baseline either.

  The run after a cut-short sample applies the same rule to what that scan never
  reached. A directory with no earlier figure is unmeasured, not new: it is left out of
  the ranking, counted in the alert, and its size becomes the baseline the next run
  compares against. Without that, a first sample that ran out of time made the next run
  report every tree it had not reached as growth. A directory that appears after a
  complete sample still ranks, because then its absence really does mean it was not
  there.

  A directory the walk is not allowed into is unmeasured for the other reason, and gets
  the same treatment: the sum holds only the part that could be read, so it is a floor
  rather than a size. It is named in the alert, left out of the ranking, and the figure
  the last readable sample gave it stays the baseline -- recording the readable part
  would report the rest of the tree as growth on the run that can read it again, and
  report the same part as a fall on this one. A root that refuses to be listed at all
  keeps its children's figures the same way, instead of dropping them, which would make
  the next readable sample call each of them new and rank whole trees as growth.

  -DryRun answers the same question without acting on it: the stale sandboxes the
  pre-sample sweep would remove are named with their sizes, the collector is asked
  `--sweep --dry-run` what it would clear (its rule, not a second copy of it), the
  cache plan is reported within the cap, and nothing is deleted or journalled anywhere.
  A plan that lives only in the log is a preview nobody can find, so the plan is also
  written to C-SPACE-ALERT.txt -- even when the drive is healthy and the run would not
  have alerted -- under a `C: SPACE PLAN (dry run)` header. It is still not an alert: no
  toast, exit code 0, and the state file's alert clock is left alone.

  State, log and alert file live outside the watched volume, in
  %LOCALAPPDATA%\c-space-watch by default, so the evidence survives the drive.

.PARAMETER Register
  Create (or replace) the per-user scheduled task that runs this script every
  -EveryMinutes. It is registered with highest privileges, because vssadmin reports
  shadow-copy storage only to an elevated caller -- the measurement a fall-with-nothing-
  growing alert asks for. Task Scheduler accepts that run level only from an elevated
  prompt, so run -Register from one; from a limited prompt it refuses and prints the
  command to use, rather than registering a task that would keep answering "unknown".
  The logon stays interactive, so the task runs only while you are signed in (a toast
  needs a session) and nobody is prompted at each tick.

  The task does not run this file where it sits. It runs a copy installed in -InstallDir,
  a directory only administrators can write, because this file sits under the profile,
  where the account holds full control all the way down: a script an elevated task runs
  from there can be replaced by any process running without elevation, which is the same
  thing as handing that process an administrator. -Register copies the file, checks the
  copy hashes to the source, refuses an -InstallDir whose permissions let a limited
  process write, and records both hashes beside the copy. Editing the checkout therefore
  does not change what the task runs until -Register is run again -- and a run of the
  installed copy says so in the log and in the alert, instead of leaving an old rule in
  place silently.

.PARAMETER Unregister
  Remove the scheduled task.

.PARAMETER InstallDir
  Where -Register installs the copy the task runs. Defaults to C:\Program Files\C-Space
  Watch, which inherits write access for Administrators and SYSTEM only. Point it
  elsewhere only at a directory that answers the same way: -Register audits the
  permissions and refuses to register against one that does not.

.EXAMPLE
  powershell -NoProfile -File scripts\c-space-watch.ps1
  # one sample; prints the verdict and the biggest growers

.EXAMPLE
  powershell -NoProfile -File scripts\c-space-watch.ps1 -Simulate -NoToast
  # prove the alert path without waiting for the drive to fill

.EXAMPLE
  powershell -NoProfile -File scripts\c-space-watch.ps1 -Register
#>
[CmdletBinding()]
param(
    # The volume to watch. One letter.
    [string]$DriveLetter = 'C',

    # Alert when free space falls below this. 80 GB of 237 GB leaves ~30 GB of runway
    # before the 47 GB state that already caused refused writes.
    [double]$MinFreeGB = 80,

    # Alert when free space fell this much since the previous sample, even above the
    # floor: a rehearsal run that leaks 1.6 GB should be visible the same hour.
    [double]$DropGB = 3,

    # At most one alert per this many hours while the condition persists.
    [int]$ReAlertHours = 6,

    # What to measure. An entry ending in `*` measures each immediate child (the
    # children are what get named); any other entry measures that directory itself.
    # Defaults are the directories that have actually grown on this machine, chosen
    # to scan in ~15 s -- whole-profile roots (Local\Microsoft, Chrome User Data)
    # cost minutes and are deliberately not in the list.
    [string[]]$WatchRoot,

    [int]$Top = 3,

    # Give up sizing after this long and report a truncated scan. The directory it stopped
    # in is named and left out of the ranking; its partial size is not kept as a baseline.
    [int]$TimeBudgetSeconds = 120,

    # Where the state, log and alert file live. Defaults to
    # %LOCALAPPDATA%\c-space-watch -- never inside the watched volume's project trees.
    [string]$StateDir,

    # Rehearsal scratch roots whose dead sandboxes are swept before each sample, and
    # whose top-grower sandboxes are cleared after it by the collector (an elevated run
    # reports that one instead of starting it). Defaults to the Maktabat
    # rehearsal's scratch root. This is the last line of defence: the run's own reaper
    # handles a kill, the next rehearsal sweeps any corpse the reaper missed, and this
    # covers the case where neither happens.
    [string[]]$SandboxRoot,

    # Clear nothing at all: no sandbox sweep, no collector, no cache clearing. Silent by
    # itself; pair it with -DryRun to see what it would have cleared.
    [switch]$NoSweep,

    # A sandbox is stale when its owner is gone, or -- for kept or markerless ones --
    # when it is this many hours old. 24 h matches the rehearsal's own startup sweep.
    # This governs the pre-sample sweep only: the collector applies its own cap to the
    # top-grower run.
    [int]$SandboxMaxAgeHours = 24,

    # The rehearsal's own collector, `node <this> --sweep`, which clears stale sandboxes
    # and starts nothing. The top-grower action runs it instead of deleting by itself,
    # except when this run is elevated: the file it names is one this account can rewrite,
    # so an elevated run declines and says so. Defaults to the harness in the library
    # checkout beside this one.
    [string]$RehearsalCli,

    # Directories treated as regenerable: browser caches and the desktop updater's
    # payload. When one of these is the top grower and the drive is short, its CONTENTS
    # are cleared here (the directory stays) instead of being merely named. Defaults to
    # the Chrome and Edge caches that have grown on this machine plus the updater's
    # download directory. A path is cleared because it is listed here, never because of
    # its name.
    [string[]]$CacheRoot,

    # The most one run will free from those directories. A cache is performance rather
    # than garbage, so the clear is bounded: whatever is past the cap is left and
    # reported.
    [double]$CacheMaxClearGB = 5,

    # Report every action and delete nothing at all -- no cache files, no sandboxes, no
    # collector, no journal. The pre-sample sweep names the stale sandboxes it would
    # remove with their sizes, the harness's collector is asked with `--sweep --dry-run`
    # what it would clear, and the cache action reports its plan within the cap -- or says
    # there is none, because the cache action only runs while the drive is short. The plan
    # is written to C-SPACE-ALERT.txt even when no alert would have been raised.
    [switch]$DryRun,

    # A drop can land outside the watch roots -- a build, a clone, a library import.
    # When this much of the fall is unexplained by them, the run walks -CorrelateRoot
    # for files written inside the window and names the directories. 0.5 GB keeps the
    # ~40-90 s walk off runs that are only seeing cache churn.
    [double]$CorrelateMinGB = 0.5,

    # Where the correlation looks. Defaults to the profile, which is where every drop
    # observed on this machine has come from. Narrow it, or add roots, with -CorrelateRoot.
    [string[]]$CorrelateRoot,

    # Hard cap on the windowed walk. It is truncated rather than trusted when it hits
    # this, and the alert says so. ~60 s for 300k files on this machine.
    [int]$CorrelateBudgetSeconds = 90,

    # Only directories holding at least this much new data are worth naming.
    [double]$CorrelateMinMB = 100,

    # How many runs a promoted root is measured for before it is dropped and the next
    # alert's correlation has to name it again. 4 runs is about an hour at the 15-minute
    # cadence: long enough for a continuing leak to be caught by the cheap sample, short
    # enough that a permanently churning directory cannot own a slot forever.
    [int]$PromotedMaxRuns = 4,

    # Once a promotion has spent those runs, how long the directory stays out of the
    # measure set even if a walk names it again. Without a cooldown, a permanently
    # churning directory is re-promoted by the very next correlation and the per-entry
    # bound never bites. Hours, not runs, because the walk only happens on an unexplained
    # drop: 6 h is the re-alert window, so a directory can only come back after another
    # drop has had its chance to point somewhere else. 0 disables the cooldown.
    [int]$PromotionCooldownHours = 6,

    # How many directories the promotion history remembers. Each entry is a path and two
    # counters, so this only has to be deep enough to recognise a churn that comes back
    # after its cooldown; 64 is many cycles on the slowest churn this machine has shown.
    # Entries seen longest ago are dropped first when it overflows.
    [int]$PromotionHistoryMax = 64,

    # How long a promotion-history entry stays meaningful after the last time it was seen
    # churning. The counts are a statement about current behaviour, not a permanent
    # record: a directory that churned for a week and has been quiet for a month is a new
    # finding when it comes back, not a repeat offender. 0 keeps entries forever.
    [int]$PromotionHistoryDays = 30,

    # The most promoted roots measured in one run. The sample is the cheap half of this
    # task and any one promoted tree is a walk of unknown size, so the list is bounded
    # as a whole as well as per entry.
    [int]$MaxPromotedRoots = 6,

    # Measure only; do not correlate a drop with files written in the window.
    [switch]$NoCorrelate,

    # Force the breach path (threshold treated as met) and skip the re-alert throttle.
    [switch]$Simulate,

    [switch]$NoToast,
    [switch]$NoState,
    [switch]$Quiet,

    [switch]$Register,
    [switch]$Unregister,
    [int]$EveryMinutes = 15,
    [string]$TaskName = 'C Space Watch',

    # Where -Register installs the copy the task runs. Only administrators can write here,
    # which is the point rather than the tidiness: the task starts with an elevated token,
    # so a script it runs from a directory a limited process can write is a way to run
    # anything as administrator -- replacing the file is the whole exploit. -Register
    # audits whatever this points at and refuses to register against a directory that
    # answers any other way, so the default is the safe place, not just the obvious one.
    [string]$InstallDir = 'C:\Program Files\C-Space Watch'
)

$ErrorActionPreference = 'Continue'
$script:Now = Get-Date

# One switch that promises "nothing is deleted": a dry run must not clear a cache and
# then quietly sweep a sandbox, because the whole point is to look before trusting it.
if ($DryRun) { $NoSweep = $true }

# ---------------------------------------------------------------- paths / task
if (-not $StateDir) { $StateDir = Join-Path $env:LOCALAPPDATA 'c-space-watch' }
$logPath = Join-Path $StateDir 'c-space-watch.log'
$statePath = Join-Path $StateDir 'c-space-state.json'
$alertPath = Join-Path $StateDir 'C-SPACE-ALERT.txt'

# vssadmin answers the shadow-copy question only with an elevated token, and Task
# Scheduler only accepts a Highest-privileges registration from one. Both halves of that
# are asked here so the answer is the same whether it is a registration or a measurement.
function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# One answer for the whole run. The registration blocks and the measurement have to agree
# about whether this process is elevated, and asking once makes that structural rather than
# something each caller has to remember.
$script:Elevated = Test-Elevated

# Can something running at ordinary integrity replace what lives in this directory? That
# is the question the elevated task's own script placement has to answer, so it is answered
# by walking the directory's permissions rather than by trusting the location's reputation:
# a directory that grants write to Users, Authenticated Users, Everyone, Interactive or the
# signed-in account is writable by a process without elevation, and a script kept there is
# a way to run code as administrator.
function Test-InstallDirProtected([string]$Path) {
    $writeBits = [System.Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteAttributes, WriteExtendedAttributes, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'
    $admins = @()
    foreach ($name in @('BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM', 'NT SERVICE\TrustedInstaller')) {
        try { $admins += (New-Object System.Security.Principal.NTAccount($name)).Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { }
    }
    try { $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop } catch {
        return [pscustomobject]@{ Ok = $false; Findings = @("the permissions of $Path could not be read: $($_.Exception.Message)") }
    }
    $findings = New-Object System.Collections.Generic.List[string]
    foreach ($ace in $acl.Access) {
        if ($ace.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
        if (($ace.FileSystemRights -band $writeBits) -eq 0) { continue }
        $sid = try { $ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { $null }
        if ($sid -and ($admins -contains $sid)) { continue }
        # CREATOR OWNER hands the creator of a file full control of that file. It is not a
        # way in on its own: creating anything here is gated by the same check, so the only
        # principal that could be a creator is one that already passed it.
        if ($sid -eq 'S-1-3-0') { continue }
        $findings.Add(('{0} can write ({1})' -f $ace.IdentityReference.Value, $ace.FileSystemRights))
    }
    return [pscustomobject]@{ Ok = ($findings.Count -eq 0); Findings = @($findings) }
}

# The installed copy is the one the task runs, so an edit to the checkout no longer reaches
# the task by itself. Without a line saying that, an improvement would sit in the repository
# while the task went on running last month's rules -- the failure would be silent, and
# silence is exactly what this script exists to break. This compares the copy with the
# manifest -Register wrote beside it and the checkout with the hash it was installed from.
# It is not the security check (that is the directory's permissions, verified at install);
# it is how a stale install stops being invisible.
function Get-InstallNote {
    if (-not $PSCommandPath) { return $null }
    $installedPath = Join-Path $InstallDir 'c-space-watch.ps1'
    if ([System.IO.Path]::GetFullPath($PSCommandPath) -ne [System.IO.Path]::GetFullPath($installedPath)) { return $null }
    $manifestPath = Join-Path $InstallDir 'install.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        return ('no manifest beside this copy -- re-run -Register from the checkout')
    }
    try { $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json } catch {
        return ('the manifest beside this copy is unreadable -- re-run -Register from the checkout')
    }
    $self = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    if ($self -ne $manifest.installedSha256) {
        return ('this copy does not match its manifest -- it was replaced or damaged; re-run -Register from the checkout')
    }
    if (-not $manifest.sourcePath -or -not (Test-Path -LiteralPath $manifest.sourcePath)) {
        return ('the checkout it was installed from is gone ({0}) -- re-run -Register once it is back' -f $manifest.sourcePath)
    }
    $source = (Get-FileHash -LiteralPath $manifest.sourcePath -Algorithm SHA256).Hash
    if ($source -ne $manifest.sourceSha256) {
        return ('the checkout has changed since this copy was installed -- run -Register from an elevated prompt to deploy it ({0})' -f $manifest.sourcePath)
    }
    return $null
}

if ($Unregister) {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $existing) { Write-Host "no task named '$TaskName'"; exit 0 }
    # Removal can be refused now that the task runs elevated (it is stored under System32),
    # so a refusal has to say what it means and print the command, rather than leaving a
    # raw access-denied in the middle of a run that otherwise reports success.
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Host "removed scheduled task '$TaskName'"
        exit 0
    } catch {
        Write-Host ("could not remove '{0}': {1}" -f $TaskName, $_.Exception.Message)
        if (-not $script:Elevated) {
            Write-Host '  it runs elevated, so it has to be removed from an elevated prompt:'
            Write-Host ('  powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -Unregister' -f $PSCommandPath)
        }
        exit 2
    }
}

if ($Register) {
    # Refuse rather than fall back to a limited task: that task would look registered and
    # then answer "unknown" to the one question the alert cannot otherwise answer, which
    # is exactly the guess the shadow line exists to replace.
    if (-not $script:Elevated) {
        Write-Host 'not registered -- a highest-privileges task has to be created from an elevated prompt'
        Write-Host '  (vssadmin reports shadow-copy storage only to an elevated caller, and Task'
        Write-Host '   Scheduler accepts that run level only from one)'
        Write-Host ''
        Write-Host ('  powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -Register' -f $PSCommandPath)
        exit 2
    }
    # The task starts elevated, so it must not run a file anything at ordinary integrity
    # can replace: the checkout is under the profile, where jfong holds full control all
    # the way down. Registering a copy here is the fix, and the permission audit below is
    # what keeps it a fix -- registering in place would have been the whole problem back.
    $installedPath = Join-Path $InstallDir 'c-space-watch.ps1'
    $manifestPath = Join-Path $InstallDir 'install.json'
    if ([System.IO.Path]::GetFullPath($PSCommandPath) -eq [System.IO.Path]::GetFullPath($installedPath)) {
        Write-Host 'not registered -- this is the installed copy, not the checkout'
        Write-Host '  register from the file you edit, so the copy has a source to be compared against:'
        Write-Host '  powershell -NoProfile -ExecutionPolicy Bypass -File "<checkout>\scripts\c-space-watch.ps1" -Register'
        exit 2
    }
    if (-not (Test-Path -LiteralPath $InstallDir)) {
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    }
    # Audited while the directory is still empty: a copy the task would run must not exist
    # for even one tick in a directory that fails this.
    $protection = Test-InstallDirProtected $InstallDir
    if (-not $protection.Ok) {
        Write-Host "not registered -- $InstallDir is writable by something other than administrators:"
        foreach ($finding in $protection.Findings) { Write-Host "  $finding" }
        Write-Host '  an elevated task must not run a file those principals can replace.'
        Write-Host '  point -InstallDir at a directory only administrators can write, or fix its permissions first.'
        exit 2
    }
    Copy-Item -LiteralPath $PSCommandPath -Destination $installedPath -Force
    $sourceHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    $installedHash = (Get-FileHash -LiteralPath $installedPath -Algorithm SHA256).Hash
    if ($sourceHash -ne $installedHash) {
        Write-Host "not registered -- the copy at $installedPath does not hash to the source"
        Write-Host "  source $sourceHash"
        Write-Host "  copy   $installedHash"
        exit 3
    }
    # Beside the copy, not in the state directory: the state directory is writable by the
    # user, and a record of what was installed can only be trusted where a replacement
    # cannot also rewrite it to match itself.
    [ordered]@{
        installedPath   = $installedPath
        installedSha256 = $installedHash
        sourcePath      = $PSCommandPath
        sourceSha256    = $sourceHash
        installedAt     = (Get-Date).ToString('o')
        installDir      = $InstallDir
    } | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
        '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Quiet' -f $installedPath
    )
    # A 10-year repetition stands in for "indefinitely": MaxValue is rejected on some
    # builds. StartWhenAvailable catches up after a sleep instead of skipping the tick.
    $trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) `
        -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    # Interactive is what keeps the run in the signed-in session, which a toast needs.
    # Highest is not a quiet UAC prompt: the task starts with the caller's elevated token,
    # so vssadmin answers every tick and nobody is asked anything.
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
        -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
        -Principal $principal `
        -Description 'Alerts when C: free space breaches its floor or drops fast, and names the directory that grew. Runs elevated so it can read shadow-copy storage.' `
        -Force | Out-Null
    $task = Get-ScheduledTask -TaskName $TaskName
    Write-Host ("registered '{0}' every {1} min -- state {2}" -f $TaskName, $EveryMinutes, $StateDir)
    Write-Host ("run level: {0} for {1} ({2} logon)" -f $task.Principal.RunLevel, $task.Principal.UserId, $task.Principal.LogonType)
    Write-Host ("installed: {0}" -f $installedPath)
    Write-Host ("  sha256 {0}" -f $installedHash)
    Write-Host ("  from   {0}" -f $PSCommandPath)
    Write-Host ("  only administrators can write {0}" -f $InstallDir)
    Write-Host ("next run: {0}" -f (Get-ScheduledTaskInfo -TaskName $TaskName).NextRunTime)
    exit 0
}

if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }

function Write-Log([string]$line) {
    try {
        if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 512KB) {
            Move-Item -LiteralPath $logPath -Destination "$logPath.1" -Force -ErrorAction SilentlyContinue
        }
        Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    } catch { }
    if (-not $Quiet) { Write-Host $line }
}

function Show-Toast([string]$title, [string]$message) {
    if ($NoToast) { return $false }
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
            [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $texts = $template.GetElementsByTagName('text')
        [void]$texts.Item(0).AppendChild($template.CreateTextNode($title))
        [void]$texts.Item(1).AppendChild($template.CreateTextNode($message))
        $toast = New-Object Windows.UI.Notifications.ToastNotification $template
        $aumid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($aumid).Show($toast)
        return $true
    } catch {
        Write-Log "  (toast failed: $($_.Exception.Message))"
        return $false
    }
}

# ---------------------------------------------------------------- sizing
$script:Deadline = (Get-Date).AddSeconds($TimeBudgetSeconds)
$script:Truncated = $false
# The one directory the budget cut through, if any. Its sum is a fraction of its tree, so
# both its delta in this alert and its size in the next sample's baseline would be the
# scan's cutoff showing up as a change on disk.
$script:PartialPath = $null
# The directories the walk in progress was not allowed to enumerate. A tree holding one of
# these cannot be sized: what came back is the readable part, which is a floor rather than
# a measurement.
$script:Unreadable = @()
# Set when a dry-run measurement hits the budget: the report is a floor, but the scan
# itself has not run yet and must not inherit the flag.
$script:PreviewTruncated = $false

# A .NET method call surfaces its exception through PowerShell wrapped in
# MethodInvocationException, so the type that decides whether a walk was refused is the
# inner one. Missing that is why a denied tree used to look like a smaller one.
function Test-RefusedAccess($err) {
    $e = $err
    while ($e) {
        if ($e -is [System.UnauthorizedAccessException] -or $e -is [System.Security.SecurityException]) { return $true }
        $e = $e.InnerException
    }
    return $false
}

function Get-TreeBytes([string]$path, [switch]$Preview) {
    $sum = [long]0
    # Per call, not per run: the caller reads it right after the walk it belongs to.
    $script:Unreadable = @()
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($path)
    while ($stack.Count -gt 0) {
        if ((Get-Date) -gt $script:Deadline) {
            if ($Preview) { $script:PreviewTruncated = $true }
            else { $script:Truncated = $true; $script:PartialPath = $path }
            return $sum
        }
        $cur = $stack.Pop()
        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($cur)) {
                try { $sum += ([System.IO.FileInfo]$f).Length } catch { }
            }
        } catch {
            # Rights, not the clock and not a directory that vanished: the part of this
            # tree behind that refusal is invisible to the sum below.
            if (Test-RefusedAccess $_.Exception) { $script:Unreadable += $cur }
        }
        try {
            foreach ($d in [System.IO.Directory]::EnumerateDirectories($cur)) {
                try {
                    # A junction must not be walked: it would double-count (node_modules
                    # -> the checkout) or loop (AppData's compatibility junctions).
                    # GetAttributes is a static call; New-Object per directory costs
                    # ~1 ms on PS 5.1 and turned a 15 s scan into 50 s.
                    $attrs = [System.IO.File]::GetAttributes($d)
                    if (-not ($attrs -band [System.IO.FileAttributes]::ReparsePoint)) { $stack.Push($d) }
                } catch {
                    # A subdirectory that cannot even be stat'ed is a subtree this sum does
                    # not include, so the figure is short for the same reason.
                    if (Test-RefusedAccess $_.Exception) { $script:Unreadable += $d }
                }
            }
        } catch {
            if (Test-RefusedAccess $_.Exception) { $script:Unreadable += $cur }
        }
    }
    return $sum
}

function Format-GB([long]$bytes) { return ('{0,8:N2} GB' -f ($bytes / 1GB)) }

# ---------------------------------------------------------------- sandbox sweep
# The rehearsal writes an owner marker beside every sandbox (pid, startedAt, dir,
# keep). Its own reaper deletes the sandbox seconds after a kill, and the next
# rehearsal sweeps anything the reaper missed -- but if the reaper dies too and no
# rehearsal runs, the clone sits there. This task runs every 15 minutes, so it is
# the fallback: same interlocks, same 24 h cap, same journal.

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Add-JournalLine([string]$line) {
    # Same override the Node side honours (REHEARSE_JOURNAL), so a test can point both
    # at a throwaway file instead of the real audit trail.
    $journal = if ($env:REHEARSE_JOURNAL) { $env:REHEARSE_JOURNAL } else { Join-Path $env:LOCALAPPDATA 'maktabat-rehearse\sandbox-journal.jsonl' }
    try {
        $journalDir = Split-Path -Parent $journal
        if (-not (Test-Path -LiteralPath $journalDir)) { return }
        if ((Test-Path -LiteralPath $journal) -and (Get-Item -LiteralPath $journal).Length -gt 1MB) {
            Move-Item -LiteralPath $journal -Destination "$journal.1" -Force -ErrorAction SilentlyContinue
        }
        # Append without a BOM: Add-Content -Encoding UTF8 would prepend one when it has
        # to create the file after a rotation, and the reader would lose that line.
        [System.IO.File]::AppendAllText($journal, $line + [Environment]::NewLine, $script:Utf8NoBom)
    } catch { }
}

function Test-OwnerAlive([int]$ownerPid) {
    if ($ownerPid -le 0) { return $false }
    try {
        $null = [System.Diagnostics.Process]::GetProcessById($ownerPid)
        return $true
    } catch {
        return $false
    }
}

# One sandbox, judged and -- when it is stale -- deleted, for the pre-sample sweep.
# The top-grower action deliberately does NOT come through here: it asks the rehearsal's
# collector, so the harness's staleness rule is the only rule. This gate stays because
# a corpse has to be cleared even on a day no rehearsal is due to run, and because a
# sweep that only ever happens inside a rehearsal is how the drive filled up.
function Remove-StaleSandbox($dir, [int]$maxAgeHours, [datetime]$now, [switch]$Preview) {
    if ($dir.Name.StartsWith('.')) { return $null }
    $marker = $null
    foreach ($candidate in @((Join-Path $dir.FullName '.owner.json'), (Join-Path $dir.FullName 'sandbox\.owner.json'))) {
        if (Test-Path -LiteralPath $candidate) {
            try { $marker = Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
            break
        }
    }

    $ownerPid = 0
    if ($marker -and $marker.pid -as [int]) { $ownerPid = [int]$marker.pid }
    $hasOwner = ($null -ne $marker) -and ($ownerPid -gt 0)

    $startedAt = $dir.LastWriteTime
    if ($marker -and $marker.startedAt) {
        try { $startedAt = [System.DateTimeOffset]::FromUnixTimeMilliseconds([long]$marker.startedAt).LocalDateTime } catch { }
    }
    $ageHours = ($now - $startedAt).TotalHours

    # The reaper's interlock, mirrored: a marker may only authorise deleting
    # the directory it names, so a recycled pid or a copied marker gets no say.
    if ($marker -and $marker.dir) {
        $named = [string]$marker.dir
        try { $named = [System.IO.Path]::GetFullPath($named) } catch { }
        # The rehearsal names the SANDBOX (runDir\sandbox); a marker that names
        # the run directory is equally binding. Anything else is not ours.
        $named = $named.TrimEnd('\')
        $allowed = @($dir.FullName.TrimEnd('\'), (Join-Path $dir.FullName 'sandbox').TrimEnd('\'))
        if ($allowed -notcontains $named) {
            if ($VerbosePreference -ne 'SilentlyContinue') {
                Write-Log ("  refused {0}: its marker names {1}" -f $dir.Name, $marker.dir)
            }
            return $null
        }
    }

    # Same rules as the rehearsal's own startup sweep, plus its 'keep' flag:
    # a dead owner is decisive, 'keep' is a promise only the age cap breaks,
    # and a live owner is trusted only until the cap (pid reuse).
    $tooOld = "older than ${maxAgeHours}h"
    $reason = $null
    if ($marker -and $marker.keep -eq $true) {
        if ($ageHours -ge $maxAgeHours) { $reason = $tooOld }
    } elseif ($hasOwner) {
        if (-not (Test-OwnerAlive $ownerPid)) { $reason = "pid $ownerPid is gone" }
        elseif ($ageHours -ge $maxAgeHours) { $reason = $tooOld }
    } elseif ($ageHours -ge $maxAgeHours) {
        $reason = 'no owner marker'
    }
    if (-not $reason) { return $null }

    # A preview applies the same verdict and stops there. The size is measured first
    # because a real sweep learns it from the free-space delta and a dry run has no
    # delta -- "three sandboxes" says nothing about whether the sweep matters.
    if ($Preview) {
        $bytes = Get-TreeBytes $dir.FullName -Preview
        return [pscustomobject]@{ Name = $dir.Name; Path = $dir.FullName; Reason = $reason; AgeHours = [math]::Round($ageHours, 1); Bytes = [long]$bytes; Preview = $true }
    }

    # The interlock that matters: unlink the junction before a recursive delete,
    # or it can walk into the checkout's real node_modules.
    $link = Join-Path $dir.FullName 'sandbox\repo\node_modules'
    try {
        if (Test-Path -LiteralPath $link) {
            $item = Get-Item -LiteralPath $link -Force
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { $item.Delete() }
        }
    } catch { }

    try {
        Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop
        $record = [pscustomobject]@{ Name = $dir.Name; Path = $dir.FullName; Reason = $reason; AgeHours = [math]::Round($ageHours, 1) }
        Add-JournalLine ([ordered]@{
                at     = $now.ToUniversalTime().ToString('o')
                event  = 'swept'
                run    = $dir.Name
                dir    = $dir.FullName
                ms     = [long][math]::Round($ageHours * 3600000)
                reason = $reason
                by     = 'c-space-watch'
            } | ConvertTo-Json -Compress)
        return $record
    } catch {
        Write-Log ("  could not sweep {0}: {1}" -f $dir.Name, $_.Exception.Message)
    }
    return $null
}

function Invoke-SandboxSweep([string[]]$roots, [int]$maxAgeHours, [datetime]$now, [switch]$Preview) {
    $swept = @()
    foreach ($root in $roots) {
        if (-not $root) { continue }
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $full = (Resolve-Path -LiteralPath $root).Path
        # Never aim this at a drive root or the profile itself, even by accident.
        if ($full -match '^[A-Za-z]:\?$' -or $full -eq $env:USERPROFILE) { continue }

        foreach ($dir in (Get-ChildItem -LiteralPath $full -Force -Directory -ErrorAction SilentlyContinue)) {
            $one = Remove-StaleSandbox -dir $dir -maxAgeHours $maxAgeHours -now $now -Preview:$Preview
            if ($one) { $swept += $one }
        }
    }
    return $swept
}

function Test-OwnerMarker([string]$dir) {
    # The harness's own signature: a marker beside the run directory, or beside the
    # sandbox inside it. Presence alone is not enough to delete anything -- this only
    # decides whether a grown directory is worth putting to Remove-StaleSandbox.
    foreach ($candidate in @((Join-Path $dir '.owner.json'), (Join-Path $dir 'sandbox\.owner.json'))) {
        if (Test-Path -LiteralPath $candidate) { return $true }
    }
    return $false
}

function Test-UnderRoot([string]$path, [string]$root) {
    $r = $root.TrimEnd('\')
    if ($path.Equals($r, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $path.StartsWith($r + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

<#
  Which sandbox directories would free a sampled path?

  Two ways in, both narrow:
    - the path is a configured -SandboxRoot, or something under it (then every stale
      child is a candidate when the root itself grew);
    - the path is under TEMP and carries an owner marker, i.e. it is a rehearsal
      sandbox whose scratch root was never configured here (a second harness, a
      renamed root). Without this the action could only ever fire on the race where a
      run starts and dies inside the scan window, because the pre-sample sweep would
      have removed every older corpse already.

  A deeper path is mapped back to the run directory it belongs to: clearing
  `sandbox\repo` on its own would leave a half-sandbox behind. What is returned here
  still has to get past the collector, so a live owner or a marker naming some other
  directory is refused there -- this function only says "that is a sandbox".
#>
function Resolve-SandboxGrower([string]$path) {
    $out = @()
    $p = $path.TrimEnd('\')
    foreach ($root in @($SandboxRoot)) {
        if (-not $root) { continue }
        $full = $null
        try { $full = (Resolve-Path -LiteralPath $root -ErrorAction Stop).Path } catch { continue }
        $full = $full.TrimEnd('\')
        if ($p -eq $full) {
            foreach ($child in (Get-ChildItem -LiteralPath $full -Force -Directory -ErrorAction SilentlyContinue)) { $out += $child }
        } elseif (Test-UnderRoot $p $full) {
            $first = (($p.Substring($full.Length + 1)) -split '\\')[0]
            $item = Get-Item -LiteralPath (Join-Path $full $first) -Force -ErrorAction SilentlyContinue
            if ($item -and $item.PSIsContainer) { $out += $item }
        }
    }

    if ($out.Count -eq 0) {
        $tempRoots = @($env:TEMP, (Join-Path $env:LOCALAPPDATA 'Temp')) | Where-Object { $_ } | Select-Object -Unique
        $inTemp = $false
        foreach ($t in $tempRoots) { if (Test-UnderRoot $p $t) { $inTemp = $true; break } }
        # Never outside TEMP: a sandbox marker copied into a project tree must not turn
        # this into a delete tool for the checkout.
        if ($inTemp -and (Test-Path -LiteralPath $p -PathType Container) -and (Test-OwnerMarker $p)) {
            $out += (Get-Item -LiteralPath $p -Force)
        }
    }
    return $out
}

# ---------------------------------------------------------------- the collector
# Deleting a sandbox is the harness's decision, not this script's: the staleness rule
# (a dead owner, the 'keep' flag, the 24 h cap that breaks a recycled pid, the
# node_modules junction interlock) lives in the rehearsal's own sandbox module, and a
# second copy here is a second rule to drift. So when the top grower is a rehearsal
# sandbox this runs the harness's collector (`--sweep`) aimed at the root that holds
# that run, and reports ITS verdict. What this script still decides is identification:
# whether the grown directory is a sandbox at all.

function Find-RehearsalCli {
    # The harness lives in the library checkout beside this one. That folder's name
    # carries Arabic, and Windows PowerShell 5.1 reads this file as ANSI, so it is
    # matched rather than spelled -- a non-ASCII literal here would arrive mangled.
    $projects = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    if (-not $projects) { return $null }
    try {
        foreach ($dir in @(Get-ChildItem -LiteralPath $projects -Directory -Filter 'Maktabat-Abee-*' -ErrorAction Stop)) {
            $cli = Join-Path $dir.FullName '.freebuff\rehearse-release.mjs'
            if (Test-Path -LiteralPath $cli -PathType Leaf) { return $cli }
        }
    } catch { }
    return $null
}

# Is this directory a scratch root -- one whose children are all sandboxes? Aiming the
# collector at anything else would let it delete a 25-hour-old directory that is just
# some other program's temp data, because to the collector an unowned directory past
# the cap looks stale. A root with a sandbox still being created fails this and is
# reported instead of swept, which is the safe way to be wrong.
function Test-ScratchRoot([string]$path) {
    try { $children = @(Get-ChildItem -LiteralPath $path -Force -Directory -ErrorAction Stop) } catch { return $false }
    if ($children.Count -eq 0) { return $false }
    foreach ($child in $children) {
        if (-not (Test-OwnerMarker $child.FullName)) { return $false }
    }
    return $true
}

# One `--sweep` run aimed at -Root, with its report parsed back into verdicts. The exit
# code is carried, not judged here: 1 means a stale sandbox could not be removed and 2
# means the collector refused its flags, and the caller reports whichever it got.
function Invoke-RehearsalSweep([string]$clientPath, [string]$root, [switch]$Preview) {
    $report = [pscustomobject]@{
        Ran = $false; ExitCode = $null; Error = $null; Preview = [bool]$Preview
        Blocked = $false
        Root = $root; Scratch = $null; Freed = $null; WouldFree = $null
        Swept = @(); Kept = @(); StillThere = @(); WouldSweep = @(); Lines = @()
    }
    # The task runs with highest privileges, and the collector is not part of the copy
    # -Register installs: it is a script in the library checkout (or whatever -RehearsalCli
    # names), under the profile, where anything running as this account can replace it.
    # Starting it here would hand that file -- and the node it resolves through PATH -- the
    # administrator token -Register keeps the checkout away from. So an elevated run
    # declines, and the caller says why instead of reporting a sweep. What still runs is
    # the pre-sample sweep, which is this file's own code, installed where only
    # administrators can write.
    if ($script:Elevated) {
        $report.Blocked = $true
        $report.Error = 'an elevated run does not start the collector from the checkout'
        return $report
    }
    if (-not $clientPath) { $clientPath = Find-RehearsalCli }
    if (-not $clientPath) { $report.Error = 'no collector was found beside this checkout (pass -RehearsalCli)'; return $report }
    if (-not (Test-Path -LiteralPath $clientPath -PathType Leaf)) { $report.Error = "the collector is not at $clientPath"; return $report }
    $node = @(Get-Command node -CommandType Application -ErrorAction SilentlyContinue)
    if ($node.Count -eq 0) { $report.Error = 'node is not on PATH'; return $report }

    # REHEARSE_SCRATCH is the harness's own redirection (its tests use it), and it is
    # how the collector is aimed at the root that holds the grown sandbox without a
    # flag only this script would ever pass. Restored afterwards: this is a child
    # process's environment, not a settings change.
    $previous = $env:REHEARSE_SCRATCH
    try {
        if ($root) { $env:REHEARSE_SCRATCH = $root }
        # --dry-run is the collector's own preview: the same staleness rule and the same
        # measuring pass, so this script never decides stale and the report is still the
        # harness's verdict rather than a second copy of it.
        $sweepArgs = @($clientPath, '--sweep')
        if ($Preview) { $sweepArgs += '--dry-run' }
        $lines = @(& $node[0].Source @sweepArgs 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } catch {
        $report.Error = "the collector could not be started: $($_.Exception.Message)"
        return $report
    } finally {
        if ($null -eq $previous) { Remove-Item Env:\REHEARSE_SCRATCH -ErrorAction SilentlyContinue }
        else { $env:REHEARSE_SCRATCH = $previous }
    }

    $report.Ran = $true
    $report.ExitCode = $code
    $report.Lines = $lines
    # Each report line is padded with two spaces: size, name, then the verdict and its
    # reason. The reason is everything after the verdict with its leading punctuation
    # stripped, because 'kept' is printed with an em dash and this file must not depend
    # on how that character survived the console -- which may be as several letters.
    $verdictLine = '^\s*(?<size>[\d.]+ [BKMGT]B)\s{2,}(?<name>.+?)\s{2,}(?<verdict>would sweep|swept|kept|STILL THERE)\b(?<tail>.*)$'
    foreach ($line in $lines) {
        if ($line -match '^\s*scratch\s{2,}(?<path>.+?)\s*$') { $report.Scratch = $Matches['path']; continue }
        if ($line -match '^\s*freed\s+(?<freed>[\d.]+ [BKMGT]B)') { $report.Freed = $Matches['freed']; continue }
        if ($line -match '^\s*would free\s+(?<freed>[\d.]+ [BKMGT]B)') { $report.WouldFree = $Matches['freed']; continue }
        if ($line -notmatch $verdictLine) { continue }
        $name = $Matches['name'].Trim()
        $entry = [pscustomobject]@{
            Name   = $name
            Size   = $Matches['size']
            # 'swept (…)' and 'kept — …' are the two shapes: strip the bracket or dash
            # on both sides so the reason can be printed in brackets of our own.
            Reason = (($Matches['tail'] -replace '^[^A-Za-z0-9]+', '') -replace '[^A-Za-z0-9]+$', '').Trim()
            Path   = if ($report.Scratch) { Join-Path $report.Scratch $name } else { $null }
        }
        switch ($Matches['verdict']) {
            'would sweep' { $report.WouldSweep += $entry }
            'swept' { $report.Swept += $entry }
            'kept' { $report.Kept += $entry }
            default { $report.StillThere += $entry }
        }
    }
    return $report
}

# The top grower, acted on through the collector. Returns what the collector removed
# (for the sample and the free-space figure) plus two messages: Log, always written,
# and Tag, added to the summary line and the alert only when the run is worth flagging.
# With -Preview it asks the collector `--sweep --dry-run` instead and returns what it
# WOULD remove in Would -- nothing is deleted, so Swept stays empty.
function Invoke-GrowerSweep($grower, [string]$clientPath, [switch]$Preview) {
    $result = [pscustomobject]@{ Tag = $null; Log = $null; Blocked = $false; BlockedNote = $null; Swept = @(); Would = @(); Ran = $false }
    $runs = @(Resolve-SandboxGrower $grower.Path)
    if ($runs.Count -eq 0) { return $result }
    $names = @($runs | ForEach-Object { Split-Path -Leaf $_.FullName })
    $root = Split-Path -Parent $runs[0].FullName

    if (-not (Test-ScratchRoot $root)) {
        $result.Log = "  the top grower $($names -join ', ') looks like a sandbox, but $root is not a scratch root (it holds directories with no owner marker) -- the collector was not aimed at it"
        return $result
    }

    $report = Invoke-RehearsalSweep -clientPath $clientPath -root $root -Preview:$Preview
    $result.Ran = $report.Ran
    if (-not $report.Ran) {
        if ($report.Blocked) {
            # A refusal, not a failure. It still has to reach the alert: the biggest grower
            # the alert names IS the sandbox this run declined to clear, and an absent
            # "acted" line would read as "that directory is not a sandbox".
            $result.Blocked = $true
            $result.BlockedNote = "the top grower $($names -join ', ') is a rehearsal sandbox, but an elevated run does not execute the collector out of the checkout -- run c-space-watch.ps1 from a normal prompt to clear it"
            $result.Log = "  $($result.BlockedNote)"
            $result.Tag = 'sandbox left: an elevated run does not start the collector from the checkout'
            return $result
        }
        $result.Tag = "the rehearsal collector could not run ($($report.Error)); the top grower was left alone"
        $result.Log = "  $($result.Tag)"
        return $result
    }

    # A preview asks the collector the same question and stops before the deletion, so
    # the verdict still comes from the harness -- this script never decides stale.
    if ($Preview) {
        $would = @($report.WouldSweep | Where-Object { $names -contains $_.Name })
        $held = @($report.Kept | Where-Object { $names -contains $_.Name })
        $result.Would = $would
        if ($would.Count -gt 0) {
            $result.Log = "  --sweep --dry-run would clear " + (($would | ForEach-Object { "$($_.Name) ($($_.Reason), $($_.Size))" }) -join '; ') + ' -- nothing was deleted'
        } elseif ($held.Count -gt 0) {
            $result.Log = "  --sweep --dry-run would keep " + (($held | ForEach-Object { "$($_.Name) ($($_.Reason))" }) -join '; ')
        } else {
            $result.Log = "  --sweep --dry-run reported nothing for the top grower $($names -join ', '); the collector would clear nothing there"
        }
        return $result
    }

    $result.Swept = @($report.Swept)
    $own = @($report.Swept | Where-Object { $names -contains $_.Name })
    $still = @($report.StillThere | Where-Object { $names -contains $_.Name })
    $held = @($report.Kept | Where-Object { $names -contains $_.Name })

    if ($own.Count -gt 0) {
        $result.Log = "  --sweep cleared " + (($report.Swept | ForEach-Object { "$($_.Name) ($($_.Reason))" }) -join '; ')
        return $result
    }
    if ($still.Count -gt 0) {
        $result.Tag = "the collector could not remove the top grower: " + (($still | ForEach-Object { "$($_.Name) ($($_.Reason))" }) -join '; ')
        $result.Log = "  $($result.Tag)"
        return $result
    }
    if ($held.Count -gt 0) {
        # A live owner, or a 'keep' marker inside the cap: the normal case for a
        # rehearsal in progress, so it is logged and nothing more.
        $result.Log = "  --sweep kept " + (($held | ForEach-Object { "$($_.Name) ($($_.Reason))" }) -join '; ')
        return $result
    }
    # The collector never named the run: it swept a different root, or its report could
    # not be read. Nothing was deleted, and saying so beats silence.
    $result.Log = "  the collector reported nothing for the top grower $($names -join ', '); it was left alone"
    return $result
}

# ---------------------------------------------------------------- caches / updater payload
# Chrome and Edge caches, and the desktop updater's downloaded payload, are regenerable
# in the same sense a sandbox is -- but they are also performance, so they are cleared
# only while the drive is actually short and only up to -CacheMaxClearGB. The list is a
# parameter rather than a name pattern: a directory is cleared because it was configured
# as a cache, never because its path happens to contain the word "cache".

function Resolve-CacheGrower([string]$path) {
    # Exact, or inside a configured cache. A parent that merely CONTAINS one (Chrome's
    # User Data, say) is not a cache, and clearing it would take profiles with it.
    $p = $path.TrimEnd('\')
    foreach ($root in @($CacheRoot)) {
        if (-not $root) { continue }
        $full = $null
        try { $full = (Resolve-Path -LiteralPath $root -ErrorAction Stop).Path.TrimEnd('\') } catch { continue }
        if ($p -eq $full -or (Test-UnderRoot $p $full)) { return $full }
    }
    return $null
}

<#
  Clear a cache directory's contents, or say what it would clear.

  Contents only: the directory (and its parents) stay, so the next sample still finds
  the path it was measuring and a browser holding the directory open is left with
  something to hold. Files are removed until -MaxBytes is reached, so this can never
  free an unbounded amount in one run; whatever is past the cap is left and reported.
  A file that will not delete (in use) is counted, not fatal.
#>
function Clear-CacheTree([string]$path, [long]$maxBytes, [switch]$Preview) {
    $freed = [long]0
    $files = 0
    $inUse = 0
    $capped = $false
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($path)
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        try {
            foreach ($d in [System.IO.Directory]::EnumerateDirectories($cur)) {
                try {
                    # Never follow a junction: a cache holding one would walk out of the
                    # directory the cap was meant for.
                    $attrs = [System.IO.File]::GetAttributes($d)
                    if (-not ($attrs -band [System.IO.FileAttributes]::ReparsePoint)) { $stack.Push($d) }
                } catch { }
            }
        } catch { }
        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($cur)) {
                $len = [long]0
                try { $len = ([System.IO.FileInfo]$f).Length } catch { }
                if (($freed + $len) -gt $maxBytes) { $capped = $true; continue }
                try {
                    if (-not $Preview) { [System.IO.File]::Delete($f) }
                    $freed += $len
                    $files += 1
                } catch { $inUse += 1 }
            }
        } catch { }
    }
    return [pscustomobject]@{ Path = $path; Freed = $freed; Files = $files; InUse = $inUse; Capped = $capped; Preview = [bool]$Preview }
}

# ---------------------------------------------------------------- correlate a drop
# The watch roots are a short list chosen for cost, not a claim about where growth
# lands: a build, a clone or a library import lands in a project tree nobody listed.
# So when the roots cannot account for a fall, walk the correlate roots for files
# WRITTEN inside the window and rank their directories. This is the expensive part of
# the task (~60 s over 300k files), which is why it runs only on an alert whose drop
# the watched roots leave unexplained, inside its own budget, and says so if it
# truncates. The window is the interval between samples, so "written" means what it
# says rather than "recent-ish".

function Shorten-Path([string]$path) {
    foreach ($prefix in @($env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA)) {
        if ($prefix -and $path.StartsWith($prefix + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            return '~' + $path.Substring($prefix.Length)
        }
    }
    return $path
}

# Shadow copies are the one likely cause of a fall that no walk can see: their blocks
# belong to the volume, not to a directory tree. Windows reports them only to an elevated
# account -- vssadmin refuses otherwise, and the WMI class for it does not initialise on
# this machine -- so the answer comes back as a verdict that can be printed rather than a
# zero that would read as "none". Asked only when a fall has nothing in the ranked roots
# to blame.

# Split from the query so the parsing can be exercised without an elevated prompt: the
# command line is the part this machine cannot test, the reading of its output is not.
function ConvertFrom-ShadowStorageText([string]$Text, [string]$DriveLetter) {
    $result = [pscustomobject]@{ Measured = $false; Allocated = [long]0; Used = [long]0; Max = $null; Reason = $null }
    $raw = "$Text"
    if (-not $raw) { $result.Reason = 'its output was empty'; return $result }
    # One association per volume. The labels are localised, so the figures are read in the
    # order Windows prints them -- used, allocated, maximum -- and an unbounded maximum
    # simply leaves the third out rather than being invented as a number.
    $sizes = @()
    $inBlock = $false
    foreach ($line in @($raw -split "`r?`n")) {
        if ($line -match ('For volume:.*\(' + [regex]::Escape($DriveLetter) + ':\)')) { $inBlock = $true; continue }
        if ($inBlock -and $line -match 'For volume:') { break }
        if (-not $inBlock) { continue }
        foreach ($m in [regex]::Matches($line, '([\d]+(?:[.,]\d+)?)\s*(B|KB|MB|GB|TB)\b')) {
            $value = [double]($m.Groups[1].Value -replace ',', '.')
            $factor = switch ($m.Groups[2].Value.ToUpper()) { 'B' { 1 } 'KB' { 1KB } 'MB' { 1MB } 'GB' { 1GB } 'TB' { 1TB } }
            $sizes += [long]($value * $factor)
        }
    }
    if ($sizes.Count -ge 2) {
        $result.Measured = $true
        $result.Used = $sizes[0]
        $result.Allocated = $sizes[1]
        if ($sizes.Count -ge 3) { $result.Max = $sizes[2] }
    } elseif ($raw -match '(?i)no shadow') {
        # "No shadow copies were found": a real answer, and a reassuring one.
        $result.Measured = $true
    } else {
        $result.Reason = 'its output could not be read'
    }
    return $result
}

# Ask Windows, and turn a refusal into something the alert can say out loud.
function Get-ShadowStorage([string]$DriveLetter) {
    $raw = ''
    try {
        $raw = (& "$env:SystemRoot\System32\vssadmin.exe" list shadowstorage "/for=$DriveLetter`:" 2>&1 | Out-String)
        $code = $LASTEXITCODE
    } catch {
        return [pscustomobject]@{ Measured = $false; Allocated = [long]0; Used = [long]0; Max = $null
            Reason = "its query could not be started ($($_.Exception.Message))" }
    }
    if ($code -ne 0) {
        # A refusal has two different meanings now that the scheduled task runs elevated: in
        # a hand-started run it is the token, in an elevated one it is something else, and
        # saying "runs unelevated" there would be a wrong answer to the question asked.
        $reason = if ($raw -notmatch 'elevat|administrat|permission') {
            "its query failed (exit $code)"
        } elseif ($script:Elevated) {
            "its query was refused even when elevated (exit $code)"
        } else {
            'reading it needs an elevated prompt ("vssadmin list shadowstorage"); this run is unelevated'
        }
        return [pscustomobject]@{ Measured = $false; Allocated = [long]0; Used = [long]0; Max = $null
            Reason = $reason }
    }
    return ConvertFrom-ShadowStorageText -Text $raw -DriveLetter $DriveLetter
}

# The other two things that take space without growing a ranked directory are single files
# at the volume root, and unlike shadow storage they answer a limited caller. Windows hides
# both from Get-Item -- a hidden system file at the root is reported as "does not exist" --
# so the length is read through FileInfo, which does see them. Sizing them here rather than
# leaving them to the advice is the difference between "your pagefile could be holding it"
# and "your pagefile holds 4.35 GB".
function Get-PageFileInfo([string]$DriveLetter) {
    $result = [pscustomobject]@{ Measured = $false; Bytes = [long]0; Max = $null; Reason = $null }
    try {
        $info = New-Object System.IO.FileInfo "${DriveLetter}:\pagefile.sys"
        if (-not $info.Exists) { $result.Reason = "no pagefile.sys on $DriveLetter`:"; return $result }
        $result.Measured = $true
        $result.Bytes = [long]$info.Length
    } catch {
        $result.Reason = "it could not be read ($($_.Exception.Message))"
        return $result
    }
    # The configured ceiling is what says how much more this file may take, which is why the
    # shadow line carries its maximum too. It is optional: a system-managed pagefile can
    # report none, and a failure here must not cost the size that was just measured.
    try {
        $settings = @(Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction Stop |
            Where-Object { $_.Name -like "$DriveLetter`:*" })
        $max = ($settings | Measure-Object -Property MaximumSize -Maximum).Maximum
        if ($max -and $max -gt 0) { $result.Max = [long]$max * 1MB }
    } catch { }
    return $result
}

# Hibernation off and hiberfil.sys missing are two different answers: the file being absent
# is reassuring when nothing writes it and suspicious when something should. Windows keeps
# the setting in the power key, which is readable without elevation.
function Get-HibernationFileInfo([string]$DriveLetter) {
    $result = [pscustomobject]@{ Measured = $false; Bytes = [long]0; Reason = $null }
    try {
        $info = New-Object System.IO.FileInfo "${DriveLetter}:\hiberfil.sys"
        if ($info.Exists) {
            $result.Measured = $true
            $result.Bytes = [long]$info.Length
            return $result
        }
    } catch {
        $result.Reason = "it could not be read ($($_.Exception.Message))"
        return $result
    }
    $enabled = $null
    try {
        $enabled = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' `
            -Name 'HibernateEnabled' -ErrorAction Stop).HibernateEnabled
    } catch { }
    $result.Reason = if ($enabled -eq 0) { 'hibernation is off' } else { "no hiberfil.sys on $DriveLetter`:" }
    return $result
}

function Get-WrittenInWindow {
    param(
        [string[]]$Roots,
        [datetime]$Since,
        [int]$BudgetSeconds,
        [string[]]$Exclude,
        [long]$MinBytes,
        [int]$Top
    )
    $deadline = (Get-Date).AddSeconds($BudgetSeconds)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $sinceUtc = $Since.ToUniversalTime()
    $perDirBytes = @{}
    $perDirFiles = @{}
    $walked = [long]0
    $written = [long]0
    $truncated = $false
    $seen = @{}

    foreach ($root in $Roots) {
        if (-not $root) { continue }
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $full = (Resolve-Path -LiteralPath $root).Path.TrimEnd('\')
        # Two roots can nest; walking the parent already covers the child.
        $dominated = $false
        foreach ($other in $seen.Keys) { if (Test-UnderRoot $full $other) { $dominated = $true; break } }
        if ($dominated) { continue }
        $seen[$full] = $true

        $stack = New-Object System.Collections.Generic.Stack[string]
        $stack.Push($full)
        while ($stack.Count -gt 0) {
            if ((Get-Date) -gt $deadline) { $truncated = $true; break }
            $cur = $stack.Pop()
            $skip = $false
            foreach ($e in $Exclude) { if ($e -and (Test-UnderRoot $cur $e)) { $skip = $true; break } }
            if ($skip) { continue }

            $di = $null
            try { $di = [System.IO.DirectoryInfo]::new($cur) } catch { continue }
            try {
                foreach ($f in $di.EnumerateFiles()) {
                    $walked++
                    try {
                        # LastWriteTimeUtc is cached by the enumeration, so this is a
                        # property read, not a syscall per file.
                        if ($f.LastWriteTimeUtc -ge $sinceUtc) {
                            $len = [long]$f.Length
                            $written += $len
                            $perDirBytes[$cur] = [long]($perDirBytes[$cur]) + $len
                            $perDirFiles[$cur] = [int]($perDirFiles[$cur]) + 1
                        }
                    } catch { }
                }
            } catch { }
            try {
                foreach ($d in $di.EnumerateDirectories()) {
                    try {
                        if (-not ($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { $stack.Push($d.FullName) }
                    } catch { }
                }
            } catch { }
        }
        if ($truncated) { break }
    }
    $sw.Stop()

    $dirs = @($perDirBytes.GetEnumerator() |
        Where-Object { $_.Value -ge $MinBytes } |
        Sort-Object Value -Descending |
        Select-Object -First $Top |
        ForEach-Object { [pscustomobject]@{ Path = $_.Key; Bytes = [long]$_.Value; Files = [int]$perDirFiles[$_.Key] } })

    return [pscustomobject]@{
        WindowStart = $Since
        Dirs        = $dirs
        TotalBytes  = $written
        Walked      = $walked
        Truncated   = $truncated
        Seconds     = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
}

# ---------------------------------------------------------------- sample
$volume = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
if (-not $volume) {
    Write-Log ("{0:yyyy-MM-dd HH:mm:ss}  {1}: volume not found -- nothing to watch" -f $script:Now, $DriveLetter)
    exit 2
}
# Sweep first, so the free-space reading and the next drop comparison both
# describe the drive after the leak was removed -- but record that it happened.
$sweptSandboxes = @()
$sweptPlan = @()
$freeBeforeSweep = [long]$volume.SizeRemaining
# -DryRun forces -NoSweep, but the run still has to answer for the sweep it is declining
# to do: a dry run that reports only the cache half is answering half the question.
if (-not $NoSweep -or $DryRun) {
    if (-not $SandboxRoot) { $SandboxRoot = @((Join-Path $env:LOCALAPPDATA 'Temp\maktabat-rehearse-release')) }
    if ($DryRun) {
        $sweptPlan = @(Invoke-SandboxSweep $SandboxRoot $SandboxMaxAgeHours $script:Now -Preview)
    } else {
        $sweptSandboxes = @(Invoke-SandboxSweep $SandboxRoot $SandboxMaxAgeHours $script:Now)
        if ($sweptSandboxes.Count -gt 0) {
            $volume = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
            if (-not $volume) { Write-Log 'volume disappeared during the sandbox sweep'; exit 2 }
        }
    }
}

$freeBytes = [long]$volume.SizeRemaining
$totalBytes = [long]$volume.Size
$freeGB = [math]::Round($freeBytes / 1GB, 2)

# The previous sample is read before the scan now, not after it: its `promoted` list is
# what the last correlation asked to watch, and those roots have to be in the measure
# set before the first directory is sized.
$previous = $null
if (-not $NoState -and (Test-Path -LiteralPath $statePath)) {
    try {
        $previous = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch { Write-Log "  (unreadable state -- treating this as the first sample: $($_.Exception.Message))" }
}

# Whether that sample's `paths` map is a complete picture. A truncated run can leave one
# only when it carried a complete one; when it could not -- a first sample that ran out of
# time -- the directories it never reached are missing from the map, and the next run must
# not read a missing path as "did not exist". That is the difference between a directory
# that appeared since the last sample and one no sample has ever measured, and reading the
# second as the first reported whole trees as growth. States written before this field
# existed fall back to their own `truncated` flag, which is the same question: a truncated
# sample is not a complete baseline until a complete one follows it.
$previousBaselineComplete = if (-not $previous) { $false }
    elseif ($previous.PSObject.Properties['baselineComplete']) { [bool]$previous.baselineComplete }
    else { -not [bool]$previous.truncated }

$local = $env:LOCALAPPDATA
$roaming = $env:APPDATA
$chrome = Join-Path $local 'Google\Chrome\User Data\Default'
$edge = Join-Path $local 'Microsoft\Edge\User Data\Default'

if (-not $WatchRoot) {
    # Measured on this machine (-Verbose prints the per-root timings): Temp 1.4 s,
    # Packages 11.7 s, Roaming 20 s, ProgramData 12 s. The two whole-tree roots are
    # left out of the default set: 45 s every tick is not a lightweight watchdog,
    # and the observed growth landed in Temp and the caches. Add them back with
    # -WatchRoot 'C:\Users\...\AppData\Roaming\*' if you want the wider net.
    $WatchRoot = @(
        (Join-Path $local 'Temp\*'),
        'C:\Windows\Temp\*',
        (Join-Path $local 'Packages\*'),
        (Join-Path $roaming 'Freebuff'),
        (Join-Path $chrome 'Cache'),
        (Join-Path $chrome 'Code Cache'),
        (Join-Path $chrome 'Service Worker\CacheStorage'),
        (Join-Path $edge 'Cache'),
        (Join-Path $edge 'Service Worker\CacheStorage'),
        (Join-Path $local '@codebufffreebuff-desktop-updater')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath ($_.TrimEnd('*').TrimEnd('\'))) } | Select-Object -Unique
}

if (-not $CacheRoot) {
    $CacheRoot = @(
        (Join-Path $chrome 'Cache'),
        (Join-Path $chrome 'Code Cache'),
        (Join-Path $chrome 'Service Worker\CacheStorage'),
        (Join-Path $edge 'Cache'),
        (Join-Path $edge 'Service Worker\CacheStorage'),
        (Join-Path $local '@codebufffreebuff-desktop-updater')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
}

# ---------------------------------------------------------------- promoted roots
# The correlation names a directory by walking for files written in the window -- the
# expensive half of a run (~80 s over the profile). Sizing that directory in the next
# sample costs almost nothing, and it is what turns "found once, by a minute-long walk"
# into "watched from now on". A promotion is for the NEXT run: it is carried again while
# the directory keeps growing, so a continuing leak stays in the cheap sample and one
# that stopped drops back out.
#
# That rule alone has no ceiling: "still growing" is true of every permanently churning
# cache there is, so a directory could hold a slot forever. A promotion is therefore
# bounded twice -- -PromotedMaxRuns caps how many samples any one directory gets (the
# next alert's correlation can name it afresh), and -MaxPromotedRoots caps how many
# trees a single run walks, applied before the scan because that is the only place
# dropping a root saves anything.
$promoted = @()
# Each promotion carries the directory's size at the moment it was named, so the next
# sample subtracts a real baseline instead of counting the whole directory as new
# growth -- which would over-explain the drop and hide a fresh leak elsewhere.
$promotedBaseline = @{}
# How many samples each carried entry has already had; carried in the state so a run
# that is killed cannot reset the budget by forgetting it.
$promotedRuns = @{}
$promotedExpired = @()
$promotedTrimmed = @()
# A promotion that has spent its runs is remembered for -PromotionCooldownHours. Without
# it the next walk names the same directory and it is promoted straight back, so the
# per-entry bound and the count bound only take turns: a cache that churns all day would
# be sampled every other run for as long as the machine lives.
$promotedCooling = @()
$promotedCoolingUntil = @{}
$cooldown = @{}
$cooldownNext = [ordered]@{}
$cooldownHours = [math]::Max(0, $PromotionCooldownHours)
function Set-PromotionCooldown([string]$Path) {
    if ($cooldownHours -le 0) { return }
    $until = $script:Now.AddHours($cooldownHours)
    $cooldown[$Path] = $until
    $cooldownNext[$Path] = $until
}
# How long is left, not when it ends: the alert is read hours after it was written, and
# "until 07:48" then needs arithmetic the reader should not have to do.
# How an earlier measurement is named in the alert: the clock time when it was the same day,
# the date too when it was not, because "grew since 09:12" across two days reads as this
# morning and would make a 30-hour change look like a 3-hour one.
function Format-SampleTime([datetime]$At) {
    if ($At.Date -eq $script:Now.Date) { return $At.ToString('HH:mm') }
    return $At.ToString('MM-dd HH:mm')
}

function Format-CooldownLeft([datetime]$Until) {
    $minutes = [int][math]::Ceiling(($Until - $script:Now).TotalMinutes)
    if ($minutes -le 1) { return 'under a minute left' }
    $hours = [int][math]::Floor($minutes / 60)
    $rest = $minutes % 60
    if ($hours -le 0) { return "$minutes min left" }
    if ($rest -eq 0) { return "$hours h left" }
    return "$hours h $rest min left"
}
$promotionCap = [math]::Max(0, $MaxPromotedRoots)
# How many times each directory has been promoted and cooled off. It has to outlive the
# cooldown: one cycle here is 4 samples plus 6 h of cooling, and the walk that names the
# directory again comes after the cooldown entry has been forgotten. Without this a
# directory that has been through the cycle a dozen times is indistinguishable from the
# first leak the walk ever found.
$history = @{}
$historyMax = [math]::Max(0, $PromotionHistoryMax)
# The counts age out. A directory quiet for this long is read as a new finding rather
# than a repeat, which is the honest answer: nothing has churned there for a month.
$historyAged = 0
$historyCutoff = if ($PromotionHistoryDays -gt 0) { $script:Now.AddDays(-$PromotionHistoryDays) } else { $null }
if ($previous -and $previous.history) {
    foreach ($h in @($previous.history)) {
        if (-not $h -or -not $h.path) { continue }
        $seen = $null
        if ($h.seenAt) { try { $seen = [datetime]$h.seenAt } catch { $seen = $null } }
        $entry = [pscustomobject]@{
            Path     = $h.path
            Promoted = [int]$h.promoted
            Cooled   = [int]$h.cooled
            Seen     = if ($seen) { $seen } else { $script:Now }
        }
        if ($historyCutoff -and $entry.Seen -lt $historyCutoff) { $historyAged += 1; continue }
        $history[$h.path] = $entry
    }
}
# The cooldown is carried in the state -- a run has no other memory -- and entries are
# dropped as they come off it, so a directory cannot be kept out of the measure set for
# good by a stale record.
if ($cooldownHours -gt 0 -and $previous -and $previous.cooldown) {
    foreach ($c in @($previous.cooldown)) {
        $cp = if ($c -is [string]) { $c } else { $c.path }
        if (-not $cp) { continue }
        $until = $null
        if ($c -isnot [string] -and $c.until) { try { $until = [datetime]$c.until } catch { $until = $null } }
        # Missing or unreadable means promotable: a bad record may cost a walk, never a
        # missed leak.
        if (-not $until -or $until -le $script:Now) { continue }
        $cooldown[$cp] = $until
        $cooldownNext[$cp] = $until
    }
}
if ($previous -and $previous.promoted) {
    $bareRoots = @($WatchRoot | ForEach-Object { $_.TrimEnd('*').TrimEnd('\') })
    $candidates = @()
    foreach ($entry in @($previous.promoted)) {
        $p = if ($entry -is [string]) { $entry } else { $entry.path }
        if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Container)) { continue }
        # Already covered by the configured roots: measuring it twice would inflate the
        # growth figure, which is the one number this script exists to get right.
        $covered = $false
        foreach ($bare in $bareRoots) {
            if ($p -eq $bare -or (Test-UnderRoot $p $bare)) { $covered = $true; break }
        }
        if ($covered) { continue }
        # An entry written before this counter existed has spent no runs yet.
        $spent = if ($entry -and $null -ne $entry.runs) { [int]$entry.runs } else { 0 }
        if ($spent -ge $PromotedMaxRuns) {
            # Expired by the previous run, which was killed before it could write the
            # cooldown: put it back on, so the budget cannot be reset by a crash.
            $promotedExpired += $p
            Set-PromotionCooldown $p
            continue
        }
        $bytes = if ($entry -and $entry.bytes) { [long]$entry.bytes } else { [long]0 }
        $candidates += [pscustomobject]@{ Path = $p; Runs = $spent; Bytes = $bytes }
    }
    # The cap has to bite before the scan -- dropping a root after measuring it saves
    # nothing. Youngest first, with the larger of equally young roots kept: an old
    # promotion has already had its runs and is the one closer to expiry.
    if ($candidates.Count -gt $promotionCap) {
        $candidates = @($candidates | Sort-Object Runs, @{ Expression = { $_.Bytes }; Descending = $true })
        $promotedTrimmed = @($candidates | Select-Object -Skip $promotionCap | ForEach-Object { $_.Path })
        $candidates = @($candidates | Select-Object -First $promotionCap)
    }
    foreach ($c in $candidates) {
        if ($c.Bytes -gt 0) { $promotedBaseline[$c.Path] = $c.Bytes }
        $promotedRuns[$c.Path] = $c.Runs
        $promoted += $c.Path
        $WatchRoot += $c.Path
    }
}

$samples = [ordered]@{}
# Samples whose walk could not read all of them: the figure is the readable part, and the
# directories it was refused. Neither ranked nor stored as a baseline -- see "compare".
$unmeasured = [ordered]@{}
# A root that refused to be listed at all. Its children are not in $samples, so nothing
# about them is compared this run, and their last figures have to be carried instead of
# dropped -- see the state write.
$deniedRoots = @()
$timings = @()
$started = Get-Date
foreach ($spec in $WatchRoot) {
    $specWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $specCount = 0
    if ($spec.EndsWith('*')) {
        $root = $spec.Substring(0, $spec.Length - 1).TrimEnd('\')
        $children = @()
        try { $children = [System.IO.Directory]::EnumerateDirectories($root) } catch {
            if (Test-RefusedAccess $_.Exception) { $deniedRoots += $root }
        }
        foreach ($child in $children) {
            $samples[$child] = Get-TreeBytes $child
            if ($script:Unreadable.Count -gt 0) { $unmeasured[$child] = @($script:Unreadable | Select-Object -Unique) }
            $specCount += 1
            if ($script:Truncated) { break }
        }
    } else {
        $path = $spec
        try { $rp = Resolve-Path -LiteralPath $spec -ErrorAction Stop; if ($rp) { $path = $rp.Path } } catch { }
        $samples[$path] = Get-TreeBytes $path
        if ($script:Unreadable.Count -gt 0) { $unmeasured[$path] = @($script:Unreadable | Select-Object -Unique) }
        $specCount += 1
    }
    $specWatch.Stop()
    $timings += [pscustomobject]@{ Spec = $spec; Seconds = [math]::Round($specWatch.Elapsed.TotalSeconds, 1); Count = $specCount }
    if ($script:Truncated) { break }
}
$elapsed = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)

# ---------------------------------------------------------------- compare

$growers = @()
$prevPaths = @{}
# Measured directories this run could not compare because the sample it would compare with
# never reached them. Counted here, reported in the alert: the absence has to be visible,
# or a short ranking reads as a quiet disk.
$newBaselinePaths = 0
$baselineIncomplete = $false
# Directories the previous run could not read either. One that has no figure there is not
# new: it was unreadable, so this run's figure is its first measurement, not growth.
$prevUnmeasured = @{}
if ($previous -and $previous.unmeasured) {
    foreach ($p in @($previous.unmeasured)) { if ($p) { $prevUnmeasured[[string]$p] = $true } }
}
$unreadableBaselinePaths = 0
if ($previous -and $previous.paths) {
    $baselineIncomplete = -not $previousBaselineComplete
    foreach ($p in $previous.paths.PSObject.Properties) { $prevPaths[$p.Name] = [long]$p.Value }
    foreach ($path in $samples.Keys) {
        # The directory the budget cut through holds part of its tree, so subtracting the
        # old size from it produces a number about the scan, not about the disk -- usually
        # a phantom fall, occasionally a small phantom rise. Ranked, it would present the
        # cutoff as something that happened to the directory, and could name a grower for
        # the cache action out of the same arithmetic. It is left out here and named in the
        # alert instead.
        if ($script:PartialPath -and $path -eq $script:PartialPath) { continue }
        # The same rule for rights: a tree this walk could only partly read is a floor,
        # not a size. Subtracting the old figure from it would report the unreadable part
        # as a fall, and storing it would report that part as growth on the run that can
        # read it again. It is named in the alert instead.
        if ($unmeasured.Contains($path)) { continue }
        # A directory that did not exist at the previous sample is pure growth:
        # the leak creates a new %TEMP% child per run, so "new" must rank. A promoted
        # root is the exception: it existed, this script just was not measuring it, and
        # the size recorded when it was promoted is its honest baseline.
        # A path with no earlier figure, in a baseline that never reached it, is
        # unmeasured rather than new. Counting its whole tree as growth would report the
        # missing part of the baseline as a leak -- and could hand the cache action a top
        # grower made of arithmetic. Its size is still stored below, so it becomes the
        # baseline this comparison simply did not have.
        $hasEarlier = $prevPaths.ContainsKey($path) -or $promotedBaseline.ContainsKey($path)
        if (-not $hasEarlier -and $prevUnmeasured.ContainsKey($path)) {
            # Unreadable last time, so there was no figure then either: the same fact as a
            # cut-short baseline, one path at a time. This figure becomes the baseline.
            $unreadableBaselinePaths += 1
            continue
        }
        if (-not $hasEarlier -and $baselineIncomplete) {
            $newBaselinePaths += 1
            continue
        }
        $before = if ($prevPaths.ContainsKey($path)) { $prevPaths[$path] }
                  elseif ($promotedBaseline.ContainsKey($path)) { [long]$promotedBaseline[$path] }
                  else { [long]0 }
        $delta = [long]$samples[$path] - $before
        # Sub-megabyte churn is noise; naming it would bury the directory that matters.
        if ([math]::Abs($delta) -ge 1MB) { $growers += [pscustomobject]@{ Path = $path; Bytes = [long]$samples[$path]; Delta = $delta } }
    }
    # @() matters: one PSCustomObject has no .Count in PS 5.1, so an uncoerced
    # single grower would report as none.
    $growers = @($growers | Sort-Object Delta -Descending)
    if ($VerbosePreference -ne 'SilentlyContinue') {
        Write-Log ("  [verbose] previous sample {0} with {1} path(s); {2} grew" -f $previous.sampledAt, $prevPaths.Count, @($growers).Count)
    }
}

$topGrower = $null
if ($growers.Count -gt 0) { $topGrower = $growers | Where-Object { $_.Delta -gt 0 } | Select-Object -First 1 }

# ---------------------------------------------------------------- act on the top grower
# Naming the corpse and leaving it on the disk is the failure this task exists to end:
# a 1.6 GB sandbox reported every 15 minutes is a headline, not a fix. So when the top
# grower is a rehearsal sandbox, the harness's collector is asked to clear it -- this
# script no longer decides whether a sandbox may go, only that it is one. A run that is
# still alive comes back as a 'kept' verdict and is merely reported.
#
# The drop comparison keeps the PRE-action reading. The leak did happen, and the alert
# should still say so; what changes is that it can also say the space came back.
$actioned = @()
$sweepAction = $null
$freeAtSample = $freeBytes
if ($topGrower -and (-not $NoSweep -or $DryRun)) {
    # -Preview asks the collector instead of acting on it; $sweepAction.Swept stays empty,
    # so nothing downstream believes a directory left the disk.
    $sweepAction = Invoke-GrowerSweep -grower $topGrower -clientPath $RehearsalCli -Preview:$DryRun
    if ($sweepAction.Log) { Write-Log $sweepAction.Log }
    $actioned = @($sweepAction.Swept)
    if ($actioned.Count -gt 0) {
        # The next sample must not measure a directory that just left, and neither
        # should the "largest directories" list in this run's alert. -eq is
        # case-insensitive here, and a nested sample path goes with its run.
        foreach ($a in $actioned) {
            if (-not $a.Path) { continue }
            foreach ($key in @($samples.Keys)) {
                if ($key -eq $a.Path -or (Test-UnderRoot $key $a.Path)) { $samples.Remove($key) }
            }
        }
        $volume = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
        if ($volume) {
            $freeBytes = [long]$volume.SizeRemaining
            $freeGB = [math]::Round($freeBytes / 1GB, 2)
        }
    }
}

$prevFree = if ($previous) { [long]$previous.freeBytes } else { $null }
# Not $dropGB: PowerShell is case-insensitive, and assigning it would overwrite the
# -DropGB threshold with the measurement (which made every run "drop >= 0").
$fellGB = if ($prevFree -ne $null) { [math]::Round(($prevFree - $freeAtSample) / 1GB, 2) } else { 0 }

$breach = $freeGB -lt $MinFreeGB
$dropEvent = ($prevFree -ne $null) -and ($fellGB -ge $DropGB)
$alert = $Simulate -or $breach -or $dropEvent

# ---------------------------------------------------------------- clear a cache
# The same treatment the sandboxes get, for the directories that are regenerable on
# purpose: when one is the top grower it is cleared here, not just named, so the
# alert's free-space figure already includes it. Two guards a sandbox does not need:
# it only runs while the drive is actually short ($alert) -- a cache is a performance
# store, and emptying one on a healthy drive buys nothing -- and it stops at
# -CacheMaxClearGB, so no one run can free an unbounded amount.
$cacheCleared = @()
$cacheNote = $null
# Set when the grower was looked at and is simply not regenerable: informational, so it
# does not take the advice that only fits a cache action that ran.
$cacheSkipNote = $null
if ($topGrower -and $alert) {
    $cacheRoot = Resolve-CacheGrower $topGrower.Path
    if ($cacheRoot) {
        $capBytes = [long]($CacheMaxClearGB * 1GB)
        # The sample key is matched case-insensitively: one comes from enumerating a
        # watch root as the user typed it, the other from Resolve-Path's real casing.
        $sampleKey = $null
        foreach ($k in @($samples.Keys)) { if ($k -eq $cacheRoot) { $sampleKey = $k; break } }
        $cacheSize = if ($sampleKey) { [long]$samples[$sampleKey] } else { Get-TreeBytes $cacheRoot }
        if ($DryRun) {
            $plan = Clear-CacheTree -path $cacheRoot -maxBytes $capBytes -Preview
            $cacheNote = "would clear {0:N2} of {1:N2} GB from {2} (cap {3} GB, -DryRun)" -f `
                ($plan.Freed / 1GB), ($cacheSize / 1GB), (Shorten-Path $cacheRoot), $CacheMaxClearGB
            if ($plan.Capped) { $cacheNote += '; the cap would stop it' }
        } elseif (-not $NoSweep) {
            $done = Clear-CacheTree -path $cacheRoot -maxBytes $capBytes
            $freeBefore = $freeBytes
            $volume = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
            if ($volume) {
                $freeBytes = [long]$volume.SizeRemaining
                $freeGB = [math]::Round($freeBytes / 1GB, 2)
            }
            # The directory still exists and is now small: re-measure it, or this run's
            # "largest" list and the next run's growth ranking both report the gap.
            if ($sampleKey) { $samples[$sampleKey] = Get-TreeBytes $cacheRoot }
            if ($done.Freed -gt 0) {
                $cacheCleared += $done
                $cacheNote = "cleared {0:N2} GB from {1} (+{2:N2} GB free)" -f `
                    ($done.Freed / 1GB), (Shorten-Path $cacheRoot), [math]::Round(($freeBytes - $freeBefore) / 1GB, 2)
                if ($done.Capped) { $cacheNote += "; stopped at the $CacheMaxClearGB GB cap, the rest is left" }
                if ($done.InUse -gt 0) { $cacheNote += "; $($done.InUse) file(s) were in use" }
            } else {
                $cacheNote = "the top grower is the cache {0}, but nothing could be cleared ({1} file(s) in use)" -f (Shorten-Path $cacheRoot), $done.InUse
            }
        }
    } else {
        # Without this the cache section is simply absent, which beside the sweep and
        # collector lines reads as an omission rather than a verdict. Name the grower so
        # the reader can see the decision was about that directory, not about caches in
        # general.
        $cacheSkipNote = "nothing -- the top grower {0} is not one of the -CacheRoot directories" -f (Shorten-Path $topGrower.Path)
    }
} elseif ($DryRun -and -not $alert) {
    # The cache action is the one whose trigger is the alert itself, so on a healthy drive
    # there is no plan to report -- and saying nothing, in a document whose other halves
    # both say what they would do, reads as an omission. Say why there is nothing.
    $cacheNote = 'nothing -- the drive is not short, and the cache action only runs while it is'
} elseif ($alert) {
    # A breach with no grower to name: the floor was already under when the run started and
    # nothing measurable moved after it. The cache action is keyed on the top grower, so it
    # has nothing to look at -- and an absent cache line beside the sweep and collector
    # lines reads as an omission rather than as that verdict.
    $cacheSkipNote = if (-not $previous) {
        'nothing -- this is the first sample, so there is no growth ranking to name a top grower from'
    } elseif ($script:Truncated) {
        'nothing -- the scan hit its time budget, so no grower was ranked (see the note below)'
    } elseif ($baselineIncomplete) {
        # Same distinction as the ranking above: the absence of a grower here is the
        # absence of a baseline, and "nothing grew" would be the wrong reason.
        'nothing -- the previous sample was cut short, so no directory had an earlier figure to grow from'
    } elseif (@($unmeasured.Keys).Count -gt 0 -or $deniedRoots.Count -gt 0) {
        # A tree that could not be read may hold the grower; "nothing grew" would state
        # the one thing this run did not find out.
        'nothing -- a directory could not be read in full, so there is no ranked grower to check for a cache'
    } else {
        'nothing -- nothing grew by 1 MB or more, so there is no top grower to check for a cache'
    }
}

# Built after the cache clear so this list cannot show a cache that was just emptied
# as still holding its old size.
# A row whose figure is a floor rather than a size says so on the line. The note above the
# list explains why for the one tree it concerns, but the list is what a reader scans, and
# a bare "0.00 GB" there reads as a measurement -- which is the one thing it is not.
$largest = @()
foreach ($path in $samples.Keys) {
    $floorNote = if ($unmeasured.Contains($path)) { 'floor, not a size -- part of this tree could not be read' }
                 elseif ($script:PartialPath -and $path -eq $script:PartialPath) { 'floor, not a size -- the scan stopped inside it' }
                 else { $null }
    $largest += [pscustomobject]@{ Path = $path; Bytes = [long]$samples[$path]; Delta = [long]0; FloorNote = $floorNote }
}
$largest = @($largest | Sort-Object Bytes -Descending | Select-Object -First $Top)

$lastAlert = if ($previous -and $previous.lastAlert) { [datetime]$previous.lastAlert } else { $null }
$throttled = $false
if ($alert -and -not $Simulate -and $lastAlert -and ($script:Now - $lastAlert).TotalHours -lt $ReAlertHours) { $throttled = $true }

# ---------------------------------------------------------------- what the roots cannot see
# Three things take space without growing a directory a watch root covers, and they are
# measured on every run rather than only when they are printed: the question the alert asks
# about them is which of them grew since the previous sample, and that needs the previous
# sample to have measured them too. Only the shadow figure needs elevation -- the pagefile
# and the hibernation file are read straight off the volume root.
$measuredAt = $script:Now.ToString('o')
$pf = Get-PageFileInfo -DriveLetter $DriveLetter
$hb = Get-HibernationFileInfo -DriveLetter $DriveLetter
$sh = Get-ShadowStorage -DriveLetter $DriveLetter

# A verdict, not just a number: "none" is something measured (hibernation is off, no shadow
# copies hold space), "unknown" is the absence of a measurement. The comparison below must
# not read the second as zero, or an unreadable figure would report itself as unchanged.
$pfVerdict = if ($pf.Measured) {
    [ordered]@{ state = 'size'; bytes = [long]$pf.Bytes; at = $measuredAt }
} elseif ($pf.Reason -like 'no pagefile.sys*') {
    [ordered]@{ state = 'none'; bytes = [long]0; at = $measuredAt }
} else {
    [ordered]@{ state = 'unknown'; bytes = [long]0; at = $measuredAt }
}
$hbVerdict = if ($hb.Measured) {
    [ordered]@{ state = 'size'; bytes = [long]$hb.Bytes; at = $measuredAt }
} elseif ($hb.Reason -like 'hibernation is off*' -or $hb.Reason -like 'no hiberfil.sys*') {
    [ordered]@{ state = 'none'; bytes = [long]0; at = $measuredAt }
} else {
    [ordered]@{ state = 'unknown'; bytes = [long]0; at = $measuredAt }
}
$shVerdict = if ($sh.Measured -and $sh.Allocated -gt 0) {
    [ordered]@{ state = 'size'; bytes = [long]$sh.Allocated; at = $measuredAt }
} elseif ($sh.Measured) {
    [ordered]@{ state = 'none'; bytes = [long]0; at = $measuredAt }
} else {
    [ordered]@{ state = 'unknown'; bytes = [long]0; at = $measuredAt }
}
$notRankedNow = [ordered]@{ pagefile = $pfVerdict; hibernation = $hbVerdict; shadow = $shVerdict }

# A fall the ranked roots cannot explain has three candidates no walk can see -- shadow
# copies, the pagefile, the hibernation file -- and only the first is hard to read. So they
# are reported as one line: the two that any caller can size come first, and the shadow
# verdict follows as a figure, "none", or "unknown" with the reason, so a missing
# measurement cannot hide the two that are not. Built only for that case -- an ordinary
# alert has a grower to act on, and a plan is not an alert.
$unrankedNotes = @()
$unrankedTags = @()
if ($alert -and -not $throttled -and -not $DryRun -and -not $topGrower -and $prevFree -ne $null -and $fellGB -ge 0.01) {
    if ($pf.Measured) {
        $unrankedNotes += ('pagefile {0:N2} GB on {1}:{2}' -f ($pf.Bytes / 1GB), $DriveLetter,
            $(if ($null -ne $pf.Max -and $pf.Max -gt $pf.Bytes) { ' (maximum {0:N2} GB)' -f ($pf.Max / 1GB) } else { '' }))
        $unrankedTags += 'pagefile {0:N2} GB' -f ($pf.Bytes / 1GB)
    } else {
        $unrankedNotes += "pagefile none -- $($pf.Reason)"
        $unrankedTags += 'pagefile none'
    }
    if ($hb.Measured) {
        $unrankedNotes += 'hibernation file {0:N2} GB on {1}:' -f ($hb.Bytes / 1GB), $DriveLetter
        $unrankedTags += 'hibernation {0:N2} GB' -f ($hb.Bytes / 1GB)
    } else {
        $unrankedNotes += "hibernation file none -- $($hb.Reason)"
        $unrankedTags += 'hibernation none'
    }
    if ($sh.Measured -and $sh.Allocated -gt 0) {
        $unrankedNotes += ('shadow {0:N2} GB on {1}:{2}' -f ($sh.Allocated / 1GB), $DriveLetter,
            $(if ($null -ne $sh.Max) { ' (maximum {0:N2} GB)' -f ($sh.Max / 1GB) } else { '' }))
        $unrankedTags += 'shadow {0:N2} GB' -f ($sh.Allocated / 1GB)
    } elseif ($sh.Measured) {
        $unrankedNotes += "shadow none -- no shadow copies hold space on $DriveLetter`:"
        $unrankedTags += 'shadow none'
    } else {
        $unrankedNotes += "shadow unknown -- $($sh.Reason)"
        $unrankedTags += 'shadow unknown'
    }
    # Sizes on their own do not answer the question this line exists for. Compared with the
    # last set of figures, it says which of them grew -- and when none did, that is itself the
    # finding: the fall came from something other than these three. A figure this run could
    # not read, or had no earlier figure for, is named rather than counted as unchanged.
    $then = if ($previous -and $previous.notRanked) { $previous.notRanked } else { $null }
    $grew = @()
    $notCompared = @()
    $baselines = @()
    if ($then) {
        foreach ($key in @('pagefile', 'hibernation', 'shadow')) {
            $nowVerdict = $notRankedNow[$key]
            $label = switch ($key) { 'pagefile' { 'pagefile' } 'hibernation' { 'hibernation file' } 'shadow' { 'shadow storage' } }
            if ($nowVerdict.state -eq 'unknown') { $notCompared += $label; continue }
            $thenVerdict = $then.$key
            if (-not $thenVerdict -or $thenVerdict.state -eq 'unknown') { $notCompared += $label; continue }
            if ($thenVerdict.at) { $baselines += [datetime]$thenVerdict.at }
            $thenBytes = if ($thenVerdict.state -eq 'none') { [long]0 } else { [long]$thenVerdict.bytes }
            $delta = [long]$nowVerdict.bytes - $thenBytes
            # 10 MB: the pagefile grows in hundreds of MB and a shadow block is not smaller, so
            # calling a few MB of slack growth would only stack noise beside the real number.
            if ($delta -ge 10MB) {
                $grew += ('{0} +{1:N2} GB{2}' -f $label, ($delta / 1GB), $(if ($thenBytes -eq 0) { ' (it was not there then)' } else { '' }))
            }
        }
    }
    if ($grew.Count -gt 0) {
        $when = Format-SampleTime (@($baselines | Sort-Object)[0])
        $unrankedNotes += ('grew since {0}: {1}' -f $when, ($grew -join ', '))
        $unrankedTags += ('grew {0}' -f ($grew -join ', '))
    } elseif ($baselines.Count -gt 0) {
        $when = Format-SampleTime (@($baselines | Sort-Object)[0])
        $unrankedNotes += ('none of them grew since {0}' -f $when)
        $unrankedTags += 'nothing grew'
    } else {
        $unrankedNotes += 'no earlier figures to compare with -- this run is their baseline'
        $unrankedTags += 'no baseline'
    }
    if ($notCompared.Count -gt 0 -and $baselines.Count -gt 0) {
        $unrankedNotes += ('{0} not compared' -f ($notCompared -join ' and '))
    }
}

# ---------------------------------------------------------------- report
$why = @()
if ($Simulate) { $why += 'simulated' }
if ($breach) { $why += "free $freeGB GB is below the $MinFreeGB GB floor" }
if ($dropEvent) { $why += "free space fell $fellGB GB since the last sample" }

# The sweep already deleted the leak, so say so in the same line as the numbers it
# changed: free space that rose is otherwise indistinguishable from a miscount.
$sweptNote = $null
if ($sweptSandboxes.Count -gt 0) {
    $sweptNote = "swept {0} stale sandbox(es) (+{1:N2} GB)" -f $sweptSandboxes.Count, ([math]::Round(($freeBytes - $freeBeforeSweep) / 1GB, 2))
}
# The dry run's version: same list, no deletion, so its quantity is what the sweep would
# have freed -- summed from the stale directories themselves, not from a free-space delta
# that a run deleting nothing cannot produce.
$sweepPlanNote = $null
if ($sweptPlan.Count -gt 0) {
    $planBytes = [long]0
    foreach ($s in $sweptPlan) { $planBytes += [long]$s.Bytes }
    $sweepPlanNote = "would sweep {0} stale sandbox(es) ({1}{2:N2} GB)" -f `
        $sweptPlan.Count, $(if ($script:PreviewTruncated) { 'at least ' } else { '~' }), ($planBytes / 1GB)
}
# Same idea for the grower action: the collection is the point of the run, so the
# summary has to carry what it removed and what that bought. The collector is named
# because the deletion was its call, not this script's.
$actionNote = $null
if ($actioned.Count -gt 0) {
    $what = if ($actioned.Count -eq 1) { "the top-grower sandbox $($actioned[0].Name)" }
            else { "$($actioned.Count) stale sandboxes, the top grower among them" }
    $actionNote = "the rehearsal's --sweep cleared $what (+{0:N2} GB)" -f ([math]::Round(($freeBytes - $freeAtSample) / 1GB, 2))
}
# ...and its dry-run counterpart, in the collector's own words and sizes.
$growerPlanNote = $null
if ($DryRun -and $sweepAction -and @($sweepAction.Would).Count -gt 0) {
    $growerPlanNote = "the rehearsal's collector would clear " +
        (($sweepAction.Would | ForEach-Object { "$($_.Name) ($($_.Size))" }) -join '; ')
}

# ---------------------------------------------------------------- correlate a drop
# Only the part of the fall the watched roots cannot explain is worth walking for: if
# they already account for it, the walk would cost a minute and repeat this run's answer.
$explainedBytes = [long]0
foreach ($g in $growers) { if ($g.Delta -gt 0) { $explainedBytes += $g.Delta } }
$explainedGB = [math]::Round($explainedBytes / 1GB, 2)
$unexplainedGB = [math]::Round($fellGB - $explainedGB, 2)

$correlation = $null
# $throttled, not $alert: a drive that has been below its floor for a day is still an
# alert every tick, and a one-minute walk per tick is five hours a day of scanning for
# an answer that has not changed. The walk follows the same 6 h rhythm as the alert.
if ($alert -and -not $throttled -and -not $NoCorrelate -and $prevFree -ne $null -and $unexplainedGB -ge $CorrelateMinGB) {
    $windowStart = if ($previous -and $previous.sampledAt) { [datetime]$previous.sampledAt } else { $script:Now }
    # A clock that jumped backwards would make the window empty rather than wrong.
    if ($windowStart -gt $script:Now) { $windowStart = $script:Now }

    $exclude = @()
    foreach ($spec in $WatchRoot) {
        if (-not $spec) { continue }
        $bare = $spec.TrimEnd('*').TrimEnd('\')
        try { $exclude += (Resolve-Path -LiteralPath $bare -ErrorAction Stop).Path } catch { }
    }
    foreach ($s in @($SandboxRoot)) { if ($s) { try { $exclude += (Resolve-Path -LiteralPath $s).Path } catch { } } }

    $correlateRoots = if ($CorrelateRoot) { $CorrelateRoot } else { @($env:USERPROFILE) }
    # -Top is the same knob the growth ranking uses: how many directories to name.
    $correlation = Get-WrittenInWindow -Roots $correlateRoots -Since $windowStart `
        -BudgetSeconds $CorrelateBudgetSeconds -Exclude $exclude `
        -MinBytes ([long]($CorrelateMinMB * 1MB)) -Top $Top
}

$correlationNote = $null
if ($correlation) {
    if ($correlation.Dirs.Count -gt 0) {
        $correlationNote = "outside the watched roots: +{0:N2} GB in {1}" -f ($correlation.TotalBytes / 1GB), (Shorten-Path $correlation.Dirs[0].Path)
    } else {
        $correlationNote = "outside the watched roots: nothing above {0} MB written in this window" -f $CorrelateMinMB
    }
    if ($correlation.Truncated) { $correlationNote += '  (walk truncated)' }
}

# ---------------------------------------------------------------- promote what it named
# Everything the walk named goes into the next run's measure set, and a promotion from
# the last run is carried forward only if this sample saw that directory grow -- the
# rule that keeps the state from accumulating roots nobody has written to since -- and
# only until it has been sampled -PromotedMaxRuns times, which is the rule that stops a
# directory that grows forever from being watched forever.
# 1 MB is the same bar the growth ranking uses, so "still growing" means the same thing
# in both places.
$promotedNext = @()
$promotedFresh = @{}
$promotedRunsNext = @{}
# Of those, the ones promoted by THIS run, and the repeat offenders among them.
$promotedNew = @()
$promotedRepeat = @()
if ($correlation) {
    foreach ($d in $correlation.Dirs) {
        if ($promotedNext -contains $d.Path) { continue }
        # Named again while cooling: the case the cooldown exists for. It is reported
        # rather than dropped silently, so a walk that named something is not mistaken
        # for a walk that found nothing.
        $cooledUntil = $null
        foreach ($k in @($cooldown.Keys)) { if ($k -eq $d.Path) { $cooledUntil = $cooldown[$k]; break } }
        if ($cooledUntil) {
            if ($promotedCooling -notcontains $d.Path) {
                $promotedCooling += $d.Path
                $promotedCoolingUntil[$d.Path] = $cooledUntil
            }
            continue
        }
        # A directory the history already knows is a different fact from a new one: the
        # walk is finding the same churn again, not discovering a leak.
        $prior = $history[$d.Path]
        if ($prior -and ($prior.Promoted -ge 1 -or $prior.Cooled -ge 1)) {
            $promotedRepeat += [pscustomobject]@{ Path = $d.Path; Promoted = $prior.Promoted; Cooled = $prior.Cooled }
        }
        $promotedNew += $d.Path
        $promotedNext += $d.Path
        $promotedFresh[$d.Path] = Get-TreeBytes $d.Path
        # Named now, measured from the next run on: this measurement is the baseline, not
        # one of the samples the budget counts.
        $promotedRunsNext[$d.Path] = 0
    }
}
foreach ($p in $promoted) {
    if ($promotedNext -contains $p) { continue }
    if (-not (Test-Path -LiteralPath $p -PathType Container)) { continue }
    foreach ($g in $growers) {
        if ($g.Path -eq $p -and $g.Delta -ge 1MB) {
            $spent = [int]$promotedRuns[$p] + 1
            if ($spent -ge $PromotedMaxRuns) {
                # It has had its runs. Carrying it again is exactly the unbounded list the
                # cap exists to prevent; the next alert's correlation can name it afresh --
                # which is why it goes on cooldown too, so "afresh" is not "next run".
                $promotedExpired += $p
                Set-PromotionCooldown $p
            } else {
                $promotedNext += $p
                $promotedRunsNext[$p] = $spent
            }
            break
        }
    }
}
# The correlation can name up to -Top directories in one alert, so the write side has
# to enforce the same cap the read side does -- otherwise the state grows with every
# new leak and the next read has to discard what this run promised.
if ($promotedNext.Count -gt $promotionCap) {
    $promotedTrimmed += @($promotedNext | Select-Object -Skip $promotionCap)
    $promotedNext = @($promotedNext | Select-Object -First $promotionCap)
}
# The two lists are reported, not just applied: a directory that quietly stopped being
# sampled after explaining a drop is the one fact a reader of the log would want.
$promotedExpired = @($promotedExpired | Select-Object -Unique)
$promotedTrimmed = @($promotedTrimmed | Select-Object -Unique)
# Only the repeats this run actually kept: a directory the cap dropped was not promoted,
# and "promoted 2x" would then be a count the state does not hold.
$promotedRepeat = @($promotedRepeat | Where-Object { $promotedNext -contains $_.Path })
$repeatText = $null
if ($promotedRepeat.Count -gt 0) {
    $repeatText = (($promotedRepeat | ForEach-Object {
                "{0} (promoted {1}x, cooled {2}x)" -f (Shorten-Path $_.Path), ($_.Promoted + 1), $_.Cooled
            }) -join ' | ')
}
# Record what this run did, after the reporting above has read the counts it needs: a
# promotion when one is kept, a cool-off when a promotion's runs ran out.
foreach ($p in $promotedNext) {
    if ($promotedNew -notcontains $p) { continue }
    $h = $history[$p]
    if (-not $h) {
        $h = [pscustomobject]@{ Path = $p; Promoted = 0; Cooled = 0; Seen = $script:Now }
        $history[$p] = $h
    }
    $h.Promoted = [int]$h.Promoted + 1
    $h.Seen = $script:Now
}
foreach ($p in $promotedExpired) {
    $h = $history[$p]
    if (-not $h) {
        # Promoted before this history existed and about to be measured no longer.
        $h = [pscustomobject]@{ Path = $p; Promoted = 1; Cooled = 0; Seen = $script:Now }
        $history[$p] = $h
    }
    # Only when there was a cooldown to spend: with -PromotionCooldownHours 0 the expiry is
    # a rotation, not a cooling-off.
    if ($cooldownHours -gt 0) { $h.Cooled = [int]$h.Cooled + 1 }
    $h.Seen = $script:Now
}
foreach ($p in $promotedCooling) {
    $h = $history[$p]
    if ($h) { $h.Seen = $script:Now }
}
$promotedNote = $null
if ($promotedNext.Count -gt 0) {
    $promotedNote = 'next run also measures: ' + (($promotedNext | ForEach-Object { Shorten-Path $_ }) -join ' | ')
}
# One wording for both surfaces: the log has the history, the alert has to say the same
# thing to whoever reads it first, and each directory has its own end time.
$coolingText = $null
if ($promotedCooling.Count -gt 0) {
    $coolingText = (($promotedCooling | ForEach-Object {
                $prior = $history[$_]
                $counts = if ($prior -and ($prior.Promoted -ge 1 -or $prior.Cooled -ge 1)) {
                    '; promoted {0}x, cooled {1}x' -f $prior.Promoted, $prior.Cooled
                } else { '' }
                "{0} ({1}{2})" -f (Shorten-Path $_), (Format-CooldownLeft $promotedCoolingUntil[$_]), $counts
            }) -join ' | ')
}

$installNote = Get-InstallNote

$summary = "{0:yyyy-MM-dd HH:mm:ss}  free {1:N2}/{2:N2} GB  threshold {3} GB  {4}  [{5:N1}s scan, {6} dirs]" -f `
    $script:Now, $freeGB, ($totalBytes / 1GB), $MinFreeGB, ($(if ($alert) { 'ALERT: ' + ($why -join '; ') } else { 'ok' })), $elapsed, $samples.Count
if ($script:Truncated) { $summary += "  [scan truncated at ${TimeBudgetSeconds}s]" }
if ($sweptNote) { $summary += "  [$sweptNote]" }
if ($sweepPlanNote) { $summary += "  [$sweepPlanNote]" }
if ($actionNote) { $summary += "  [$actionNote]" }
if ($growerPlanNote) { $summary += "  [$growerPlanNote]" }
if ($cacheNote) { $summary += "  [$cacheNote]" }
elseif ($cacheSkipNote) { $summary += "  [$cacheSkipNote]" }
foreach ($tag in $unrankedTags) { $summary += "  [$tag]" }
if ($newBaselinePaths -gt 0 -and -not $script:Truncated) { $summary += "  [baseline: $newBaselinePaths dir(s) had no earlier figure]" }
if ($unreadableBaselinePaths -gt 0) { $summary += "  [baseline: $unreadableBaselinePaths dir(s) could not be read last run]" }
if ($unmeasured.Count -gt 0) { $summary += "  [unreadable: $($unmeasured.Count) dir(s) not ranked, last figure kept]" }
if ($deniedRoots.Count -gt 0) { $summary += '  [denied: ' + (($deniedRoots | ForEach-Object { Shorten-Path $_ }) -join ' | ') + ']' }
if ($sweepAction -and $sweepAction.Tag) { $summary += "  [$($sweepAction.Tag)]" }
if ($correlationNote) { $summary += "  [$correlationNote]" }
Write-Log $summary
if ($installNote) { Write-Log ("  install     : {0}" -f $installNote) }
if ($correlation -and $correlation.Dirs.Count -gt 0) {
    foreach ($d in $correlation.Dirs) {
        Write-Log ("  written: {0}  {1,6:N0} {2}  {3}" -f (Format-GB $d.Bytes).Trim(), $d.Files, $(if ($d.Files -eq 1) { 'file ' } else { 'files' }), (Shorten-Path $d.Path))
    }
    Write-Log ("  ({0:N2} GB fell, {1:N2} GB written in {2:N0} files walked in {3:N1}s{4})" -f `
            $fellGB, ($correlation.TotalBytes / 1GB), $correlation.Walked, $correlation.Seconds,
            $(if ($correlation.Truncated) { ', truncated at budget' } else { '' }))
}
if ($promotedNote) { Write-Log "  $promotedNote" }
if ($promotedExpired.Count -gt 0) {
    Write-Log ("  promotion expired after {0} run(s){1}: {2}" -f `
        $PromotedMaxRuns, $(if ($cooldownHours -gt 0) { ", not sampled again for $cooldownHours h" } else { '' }),
        (($promotedExpired | ForEach-Object { Shorten-Path $_ }) -join ' | '))
}
if ($coolingText) {
    Write-Log ("  promotion cooling, named again but not re-promoted: {0}" -f $coolingText)
}
if ($repeatText) {
    Write-Log ("  repeat promotion, this directory has churned before: {0}" -f $repeatText)
}
if ($historyAged -gt 0) {
    Write-Log ("  promotion history: forgot {0} director{1} not seen for {2}+ days, so a return counts as new" -f `
        $historyAged, $(if ($historyAged -eq 1) { 'y' } else { 'ies' }), $PromotionHistoryDays)
}
if ($promotedTrimmed.Count -gt 0) {
    Write-Log ("  promotion cap of {0} reached, not sampled this run: {1}" -f `
        $promotionCap, (($promotedTrimmed | ForEach-Object { Shorten-Path $_ }) -join ' | '))
}
if ($sweptNote) {
    $detail = (($sweptSandboxes | Select-Object -First 3 | ForEach-Object { "$($_.Name) ($($_.Reason))" }) -join '; ')
    if ($sweptSandboxes.Count -gt 3) { $detail += "; +$($sweptSandboxes.Count - 3) more" }
    Write-Log "  $detail"
}
if ($sweepPlanNote) {
    $detail = (($sweptPlan | Select-Object -First 3 | ForEach-Object { "$($_.Name) ($($_.Reason), $([math]::Round($_.Bytes / 1MB)) MB)" }) -join '; ')
    if ($sweptPlan.Count -gt 3) { $detail += "; +$($sweptPlan.Count - 3) more" }
    Write-Log "  $detail"
}
if ($script:Truncated) {
    $cutShort = if ($script:PartialPath) { ' (cut short inside {0})' -f (Shorten-Path $script:PartialPath) } else { '' }
    Write-Log "  sized only $($samples.Count) director(ies) in $elapsed s$cutShort -- raise -TimeBudgetSeconds or narrow -WatchRoot"
}
foreach ($p in @($unmeasured.Keys)) {
    $inside = @($unmeasured[$p])
    Write-Log ("  unreadable: {0} -- {1} director{2} inside denied access, so its size is a floor: not ranked, last figure kept" -f `
            (Shorten-Path $p), $inside.Count, $(if ($inside.Count -eq 1) { 'y' } else { 'ies' }))
    Write-Log ("              first refused: {0}" -f (Shorten-Path $inside[0]))
}
if ($deniedRoots.Count -gt 0) {
    Write-Log ("  denied root: {0} -- not enumerated this run; its children keep their last figures" -f `
            (($deniedRoots | ForEach-Object { Shorten-Path $_ }) -join ' | '))
}
if ($unreadableBaselinePaths -gt 0) {
    Write-Log ("  {0} director{1} could not be read last run, so this run's figure is its baseline" -f `
            $unreadableBaselinePaths, $(if ($unreadableBaselinePaths -eq 1) { 'y' } else { 'ies' }))
}
if ($VerbosePreference -ne 'SilentlyContinue') {
    foreach ($t in $timings) { Write-Log ("  [verbose] {0,5:N1}s  {1,4} dirs  {2}" -f $t.Seconds, $t.Count, $t.Spec) }
}

if ($growers.Count -gt 0) {
    Write-Log ("  grew: " + (($growers | Select-Object -First $Top | ForEach-Object {
        "{0}  {1}" -f (Format-GB $_.Delta).Trim(), $_.Path
    }) -join ' | '))
}
if (-not $Quiet -and $previous -eq $null -and $samples.Count -gt 0) {
    Write-Log '  first sample -- growth ranking starts with the next run'
}

# ---------------------------------------------------------------- state
# Written every run: the next sample's drop and growth numbers come from it, not
# only from the runs that alerted.
$alerted = $alert -and -not $throttled
if (-not $NoState) {
    # A partial size must not become the next sample's baseline. The directory the budget
    # cut through holds a fraction of its tree, so recording that fraction would make the
    # next complete scan report the rest of the tree as growth -- a false positive produced
    # by this run's clock. It keeps the size it had, and so does every path the truncated
    # scan never reached.
    # The baseline this run leaves behind has to say whether it is a whole picture. A
    # truncated run can only claim that when it inherited one; otherwise the paths it
    # never reached stay missing, and the next run reads the flag instead of guessing.
    $baselineComplete = if ($script:Truncated) { [bool]$previousBaselineComplete } else { $true }
    $pathsWrite = [ordered]@{}
    # Paths whose figure this run holds only part of a tree, or whose root refused to be
    # listed. Carried so an unreadable run is visible, and so the next run does not read a
    # first measurement as growth.
    $unmeasuredWrite = @()
    # A root that refused to be enumerated has no children in $samples at all. Dropping
    # their last figures would make the next readable sample call each of them a new
    # directory and rank whole trees as growth.
    if ($deniedRoots.Count -gt 0 -and $previous -and $previous.paths) {
        foreach ($p in $previous.paths.PSObject.Properties) {
            foreach ($dr in $deniedRoots) {
                if ($p.Name.StartsWith($dr + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                    $pathsWrite[$p.Name] = [long]$p.Value
                    $unmeasuredWrite += $p.Name
                    break
                }
            }
        }
    }
    if ($script:Truncated) {
        if ($previous -and $previous.paths) {
            foreach ($p in $previous.paths.PSObject.Properties) {
                if (-not $pathsWrite.Contains($p.Name)) { $pathsWrite[$p.Name] = [long]$p.Value }
            }
        }
    }
    foreach ($path in $samples.Keys) {
        if ($script:PartialPath -and $path -eq $script:PartialPath) { continue }
        if ($unmeasured.Contains($path)) {
            # Rights have the same effect on the next sample as the clock: the readable
            # part is not the size. It keeps the last figure it was measured at, and is
            # named in the state so a first measurement is not read as growth.
            $unmeasuredWrite += $path
            if ($prevPaths.ContainsKey($path)) { $pathsWrite[$path] = [long]$prevPaths[$path] }
            continue
        }
        $pathsWrite[$path] = [long]$samples[$path]
    }
    $notRankedWrite = [ordered]@{}
    foreach ($key in @('pagefile', 'hibernation', 'shadow')) {
        $nowVerdict = $notRankedNow[$key]
        $thenVerdict = if ($previous -and $previous.notRanked) { $previous.notRanked.$key } else { $null }
        if ($nowVerdict.state -eq 'unknown' -and $thenVerdict -and $thenVerdict.state -ne 'unknown') {
            $notRankedWrite[$key] = $thenVerdict
        } else {
            $notRankedWrite[$key] = $nowVerdict
        }
    }
    $state = [ordered]@{
        sampledAt       = $script:Now.ToString('o')
        # The roots the correlation named, for the next run to measure, with the size
        # that is their baseline. Carried while the directory keeps growing and for at
        # most -PromotedMaxRuns samples; `runs` is what enforces the second half.
        promoted        = @($promotedNext | ForEach-Object {
                [ordered]@{
                    path  = $_
                    bytes = [long]$(if ($promotedFresh.ContainsKey($_)) { $promotedFresh[$_] }
                        elseif ($samples.Contains($_)) { $samples[$_] } else { 0 })
                    # Samples this entry has had, so the next run can expire it: a state file
                    # written by a killed run must not hand a churning directory a fresh
                    # budget, and this is the number that travels instead.
                    runs  = [int]$(if ($promotedRunsNext.ContainsKey($_)) { $promotedRunsNext[$_] } else { 0 })
                }
            })
        # Every directory this run expired, and when it becomes promotable again, so the
        # next walk cannot hand it the budget it just spent.
        cooldown        = @($cooldownNext.Keys | ForEach-Object {
                [ordered]@{ path = $_; until = ([datetime]$cooldownNext[$_]).ToString('o') }
            })
        # Promotion and cool-off counts per directory, newest first and bounded by
        # -PromotionHistoryMax: enough to recognise a directory that keeps coming back,
        # not a permanent record of everything this machine ever grew.
        # `expiresAt` is when the counts stop counting if nothing else happens there, so a
        # reader does not have to add the policy below to `seenAt` to learn that.
        history         = @($history.Values | Sort-Object Seen -Descending | Select-Object -First $historyMax | ForEach-Object {
                [ordered]@{
                    path      = $_.Path
                    promoted  = [int]$_.Promoted
                    cooled    = [int]$_.Cooled
                    seenAt    = $_.Seen.ToString('o')
                    expiresAt = if ($historyCutoff) { $_.Seen.AddDays($PromotionHistoryDays).ToString('o') } else { $null }
                }
            })
        # The aging policy in force, because the numbers above are only meaningful with it:
        # the same `promoted = 2` means "still churning" or "long gone" depending on these.
        historyPolicy   = [ordered]@{
            maxEntries      = $historyMax
            forgetAfterDays = [int]$PromotionHistoryDays
            # The cutoff this run applied while loading the file; null when aging is off.
            forgetBefore    = if ($historyCutoff) { $historyCutoff.ToString('o') } else { $null }
            # What happens to an entry that ages out: it is dropped, so a returning directory
            # starts from zero rather than continuing a count nothing has earned.
            whenForgotten   = if ($historyCutoff) { 'entry is dropped at load and its counts restart at 0' } else { 'aging disabled: entries are kept until -PromotionHistoryMax drops the oldest' }
        }
        drive           = "$DriveLetter`:"
        freeBytes       = $freeBytes
        totalBytes      = $totalBytes
        minFreeGB       = $MinFreeGB
        truncated       = [bool]$script:Truncated
        baselineComplete = [bool]$baselineComplete
        # Paths this run could not read in full, or could not enumerate at all. A figure
        # absent from `paths` and listed here is unmeasured, not missing.
        unmeasured      = @($unmeasuredWrite | Select-Object -Unique)
        scanSeconds     = $elapsed
        # Only a raised alert moves the clock; a quiet run must not eat the next one.
        lastAlert       = if ($alerted) { $script:Now.ToString('o') } elseif ($previous) { $previous.lastAlert } else { $null }
        lastAlertReason = if ($alerted) { ($why -join '; ') } elseif ($previous) { $previous.lastAlertReason } else { $null }
        # Kept so the next run (and a human reading the state) can see what the last
        # unexplained drop turned out to be, even though the alert is throttled.
        # What the roots cannot see, as last measured and when it was measured: the next
        # alert compares against these instead of only repeating them. An entry this run
        # could not read keeps the earlier measurement and its time, so a run without
        # elevation cannot erase the shadow baseline the next elevated sample uses.
        notRanked       = $notRankedWrite
        correlation     = if ($correlation) {
            [ordered]@{
                at          = $script:Now.ToString('o')
                windowStart = $correlation.WindowStart.ToString('o')
                totalBytes  = $correlation.TotalBytes
                walked      = $correlation.Walked
                truncated   = [bool]$correlation.Truncated
                seconds     = $correlation.Seconds
                dirs        = @($correlation.Dirs | ForEach-Object { [ordered]@{ path = $_.Path; bytes = $_.Bytes; files = $_.Files } })
            }
        } elseif ($previous) { $previous.correlation } else { $null }
        paths           = $pathsWrite
    }
    try {
        $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8
    } catch { Write-Log "  (could not write ${statePath}: $($_.Exception.Message))" }
}

# A manual dry run has to leave its plan where a person will look for it: the log is the
# history, not the place anyone reads a preview. So the body is built and written even
# when the drive is healthy -- under a header that says plan, with no toast and a zero
# exit, so nothing downstream mistakes it for an alert. A run that would have alerted
# and is throttled still exits above this: there the file holds the real alert.
$planOnly = $DryRun -and -not $alert
if (-not $alert -and -not $planOnly) { exit 0 }

if ($throttled) {
    Write-Log ("  alert suppressed: last alert {0:yyyy-MM-dd HH:mm} is within {1}h" -f $lastAlert, $ReAlertHours)
    exit 1
}

$lines = New-Object System.Collections.Generic.List[string]
if ($planOnly) {
    $lines.Add(("C: SPACE PLAN (dry run) - {0}" -f $script:Now))
} else {
    $lines.Add(("C: SPACE ALERT - {0}" -f $script:Now))
}
$lines.Add('')
$lines.Add(("free        : {0:N2} GB of {1:N2} GB  (floor {2} GB)" -f $freeGB, ($totalBytes / 1GB), $MinFreeGB))
if ($prevFree -ne $null) {
    $lines.Add(("change      : {0}{1:N2} GB since the previous sample" -f $(if ($fellGB -lt 0) { '+' } else { '-' }), [math]::Abs($fellGB)))
} else {
    $lines.Add('change      : no previous sample')
}
if ($planOnly) {
    # The plan is the whole document here, so the reason it is a plan and not an alert
    # has to be stated rather than implied by a missing alert.
    $lines.Add(("why         : no alert would be raised -- free space is above the {0} GB floor and the fall is under the {1} GB trigger" -f $MinFreeGB, $DropGB))
} else {
    $lines.Add(("why         : {0}" -f ($why -join '; ')))
}
if ($unrankedNotes.Count -gt 0) { $lines.Add(("not ranked  : {0}" -f ($unrankedNotes -join '; '))) }
if ($installNote) { $lines.Add(("install     : {0}" -f $installNote)) }
if ($sweptNote) { $lines.Add(("swept       : {0}" -f $sweptNote)) }
if ($sweepPlanNote) { $lines.Add(("would sweep : {0}" -f ($sweepPlanNote -replace '^would sweep ', ''))) }
if ($promotedNote) { $lines.Add(("promoted    : {0}" -f ($promotedNote -replace '^next run also measures: ', ''))) }
if ($promotedExpired.Count -gt 0) { $lines.Add(("expired     : {0} after {1} run(s){2}" -f (($promotedExpired | ForEach-Object { Shorten-Path $_ }) -join ' | '), $PromotedMaxRuns, $(if ($cooldownHours -gt 0) { ", cooling $cooldownHours h" } else { '' }))) }
if ($repeatText) { $lines.Add(("repeat      : {0} -- this directory has churned before" -f $repeatText)) }
if ($coolingText) { $lines.Add(("cooling     : {0} -- named again, not re-promoted" -f $coolingText)) }
if ($promotedTrimmed.Count -gt 0) { $lines.Add(("not sampled : {0} (promotion cap {1})" -f (($promotedTrimmed | ForEach-Object { Shorten-Path $_ }) -join ' | '), $promotionCap)) }
if ($actionNote) { $lines.Add(("acted       : {0}" -f $actionNote)) }
if ($growerPlanNote) { $lines.Add(("would act   : {0}" -f $growerPlanNote)) }
if ($sweepAction -and $sweepAction.Blocked) { $lines.Add(("blocked     : {0}" -f $sweepAction.BlockedNote)) }
$cacheLine = if ($cacheNote) { $cacheNote } else { $cacheSkipNote }
if ($cacheLine) {
    # A planned clear is not a cleared one, so the label says which this is, and the note's
    # own leading "would clear" is stripped rather than said twice.
    if ($DryRun) { $lines.Add(("would clear : {0}" -f ($cacheLine -replace '^would clear ', ''))) }
    else { $lines.Add(("cleared     : {0}" -f $cacheLine)) }
}
if ($correlation) {
    $lines.Add('')
    $lines.Add('written in this window outside the watched roots:')
    if ($correlation.Dirs.Count -gt 0) {
        foreach ($d in $correlation.Dirs) {
            $lines.Add(("  +{0}  {1,6:N0} {2}  {3}" -f (Format-GB $d.Bytes).Trim(), $d.Files, $(if ($d.Files -eq 1) { 'file ' } else { 'files' }), (Shorten-Path $d.Path)))
        }
    } else {
        $lines.Add("  (nothing above $CorrelateMinMB MB -- the fall may be a pagefile, an in-place")
        $lines.Add('   overwrite of a file that already existed, or outside the scanned roots)')
    }
    $lines.Add(("  ({0:N2} GB fell since {1:HH:mm}, {2:N2} GB written across {3:N0} files walked in {4:N1}s{5})" -f `
            $fellGB, $correlation.WindowStart, ($correlation.TotalBytes / 1GB), $correlation.Walked, $correlation.Seconds,
            $(if ($correlation.Truncated) { ', truncated at budget' } else { '' })))
}
$lines.Add('')
$lines.Add('biggest growth since the previous sample:')
if ($growers.Count -gt 0) {
    foreach ($g in ($growers | Select-Object -First $Top)) {
        $lines.Add(("  {0}{1}  {2}" -f $(if ($g.Delta -ge 0) { '+' } else { '-' }), (Format-GB ([math]::Abs($g.Delta))).Trim(), $g.Path))
    }
} elseif ($script:Truncated) {
    # The budget stopped the scan, so an empty ranking is a statement about the time it had,
    # not about the disk: a directory that grew may never have been reached.
    $lines.Add('  (none ranked -- the scan stopped at its time budget, so a growing directory')
    $lines.Add('   may simply not have been reached)')
} elseif ($baselineIncomplete) {
    # Not the same fact as "nothing moved": the previous sample stopped before it reached
    # these directories, so there is no earlier figure to subtract. Saying "none changed"
    # would report the missing half of a baseline as a quiet disk.
    $lines.Add('  (none ranked -- the previous sample was cut short, so the directories it')
    $lines.Add('   never reached had no earlier figure; this run records them as their baseline)')
} elseif ($unreadableBaselinePaths -gt 0) {
    # Readable now, but its last figure is from before it was last measured: the same
    # absence as a cut-short baseline, one path at a time, and it becomes the baseline.
    $lines.Add(("  (none ranked -- {0} director{1} had no earlier figure, because it could not be read" -f $unreadableBaselinePaths, $(if ($unreadableBaselinePaths -eq 1) { 'y' } else { 'ies' })))
    $lines.Add('   last run; this run records it as the baseline)')
} elseif (@($unmeasured.Keys).Count -gt 0 -or $deniedRoots.Count -gt 0) {
    # An empty ranking beside something it could not read is not "nothing moved": what
    # moved inside that tree was never seen. After the first-sample branch, because with
    # no earlier sample there is no comparison at all -- the refusal is still named in the
    # line that follows this block.
    $blind = @($unmeasured.Keys).Count
    if ($blind -gt 0) {
        $lines.Add(("  (none ranked -- {0} director{1} could not be read in full, so what changed" -f $blind, $(if ($blind -eq 1) { 'y' } else { 'ies' })))
        $lines.Add("   inside $(if ($blind -eq 1) { 'it' } else { 'them' }) is unmeasured)")
    } else {
        $lines.Add('  (none ranked -- a watch root could not be enumerated, so the directories')
        $lines.Add('   it held were not compared this run)')
    }
} elseif (-not $previous) {
    # Two different facts, said differently: a first sample has nothing to compare against,
    # and a sample after one found nothing that moved. The old line said both at once, so
    # neither reader could tell which had happened.
    $lines.Add('  (none -- this is the first sample, so there is no earlier size to compare against)')
} else {
    $lines.Add('  (none -- no directory changed by 1 MB or more since the previous sample)')
}
if ($newBaselinePaths -gt 0 -and $growers.Count -gt 0) {
    # Some directories could be compared, some could not. The second kind has to be counted:
    # a directory missing from the list above would read as one that did not grow.
    $lines.Add(("  ({0} director{1} had no earlier figure -- the previous sample was cut short)" -f $newBaselinePaths, $(if ($newBaselinePaths -eq 1) { 'y' } else { 'ies' })))
}
if ($script:Truncated -and $script:PartialPath) {
    # Named rather than silently dropped: a directory missing from the list would read as
    # one that did not change. What is true is narrower -- it was cut short, so its size is
    # a fraction of its tree and no delta could be computed from it.
    $lines.Add(("  (cut short inside {0} -- its size is partial, so it is not ranked)" -f (Shorten-Path $script:PartialPath)))
}
foreach ($p in @($unmeasured.Keys)) {
    # Named for the same reason the cut-short directory is: a tree missing from the list
    # above would read as one that did not change, and the figure this run measured is
    # only the part of it this account was allowed to see.
    $inside = @($unmeasured[$p])
    $lines.Add(("  (could not read all of {0} -- {1} director{2} inside denied access," -f (Shorten-Path $p), $inside.Count, $(if ($inside.Count -eq 1) { 'y' } else { 'ies' })))
    $lines.Add('   so its size is a floor and it is not ranked; its last figure is kept)')
}
if ($deniedRoots.Count -gt 0) {
    $lines.Add(("  (could not enumerate {0} -- its children keep their last figures)" -f (($deniedRoots | ForEach-Object { Shorten-Path $_ }) -join ', ')))
}
if ($unreadableBaselinePaths -gt 0 -and $growers.Count -gt 0) {
    $lines.Add(("  ({0} director{1} had no earlier figure -- it could not be read last run)" -f $unreadableBaselinePaths, $(if ($unreadableBaselinePaths -eq 1) { 'y' } else { 'ies' })))
}
$lines.Add('')
$lines.Add('largest directories now:')
foreach ($l in $largest) {
    $row = "  {0}  {1}" -f (Format-GB $l.Bytes).Trim(), $l.Path
    if ($l.FloorNote) { $row += "  ($($l.FloorNote))" }
    $lines.Add($row)
}
$lines.Add('')
if ($script:Truncated) {
    $lines.Add("NOTE: the scan hit its ${TimeBudgetSeconds}s budget, so sizes are partial and")
    $lines.Add('      the ranking may be incomplete. Raise -TimeBudgetSeconds.')
    $lines.Add('')
}
if ($DryRun) {
    if ($sweepAction -and $sweepAction.Blocked) {
        # "Re-run without -DryRun" is the wrong next step here: that re-run would be the
        # elevated one, and it declines the collector for the same reason this plan did.
        # The plan's own half is unaffected -- nothing was deleted because it was a plan --
        # so the advice keeps both facts and points at the run that can actually clear it.
        $lines.Add('what to do: this was a dry run -- nothing was deleted, so the free-space figure')
        $lines.Add('            above is unchanged. Dropping -DryRun would not clear the sandbox named')
        $lines.Add('            in blocked either: an elevated run does not start the collector. Run')
        $lines.Add('            c-space-watch.ps1 from a normal prompt to clear it -- or keep it with')
        $lines.Add('            its reason if the owner is still alive.')
    } else {
        $lines.Add('what to do: this was a dry run -- nothing was deleted, so the free-space figure')
        $lines.Add('            above is unchanged. Re-run without -DryRun to act on the lines above.')
    }
} elseif ($actioned.Count -gt 0 -or $cacheCleared.Count -gt 0 -or $cacheNote) {
    $lines.Add('what to do: what the notes above report as cleared is already reflected in the')
    $lines.Add('            free-space figure on this run. Anything still listed as growth was left')
    $lines.Add('            alone -- a live owner, a file in use, past the cache cap, or not something')
    $lines.Add('            this task clears. A project tree is never touched.')
} elseif (-not $topGrower) {
    # "Start with the top grower" beside a list that names none is advice the reader cannot
    # follow, so this case gets its own: the numbers are on the page, the culprit is not.
    if ($script:Truncated) {
        # Before first sample, before fall, before flat: a scan that ran out of time may not
        # have reached the directory that grew at all, so "nothing grew" is the one thing
        # this run cannot have found out. Telling the reader to wait for the next sample
        # would only work if that one finished.
        $lines.Add('what to do: the scan ran out of its time budget before it finished, so a directory')
        $lines.Add('            that grew may simply not have been measured -- this run cannot say that')
        $lines.Add('            nothing grew. Raise -TimeBudgetSeconds, or narrow -WatchRoot to the roots')
        $lines.Add('            that matter, and let a full scan rank the growth.')
    } elseif (-not $previous) {
        # The first sample has no earlier size to compare with, so "nothing grew" is not
        # something this run found out -- it is a comparison that was never made. What the
        # run is actually for is the baseline, and the advice should say so.
        $lines.Add('what to do: this is the first sample, so there is no growth ranking yet -- the sizes')
        $lines.Add('            above are the baseline the next run measures against. Look at the largest')
        $lines.Add('            directories now, or let the next sample show what moved.')
    } elseif (@($unmeasured.Keys).Count -gt 0 -or $deniedRoots.Count -gt 0) {
        # More specific than the fall advice below: part of what this run measures was not
        # measured at all, so "the fall is something else on the volume" would be a guess
        # this run is in no position to make.
        $lines.Add('what to do: part of what this run measures could not be read, so nothing inside')
        $lines.Add('            it was measured. A scheduled run with highest privileges may read it on')
        $lines.Add('            the next tick; until then the last readable figures are kept as the')
        $lines.Add('            baseline, so the gap is not reported as growth when it can be read again.')
    } elseif ($prevFree -ne $null -and $fellGB -ge 0.01) {
        # A real fall with nothing in the ranked roots to show for it. Naming a directory
        # would be a guess: the things that take space without growing a directory this
        # scan ranks are, by construction, ones it cannot see -- so name them instead.
        $lines.Add(("what to do: free space fell {0:N2} GB with nothing in the watch roots to show for it." -f $fellGB))
        $lines.Add('            What takes space without growing a directory this scan ranks sits')
        $lines.Add('            outside it: shadow copies and restore points, the pagefile or')
        $lines.Add('            hibernation file, a deleted file a process still holds open, or a')
        $lines.Add('            tree -WatchRoot does not cover (ProgramData, Program Files, much of')
        $lines.Add('            your profile). Start with the largest directories above, then')
        $lines.Add('            "vssadmin list shadowstorage" if the fall keeps repeating.')
    } else {
        $lines.Add('what to do: nothing grew enough to name, so there is no single directory to start')
        $lines.Add('            with. Look at the largest directories above, or let the next sample')
        $lines.Add('            show what moved.')
    }
} elseif ($sweepAction -and $sweepAction.Blocked) {
    # The verdict above is why this grower is still on disk, so the advice has to carry
    # it: the elevated run is not the one that can clear the sandbox, and the generic
    # "start with the top grower" would send the reader to the run that just refused.
    $lines.Add('what to do: the sandbox above is still on disk. Run c-space-watch.ps1 again from a')
    $lines.Add('            normal prompt: that run starts the collector, which clears it -- or keeps')
    $lines.Add('            it with its reason if the owner is still alive. Re-run after clearing to')
    $lines.Add('            confirm the free space holds.')
} else {
    $lines.Add('what to do: start with the top grower. %TEMP% sandboxes, browser caches and')
    $lines.Add('            app caches are regenerable; a project tree is not.')
    $lines.Add('            Re-run this script after clearing to confirm the free space holds.')
}
$body = ($lines -join [Environment]::NewLine)

try {
    Set-Content -LiteralPath $alertPath -Value $body -Encoding UTF8
    if ($planOnly) { Write-Log "  plan written to $alertPath (no alert would have been raised)" }
} catch { Write-Log "  (could not write $alertPath : $($_.Exception.Message))" }

# A plan raises no toast: the drive is fine, and a low-space bubble on a healthy run
# would cost the alert its meaning.
if (-not $planOnly) {
    if ($topGrower) {
        [void](Show-Toast "C: low on space -- $freeGB GB free" ("+{0} in {1}" -f (Format-GB $topGrower.Delta).Trim(), (Split-Path -Leaf $topGrower.Path)))
    } else {
        [void](Show-Toast "C: low on space -- $freeGB GB free" ($why -join '; '))
    }
}
if (-not $Quiet) { Write-Host ''; Write-Host $body }

if ($planOnly) { exit 0 }
exit 1
