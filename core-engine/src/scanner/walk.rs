//! Parallel walking of a single sanctioned root.
//!
//! Traversal uses `walkdir` (recursive, symlink-safe, same-filesystem) and
//! processing uses `rayon`'s parallel iterator over the collected entries, so
//! metadata reads, size computation, and protected-path validation all run
//! across the thread pool. Entries are re-sorted by path afterwards so scan
//! output (and the Phase 2 dry-run manifest) is deterministic.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use walkdir::WalkDir;

use super::roots::{Category, ScanRoot};
use crate::safety::protected::{ProtectedMatrix, ProtectionVerdict};

/// Cap on reported per-root walk errors (permission issues, vanished files).
const MAX_ERRORS: usize = 32;

/// `FILE_ATTRIBUTE_REPARSE_POINT` — set on any NTFS reparse point: a directory
/// junction, a mount point, or a symlink.
#[cfg(windows)]
const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0400;

/// What kind of filesystem object a [`ScanEntry`] is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum EntryKind {
    /// A regular file — the primary cleanup candidate.
    File,
    /// A symbolic link. Links are never followed during traversal.
    Symlink,
}

/// One candidate found by the scanner, ready for the dry-run manifest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScanEntry {
    /// Absolute path of the candidate.
    pub path: PathBuf,
    /// Category of the root it was found under.
    pub category: Category,
    /// Whether this is a regular file or a symbolic link.
    pub kind: EntryKind,
    /// Lowercased extension without the dot (`"log"`); `None` if none.
    pub file_type: Option<String>,
    /// Size in bytes (0 for symlinks).
    pub size_bytes: u64,
    /// Last modification time as Unix seconds, when known.
    pub modified_unix: Option<u64>,
    /// The protected-path verdict for this exact path. Only entries with
    /// `verdict.allowed == true` may ever be acted on.
    pub verdict: ProtectionVerdict,
}

impl ScanEntry {
    /// Whether the protected-path matrix allows this entry to be acted on.
    pub fn is_cleanable(&self) -> bool {
        self.verdict.allowed
    }
}

/// Result of scanning one [`ScanRoot`].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RootScan {
    /// The root that was scanned.
    pub root: ScanRoot,
    /// Candidates found beneath the root, sorted by path.
    pub entries: Vec<ScanEntry>,
    /// Non-fatal issues (permission errors, vanished entries), capped.
    pub errors: Vec<String>,
}

/// A complete dry-run scan report — the input to the Phase 2 manifest engine.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScanReport {
    /// When the scan ran (Unix seconds).
    pub scanned_at_unix: u64,
    /// One [`RootScan`] per root that was attempted.
    pub roots: Vec<RootScan>,
}

impl ScanReport {
    /// Number of candidates found across all roots.
    pub fn entry_count(&self) -> usize {
        self.roots.iter().map(|r| r.entries.len()).sum()
    }

    /// Total size in bytes of every candidate.
    pub fn total_bytes(&self) -> u64 {
        self.roots
            .iter()
            .flat_map(|r| r.entries.iter())
            .map(|e| e.size_bytes)
            .sum()
    }

    /// Total size in bytes of candidates the matrix allows acting on.
    pub fn cleanable_bytes(&self) -> u64 {
        self.roots
            .iter()
            .flat_map(|r| r.entries.iter())
            .filter(|e| e.is_cleanable())
            .map(|e| e.size_bytes)
            .sum()
    }

    /// Total size per [`Category`] (deterministic ordering).
    pub fn bytes_by_category(&self) -> BTreeMap<Category, u64> {
        let mut by_category = BTreeMap::new();
        for root in &self.roots {
            for entry in &root.entries {
                *by_category.entry(entry.category).or_insert(0) += entry.size_bytes;
            }
        }
        by_category
    }
}

/// Whether `entry` is a Windows reparse point (junction, mount point, or
/// symlink) rather than a real directory.
///
/// `walkdir`'s `follow_links(false)` keeps it from following *symlinks*, but
/// Windows does not report a directory junction as a symlink — it reports a
/// directory — so without this check the walker would descend into one.
/// Package-manager caches are the common case: `~/.bun/install/cache` stores
/// each package as a real directory *plus* a junction pointing at a sibling,
/// so following junctions would count the same bytes twice and let the
/// executor offer the same file for deletion under two paths.
#[cfg(windows)]
fn is_reparse_point(entry: &walkdir::DirEntry) -> bool {
    use std::os::windows::fs::MetadataExt;
    entry
        .metadata()
        .map(|m| m.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0)
        .unwrap_or(false)
}

/// Unix equivalent: symlinks are already not followed (`follow_links(false)`)
/// and `same_file_system(true)` stops bind mounts at the filesystem boundary,
/// so nothing extra has to be refused here.
#[cfg(not(windows))]
fn is_reparse_point(_entry: &walkdir::DirEntry) -> bool {
    false
}

/// Scans one root with `walkdir` + `rayon`.
///
/// `follow_links(false)` guarantees traversal never escapes the root through a
/// symlink, `same_file_system(true)` stops the walk at mount boundaries, and
/// the `filter_entry` guard refuses reparse points (Windows directory
/// junctions in particular — see [`is_reparse_point`]) so a link to a sibling
/// directory cannot make the same bytes appear twice. Every file and symlink
/// is classified, measured, and passed through the protected-path matrix;
/// directories are implied by their contents and are not emitted as
/// candidates.
pub fn scan_root(root: &ScanRoot, matrix: &ProtectedMatrix) -> RootScan {
    let walker = WalkDir::new(&root.path)
        .follow_links(false)
        .same_file_system(true)
        .into_iter()
        .filter_entry(|entry| !is_reparse_point(entry));

    // Single-pass traversal; metadata/validation happens in parallel below.
    let items: Vec<Result<walkdir::DirEntry, walkdir::Error>> = walker.collect();

    let mut errors: Vec<String> = Vec::new();
    let mut omitted = 0usize;
    for item in &items {
        if let Err(e) = item {
            if errors.len() < MAX_ERRORS {
                errors.push(e.to_string());
            } else {
                omitted += 1;
            }
        }
    }
    if omitted > 0 {
        errors.push(format!("… and {omitted} more errors omitted"));
    }

    let mut entries: Vec<ScanEntry> = items
        .into_par_iter()
        .filter_map(|item| item.ok())
        .filter_map(|de| classify(de, root.category, matrix))
        .collect();

    // Deterministic manifest ordering regardless of parallel collection order.
    entries.sort_by(|a, b| a.path.cmp(&b.path));

    RootScan {
        root: root.clone(),
        entries,
        errors,
    }
}

/// Classifies one walked entry into a [`ScanEntry`], or skips it (directories,
/// sockets, devices, ...) when it is not a cleanup candidate.
fn classify(de: walkdir::DirEntry, category: Category, matrix: &ProtectedMatrix) -> Option<ScanEntry> {
    let path = de.path();
    let ft = de.file_type();

    // Windows Recycle Bin stores a tiny `$I*` metadata file (original path,
    // deletion date) beside every `$R*` content file. The metadata carries no
    // recoverable space and only doubles the manifest noise, so only the real
    // content entries are emitted for the RecycleBin category.
    #[cfg(windows)]
    if category == Category::RecycleBin {
        let is_metadata = path
            .file_name()
            .and_then(|n| n.to_str())
            .map(|n| n.starts_with("$I"))
            .unwrap_or(false);
        if is_metadata {
            return None;
        }
    }

    let kind = if ft.is_file() {
        EntryKind::File
    } else if ft.is_symlink() {
        EntryKind::Symlink
    } else {
        return None;
    };

    // With follow_links(false), metadata() has symlink_metadata semantics, so
    // a symlink inside the root can never make us stat through to a target
    // outside it. We only measure real files anyway.
    let (size_bytes, modified_unix) = if kind == EntryKind::File {
        match de.metadata() {
            Ok(m) => (m.len(), unix_secs(m.modified().ok())),
            Err(_) => (0, None),
        }
    } else {
        (0, None)
    };

    let file_type = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_lowercase());

    Some(ScanEntry {
        path: path.to_path_buf(),
        category,
        kind,
        file_type,
        size_bytes,
        modified_unix,
        verdict: matrix.validate(path),
    })
}

fn unix_secs(t: Option<SystemTime>) -> Option<u64> {
    t.and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
}
