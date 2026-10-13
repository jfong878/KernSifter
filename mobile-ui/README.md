# mobile-ui (Flutter)

Thin mobile shell binding the compiled `core-engine` Rust library via FFI.
Cleaning logic never lives here — only UI, FFI glue, and the flow that makes
the user confirm before anything is removed.

## Layout

```
mobile-ui/
├── lib/
│   ├── main.dart              # UI: scan → plan → manifest → dry run → confirm
│   ├── core_engine_ffi.dart   # dart:ffi bindings to the core-engine cdylib
│   └── models.dart            # typed views over the engine's JSON
├── test/
│   ├── models_test.dart       # parsing and the invariants the UI depends on
│   └── engine_live_test.dart  # loads the real .so/.dll and calls across FFI
├── android/                   # bundles libcore_engine.so (per ABI)
└── ios/                       # links core_engine
```

## The rule this shell follows

`lib/core_engine_ffi.dart` marshals JSON and nothing else. Every decision about
what may be deleted is made in Rust. If you find yourself writing a cleanup
condition in Dart, the architecture has been broken — put it in the engine.

The UI does enforce one thing, because it is a flow rather than a policy: the
**dry-run gate**. `executeManifest` is never called with `simulate: false`
unless a simulation of that same manifest has already been shown to the user.
The engine independently refuses to act on an unverified manifest; the UI just
makes sure the user is never asked to confirm something they have not seen.

## Building the native library

The Dart side expects a `cdylib`. The Rust crate emits one alongside the `rlib`
the desktop shell and tests use — same source, so the two cannot drift.

```bash
# Android (per ABI: armeabi-v7a, arm64-v8a, x86_64)
cross build -p core-engine --release --target aarch64-linux-android
cp target/aarch64-linux-android/release/libcore_engine.so \
   android/app/src/main/jniLibs/arm64-v8a/

# iOS / desktop host
cargo build -p core-engine --release          # libcore_engine.dylib / .so / .dll
```

On iOS the symbols are linked into the app binary, so `CoreEngine.open()` uses
`DynamicLibrary.process()` rather than opening a file.

## ABI compatibility

`ffi.rs` exports a version number as `<major> * 10000 + <minor> * 100 + <patch>`.
`CoreEngine.open()` compares the **major** against `kExpectedAbiMajor` and
throws `CoreEngineAbiMismatch` if they differ. Refusing to bind is deliberate: a
mismatched engine could return JSON in a shape this UI would silently misread.

Bump the major when a function changes meaning or disappears, the minor when
one is added.

## Testing

```bash
flutter analyze
flutter test                                    # unit tests only; live ones skip

# Exercise the real FFI boundary against a built library:
KS_ENGINE_LIB=../target/debug/libcore_engine.so flutter test
```

`engine_live_test.dart` is the only test that crosses into Rust, and it is
skipped unless `KS_ENGINE_LIB` points at a built library — the library is
cross-compiled per target, so a host test run has no guarantee one exists. It
is worth running: a signature mismatch between `dart:ffi` and `extern "C"`
type-checks cleanly on both sides and still fails at runtime.

Everything it does is read-only or simulated. It never takes the destructive
path.

## Platform strategy (mirrors the core's conditional abstraction)

- **Standard AOSP:** scoped storage + `MediaStore` queries and the cache
  directories the system API permits. No `MANAGE_EXTERNAL_STORAGE`.
- **Hardened Android (GrapheneOS / CalyxOS):** Storage Access Framework only —
  the app asks the user to explicitly pick target directories. The core's
  Android matrix is empty by design; the OS sandbox is the boundary.
- **iOS:** `NSTemporaryDirectory()` purging plus a guided manual storage
  offload dashboard.
