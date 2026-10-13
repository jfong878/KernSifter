# KernSifter — agent notes

Workspace hygiene, per `F:\Projects\AGENTS.md`:

- Scratch, probes, scan/inspect/confirm scripts, logs and inventory dumps go
  in `.freebuff\scratch\` — never in this repo root. `.freebuff/` is
  git-ignored for exactly this reason.
- Never write to a volume root — no `F:\`, no `F:\tmp`, no bare `tmp/`.
- One-off scripts are disposable: put them in `.freebuff\scratch\` rather than
  beside `Cargo.toml`.
- Older root-level scratch that belonged here was moved to
  `.freebuff\scratch\repo-root-2026-09\`.
- Build caches stay in the workspace (`target/`). Never point
  `CARGO_TARGET_DIR` (or any other build cache) at a `C:` temp path — C:
  fills up fast on this machine, and the toolchain already needs ~1 GB there.
  If a cache genuinely has to live outside the repo, use
  `.freebuff\scratch\` and delete it when the run is over.- **`F:` is degraded hardware, and we build on it anyway (2026-09-27).** `F:` is
  a USB volume. An elevated `Repair-Volume -OfflineScanAndFix` on 2026-09-27
  returned `ErrorsFixed` and the volume went back to `Healthy`/`OK` with the
  dirty bit cleared, and the `Ntfs` Id 55 MFT/index corruption stopped. The
  `disk` Event Id 11 controller errors on `\Device\Harddisk1` did **not** stop
  — they are hardware/transport level, below the filesystem, and a filesystem
  repair cannot touch them. They were still firing on the evening of
  2026-09-27, so do not read `Get-Volume` reporting `Healthy` as reassurance.
  Consequence, because rustc trusts dependency metadata (`.rmeta`) read back
  off disk: an artifact landing on a bad sector panics the compiler with
  `invalid enum variant tag while decoding TyKind`, expected 0..29, actual N
  (N varies — 118 on `url`, 32 on `windows`) and then emits thousands of bogus
  trait-bound errors. That is corrupt build input, not a source regression and
  not a rustc bug.
  A `build.target-dir` override on `C:` was tried as a workaround and has been
  **removed**: this machine's storage is sparse, and a multi-GB cache on `C:`
  is not affordable. Build output stays in the workspace `target/` on `F:`, per
  the rule above.
  Mitigations that do work:
  - Build through `scripts\invoke-build.ps1`. It watches for the corruption
    signature and purges the cache with `cargo clean`, so a bad sector surfaces
    as "cache purged, rebuild" instead of a wall of fake trait errors. It also
    reports new Id 11 events per build, and exits 90 (corruption, purged),
    91 (corruption, `--no-purge`) or cargo's own code.
  - Re-check the Id 11 count before assuming the hardware settled:
    `Get-WinEvent -FilterHashtable @{LogName='System'; Id=11; StartTime=(Get-Date).AddDays(-1)}`
  - Never "fix" the resulting trait-bound errors in the source. If the errors
    are nonsense, suspect the cache.
- **Durable tooling lives in `scripts\`, not `.freebuff\scratch\`.** The
  scratch rule above is for one-off probes, logs and inventory dumps.
  `scripts\` holds things meant to be re-run — treat it as source, and do not
  delete it as part of scratch cleanup.
