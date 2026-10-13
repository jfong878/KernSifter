//! # Phase 1 — platform executors
//!
//! The strict conditional abstraction layer. [`crate::scanner::roots`]
//! declares *where* each OS keeps its junk; this module decides *what may be
//! done with it* — which categories are routine, which need an explicit tick,
//! which are never KernSifter's business, how old a file must be before it is
//! fair game, and whether a given path needs an elevated process.
//!
//! The split is deliberate. The scanner is a whitelist over *paths*; the
//! executor is a policy over *categories*. Neither can widen the other, and
//! the protected-path matrix still has the final say on every individual
//! entry, at scan time and again at execution time.
//!
//! ## The pipeline
//!
//! ```text
//!   platform_roots()  →  scan_roots()      →  plan()          →  register()
//!   scanner::roots       scanner::walk       platform::plan      manifest
//!   (where)              (what exists)       (what is fair)     (freeze)
//! ```
//!
//! [`plan`] is pure: it never touches the filesystem, only the report it is
//! handed. Everything that mutates still lives behind the Phase 2 gates, so a
//! plan can be computed, shown, and thrown away without consequence.
//!
//! ## Per-platform modules
//!
//! Each OS file exports a `PROFILE` table plus its own helpers. The policy
//! tables are plain data and are compiled on every platform, so the rules are
//! unit-tested from any host — the only `#[cfg]`-gated code is the handful of
//! calls that ask the live OS something.
//!
//! - [`windows`] — `%TEMP%`, `C:\Windows\Temp`, Prefetch, AppData orphans.
//! - [`macos`] — `~/Library/Caches`, `/Library/Caches`, `~/Library/Logs`.
//! - [`linux`] — `/var/cache/apt|dnf`, `~/.cache` (non-root safe).
//! - [`android`] — scoped storage + MediaStore, user-granted trees only.
//! - [`hardened_android`] — SAF-only, explicit per-directory grants, no
//!   `MANAGE_EXTERNAL_STORAGE`, no implicit roots, ever.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::scanner::{Category, RootScan, ScanEntry, ScanReport, ScanRoot};

pub mod android;
pub mod hardened_android;
pub mod linux;
pub mod macos;
pub mod windows;

/// Seconds in a day — the unit the age floors are expressed in.
const SECONDS_PER_DAY: u64 = 86_400;

/// Which OS an executor profile describes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub enum PlatformId {
    /// Windows 10/11 (and Server).
    Windows,
    /// macOS, desktop sandbox intact.
    MacOs,
    /// Desktop Linux (apt/dnf class distributions).
    Linux,
    /// Android with the stock scoped-storage model (SAF + MediaStore).
    Android,
    /// Hardened Android (GrapheneOS / CalyxOS): SAF-only, no legacy escapes.
    HardenedAndroid,
}

impl PlatformId {
    /// The platform this binary was compiled for.
    pub fn host() -> Self {
        #[cfg(windows)]
        {
            PlatformId::Windows
        }
        #[cfg(target_os = "macos")]
        {
            PlatformId::MacOs
        }
        #[cfg(all(unix, not(target_os = "macos"), not(target_os = "android")))]
        {
            PlatformId::Linux
        }
        #[cfg(target_os = "android")]
        {
            PlatformId::Android
        }
    }

    /// Short display name, safe to show in a UI status line.
    pub fn display_name(self) -> &'static str {
        match self {
            PlatformId::Windows => "Windows",
            PlatformId::MacOs => "macOS",
            PlatformId::Linux => "Linux",
            PlatformId::Android => "Android",
            PlatformId::HardenedAndroid => "Hardened Android",
        }
    }
}

/// How much of a category the user has to opt into before KernSifter will
/// act on it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub enum Confirmation {
    /// Regenerated on demand and holds no user data (temp, caches). These are
    /// the categories a one-click "Smart clean" may select by itself.
    Routine,
    /// Reclaimable, but the user must tick the category explicitly — the win
    /// is real but so is the surprise if the guess about intent is wrong.
    Explicit,
    /// Surfaced so the user can find and remove it themselves. KernSifter
    /// will never select these: deleting them is a decision only the owner of
    /// the data can make (a 40 GB model download, say).
    Manual,
    /// Not actionable through KernSifter at all. The OS trash is the only
    /// member: emptying it is permanent, so it is reported and left alone.
    Never,
}

impl Confirmation {
    /// Whether a one-click "Smart clean" may select this on its own.
    pub fn is_auto_selectable(self) -> bool {
        matches!(self, Confirmation::Routine)
    }
}

/// The executor's rules for one [`Category`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CategoryPolicy {
    /// The category these rules apply to.
    pub category: Category,
    /// How much opt-in the category needs.
    pub confirmation: Confirmation,
    /// Minimum age in days before a candidate may be selected.
    ///
    /// The floor is the executor's only proxy for "is this still in use",
    /// which no amount of path matching can answer. Zero means no floor.
    pub min_age_days: u32,
    /// Shown next to the category's toggle so the rule is never a black box.
    pub rationale: &'static str,
}

impl CategoryPolicy {
    /// Whether a file of the given age (in days) clears this category's floor.
    pub fn age_clears_floor(&self, age_days: u64) -> bool {
        age_days >= u64::from(self.min_age_days)
    }
}

/// Everything the executor knows about one OS.
#[derive(Debug, Clone, Copy)]
pub struct PlatformProfile {
    /// Which OS this profile describes.
    pub id: PlatformId,
    /// Display name for status lines.
    pub display_name: &'static str,
    /// Per-category rules, in presentation order. A category the OS has no
    /// roots for is simply absent — an absent category is refused by
    /// [`plan_for`], never guessed at.
    pub policies: &'static [CategoryPolicy],
    /// Whether deletions can be staged in an OS trash on this platform.
    ///
    /// `false` on Android: there deletions go through MediaStore / SAF user
    /// consent, which is not a recoverable trash step the core can perform
    /// itself, so a plan there is review-only until the app layer confirms.
    pub supports_os_trash: bool,
    /// Whether acting on `path` needs a privileged (administrator / root)
    /// process. Path-based, not category-based: the same category can be
    /// user-writable under `%LOCALAPPDATA%` and root-only under
    /// `C:\Windows`.
    pub needs_elevation: fn(&Path) -> bool,
}

impl PlatformProfile {
    /// The rules for `category`, or `None` when this platform has no roots for
    /// it.
    pub fn policy(&self, category: Category) -> Option<&'static CategoryPolicy> {
        self.policies
            .iter()
            .find(|p| p.category == category)
    }

    /// Whether `path` needs a privileged process on this platform.
    pub fn path_needs_elevation(&self, path: &Path) -> bool {
        (self.needs_elevation)(path)
    }

    /// Whether a selected plan has to be driven by the app layer instead of
    /// being executed by the core.
    ///
    /// True where deletions are consent-gated rather than recoverable:
    /// Android routes them through `MediaStore` / the Storage Access
    /// Framework, so the core can compute and freeze a plan but never carry
    /// it out itself. The shells read this to decide whether to show the
    /// system consent flow.
    pub fn requires_user_consent(&self) -> bool {
        !self.supports_os_trash
    }
}

/// The profile of the OS this binary was compiled for.
pub fn profile() -> &'static PlatformProfile {
    #[cfg(windows)]
    {
        &windows::PROFILE
    }
    #[cfg(target_os = "macos")]
    {
        &macos::PROFILE
    }
    #[cfg(all(unix, not(target_os = "macos"), not(target_os = "android")))]
    {
        &linux::PROFILE
    }
    // A hardened device (GrapheneOS / CalyxOS) is not a compile-time choice:
    // the app layer detects it at runtime and drives
    // [`hardened_android::plan`] instead, so the stock profile is the default
    // here and the hardened table is never silently selected.
    #[cfg(target_os = "android")]
    {
        &android::PROFILE
    }
}

/// All profiles, host first. Used by the shells to render the full policy
/// matrix and by the tests to exercise every table from any host.
pub fn all_profiles() -> [&'static PlatformProfile; 5] {
    [
        &windows::PROFILE,
        &macos::PROFILE,
        &linux::PROFILE,
        &android::PROFILE,
        &hardened_android::PROFILE,
    ]
}

/// Why a candidate was left out of a [`CleanupPlan`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum SkipReason {
    /// The OS trash is reported for visibility only; emptying it is a
    /// permanent delete, so KernSifter never selects its contents.
    RecycleBinIsNeverDeleted,
    /// Deliberately manual: the user removes these themselves.
    ManualReviewOnly,
    /// This platform has no sanctioned roots for the category.
    UnsupportedOnPlatform,
    /// The category needs the user to tick it explicitly.
    RequiresExplicitSelection,
    /// Younger than the category's age floor.
    TooRecent {
        /// How old the candidate is, in days.
        age_days: u64,
        /// The floor it had to clear.
        min_age_days: u32,
    },
    /// No modification time was recorded, so its age cannot be proven and the
    /// floor is enforced conservatively.
    AgeUnknown,
    /// The protected-path matrix refused this path at scan time. Execution
    /// re-checks it regardless; surfacing it here keeps the manifest honest.
    BlockedByMatrix,
}

impl SkipReason {
    /// A message suitable for a UI tooltip or a CLI line.
    pub fn message(&self) -> String {
        match self {
            SkipReason::RecycleBinIsNeverDeleted => {
                "OS trash is never deleted by KernSifter — empty it with the OS".to_string()
            }
            SkipReason::ManualReviewOnly => {
                "review and remove manually — KernSifter will not select these".to_string()
            }
            SkipReason::UnsupportedOnPlatform => {
                "this platform declares no roots for the category".to_string()
            }
            SkipReason::RequiresExplicitSelection => {
                "select the category explicitly to include it".to_string()
            }
            SkipReason::TooRecent {
                age_days,
                min_age_days,
            } => format!("only {age_days} day(s) old — the floor is {min_age_days}"),
            SkipReason::AgeUnknown => "no modification time recorded — age unproven".to_string(),
            SkipReason::BlockedByMatrix => "refused by the protected-path matrix".to_string(),
        }
    }

    /// Whether the exclusion is permanent for this candidate, as opposed to a
    /// floor the candidate may simply be too young for.
    pub fn is_permanent(&self) -> bool {
        !matches!(self, SkipReason::TooRecent { .. } | SkipReason::AgeUnknown)
    }
}

/// A candidate that did not make it into a [`CleanupPlan`], with the reason.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SkippedEntry {
    /// Absolute path of the candidate.
    pub path: PathBuf,
    /// Category it was found under.
    pub category: Category,
    /// Size in bytes at scan time.
    pub size_bytes: u64,
    /// Why it was excluded.
    pub reason: SkipReason,
}

/// Knobs for [`plan`]. `now_unix` is injected rather than read from the clock
/// so plans are deterministic and testable.
#[derive(Debug, Clone)]
pub struct PlanOptions {
    /// Wall-clock "now" in Unix seconds, used for the age floors.
    pub now_unix: u64,
    /// The categories the user selected. `None` means "smart clean": every
    /// category the profile marks [`Confirmation::Routine`].
    pub selected: Option<Vec<Category>>,
    /// Ignore the age floors. Still never overrides
    /// [`Confirmation::Manual`], [`Confirmation::Never`], the platform's
    /// unsanctioned categories, or the matrix.
    pub include_recent: bool,
}

impl PlanOptions {
    /// "Smart clean" options at wall-clock `now_unix`: routine categories,
    /// age floors enforced.
    pub fn smart_clean(now_unix: u64) -> Self {
        PlanOptions {
            now_unix,
            selected: None,
            include_recent: false,
        }
    }

    /// The given categories, age floors enforced.
    pub fn selecting(now_unix: u64, categories: Vec<Category>) -> Self {
        PlanOptions {
            now_unix,
            selected: Some(categories),
            include_recent: false,
        }
    }

    /// Turns the age floors off (everything else still applies).
    pub fn including_recent(mut self) -> Self {
        self.include_recent = true;
        self
    }

    fn selects(&self, category: Category) -> bool {
        match &self.selected {
            None => true,
            Some(selected) => selected.contains(&category),
        }
    }
}

/// The executor's answer to "of everything the scanner found, what is fair to
/// clean right now?" — everything else is in [`CleanupPlan::skipped`] with a
/// reason, so the UI can show the user exactly what it declined and why.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CleanupPlan {
    /// The profile the plan was computed against.
    pub platform: PlatformId,
    /// When the plan was computed (Unix seconds, from [`PlanOptions`]).
    pub generated_at_unix: u64,
    /// The candidates that may be acted on, sorted by path.
    pub eligible: Vec<ScanEntry>,
    /// The candidates that were left out, sorted by path, with reasons.
    pub skipped: Vec<SkippedEntry>,
    /// Whether any eligible path needs a privileged process.
    pub needs_elevation: bool,
}

impl CleanupPlan {
    /// Number of candidates the plan selected.
    pub fn eligible_count(&self) -> usize {
        self.eligible.len()
    }

    /// Bytes the plan would reclaim.
    pub fn eligible_bytes(&self) -> u64 {
        self.eligible.iter().map(|e| e.size_bytes).sum()
    }

    /// Number of candidates the plan declined.
    pub fn skipped_count(&self) -> usize {
        self.skipped.len()
    }

    /// Bytes the plan declined, per reason, for the "why is this still here?"
    /// panel.
    pub fn skipped_bytes_by_reason(&self) -> Vec<(SkipReason, u64)> {
        let mut out: Vec<(SkipReason, u64)> = Vec::new();
        for entry in &self.skipped {
            match out.iter_mut().find(|(r, _)| *r == entry.reason) {
                Some((_, bytes)) => *bytes += entry.size_bytes,
                None => out.push((entry.reason.clone(), entry.size_bytes)),
            }
        }
        out.sort_by(|a, b| b.1.cmp(&a.1));
        out
    }

    /// Rebuilds a [`ScanReport`] from the selected candidates, grouped by
    /// category.
    ///
    /// The manifest engine consumes reports, not plans, so this is the seam
    /// that keeps the Phase 2 gates untouched: `registry.register(&plan.to_scan_report())`
    /// freezes exactly the selected candidates, and execution re-validates
    /// every one of them.
    pub fn to_scan_report(&self) -> ScanReport {
        let mut categories: Vec<Category> = self.eligible.iter().map(|e| e.category).collect();
        categories.sort();
        categories.dedup();

        let roots = categories
            .into_iter()
            .map(|category| {
                let entries: Vec<ScanEntry> = self
                    .eligible
                    .iter()
                    .filter(|e| e.category == category)
                    .cloned()
                    .collect();
                let paths: Vec<PathBuf> = entries.iter().map(|e| e.path.clone()).collect();
                RootScan {
                    root: ScanRoot {
                        path: common_ancestor(&paths).unwrap_or_default(),
                        category,
                    },
                    entries,
                    errors: Vec::new(),
                }
            })
            .collect();

        ScanReport {
            scanned_at_unix: self.generated_at_unix,
            roots,
        }
    }

    /// The deepest directory every eligible entry shares with at least one
    /// other eligible entry, or `None` when the eligible set is empty or split
    /// across disjoint roots (e.g. Temp on C: and Cache on D:).
    //
    /// Used by the UI to describe a cleanup in one human-useful unit
    /// ("Chrome's cache", "npm's cache", "several roots") without
    /// confusing the user with the path shape of individual files. Callers
    /// typically show this alongside the per-category breakdown.
    pub fn common_ancestor_of_selected(&self) -> Option<PathBuf> {
        // Only entries that may actually be cleaned.
        let paths: Vec<PathBuf> = self
            .eligible
            .iter()
            .map(|e| e.path.clone())
            .collect();
        if paths.is_empty() {
            return None;
        }
        common_ancestor(&paths)
    }
}

/// Computes a cleanup plan for the host platform.
pub fn plan(report: &ScanReport, options: &PlanOptions) -> CleanupPlan {
    plan_for(profile(), report, options)
}

/// Computes a cleanup plan against an explicit profile.
///
/// Pure: reads nothing but the report it is given and the profile's rules, so
/// every platform's policy is exercisable from any host.
pub fn plan_for(
    profile: &PlatformProfile,
    report: &ScanReport,
    options: &PlanOptions,
) -> CleanupPlan {
    let mut eligible: Vec<ScanEntry> = Vec::new();
    let mut skipped: Vec<SkippedEntry> = Vec::new();

    for entry in report.roots.iter().flat_map(|r| r.entries.iter()) {
        let skip = classify(profile, entry, options);
        match skip {
            Some(reason) => skipped.push(SkippedEntry {
                path: entry.path.clone(),
                category: entry.category,
                size_bytes: entry.size_bytes,
                reason,
            }),
            None => eligible.push(entry.clone()),
        }
    }

    eligible.sort_by(|a, b| a.path.cmp(&b.path));
    skipped.sort_by(|a, b| a.path.cmp(&b.path));

    let needs_elevation = eligible
        .iter()
        .any(|e| profile.path_needs_elevation(&e.path));

    CleanupPlan {
        platform: profile.id,
        generated_at_unix: options.now_unix,
        eligible,
        skipped,
        needs_elevation,
    }
}

/// The rule that excluded one entry, or `None` when it may be acted on.
fn classify(profile: &PlatformProfile, entry: &ScanEntry, options: &PlanOptions) -> Option<SkipReason> {
    // The matrix is consulted first: a policy exception never widens it.
    if !entry.verdict.allowed {
        return Some(SkipReason::BlockedByMatrix);
    }

    let policy = match profile.policy(entry.category) {
        Some(policy) => policy,
        None => return Some(SkipReason::UnsupportedOnPlatform),
    };

    match policy.confirmation {
        Confirmation::Never => return Some(SkipReason::RecycleBinIsNeverDeleted),
        Confirmation::Manual => return Some(SkipReason::ManualReviewOnly),
        Confirmation::Explicit | Confirmation::Routine => {}
    }

    // A category is only auto-selectable when the user has not narrowed the
    // plan; with an explicit selection, the tick is the confirmation.
    let wants_category = if options.selected.is_none() {
        policy.confirmation.is_auto_selectable()
    } else {
        options.selects(entry.category)
    };
    if !wants_category {
        return Some(SkipReason::RequiresExplicitSelection);
    }

    if options.include_recent || policy.min_age_days == 0 {
        return None;
    }

    // No timestamp means no proof of age, and an unproven age is not old.
    let modified = match entry.modified_unix {
        Some(modified) => modified,
        None => return Some(SkipReason::AgeUnknown),
    };
    let age_seconds = options.now_unix.saturating_sub(modified);
    let age_days = age_seconds / SECONDS_PER_DAY;
    if policy.age_clears_floor(age_days) {
        None
    } else {
        Some(SkipReason::TooRecent {
            age_days,
            min_age_days: policy.min_age_days,
        })
    }
}

/// The deepest directory that contains every given path.
///
/// Used to name a [`RootScan`] after the tree its entries live in. Returns
/// `None` for an empty slice. When a single path is given (or every path
/// shares one full path) its parent is returned, so the result is always a
/// directory rather than a file.
pub fn common_ancestor(paths: &[PathBuf]) -> Option<PathBuf> {
    let mut iter = paths.iter();
    let first = iter.next()?.as_path();
    let mut shared: Vec<_> = first.components().collect();
    for path in iter {
        let mut other = path.components();
        let mut common = 0usize;
        for (a, b) in shared.iter().zip(other.by_ref()) {
            if *a != b {
                break;
            }
            common += 1;
        }
        shared.truncate(common);
    }
    // A single file (or one identical path) is not a usable root.
    if shared.len() == first.components().count() {
        shared.pop();
    }
    if shared.is_empty() {
        return None;
    }
    Some(shared.iter().collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::safety::protected::ProtectionVerdict;

    const NOW: u64 = 1_800_000_000;

    fn entry(path: &str, category: Category, size: u64, age_days: u64) -> ScanEntry {
        ScanEntry {
            path: PathBuf::from(path),
            category,
            kind: crate::scanner::EntryKind::File,
            file_type: None,
            size_bytes: size,
            modified_unix: Some(NOW - age_days * SECONDS_PER_DAY),
            verdict: ProtectionVerdict {
                allowed: true,
                reason: None,
                rule: None,
            },
        }
    }

    fn report(entries: Vec<ScanEntry>) -> ScanReport {
        ScanReport {
            scanned_at_unix: NOW,
            roots: vec![RootScan {
                root: ScanRoot {
                    path: PathBuf::from("C:\\Temp"),
                    category: Category::Temp,
                },
                entries,
                errors: Vec::new(),
            }],
        }
    }

    // ── Profile table integrity ───────────────────────────────────────────

    /// Every profile must cover its categories exactly once — a duplicate row
    /// would silently shadow the first, and a missing row would silently drop
    /// a category from the UI.
    #[test]
    fn every_profile_lists_each_category_at_most_once() {
        for profile in all_profiles() {
            let mut seen: Vec<Category> = profile.policies.iter().map(|p| p.category).collect();
            let count = seen.len();
            seen.sort();
            seen.dedup();
            assert_eq!(
                seen.len(),
                count,
                "{} lists a category twice: {seen:?}",
                profile.display_name
            );
        }
    }

    /// The two categories with non-negotiable rules must be non-negotiable on
    /// every platform: the OS trash is never deleted, and model weights are
    /// never auto-selected.
    #[test]
    fn trash_and_models_are_never_routine_anywhere() {
        for profile in all_profiles() {
            let trash = profile
                .policy(Category::RecycleBin)
                .unwrap_or_else(|| panic!("{} must declare the trash", profile.display_name));
            assert_eq!(
                trash.confirmation,
                Confirmation::Never,
                "{} must never delete trash",
                profile.display_name
            );

            let models = profile
                .policy(Category::AiModels)
                .unwrap_or_else(|| panic!("{} must declare AI models", profile.display_name));
            assert_eq!(
                models.confirmation,
                Confirmation::Manual,
                "{} must never auto-select model weights",
                profile.display_name
            );
        }
    }

    /// Every category the host platform actually scans must have a policy —
    /// otherwise `plan()` would report its own scanner's output as
    /// "unsupported on this platform".
    #[test]
    fn host_scan_roots_all_have_a_policy() {
        let profile = profile();
        for root in crate::scanner::platform_roots() {
            assert!(
                profile.policy(root.category).is_some(),
                "{}: scanned category {:?} has no policy",
                profile.display_name,
                root.category
            );
        }
    }

    /// A smart clean must never select anything outside a sanctioned root,
    /// and must never select the trash — the two invariants the UI's biggest
    /// button depends on.
    #[test]
    fn smart_clean_only_selects_routine_categories() {
        let profile = profile();
        let entries: Vec<ScanEntry> = vec![
            entry("C:\\a.tmp", Category::Temp, 10, 400),
            entry("C:\\a.bin", Category::RecycleBin, 10_000, 400),
            entry("C:\\model.gguf", Category::AiModels, 90_000, 400),
        ];
        let plan = plan_for(profile, &report(entries), &PlanOptions::smart_clean(NOW));

        for e in &plan.eligible {
            let policy = profile.policy(e.category).expect("policy");
            assert!(
                policy.confirmation.is_auto_selectable(),
                "smart clean selected {:?}",
                e.category
            );
        }
        assert!(!plan
            .skipped
            .iter()
            .any(|s| s.category == Category::RecycleBin && !s.reason.is_permanent()));
    }

    // ── Plan filtering ────────────────────────────────────────────────────

    /// The age floor is the executor's proxy for "still in use": a log older
    /// than its floor is fair game, a fresh one is not.
    #[test]
    fn age_floor_excludes_recent_candidates() {
        let profile = &linux::PROFILE;
        let entries = vec![
            entry("/var/log/old.log", Category::Logs, 10, 400),
            entry("/var/log/new.log", Category::Logs, 10, 0),
        ];
        let plan = plan_for(profile, &report(entries), &PlanOptions::smart_clean(NOW));

        assert_eq!(plan.eligible_count(), 1, "{plan:?}");
        assert_eq!(plan.eligible[0].path, PathBuf::from("/var/log/old.log"));

        let skipped = &plan.skipped[0];
        assert_eq!(skipped.path, PathBuf::from("/var/log/new.log"));
        assert!(
            matches!(skipped.reason, SkipReason::TooRecent { min_age_days, .. } if min_age_days > 0),
            "{skipped:?}"
        );
        assert!(!skipped.reason.is_permanent());
    }

    /// `include_recent` lowers the floor but leaves the non-negotiables alone.
    #[test]
    fn include_recent_lowers_the_floor_but_not_the_rules() {
        let profile = &linux::PROFILE;
        let entries = vec![
            entry("/var/log/new.log", Category::Logs, 10, 0),
            entry("/var/log/trash.bin", Category::RecycleBin, 10, 0),
            entry("/var/log/model.gguf", Category::AiModels, 10, 0),
        ];
        let options = PlanOptions::smart_clean(NOW).including_recent();
        let plan = plan_for(profile, &report(entries), &options);

        assert_eq!(plan.eligible_count(), 1, "{plan:?}");
        assert_eq!(plan.eligible[0].path, PathBuf::from("/var/log/new.log"));
        assert!(plan
            .skipped
            .iter()
            .any(|s| s.reason == SkipReason::RecycleBinIsNeverDeleted));
        assert!(plan
            .skipped
            .iter()
            .any(|s| s.reason == SkipReason::ManualReviewOnly));
    }

    /// Download archives are never swept up automatically on any platform:
    /// an archive in a package cache can be a *pending* update, so it is the
    /// user's explicit call. A profile with no roots for the category may
    /// simply omit the row.
    #[test]
    fn package_cache_is_never_routine_anywhere() {
        let mut declared = 0;
        for profile in all_profiles() {
            if let Some(policy) = profile.policy(Category::PackageCache) {
                declared += 1;
                assert_eq!(
                    policy.confirmation,
                    Confirmation::Explicit,
                    "{} must require an explicit tick for download archives",
                    profile.display_name
                );
                assert!(!policy.confirmation.is_auto_selectable());
            }
        }
        assert!(declared >= 3, "Windows/macOS/Linux all declare a package cache");
    }

    /// A category with no policy on this platform is refused, not guessed.
    #[test]
    fn unsanctioned_categories_are_refused() {
        // Prefetch is a Windows-only root; the macOS profile has no policy
        // for it, so a report containing one must be declined.
        let entry = entry("C:\\Windows\\Prefetch\\APP.EXE-1A2B3C", Category::Prefetch, 5, 400);
        let plan = plan_for(
            &macos::PROFILE,
            &report(vec![entry]),
            &PlanOptions::selecting(NOW, vec![Category::Prefetch]),
        );
        assert!(plan.eligible.is_empty(), "{plan:?}");
        assert_eq!(plan.skipped[0].reason, SkipReason::UnsupportedOnPlatform);
    }

    /// The matrix outranks the policy: a denied entry is skipped even in a
    /// category the user explicitly selected and with floors disabled.
    #[test]
    fn matrix_verdicts_outrank_policy() {
        let mut e = entry("C:\\Temp\\ok.tmp", Category::Temp, 10, 0);
        e.verdict.allowed = false;
        let options = PlanOptions::selecting(NOW, vec![Category::Temp]).including_recent();
        let plan = plan_for(&windows::PROFILE, &report(vec![e]), &options);

        assert!(plan.eligible.is_empty(), "{plan:?}");
        assert_eq!(plan.skipped[0].reason, SkipReason::BlockedByMatrix);
    }

    /// An entry with no timestamp cannot prove its age, so the floor is
    /// enforced against it conservatively.
    #[test]
    fn missing_timestamp_cannot_clear_the_floor() {
        let mut e = entry("/var/log/unknown.log", Category::Logs, 10, 0);
        e.modified_unix = None;
        let plan = plan_for(
            &linux::PROFILE,
            &report(vec![e]),
            &PlanOptions::smart_clean(NOW),
        );
        assert!(plan.eligible.is_empty(), "{plan:?}");
        assert_eq!(plan.skipped[0].reason, SkipReason::AgeUnknown);
    }

    /// A clock that runs backwards must not make a fresh file look ancient.
    #[test]
    fn future_timestamps_are_treated_as_zero_age() {
        let mut e = entry("/var/log/future.log", Category::Logs, 10, 0);
        e.modified_unix = Some(NOW + 10 * SECONDS_PER_DAY);
        let plan = plan_for(&linux::PROFILE, &report(vec![e]), &PlanOptions::smart_clean(NOW));
        assert!(plan.eligible.is_empty(), "{plan:?}");
        assert!(matches!(
            plan.skipped[0].reason,
            SkipReason::TooRecent { age_days: 0, .. }
        ));
    }

    /// An explicit selection is the confirmation: a non-routine category the
    /// user ticked is included, one they did not is not.
    #[test]
    fn explicit_selection_includes_only_what_was_ticked() {
        let entries = vec![
            entry("/var/cache/apt/archives/pkg.deb", Category::PackageCache, 10, 400),
            entry("/var/lib/orphan", Category::AppOrphan, 10, 400),
        ];
        let options = PlanOptions::selecting(NOW, vec![Category::PackageCache]);
        let plan = plan_for(&linux::PROFILE, &report(entries), &options);

        assert_eq!(plan.eligible_count(), 1, "{plan:?}");
        assert_eq!(plan.eligible[0].category, Category::PackageCache);
        assert_eq!(
            plan.skipped[0].reason,
            SkipReason::RequiresExplicitSelection
        );
    }

    // ── Site storage ──────────────────────────────────────────────────────

    /// Offline site data must survive a smart clean untouched — only a
    /// deliberate, by-name selection may include it. This is the invariant
    /// that keeps one click from destroying a web app's Service Worker state.
    #[test]
    fn site_storage_is_never_swept_up_by_a_smart_clean() {
        let sw = entry(
            "C:\\browser\\Default\\Service Worker\\CacheStorage\\x",
            Category::SiteStorage,
            500,
            400,
        );

        let smart = plan_for(
            &windows::PROFILE,
            &report(vec![sw.clone()]),
            &PlanOptions::smart_clean(NOW),
        );
        assert!(smart.eligible.is_empty(), "{smart:?}");
        assert_eq!(smart.skipped[0].reason, SkipReason::RequiresExplicitSelection);

        let explicit = plan_for(
            &windows::PROFILE,
            &report(vec![sw]),
            &PlanOptions::selecting(NOW, vec![Category::SiteStorage]),
        );
        assert_eq!(explicit.eligible_count(), 1, "{explicit:?}");
        assert_eq!(explicit.eligible[0].category, Category::SiteStorage);
    }

    // ── Elevation ─────────────────────────────────────────────────────────

    /// Elevation is a property of the path, not the category: the same
    /// category is user-writable under a profile dir and root-only under
    /// `C:\Windows`.
    #[test]
    fn elevation_is_decided_per_path() {
        let windows_profile = &windows::PROFILE;
        assert!(!windows_profile.path_needs_elevation(Path::new(
            "C:\\Users\\jfong\\AppData\\Local\\Temp\\a.tmp"
        )));
        assert!(windows_profile.path_needs_elevation(Path::new(
            "C:\\Windows\\Temp\\a.tmp"
        )));

        let linux_profile = &linux::PROFILE;
        assert!(!linux_profile.path_needs_elevation(Path::new("/home/u/.cache/a")));
        assert!(linux_profile.path_needs_elevation(Path::new("/var/cache/apt/a.deb")));

        let macos_profile = &macos::PROFILE;
        assert!(macos_profile.path_needs_elevation(Path::new("/Library/Caches/a")));
        assert!(!macos_profile
            .path_needs_elevation(Path::new("/Users/u/Library/Caches/a")));
    }

    /// The plan flags elevation only when something it selected actually needs
    /// it — a user-only plan must never demand an admin prompt.
    #[test]
    fn plan_flags_elevation_only_when_selected_paths_need_it() {
        let user_temp = entry("C:\\Users\\u\\AppData\\Local\\Temp\\a.tmp", Category::Temp, 10, 400);
        let system_temp = entry("C:\\Windows\\Temp\\b.tmp", Category::Temp, 10, 400);

        let user_only = plan_for(
            &windows::PROFILE,
            &report(vec![user_temp.clone()]),
            &PlanOptions::smart_clean(NOW),
        );
        assert!(!user_only.needs_elevation, "{user_only:?}");

        let mixed = plan_for(
            &windows::PROFILE,
            &report(vec![user_temp, system_temp]),
            &PlanOptions::smart_clean(NOW),
        );
        assert!(mixed.needs_elevation, "{mixed:?}");
    }

    /// Android must never claim it can stage a trash move — its deletions
    /// need a user-consented MediaStore/SAF request instead.
    #[test]
    fn android_profiles_do_not_claim_os_trash_staging() {
        assert!(!android::PROFILE.supports_os_trash);
        assert!(!hardened_android::PROFILE.supports_os_trash);
        assert!(!hardened_android::PROFILE.path_needs_elevation(Path::new("/data/local/tmp")));
    }

    // ── Report reconstruction ─────────────────────────────────────────────

    /// The plan→report seam must group by category and stay sorted, so the
    /// manifest it feeds passes `verify()` unchanged.
    #[test]
    fn plan_rebuilds_a_grouped_report() {
        let entries = vec![
            entry("C:\\b.tmp", Category::Temp, 5, 400),
            entry("C:\\a.tmp", Category::Temp, 7, 400),
            entry("C:\\c.bin", Category::Cache, 3, 400),
        ];
        let plan = plan_for(
            &windows::PROFILE,
            &report(entries),
            &PlanOptions::smart_clean(NOW),
        );
        let rebuilt = plan.to_scan_report();

        assert_eq!(rebuilt.roots.len(), 2, "{rebuilt:?}");
        let temp = rebuilt
            .roots
            .iter()
            .find(|r| r.root.category == Category::Temp)
            .expect("temp root");
        assert_eq!(temp.entries.len(), 2, "{rebuilt:?}");
        assert!(temp.root.path.is_absolute(), "{temp:?}");
        assert!(temp.entries[0].path < temp.entries[1].path, "{temp:?}");

        // The rebuilt report must survive the manifest engine untouched.
        let registry = crate::safety::manifest::ManifestRegistry::default();
        let id = registry.register(&rebuilt);
        let manifest = registry.get(id).expect("registered");
        assert_eq!(manifest.total_bytes, 15);
        manifest.verify().expect("manifest must verify");
    }

    /// An empty plan must still produce a valid (empty) report rather than
    /// panicking on the ancestor search.
    #[test]
    fn empty_plan_rebuilds_an_empty_report() {
        let plan = plan_for(&windows::PROFILE, &report(Vec::new()), &PlanOptions::smart_clean(NOW));
        assert!(plan.eligible.is_empty());
        assert_eq!(plan.to_scan_report().roots.len(), 0);
    }

    // ── common_ancestor ───────────────────────────────────────────────────

    #[test]
    fn common_ancestor_finds_the_shared_directory() {
        let paths = vec![
            PathBuf::from("/var/cache/apt/a.deb"),
            PathBuf::from("/var/cache/apt/sub/b.deb"),
            PathBuf::from("/var/cache/c.deb"),
        ];
        assert_eq!(
            common_ancestor(&paths),
            Some(PathBuf::from("/var/cache"))
        );
    }

    /// A lone file has no shared directory with itself, so its parent is the
    /// answer — a root must be a directory, never a candidate file.
    #[test]
    fn common_ancestor_of_one_path_is_its_parent() {
        assert_eq!(
            common_ancestor(&[PathBuf::from("/var/log/app.log")]),
            Some(PathBuf::from("/var/log"))
        );
    }

    /// Siblings on different volumes share nothing usable — the result must
    /// never be one of the candidate files.
    #[test]
    fn common_ancestor_of_disjoint_paths_is_never_a_candidate_file() {
        let paths = vec![PathBuf::from("C:\\a\\x.tmp"), PathBuf::from("D:\\b\\y.tmp")];
        if let Some(ancestor) = common_ancestor(&paths) {
            assert!(ancestor.components().count() <= 2, "{ancestor:?}");
        }

        assert_eq!(common_ancestor(&[]), None);
    }
}
