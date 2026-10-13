//! Fail-safe & safety layer (Phase 2).
//!
//! No cleaning operation may execute until it has passed every gate in this
//! layer:
//!
//! 1. [`protected`] — Protected Path Validation: a compile-time blocklist of
//!    system-critical paths; anything inside them is denied.
//! 2. [`manifest`] — Dry-run manifest engine: every cleanup first freezes a
//!    versioned, JSON-serializable manifest of targeted paths, computed
//!    sizes, file types, categories, and protection verdicts. Manifests are
//!    written to / loaded from disk ([`DryRunManifest::to_file`] /
//!    [`DryRunManifest::from_file`]) and must pass [`DryRunManifest::verify`]
//!    (version, totals, ordering, duplicates) before execution accepts them.
//! 3. [`execution`] — Gated execution: an unverified or unconfirmed
//!    execution is refused, every path is re-validated against the matrix at
//!    execution time, and files are staged through the OS recycle bin / trash
//!    (or simulated).
//! 4. [`staging`] — the trash move itself: filesystem-level `$I`/`$R`
//!    staging on Windows (locked files fail fast instead of hanging the
//!    run), the `trash` crate elsewhere.
//! 5. [`trash`] — Empty Recycle Bin: the one permanent operation. Fixed to
//!    the current user's OS trash, refused without explicit confirmation, and
//!    implemented in safe Rust only (std `fs` on macOS/Linux, the shell's
//!    `Clear-RecycleBin` on Windows).

pub mod execution;
pub mod manifest;
pub mod protected;
pub mod staging;
pub mod trash;
