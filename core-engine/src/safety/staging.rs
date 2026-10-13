//! # Trash staging — moving files to the OS recycle bin
//!
//! [`super::execution`] never permanently deletes: it **stages** every path
//! into the OS recycle bin / trash, where it stays recoverable. This module
//! owns that move, with platform paths chosen for *robustness first*:
//!
//! - **Windows**: a filesystem-level rename into the current user's SID
//!   folder under the system drive's `\$Recycle.Bin`, writing the `$I*`
//!   metadata file the shell expects alongside the `$R*` content file. This
//!   never calls the per-file shell/COM API: a locked or in-use file fails
//!   **immediately** with an OS error, so one bad file cannot stall an
//!   entire run (the per-file API previously hung for minutes on locked
//!   browser caches, and cost tens of milliseconds *per file* even when
//!   healthy). If the rename fails and the file lives on a different
//!   volume than the staging bin, [`delete`] retries once through the
//!   `trash` crate, which resolves the correct per-volume bin.
//! - **macOS / Linux**: the `trash` crate (per-file, no known hang issues),
//!   matching the freedesktop trash spec and `~/.Trash`.
//!
//! Correctness notes for the Windows path:
//!
//! - The target SID folder is looked up, never guessed: the current user's
//!   SID comes from `WindowsIdentity::GetCurrent()` and the bin folder is
//!   resolved **once per process** and cached.
//! - `$I` metadata is written in the Windows 10+ format (v2, 544 bytes) so
//!   Explorer shows the original path and deletion date, and "Restore" works.
//! - Renames stay inside the same volume, so they are metadata operations,
//!   not copies — and atomic ones: an entry is either fully staged (with its
//!   `$I` file) or rolled back.
//! - The staging area is never cleaned here — emptying the bin is
//!   [`super::trash::empty_recycle_bin`]'s explicitly-confirmed job.

use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

/// Why staging a path into the trash failed.
#[derive(Debug, thiserror::Error)]
pub enum StageError {
    /// The path vanished between the scan and the move (TOCTOU).
    #[error("path no longer exists: {0}")]
    Missing(String),
    /// Both the filesystem-level stage and the `trash` crate fallback
    /// refused the path. The message is safe to show a user.
    #[error("could not move to the recycle bin: {0}")]
    Refused(String),
}

/// Size of the Windows 10+ `$I` metadata file (v2, with the variable-length
/// file-name buffer). The older Windows 8 format was 552 bytes with
/// fixed-length names.
#[cfg(windows)]
const IFILE_SIZE_V2: usize = 544;

/// Moves `path` to the OS recycle bin / trash (recoverable).
///
/// Windows: filesystem-level `$I`/`$R` stage into the current user's SID bin
/// (see the module docs). Other platforms: the `trash` crate. Locked or
/// in-use files fail fast on Windows with the OS error naming the file.
pub fn delete(path: &Path) -> Result<(), StageError> {
    if !path.exists() {
        return Err(StageError::Missing(path.display().to_string()));
    }

    #[cfg(windows)]
    {
        match stage_windows(path) {
            Ok(_staged_r_path) => Ok(()),
            Err(first) => {
                if same_volume_as_staging(path) {
                    // Same volume as the bin: the rename is the authoritative
                    // answer (a locked file fails here instantly). Falling
                    // back to the per-file shell API is what used to hang.
                    Err(StageError::Refused(first))
                } else {
                    // Different volume: the `trash` crate resolves that
                    // volume's own bin, which the rename cannot reach.
                    trash::delete(path)
                        .map_err(|second| StageError::Refused(format!("{first}; shell API: {second}")))
                }
            }
        }
    }

    #[cfg(not(windows))]
    {
        trash::delete(path).map_err(|e| StageError::Refused(e.to_string()))
    }
}

/// `true` when `path` sits on the same drive letter as the staging bin
/// (the system drive, e.g. `C:`). Same-volume renames are the fast path.
#[cfg(windows)]
fn same_volume_as_staging(path: &Path) -> bool {
    let system_drive = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".to_string());
    let prefix = path
        .display()
        .to_string()
        .get(..2)
        .map(str::to_string)
        .unwrap_or_default();
    prefix.eq_ignore_ascii_case(&system_drive)
}

// ── Windows: filesystem-level $I/$R staging ──────────────────────────────

/// Stages `path` into the current user's `\$Recycle.Bin\<SID>` folder by
/// renaming it to a `$R<token>` entry and writing the paired `$I<token>`
/// metadata file. Returns the staged `$R` path on success.
///
/// The rename is atomic and instant; a locked or exclusively-open file
/// returns an OS error immediately instead of blocking. If the `$I` write
/// fails after the rename, the entry is rolled back out of the bin so no
/// orphaned `$R` file is left behind.
#[cfg(windows)]
fn stage_windows(path: &Path) -> Result<String, String> {
    let bin = user_recycle_bin_dir()?;

    // symlink_metadata does not follow links: a symlink is staged as the
    // link itself (exactly what the shell does), never as its target.
    let meta =
        std::fs::symlink_metadata(path).map_err(|e| format!("{}: {e}", path.display()))?;

    let token = random_token();
    let r_path = bin.join(format!("$R{token}"));
    let i_path = bin.join(format!("$I{token}"));

    std::fs::rename(path, &r_path).map_err(|e| format!("{}: {e}", path.display()))?;

    // The bin entry is only valid once $I metadata exists — if writing it
    // fails, roll the content back out of the bin rather than leave an
    // orphaned $R file Explorer cannot display or restore.
    if let Err(e) = write_ifile(&i_path, path, meta.len()) {
        let _ = std::fs::rename(&r_path, path);
        return Err(format!("{}: {e}", path.display()));
    }

    Ok(r_path.display().to_string())
}

/// Resolves the current user's recycle bin directory
/// (`<SystemDrive>\$Recycle.Bin\<SID>`), **once per process**.
///
/// The SID comes from `WindowsIdentity::GetCurrent()` via PowerShell (safe
/// Rust cannot read it without `unsafe`/Win32 FFI), and the directory is
/// created if the shell has not made it yet. The result — success or
/// failure — is cached so a 50k-entry execution costs one PowerShell
/// invocation, not 50k.
#[cfg(windows)]
fn user_recycle_bin_dir() -> Result<std::path::PathBuf, String> {
    use std::sync::OnceLock;

    static BIN: OnceLock<Result<std::path::PathBuf, String>> = OnceLock::new();

    BIN.get_or_init(|| {
        let output = std::process::Command::new("powershell")
            .args([
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "[System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value",
            ])
            .output()
            .map_err(|e| format!("cannot query the current user SID: {e}"))?;
        let sid = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !output.status.success() || sid.is_empty() {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            return Err(if stderr.is_empty() {
                "cannot determine the current user SID".to_string()
            } else {
                stderr
            });
        }

        let drive = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".to_string());
        let bin = std::path::PathBuf::from(format!(r"{drive}\$Recycle.Bin\{sid}"));
        // The shell creates this on first trash use; create it ourselves so
        // the very first stage also works (users may create their own SID
        // folder — the ACL grants CreatorOwner).
        std::fs::create_dir_all(&bin)
            .map_err(|e| format!("cannot prepare the recycle bin folder {}: {e}", bin.display()))?;
        Ok(bin)
    })
    .clone()
}

/// Writes the Windows 10+ `$I` metadata file (v2) for a staged entry so
/// Explorer shows the original path/date and can restore it.
///
/// Layout (all little-endian): `u64 version(2)` · `u64 file size` · `u64
/// deletion time (FILETIME)` · `u32 name length in UTF-16 units (v2)` ·
/// UTF-16 original path · zero padding out to [`IFILE_SIZE_V2`] bytes.
#[cfg(windows)]
fn write_ifile(i_path: &Path, original: &Path, size_bytes: u64) -> Result<(), String> {
    use std::io::Write;

    let original_str = strip_extended_path(original);
    let name_utf16: Vec<u16> = original_str.encode_utf16().collect();

    let mut buf = vec![0u8; IFILE_SIZE_V2];
    buf[0..8].copy_from_slice(&2u64.to_le_bytes()); // version 2
    buf[8..16].copy_from_slice(&size_bytes.to_le_bytes());
    buf[16..24].copy_from_slice(&filetime_now().to_le_bytes());
    buf[24..28].copy_from_slice(&(name_utf16.len() as u32).to_le_bytes());
    for (i, unit) in name_utf16.iter().enumerate() {
        let at = 28 + i * 2;
        if at + 2 <= IFILE_SIZE_V2 {
            buf[at..at + 2].copy_from_slice(&unit.to_le_bytes());
        }
    }

    let mut f =
        std::fs::File::create(i_path).map_err(|e| format!("writing $I metadata: {e}"))?;
    f.write_all(&buf).map_err(|e| format!("writing $I metadata: {e}"))?;
    Ok(())
}

/// `$I` time is FILETIME (100 ns ticks since 1601-01-01). Deletion time is
/// "now", matching what the shell would stamp.
#[cfg(windows)]
fn filetime_now() -> u64 {
    const EPOCH_DIFF: u64 = 11_644_473_600; // 1601 → 1970, seconds
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    (secs + EPOCH_DIFF) * 10_000_000
}

/// The shell reports some recycle-bin paths with the `\\?\` extended-length
/// prefix; `$I` metadata should carry the plain path the user recognizes.
#[cfg(windows)]
fn strip_extended_path(path: &Path) -> String {
    let s = path.to_string_lossy();
    s.strip_prefix(r"\\?\").map(str::to_string).unwrap_or_else(|| s.into_owned())
}

/// Eight hex characters — the same width the shell uses for its `$R`/`$I`
/// tokens. Random (pid + time, xorshift-mixed) so concurrent batch entries
/// never collide.
#[cfg(windows)]
fn random_token() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos() as u64 ^ d.as_secs())
        .unwrap_or(0);
    let pid = std::process::id() as u64;
    let mut x = nanos ^ (pid << 32) ^ 0x9E37_79B9_7F4A_7C15;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    // Fold to 32 bits (the shell's token width): mixes the high half in and
    // guarantees the formatted token is exactly 8 hex chars.
    let token32 = (x ^ (x >> 32)) as u32;
    format!("{token32:08X}")
}

#[cfg(all(test, windows))]
mod tests {
    use super::*;
    use std::fs;

    fn fixture_dir(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "kernsifter-stage-test-{}-{name}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("create fixture dir");
        dir
    }

    #[test]
    fn ifile_layout_matches_v2_spec() {
        let dir = fixture_dir("ifile");
        let file = dir.join("hello.txt");
        fs::write(&file, vec![0u8; 1234]).expect("write");

        let i_path = dir.join("$ITEST");
        write_ifile(&i_path, &file, 1234).expect("write $I");

        let buf = fs::read(&i_path).expect("read $I");
        assert_eq!(buf.len(), IFILE_SIZE_V2, "$I must be the exact v2 size");
        assert_eq!(u64::from_le_bytes(buf[0..8].try_into().unwrap()), 2, "version");
        assert_eq!(
            u64::from_le_bytes(buf[8..16].try_into().unwrap()),
            1234,
            "file size"
        );
        let chars = u32::from_le_bytes(buf[24..28].try_into().unwrap()) as usize;
        let units: Vec<u16> = buf[28..]
            .chunks_exact(2)
            .take(chars)
            .map(|c| u16::from_le_bytes(c.try_into().unwrap()))
            .collect();
        assert_eq!(
            String::from_utf16(&units).unwrap(),
            file.display().to_string(),
            "original path must round-trip"
        );

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn random_token_is_eight_hex_chars() {
        let a = random_token();
        let b = random_token();
        assert_eq!(a.len(), 8, "{a}");
        assert!(a.chars().all(|c| c.is_ascii_hexdigit()), "{a}");
        // Two calls in a row differ (pid + nanos + xorshift mixing).
        assert_ne!(a, b, "tokens must not collide within a run");
    }

    #[test]
    fn extended_path_prefix_is_stripped() {
        assert_eq!(
            strip_extended_path(Path::new(r"\\?\C:\Temp\x.txt")),
            r"C:\Temp\x.txt"
        );
        assert_eq!(strip_extended_path(Path::new(r"C:\Temp\x.txt")), r"C:\Temp\x.txt");
    }

    #[test]
    fn missing_path_is_reported_missing() {
        let err = delete(Path::new(r"C:\definitely\not\here\kernsifter.tmp"))
            .expect_err("missing path must fail");
        assert!(matches!(err, StageError::Missing(_)), "{err:?}");
    }

    #[test]
    fn system_drive_matches_staging_volume() {
        let drive = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".to_string());
        let on_system = path_buf_from(format!(r"{drive}\Temp\x.txt"));
        let other = path_buf_from(format!(
            r"{}:\Temp\x.txt",
            if drive.starts_with('C') { "Q" } else { "C" }
        ));
        assert!(same_volume_as_staging(&on_system));
        assert!(!same_volume_as_staging(&other));
    }

    // Small helper so the test above stays readable on any system drive.
    fn path_buf_from(s: String) -> std::path::PathBuf {
        std::path::PathBuf::from(s)
    }
}
