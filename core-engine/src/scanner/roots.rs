//! Platform-sanctioned scan roots.
//!
//! Each supported OS declares the directories the scanner may traverse and
//! what kind of junk lives there. Roots are the *whitelist* half of the safety
//! model: a root must itself pass the protected-path matrix (i.e. be inside a
//! sanctioned carve-out) or it is refused before a single entry is walked.

use std::collections::HashSet;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::safety::protected;

/// What kind of junk a [`ScanRoot`] (and the entries beneath it) holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub enum Category {
    /// Transient user/system temp files (`%TEMP%`, `C:\Windows\Temp`).
    Temp,
    /// Application/system caches (`~/.cache`, `~/Library/Caches`).
    Cache,
    /// Log output (`~/Library/Logs`).
    Logs,
    /// Package-manager download archives (`/var/cache/apt/archives`, `/var/cache/dnf`).
    PackageCache,
    /// Windows Prefetch app-launch traces.
    Prefetch,
    /// Browser cache internals: service workers, code cache, disk cache,
    /// GPU/WebGPU shader cache, site storage (Chrome, Edge, Brave, etc.).
    ///
    /// These live deep inside each browser's User Data tree — exactly
    /// where "ghost downloads" like Gemini Nano and compiled site JS hide
    /// from normal cleanup tools.
    ///
    /// Note this is the *disposable* half of a browser profile. Offline site
    /// data — which a running site depends on — is [`Category::SiteStorage`]
    /// instead.
    BrowserCache,
    /// Offline site data held by a browser profile: the Service Worker tree
    /// (CacheStorage, PWA offline bundles, background-sync payloads).
    ///
    /// It lives inside the browser's User Data tree, but deleting it is not
    /// harmless the way a disk/code cache is: it is where an installed web
    /// app's offline state lives, so the site can stop working until it
    /// re-fetches everything. It is therefore [`Confirmation::Explicit`]
    /// (see [`crate::platform`]) — never part of a routine "smart clean",
    /// only ever removed when the user selects it by name.
    SiteStorage,
    /// Uninstalled-app residue: a user-data directory under `%LOCALAPPDATA%`
    /// / `%APPDATA%` that no installed program still owns.
    ///
    /// Surfaced for review only — a false positive here would take an app's
    /// settings with it, so the executor marks this category
    /// [`Confirmation::Explicit`](crate::platform::Confirmation::Explicit) and
    /// never selects it on its own. Roots are discovered on demand by
    /// [`crate::platform::windows::appdata_orphan_roots`] rather than by
    /// `platform_roots()`, because the walk is a heuristic over a directory
    /// that holds live application state.
    AppOrphan,
    /// Locally cached AI model weights (Ollama, LM Studio, etc.).
    ///
    /// Unlike browser caches these are *not* automatically cleanable — they
    /// are surfaced in the manifest for user review so large outdated models
    /// can be identified and removed manually.
    AiModels,
    /// Contents of the OS trash / recycle bin (`C:\$Recycle.Bin` on Windows,
    /// `~/.Trash` on macOS, `~/.local/share/Trash/files` on Linux).
    ///
    /// Surfaced in the manifest purely for **visibility** — trashed files
    /// still eat disk space until the bin is emptied. KernSifter never
    /// deletes from the trash: removing from the recycle bin is a permanent
    /// delete with no recoverable trash step, so every entry in this
    /// category is refused by the matrix and the execution engine.
    RecycleBin,
}

/// A directory the scanner is allowed to traverse, and what it contains.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScanRoot {
    /// Absolute path of the sanctioned root.
    pub path: PathBuf,
    /// What kind of files live there (drives manifest grouping + confirmation).
    pub category: Category,
}

/// The scan roots for the host OS, per the platform spec:
///
/// - **Windows** — `%TEMP%`, `C:\Windows\Temp`, `C:\Windows\Prefetch`.
/// - **macOS** — `~/Library/Caches`, `/Library/Caches`, `~/Library/Logs`.
/// - **Linux** — `/var/cache/apt/archives`, `/var/cache/dnf`, `~/.cache`.
/// - **Android / iOS** — none. Scoped storage / SAF (Android) and
///   `NSTemporaryDirectory()` (iOS) are driven from the app layer, which feeds
///   user-granted roots back through [`crate::scanner::scan_roots`].
///
/// Roots are de-duplicated (e.g. `%TEMP%` often equals `%LocalAppData%\Temp`)
/// and are not required to exist — non-existent roots are reported as skipped
/// by [`crate::scanner::scan_roots`].
#[cfg(windows)]
pub fn platform_roots() -> Vec<ScanRoot> {
    let mut roots = vec![
        ScanRoot {
            path: std::env::temp_dir(),
            category: Category::Temp,
        },
        ScanRoot {
            path: PathBuf::from(r"C:\Windows\Temp"),
            category: Category::Temp,
        },
        ScanRoot {
            path: PathBuf::from(r"C:\Windows\Prefetch"),
            category: Category::Prefetch,
        },
    ];

    // Deep scan: browser caches, Electron app caches, npm, AI models.
    roots.extend(discover_deep_roots());

    // Recycle Bin: surfaced for visibility, never cleanable (see Category).
    roots.push(ScanRoot {
        path: PathBuf::from(r"C:\$Recycle.Bin"),
        category: Category::RecycleBin,
    });

    // Register deep-root paths as matrix carve-outs so the protected-path
    // validator allows the scanner to enter these directories. Must happen
    // before any path validation (the matrix is built lazily). Recycle Bin
    // roots are scan-only and are excluded — nothing is carved out of the
    // protection matrix for the trash.
    let carve_outs: Vec<PathBuf> = roots
        .iter()
        .filter(|r| r.category != Category::RecycleBin)
        .map(|r| r.path.clone())
        .collect();
    protected::register_carveouts(&carve_outs);

    dedupe(&mut roots);
    roots
}

/// macOS: `~/Library/Caches`, `/Library/Caches`, `~/Library/Logs` +
/// deep scan for browser caches, Electron apps, npm, pip, Ollama.
#[cfg(target_os = "macos")]
pub fn platform_roots() -> Vec<ScanRoot> {
    let mut roots = Vec::new();
    if let Some(home) = dirs::home_dir() {
        roots.push(ScanRoot {
            path: home.join("Library").join("Caches"),
            category: Category::Cache,
        });
        roots.push(ScanRoot {
            path: home.join("Library").join("Logs"),
            category: Category::Logs,
        });
    }
    roots.push(ScanRoot {
        path: PathBuf::from("/Library/Caches"),
        category: Category::Cache,
    });

    roots.extend(discover_deep_roots());

    // Recycle Bin (macOS Finder trash): surfaced for visibility only.
    if let Some(home) = dirs::home_dir() {
        roots.push(ScanRoot {
            path: home.join(".Trash"),
            category: Category::RecycleBin,
        });
    }

    // Register deep-root paths as matrix carve-outs so the protected-path
    // validator allows the scanner to enter ~/Library/Application Support/
    // subdirectories (browser profiles, Electron apps). Recycle Bin roots
    // are scan-only and are excluded — nothing is carved out for the trash.
    let carve_outs: Vec<PathBuf> = roots
        .iter()
        .filter(|r| r.category != Category::RecycleBin)
        .map(|r| r.path.clone())
        .collect();
    protected::register_carveouts(&carve_outs);

    dedupe(&mut roots);
    roots
}

/// Linux: `/var/cache/apt/archives`, `/var/cache/dnf`, `~/.cache` +
/// deep scan for browser caches, npm, pip, Ollama, Electron apps.
#[cfg(all(unix, not(target_os = "android"), not(target_os = "ios")))]
pub fn platform_roots() -> Vec<ScanRoot> {
    let mut roots = vec![
        ScanRoot {
            path: PathBuf::from("/var/cache/apt/archives"),
            category: Category::PackageCache,
        },
        ScanRoot {
            path: PathBuf::from("/var/cache/dnf"),
            category: Category::PackageCache,
        },
    ];
    if let Some(home) = dirs::home_dir() {
        roots.push(ScanRoot {
            path: home.join(".cache"),
            category: Category::Cache,
        });
    }

    roots.extend(discover_deep_roots());

    // Trash (XDG trash spec): surfaced for visibility only. The `files`
    // subdirectory holds the actual content; `info` holds deletion metadata.
    if let Some(data) = dirs::data_dir() {
        roots.push(ScanRoot {
            path: data.join("Trash").join("files"),
            category: Category::RecycleBin,
        });
    }

    dedupe(&mut roots);
    roots
}

/// Android (incl. GrapheneOS/CalyxOS) & iOS: no roots — scoped storage / SAF
/// and `NSTemporaryDirectory()` are driven from the app layer (see module
/// docs).
#[cfg(any(target_os = "android", target_os = "ios"))]
pub fn platform_roots() -> Vec<ScanRoot> {
    Vec::new()
}

// ── Cross-platform deep-scan discovery ────────────────────────────────────

/// Subdirectory names under a Chromium profile that hold disposable cache
/// data (common across Windows, macOS, and Linux).
///
/// `Service Worker` is deliberately absent: it is offline site data, not
/// cache, and is discovered separately as [`Category::SiteStorage`].
const CHROMIUM_CACHE_DIRS: &[&str] = &[
    "Code Cache",
    "Cache",
    "GPUCache",
    "DawnCache",
    "GrShaderCache",
    "ShaderCache",
];

/// Subdirectory names under a Chromium profile that hold *offline site data*.
///
/// Kept apart from [`CHROMIUM_CACHE_DIRS`] so a routine clean can never
/// delete a web app's offline state — these roots are scanned for review but
/// gated behind [`Category::SiteStorage`]'s explicit-only policy.
const CHROMIUM_SITE_STORAGE_DIRS: &[&str] = &["Service Worker"];

/// Adds Chromium cache subdirectories for every profile found inside the
/// given user-data directory.
fn add_chromium_profile_caches(
    roots: &mut Vec<ScanRoot>,
    user_data_dir: &PathBuf,
) {
    if !user_data_dir.is_dir() {
        return;
    }
    if let Ok(profiles) = std::fs::read_dir(user_data_dir) {
        for entry in profiles.flatten() {
            let p = entry.path();
            if !p.is_dir() {
                continue;
            }
            let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
            let is_profile = name == "Default"
                || name == "System Profile"
                || name.starts_with("Profile ");
            if !is_profile {
                continue;
            }
            for cache_dir in CHROMIUM_CACHE_DIRS {
                let cache_path = p.join(cache_dir);
                if cache_path.is_dir() {
                    roots.push(ScanRoot {
                        path: cache_path,
                        category: Category::BrowserCache,
                    });
                }
            }
            for storage_dir in CHROMIUM_SITE_STORAGE_DIRS {
                let storage_path = p.join(storage_dir);
                if storage_path.is_dir() {
                    roots.push(ScanRoot {
                        path: storage_path,
                        category: Category::SiteStorage,
                    });
                }
            }
        }
    }
}

/// Discover deep-scan roots for the host platform: browser caches, Electron
/// app caches, npm/pip archives, SquirrelTemp leftovers, and AI model
/// downloads that hide deep inside user-data directories.
///
/// Each platform puts things in different places, but the discovery logic is
/// the same: check known paths, add what exists. The protected-path matrix
/// carve-outs are registered separately by each platform's `platform_roots()`.
fn discover_deep_roots() -> Vec<ScanRoot> {
    let mut roots = Vec::new();

    #[cfg(windows)]
    {
        let local = match dirs::data_local_dir() {
            Some(d) => d,
            None => return roots,
        };

        // ── Browser caches (Chromium: Chrome, Edge, Brave, Opera) ──
        for (vendor, dir_name) in [
            ("Google", "Chrome"),
            ("Microsoft", "Edge"),
            ("BraveSoftware", "Brave-Browser"),
            ("Opera Software", "Opera Stable"),
        ] {
            add_chromium_profile_caches(
                &mut roots,
                &local.join(vendor).join(dir_name).join("User Data"),
            );
        }

        // Electron app caches.
        for (app_dir, cache_sub) in &[
            ("Discord", "Cache"),
            ("slack", "Cache"),
        ] {
            let cache_path = local.join(app_dir).join(cache_sub);
            if cache_path.is_dir() {
                roots.push(ScanRoot { path: cache_path, category: Category::BrowserCache });
            }
        }

        // npm, pip, SquirrelTemp, AI models.
        //
        // AI model weights live in the user's home directory, NOT inside the
        // app's install dir: Ollama stores blobs under ~\.ollama\models and
        // LM Studio under ~\.lm-studio\models. Scanning the install dir
        // (e.g. AppData\Local\Programs\Ollama) would flag the program's own
        // runtime DLLs and binaries as cleanable — never the intent.
        let home = match dirs::home_dir() {
            Some(d) => d,
            None => return roots,
        };
        // Package-manager and app-updater download archives. These are
        // `Category::PackageCache` — surfaced for review but never selected by
        // a smart clean, because an archive sitting in an updater directory
        // may be a *pending* update rather than a stale leftover. A pending
        // Ollama update, for instance, is a file the app intends to install.
        for (path, cat) in &[
            (local.join("npm-cache"), Category::BrowserCache),
            (local.join("pip").join("cache"), Category::BrowserCache),
            (local.join("SquirrelTemp"), Category::Temp),
            (local.join("@codebufffreebuff-desktop-updater"), Category::PackageCache),
            (local.join("Ollama").join("updates_v2"), Category::PackageCache),
            (home.join(".bun").join("install").join("cache"), Category::PackageCache),
            (home.join(".ollama").join("models"), Category::AiModels),
            (home.join(".lm-studio").join("models"), Category::AiModels),
        ] {
            if path.is_dir() {
                roots.push(ScanRoot { path: path.clone(), category: *cat });
            }
        }
    }

    #[cfg(target_os = "macos")]
    {
        let home = match dirs::home_dir() {
            Some(d) => d,
            None => return roots,
        };

        // Chromium browsers on macOS: ~/Library/Application Support/<Vendor>/<Browser>
        // (no "User Data" intermediate directory).
        for (vendor, dir_name) in [
            ("Google", "Chrome"),
            ("Microsoft", "Edge"),
            ("BraveSoftware", "Brave-Browser"),
        ] {
            add_chromium_profile_caches(
                &mut roots,
                &home.join("Library").join("Application Support").join(vendor).join(dir_name),
            );
        }

        // Firefox: ~/Library/Application Support/Firefox/Profiles/*/cache2
        let ff = home.join("Library").join("Application Support").join("Firefox").join("Profiles");
        if ff.is_dir() {
            if let Ok(profiles) = std::fs::read_dir(&ff) {
                for entry in profiles.flatten() {
                    let cache = entry.path().join("cache2");
                    if cache.is_dir() {
                        roots.push(ScanRoot { path: cache, category: Category::BrowserCache });
                    }
                }
            }
        }

        // Electron apps on macOS often under ~/Library/Application Support/
        for app in &["Discord", "Slack", "Postman", "Spotify"] {
            let app_support = home.join("Library").join("Application Support").join(app);
            for sub in &["Cache", "Code Cache"] {
                let d = app_support.join(sub);
                if d.is_dir() {
                    roots.push(ScanRoot { path: d, category: Category::BrowserCache });
                }
            }
            let sw = app_support.join("Service Worker");
            if sw.is_dir() {
                roots.push(ScanRoot { path: sw, category: Category::SiteStorage });
            }
        }

        // npm, pip, AI models.
        // Package-manager / app-updater archives (review-only, never automatic).
        for (path, cat) in &[
            (home.join(".npm").join("_cacache"), Category::BrowserCache),
            (home.join("Library").join("Caches").join("pip"), Category::BrowserCache),
            (home.join(".bun").join("install").join("cache"), Category::PackageCache),
            (home.join(".ollama").join("models"), Category::AiModels),
            (home.join(".cache").join("lm-studio").join("models"), Category::AiModels),
        ] {
            if path.is_dir() {
                roots.push(ScanRoot { path: path.clone(), category: *cat });
            }
        }
    }

    #[cfg(all(unix, not(target_os = "macos"), not(target_os = "android")))]
    {
        let home = match dirs::home_dir() {
            Some(d) => d,
            None => return roots,
        };
        let data = dirs::data_dir();  // ~/.local/share
        let config = dirs::config_dir(); // ~/.config

        // Chromium / Chrome (Linux uses ~/.config/<browser>/Default/...).
        if let Some(config) = &config {
            for browser in &["google-chrome", "chromium", "microsoft-edge", "brave-browser", "opera"] {
                add_chromium_profile_caches(&mut roots, &config.join(browser));
            }
        }

        // Firefox: ~/.mozilla/firefox/*.default*/cache2
        let ff = home.join(".mozilla").join("firefox");
        if ff.is_dir() {
            if let Ok(profiles) = std::fs::read_dir(&ff) {
                for entry in profiles.flatten() {
                    let n = entry.file_name().to_string_lossy().into_owned();
                    if n.ends_with(".default") || n.ends_with(".default-release") {
                        let cache = entry.path().join("cache2");
                        if cache.is_dir() {
                            roots.push(ScanRoot { path: cache, category: Category::BrowserCache });
                        }
                    }
                }
            }
        }

        // Electron apps (flatpak / snap / native).
        if let Some(config) = &config {
            for app in &["discord", "slack", "postman", "spotify", "Code"] {
                for sub in &["Cache", "Code Cache"] {
                    let d = config.join(app).join(sub);
                    if d.is_dir() {
                        roots.push(ScanRoot { path: d, category: Category::BrowserCache });
                    }
                }
                let sw = config.join(app).join("Service Worker");
                if sw.is_dir() {
                    roots.push(ScanRoot { path: sw, category: Category::SiteStorage });
                }
            }
        }

        // npm, pip, AI models.
        // Package-manager / app-updater archives (review-only, never automatic).
        for (path, cat) in &[
            (home.join(".npm").join("_cacache"), Category::BrowserCache),
            (home.join(".cache").join("pip"), Category::BrowserCache),
            (home.join(".bun").join("install").join("cache"), Category::PackageCache),
            (home.join(".ollama").join("models"), Category::AiModels),
            (home.join(".cache").join("lm-studio").join("models"), Category::AiModels),
        ] {
            if path.is_dir() {
                roots.push(ScanRoot { path: path.clone(), category: *cat });
            }
        }

        // SquirrelTemp (Electron updater leftovers).
        if let Some(data) = &data {
            let squirrel = data.join("SquirrelTemp");
            if squirrel.is_dir() {
                roots.push(ScanRoot { path: squirrel, category: Category::Temp });
            }
        }
    }

    roots
}

/// Removes duplicate roots (by path). Order of first occurrence is kept.
fn dedupe(roots: &mut Vec<ScanRoot>) {
    let mut seen = HashSet::new();
    roots.retain(|r| seen.insert(r.path.clone()));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "freebuff-roots-test-{}-{name}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create fixture");
        dir
    }

    /// A Chromium profile's disposable caches and its offline site data must
    /// land in *different* categories: a disk/code cache is routine, but a
    /// Service Worker tree is a web app's offline state and must never be
    /// swept up by a smart clean.
    #[test]
    fn chromium_profile_splits_cache_from_site_storage() {
        let user_data = fixture("chromium");
        let profile = user_data.join("Default");
        std::fs::create_dir_all(profile.join("Cache")).expect("cache dir");
        std::fs::write(profile.join("Cache").join("data_0"), b"cached").expect("cache file");
        std::fs::create_dir_all(profile.join("Service Worker")).expect("sw dir");
        std::fs::write(profile.join("Service Worker").join("CacheStorage"), b"offline")
            .expect("sw file");

        let mut roots = Vec::new();
        add_chromium_profile_caches(&mut roots, &user_data);

        let cache = roots
            .iter()
            .find(|r| r.path.ends_with("Cache"))
            .expect("cache root");
        assert_eq!(cache.category, Category::BrowserCache, "{roots:?}");

        let site = roots
            .iter()
            .find(|r| r.path.ends_with("Service Worker"))
            .expect("service worker root");
        assert_eq!(
            site.category,
            Category::SiteStorage,
            "Service Worker must not be routine cache: {roots:?}"
        );

        let _ = std::fs::remove_dir_all(&user_data);
    }

    /// The two Chromium subdirectory lists must stay disjoint — a name in both
    /// would register the same directory twice under conflicting categories.
    #[test]
    fn cache_and_site_storage_dirs_do_not_overlap() {
        for name in CHROMIUM_SITE_STORAGE_DIRS {
            assert!(
                !CHROMIUM_CACHE_DIRS.contains(name),
                "{name} is both cache and site storage"
            );
        }
    }
}