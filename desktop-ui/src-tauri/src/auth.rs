//! Keystore-backed custody of the sync bearer token.
//!
//! The token is a credential for the user's synced data, so it lives in the OS
//! credential store — Windows Credential Manager, the macOS Keychain, or Secret
//! Service on Linux — and nowhere else. Not a settings file, not a log line, and
//! not the webview's `localStorage`: the webview holds it only for the duration
//! of a request and hands it here to persist.
//!
//! The device-authorization flow itself runs in the webview
//! (`src/sync-auth.js`) because a webview `fetch` needs no Rust HTTP client;
//! these commands are the only part that must be native, because only the shell
//! can reach the platform keystore.

use keyring::Entry;

/// Service/account pair under which the token is filed. Both are stable
/// identifiers, not secrets.
const SERVICE: &str = "KernSifter";
const ACCOUNT: &str = "sync-token";

fn entry() -> Result<Entry, String> {
    Entry::new(SERVICE, ACCOUNT).map_err(|error| error.to_string())
}

/// Store the sync token, replacing any previous one.
///
/// Refuses an empty token so a failed flow cannot silently blank the credential
/// and leave the app in a state that looks signed out but is not.
#[tauri::command]
pub fn store_token(token: String) -> Result<(), String> {
    if token.trim().is_empty() {
        return Err("refusing to store an empty token".to_string());
    }
    entry()?.set_password(&token).map_err(|error| error.to_string())
}

/// The stored token, if any. `None` means "not connected", which is ordinary.
#[tauri::command]
pub fn load_token() -> Result<Option<String>, String> {
    match entry()?.get_password() {
        Ok(token) => Ok(Some(token)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(error) => Err(error.to_string()),
    }
}

/// Forget the token. Succeeds when nothing was stored, so sign-out is idempotent.
///
/// This only deletes the local copy: the caller is responsible for revoking the
/// token server-side first (`disconnect()` in `sync-auth.js` does that), because
/// deleting it locally leaves a live credential at the Worker.
#[tauri::command]
pub fn clear_token() -> Result<(), String> {
    match entry()?.delete_credential() {
        Ok(()) => Ok(()),
        Err(keyring::Error::NoEntry) => Ok(()),
        Err(error) => Err(error.to_string()),
    }
}
