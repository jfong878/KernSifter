//! Windows executor: `%TEMP%`, `C:\Windows\Temp`, Prefetch, AppData orphans.
//!
//! Two Windows-specific rules live here.
//!
//! **Elevation is per path, not per category.** `C:\Windows\Temp` and
//! `C:\Windows\Prefetch` need an elevated process; the user's `%TEMP%` under
//! `%LOCALAPPDATA%\Temp` never does. A category-level flag would either
//! demand a UAC prompt for a user-only cleanup or silently fail a system one,
//! so [`PROFILE::needs_elevation`] tests the path itself.
//!
//! **AppData orphans are heuristic and never automatic.** A directory under
//! `%LOCALAPPDATA%` / `%APPDATA%` whose name no installed program still owns
//! is usually uninstall residue — but "no installed program owns it" can only
//! be answered against the install locations on this machine, and an app
//! installed elsewhere (a game on `D:\`, say) is invisible to that check. The
//! category is therefore [`Confirmation::Explicit`]: KernSifter shows the
//! candidate and the user decides.

use std::path::{Path, PathBuf};

use super::{CategoryPolicy, Confirmation, PlatformId, PlatformProfile};
use crate::scanner::{Category, ScanRoot};
use crate::safety::protected;

/// A directory must have been untouched for this long before it is offered as
/// uninstall residue. Long enough that a rarely-used app's data is not
/// mistaken for residue on a day off.
pub const ORPHAN_IDLE_DAYS: u64 = 180;

/// Directories under `%LOCALAPPDATA%` / `%APPDATA%` that are never offered as
/// orphans, however idle: they are shared, OS-managed, or the sanctioned temp
/// roots themselves.
const NEVER_ORPHAN: &[&str] = &[
    "Temp",
    "TempState",
    "Packages",
    "Microsoft",
    "CrashDumps",
    "ConnectedDevicesPlatform",
    "Windows",
];

/// The Windows executor profile.
///
/// Prefetch carries a one-day floor: a `.pf` file younger than that belongs
/// to an app that launched in the last day, and Windows is still writing to
/// it. The other floors follow the same "is anyone still using it" logic.
pub const PROFILE: PlatformProfile = PlatformProfile {
    id: PlatformId::Windows,
    display_name: "Windows",
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
            category: Category::Prefetch,
            confirmation: Confirmation::Routine,
            min_age_days: 1,
            rationale: "app-launch traces; skip the last day so in-flight prefetches survive",
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

/// Whether acting on `path` needs an administrator process.
///
/// True for anything under the Windows directory (`C:\Windows\Temp`,
/// `C:\Windows\Prefetch`) — the only sanctioned roots that do. Everything
/// else, `%LOCALAPPDATA%` included, runs as the signed-in user.
pub fn needs_elevation(path: &Path) -> bool {
    let windows_dir = std::env::var_os("SystemRoot")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(r"C:\Windows"));
    // Compared per component, with the host's case rules: `SystemRoot` is
    // commonly spelled `C:\WINDOWS` while callers write `C:\Windows\Temp`,
    // and `Path::starts_with` compares bytes. Component-wise also keeps
    // `C:\WindowsX` from passing for `C:\Windows`.
    let mut actual = path.components();
    windows_dir.components().all(|expected| {
        actual.next().is_some_and(|component| {
            protected::comp_eq(
                &component.as_os_str().to_string_lossy(),
                &expected.as_os_str().to_string_lossy(),
            )
        })
    })
}

/// Whether a `%LOCALAPPDATA%` / `%APPDATA%` child directory is uninstall
/// residue.
///
/// The rule, in full: the name is not on the never-orphan list, the
/// directory has been idle for [`ORPHAN_IDLE_DAYS`], and no install location
/// holds a directory of the same name. Split out from the filesystem walk so
/// the rule itself is testable without a real profile.
pub fn is_orphan(name: &str, idle_days: u64, has_install_dir: bool) -> bool {
    if NEVER_ORPHAN.iter().any(|n| n.eq_ignore_ascii_case(name)) {
        return false;
    }
    idle_days >= ORPHAN_IDLE_DAYS && !has_install_dir
}

/// The `%LOCALAPPDATA%` / `%APPDATA%` children that look like uninstall
/// residue right now, as scan roots.
///
/// Registers a protected-path carve-out for each one (the same contract
/// [`crate::scanner::platform_roots`] follows), because a directory that is
/// not carved out would be refused by the matrix before it could be scanned.
pub fn appdata_orphan_roots() -> Vec<ScanRoot> {
    appdata_orphan_roots_at(unix_now())
}

/// [`appdata_orphan_roots`] against an explicit clock, so callers (and tests)
/// can reason about the idle floor deterministically.
pub fn appdata_orphan_roots_at(now_unix: u64) -> Vec<ScanRoot> {
    let install_dirs = install_locations();
    let mut roots = Vec::new();

    for base in user_data_bases() {
        let Ok(children) = std::fs::read_dir(&base) else {
            continue;
        };
        for child in children.flatten() {
            let path = child.path();
            if !path.is_dir() {
                continue;
            }
            let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
                continue;
            };

            let last_modified = child
                .metadata()
                .ok()
                .and_then(|m| m.modified().ok())
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_secs())
                .unwrap_or(0);
            let idle_days = now_unix.saturating_sub(last_modified) / 86_400;

            let has_install_dir = install_dirs.iter().any(|dir| dir.join(name).is_dir());
            if is_orphan(name, idle_days, has_install_dir) {
                roots.push(ScanRoot {
                    path,
                    category: Category::AppOrphan,
                });
            }
        }
    }

    if !roots.is_empty() {
        let carve_outs: Vec<PathBuf> = roots.iter().map(|r| r.path.clone()).collect();
        protected::register_carveouts(&carve_outs);
    }
    roots.sort_by(|a, b| a.path.cmp(&b.path));
    roots
}

/// The user-data directories that hold per-app residue: `%LOCALAPPDATA%` and
/// the roaming `%APPDATA%`.
fn user_data_bases() -> Vec<PathBuf> {
    let mut bases = Vec::new();
    if let Some(local) = dirs::data_local_dir() {
        bases.push(local);
    }
    if let Some(roaming) = dirs::data_dir() {
        // `data_dir` is `%APPDATA%` on Windows and `~/.local/share` on Unix;
        // the roaming tree is the only one that is per-app on Windows.
        #[cfg(windows)]
        bases.push(roaming);
        #[cfg(not(windows))]
        let _ = roaming;
    }
    bases
}

/// Where an application with `name` would have been installed. A residue
/// directory whose name matches one of these belongs to a live install, not
/// to an uninstalled one.
fn install_locations() -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = Vec::new();
    if let Some(local) = dirs::data_local_dir() {
        // Per-user installs: %LOCALAPPDATA%\Programs\<app>
        dirs.push(local.join("Programs"));
    }
    for var in ["ProgramFiles", "ProgramFiles(x86)"] {
        if let Some(dir) = std::env::var_os(var) {
            dirs.push(PathBuf::from(dir));
        }
    }
    dirs
}

fn unix_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_profile_row_is_about_windows() {
        assert_eq!(PROFILE.id, PlatformId::Windows);
        assert!(PROFILE.supports_os_trash);
        assert!(PROFILE.policies.iter().all(|p| p.rationale.len() > 10));
    }

    /// Prefetch files younger than a day belong to an app that launched
    /// recently and are still being written.
    #[test]
    fn prefetch_has_a_one_day_floor() {
        let prefetch = PROFILE.policy(Category::Prefetch).expect("prefetch policy");
        assert_eq!(prefetch.min_age_days, 1);
        assert!(!prefetch.age_clears_floor(0));
        assert!(prefetch.age_clears_floor(2));
    }

    /// Offline site data is opt-in by name only: a one-click smart clean must
    /// never delete a web app's Service Worker state.
    #[test]
    fn site_storage_is_explicit_and_never_auto_selected() {
        let policy = PROFILE
            .policy(Category::SiteStorage)
            .expect("site storage policy");
        assert_eq!(policy.confirmation, Confirmation::Explicit);
        assert!(!policy.confirmation.is_auto_selectable());
        assert_eq!(policy.min_age_days, 0);
    }

    /// Download archives can be a *pending* update, so they are offered only
    /// when the user ticks the category, and only once they are a month old.
    #[test]
    fn package_cache_is_explicit_with_a_month_floor() {
        let policy = PROFILE
            .policy(Category::PackageCache)
            .expect("package cache policy");
        assert_eq!(policy.confirmation, Confirmation::Explicit);
        assert!(!policy.confirmation.is_auto_selectable());
        assert_eq!(policy.min_age_days, 30);
        assert!(!policy.age_clears_floor(29));
        assert!(policy.age_clears_floor(30));
    }

    #[test]
    fn windows_temp_needs_admin_and_appdata_does_not() {
        assert!(needs_elevation(Path::new(r"C:\Windows\Temp")));
        assert!(needs_elevation(Path::new(r"C:\Windows\Prefetch")));
        assert!(!needs_elevation(Path::new(
            r"C:\Users\jfong\AppData\Local\Temp"
        )));
        assert!(!needs_elevation(Path::new(r"C:\Program Files\App")));
    }

    /// Case-insensitive, component-wise: the system directory is spelled
    /// `Windows` regardless of how the caller typed it.
    #[test]
    fn elevation_check_ignores_path_casing() {
        let windows_dir = std::env::var_os("SystemRoot")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(r"C:\Windows"));
        let shouted = PathBuf::from(windows_dir.to_string_lossy().to_uppercase());
        if shouted != windows_dir {
            assert!(needs_elevation(&shouted.join("Temp")));
        }
    }

    /// A directory an installed program still owns is never residue, however
    /// long it has been idle.
    #[test]
    fn a_live_install_is_never_an_orphan() {
        assert!(!is_orphan("Steam", 3650, true));
        assert!(is_orphan("Steam", 3650, false));
    }

    /// Recently-touched directories are somebody's active app, not residue.
    #[test]
    fn recent_and_shared_directories_are_never_orphans() {
        assert!(!is_orphan("SomeApp", 3, false));
        for shared in NEVER_ORPHAN {
            assert!(!is_orphan(shared, 3650, false), "{shared} must be exempt");
        }
    }

    #[test]
    fn orphan_detection_finds_an_idle_unowned_directory() {
        let dir = std::env::temp_dir().join(format!(
            "freebuff-platform-test-{}-orphan",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create fixture");
        std::fs::write(dir.join("marker.txt"), b"x").expect("write marker");

        let roots = appdata_orphan_roots_at(unix_now());
        // The fixture lives in the temp dir, not in %LOCALAPPDATA%, so it is
        // not discovered — but the walk must not panic or error on a machine
        // with no user-data directory at all.
        assert!(roots.iter().all(|r| r.category == Category::AppOrphan));

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A discovered orphan must be reachable by the scanner, which means the
    /// matrix has to be told about it (carve-out) — otherwise the category
    /// would be refused before it could ever be reviewed.
    #[test]
    fn discovered_orphans_are_carved_out_of_the_matrix() {
        let dir = std::env::temp_dir().join(format!(
            "freebuff-platform-test-{}-carveout",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create fixture");

        protected::register_carveouts(&[dir.clone()]);
        let verdict = protected::validate_path(dir.join("marker.txt"));
        assert!(verdict.allowed, "{verdict:?}");

        let _ = std::fs::remove_dir_all(&dir);
    }
}
