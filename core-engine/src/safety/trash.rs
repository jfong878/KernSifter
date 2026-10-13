//! # Empty Recycle Bin (permanent — the one exception)
//!
//! Everything else in KernSifter stages deletions through the OS recycle bin
//! / trash so they stay recoverable. Emptied trash is the opposite: it is the
//! **permanent** deletion the tool otherwise never performs. That is exactly
//! why it gets its own gate and its own module:
//!
//! - **Gate 1 — explicit confirmation**: [`empty_recycle_bin`] refuses unless
//!   `confirmed == true`. The caller (UI dialog, CLI prompt) must obtain it
//!   from the user in a step that cannot be confused with a normal cleanup.
//! - **Fixed scope**: the function only ever touches the *current user's* OS
//!   trash — `C:\$Recycle.Bin` on Windows (via the shell's own
//!   `Clear-RecycleBin`), `~/.Trash` on macOS, and the XDG trash
//!   (`~/.local/share/Trash`) on Linux. There is no path argument, so a
//!   caller cannot aim it anywhere else.
//! - **No unsafe**: the crate forbids `unsafe_code`; the OS-native empty is
//!   reached through safe means (std `fs` on macOS/Linux, PowerShell's
//!   `Clear-RecycleBin` on Windows — which calls `SHEmptyRecycleBin`).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

/// Result of emptying the OS trash.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EmptyTrashReport {
    /// When the empty ran (Unix seconds).
    pub emptied_at_unix: u64,
    /// Best-effort count of entries removed (0 when the OS reports no count,
    /// e.g. Windows shell API).
    pub removed_entries: usize,
    /// Best-effort bytes removed (0 when the OS reports no count).
    pub removed_bytes: u64,
    /// Non-fatal issues encountered while emptying (permission errors on
    /// subdirectories owned by other users, PowerShell stderr, ...).
    pub errors: Vec<String>,
}

/// One extension group in a [`RecycleBinSummary`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtensionSummary {
    /// Lowercased extension without the dot (`"pdf"`), or `"(none)"` for
    /// extension-less files.
    pub extension: String,
    /// Number of entries in this group.
    pub entries: usize,
    /// Combined size in bytes.
    pub bytes: u64,
}

/// One file found in the trash (for the "largest files" review list).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TrashFile {
    /// Absolute path of the trashed file.
    pub path: PathBuf,
    /// Size in bytes.
    pub size_bytes: u64,
    /// Last modification time as Unix seconds, when known.
    pub modified_unix: Option<u64>,
}

/// Per-directory totals inside the trash (on Windows this is the whole
/// `$Recycle.Bin`, whose per-user SID subfolders are best-effort).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DirSummary {
    /// The trash directory.
    pub path: PathBuf,
    /// Readable entries found under it.
    pub entries: usize,
    /// Their combined size in bytes.
    pub bytes: u64,
}

/// A read-only breakdown of the current user's recycle bin contents — what
/// the UI shows *before* the user commits to emptying it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RecycleBinSummary {
    /// When the summary was computed (Unix seconds).
    pub scanned_at_unix: u64,
    /// Total readable entries in the trash.
    pub total_entries: usize,
    /// Their combined size in bytes.
    pub total_bytes: u64,
    /// Grouped by file extension, largest group first.
    pub by_extension: Vec<ExtensionSummary>,
    /// Largest individual files, largest first (capped at 25).
    pub largest_files: Vec<TrashFile>,
    /// Per-trash-directory totals.
    pub dirs: Vec<DirSummary>,
}

/// Why the recycle bin could not be emptied.
#[derive(Debug, thiserror::Error)]
pub enum TrashError {
    /// The caller did not pass explicit confirmation.
    #[error("emptying the recycle bin is permanent and requires explicit confirmation (confirmed = true)")]
    NotConfirmed,
    /// The OS refused to empty the trash (Windows shell failure, etc.).
    #[error("the OS refused to empty the recycle bin: {0}")]
    Os(String),
    /// Underlying filesystem error while removing trash contents.
    #[error("failed to empty the recycle bin: {0}")]
    Io(#[from] std::io::Error),
}

/// The current user's trash directories for the host platform.
///
/// Only these paths are ever touched — the function has no path parameter, so
/// the fixed scope cannot be widened by a caller.
#[cfg(windows)]
fn trash_dirs() -> Vec<PathBuf> {
    vec![PathBuf::from(r"C:\$Recycle.Bin")]
}

#[cfg(target_os = "macos")]
fn trash_dirs() -> Vec<PathBuf> {
    dirs::home_dir()
        .map(|h| vec![h.join(".Trash")])
        .unwrap_or_default()
}

#[cfg(all(unix, not(target_os = "macos"), not(target_os = "android")))]
fn trash_dirs() -> Vec<PathBuf> {
    dirs::data_dir()
        .map(|d| vec![d.join("Trash").join("files"), d.join("Trash").join("info")])
        .unwrap_or_default()
}

#[cfg(any(target_os = "android", target_os = "ios"))]
fn trash_dirs() -> Vec<PathBuf> {
    // Scoped storage / sandbox: the OS manages trash; there is nothing to do.
    Vec::new()
}

/// Empties the current user's OS recycle bin — **permanently**.
///
/// Refuses without explicit confirmation. On Windows the empty is delegated to
/// PowerShell's `Clear-RecycleBin` (the shell API, `SHEmptyRecycleBin`); on
/// macOS and Linux the contents of the trash directories are removed directly.
/// In both cases the trash directories themselves are never deleted, and
/// entries the current user cannot read (other users' trash on Windows) are
/// reported as errors rather than silently skipped.
pub fn empty_recycle_bin(confirmed: bool) -> Result<EmptyTrashReport, TrashError> {
    if !confirmed {
        return Err(TrashError::NotConfirmed);
    }

    let dirs = trash_dirs();
    let (removed_entries, removed_bytes) = count_contents(&dirs);

    // Windows delegates to the shell and never mutates this; macOS/Linux do.
    #[allow(unused_mut)]
    let mut errors: Vec<String> = Vec::new();

    #[cfg(windows)]
    {
        // The OS-native empty (SHEmptyRecycleBin) via PowerShell. This is the
        // authoritative way: it handles locked files, shell notifications, and
        // per-user SID folders the way the shell itself does.
        let output = std::process::Command::new("powershell")
            .args(["-NoProfile", "-NonInteractive", "-Command", "Clear-RecycleBin -Force"])
            .output()
            .map_err(|e| TrashError::Os(format!("cannot launch powershell: {e}")))?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            return Err(TrashError::Os(if stderr.is_empty() {
                format!("exit code {:?}", output.status.code())
            } else {
                stderr
            }));
        }
    }

    #[cfg(not(windows))]
    {
        // Remove the contents of each trash directory, never the directory
        // itself. remove_dir_all on a symlink removes the link, not the
        // target, so traversal cannot escape the trash through a link.
        for dir in &dirs {
            if !dir.is_dir() {
                continue;
            }
            errors.extend(remove_contents(dir));
        }
    }

    Ok(EmptyTrashReport {
        emptied_at_unix: unix_now(),
        removed_entries,
        removed_bytes,
        errors,
    })
}

/// Computes a read-only breakdown of the current user's recycle bin.
///
/// Best-effort: unreadable subtrees (other users' SID folders under
/// `$Recycle.Bin`) are skipped, so the totals are "what the current user can
/// see". Nothing is deleted.
pub fn recycle_bin_summary() -> RecycleBinSummary {
    let dirs = trash_dirs();

    let mut files = Vec::new();
    for dir in &dirs {
        collect_files(dir, &mut files);
    }

    let mut summary = summarize_files(files);
    summary.scanned_at_unix = unix_now();
    summary.dirs = dirs
        .iter()
        .map(|d| {
            let (entries, bytes) = count_contents(&[d.clone()]);
            DirSummary {
                path: d.clone(),
                entries,
                bytes,
            }
        })
        .collect();
    summary
}

/// Windows Recycle Bin pairs every `$R*` content file with a tiny `$I*`
/// metadata file (original path, deletion date). The metadata carries no
/// recoverable space and doubles the noise in summaries, so it is excluded
/// from counts and listings. No-op on other platforms (macOS `~/.Trash` and
/// the XDG trash `files/` dir keep original filenames).
fn is_recycle_bin_metadata(path: &Path) -> bool {
    #[cfg(windows)]
    {
        path.file_name()
            .and_then(|n| n.to_str())
            .map(|n| n.starts_with("$I"))
            .unwrap_or(false)
    }
    #[cfg(not(windows))]
    {
        let _ = path;
        false
    }
}

/// Collects every readable file under `dir` (recursively) into `out`.
///
/// Uses `walkdir` with symlinks never followed and the same filesystem, and
/// permission errors (e.g. other users' SID folders under `$Recycle.Bin`)
/// are skipped rather than hanging or aborting the walk. Windows `$I*`
/// metadata files are excluded (see [`is_recycle_bin_metadata`]).
fn collect_files(dir: &Path, out: &mut Vec<TrashFile>) {
    for item in walkdir::WalkDir::new(dir)
        .follow_links(false)
        .same_file_system(true)
        .into_iter()
        .filter_map(|e| e.ok())
    {
        if !item.file_type().is_file() {
            continue;
        }
        let path = item.path();
        if is_recycle_bin_metadata(path) {
            continue;
        }
        if let Ok(m) = std::fs::metadata(path) {
            out.push(TrashFile {
                path: path.to_path_buf(),
                size_bytes: m.len(),
                modified_unix: m
                    .modified()
                    .ok()
                    .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                    .map(|d| d.as_secs()),
            });
        }
    }
}

/// Groups collected files into a [`RecycleBinSummary`]: totals, extension
/// breakdown (largest group first), and largest files (largest first, capped
/// at 25).
fn summarize_files(mut files: Vec<TrashFile>) -> RecycleBinSummary {
    files.sort_by(|a, b| {
        b.size_bytes
            .cmp(&a.size_bytes)
            .then_with(|| a.path.cmp(&b.path))
    });

    let total_entries = files.len();
    let total_bytes = files.iter().map(|f| f.size_bytes).sum();

    let mut by_ext: BTreeMap<String, (usize, u64)> = BTreeMap::new();
    for f in &files {
        let ext = f
            .path
            .extension()
            .and_then(|e| e.to_str())
            .map(|e| e.to_lowercase())
            .unwrap_or_else(|| "(none)".to_string());
        let e = by_ext.entry(ext).or_insert((0, 0));
        e.0 += 1;
        e.1 += f.size_bytes;
    }
    let mut by_extension: Vec<ExtensionSummary> = by_ext
        .into_iter()
        .map(|(extension, (entries, bytes))| ExtensionSummary {
            extension,
            entries,
            bytes,
        })
        .collect();
    by_extension.sort_by(|a, b| b.bytes.cmp(&a.bytes));

    RecycleBinSummary {
        scanned_at_unix: 0,
        total_entries,
        total_bytes,
        by_extension,
        largest_files: files.into_iter().take(25).collect(),
        dirs: Vec::new(),
    }
}

/// Counts files and bytes under the given directories (best-effort; skips
/// unreadable subtrees, e.g. other users' SID folders under `$Recycle.Bin`).
fn count_contents(dirs: &[PathBuf]) -> (usize, u64) {
    let mut entries = 0usize;
    let mut bytes = 0u64;
    for dir in dirs {
        for item in walkdir::WalkDir::new(dir)
            .follow_links(false)
            .same_file_system(true)
            .into_iter()
            .filter_map(|e| e.ok())
        {
            if !item.file_type().is_file() {
                continue;
            }
            if is_recycle_bin_metadata(item.path()) {
                continue;
            }
            entries += 1;
            if let Ok(m) = item.metadata() {
                bytes += m.len();
            }
        }
    }
    (entries, bytes)
}

/// Removes every entry inside `dir`, keeping the directory itself. Returns
/// per-entry error messages; `remove_dir_all` on a symlink only removes the
/// link, so nothing outside the trash can be reached through a link.
///
/// Only used on macOS/Linux — Windows delegates to the shell's
/// `Clear-RecycleBin`, so this is dead code there.
#[cfg(not(windows))]
fn remove_contents(dir: &Path) -> Vec<String> {
    let mut errors = Vec::new();
    let Ok(rd) = std::fs::read_dir(dir) else {
        errors.push(format!("cannot read {}", dir.display()));
        return errors;
    };
    for item in rd.flatten() {
        let path = item.path();
        if let Err(e) = std::fs::remove_dir_all(&path) {
            // Fall back to plain removal in case remove_dir_all refuses (e.g.
            // read-only or already-gone entries).
            if let Err(e2) = std::fs::remove_file(&path) {
                errors.push(format!("{}: {e} / {e2}", path.display()));
            }
        }
    }
    errors
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

    fn fixture_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "kernsifter-trash-test-{}-{name}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create fixture dir");
        dir
    }

    #[test]
    fn unconfirmed_empty_is_refused() {
        let err = empty_recycle_bin(false).expect_err("must refuse without confirmation");
        assert!(matches!(err, TrashError::NotConfirmed));
    }

    #[test]
    fn count_contents_sums_files_and_bytes() {
        let dir = fixture_dir("count");
        std::fs::write(dir.join("a.bin"), vec![0u8; 10]).expect("write");
        std::fs::create_dir_all(dir.join("sub")).expect("mkdir");
        std::fs::write(dir.join("sub").join("b.bin"), vec![0u8; 5]).expect("write");

        let (entries, bytes) = count_contents(&[dir.clone()]);
        assert_eq!(entries, 2);
        assert_eq!(bytes, 15);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn summary_groups_by_extension_and_orders_largest_first() {
        let files = vec![
            TrashFile {
                path: PathBuf::from("C:\\Trash\\$R1.pdf"),
                size_bytes: 10,
                modified_unix: None,
            },
            TrashFile {
                path: PathBuf::from("C:\\Trash\\$R2.PDF"),
                size_bytes: 20,
                modified_unix: None,
            },
            TrashFile {
                path: PathBuf::from("C:\\Trash\\$R3.bin"),
                size_bytes: 50,
                modified_unix: None,
            },
            TrashFile {
                path: PathBuf::from("C:\\Trash\\$R4"),
                size_bytes: 5,
                modified_unix: None,
            },
        ];
        let s = summarize_files(files);
        assert_eq!(s.total_entries, 4);
        assert_eq!(s.total_bytes, 85);

        // Extensions are case-normalized and grouped, largest group first.
        let exts: Vec<&str> = s.by_extension.iter().map(|e| e.extension.as_str()).collect();
        assert_eq!(exts, ["bin", "pdf", "(none)"]);
        assert_eq!(s.by_extension[0].bytes, 50);
        assert_eq!(s.by_extension[1].entries, 2);
        assert_eq!(s.by_extension[1].bytes, 30);

        // Largest files come first.
        assert_eq!(s.largest_files[0].size_bytes, 50);
        assert_eq!(s.largest_files[3].size_bytes, 5);
    }

    #[cfg(windows)]
    #[test]
    fn collect_files_skips_recycle_bin_metadata() {
        let dir = fixture_dir("meta");
        // The real Windows pairing: $I metadata + $R content for each item.
        std::fs::write(dir.join("$I0001"), vec![0u8; 100]).expect("write $I");
        std::fs::write(dir.join("$R0001.pdf"), vec![0u8; 10_000]).expect("write $R");
        std::fs::write(dir.join("$I0002"), vec![0u8; 50]).expect("write $I");
        std::fs::write(dir.join("$R0002.bin"), vec![0u8; 20_000]).expect("write $R");

        let mut files = Vec::new();
        collect_files(&dir, &mut files);
        let names: Vec<String> = files
            .iter()
            .map(|f| f.path.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, ["$R0001.pdf", "$R0002.bin"], "$I metadata must be excluded");
        assert_eq!(files.iter().map(|f| f.size_bytes).sum::<u64>(), 30_000);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn collect_files_recurses_and_records_sizes() {
        let dir = fixture_dir("collect");
        std::fs::write(dir.join("a.txt"), vec![0u8; 7]).expect("write");
        std::fs::create_dir_all(dir.join("sub")).expect("mkdir");
        std::fs::write(dir.join("sub").join("b.zip"), vec![0u8; 9]).expect("write");

        let mut files = Vec::new();
        collect_files(&dir, &mut files);
        assert_eq!(files.len(), 2);
        assert_eq!(files.iter().map(|f| f.size_bytes).sum::<u64>(), 16);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(not(windows))]
    #[test]
    fn remove_contents_empties_but_keeps_the_directory() {
        let dir = fixture_dir("remove");
        std::fs::write(dir.join("a.bin"), b"x").expect("write");
        std::fs::create_dir_all(dir.join("sub")).expect("mkdir");
        std::fs::write(dir.join("sub").join("b.bin"), b"y").expect("write");

        let errors = remove_contents(&dir);
        assert!(errors.is_empty(), "{errors:?}");
        assert!(dir.is_dir(), "the trash directory itself must survive");
        assert_eq!(
            std::fs::read_dir(&dir).expect("read dir").count(),
            0,
            "contents must be gone"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// `remove_dir_all` on a symlink removes the link, not the target — so a
    /// link inside the trash cannot escape it.
    #[cfg(unix)]
    #[test]
    fn remove_contents_does_not_follow_symlinks_out() {
        let parent = fixture_dir("symlink");
        let outside = parent.join("outside");
        let trash = parent.join("trash");
        std::fs::create_dir_all(&outside).expect("mkdir outside");
        std::fs::create_dir_all(&trash).expect("mkdir trash");
        std::fs::write(outside.join("secret.txt"), b"secret").expect("write secret");
        std::os::unix::fs::symlink(&outside, trash.join("link")).expect("symlink");

        let errors = remove_contents(&trash);
        assert!(errors.is_empty(), "{errors:?}");
        assert!(
            outside.join("secret.txt").exists(),
            "the symlink target must survive"
        );

        let _ = std::fs::remove_dir_all(&parent);
    }
}
