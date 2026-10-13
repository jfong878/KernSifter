//! Hardened Android executor (GrapheneOS / CalyxOS): SAF-only, no exceptions.
//!
//! Stock Android already forbids the app from touching anything it was not
//! granted. Hardened Android removes what was left: no
//! `MANAGE_EXTERNAL_STORAGE`, no legacy storage opt-in, no other apps'
//! private data, no work-profile crossover, and no way for a user-facing
//! affordance to quietly widen the blast radius. The executor reflects that
//! posture in three ways.
//!
//! 1. **Every grant is authorized against a deny list before it is
//!    sanctioned.** [`authorize`] runs *first* — before the existence and
//!    absoluteness checks — so a denied path is refused however it was spelled,
//!    and a path that merely looks system-ish cannot slip past by being
//!    relative.
//! 2. **Nothing is [`Confirmation::Routine`].** On a device where a deletion
//!    has no trash behind it and no second chance, "one click" is not a
//!    safety property.
//! 3. **Nothing elevates.** An app is one uid; there is no `root` to become.
//!
//! The app layer selects this profile at runtime (a hardened device is not a
//! compile-time property) by calling [`plan`] instead of
//! [`crate::platform::plan`], and [`sanctioned_roots`] instead of
//! [`crate::platform::android::sanction_grants`].

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use super::android::{GrantError, UserGrant};
use super::{
    CategoryPolicy, CleanupPlan, Confirmation, PlanOptions, PlatformId, PlatformProfile, plan_for,
};
use crate::scanner::{Category, ScanReport, ScanRoot};

/// The hardened-Android executor profile.
///
/// Every row is at least [`Confirmation::Explicit`].
pub const PROFILE: PlatformProfile = PlatformProfile {
    id: PlatformId::HardenedAndroid,
    display_name: "Hardened Android",
    policies: &[
        CategoryPolicy {
            category: Category::Temp,
            confirmation: Confirmation::Explicit,
            min_age_days: 0,
            rationale: "SAF tree; deleted through a system consent sheet, so nothing is preselected",
        },
        CategoryPolicy {
            category: Category::Cache,
            confirmation: Confirmation::Explicit,
            min_age_days: 0,
            rationale: "SAF tree; deleted through a system consent sheet, so nothing is preselected",
        },
        CategoryPolicy {
            category: Category::Logs,
            confirmation: Confirmation::Explicit,
            min_age_days: 0,
            rationale: "SAF tree; deleted through a system consent sheet, so nothing is preselected",
        },
        CategoryPolicy {
            category: Category::BrowserCache,
            confirmation: Confirmation::Explicit,
            min_age_days: 0,
            rationale: "WebView state is expensive to rebuild on a metered connection",
        },
        CategoryPolicy {
            category: Category::SiteStorage,
            confirmation: Confirmation::Explicit,
            min_age_days: 0,
            rationale: "WebView offline state; SAF tree — select it by name, nothing is preselected",
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

/// Hardened Android never elevates, for any path.
pub fn needs_elevation(_path: &Path) -> bool {
    false
}

/// Trees that are off limits on a hardened device even if a grant points at
/// them. Two different failures, two different messages.
const SYSTEM_PREFIXES: &[&str] = &["/system", "/vendor", "/apex", "/factory", "/odm"];

/// Another app's private data, other users' storage, and the work profile.
/// A grant cannot reach any of these on stock Android either — listing them
/// makes the refusal explicit instead of incidental.
const FOREIGN_DATA_PREFIXES: &[&str] = &[
    "/data",
    "/mnt/user/10",
    "/mnt/user/11",
    "/storage/emulated/10",
    "/storage/emulated/11",
    "/sdcard/Android/data",
    "/sdcard/Android/obb",
];

/// Why a grant was refused on a hardened device.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum HardenedDenial {
    /// The path is part of the read-only system image.
    #[error("refused: {path} is on the read-only system image")]
    SystemPath {
        /// The offending path.
        path: PathBuf,
    },
    /// The path is another app's data, another user's storage, or a work
    /// profile.
    #[error("refused: {path} is outside the user's own storage")]
    ForeignData {
        /// The offending path.
        path: PathBuf,
    },
    /// The path is a symlink, so it could resolve to either of the above.
    #[error("refused: {path} is a symlink, not a granted tree")]
    Symlink {
        /// The offending path.
        path: PathBuf,
    },
    /// The path is not a directory.
    #[error("refused: {path} is not a directory")]
    NotADirectory {
        /// The offending path.
        path: PathBuf,
    },
    /// The path does not exist.
    #[error("refused: {path} does not exist")]
    NotFound {
        /// The offending path.
        path: PathBuf,
    },
    /// The path is a filesystem root.
    #[error("refused: {path} is a filesystem root")]
    FilesystemRoot {
        /// The offending path.
        path: PathBuf,
    },
    /// The path is relative. A grant from the Storage Access Framework is
    /// always an absolute tree; a relative one would resolve against
    /// whatever the app's working directory happens to be.
    #[error("refused: {path} is not an absolute path")]
    NotAbsolute {
        /// The offending path.
        path: PathBuf,
    },
    /// A stock-Android grant check failed (see [`GrantError`]).
    #[error("refused: {0}")]
    Grant(#[from] GrantError),
}

/// A grant that has cleared every hardened check and may be scanned.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthorizedGrant {
    /// The granted tree.
    pub path: PathBuf,
    /// The category the app layer declared.
    pub category: Category,
    /// When the user granted it (Unix seconds).
    pub granted_at_unix: u64,
}

/// The refusal a path earns purely for where it points, if any.
///
/// The comparison runs against a **root-anchored** view of the path.
/// `Path::starts_with` is lexical and component-exact, so it never matches a
/// relative spelling (`data/data/com.other.app`) against an absolute prefix
/// (`/data`) — the first components are `Normal` and `RootDir` and simply are
/// not equal. On a device whose working directory is `/`, that relative
/// spelling *lands* in foreign data, so it is anchored to the root before the
/// prefixes are tested. The denial still reports the path exactly as it was
/// granted, because that is what the user has to recognise in the log.
fn denial_for_path(path: &Path) -> Option<HardenedDenial> {
    let anchored: PathBuf = if path.is_absolute() {
        path.to_path_buf()
    } else {
        Path::new("/").join(path)
    };

    if SYSTEM_PREFIXES
        .iter()
        .any(|prefix| anchored.starts_with(Path::new(prefix)))
    {
        return Some(HardenedDenial::SystemPath {
            path: path.to_path_buf(),
        });
    }
    if FOREIGN_DATA_PREFIXES
        .iter()
        .any(|prefix| anchored.starts_with(Path::new(prefix)))
    {
        return Some(HardenedDenial::ForeignData {
            path: path.to_path_buf(),
        });
    }
    None
}

/// Checks one grant against the hardened rules.
///
/// The deny list is consulted **first**, before the path is even required to
/// be absolute: a path inside `/system` is refused whether it was spelled
/// `/system/app`, `/system/../system/app`, or a relative path that would
/// resolve there. Only then does the grant have to be a real, existing,
/// absolute directory.
pub fn authorize(grant: &UserGrant) -> Result<AuthorizedGrant, HardenedDenial> {
    if let Some(denial) = denial_for_path(&grant.path) {
        return Err(denial);
    }
    if !grant.path.is_absolute() {
        return Err(HardenedDenial::NotAbsolute {
            path: grant.path.clone(),
        });
    }
    let metadata =
        std::fs::symlink_metadata(&grant.path).map_err(|_| HardenedDenial::NotFound {
            path: grant.path.clone(),
        })?;
    if metadata.file_type().is_symlink() {
        return Err(HardenedDenial::Symlink {
            path: grant.path.clone(),
        });
    }
    if !metadata.is_dir() {
        return Err(HardenedDenial::NotADirectory {
            path: grant.path.clone(),
        });
    }
    if grant.path.components().count() <= 1 {
        return Err(HardenedDenial::FilesystemRoot {
            path: grant.path.clone(),
        });
    }

    Ok(AuthorizedGrant {
        path: grant.path.clone(),
        category: grant.category,
        granted_at_unix: grant.granted_at_unix,
    })
}

/// Authorizes every grant, then sanctions the survivors as scan roots.
///
/// All-or-nothing, like [`crate::platform::android::sanction_grants`]: the
/// hardened app layer gets a tree it fully understands, or an error naming the
/// grant that broke the rules.
pub fn sanctioned_roots(grants: &[UserGrant]) -> Result<Vec<ScanRoot>, HardenedDenial> {
    let authorized: Vec<AuthorizedGrant> = grants
        .iter()
        .map(authorize)
        .collect::<Result<Vec<_>, _>>()?;

    let reparsed: Vec<UserGrant> = authorized
        .into_iter()
        .map(|g| UserGrant::new(g.path, g.category, g.granted_at_unix))
        .collect();

    Ok(crate::platform::android::sanction_grants(&reparsed)?)
}

/// Computes a cleanup plan under the hardened profile.
///
/// The app layer calls this instead of [`crate::platform::plan`] when it
/// detects a hardened device; the plan is otherwise identical, and still has
/// to be driven through a system consent sheet to actually delete anything.
pub fn plan(report: &ScanReport, options: &PlanOptions) -> CleanupPlan {
    plan_for(&PROFILE, report, options)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scanner::{EntryKind, RootScan, ScanEntry};
    use crate::safety::protected::ProtectionVerdict;

    fn fixture_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "freebuff-platform-test-{}-hardened-{name}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create fixture dir");
        dir
    }

    #[test]
    fn every_profile_row_is_about_hardened_android() {
        assert_eq!(PROFILE.id, PlatformId::HardenedAndroid);
        assert!(!PROFILE.supports_os_trash);
        assert!(PROFILE.policies.iter().all(|p| p.rationale.len() > 10));
    }

    /// The central hardened invariant: there is no one-click clean.
    #[test]
    fn nothing_on_hardened_android_is_auto_selectable() {
        assert!(
            PROFILE
                .policies
                .iter()
                .all(|p| !p.confirmation.is_auto_selectable()),
            "a routine row would mean a one-click delete with no undo"
        );
    }

    /// A plain user directory inside the user's own storage is exactly what a
    /// SAF grant looks like, and it must be authorized.
    #[test]
    fn an_ordinary_user_tree_is_authorized() {
        let dir = fixture_dir("ok");
        let grant = UserGrant::new(&dir, Category::Cache, 1_800_000_000);
        let authorized = authorize(&grant).expect("authorized");

        assert_eq!(authorized.path, dir);
        assert_eq!(authorized.category, Category::Cache);
        assert_eq!(authorized.granted_at_unix, 1_800_000_000);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The system image is refused — and refused on the path alone, before
    /// anything is stat'ed, so a stale or unreachable path cannot change the
    /// answer.
    #[test]
    fn the_system_image_is_refused() {
        for path in ["/system/app", "/system", "/vendor/bin", "/apex/com.android.runtime"] {
            let grant = UserGrant::new(path, Category::Cache, 1);
            let err = authorize(&grant).expect_err("must be refused");
            assert!(
                matches!(err, HardenedDenial::SystemPath { .. }),
                "{path}: {err:?}"
            );
        }
    }

    /// Another app's private data, another user's storage, and the work
    /// profile are all outside the user's own storage.
    #[test]
    fn foreign_data_is_refused() {
        for path in [
            "/data/data/com.other.app",
            "/storage/emulated/10/Android/data/com.other.app",
            "/storage/emulated/11/Android/obb",
            "/mnt/user/10/Documents",
            "/sdcard/Android/data",
        ] {
            let grant = UserGrant::new(path, Category::Cache, 1);
            let err = authorize(&grant).expect_err("must be refused");
            assert!(
                matches!(err, HardenedDenial::ForeignData { .. }),
                "{path}: {err:?}"
            );
        }
    }

    /// The deny list runs before the absoluteness check, so a relative path
    /// that would resolve into `/data` is refused for the reason that matters.
    #[test]
    fn the_deny_list_outranks_the_path_syntax_checks() {
        let relative = UserGrant::new("data/data/com.other.app", Category::Cache, 1);
        let err = authorize(&relative).expect_err("must be refused");
        assert!(
            matches!(err, HardenedDenial::ForeignData { .. }),
            "{err:?}"
        );
    }

    /// One bad grant refuses the batch.
    #[test]
    fn one_denied_grant_refuses_the_batch() {
        let dir = fixture_dir("batch");
        let grants = vec![
            UserGrant::new(&dir, Category::Cache, 1),
            UserGrant::new("/system/app", Category::Cache, 1),
        ];
        assert!(sanctioned_roots(&grants).is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// An authorized tree reaches the scanner, carve-out included.
    #[test]
    fn an_authorized_tree_is_sanctioned_as_a_root() {
        let dir = fixture_dir("roots");
        let grants = vec![UserGrant::new(&dir, Category::Cache, 1)];
        let roots = sanctioned_roots(&grants).expect("sanctioned");

        assert_eq!(roots.len(), 1, "{roots:?}");
        assert_eq!(roots[0].path, dir);
        assert!(crate::safety::protected::validate_path(dir.join("a.tmp")).allowed);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A plan computed under the hardened profile is the normal plan, minus
    /// the one-click categories.
    #[test]
    fn hardened_planing_still_works_on_a_report() {
        let dir = fixture_dir("plan");
        let file = dir.join("cache.bin");
        std::fs::write(&file, b"x").expect("write");

        let entry = ScanEntry {
            path: file.clone(),
            category: Category::Cache,
            kind: EntryKind::File,
            file_type: Some("bin".to_string()),
            size_bytes: 1,
            modified_unix: Some(1_800_000_000 - 30 * 86_400),
            verdict: ProtectionVerdict {
                allowed: true,
                reason: None,
                rule: None,
            },
        };
        let report = ScanReport {
            scanned_at_unix: 1_800_000_000,
            roots: vec![RootScan {
                root: ScanRoot {
                    path: dir.clone(),
                    category: Category::Cache,
                },
                entries: vec![entry],
                errors: Vec::new(),
            }],
        };

        // A smart clean selects nothing here — that is the point.
        let smart = plan(&report, &PlanOptions::smart_clean(1_800_000_000));
        assert_eq!(smart.platform, PlatformId::HardenedAndroid);
        assert!(smart.eligible.is_empty(), "{smart:?}");
        assert_eq!(
            smart.skipped[0].reason,
            crate::platform::SkipReason::RequiresExplicitSelection
        );

        // An explicit selection does, and it needs no elevation.
        let selected = plan(
            &report,
            &PlanOptions::selecting(1_800_000_000, vec![Category::Cache]),
        );
        assert_eq!(selected.eligible_count(), 1, "{selected:?}");
        assert!(!selected.needs_elevation);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A symlinked "grant" is refused on a hardened device even when it
    /// points somewhere perfectly ordinary — the link could resolve anywhere,
    /// and a link is not what the Storage Access Framework hands out.
    #[cfg(unix)]
    #[test]
    fn a_symlinked_grant_is_refused() {
        let real = fixture_dir("symlink-target");
        let link = std::env::temp_dir().join(format!(
            "freebuff-platform-test-{}-hardened-link",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&link);
        std::os::unix::fs::symlink(&real, &link).expect("create symlink");

        let err = authorize(&UserGrant::new(&link, Category::Cache, 1)).expect_err("refused");
        assert!(matches!(err, HardenedDenial::Symlink { .. }), "{err:?}");

        let _ = std::fs::remove_dir_all(&link);
        let _ = std::fs::remove_dir_all(&real);
    }
}
