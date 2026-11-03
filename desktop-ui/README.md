# desktop-ui (Tauri 2)

Thin desktop shell for the `core-engine` Rust crate. All cleaning logic lives
in the core; this crate owns only the window, the frontend, and IPC.

## Layout

```
desktop-ui/
├── scripts/generate_icons.py      # stdlib-only icon generator (PNG/ICO/ICNS)
├── src/                           # frontend (self-contained HTML — no node needed)
│   └── index.html                 # withGlobalTauri: calls window.__TAURI__.core.invoke
└── src-tauri/
    ├── Cargo.toml                 # tauri 2 + core-engine (path dependency)
    ├── build.rs                   # tauri_build::build()
    ├── tauri.conf.json
    ├── capabilities/default.json  # core:default for the main window
    ├── icons/                     # generated icon set
    └── src/
        ├── main.rs                # → desktop_ui_lib::run()
        └── lib.rs                 # commands: scan, generate_manifest, execute_manifest
```

## Commands (thin wrappers over core-engine)

| Command | Safety contract |
|---|---|
| `scan` | Read-only scan of platform-sanctioned roots; every entry carries its protection verdict. |
| `generate_manifest` | Fresh scan frozen into a dry-run manifest in the session registry; nothing is deletable without one. |
| `execute_manifest` | Refuses without `confirmed = true`; re-validates every path against the protected-path matrix at execution time; moves files to the OS trash (never permanent delete); `simulate` mode changes nothing. |

## Running

Requires a Rust toolchain (rustup) and the Tauri CLI:

```bash
cargo install tauri-cli --version "^2" --locked
cargo tauri dev            # from desktop-ui/
```

Dev mode serves the plain HTML frontend; no npm/node required. For real
scanning on Linux you'll need read access to the cache roots; `C:\Windows\Prefetch`
needs admin rights on modern Windows (the scanner reports, never crashes).

## Self-updates & releases

| Command | Purpose |
|---|---|
| `app_info` | Running version, canonical repo slug, "download latest" URL. |
| `check_for_update` | Asks the release feed (`plugins.updater.endpoints`) whether a newer signed version exists. Read-only. |
| `install_update` | Downloads, verifies and installs the newest signed release, then relaunches. |

The trust anchor is the minisign public key in `tauri.conf.json`
(`plugins.updater.pubkey`). Generate a new keypair with
`cargo tauri signer generate -w desktop-ui/.tauri/kernsifter.key`; the private
key must never be committed (`.tauri/` is git-ignored) and CI reads it from the
`TAURI_SIGNING_PRIVATE_KEY` / `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` repository
secrets.

`bundle.createUpdaterArtifacts: true` makes every `cargo tauri build` emit the
signed `.sig` packages; `.github/workflows/release.yml` publishes them (plus
`latest.json`) on a `v*` tag push. Test builds without the signing env vars are
fine — they simply can't be used as updates.

## Icons

`python3 scripts/generate_icons.py` regenerates the icon set from the script's
artwork. Swap in real artwork and run `npx @tauri-apps/cli icon path/to.png` for
a professionally crafted set — the generated placeholders are valid but simple.

## Targets

Windows, macOS, Linux (X11 & Wayland). Release builds use the workspace's
thin-LTO profile: `cargo tauri build`.
