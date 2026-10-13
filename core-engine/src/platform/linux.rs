//! Linux executor: `/var/cache/apt|dnf`, `~/.cache` (non-root safe).
//!
//! Linux is the one desktop platform where cleaning a *system* directory is
//! part of the normal job, which brings its own hazard: `/var/cache/apt` and
//! `/var/cache/dnf` belong to the package manager, and deleting archives out
//! from under a running `apt`/`dnf` can leave it with a package database that
//! no longer matches the files on disk. [`package_manager_lock`] is the
//! executor's check for that, and the package cache is
//! [`Confirmation::Explicit`] on top of a 30-day floor: it is the user's call
//! whether a re-download is cheap, and a month is long enough that a running
//! upgrade is long over.
//!
//! `~/.cache` is the opposite case — user-owned and never worth a `sudo`
//! prompt — but it also holds build caches that a working developer is using
//! right now, so it carries a 7-day floor.

use std::path::{Path, PathBuf};

use super::{CategoryPolicy, Confirmation, PlatformId, PlatformProfile};
use crate::scanner::Category;

/// Lock files held by the common package managers while they are running.
///
/// A present lock file means a package operation is in flight; the package
/// cache must not be touched until it is gone.
const PACKAGE_MANAGER_LOCKS: &[&str] = &[
    "/var/lib/dpkg/lock-frontend",
    "/var/lib/dpkg/lock",
    "/var/lib/rpm/.rpm.lock",
    "/var/cache/dnf/metadata_lock.pid",
    "/var/lib/apt/lists/lock",
];

/// The Linux executor profile.
///
/// `Cache` carries the 7-day floor; `PackageCache` is explicit and 30 days.
pub const PROFILE: PlatformProfile = PlatformProfile {
    id: PlatformId::Linux,
    display_name: "Linux",
    policies: &[
        CategoryPolicy {
            category: Category::Temp,
            confirmation: Confirmation::Routine,
            min_age_days: 0,
            rationale: "scratch files; anything still open is refused at execution",
        },
        CategoryPolicy {
            category: Category::Cache,
            confirmation: Confirmation::Routine,
            min_age_days: 7,
            rationale: "user cache — but it holds live build caches, so keep a week",
        },
        CategoryPolicy {
            category: Category::Logs,
            confirmation: Confirmation::Routine,
            min_age_days: 7,
            rationale: "keep a week of logs for post-mortem diagnosis",
        },
        CategoryPolicy {
            category: Category::PackageCache,
            confirmation: Confirmation::Explicit,
            min_age_days: 30,
            rationale: "archives the package manager still tracks; only re-download is cheap",
        },
        CategoryPolicy {
            category: Category::BrowserCache,
            confirmation: Confirmation::Routine,
            min_age_days: 0,
            rationale: "regenerated on next page load; a running browser's files are locked",
        },
        CategoryPolicy {
            category: Category::SiteStorage,
            confirmation: Confirmation::Explicit,
            min_age_days: 0,
            rationale: "offline site data (Service Worker/CacheStorage) — a smart clean never touches it",
        },
        CategoryPolicy {
            category: Category::AppOrphan,
            confirmation: Confirmation::Explicit,
            min_age_days: 0,
            rationale: "uninstall residue detected heuristically — review every entry",
        },
        CategoryPolicy {
            category: Category::AiModels,
            confirmation: Confirmation::Manual,
            min_age_days: 0,
            rationale: "model weights are re-downloaded, not regenerated — you decide",
        },
        CategoryPolicy {
            category: Category::RecycleBin,
            confirmation: Confirmation::Never,
            min_age_days: 0,
            rationale: "emptying the bin is permanent; the OS owns that operation",
        },
    ],
    supports_os_trash: true,
    needs_elevation,
};

/// Directories owned by root. Cleaning under any of them needs `sudo`; a
/// user's `~/.cache` never does.
const ELEVATED_PREFIXES: &[&str] = &[
    "/var",
    "/usr",
    "/etc",
    "/opt",
    "/boot",
    "/root",
    "/snap",
];

/// Whether acting on `path` needs a root process on Linux.
pub fn needs_elevation(path: &Path) -> bool {
    ELEVATED_PREFIXES
        .iter()
        .any(|prefix| path.starts_with(Path::new(prefix)))
}

/// The package-manager lock file currently held on this machine, if any.
///
/// `Some` means `apt`/`dpkg`/`dnf`/`rpm` is running right now, and the
/// package cache must be left alone until it is gone. Callers that are about
/// to execute a plan containing [`Category::PackageCache`] should check this
/// immediately beforehand, not when the plan was built — a package operation
/// can start in between.
pub fn package_manager_lock() -> Option<PathBuf> {
    PACKAGE_MANAGER_LOCKS
        .iter()
        .map(PathBuf::from)
        .find(|lock| lock.exists())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_profile_row_is_about_linux() {
        assert_eq!(PROFILE.id, PlatformId::Linux);
        assert!(PROFILE.supports_os_trash);
        assert!(PROFILE.policies.iter().all(|p| p.rationale.len() > 10));
    }

    /// `~/.cache` is the whole point of "non-root safe" — it must never be
    /// treated as a system path.
    #[test]
    fn the_user_cache_never_needs_sudo() {
        assert!(!needs_elevation(Path::new("/home/jfong/.cache/pip/http")));
        assert!(!needs_elevation(Path::new("/rootless")));
    }

    #[test]
    fn system_caches_need_sudo() {
        assert!(needs_elevation(Path::new("/var/cache/apt/archives/pkg.deb")));
        assert!(needs_elevation(Path::new("/var/cache/dnf/x86_64/repodata")));
        assert!(needs_elevation(Path::new("/usr/lib/things")));
        // Component boundaries: /varball is not /var.
        assert!(!needs_elevation(Path::new("/varball/x")));
    }

    /// The package cache is the one category that must be asked for by name,
    /// and it is never young enough to be worth it.
    #[test]
    fn package_cache_is_explicit_with_a_long_floor() {
        let policy = PROFILE.policy(Category::PackageCache).expect("policy");
        assert_eq!(policy.confirmation, Confirmation::Explicit);
        assert!(!policy.confirmation.is_auto_selectable());
        assert_eq!(policy.min_age_days, 30);
        assert!(!policy.age_clears_floor(29));
        assert!(policy.age_clears_floor(30));
    }

    /// A user cache is routine, but a week-old floor keeps a running build's
    /// cache out of a one-click clean.
    #[test]
    fn user_cache_is_routine_with_a_week_floor() {
        let policy = PROFILE.policy(Category::Cache).expect("policy");
        assert_eq!(policy.confirmation, Confirmation::Routine);
        assert_eq!(policy.min_age_days, 7);
        assert!(!policy.age_clears_floor(6));
        assert!(policy.age_clears_floor(8));
    }

    /// The lock probe is a plain existence check over a fixed list: on a
    /// machine with no package manager in flight it must report `None` and
    /// must not fail.
    #[test]
    fn lock_probe_reports_no_lock_when_none_is_held() {
        match package_manager_lock() {
            None => {}
            Some(lock) => {
                // If a package operation really is running, the reported path
                // must be one we asked about and must exist.
                assert!(
                    PACKAGE_MANAGER_LOCKS
                        .iter()
                        .any(|known| Path::new(known) == lock),
                    "unexpected lock path: {lock:?}"
                );
                assert!(lock.exists());
            }
        }
    }
}
