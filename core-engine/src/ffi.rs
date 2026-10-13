//! # C ABI for the mobile shells
//!
//! The Dart and Swift clients cannot call Rust directly, so this module is the
//! entire cross-language surface. It is deliberately thin: every function here
//! wraps a [`crate`] API and serializes the result with `serde_json`. **No
//! cleaning policy lives in this file** — the shells receive exactly the
//! verdicts the core computed, never a second implementation of them.
//!
//! ## Conventions
//!
//! - Every function is `extern "C"`, takes only FFI-safe types, and never
//!   returns a Rust type whose layout could change without a recompile.
//! - Payloads cross as UTF-8 JSON in a heap `CString`. The caller owns it and
//!   must hand it back to [`ks_string_free`]; anything else leaks.
//! - Errors do not cross the boundary as Rust types. They become `null` plus a
//!   message retrievable from [`ks_last_error`], so a Dart `try`/`catch` maps
//!   onto the same shape as a Rust `Result`.
//! - [`ks_version`] is the compatibility probe: the Dart side refuses to bind
//!   against a `MAJOR` it was not built against.
//!
//! # Safety
//!
//! This module is the one place the crate uses `unsafe`, because FFI is by
//! definition an unsafe interface. The rest of the crate stays
//! `#![deny(unsafe_code)]`. Every `unsafe` block below is local and auditable:
//! pointer validation, C-string conversion, and transfer of ownership.

use std::ffi::{c_char, c_int, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

use crate::{
    execute_manifest, plan, scan, validate_path, Category, DryRunManifest, ManifestRegistry,
    PlanOptions, PlatformId,
};

/// ABI version, `<major> * 10000 + <minor> * 100 + <patch>`.
///
/// Bump `major` when a function changes meaning or disappears; bump `minor`
/// when a function is added. Clients compare `major` only.
const ABI_VERSION: c_int = 1_00_00;

/// The major component of [`ABI_VERSION`]. Clients compare this, not the whole
/// number, so a minor addition is not a breaking change.
pub const ABI_VERSION_MAJOR: c_int = ABI_VERSION / 10_000;

/// The library version as a static NUL-terminated string. Never freed.
#[no_mangle]
pub extern "C" fn ks_version() -> *const c_char {
    // A literal containing no interior NUL, so this cannot fail.
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr() as *const c_char
}

/// The ABI version as an integer. See [`ks_version`] for the string form.
#[no_mangle]
pub extern "C" fn ks_abi_version() -> c_int {
    ABI_VERSION
}

/// Frees a string previously returned by this library.
///
/// # Safety
/// `ptr` must be a pointer returned by this library and not yet freed. Passing
/// null is a no-op; passing anything else is undefined behaviour.
#[no_mangle]
pub unsafe extern "C" fn ks_string_free(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    // Safety: the caller contract requires ptr to come from a `CString::into_raw`
    // in this module, which is exactly what `from_raw` expects.
    drop(unsafe { CString::from_raw(ptr) });
}

/// The host platform as a stable integer. See [`ks_platform_name`] for the
/// human-readable form; Dart maps this to its own enum.
#[no_mangle]
pub extern "C" fn ks_platform_id() -> c_int {
    PlatformId::host() as c_int
}

/// The host platform's name as a static string, e.g. `"Android"`.
#[no_mangle]
pub extern "C" fn ks_platform_name() -> *const c_char {
    // `PlatformId::display_name` returns a `&'static str` from a closed set with
    // no interior NUL bytes.
    match PlatformId::host() {
        PlatformId::Windows => c"Windows".as_ptr(),
        PlatformId::MacOs => c"macOS".as_ptr(),
        PlatformId::Linux => c"Linux".as_ptr(),
        PlatformId::Android => c"Android".as_ptr(),
        PlatformId::HardenedAndroid => c"Hardened Android".as_ptr(),
    }
}

// The last error recorded on this thread.
//
// This must be declared exactly once. A second `thread_local!` would create a
// *separate* static, and errors written by one would be invisible to the other
// — every failure would silently report "ok" to the client.
thread_local! {
    static LAST_ERROR: std::cell::RefCell<Option<CString>> = const { std::cell::RefCell::new(None) };
}

/// The message describing the most recent failure on this thread, or `"ok"` if
/// the last call succeeded. Static storage, never freed.
#[no_mangle]
pub extern "C" fn ks_last_error() -> *const c_char {
    LAST_ERROR.with(|cell| match cell.borrow().as_ref() {
        Some(c) => c.as_ptr(),
        None => c"ok".as_ptr(),
    })
}

fn set_last_error(message: &str) {
    // A message with an interior NUL cannot be represented as a CString; the
    // replacement keeps the pointer valid rather than panicking.
    let sanitized = message.replace('\0', " ");
    LAST_ERROR.with(|cell| {
        *cell.borrow_mut() = CString::new(sanitized).ok();
    });
}

/// Runs `f`, converting a success into a JSON string the caller owns and any
/// failure into `null` plus a recorded error message.
///
/// `catch_unwind` is not decoration: a panic unwinding into Dart's or Swift's
/// frames is undefined behaviour, so a panic is converted into a normal error
/// response at the boundary.
fn respond<F>(f: F) -> *mut c_char
where
    F: FnOnce() -> Result<serde_json::Value, String>,
{
    let outcome = catch_unwind(AssertUnwindSafe(f));
    let json = match outcome {
        Ok(Ok(value)) => value,
        Ok(Err(message)) => {
            set_last_error(&message);
            return std::ptr::null_mut();
        }
        Err(_) => {
            set_last_error("core-engine panicked while handling the request");
            return std::ptr::null_mut();
        }
    };

    let text = match serde_json::to_string(&json) {
        Ok(t) => t,
        Err(e) => {
            set_last_error(&format!("failed to serialize response: {e}"));
            return std::ptr::null_mut();
        }
    };

    match CString::new(text) {
        Ok(c) => {
            set_last_error("ok");
            c.into_raw()
        }
        Err(_) => {
            set_last_error("response contained an interior NUL byte");
            std::ptr::null_mut()
        }
    }
}

/// Reads a `#[no_mangle] extern "C"` string argument.
///
/// # Safety
/// `ptr` must be null or a valid NUL-terminated string that stays alive for the
/// duration of this call. Callers are the Dart/Swift marshalling code, which
/// owns the buffer for the whole call.
unsafe fn arg_str<'a>(ptr: *const c_char) -> Result<&'a str, String> {
    if ptr.is_null() {
        return Err("null string argument".to_string());
    }
    // Safety: delegated to the caller contract above.
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map_err(|e| format!("argument is not valid UTF-8: {e}"))
}

/// Validates one path against the protected-path matrix.
///
/// # Safety
/// `path` must be null or a valid NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn ks_audit_path(path: *const c_char) -> *mut c_char {
    let path = match unsafe { arg_str(path) } {
        Ok(p) => p,
        Err(e) => {
            set_last_error(&e);
            return std::ptr::null_mut();
        }
    };
    respond(|| {
        let verdict = validate_path(std::path::Path::new(path));
        Ok(serde_json::json!({
            "path": path,
            "allowed": verdict.allowed,
            "reason": verdict.reason,
            "rule": verdict.rule,
        }))
    })
}

/// Runs a platform scan and returns the full [`ScanReport`](crate::ScanReport)
/// as JSON. Read-only: nothing is modified.
///
/// # Safety
/// This function takes no pointer arguments and is safe to call, but the
/// returned string must still be released with [`ks_string_free`].
#[no_mangle]
pub extern "C" fn ks_scan_json() -> *mut c_char {
    respond(|| Ok(serde_json::to_value(scan()).map_err(|e| e.to_string())?))
}

/// Runs a scan and returns the executor's cleanup plan as JSON — what may be
/// cleaned and what was declined, with a reason for every decline.
///
/// `categories_json` is a JSON array of category names (e.g. `["Temp"]`), or
/// null for a "smart clean" over the profile's routine categories.
/// `include_recent` non-zero ignores the per-category age floors. Nothing else
/// is relaxed: manual-only, unsupported, and matrix-blocked candidates stay
/// excluded either way.
///
/// # Safety
/// `categories_json` must be null or a valid NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn ks_plan_json(
    categories_json: *const c_char,
    include_recent: c_int,
) -> *mut c_char {
    let selected = if categories_json.is_null() {
        None
    } else {
        let raw = match unsafe { arg_str(categories_json) } {
            Ok(s) => s,
            Err(e) => {
                set_last_error(&e);
                return std::ptr::null_mut();
            }
        };
        match parse_categories(raw) {
            Ok(cats) => Some(cats),
            Err(e) => {
                set_last_error(&e);
                return std::ptr::null_mut();
            }
        }
    };

    respond(|| {
        let now = unix_now();
        let mut options = match selected.clone() {
            Some(cats) => PlanOptions::selecting(now, cats),
            None => PlanOptions::smart_clean(now),
        };
        if include_recent != 0 {
            options = options.including_recent();
        }
        let report = scan();
        let cleanup = plan(&report, &options);
        Ok(serde_json::json!({
            "platform": cleanup.platform,
            "generated_at_unix": cleanup.generated_at_unix,
            "eligible": cleanup.eligible,
            "skipped": cleanup.skipped,
            "needs_elevation": cleanup.needs_elevation,
            "eligible_count": cleanup.eligible_count(),
            "eligible_bytes": cleanup.eligible_bytes(),
            "skipped_count": cleanup.skipped_count(),
            "skipped_bytes_by_reason": cleanup
                .skipped_bytes_by_reason()
                .into_iter()
                .map(|(reason, bytes)| serde_json::json!({
                    "reason": reason,
                    "message": reason.message(),
                    "permanent": reason.is_permanent(),
                    "bytes": bytes,
                }))
                .collect::<Vec<_>>(),
        }))
    })
}

/// Parses a JSON array of category names. An empty array means "no explicit
/// selection", matching the CLI.
fn parse_categories(raw: &str) -> Result<Vec<Category>, String> {
    let names: Vec<String> = serde_json::from_str(raw)
        .map_err(|e| format!("categories must be a JSON array of strings: {e}"))?;
    names
        .iter()
        .map(|n| match n.as_str() {
            "Temp" => Ok(Category::Temp),
            "Cache" => Ok(Category::Cache),
            "Logs" => Ok(Category::Logs),
            "PackageCache" => Ok(Category::PackageCache),
            "Prefetch" => Ok(Category::Prefetch),
            "BrowserCache" => Ok(Category::BrowserCache),
            "SiteStorage" => Ok(Category::SiteStorage),
            "AppOrphan" => Ok(Category::AppOrphan),
            "AiModels" => Ok(Category::AiModels),
            "RecycleBin" => Ok(Category::RecycleBin),
            other => Err(format!("unknown category: {other}")),
        })
        .collect()
}

/// Freezes the current host platform's eligible set into a manifest and returns
/// it as JSON, including the id needed by [`ks_execute_manifest`].
///
/// `categories_json` and `include_recent` behave as in [`ks_plan_json`].
///
/// # Safety
/// `categories_json` must be null or a valid NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn ks_build_manifest_json(
    categories_json: *const c_char,
    include_recent: c_int,
) -> *mut c_char {
    let selected = if categories_json.is_null() {
        None
    } else {
        let raw = match unsafe { arg_str(categories_json) } {
            Ok(s) => s,
            Err(e) => {
                set_last_error(&e);
                return std::ptr::null_mut();
            }
        };
        match parse_categories(raw) {
            Ok(cats) => Some(cats),
            Err(e) => {
                set_last_error(&e);
                return std::ptr::null_mut();
            }
        }
    };

    respond(|| {
        let now = unix_now();
        let mut options = match selected {
            Some(cats) => PlanOptions::selecting(now, cats),
            None => PlanOptions::smart_clean(now),
        };
        if include_recent != 0 {
            options = options.including_recent();
        }
        let report = scan();
        let cleanup = plan(&report, &options);
        // The registry is process-global and lives for the call: the manifest
        // is serialized out, and execution re-registers it from that JSON.
        let registry = ManifestRegistry::default();
        let id = registry.register(&cleanup.to_scan_report());
        let manifest = registry
            .get(id)
            .ok_or_else(|| format!("manifest #{id} vanished from the registry"))?;
        Ok(serde_json::to_value(manifest).map_err(|e| e.to_string())?)
    })
}

/// Executes a previously built manifest and returns the
/// [`ExecutionReport`](crate::ExecutionReport) as JSON.
///
/// `manifest_json` must be the exact JSON produced by [`ks_build_manifest_json`].
/// `simulate` non-zero performs a dry run and changes nothing; zero actually
/// stages the files into the OS trash, which is recoverable.
///
/// Execution re-validates every path against the protected-path matrix, so a
/// manifest edited between build and execute cannot smuggle a protected path
/// through.
///
/// # Safety
/// `manifest_json` must be a valid NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn ks_execute_manifest(
    manifest_json: *const c_char,
    simulate: c_int,
) -> *mut c_char {
    let raw = match unsafe { arg_str(manifest_json) } {
        Ok(s) => s,
        Err(e) => {
            set_last_error(&e);
            return std::ptr::null_mut();
        }
    };

    respond(|| {
        let manifest = DryRunManifest::from_json(raw).map_err(|e| format!("invalid manifest: {e}"))?;
        let id = manifest.id;
        manifest
            .verify()
            .map_err(|e| format!("manifest verification failed, refusing to execute: {e}"))?;

        let registry = ManifestRegistry::default();
        registry.register_manifest(manifest);

        let report = execute_manifest(&registry, id, true, simulate != 0)
            .map_err(|e| e.to_string())?;
        Ok(serde_json::json!({
            "simulated": simulate != 0,
            "trashed_bytes": report.trashed_bytes,
            "simulated_bytes": report.simulated_bytes,
            "outcomes": report.outcomes.iter().map(|o| serde_json::json!({
                "path": o.path,
                "status": o.status,
                "detail": o.detail,
            })).collect::<Vec<_>>(),
        }))
    })
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

    /// Reads a returned C string and releases it, which is exactly the
    /// ownership dance the Dart side performs.
    unsafe fn take(ptr: *mut c_char) -> Option<String> {
        if ptr.is_null() {
            return None;
        }
        // Safety: every non-null pointer from this module came from
        // `CString::into_raw`, and this is its single matching `from_raw`.
        let text = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_string();
        unsafe { ks_string_free(ptr) };
        Some(text)
    }

    /// Fails loudly if a previous test left an error recorded, so one failure
    /// cannot silently colour the next test's assertion.
    fn expect_ok() {
        let last = unsafe { CStr::from_ptr(ks_last_error()) };
        assert_eq!(last.to_str().unwrap(), "ok", "stale error from a prior call");
    }

    #[test]
    fn abi_version_is_readable_and_stable() {
        assert_eq!(ks_abi_version(), ABI_VERSION);
        let major = ABI_VERSION / 10_000;
        assert_eq!(major, ABI_VERSION_MAJOR);
        let version = unsafe { CStr::from_ptr(ks_version()) };
        assert_eq!(version.to_str().unwrap(), env!("CARGO_PKG_VERSION"));
    }

    #[test]
    fn platform_identity_is_consistent() {
        let id = ks_platform_id();
        assert!(id >= PlatformId::Windows as c_int, "unexpected platform id {id}");
        let name = unsafe { CStr::from_ptr(ks_platform_name()) }.to_str().unwrap();
        assert!(!name.is_empty());
    }

    #[test]
    fn audit_returns_a_verdict_for_a_valid_path() {
        // Safety: static NUL-terminated literals.
        let ptr = unsafe { ks_audit_path(c"/tmp/probe.tmp".as_ptr()) };
        let json = unsafe { take(ptr) }.expect("audit should succeed");
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(value["path"], "/tmp/probe.tmp");
        assert!(value["allowed"].is_boolean(), "{value}");
        expect_ok();
    }

    #[test]
    fn a_null_argument_is_an_error_not_a_crash() {
        // Safety: null is the documented "absent" sentinel, not a wild pointer.
        let ptr = unsafe { ks_audit_path(std::ptr::null()) };
        assert!(ptr.is_null(), "a null argument must not return a result");
        let last = unsafe { CStr::from_ptr(ks_last_error()) };
        assert!(last.to_str().unwrap().contains("null string argument"));
    }

    #[test]
    fn category_names_match_the_core_enum() {
        // Every variant must be reachable by name, or a shell cannot select it.
        let all = [
            Category::Temp,
            Category::Cache,
            Category::Logs,
            Category::PackageCache,
            Category::Prefetch,
            Category::BrowserCache,
            Category::SiteStorage,
            Category::AppOrphan,
            Category::AiModels,
            Category::RecycleBin,
        ];
        let names: Vec<String> = all
            .iter()
            .map(|c| serde_json::to_value(c).unwrap().as_str().unwrap().to_string())
            .collect();
        let parsed = parse_categories(&serde_json::to_string(&names).unwrap()).unwrap();
        assert_eq!(parsed, all);
    }

    #[test]
    fn an_unknown_category_is_rejected_by_name() {
        let err = parse_categories(r#"["Temp","Nope"]"#).unwrap_err();
        assert!(err.contains("Nope"), "{err}");
    }

    #[test]
    fn malformed_category_json_is_rejected() {
        assert!(parse_categories("not json").is_err());
        assert!(parse_categories("[1,2,3]").is_err());
    }

    #[test]
    fn a_manifest_that_is_not_a_manifest_is_refused() {
        let bad = CString::new("{\"version\":999}").unwrap();
        // Safety: `bad` outlives the call.
        let ptr = unsafe { ks_execute_manifest(bad.as_ptr(), 1) };
        assert!(ptr.is_null(), "a bogus manifest must not execute");
        let last = unsafe { CStr::from_ptr(ks_last_error()) };
        assert!(last.to_str().unwrap().contains("invalid manifest"));
    }
}
