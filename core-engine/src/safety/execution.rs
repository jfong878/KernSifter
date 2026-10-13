//! # Gated execution (Phase 2, safety gate 3)
//!
//! The Safe Deletion Protocol: nothing is ever permanently deleted without a
//! reviewed manifest, an explicit confirmation, and a fresh re-validation of
//! every path against the protected-path matrix at execution time.
//!
//! Execution semantics:
//!
//! - **Gate 1 — manifest**: execution requires a [`DryRunManifest`] that was
//!   registered in this process (via [`ManifestRegistry`]); random ids are
//!   refused.
//! - **Gate 2 — verification**: the manifest must pass
//!   [`DryRunManifest::verify`] — a tampered or hand-made manifest (wrong
//!   totals, duplicates, bad version) is refused before anything runs.
//! - **Gate 3 — confirmation**: the caller must pass `confirmed = true`; a
//!   UI "I reviewed the manifest" step is the intended source.
//! - **Gate 4 — re-validation**: every path is re-checked against the matrix
//!   *at execution time* (never trusted from scan time), so a path cannot
//!   become protected between the manifest and the delete.
//! - **Staging**: files are moved to the OS recycle bin / trash
//!   ([`staging::delete`]) — recoverable, never a permanent `remove`. A
//!   transient failure (an antivirus or indexer holding a file) is retried
//!   **once**; a locked in-use file then records `Failed` and the run moves
//!   on — no single path can stall an execution. With `simulate = true`
//!   nothing touches the filesystem at all (Simulation Mode).

use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use super::manifest::{DryRunManifest, ManifestRegistry};
use crate::safety::protected::validate_path;

/// What happened to a single path during execution.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ExecutionStatus {
    /// Moved to the OS recycle bin / trash (recoverable).
    Trashed,
    /// Would have been moved, but simulation mode was on (nothing changed).
    Simulated,
    /// Re-validation refused the path at execution time (protection matrix).
    Blocked,
    /// The path no longer exists (deleted since the scan, etc.).
    Missing,
    /// The trash move failed; `detail` carries the OS error.
    Failed,
}

/// Per-path execution result.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExecutionOutcome {
    /// The path that was acted on (or refused).
    pub path: PathBuf,
    /// What happened.
    pub status: ExecutionStatus,
    /// Extra context (blocked rule, OS error message, ...).
    pub detail: Option<String>,
}

/// Full result of executing one manifest.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExecutionReport {
    /// The manifest this execution refers to.
    pub manifest_id: u64,
    /// When execution ran (Unix seconds).
    pub executed_at_unix: u64,
    /// `true` when nothing was actually changed (simulation mode).
    pub simulate: bool,
    /// Per-path outcomes, sorted by path.
    pub outcomes: Vec<ExecutionOutcome>,
    /// Bytes actually moved to trash (0 in simulation mode).
    pub trashed_bytes: u64,
    /// Bytes that would have been moved (simulation mode only).
    pub simulated_bytes: u64,
}

impl ExecutionReport {
    /// Number of outcomes with the given status.
    pub fn status_count(&self, status: ExecutionStatus) -> usize {
        self.outcomes.iter().filter(|o| o.status == status).count()
    }
}

/// Why execution was refused before touching anything.
#[derive(Debug, Clone, thiserror::Error)]
pub enum ExecutionError {
    /// The manifest id is unknown to this process's registry.
    #[error("no manifest with id {0} — generate and review a dry-run manifest first")]
    UnknownManifest(u64),
    /// The manifest failed structural verification (tampered or hand-made).
    #[error("manifest {0} failed verification: {1}")]
    UnverifiedManifest(u64, String),
    /// The caller did not pass explicit confirmation.
    #[error("execution requires explicit confirmation (confirmed = true)")]
    NotConfirmed,
    /// The manifest exists but contains nothing to do.
    #[error("manifest {0} contains no entries")]
    EmptyManifest(u64),
}

/// Executes the manifest with the given id.
///
/// Refuses (`Err`) without a registered manifest, when the manifest fails
/// [`DryRunManifest::verify`] (tampered / hand-made), or without explicit
/// confirmation. With `simulate = true`, every path is still re-validated and
/// reported, but nothing touches the filesystem.
pub fn execute_manifest(
    registry: &ManifestRegistry,
    manifest_id: u64,
    confirmed: bool,
    simulate: bool,
) -> Result<ExecutionReport, ExecutionError> {
    if !confirmed {
        return Err(ExecutionError::NotConfirmed);
    }
    let manifest: DryRunManifest = registry
        .get(manifest_id)
        .ok_or(ExecutionError::UnknownManifest(manifest_id))?;

    // Gate 2: the manifest artifact must be structurally truthful — a
    // tampered or hand-made manifest is refused before anything runs.
    manifest.verify().map_err(|e| {
        ExecutionError::UnverifiedManifest(manifest_id, e.to_string())
    })?;

    if manifest.entries.is_empty() {
        return Err(ExecutionError::EmptyManifest(manifest_id));
    }

    let mut outcomes = Vec::with_capacity(manifest.entries.len());
    let mut trashed_bytes = 0u64;
    let mut simulated_bytes = 0u64;

    for entry in &manifest.entries {
        // Gate 3.5: the recycle bin is never executable, even if a hand-made
        // manifest points a RecycleBin entry at a deletable path. Removing
        // from the trash is a permanent delete — no recoverable trash step.
        if entry.category == crate::scanner::Category::RecycleBin {
            outcomes.push(ExecutionOutcome {
                path: entry.path.clone(),
                status: ExecutionStatus::Blocked,
                detail: Some(
                    "OS recycle bin — KernSifter never deletes trash (empty it via the OS)"
                        .to_string(),
                ),
            });
            continue;
        }

        // Gate 3: re-validate at execution time — the matrix is the authority,
        // not the scan-time verdict stored in the manifest.
        let verdict = validate_path(&entry.path);
        if !verdict.allowed {
            outcomes.push(ExecutionOutcome {
                path: entry.path.clone(),
                status: ExecutionStatus::Blocked,
                detail: Some(format!(
                    "protected: {}",
                    verdict.rule.unwrap_or_default()
                )),
            });
            continue;
        }

        // The file may have vanished since the scan (TOCTOU).
        if !entry.path.exists() {
            outcomes.push(ExecutionOutcome {
                path: entry.path.clone(),
                status: ExecutionStatus::Missing,
                detail: None,
            });
            continue;
        }

        if simulate {
            simulated_bytes += entry.size_bytes;
            outcomes.push(ExecutionOutcome {
                path: entry.path.clone(),
                status: ExecutionStatus::Simulated,
                detail: None,
            });
        } else {
            match stage_with_retry(&entry.path) {
                Ok(()) => {
                    trashed_bytes += entry.size_bytes;
                    outcomes.push(ExecutionOutcome {
                        path: entry.path.clone(),
                        status: ExecutionStatus::Trashed,
                        detail: None,
                    });
                }
                Err(e) => outcomes.push(ExecutionOutcome {
                    path: entry.path.clone(),
                    status: ExecutionStatus::Failed,
                    detail: Some(e.to_string()),
                }),
            }
        }
    }

    outcomes.sort_by(|a, b| a.path.cmp(&b.path));

    Ok(ExecutionReport {
        manifest_id,
        executed_at_unix: unix_now(),
        simulate,
        outcomes,
        trashed_bytes,
        simulated_bytes,
    })
}

/// Stages one path into the trash, retrying **once** on failure: an
/// antivirus scan or search indexer can hold a file for a moment, and one
/// short pause is enough to clear most transient locks. Two strikes and the
/// entry is reported as `Failed` and execution moves on — a single locked
/// file can never stall the run (the failure mode of the old per-file shell
/// API, which hung indefinitely).
fn stage_with_retry(path: &std::path::Path) -> Result<(), super::staging::StageError> {
    match super::staging::delete(path) {
        Ok(()) => Ok(()),
        // A vanished file will not come back — retrying is pointless.
        Err(e @ super::staging::StageError::Missing(_)) => Err(e),
        Err(first) => {
            std::thread::sleep(std::time::Duration::from_millis(200));
            match super::staging::delete(path) {
                Ok(()) => Ok(()),
                Err(_) => Err(first),
            }
        }
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
    use crate::safety::protected::ProtectionVerdict;
    use crate::scanner::{EntryKind, RootScan, ScanEntry, ScanRoot};
    use std::fs;
    use std::path::PathBuf;

    fn fixture_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "freebuff-exec-test-{}-{name}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("create fixture dir");
        dir
    }

    fn scan_entry(path: PathBuf, size: u64, allowed: bool) -> ScanEntry {
        ScanEntry {
            path,
            category: crate::scanner::Category::Temp,
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
                    reason: Some(crate::safety::protected::ProtectionReason::ProtectedDirectory),
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
                    category: crate::scanner::Category::Temp,
                },
                entries,
                errors: Vec::new(),
            }],
        }
    }

    #[test]
    fn unconfirmed_execution_is_rejected() {
        let registry = ManifestRegistry::default();
        let dir = fixture_dir("gated");
        let file = dir.join("junk.tmp");
        fs::write(&file, b"x").expect("write");

        let id = registry.register(&report_with(vec![scan_entry(file.clone(), 1, true)]));
        let err = execute_manifest(&registry, id, false, true).expect_err("must be refused");
        assert!(matches!(err, ExecutionError::NotConfirmed));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn unknown_manifest_is_rejected() {
        let registry = ManifestRegistry::default();
        let err = execute_manifest(&registry, 999, true, true).expect_err("must be refused");
        assert!(matches!(err, ExecutionError::UnknownManifest(999)));
    }

    #[test]
    fn execution_revalidates_every_path() {
        let registry = ManifestRegistry::default();
        let dir = fixture_dir("revalidate");
        let file = dir.join("junk.tmp");
        fs::write(&file, b"0123456789").expect("write");

        // One cleanable fixture file + one planted path the matrix protects.
        #[cfg(windows)]
        let protected = PathBuf::from(r"C:\Windows\System32\kernel32.dll");
        #[cfg(not(windows))]
        let protected = PathBuf::from("/etc/passwd");
        let report = report_with(vec![
            scan_entry(file.clone(), 10, true),
            scan_entry(protected.clone(), 999, true), // scan-time verdict says allowed!
        ]);
        let id = registry.register(&report);

        let out = execute_manifest(&registry, id, true, true).expect("simulated execution");
        assert_eq!(out.status_count(ExecutionStatus::Simulated), 1, "{out:?}");
        assert_eq!(out.status_count(ExecutionStatus::Blocked), 1, "{out:?}");
        let blocked = out
            .outcomes
            .iter()
            .find(|o| o.status == ExecutionStatus::Blocked)
            .expect("blocked outcome");
        assert_eq!(blocked.path, protected);
        assert_eq!(out.simulated_bytes, 10);
        assert!(file.exists(), "simulation must not delete");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn tampered_manifest_is_refused_at_execution() {
        use crate::safety::manifest::{ManifestEntry, MANIFEST_VERSION};

        let registry = ManifestRegistry::default();
        let entry = ManifestEntry {
            path: PathBuf::from(r"some\file.tmp"),
            category: crate::scanner::Category::Temp,
            kind: EntryKind::File,
            file_type: None,
            size_bytes: 10,
            verdict: ProtectionVerdict {
                allowed: true,
                reason: None,
                rule: None,
            },
        };
        // total_bytes lies (999 vs the real sum of 10) — verify must catch it.
        let tampered = crate::safety::manifest::DryRunManifest {
            id: 42,
            version: MANIFEST_VERSION,
            generated_at_unix: 0,
            entries: vec![entry],
            total_bytes: 999,
            cleanable_bytes: 10,
            blocked_count: 0,
        };
        registry.register_manifest(tampered);

        let err = execute_manifest(&registry, 42, true, true).expect_err("must be refused");
        assert!(
            matches!(err, ExecutionError::UnverifiedManifest(42, _)),
            "{err:?}"
        );
    }

    #[test]
    fn recycle_bin_entries_are_always_blocked() {
        let registry = ManifestRegistry::default();
        let dir = fixture_dir("recycle-bin");
        let file = dir.join("junk.tmp");
        fs::write(&file, b"x").expect("write");

        // A hand-made manifest that (maliciously or accidentally) tags a
        // normal deletable file as RecycleBin — execution must still refuse.
        let entry = crate::safety::manifest::ManifestEntry {
            path: file.clone(),
            category: crate::scanner::Category::RecycleBin,
            kind: EntryKind::File,
            file_type: None,
            size_bytes: 1,
            verdict: ProtectionVerdict {
                allowed: true,
                reason: None,
                rule: None,
            },
        };
        let manifest = crate::safety::manifest::DryRunManifest {
            id: 77,
            version: crate::safety::manifest::MANIFEST_VERSION,
            generated_at_unix: 0,
            entries: vec![entry],
            total_bytes: 1,
            cleanable_bytes: 1,
            blocked_count: 0,
        };
        registry.register_manifest(manifest);

        let out = execute_manifest(&registry, 77, true, false).expect("executes");
        assert_eq!(out.status_count(ExecutionStatus::Blocked), 1, "{out:?}");
        assert_eq!(out.trashed_bytes, 0);
        assert!(file.exists(), "recycle bin entries must never be deleted");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn paths_that_vanished_are_reported_missing() {
        let registry = ManifestRegistry::default();
        let dir = fixture_dir("missing");
        let file = dir.join("gone.tmp");
        fs::write(&file, b"x").expect("write");

        let id = registry.register(&report_with(vec![scan_entry(file.clone(), 5, true)]));
        fs::remove_file(&file).expect("remove before executing");

        let out = execute_manifest(&registry, id, true, true).expect("simulated execution");
        assert_eq!(out.status_count(ExecutionStatus::Missing), 1, "{out:?}");

        let _ = fs::remove_dir_all(&dir);
    }
}
