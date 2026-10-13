//! # Dry-run manifest engine (Phase 2, safety gate 2)
//!
//! A [`DryRunManifest`] is the verified snapshot that must exist *before* any
//! destructive execution: it freezes every candidate path with its computed
//! size, file type, category, and the protection verdict it received at scan
//! time.
//!
//! The engine has four parts:
//!
//! 1. **Build** — [`build_manifest`] freezes a [`ScanReport`] into a manifest
//!    with recomputed totals and globally path-sorted entries.
//! 2. **Persist** — [`DryRunManifest::to_file`] / [`DryRunManifest::from_file`]
//!    write and read the JSON artifact (pretty-printed, versioned); the UI
//!    additionally gets it over IPC, and it survives restarts on disk.
//! 3. **Verify** — [`DryRunManifest::verify`] re-checks the manifest's
//!    structural truthfulness (version, recomputed totals, sortedness,
//!    duplicates) and refuses a tampered or hand-made manifest.
//! 4. **Registry** — session-scoped [`ManifestRegistry`]; execution only acts
//!    on manifests registered in this process (an id is meaningless without
//!    a registry entry).
//!
//! Layering: `verify` checks the *artifact*; the protected-path matrix is
//! re-checked per path at execution time (gate 3), because scan-time verdicts
//! are never trusted that far forward.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::safety::protected::ProtectionVerdict;
use crate::scanner::{Category, EntryKind, ScanReport};

/// Current manifest file-format version. Bump on any breaking JSON change.
pub const MANIFEST_VERSION: u32 = 1;

/// Why a manifest could not be produced, read, or verified.
#[derive(Debug, thiserror::Error)]
pub enum ManifestError {
    /// Underlying filesystem error (read/write of the manifest file).
    #[error("manifest I/O error: {0}")]
    Io(#[from] std::io::Error),
    /// The file/string is not valid manifest JSON.
    #[error("invalid manifest JSON: {0}")]
    Json(#[from] serde_json::Error),
    /// The manifest is structurally inconsistent (tampered, hand-made, ...).
    #[error("manifest verification failed: {0}")]
    Verification(String),
}

/// One frozen candidate inside a [`DryRunManifest`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ManifestEntry {
    /// Absolute path of the candidate, as scanned.
    pub path: PathBuf,
    /// Category of the root it was found under.
    pub category: Category,
    /// Whether this is a regular file or a symbolic link.
    pub kind: EntryKind,
    /// Lowercased extension without the dot; `None` if none.
    pub file_type: Option<String>,
    /// Size in bytes at scan time.
    pub size_bytes: u64,
    /// The protection verdict recorded at scan time (re-checked at execution).
    pub verdict: ProtectionVerdict,
}

impl ManifestEntry {
    /// Whether the scan-time verdict allowed acting on this entry.
    pub fn is_cleanable(&self) -> bool {
        self.verdict.allowed
    }
}

/// A dry-run manifest: the reviewed, verifiable snapshot that gates execution.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DryRunManifest {
    /// Registry-assigned id; execution refers to manifests by this id.
    pub id: u64,
    /// Manifest file-format version (see [`MANIFEST_VERSION`]).
    pub version: u32,
    /// When the manifest was generated (Unix seconds).
    pub generated_at_unix: u64,
    /// The frozen candidates, globally sorted by path.
    pub entries: Vec<ManifestEntry>,
    /// Sum of all entry sizes.
    pub total_bytes: u64,
    /// Sum of sizes of entries whose verdict allowed acting on them.
    pub cleanable_bytes: u64,
    /// Number of entries the matrix refused at scan time.
    pub blocked_count: usize,
}

impl DryRunManifest {
    /// Verifies the manifest's structural truthfulness:
    ///
    /// - version matches [`MANIFEST_VERSION`],
    /// - `total_bytes`, `cleanable_bytes`, and `blocked_count` equal the
    ///   values recomputed from the entries,
    /// - entries are globally sorted by path with no duplicates and no empty
    ///   paths.
    ///
    /// This catches tampered files and hand-constructed manifests. It does
    /// **not** re-check entries against the live protected-path matrix — the
    /// execution layer does that per path (gate 3), since scan-time verdicts
    /// are never trusted that far forward.
    pub fn verify(&self) -> Result<(), ManifestError> {
        let mut issues: Vec<String> = Vec::new();

        if self.version != MANIFEST_VERSION {
            issues.push(format!(
                "unsupported manifest version {} (expected {MANIFEST_VERSION})",
                self.version
            ));
        }

        let total: u64 = self.entries.iter().map(|e| e.size_bytes).sum();
        if self.total_bytes != total {
            issues.push(format!(
                "total_bytes {} does not match the sum of entry sizes {total}",
                self.total_bytes
            ));
        }
        let cleanable: u64 = self
            .entries
            .iter()
            .filter(|e| e.is_cleanable())
            .map(|e| e.size_bytes)
            .sum();
        if self.cleanable_bytes != cleanable {
            issues.push(format!(
                "cleanable_bytes {} does not match the recomputed value {cleanable}",
                self.cleanable_bytes
            ));
        }
        let blocked = self.entries.iter().filter(|e| !e.is_cleanable()).count();
        if self.blocked_count != blocked {
            issues.push(format!(
                "blocked_count {} does not match the recomputed value {blocked}",
                self.blocked_count
            ));
        }

        let mut prev: Option<&Path> = None;
        for entry in &self.entries {
            if entry.path.as_os_str().is_empty() {
                issues.push("entry with an empty path".to_string());
            }
            if let Some(previous) = prev {
                if entry.path == previous {
                    issues.push(format!("duplicate entry: {}", previous.display()));
                } else if entry.path < previous {
                    issues.push(format!(
                        "entries are not sorted by path ({} before {})",
                        entry.path.display(),
                        previous.display()
                    ));
                }
            }
            prev = Some(&entry.path);
        }

        if issues.is_empty() {
            Ok(())
        } else {
            Err(ManifestError::Verification(issues.join("; ")))
        }
    }

    /// Serializes the manifest to a pretty-printed JSON string.
    pub fn to_json(&self) -> Result<String, ManifestError> {
        Ok(serde_json::to_string_pretty(self)?)
    }

    /// Parses a manifest from its JSON representation.
    pub fn from_json(json: &str) -> Result<Self, ManifestError> {
        Ok(serde_json::from_str(json)?)
    }

    /// Writes the manifest to a JSON file (pretty-printed, trailing newline).
    ///
    /// This is the review artifact: hand it to a human or a diff tool before
    /// any destructive execution.
    pub fn to_file<P: AsRef<Path>>(&self, path: P) -> Result<(), ManifestError> {
        let mut json = self.to_json()?;
        json.push('\n');
        Ok(std::fs::write(path, json)?)
    }

    /// Loads a manifest from a JSON file written by [`DryRunManifest::to_file`]
    /// (or any conforming JSON). Run [`DryRunManifest::verify`] on the result
    /// before trusting it.
    pub fn from_file<P: AsRef<Path>>(path: P) -> Result<Self, ManifestError> {
        let json = std::fs::read_to_string(path)?;
        Self::from_json(&json)
    }
}

/// Session store of generated manifests.
///
/// Every manifest is registered here before it can be executed; ids are
/// process-local and monotonically increasing. The store is safe to share
/// across threads (e.g. as Tauri managed state).
#[derive(Debug, Default)]
pub struct ManifestRegistry {
    next_id: AtomicU64,
    manifests: Mutex<HashMap<u64, DryRunManifest>>,
}

impl ManifestRegistry {
    /// Builds a manifest from a scan report, stores it, and returns its id.
    pub fn register(&self, report: &ScanReport) -> u64 {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let manifest = build_manifest(report, id);
        self.manifests
            .lock()
            .expect("manifest registry poisoned")
            .insert(id, manifest);
        id
    }

    /// Registers an existing manifest (e.g. one loaded from a file),
    /// preserving its id. Overwrites any manifest with the same id.
    ///
    /// Hand-made or tampered manifests are safe to register: execution runs
    /// [`DryRunManifest::verify`] and refuses them.
    pub fn register_manifest(&self, manifest: DryRunManifest) -> u64 {
        let id = manifest.id;
        self.manifests
            .lock()
            .expect("manifest registry poisoned")
            .insert(id, manifest);
        id
    }

    /// Returns a clone of the manifest with the given id, if it exists.
    pub fn get(&self, id: u64) -> Option<DryRunManifest> {
        self.manifests
            .lock()
            .expect("manifest registry poisoned")
            .get(&id)
            .cloned()
    }

    /// Number of manifests currently held.
    pub fn len(&self) -> usize {
        self.manifests
            .lock()
            .expect("manifest registry poisoned")
            .len()
    }

    /// Whether the registry holds no manifests.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// Freezes a scan report into a [`DryRunManifest`] with the given id.
///
/// Entries are copied with their scan-time verdicts and globally sorted by
/// path; the totals are recomputed from the entries, so a manifest built this
/// way always passes [`DryRunManifest::verify`].
pub fn build_manifest(report: &ScanReport, id: u64) -> DryRunManifest {
    let mut entries: Vec<ManifestEntry> = report
        .roots
        .iter()
        .flat_map(|r| r.entries.iter())
        .map(|e| ManifestEntry {
            path: e.path.clone(),
            category: e.category,
            kind: e.kind,
            file_type: e.file_type.clone(),
            size_bytes: e.size_bytes,
            verdict: e.verdict.clone(),
        })
        .collect();
    entries.sort_by(|a, b| a.path.cmp(&b.path));

    let total_bytes = entries.iter().map(|e| e.size_bytes).sum();
    let cleanable_bytes = entries
        .iter()
        .filter(|e| e.is_cleanable())
        .map(|e| e.size_bytes)
        .sum();
    let blocked_count = entries.iter().filter(|e| !e.is_cleanable()).count();

    DryRunManifest {
        id,
        version: MANIFEST_VERSION,
        generated_at_unix: unix_now(),
        entries,
        total_bytes,
        cleanable_bytes,
        blocked_count,
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
    use crate::safety::protected::{ProtectionReason, ProtectionVerdict};
    use crate::scanner::{EntryKind, RootScan, ScanEntry, ScanRoot};
    use std::fs;

    fn scan_entry(path: &str, size: u64, allowed: bool) -> ScanEntry {
        ScanEntry {
            path: PathBuf::from(path),
            category: Category::Temp,
            kind: EntryKind::File,
            file_type: None,
            size_bytes: size,
            modified_unix: None,
            verdict: if allowed {
                ProtectionVerdict {
                    allowed: true,
                    reason: None,
                    rule: None,
                }
            } else {
                ProtectionVerdict {
                    allowed: false,
                    reason: Some(ProtectionReason::ProtectedDirectory),
                    rule: Some("test rule".to_string()),
                }
            },
        }
    }

    fn report_with(entries: Vec<ScanEntry>) -> crate::scanner::ScanReport {
        crate::scanner::ScanReport {
            scanned_at_unix: 0,
            roots: vec![RootScan {
                root: ScanRoot {
                    path: PathBuf::from("."),
                    category: Category::Temp,
                },
                entries,
                errors: Vec::new(),
            }],
        }
    }

    /// Two cleanable files (sizes 10 + 5) and one blocked file (size 7).
    fn sample_manifest() -> DryRunManifest {
        build_manifest(
            &report_with(vec![
                scan_entry("b.log", 5, true),
                scan_entry("a.txt", 10, true),
                scan_entry("c.dll", 7, false),
            ]),
            1,
        )
    }

    #[test]
    fn build_manifest_computes_totals_and_sorts_entries() {
        let m = sample_manifest();
        assert_eq!(m.version, MANIFEST_VERSION);
        assert_eq!(m.total_bytes, 22);
        assert_eq!(m.cleanable_bytes, 15);
        assert_eq!(m.blocked_count, 1);
        let paths: Vec<String> = m
            .entries
            .iter()
            .map(|e| e.path.to_string_lossy().into_owned())
            .collect();
        assert_eq!(paths, ["a.txt", "b.log", "c.dll"]);
        assert!(!m.entries[2].is_cleanable());
        assert!(m.verify().is_ok(), "fresh manifests always verify");
    }

    #[test]
    fn json_round_trip_preserves_the_manifest() {
        let m = sample_manifest();
        let json = m.to_json().expect("serialize");
        let back = DryRunManifest::from_json(&json).expect("parse");
        assert_eq!(back, m);
    }

    #[test]
    fn file_round_trip_preserves_the_manifest() {
        let dir = std::env::temp_dir().join(format!(
            "freebuff-manifest-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("create fixture dir");
        let path = dir.join("manifest.json");

        let m = sample_manifest();
        m.to_file(&path).expect("write manifest file");
        let back = DryRunManifest::from_file(&path).expect("read manifest file");
        assert_eq!(back, m);
        assert!(back.verify().is_ok());

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn verify_detects_tampered_totals() {
        let mut value: serde_json::Value =
            serde_json::from_str(&sample_manifest().to_json().unwrap()).unwrap();
        value["total_bytes"] = serde_json::json!(999_999);
        let tampered = DryRunManifest::from_json(&value.to_string()).unwrap();
        let err = tampered.verify().unwrap_err();
        assert!(err.to_string().contains("total_bytes"), "{err}");
    }

    #[test]
    fn verify_detects_wrong_version() {
        let mut value: serde_json::Value =
            serde_json::from_str(&sample_manifest().to_json().unwrap()).unwrap();
        value["version"] = serde_json::json!(999);
        let bad = DryRunManifest::from_json(&value.to_string()).unwrap();
        assert!(bad.verify().unwrap_err().to_string().contains("version"));
    }

    #[test]
    fn verify_detects_duplicate_and_unsorted_entries() {
        let entry = ManifestEntry {
            path: PathBuf::from("x"),
            category: Category::Temp,
            kind: EntryKind::File,
            file_type: None,
            size_bytes: 1,
            verdict: ProtectionVerdict {
                allowed: true,
                reason: None,
                rule: None,
            },
        };
        let manifest = DryRunManifest {
            id: 7,
            version: MANIFEST_VERSION,
            generated_at_unix: 0,
            entries: vec![entry.clone(), entry],
            total_bytes: 2,
            cleanable_bytes: 2,
            blocked_count: 0,
        };
        let err = manifest.verify().unwrap_err();
        assert!(err.to_string().contains("duplicate"), "{err}");
    }

    #[test]
    fn garbage_json_is_rejected() {
        let err = DryRunManifest::from_json("this is not json").unwrap_err();
        assert!(matches!(err, ManifestError::Json(_)));
    }

    #[test]
    fn registry_round_trips_loaded_manifests() {
        let registry = ManifestRegistry::default();
        let m = sample_manifest();
        let id = registry.register_manifest(m.clone());
        assert_eq!(id, 1, "register_manifest preserves the manifest's id");
        assert_eq!(registry.get(id), Some(m));
        assert_eq!(registry.len(), 1);
        assert!(!registry.is_empty());
    }
}
