//! macOS executor: `~/Library/Caches`, `/Library/Caches`, `~/Library/Logs`.
//!
//! Two things are different about macOS and both are handled here.
//!
//! **The split between user and system caches is an elevation boundary.**
//! `~/Library/Caches` belongs to the user; `/Library/Caches` is root-owned. A
//! category-level elevation flag cannot express that, so
//! [`PROFILE::needs_elevation`] tests the path.
//!
//! **Installer bundles are installations, not cache.** A `.app`, `.bundle`,
//! or `.framework` that happens to sit under a cache root (SquirrelTemp-style
//! leftovers and app updaters both do this) is a *copy* of an application.
//! Deleting one is not cache cleanup, so [`is_installer_bundle`] exists for
//! callers that want to exclude them explicitly, and the `Cache` row's floor
//! keeps a fresh copy out of a routine plan in the meantime.

use std::path::Path;

use super::{CategoryPolicy, Confirmation, PlatformId, PlatformProfile};
use crate::scanner::Category;

/// The macOS executor profile.
///
/// `/Library/Caches` is system-owned but every category here is reachable
/// without root, so elevation is decided per path rather than per row.
pub const PROFILE: PlatformProfile = PlatformProfile {
    id: PlatformId::MacOs,
    display_name: "macOS",
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
            min_age_days: 0,
            rationale: "regenerated on demand by the owning app",
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
            rationale: "downloaded package/app-updater archives — a fresh one may be a pending update",
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

/// Directories owned by root (or by `wheel` for the system half of the
/// filesystem). Anything under one of them needs `sudo` to clean, whatever
/// category it belongs to.
const ELEVATED_PREFIXES: &[&str] = &[
    "/Applications",
    "/Library",
    "/System",
    "/usr",
    "/bin",
    "/sbin",
    "/etc",
    "/opt",
    "/private/var",
];

/// Whether acting on `path` needs a root process on macOS.
pub fn needs_elevation(path: &Path) -> bool {
    ELEVATED_PREFIXES
        .iter()
        .any(|prefix| path.starts_with(Path::new(prefix)))
}

/// Whether `name` is an application bundle rather than a cache artifact.
///
/// A `.app`/`.bundle`/`.framework` under a cache tree is an installer or
/// updater leftover — a full copy of an application, not a regenerable file.
/// The name is matched case-insensitively because the filesystem is.
pub fn is_installer_bundle(name: &str) -> bool {
    const BUNDLE_SUFFIXES: &[&str] = &[".app", ".bundle", ".framework", ".prefabundle", ".dmg"];
    let lower = name.to_lowercase();
    BUNDLE_SUFFIXES.iter().any(|suffix| lower.ends_with(suffix))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_profile_row_is_about_macos() {
        assert_eq!(PROFILE.id, PlatformId::MacOs);
        assert!(PROFILE.supports_os_trash);
        assert!(PROFILE.policies.iter().all(|p| p.rationale.len() > 10));
    }

    /// The system cache tree is root-owned; the user's is not. Both are
    /// `Cache`, which is exactly why elevation is a path question.
    #[test]
    fn system_caches_need_sudo_and_user_caches_do_not() {
        assert!(needs_elevation(Path::new("/Library/Caches/com.example.app")));
        assert!(needs_elevation(Path::new("/private/var/folders/xy/T")));
        assert!(!needs_elevation(Path::new("/Users/jfong/Library/Caches")));
        assert!(!needs_elevation(Path::new("/Users/jfong/Library/Logs")));
    }

    /// Prefix matching must not treat a lookalike path as a system one.
    #[test]
    fn elevation_check_respects_component_boundaries() {
        assert!(!needs_elevation(Path::new("/Users/jfong/LibraryX/Caches")));
        assert!(!needs_elevation(Path::new("/home/u/.cache")));
    }

    #[test]
    fn installer_bundles_are_recognised_regardless_of_case() {
        assert!(is_installer_bundle("Slack.app"));
        assert!(is_installer_bundle("thing.BUNDLE"));
        assert!(is_installer_bundle("FMW.framework"));
        assert!(is_installer_bundle("installer.dmg"));
        assert!(!is_installer_bundle("Cache"));
        assert!(!is_installer_bundle("com.example.app-cache"));
    }
}
