//! KernSifter — Tauri 2 shell.
//!
//! This crate owns only the window, the frontend, and IPC. All scanning,
//! manifest, and execution logic lives in `core-engine`; the commands here are
//! thin wrappers that keep the safety contract intact:
//!
//! - [`scan`] — read-only scan of the platform-sanctioned roots.
//! - [`generate_manifest`] — freezes a dry-run manifest (session registry).
//! - [`execute_manifest`] — refuses without confirmation and re-validates
//!   every path against the protected-path matrix at execution time.
//! - [`empty_recycle_bin`] — the one permanent operation: empties the current
//!   user's OS recycle bin. Refuses without explicit confirmation; the
//!   frontend must present its own irreversible-action dialog.

mod auth;

use core_engine::safety::execution as execution;
use core_engine::safety::manifest::ManifestRegistry;
use core_engine::{
    DryRunManifest, EmptyTrashReport, ExecutionReport, RecycleBinSummary, ScanReport,
};
use tauri::State;
use tauri_plugin_updater::UpdaterExt;

/// The canonical public repository. Everything user-facing that points at the
/// project — the "download latest" link and the updater feed — derives from
/// this one slug, so the app can never advertise a link that has drifted.
pub const GITHUB_REPO: &str = "jfong878/KernSifter";

/// Process-scoped state: the manifest registry gates execution — you can only
/// execute manifests that were generated (and reviewable) in this session.
#[derive(Default)]
struct AppState {
    registry: ManifestRegistry,
}

/// Scans every platform-sanctioned root (read-only, nothing is deleted).
#[tauri::command]
fn scan() -> Result<ScanReport, String> {
    Ok(core_engine::scan())
}

/// Runs a fresh scan and freezes it into a dry-run manifest in the session
/// registry. Returns the manifest (including its id) for review.
#[tauri::command]
fn generate_manifest(state: State<'_, AppState>) -> Result<DryRunManifest, String> {
    let report = core_engine::scan();
    let id = state.registry.register(&report);
    state
        .registry
        .get(id)
        .ok_or_else(|| "manifest vanished from registry".to_string())
}

/// Executes a previously generated manifest.
///
/// Refuses unless `confirmed` is true. With `simulate` true, nothing touches
/// the filesystem (Simulation Mode). Every path is re-validated against the
/// protected-path matrix at execution time, and files are staged through the
/// OS recycle bin / trash rather than permanently deleted.
#[tauri::command]
fn execute_manifest(
    state: State<'_, AppState>,
    manifest_id: u64,
    confirmed: bool,
    simulate: bool,
) -> Result<ExecutionReport, String> {
    execution::execute_manifest(&state.registry, manifest_id, confirmed, simulate)
        .map_err(|e| e.to_string())
}

/// Permanently empties the current user's OS recycle bin.
///
/// The only irreversible operation KernSifter offers. Refuses unless
/// `confirmed` is true; the frontend is expected to require the user to type
/// or click through an explicit irreversible-action confirmation first. The
/// operation is fixed to the OS trash — no path argument exists.
#[tauri::command]
fn empty_recycle_bin(confirmed: bool) -> Result<EmptyTrashReport, String> {
    core_engine::empty_recycle_bin(confirmed).map_err(|e| e.to_string())
}

/// Returns a read-only breakdown of the current user's recycle bin contents:
/// totals, per-file-type sizes, and the largest files. Nothing is deleted —
/// this is the review step shown *before* the user commits to emptying.
#[tauri::command]
fn recycle_bin_summary() -> Result<RecycleBinSummary, String> {
    Ok(core_engine::recycle_bin_summary())
}

/// Build metadata surfaced to the frontend: the running version, the canonical
/// repository slug, and where a human can download the latest release.
#[derive(serde::Serialize)]
struct AppInfo {
    version: String,
    repo: String,
    releases_url: String,
}

#[tauri::command]
fn app_info(app: tauri::AppHandle) -> AppInfo {
    AppInfo {
        version: app.package_info().version.to_string(),
        repo: GITHUB_REPO.to_string(),
        releases_url: format!("https://github.com/{GITHUB_REPO}/releases/latest"),
    }
}

/// Result of an update check. Read-only: nothing is downloaded or executed
/// until [`install_update`] is called.
#[derive(serde::Serialize)]
struct UpdateInfo {
    available: bool,
    current_version: String,
    version: Option<String>,
    notes: Option<String>,
    date: Option<String>,
}

/// Asks the release feed whether a newer signed version exists.
#[tauri::command]
async fn check_for_update(app: tauri::AppHandle) -> Result<UpdateInfo, String> {
    let current = app.package_info().version.to_string();
    let updater = app.updater().map_err(|e| e.to_string())?;
    match updater.check().await.map_err(|e| e.to_string())? {
        None => Ok(UpdateInfo {
            available: false,
            current_version: current,
            version: None,
            notes: None,
            date: None,
        }),
        Some(update) => Ok(UpdateInfo {
            available: true,
            current_version: current,
            version: Some(update.version.clone()),
            notes: update.body.clone(),
            date: update.date.map(|d| d.to_string()),
        }),
    }
}

/// Downloads and installs the newest signed release, then relaunches.
///
/// The package is verified against the minisign public key in
/// `tauri.conf.json` (`plugins.updater.pubkey`) before anything executes, so a
/// tampered or unsigned update is rejected at the plugin boundary.
#[tauri::command]
async fn install_update(app: tauri::AppHandle) -> Result<(), String> {
    let updater = app.updater().map_err(|e| e.to_string())?;
    let Some(update) = updater.check().await.map_err(|e| e.to_string())? else {
        return Ok(());
    };
    update
        .download_and_install(|_, _| {}, || {})
        .await
        .map_err(|e| e.to_string())?;
    app.restart()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(AppState::default())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .invoke_handler(tauri::generate_handler![
            scan,
            generate_manifest,
            execute_manifest,
            empty_recycle_bin,
            recycle_bin_summary,
            app_info,
            check_for_update,
            install_update,
            // Sync credential custody. The device-authorization flow itself runs
            // in the webview (src/sync-auth.js); only the keystore is native.
            auth::store_token,
            auth::load_token,
            auth::clear_token
        ])
        .run(tauri::generate_context!())
        .expect("error while running KernSifter");
}
