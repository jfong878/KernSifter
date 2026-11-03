# KernSifter — Cross-Platform Space Management & Cleaning

A modular, multi-OS space management and cleaning application. All cleaning
logic lives in one decoupled Rust core (`core-engine`); the desktop and mobile
clients are thin shells that bind to it.

- **Core Engine** — Rust. The single source of truth for scanning, safety, and
  cleanup logic. Zero-cost abstractions, memory safety, cross-compiled with
  [`cross`](https://github.com/cross-rs/cross).
- **Desktop UI** — Tauri (Rust core bound to a lightweight web frontend).
- **Mobile UI** — Flutter (binds the compiled Rust binary via `libcore_engine.so`
  / `libcore_engine.dylib` FFI).

## Download & updates

Latest release — installer plus signed updater artifacts:
**https://github.com/jfong878/KernSifter/releases/latest**

The desktop app checks that release feed on demand ("Check for updates" in
**About & updates**) and installs a newer version in place, then relaunches.
Each update package is verified against a minisign public key committed in
`desktop-ui/src-tauri/tauri.conf.json`; the matching private key exists only as
the repository's `TAURI_SIGNING_PRIVATE_KEY` secret (and a local, git-ignored
file for test builds) — an unsigned or tampered package is refused.

Releases publish automatically from a tag: bump `version` in
`desktop-ui/src-tauri/tauri.conf.json`, commit, then
`git tag vX.Y.Z && git push origin vX.Y.Z` (see
`.github/workflows/release.yml`).

## Directory Tree

```
.
├── Cargo.toml                        # Cargo workspace root (core + future Tauri crate)
├── README.md
├── .gitignore
│
├── core-engine/                      # THE single source of truth (Rust)
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs                    # crate root, re-exports the safety gate
│       ├── bin/
│       │   └── core-engine-cli.rs    # audit CLI: validate paths → JSON verdicts
│       ├── platform/                 # Phase 1 executors ✔
│       │   ├── mod.rs                #   strict conditional abstraction layer
│       │   ├── windows.rs            #   %TEMP%, C:\Windows\Temp, Prefetch, AppData orphans
│       │   ├── macos.rs              #   ~/Library/Caches, /Library/Caches, ~/Library/Logs
│       │   ├── linux.rs              #   /var/cache/apt|dnf, ~/.cache (non-root safe)
│       │   ├── android.rs            #   scoped storage + MediaStore (AOSP)
│       │   └── hardened_android.rs   #   SAF-only, explicit user directory grants
│       ├── safety/                   # Phase 2 fail-safe layer ✔
│       │   ├── mod.rs
│       │   ├── protected.rs          # Protected Directory Matrix + validation gate
│       │   ├── manifest.rs           # versioned JSON manifest: build / persist / verify
│       │   ├── execution.rs          # gated execution: verify → re-validate → trash staging
│       │   ├── staging.rs            #   the trash move itself ($I/$R staging on Windows)
│       │   └── trash.rs              #   empty the OS recycle bin (the one permanent op)
│       ├── ffi.rs                    # C ABI for the mobile shells (JSON in/out) ✔
│       └── scanner/                  # Phase 1: multi-threaded traversal (walkdir + rayon) ✔
│           ├── mod.rs                #   scan() / scan_roots() orchestration + tests
│           ├── roots.rs              #   per-platform sanctioned roots + categories
│           └── walk.rs               #   parallel walk, classification, ScanReport
│
├── desktop-ui/                       # Tauri 2 shell (implemented) ✔
│   ├── README.md
│   ├── scripts/generate_icons.py     # stdlib-only icon generator
│   ├── src/                          # self-contained HTML frontend (no node needed)
│   └── src-tauri/                    # tauri 2 + core-engine path dependency
│       ├── tauri.conf.json           # withGlobalTauri: true
│       ├── capabilities/default.json
│       ├── icons/                    # generated PNG/ICO/ICNS set
│       └── src/                      # commands: scan, generate_manifest, execute_manifest
│
└── mobile-ui/                        # Flutter shell (implemented) ✔
    ├── README.md                     # binds libcore_engine via dart:ffi
    ├── lib/                          # main.dart, core_engine_ffi.dart, models.dart
    └── test/                         # model unit tests + a live FFI boundary test
```

## Architecture — Decoupled, One Source of Truth

```
┌─────────────────────┐   ┌─────────────────────┐   ┌──────────────────┐
│  desktop-ui (Tauri) │   │ mobile-ui (Flutter) │   │  CLI/tests/CI    │
└──────────┬──────────┘   └──────────┬──────────┘   └────────┬─────────┘
           │          ┌──────────────┴──────────────┐        │
           └──────────►   core-engine  (Rust crate) ◄────────┘
                      └──────────────┬──────────────┘
                                     │
              ┌──────────────────────┼──────────────────────┐
              ▼                      ▼                      ▼
        windows.rs              macos.rs             linux.rs / android*.rs
```

There is exactly one cleaning implementation. It is compiled for every target;
the clients never re-implement cleanup logic, so behavior (and safety) cannot
drift between platforms.

## Platform Executors (Phase 1 policy)

The scanner is a whitelist over **paths**; the executor is a policy over
**categories**. Neither can widen the other, and the matrix still has the final
say on every entry at scan time and again at execution time.

```
platform_roots() → scan_roots() → plan() → register() → execute_manifest()
  scanner::roots    scanner::walk   platform   manifest      safety::execution
  (where)            (what exists)  (fair?)    (freeze)       (act, re-validated)
```

`platform::plan()` is pure — it reads only the scan report it is handed — and
splits every candidate into two lists: what may be acted on, and what was
declined **with a reason** (the trash, `ManualReviewOnly` model weights, a
category the user has not ticked, a file too young for the category's floor, a
path the matrix refuses). Nothing is silently dropped.

| Confirmation | Meaning | Examples |
|---|---|---|
| `Routine` | a one-click "Smart clean" may select it | Temp, Cache, BrowserCache |
| `Explicit` | the user must tick the category | package caches, AppData orphans, offline site storage |
| `Manual` | surfaced, never selected — the user removes it | AI model weights |
| `Never` | not actionable through KernSifter at all | the OS recycle bin |

Per-platform rules that the tables encode:

- **Age floors.** The executor's only proxy for "is anyone still using this".
  Prefetch gets 1 day (Windows is still writing those files), logs 7, the
  package cache 30, user cache 7 (it holds live build caches).
- **Offline site data is not a cache.** A browser profile's Service Worker tree
  (`CacheStorage`, PWA offline bundles) is scanned for visibility but held in a
  separate `SiteStorage` category, so a one-click smart clean can never delete a
  web app's offline state — it is `Explicit`, selected by name only.
- **Package and app-updater archives are review-only.** `%LOCALAPPDATA%\
  Ollama\updates_v2`, `@codebufffreebuff-desktop-updater`, and
  `~/.bun/install/cache` are scanned as `PackageCache`: a smart clean never
  selects them, and an explicit tick only offers entries older than a month —
  because an archive in an updater directory may be a *pending* update. The
  walker also refuses reparse points, so a cache that stores a junction beside
  the real directory (as Bun does) cannot be counted twice.
- **Elevation is a path question, not a category question.** `C:\Windows\Temp`
  needs an administrator; the user's `%TEMP%` never does. A plan flags
  elevation only when something it actually selected needs it.
- **A running package manager blocks its own cache.** `platform::linux::
  package_manager_lock()` is checked before executing a plan containing
  package archives.
- **AppData orphans are heuristic and never automatic.** A `%LOCALAPPDATA%`
  child that is idle for 180 days *and* whose name no install location still
  holds is offered for review (`platform::windows::appdata_orphan_roots()`).
  An app installed on another drive is invisible to that check, which is why
  the category is `Explicit`.
- **Android has no roots at all.** Only user-granted SAF trees
  (`platform::android::sanction_grants`), and nothing is `Routine`: a
  deletion there has no trash behind it. Hardened Android
  (`platform::hardened_android`) additionally refuses the system image, other
  apps' data, and work profiles, and never elevates.

## Safety Model (Phase 2 layering)

Every destructive operation passes through **three independent gates**:

1. **Protected Path Validation** (implemented, `core-engine/src/safety/protected.rs`)
   — an immutable, compile-time platform matrix of system-critical paths. Any
   path that is (or descends from) a protected entry is denied before it can
   reach the execution layer. Explicit carve-outs permit exactly the sanctioned
   cleanup targets (`C:\Windows\Temp`, `/var/cache/apt/archives`, ...).
2. **Dry-Run Engine** — every cleanup first produces a JSON manifest of targeted
   paths, computed sizes, and file types; nothing destructive executes until the
   manifest is verified.
3. **Safe Deletion Protocol** — deletion is staged through the OS recycle/trash
   where supported, or gated behind an explicit per-category confirmation.

### Platform rule summary (current matrix)

| OS       | Protected (never touched)                          | Carve-outs (allowed cleanup targets)            |
|----------|----------------------------------------------------|-------------------------------------------------|
| Windows  | System32, SysWOW64, Program Files, ProgramData, `C:\Windows`, `C:\Users` container, pagefile/hiberfil, `$Recycle.Bin`, user profile root, `%LocalAppData%` | `C:\Windows\Temp`, `C:\Windows\Prefetch`, `%LocalAppData%\Temp` |
| macOS    | `/System`, `/Library`, `/private` (incl. `/var`), `/usr`, `/bin`, `/sbin`, `/etc`, `/Users`, `/Volumes`, `~/Library` | `/Library/Caches`, `~/Library/Caches`, `~/Library/Logs` |
| Linux    | `/boot`, `/etc`, `/usr`, `/bin`, `/sbin`, `/lib(64)`, `/proc`, `/sys`, `/dev`, `/run`, `/var`, `/home` container, `/root`, user profile root | `/var/cache/apt/archives`, `/var/cache/dnf`, `/var/tmp` |
| Android  | (none — OS sandbox / SAF is the boundary; matrix intentionally empty) | user-granted SAF document trees |

## Build & Test

```bash
# Requires a Rust toolchain (rustup) on PATH.
cargo build --workspace            # core-engine + the Tauri shell
cargo test  -p core-engine         # safety-gate + scanner + execution + FFI tests
cargo check -p core-engine         # fast typecheck

# Desktop app (dev):
cargo install tauri-cli --version "^2" --locked
cd desktop-ui && cargo tauri dev

# Audit the protected-path matrix from the shell (one JSON verdict per line):
cargo run -p core-engine --bin core-engine-cli -- "C:\Windows\System32" "C:\Windows\Temp" --strict
# → {"path":"C:\\Windows\\System32","allowed":false,"reason":"ProtectedDirectory","rule":"C:\\Windows\\System32"}
# → {"path":"C:\\Windows\\Temp","allowed":true,"reason":null,"rule":null}
# --strict exits 1 if anything is blocked; --pretty prints a JSON array.

# See what the executor would do, and why it declined the rest. Read-only:
cargo run -p core-engine --bin core-engine-cli -- plan --top 10
# --json for the full plan, --category <Cat> to select explicitly,
# --include-recent to relax the age floors,
# -o <file> to freeze the eligible set into a manifest you can then execute.
```

The frontend is self-contained plain HTML (no npm/node) and calls the core via
`window.__TAURI__.core.invoke`. Opened in a plain browser it shows labeled mock
data; inside the Tauri shell it drives the real engine.

Cross-compilation (mobile, other desktops):

```bash
cargo install cross
cross build -p core-engine --release --target aarch64-linux-android
cross build -p core-engine --release --target x86_64-pc-windows-gnu
```

## Roadmap

- **Done:** protected-path validation gate (`safety/protected.rs`), Phase 1
  scanners (`scanner/` — walkdir + rayon over sanctioned roots, every entry
  carries its protection verdict), Phase 1 platform executors (`platform/` —
  per-OS category policy, age floors, per-path elevation, the
  scan→plan→manifest seam, SAF grant authorization for Android and hardened
  Android), dry-run manifest engine (`safety/manifest.rs`
  — versioned JSON artifacts with build/persist/verify, tamper detection),
  gated execution (`safety/execution.rs` — refuses unverified or unconfirmed
  manifests, re-validates every path at execution time, trash staging,
  simulation mode), Tauri 2 shell (`desktop-ui/`) with `scan` /
  `generate_manifest` / `execute_manifest` commands and a previewable
  mock-adaptive frontend, the `plan` CLI surface (`plan` subcommand — shows the
  executor's verdicts and every decline reason, `--json` for machines,
  `-o` to freeze the eligible set into a manifest), and the Flutter shell
  (`mobile-ui/`) bound to the engine over a C ABI (`ffi.rs` + `cdylib`).
- **Next:** platform-channel glue for the SAF directory picker on hardened
  Android, and the iOS `NSTemporaryDirectory()` offload dashboard.
- **Hardened Android:** SAF-only flow — the app prompts the user to pick target
  directories explicitly; it never requests `MANAGE_EXTERNAL_STORAGE`.
- **iOS:** `NSTemporaryDirectory()` purging + a manual storage-offload dashboard.

## Three shells, one engine

```
core-engine-cli  ─┐
desktop-ui (Tauri)─┼─→  core-engine (rlib)   ← the only cleaning implementation
mobile-ui (Flutter)┘         core-engine (cdylib) ─→ ffi.rs → JSON ─→ Dart
```

The desktop shell and the test suite link the `rlib`; the mobile shell loads the
`cdylib` through `ffi.rs`, a C ABI whose every function is a thin JSON wrapper
over a core API. No policy is defined in that file — if one appears there, it is
a second implementation of the safety model.

`ffi.rs` is the one module permitted to use `unsafe` (the crate is
`#![deny(unsafe_code)]`, and an FFI boundary is unsafe by definition). It also
converts panics into ordinary error responses: a panic unwinding into Dart or
Swift frames is undefined behaviour, so it is caught at the boundary.

The mobile shell refuses to bind an engine whose ABI major it was not built
against, and it enforces the same dry-run gate the engine does: nothing reaches
`executeManifest(simulate: false)` until a simulation of that exact manifest has
been shown.
