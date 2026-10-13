//! # core-engine
//!
//! The single source of truth for KernSifter's space-management and
//! cleaning logic. Decoupled by design: desktop (Tauri) and mobile (Flutter)
//! shells bind to this crate and never re-implement cleanup behavior.
//!
//! The crate is compiled per-target (Windows / macOS / Linux / Android /
//! hardened Android); [`cfg`] gates inside modules select the platform-specific
//! execution path, while the safety layer applies on every platform.
//!
//! ## Safety-first layout
//!
//! - [`safety::protected`] — the Protected Directory Matrix and the validation
//!   gate every destructive operation must pass.
//! - [`scanner`] — Phase 1 multi-threaded scanners (walkdir + rayon) over
//!   per-platform sanctioned roots; every candidate carries its own verdict.
//! - [`platform`] — Phase 1 platform executors: the per-OS policy that decides
//!   what may be done with a scanned candidate (routine vs. explicit vs.
//!   manual), how old it must be, and whether it needs an elevated process.
//! - [`safety::manifest`] — the dry-run manifest engine: nothing is executed
//!   without a reviewed, JSON-serializable manifest.
//! - [`safety::execution`] — gated execution: re-validates every path against
//!   the matrix at execution time and stages files through the OS trash.
//! - [`safety::trash`] — the one permanent operation: emptying the OS recycle
//!   bin, fixed to the current user's trash and refused without explicit
//!   confirmation.
//! - [`ffi`] — the C ABI the mobile shells bind to. Every function is a thin
//!   JSON-returning wrapper over an API above; no policy is defined here.

#![deny(unsafe_code)]
#![warn(missing_docs)]

pub mod platform;
pub mod safety;
pub mod scanner;

/// The cross-language surface for the mobile clients.
///
/// This is the only module permitted to use `unsafe` (via a local
/// `#[allow]`, since the crate-level attribute is `deny`, not `forbid`): an FFI
/// boundary is unsafe by definition. Keep it a shim — wrap a core API,
/// serialize, return. The moment a decision gets made in this file, it is a
/// second implementation of the safety model.
#[allow(unsafe_code)]
pub mod ffi;

pub use safety::execution::{
    ExecutionError, ExecutionOutcome, ExecutionReport, ExecutionStatus, execute_manifest,
};
pub use safety::manifest::{
    DryRunManifest, ManifestEntry, ManifestError, ManifestRegistry, MANIFEST_VERSION, build_manifest,
};
pub use safety::protected::{
    ProtectionReason, ProtectionVerdict, ProtectedMatrix, validate_path,
};
pub use safety::staging::StageError;
pub use safety::trash::{
    DirSummary, EmptyTrashReport, ExtensionSummary, RecycleBinSummary, TrashError, TrashFile,
    empty_recycle_bin, recycle_bin_summary,
};
pub use platform::{
    CategoryPolicy, CleanupPlan, Confirmation, PlanOptions, PlatformId, PlatformProfile, SkipReason,
    SkippedEntry, all_profiles, plan, plan_for, profile,
};
pub use scanner::{
    Category, EntryKind, RootScan, ScanEntry, ScanReport, ScanRoot, platform_roots, scan,
    scan_roots,
};
