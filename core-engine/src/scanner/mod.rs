//! # Phase 1 — platform scanners
//!
//! Multi-threaded filesystem scanners built on `walkdir` + `rayon`, driven by
//! per-platform sanctioned roots ([`platform_roots`]). Every candidate emitted
//! by the scanner carries its own protected-path verdict
//! ([`ScanEntry::verdict`]), so the Phase 2 dry-run manifest can show exactly
//! what is cleanable and why.
//!
//! The strict conditional abstraction (Windows / macOS / Linux / Android
//! execution paths) lives one level up from the raw walker: each platform
//! declares its roots here, and the platform executor modules (later phase)
//! map scan results to categories and confirmation flows.

pub mod roots;
pub mod walk;

pub use roots::{Category, ScanRoot, platform_roots};
pub use walk::{EntryKind, RootScan, ScanEntry, ScanReport, scan_root};

use std::time::{SystemTime, UNIX_EPOCH};

use crate::safety::protected::ProtectedMatrix;

/// Scans every root sanctioned for the host platform.
pub fn scan() -> ScanReport {
    scan_roots(&platform_roots())
}

/// Scans the given roots, verifying each one against the protected-path matrix
/// before walking it.
///
/// Roots that don't exist or that the matrix refuses (protection, carve-out
/// mismatch) are reported with an error entry and produce no candidates —
/// the scanner never walks an unsanctioned directory.
pub fn scan_roots(roots: &[ScanRoot]) -> ScanReport {
    let matrix = ProtectedMatrix::current();
    let root_scans: Vec<RootScan> = roots
        .iter()
        .map(|root| {
            if !root.path.is_dir() {
                RootScan {
                    root: root.clone(),
                    entries: Vec::new(),
                    errors: vec![format!("root is not a directory: {}", root.path.display())],
                }
            } else if root.category == Category::RecycleBin {
                // Scan-only root: trash contents are surfaced for visibility,
                // but the matrix denies every entry beneath the bin, so they
                // can never be acted on (deleting from trash is permanent).
                walk::scan_root(root, &matrix)
            } else if !matrix.validate(&root.path).allowed {
                RootScan {
                    root: root.clone(),
                    entries: Vec::new(),
                    errors: vec![
                        format!("root is protected and was not scanned: {}", root.path.display()),
                    ],
                }
            } else {
                walk::scan_root(root, &matrix)
            }
        })
        .collect();

    ScanReport {
        scanned_at_unix: unix_now(),
        roots: root_scans,
    }
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::safety::protected::validate_path;
    use std::collections::BTreeMap;
    use std::fs;
    use std::path::PathBuf;

    /// Creates a uniquely-named scratch directory under the OS temp dir and
    /// removes any stale leftovers from a previous crashed run.
    fn fixture_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "freebuff-scan-test-{}-{name}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("create fixture dir");
        dir
    }

    /// The core invariant: every platform-sanctioned root must itself pass
    /// the protected-path matrix, otherwise `scan()` would refuse to walk it.
    ///
    /// The one exception is `RecycleBin` — a scan-only root that the matrix
    /// deliberately blocks (deleting from the trash is permanent), but which
    /// the scanner still walks to surface what is eating disk space.
    #[test]
    fn platform_roots_are_all_sanctioned_by_the_matrix() {
        let roots = platform_roots();
        assert!(!roots.is_empty(), "platform should declare scan roots");
        assert!(
            roots.iter().any(|r| r.category == Category::RecycleBin),
            "platform should declare a recycle-bin scan root"
        );
        for root in &roots {
            if root.category == Category::RecycleBin {
                // Scan-only: the entries beneath it are denied by the matrix.
                let v = validate_path(&root.path);
                assert!(
                    !v.allowed,
                    "recycle bin root should be blocked from deletion: {}",
                    root.path.display()
                );
                continue;
            }
            let v = validate_path(&root.path);
            assert!(v.allowed, "root {} blocked: {:?}", root.path.display(), v);
        }
    }

    /// A RecycleBin-category root is walked (surfaced for visibility) even
    /// though the matrix refuses its contents — and its entries carry denied
    /// verdicts, so they are never counted as cleanable.
    #[test]
    fn recycle_bin_roots_are_scanned_but_entries_stay_blocked() {
        // A scratch dir under the OS temp is matrix-allowed, so to exercise
        // the scan-only path we point the root at the platform's real trash
        // path (which the matrix denies) and confirm the scan still walks it
        // instead of refusing it as protected.
        let roots = platform_roots();
        let trash_root = roots
            .iter()
            .find(|r| r.category == Category::RecycleBin)
            .expect("platform declares a recycle bin root")
            .clone();

        let report = scan_roots(&[trash_root.clone()]);
        if trash_root.path.is_dir() {
            // The root is walked, never refused as protected. Permission
            // errors are expected on Windows (other users' SID folders under
            // $Recycle.Bin) and are fine — they are walk errors, not "root is
            // protected and was not scanned" refusals.
            for err in &report.roots[0].errors {
                assert!(
                    !err.contains("protected"),
                    "recycle bin root must be walked, not refused: {err}"
                );
            }
            for entry in &report.roots[0].entries {
                assert_eq!(entry.category, Category::RecycleBin);
                assert!(
                    !entry.is_cleanable(),
                    "recycle bin entries must never be cleanable: {:?}",
                    entry.path
                );
            }
        }
        // If the platform has no trash on this machine the root simply does
        // not exist; the scan reports it as missing rather than protected.
    }

    #[test]
    fn scans_a_fixture_with_sizes_and_categories() {
        let dir = fixture_dir("basic");
        fs::write(dir.join("a.txt"), b"0123456789").expect("write a.txt");
        fs::create_dir_all(dir.join("sub")).expect("create sub");
        fs::write(dir.join("sub").join("b.log"), b"hello").expect("write b.log");

        let report = scan_roots(&[ScanRoot {
            path: dir,
            category: Category::Cache,
        }]);

        assert_eq!(report.entry_count(), 2, "{report:?}");
        assert_eq!(report.total_bytes(), 15);
        assert_eq!(report.cleanable_bytes(), 15);

        let root = &report.roots[0];
        let by_name: BTreeMap<&str, &ScanEntry> = root
            .entries
            .iter()
            .map(|e| (e.path.file_name().unwrap().to_str().unwrap(), e))
            .collect();
        assert_eq!(by_name["a.txt"].file_type.as_deref(), Some("txt"));
        assert_eq!(by_name["a.txt"].size_bytes, 10);
        assert_eq!(by_name["b.log"].file_type.as_deref(), Some("log"));
        assert_eq!(by_name["b.log"].size_bytes, 5);
        for entry in root.entries.iter() {
            assert!(entry.is_cleanable(), "{entry:?}");
            assert_eq!(entry.category, Category::Cache);
            assert_eq!(entry.kind, EntryKind::File);
        }

        let by_category = report.bytes_by_category();
        assert_eq!(by_category.get(&Category::Cache), Some(&15));

        // Clean up the fixture itself (not its parent!).
        let _ = fs::remove_dir_all(&report.roots[0].root.path);
    }

    /// Windows Recycle Bin `$I*` metadata files are excluded from the scan,
    /// leaving only the real `$R*` content entries in the manifest.
    #[cfg(windows)]
    #[test]
    fn recycle_bin_scan_skips_metadata_files() {
        let dir = fixture_dir("recycle-meta");
        fs::write(dir.join("$I0001"), b"metadata").expect("write $I");
        fs::write(dir.join("$R0001.pdf"), vec![0u8; 8]).expect("write $R");
        fs::write(dir.join("keep.txt"), b"not trash").expect("write");

        let report = scan_roots(&[ScanRoot {
            path: dir.clone(),
            category: Category::RecycleBin,
        }]);
        let entries = &report.roots[0].entries;
        let names: Vec<String> = entries
            .iter()
            .map(|e| e.path.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, ["$R0001.pdf", "keep.txt"], "{report:?}");

        let _ = fs::remove_dir_all(&dir);
    }

    /// A root the matrix protects must be reported and refused, never walked.
    #[test]
    fn protected_roots_are_reported_but_not_scanned() {
        #[cfg(windows)]
        let protected = PathBuf::from(r"C:\Windows");
        #[cfg(target_os = "macos")]
        let protected = PathBuf::from("/System");
        #[cfg(all(not(windows), not(target_os = "macos")))]
        let protected = PathBuf::from("/etc");

        let report = scan_roots(&[ScanRoot {
            path: protected,
            category: Category::Temp,
        }]);
        assert_eq!(report.entry_count(), 0);
        assert!(!report.roots[0].errors.is_empty(), "{report:?}");
        assert!(
            report.roots[0].errors[0].contains("protected"),
            "{report:?}"
        );
    }

    /// Symlinks are emitted as leaves (never followed), so traversal cannot
    /// escape the root through a link — even one pointing outside it.
    #[cfg(unix)]
    #[test]
    fn symlinks_are_leaves_and_never_followed() {
        let parent = fixture_dir("symlinks");
        let outside = parent.join("outside");
        fs::create_dir_all(&outside).expect("create outside");
        fs::write(outside.join("secret.txt"), b"secret").expect("write secret");

        let scanned = parent.join("scanned");
        fs::create_dir_all(&scanned).expect("create scanned");
        fs::write(scanned.join("keep.txt"), b"keep").expect("write keep");
        std::os::unix::fs::symlink(&outside, scanned.join("link")).expect("create symlink");

        let report = scan_roots(&[ScanRoot {
            path: scanned,
            category: Category::Cache,
        }]);
        let entries = &report.roots[0].entries;
        let mut kinds: Vec<(String, EntryKind)> = entries
            .iter()
            .map(|e| {
                (
                    e.path.file_name().unwrap().to_str().unwrap().to_string(),
                    e.kind,
                )
            })
            .collect();
        kinds.sort();
        assert_eq!(
            kinds,
            vec![
                ("keep.txt".to_string(), EntryKind::File),
                ("link".to_string(), EntryKind::Symlink),
            ],
            "{report:?}"
        );
        // The linked directory's contents must never appear.
        assert!(
            !entries.iter().any(|e| e.path.ends_with("secret.txt")),
            "{report:?}"
        );

        let _ = fs::remove_dir_all(&parent);
    }

    /// Windows directory junctions are *not* symlinks as far as `std` is
    /// concerned, so `follow_links(false)` alone would let the walker descend
    /// into one. Package-manager caches are built exactly that way
    /// (`~/.bun/install/cache` keeps a real package directory *and* a junction
    /// beside it), so a junction must be neither followed nor counted twice.
    #[cfg(windows)]
    #[test]
    fn directory_junctions_are_not_followed_or_double_counted() {
        let root = fixture_dir("junction");
        let real = root.join("real");
        fs::create_dir_all(&real).expect("create real dir");
        fs::write(real.join("payload.bin"), vec![0u8; 64]).expect("write payload");
        fs::write(root.join("top.txt"), b"top").expect("write top");

        let link = root.join("link");
        let status = std::process::Command::new("cmd")
            .args(["/C", "mklink", "/J"])
            .arg(&link)
            .arg(&real)
            .status()
            .expect("run mklink /J");
        assert!(status.success(), "mklink /J must create the junction");

        let report = scan_roots(&[ScanRoot {
            path: root.clone(),
            category: Category::Cache,
        }]);

        // `top.txt` and `real/payload.bin` — once each, and nothing under the
        // junction. A followed junction would report the payload twice.
        assert_eq!(report.entry_count(), 2, "{report:?}");
        for entry in &report.roots[0].entries {
            let path = entry.path.to_string_lossy().replace('/', "\\");
            assert!(!path.contains("\\link\\"), "walked through a junction: {path}");
        }

        let _ = fs::remove_dir_all(&root);
    }

    /// Smoke test for the parallel pipeline at a slightly larger scale.
    #[test]
    fn scans_many_files() {
        let dir = fixture_dir("many");
        for i in 0..500 {
            fs::write(dir.join(format!("f{i:04}.dat")), vec![0u8; 16])
                .expect("write fixture file");
        }

        let report = scan_roots(&[ScanRoot {
            path: dir.clone(),
            category: Category::Cache,
        }]);
        assert_eq!(report.entry_count(), 500);
        assert_eq!(report.total_bytes(), 500 * 16);
        assert_eq!(report.cleanable_bytes(), 500 * 16);

        let _ = fs::remove_dir_all(&dir);
    }
}
