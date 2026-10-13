//! Android executor: scoped storage + MediaStore, user-granted trees only.
//!
//! Android has no roots the scanner may simply declare. Under scoped storage
//! the app can see its own private directory and nothing else; every other
//! tree arrives as a **grant** the user picked through the Storage Access
//! Framework. So the executor's job here is to take a grant the app layer
//! obtained, check that it is a real directory the user could plausibly have
//! meant, and hand back a scan root — [`sanction_grants`] does exactly that,
//! and [`crate::scanner::platform_roots`] returns nothing at all on this
//! platform.
//!
//! The reverse direction is the app layer's job, and it is worth being
//! explicit about why. Deleting shared media on Android 11+ goes through
//! `MediaStore.createTrashRequest()` / `createDeleteRequest()`, which puts a
//! system consent sheet in front of the user; the core cannot perform it, and
//! `PROFILE::supports_os_trash` is `false` so no caller can assume otherwise.
//! The core computes and freezes the plan; the Flutter layer drives the
//! consent flow.
//!
//! For the stricter posture used on GrapheneOS and CalyxOS, see
//! [`crate::platform::hardened_android`].

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use super::{CategoryPolicy, Confirmation, PlatformId, PlatformProfile};
use crate::scanner::{Category, ScanRoot};
use crate::safety::protected;

/// The stock Android executor profile.
///
/// Nothing here is [`Confirmation::Routine`]. On a device where a deletion
/// has no trash to fall back on and a mis-tap is unrecoverable, "one click"
/// is not a safety property — every category is a deliberate act.
pub const PROFILE: PlatformProfile = PlatformProfile {
    id: PlatformId::Android,
    display_name: "Android",
    policies: &[
        CategoryPolicy {
            category: Category::Temp,
            confirmation: Confirmation::Explicit,
            min_age_days: 0,
            rationale: "inside a user-granted tree; nothing is selected for you",
        },
        CategoryPolicy {
            category: Category::Cache,
            confirmation: Confirmation::Explicit,
            min_age_days: 0,
            rationale: "inside a user-granted tree; nothing is selected for you",
        },
        CategoryPolicy {
            category: Category::Logs,
            confirmation: Confirmation::Explicit,
            min_age_days: 0,
            rationale: "inside a user-granted tree; nothing is selected for you",
        },
        CategoryPolicy {
            category: Category::BrowserCache,
            confirmation: Confirmation::Explicit,
            min_age_days: 0,
            rationale: "WebView caches rebuild slowly on a metered connection",
        },
        CategoryPolicy {
            category: Category::SiteStorage,
            confirmation: Confirmation::Explicit,
            min_age_days: 0,
            rationale: "WebView offline state — select it by name; nothing is preselected",
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
            rationale: "Android has no app-visible trash; the OS owns deletion",
        },
    ],
    supports_os_trash: false,
    needs_elevation,
};

/// Android never elevates: an app is one uid, and it cannot become another.
pub fn needs_elevation(_path: &Path) -> bool {
    false
}

/// A directory the user handed the app through the Storage Access Framework.
///
/// This is the *only* way a tree enters the scanner on Android. The core
/// cannot verify that a real consent sheet was shown — that is the app
/// layer's contract — so the grant carries only what the core needs to be
/// safe: where it points, what it is for, and when it was obtained.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UserGrant {
    /// Filesystem path of the granted tree (the app layer resolves the
    /// document-tree URI before handing it over).
    pub path: PathBuf,
    /// The category the app layer declared for this tree.
    pub category: Category,
    /// When the user granted it (Unix seconds), for the audit log.
    pub granted_at_unix: u64,
}

impl UserGrant {
    /// A grant obtained at `granted_at_unix`.
    pub fn new(path: impl Into<PathBuf>, category: Category, granted_at_unix: u64) -> Self {
        UserGrant {
            path: path.into(),
            category,
            granted_at_unix,
        }
    }
}

/// Why a grant could not be sanctioned.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum GrantError {
    /// The path is relative. A grant is always an absolute tree.
    #[error("grant path is not absolute: {0}")]
    NotAbsolute(PathBuf),
    /// The path does not exist (the user unmounted the card, or the tree is
    /// stale). Nothing to scan.
    #[error("granted tree no longer exists: {0}")]
    NotFound(PathBuf),
    /// The path exists but is a file, not a directory.
    #[error("granted path is not a directory: {0}")]
    NotADirectory(PathBuf),
    /// The path is a symlink. A document tree is a real directory; a link
    /// could resolve anywhere, including a tree the user never granted.
    #[error("granted path is a symlink, not a tree: {0}")]
    SymlinkGrant(PathBuf),
    /// The path is a filesystem root. A grant for `/` is never a real user
    /// selection and would swallow the whole device.
    #[error("grant resolves to a filesystem root: {0}")]
    FilesystemRoot(PathBuf),
}

/// Turns user-granted trees into scan roots.
///
/// Every grant is checked before *any* root is returned — a batch is either
/// fully sanctioned or refused as a whole, so a caller can never end up
/// scanning half of a selection it does not understand. Sanctioned paths are
/// de-duplicated, registered as protected-path carve-outs (the same contract
/// [`crate::scanner::platform_roots`] follows), and returned sorted.
pub fn sanction_grants(grants: &[UserGrant]) -> Result<Vec<ScanRoot>, GrantError> {
    let mut roots: Vec<ScanRoot> = Vec::new();

    for grant in grants {
        let path = &grant.path;

        if !path.is_absolute() {
            return Err(GrantError::NotAbsolute(path.clone()));
        }
        // `symlink_metadata` deliberately does not follow the link: the check
        // has to see the link itself, not whatever it points at.
        let metadata = std::fs::symlink_metadata(path)
            .map_err(|_| GrantError::NotFound(path.clone()))?;
        if metadata.file_type().is_symlink() {
            return Err(GrantError::SymlinkGrant(path.clone()));
        }
        if !metadata.is_dir() {
            return Err(GrantError::NotADirectory(path.clone()));
        }
        if path.components().count() <= 1 {
            return Err(GrantError::FilesystemRoot(path.clone()));
        }

        roots.push(ScanRoot {
            path: path.clone(),
            category: grant.category,
        });
    }

    roots.sort_by(|a, b| a.path.cmp(&b.path));
    roots.dedup_by(|a, b| a.path == b.path);

    if !roots.is_empty() {
        let carve_outs: Vec<PathBuf> = roots.iter().map(|r| r.path.clone()).collect();
        protected::register_carveouts(&carve_outs);
    }
    Ok(roots)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "freebuff-platform-test-{}-android-{name}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create fixture dir");
        dir
    }

    #[test]
    fn every_profile_row_is_about_android() {
        assert_eq!(PROFILE.id, PlatformId::Android);
        assert!(!PROFILE.supports_os_trash);
        assert!(PROFILE.policies.iter().all(|p| p.rationale.len() > 10));
    }

    /// No one-click clean on Android: nothing may be auto-selected, because a
    /// deletion here has no trash to fall back on.
    #[test]
    fn nothing_on_android_is_auto_selectable() {
        assert!(
            PROFILE
                .policies
                .iter()
                .all(|p| !p.confirmation.is_auto_selectable()),
            "a routine row would mean a one-click delete with no undo"
        );
    }

    #[test]
    fn a_real_directory_grant_is_sanctioned() {
        let dir = fixture_dir("ok");
        let grant = UserGrant::new(&dir, Category::Cache, 1_800_000_000);
        let roots = sanction_grants(std::slice::from_ref(&grant)).expect("sanctioned");

        assert_eq!(roots.len(), 1, "{roots:?}");
        assert_eq!(roots[0].path, dir);
        assert_eq!(roots[0].category, Category::Cache);

        // A sanctioned tree is carved out, so the scanner can actually enter
        // it — otherwise the grant would be refused by the matrix.
        let verdict = protected::validate_path(dir.join("file.tmp"));
        assert!(verdict.allowed, "{verdict:?}");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Duplicate grants for the same tree collapse to one root, so a granted
    /// folder is never scanned twice.
    #[test]
    fn duplicate_grants_collapse() {
        let dir = fixture_dir("dupe");
        let grants = vec![
            UserGrant::new(&dir, Category::Cache, 1),
            UserGrant::new(&dir, Category::Cache, 2),
        ];
        let roots = sanction_grants(&grants).expect("sanctioned");
        assert_eq!(roots.len(), 1, "{roots:?}");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A relative path is not a grant: grants come from the OS as absolute
    /// trees, and a relative one would resolve against whatever the app's
    /// working directory happens to be.
    #[test]
    fn relative_grants_are_refused() {
        let err = sanction_grants(&[UserGrant::new("relative/dir", Category::Cache, 1)])
            .expect_err("must be refused");
        assert!(matches!(err, GrantError::NotAbsolute(_)), "{err:?}");
    }

    /// A tree that has gone away (unmounted card, revoked grant) is not an
    /// error to shrug off — it must be reported, not silently skipped.
    #[test]
    fn a_missing_tree_is_reported() {
        let missing = std::env::temp_dir().join("freebuff-platform-test-grant-does-not-exist");
        let err = sanction_grants(&[UserGrant::new(&missing, Category::Cache, 1)])
            .expect_err("must be refused");
        assert!(matches!(err, GrantError::NotFound(_)), "{err:?}");
    }

    #[test]
    fn a_file_is_not_a_tree() {
        let dir = fixture_dir("file");
        let file = dir.join("not-a-dir.txt");
        std::fs::write(&file, b"x").expect("write");
        let err = sanction_grants(&[UserGrant::new(&file, Category::Cache, 1)])
            .expect_err("must be refused");
        assert!(matches!(err, GrantError::NotADirectory(_)), "{err:?}");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// One bad grant refuses the whole batch: a caller can never end up
    /// scanning part of a selection it does not understand.
    #[test]
    fn one_bad_grant_refuses_the_batch() {
        let dir = fixture_dir("batch");
        let grants = vec![
            UserGrant::new(&dir, Category::Cache, 1),
            UserGrant::new(dir.join("nope"), Category::Cache, 1),
        ];
        assert!(sanction_grants(&grants).is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A symlinked "grant" could point anywhere, including a tree the user
    /// never picked. On Unix the check can actually see the link.
    #[cfg(unix)]
    #[test]
    fn a_symlinked_grant_is_refused() {
        let real = fixture_dir("symlink-target");
        let link = std::env::temp_dir().join(format!(
            "freebuff-platform-test-{}-android-link",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&link);
        std::os::unix::fs::symlink(&real, &link).expect("create symlink");

        let err = sanction_grants(&[UserGrant::new(&link, Category::Cache, 1)])
            .expect_err("must be refused");
        assert!(matches!(err, GrantError::SymlinkGrant(_)), "{err:?}");

        let _ = std::fs::remove_dir_all(&link);
        let _ = std::fs::remove_dir_all(&real);
    }
}
