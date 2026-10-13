//! # Protected Path Validation
//!
//! The **Protected Directory Matrix** — an immutable blocklist of
//! system-critical paths, compiled into the binary per target OS. Every path a
//! cleaning operation wants to delete, move, or truncate must first pass
//! [`ProtectedMatrix::validate`] (or the global convenience
//! [`validate_path`]); anything that is, or descends from, a protected entry is
//! denied before it can reach the execution layer.
//!
//! ## Rule model
//!
//! Rules come in two flavours:
//!
//! - `Exact` — the path itself is untouchable (e.g. `C:\pagefile.sys`, the
//!   user's profile root, the `/home` container).
//! - `Prefix` — the path **and everything beneath it** is untouchable, except
//!   explicit `carve_outs` (e.g. `/var` is protected, but
//!   `/var/cache/apt/archives` and `/var/tmp` are sanctioned cleanup targets).
//!
//! Carve-outs are what let the matrix express the cleaning spec itself: the
//! scanner is allowed to reach `C:\Windows\Temp`, `C:\Windows\Prefetch`,
//! `%LocalAppData%\Temp`, `~/Library/Caches`, `/Library/Caches`,
//! `~/Library/Logs`, and the Linux package caches — while everything else in
//! those trees stays blocked.
//!
//! ## Enforcement details
//!
//! Before comparison, a candidate path is:
//!
//! 1. **Normalized lexically** — `.` and `..` segments are resolved without
//!    touching the filesystem, so `C:\Windows\..\Windows\System32` cannot
//!    evade the matrix.
//! 2. **Canonicalized when it exists** — symlinks are resolved (on macOS,
//!    `/etc` and `/var` resolve into `/private/...`; on Windows the `\\?\`
//!    verbatim prefix is stripped).
//! 3. **Compared component-wise** against every rule, case-insensitively on
//!    Windows and macOS (their default filesystems are case-insensitive),
//!    case-sensitively on Linux/Android.
//!
//! The verdict is deterministic and serializable, so it can be embedded in the
//! Phase 2 dry-run JSON manifest.
//!
//! ## Scope
//!
//! This gate protects against *wholesale destruction* of system paths. It is
//! one of three independent safety layers (see [`crate::safety`]); the scanner
//! whitelists and the dry-run manifest are the others. On Android, the matrix
//! is intentionally empty — the app sandbox and the Storage Access Framework
//! (SAF) are the OS-enforced boundary, and every deletable path arrives as an
//! explicitly user-granted document tree.

use std::path::{Component, Path, PathBuf};
use std::sync::{OnceLock, RwLock};

use serde::{Deserialize, Serialize};

/// Additional paths the scanner discovered at runtime that must be carved
/// out of protected prefix rules (e.g. browser cache directories inside the
/// otherwise-protected `%LocalAppData%` tree). Registered before any path
/// validation runs; registrations accumulate, so one caller (the scanner, the
/// orphan detector, a sanctioned Android grant) cannot silently discard what
/// another already carved out.
static ADDITIONAL_CARVEOUTS: OnceLock<RwLock<Vec<PathBuf>>> = OnceLock::new();

/// Register paths discovered at runtime as carve-outs from protected
/// directories. Call before [`ProtectedMatrix::current`] or [`validate_path`]
/// is used; each call unions with the carve-outs already registered.
///
/// On Windows the paths are added as carve-outs to the `%LocalAppData%`
/// prefix rule, allowing the scanner to reach browser caches, npm archives,
/// Electron temp directories, and AI model downloads that live deep inside
/// the protected user-data tree.
pub fn register_carveouts(paths: &[PathBuf]) {
    let registered = ADDITIONAL_CARVEOUTS.get_or_init(|| RwLock::new(Vec::new()));
    let mut known = registered
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    for path in paths {
        if !known.iter().any(|seen| seen == path) {
            known.push(path.clone());
        }
    }
}

/// Why a path was denied.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ProtectionReason {
    /// The path is a filesystem root (`/`, `C:\`, UNC share root) — never deletable.
    FilesystemRoot,
    /// The path is, or lives inside, a system-critical protected directory.
    ProtectedDirectory,
    /// The path is an explicitly protected system file (e.g. `pagefile.sys`).
    ProtectedFile,
    /// The path is empty / carries no meaning and cannot be acted on.
    InvalidPath,
}

/// Outcome of a [`ProtectedMatrix::validate`] check.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProtectionVerdict {
    /// `true` when the path is safe to pass to the execution layer.
    pub allowed: bool,
    /// Populated when `allowed == false`.
    pub reason: Option<ProtectionReason>,
    /// Human-readable description of the rule that blocked the path
    /// (useful for the dry-run manifest and the UI).
    pub rule: Option<String>,
}

/// How a [`Rule`] matches a candidate path.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RuleKind {
    /// Blocks only the exact path.
    Exact,
    /// Blocks the path and all descendants, minus `carve_outs`.
    Prefix,
}

/// A single entry in the protected-path matrix.
#[derive(Debug, Clone)]
struct Rule {
    kind: RuleKind,
    /// Human-readable description surfaced in verdicts/manifests.
    display: &'static str,
    /// Normalized path components of the protected path.
    components: Vec<String>,
    /// `Prefix` rules only: descendants explicitly allowed for cleaning.
    carve_outs: Vec<Vec<String>>,
    /// `Exact` rules only: `true` if this names a file rather than a directory.
    is_file: bool,
}

/// Immutable, platform-aware protected-path matrix.
///
/// Built once via [`ProtectedMatrix::current`]; the per-OS rule tables are
/// selected at compile time with `#[cfg]`, and the current user's home
/// directory is injected at construction. The matrix exposes no mutation, so a
/// constructed matrix is a fixed contract for the lifetime of the process.
#[derive(Debug, Clone)]
pub struct ProtectedMatrix {
    rules: Vec<Rule>,
}

impl ProtectedMatrix {
    /// Builds the matrix for the host OS, injecting the current user's home
    /// directory (its profile root is protected on every platform).
    pub fn current() -> Self {
        let mut rules = platform_rules();

        // The user's own profile root must never be deleted, on any OS.
        let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("/"));
        rules.push(rule(
            RuleKind::Exact,
            "user profile root",
            &home.to_string_lossy(),
            &[],
            false,
        ));

        // Windows: %LocalAppData% is protected except the sanctioned %TEMP%
        // and any runtime-discovered deep-scan directories (browser caches,
        // npm, Electron temp, AI models, etc.).
        #[cfg(windows)]
        if let Some(h) = home.to_str() {
            let local = format!("{h}\\AppData\\Local");
            let local_temp = format!("{h}\\AppData\\Local\\Temp");
            let mut carve_outs: Vec<String> = vec![local_temp];
            if let Some(extra) = ADDITIONAL_CARVEOUTS.get() {
                let extra = extra
                    .read()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                for p in extra.iter() {
                    carve_outs.push(p.to_string_lossy().into_owned());
                }
            }
            let carve_refs: Vec<&str> = carve_outs.iter().map(|s| s.as_str()).collect();
            rules.push(rule(
                RuleKind::Prefix,
                "local app data",
                &local,
                &carve_refs,
                false,
            ));
        }

        // macOS: ~/Library is protected except Caches, Logs, and any
        // runtime-discovered deep-scan directories (browser profiles under
        // Application Support, Electron app caches, etc.).
        #[cfg(target_os = "macos")]
        if let Some(h) = home.to_str() {
            let library = format!("{h}/Library");
            let caches = format!("{h}/Library/Caches");
            let logs = format!("{h}/Library/Logs");
            let mut carve_outs: Vec<String> = vec![caches, logs];
            if let Some(extra) = ADDITIONAL_CARVEOUTS.get() {
                let extra = extra
                    .read()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                for p in extra.iter() {
                    carve_outs.push(p.to_string_lossy().into_owned());
                }
            }
            let carve_refs: Vec<&str> = carve_outs.iter().map(|s| s.as_str()).collect();
            rules.push(rule(
                RuleKind::Prefix,
                "user Library",
                &library,
                &carve_refs,
                false,
            ));

            // Finder trash: surfaced for visibility, never deletable.
            let trash = format!("{h}/.Trash");
            rules.push(rule(
                RuleKind::Prefix,
                "user Trash",
                &trash,
                &[],
                false,
            ));
        }

        // Linux: the XDG trash tree (~/.local/share/Trash) is surfaced for
        // visibility but never deletable (removing from trash is permanent).
        #[cfg(all(unix, not(target_os = "macos"), not(target_os = "android")))]
        if let Some(h) = home.to_str() {
            let trash = format!("{h}/.local/share/Trash");
            rules.push(rule(
                RuleKind::Prefix,
                "user Trash",
                &trash,
                &[],
                false,
            ));
        }

        Self { rules }
    }

    /// Validates a candidate path against the matrix.
    ///
    /// Returns a [`ProtectionVerdict`]; only `allowed == true` paths may be
    /// passed to the deletion/execution layer.
    pub fn validate<P: AsRef<Path>>(&self, path: P) -> ProtectionVerdict {
        let raw = path.as_ref();

        // Empty paths carry no meaning — deny outright.
        if raw.as_os_str().is_empty() {
            return deny(ProtectionReason::InvalidPath, "<empty path>");
        }

        // 1. Lexical normalization: resolve `.` / `..` without touching the FS.
        let mut normalized = normalize(raw);

        // 2. Canonicalize (resolves symlinks, makes paths absolute) when the
        //    path exists; otherwise fall back to cwd-resolution for relative
        //    paths.
        if normalized.is_relative() {
            if let Ok(c) = std::fs::canonicalize(raw) {
                normalized = strip_verbatim(c);
            } else if let Ok(cwd) = std::env::current_dir() {
                normalized = normalize(&cwd.join(raw));
            }
        } else if let Ok(c) = std::fs::canonicalize(&normalized) {
            normalized = strip_verbatim(c);
        }

        // 3. Filesystem roots are never deletable, whatever the OS.
        if is_fs_root(&normalized) {
            return deny(ProtectionReason::FilesystemRoot, "filesystem root");
        }

        let components = split_components(&normalized);
        if components.is_empty() {
            return deny(ProtectionReason::InvalidPath, "<empty path>");
        }

        // 4. Walk the matrix. Specific rules are listed before broad ones so
        //    the verdict names the most precise blocker.
        for r in &self.rules {
            match r.kind {
                RuleKind::Exact => {
                    if components == r.components {
                        let reason = if r.is_file {
                            ProtectionReason::ProtectedFile
                        } else {
                            ProtectionReason::ProtectedDirectory
                        };
                        return deny(reason, r.display);
                    }
                }
                RuleKind::Prefix => {
                    if is_within(&components, &r.components) {
                        let carved_out = r
                            .carve_outs
                            .iter()
                            .any(|c| is_within(&components, c));
                        if !carved_out {
                            return deny(ProtectionReason::ProtectedDirectory, r.display);
                        }
                    }
                }
            }
        }

        ProtectionVerdict {
            allowed: true,
            reason: None,
            rule: None,
        }
    }
}

/// Global convenience validator. Builds a fresh [`ProtectedMatrix`] on every
/// call (construction is cheap — a handful of string allocations). When the
/// scanner has registered additional carve-outs via [`register_carveouts`]
/// those paths are automatically included.
pub fn validate_path<P: AsRef<Path>>(path: P) -> ProtectionVerdict {
    ProtectedMatrix::current().validate(path)
}

fn deny(reason: ProtectionReason, rule: &'static str) -> ProtectionVerdict {
    ProtectionVerdict {
        allowed: false,
        reason: Some(reason),
        rule: Some(rule.to_string()),
    }
}

fn rule(
    kind: RuleKind,
    display: &'static str,
    path: &str,
    carve_outs: &[&str],
    is_file: bool,
) -> Rule {
    Rule {
        kind,
        display,
        components: split_components(Path::new(path)),
        carve_outs: carve_outs
            .iter()
            .map(|c| split_components(Path::new(c)))
            .collect(),
        is_file,
    }
}

/// Per-OS rule tables. Only the table for the compiling target exists.
#[cfg(windows)]
fn platform_rules() -> Vec<Rule> {
    use RuleKind::{Exact, Prefix};
    // Order matters: specific rules first, so verdicts name the precise blocker.
    vec![
        rule(Exact, "C:\\pagefile.sys", "C:\\pagefile.sys", &[], true),
        rule(Exact, "C:\\hiberfil.sys", "C:\\hiberfil.sys", &[], true),
        rule(Exact, "C:\\swapfile.sys", "C:\\swapfile.sys", &[], true),
        rule(Prefix, "C:\\Windows\\System32", "C:\\Windows\\System32", &[], false),
        rule(Prefix, "C:\\Windows\\SysWOW64", "C:\\Windows\\SysWOW64", &[], false),
        rule(Prefix, "C:\\Program Files", "C:\\Program Files", &[], false),
        rule(Prefix, "C:\\Program Files (x86)", "C:\\Program Files (x86)", &[], false),
        rule(Prefix, "C:\\ProgramData", "C:\\ProgramData", &[], false),
        rule(
            Prefix,
            "C:\\System Volume Information",
            "C:\\System Volume Information",
            &[],
            false,
        ),
        rule(Prefix, "C:\\boot", "C:\\boot", &[], false),
        rule(Prefix, "C:\\Recovery", "C:\\Recovery", &[], false),
        // The recycle bin is never deletable: removing from the trash is a
        // permanent delete with no recoverable step. The scanner surfaces its
        // contents (scan-only category) but every entry is denied here.
        rule(Prefix, "C:\\$Recycle.Bin", "C:\\$Recycle.Bin", &[], false),
        rule(Exact, "C:\\Users", "C:\\Users", &[], false),
        // Broad Windows tree, with the sanctioned cleanup targets carved out
        // (C:\Windows\Temp and the Prefetch app-launch trace cache).
        rule(
            Prefix,
            "C:\\Windows",
            "C:\\Windows",
            &["C:\\Windows\\Temp", "C:\\Windows\\Prefetch"],
            false,
        ),
    ]
}

#[cfg(target_os = "macos")]
fn platform_rules() -> Vec<Rule> {
    use RuleKind::{Exact, Prefix};
    vec![
        rule(Prefix, "/System", "/System", &[], false),
        // /Library is protected; the system-wide Caches dir is a cleanup target.
        rule(Prefix, "/Library", "/Library", &["/Library/Caches"], false),
        // /etc and /var are symlinks into /private — covering /private covers both.
        rule(Prefix, "/private", "/private", &[], false),
        rule(Prefix, "/usr", "/usr", &[], false),
        rule(Prefix, "/bin", "/bin", &[], false),
        rule(Prefix, "/sbin", "/sbin", &[], false),
        rule(Prefix, "/etc", "/etc", &[], false),
        rule(Exact, "/Users", "/Users", &[], false),
        rule(Exact, "/Volumes", "/Volumes", &[], false),
    ]
}

#[cfg(all(unix, not(target_os = "macos"), not(target_os = "android")))]
fn platform_rules() -> Vec<Rule> {
    use RuleKind::{Exact, Prefix};
    vec![
        rule(Prefix, "/boot", "/boot", &[], false),
        rule(Prefix, "/etc", "/etc", &[], false),
        rule(Prefix, "/usr", "/usr", &[], false),
        rule(Prefix, "/bin", "/bin", &[], false),
        rule(Prefix, "/sbin", "/sbin", &[], false),
        rule(Prefix, "/lib", "/lib", &[], false),
        rule(Prefix, "/lib64", "/lib64", &[], false),
        rule(Prefix, "/proc", "/proc", &[], false),
        rule(Prefix, "/sys", "/sys", &[], false),
        rule(Prefix, "/dev", "/dev", &[], false),
        rule(Prefix, "/run", "/run", &[], false),
        // /var is protected; package-manager caches and /var/tmp are targets.
        rule(
            Prefix,
            "/var",
            "/var",
            &["/var/cache/apt/archives", "/var/cache/dnf", "/var/tmp"],
            false,
        ),
        rule(Exact, "/home", "/home", &[], false),
        rule(Exact, "/root", "/root", &[], false),
    ]
}

/// Hardened Android (GrapheneOS / CalyxOS) and standard AOSP: the OS sandbox
/// and the Storage Access Framework are the enforcement boundary. The app only
/// ever addresses paths inside user-granted document trees, so the matrix is
/// intentionally empty — the immutable guard rails are provided by the OS.
#[cfg(target_os = "android")]
fn platform_rules() -> Vec<Rule> {
    Vec::new()
}

/// Splits a path into its component strings (drive prefix / root / segments).
///
/// `CurDir`/`ParentDir` components are never expected here (callers normalize
/// first), but they are mapped to literal strings for exhaustive matching.
fn split_components(p: &Path) -> Vec<String> {
    p.components()
        .map(|c| match c {
            Component::Prefix(pr) => pr.as_os_str().to_string_lossy().into_owned(),
            Component::RootDir => "/".to_string(),
            Component::CurDir => ".".to_string(),
            Component::ParentDir => "..".to_string(),
            Component::Normal(s) => s.to_string_lossy().into_owned(),
        })
        .collect()
}

/// Lexically resolves `.` and `..` segments without touching the filesystem.
///
/// `..` cannot escape the root/prefix: `PathBuf::pop` is a no-op at the root.
fn normalize(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// Compares two path components with the host filesystem's default case rules:
/// case-insensitive on Windows and macOS, case-sensitive elsewhere.
#[inline]
pub(crate) fn comp_eq(a: &str, b: &str) -> bool {
    #[cfg(any(windows, target_os = "macos"))]
    {
        a.eq_ignore_ascii_case(b)
    }
    #[cfg(not(any(windows, target_os = "macos")))]
    {
        a == b
    }
}

/// `true` when `candidate` equals `rule` or descends from it (element-wise).
fn is_within(candidate: &[String], rule: &[String]) -> bool {
    candidate.len() >= rule.len()
        && candidate[..rule.len()]
            .iter()
            .zip(rule)
            .all(|(a, b)| comp_eq(a, b))
}

/// `true` when the path is a filesystem root (`/`, `C:\`, UNC share root).
fn is_fs_root(p: &Path) -> bool {
    #[cfg(windows)]
    {
        let mut it = p.components();
        matches!(it.next(), Some(Component::Prefix(_)))
            && matches!(it.next(), Some(Component::RootDir))
            && it.next().is_none()
    }
    #[cfg(not(windows))]
    {
        p.is_absolute() && p.components().count() == 1
    }
}

/// Windows `std::fs::canonicalize` prepends the `\\?\` verbatim prefix; strip
/// it so comparisons stay clean. No-op on other platforms.
#[cfg(windows)]
fn strip_verbatim(p: PathBuf) -> PathBuf {
    let s = p.to_string_lossy();
    match s.strip_prefix(r"\\?\") {
        Some(rest) => PathBuf::from(rest),
        None => p,
    }
}

#[cfg(not(windows))]
fn strip_verbatim(p: PathBuf) -> PathBuf {
    p
}

#[cfg(test)]
mod tests {
    use super::*;

    fn verdict(p: &str) -> ProtectionVerdict {
        validate_path(Path::new(p))
    }

    #[test]
    fn empty_path_is_rejected() {
        let v = verdict("");
        assert!(!v.allowed);
        assert_eq!(v.reason, Some(ProtectionReason::InvalidPath));
    }

    #[test]
    fn parent_traversal_cannot_escape_the_matrix() {
        #[cfg(windows)]
        {
            let v = verdict(r"C:\Windows\..\Windows\System32\cmd.exe");
            assert!(!v.allowed, "{v:?}");
        }
        #[cfg(not(windows))]
        {
            let v = verdict("/etc/../etc/passwd");
            assert!(!v.allowed, "{v:?}");
        }
    }

    #[test]
    fn dot_segments_do_not_change_the_outcome() {
        #[cfg(windows)]
        {
            assert!(verdict(r"C:\Windows\Temp\.\foo.tmp").allowed);
        }
        #[cfg(not(windows))]
        {
            assert!(verdict("/var/cache/./apt/archives/foo.deb").allowed);
        }
    }

    #[test]
    fn filesystem_roots_are_always_blocked() {
        #[cfg(windows)]
        {
            assert!(!verdict(r"C:\").allowed);
            assert!(!verdict(r"D:\").allowed);
        }
        #[cfg(not(windows))]
        {
            assert!(!verdict("/").allowed);
        }
    }

    #[test]
    fn verdict_serializes_into_the_manifest_shape() {
        let v = ProtectionVerdict {
            allowed: false,
            reason: Some(ProtectionReason::ProtectedDirectory),
            rule: Some("/etc".to_string()),
        };
        let json = serde_json::to_string(&v).expect("verdict must serialize");
        assert!(json.contains("\"allowed\":false"), "{json}");
        assert!(json.contains("\"ProtectedDirectory\""), "{json}");
    }

    // ── Windows ────────────────────────────────────────────────────────────

    #[cfg(windows)]
    #[test]
    fn windows_system32_is_blocked() {
        let v = verdict(r"C:\Windows\System32\kernel32.dll");
        assert!(!v.allowed);
        assert_eq!(v.reason, Some(ProtectionReason::ProtectedDirectory));
        assert_eq!(v.rule.as_deref(), Some("C:\\Windows\\System32"));
    }

    #[cfg(windows)]
    #[test]
    fn windows_temps_are_allowed() {
        assert!(verdict(r"C:\Windows\Temp\setup.log").allowed);
        let home = dirs::home_dir().expect("home dir");
        let temp = home
            .join("AppData")
            .join("Local")
            .join("Temp")
            .join("junk.tmp");
        assert!(validate_path(&temp).allowed, "{temp:?}");
    }

    #[cfg(windows)]
    #[test]
    fn windows_prefetch_is_cleanable() {
        assert!(verdict(r"C:\Windows\Prefetch").allowed);
        assert!(verdict(r"C:\Windows\Prefetch\APP.EXE-ABC123.pf").allowed);
        // ...but nothing else under C:\Windows escapes the matrix.
        assert!(!verdict(r"C:\Windows\System32\config\SAM").allowed);
        assert!(!verdict(r"C:\Windows\WinSxS\amd64_microsoft-windows\x.dll").allowed);
    }

    #[cfg(windows)]
    #[test]
    fn windows_install_locations_are_blocked() {
        assert!(!verdict(r"C:\Program Files\SomeApp\app.exe").allowed);
        assert!(!verdict(r"C:\Program Files (x86)\SomeApp\app.exe").allowed);
        assert!(!verdict(r"C:\ProgramData\SomeApp\data.db").allowed);
    }

    #[cfg(windows)]
    #[test]
    fn windows_user_profile_root_blocked_but_orphan_scan_allowed() {
        let home = dirs::home_dir().expect("home dir");
        assert!(!validate_path(&home).allowed);

        // %LocalAppData% itself is protected ...
        let local = home.join("AppData").join("Local");
        assert!(!validate_path(&local).allowed, "{local:?}");

        // ... except Temp (the sanctioned target) ...
        let temp = local.join("Temp").join("x.tmp");
        assert!(validate_path(&temp).allowed, "{temp:?}");

        // ... and Roaming is an explicit orphan-scan target (category-gated later).
        let roaming = home.join("AppData").join("Roaming").join("OrphanApp");
        assert!(validate_path(&roaming).allowed, "{roaming:?}");
    }

    #[cfg(windows)]
    #[test]
    fn windows_matching_is_case_insensitive() {
        assert!(!verdict(r"c:\windows\system32\cmd.exe").allowed);
    }

    #[cfg(windows)]
    #[test]
    fn windows_system_files_and_recycle_bin_blocked() {
        assert!(!verdict(r"C:\pagefile.sys").allowed);
        // The recycle bin container AND everything in it is never deletable
        // (deleting from the trash is permanent).
        assert!(!verdict(r"C:\$Recycle.Bin").allowed);
        assert!(!verdict(r"C:\$Recycle.Bin\S-1-5-21-1234-5678\$Rabc123.tmp").allowed);
        assert!(!verdict(r"C:\Users").allowed);
    }

    // ── Linux (incl. most CI) ──────────────────────────────────────────────

    #[cfg(all(unix, not(target_os = "macos"), not(target_os = "android")))]
    #[test]
    fn linux_system_paths_are_blocked() {
        assert!(!verdict("/etc/passwd").allowed);
        assert!(!verdict("/boot/vmlinuz-linux").allowed);
        assert!(!verdict("/usr/local/bin/tool").allowed);
        assert!(!verdict("/var/log/syslog").allowed);
    }

    #[cfg(all(unix, not(target_os = "macos"), not(target_os = "android")))]
    #[test]
    fn linux_package_caches_are_cleanable() {
        assert!(verdict("/var/cache/apt/archives/old.deb").allowed);
        assert!(verdict("/var/cache/dnf/pkg.rpm").allowed);
        assert!(verdict("/var/tmp/session.log").allowed);
        assert!(verdict("/tmp/junk").allowed);
    }

    #[cfg(all(unix, not(target_os = "macos"), not(target_os = "android")))]
    #[test]
    fn linux_home_container_protected_but_descendants_cleanable() {
        assert!(!verdict("/home").allowed);
        assert!(!verdict("/root").allowed);
        let home = dirs::home_dir().expect("home dir");
        assert!(!validate_path(&home).allowed);
        assert!(validate_path(&home.join(".cache")).allowed);
    }

    // ── macOS ──────────────────────────────────────────────────────────────

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_system_paths_are_blocked() {
        assert!(!verdict("/System/Library/CoreServices").allowed);
        assert!(!verdict("/Library/Preferences/com.apple.x.plist").allowed);
        assert!(!verdict("/usr/bin/foo").allowed);
        assert!(!verdict("/private/var/vm/swapfile0").allowed);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_cleanup_targets_are_allowed() {
        assert!(verdict("/Library/Caches/com.apple.pkg/installer").allowed);
        let home = dirs::home_dir().expect("home dir");
        assert!(validate_path(&home.join("Library/Caches/App/junk")).allowed);
        assert!(validate_path(&home.join("Library/Logs/app.log")).allowed);
        // Non-target areas of ~/Library stay protected.
        assert!(!validate_path(&home.join("Library/Application Support/App")).allowed);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_matching_is_case_insensitive() {
        assert!(!verdict("/ETC/hosts").allowed);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_trash_is_surfaced_but_never_deletable() {
        let home = dirs::home_dir().expect("home dir");
        assert!(!validate_path(&home.join(".Trash")).allowed);
        assert!(!validate_path(&home.join(".Trash").join("old-file.txt")).allowed);
    }

    #[cfg(all(unix, not(target_os = "macos"), not(target_os = "android")))]
    #[test]
    fn linux_trash_is_surfaced_but_never_deletable() {
        let home = dirs::home_dir().expect("home dir");
        let trash = home.join(".local/share/Trash");
        assert!(!validate_path(&trash).allowed);
        assert!(!validate_path(&trash.join("files/old-file.txt")).allowed);
    }
}
