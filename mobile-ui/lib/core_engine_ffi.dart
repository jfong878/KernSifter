// Dart bindings to the `core-engine` Rust cdylib.
//
// This file is *only* a marshalling layer. Every decision about what may be
// deleted lives in Rust (`core-engine/src/ffi.rs` and what it wraps); this side
// just moves JSON across the boundary and hands it to the UI. If you ever find
// yourself computing a cleanup policy here, the architecture has been broken —
// put it in the engine instead.

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

// ── native signatures ─────────────────────────────────────────────────────

typedef _VersionNative = ffi.Pointer<ffi.Char> Function();
typedef _VersionDart = ffi.Pointer<ffi.Char> Function();

typedef _IntNative = ffi.Int32 Function();
typedef _IntDart = int Function();

typedef _FreeNative = ffi.Void Function(ffi.Pointer<ffi.Char>);
typedef _FreeDart = void Function(ffi.Pointer<ffi.Char>);

typedef _AuditNative = ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char>);
typedef _AuditDart = ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char>);

typedef _PlanNative = ffi.Pointer<ffi.Char> Function(
    ffi.Pointer<ffi.Char>, ffi.Int32);
typedef _PlanDart = ffi.Pointer<ffi.Char> Function(
    ffi.Pointer<ffi.Char>, int);

typedef _BuildManifestNative = ffi.Pointer<ffi.Char> Function(
    ffi.Pointer<ffi.Char>, ffi.Int32);
typedef _BuildManifestDart = ffi.Pointer<ffi.Char> Function(
    ffi.Pointer<ffi.Char>, int);

typedef _ExecuteNative = ffi.Pointer<ffi.Char> Function(
    ffi.Pointer<ffi.Char>, ffi.Int32);
typedef _ExecuteDart = ffi.Pointer<ffi.Char> Function(
    ffi.Pointer<ffi.Char>, int);

typedef _ScanNative = ffi.Pointer<ffi.Char> Function();
typedef _ScanDart = ffi.Pointer<ffi.Char> Function();

/// Mirrors `PlatformId` in `core-engine/src/platform/mod.rs`.
///
/// The integer values are part of the ABI contract: the Rust side casts its
/// enum straight to `c_int`, so inserting a variant here without changing the
/// Rust enum (or vice versa) silently mislabels the platform.
enum CorePlatform {
  windows(0, 'Windows'),
  macOs(1, 'macOS'),
  linux(2, 'Linux'),
  android(3, 'Android'),
  hardenedAndroid(4, 'Hardened Android');

  const CorePlatform(this.id, this.label);

  /// The value the Rust enum casts to.
  final int id;
  final String label;

  /// Maps a raw ABI integer back to a platform, defaulting to [linux] rather
  /// than throwing: a newer engine may add a platform, and the shell should
  /// still render than crash.
  static CorePlatform fromId(int raw) {
    for (final p in CorePlatform.values) {
      if (p.id == raw) return p;
    }
    return CorePlatform.linux;
  }
}

/// Mirrors `Category` in `core-engine/src/scanner/walk.rs`.
///
/// The [wireName] is the exact string the Rust parser expects in the JSON array
/// passed to `ks_plan_json` and `ks_build_manifest_json`; [label] is for humans.
enum CleanupCategory {
  temp('Temp', 'Temp'),
  cache('Cache', 'Cache'),
  logs('Logs', 'Logs'),
  packageCache('PackageCache', 'Package cache'),
  prefetch('Prefetch', 'Prefetch'),
  browserCache('BrowserCache', 'Browser cache'),
  appOrphan('AppOrphan', 'AppData orphan'),
  aiModels('AiModels', 'AI models'),
  recycleBin('RecycleBin', 'Recycle bin');

  const CleanupCategory(this.wireName, this.label);

  final String wireName;
  final String label;
}

/// Thrown when the engine reports a failure.
///
/// The message always comes from the engine (`ks_last_error`), never from a
/// guess made on this side, so a user-visible error is the one Rust actually
/// produced.
class CoreEngineException implements Exception {
  CoreEngineException(this.message);

  final String message;

  @override
  String toString() => 'CoreEngineException: $message';
}

/// Raised when the loaded `core_engine` library is too old or too new for this
/// Dart code. Refusing to bind is deliberate: a mismatched engine could return
/// JSON in a shape the UI would silently misread.
class CoreEngineAbiMismatch implements Exception {
  CoreEngineAbiMismatch(this.found, this.expected);

  final int found;
  final int expected;

  @override
  String toString() =>
      'core-engine ABI $found is incompatible with this app (expected '
      '${expected ~/ 10000}.x). Rebuild the native library for this target.';
}

/// The Dart-side handle on the native engine.
///
/// One instance per process: the Rust side keeps a thread-local error slot, and
/// the UI runs on the platform thread, so a single shared instance keeps error
/// reporting coherent. Construct it once and pass it down.
class CoreEngine {
  CoreEngine._(this._lib)
      : version = _lib
            .lookupFunction<_VersionNative, _VersionDart>('ks_version')()
            .cast<Utf8>()
            .toDartString(),
        abiVersion =
            _lib.lookupFunction<_IntNative, _IntDart>('ks_abi_version')() {
    final expectedMajor = kExpectedAbiMajor;
    if (abiVersion ~/ 10000 != expectedMajor) {
      throw CoreEngineAbiMismatch(abiVersion, expectedMajor * 10000);
    }
  }

  /// The ABI major this Dart code was written against.
  static const int kExpectedAbiMajor = 1;

  final ffi.DynamicLibrary _lib;

  /// The engine's crate version, e.g. `0.1.0`.
  final String version;

  /// The engine's ABI version, `<major> * 10000 + <minor> * 100 + <patch>`.
  final int abiVersion;

  late final _FreeDart _free = _lib.lookupFunction<_FreeNative, _FreeDart>(
    'ks_string_free',
  );
  late final _VersionDart _lastError =
      _lib.lookupFunction<_VersionNative, _VersionDart>('ks_last_error');
  late final _IntDart _platformId =
      _lib.lookupFunction<_IntNative, _IntDart>('ks_platform_id');
  late final _VersionDart _platformName =
      _lib.lookupFunction<_VersionNative, _VersionDart>('ks_platform_name');
  late final _AuditDart _auditPath =
      _lib.lookupFunction<_AuditNative, _AuditDart>('ks_audit_path');
  late final _ScanDart _scanJson =
      _lib.lookupFunction<_ScanNative, _ScanDart>('ks_scan_json');
  late final _PlanDart _planJson =
      _lib.lookupFunction<_PlanNative, _PlanDart>('ks_plan_json');
  late final _BuildManifestDart _buildManifest =
      _lib.lookupFunction<_BuildManifestNative, _BuildManifestDart>(
    'ks_build_manifest_json',
  );
  late final _ExecuteDart _executeManifest =
      _lib.lookupFunction<_ExecuteNative, _ExecuteDart>('ks_execute_manifest');

  /// Opens an engine at an explicit library path.
  ///
  /// Exists for the live boundary test, which has to load a cross-compiled
  /// library that [open]'s per-platform lookup would not find. The ABI check in
  /// the constructor still applies, so this cannot be used to bypass it.
  @visibleForTesting
  static CoreEngine openAt(String path) =>
      CoreEngine._(ffi.DynamicLibrary.open(path));

  /// Opens the native library, verifying the ABI before returning.
  ///
  /// On a device or emulator the library ships inside the app bundle; on the
  /// host it is looked up in the conventional places. A missing library is a
  /// build/packaging bug, so it is reported as such rather than swallowed.
  static CoreEngine open() {
    final lib = _openLibrary();
    return CoreEngine._(lib);
  }

  static ffi.DynamicLibrary _openLibrary() {
    if (Platform.isAndroid) return ffi.DynamicLibrary.open('libcore_engine.so');
    if (Platform.isIOS || Platform.isMacOS) {
      // `DynamicLibrary.process()` resolves symbols already linked into the
      // executable, which is how a statically linked iOS build exposes them.
      try {
        return ffi.DynamicLibrary.process();
      } on ArgumentError {
        return ffi.DynamicLibrary.open('libcore_engine.dylib');
      }
    }
    if (Platform.isWindows) return ffi.DynamicLibrary.open('core_engine.dll');
    if (Platform.isLinux) return ffi.DynamicLibrary.open('libcore_engine.so');
    throw UnsupportedError(
      'KernSifter has no native core for ${Platform.operatingSystem}.',
    );
  }

  /// The host platform, as the engine sees it.
  CorePlatform get platform => CorePlatform.fromId(_platformId());

  /// The host platform's display name from the engine.
  String get platformName => _platformName().cast<Utf8>().toDartString();

  /// Takes ownership of a returned C string, decodes it, and frees it.
  ///
  /// A null return means the engine failed; the message comes from
  /// [lastError]. Every returned pointer goes through here exactly once, so the
  /// library cannot leak across a long-running scan session.
  Map<String, dynamic> _takeJson(ffi.Pointer<ffi.Char> ptr) {
    if (ptr == ffi.nullptr) {
      throw CoreEngineException(lastError);
    }
    try {
      final decoded = jsonDecode(ptr.cast<Utf8>().toDartString());
      if (decoded is! Map<String, dynamic>) {
        throw CoreEngineException(
          'engine returned ${decoded.runtimeType}, expected a JSON object',
        );
      }
      return decoded;
    } finally {
      _free(ptr);
    }
  }

  /// The engine's last error on this thread, or `ok`.
  String get lastError => _lastError().cast<Utf8>().toDartString();

  /// Validates one path against the protected-path matrix.
  ///
  /// Returns a map with `path`, `allowed`, `reason` and `rule`.
  Map<String, dynamic> auditPath(String path) {
    final native = path.toNativeUtf8();
    try {
      return _takeJson(_auditPath(native.cast<ffi.Char>()));
    } finally {
      calloc.free(native);
    }
  }

  /// Runs a platform scan and returns the raw report JSON.
  ///
  /// Read-only; nothing is modified. This walks every sanctioned root, so on a
  /// real device it is not fast — run it off the UI thread.
  Map<String, dynamic> scan() => _takeJson(_scanJson());

  /// The executor's cleanup plan: what may be cleaned, and what was declined
  /// with a reason for every decline.
  ///
  /// [categories] empty means a "smart clean" over the platform's routine
  /// categories. [includeRecent] relaxes only the age floors; manual-only,
  /// unsupported and matrix-blocked candidates stay excluded either way.
  Map<String, dynamic> plan({
    List<CleanupCategory> categories = const [],
    bool includeRecent = false,
  }) {
    final native = jsonEncode(
      categories.map((c) => c.wireName).toList(),
    ).toNativeUtf8();
    try {
      return _takeJson(_planJson(native.cast<ffi.Char>(),
          includeRecent ? 1 : 0));
    } finally {
      calloc.free(native);
    }
  }

  /// Freezes the current plan into a manifest, returning the manifest JSON.
  ///
  /// This is the dry run: nothing is touched. The returned JSON is the exact
  /// input [executeManifest] expects, and it is what the user should be shown
  /// and asked to confirm.
  Map<String, dynamic> buildManifest({
    List<CleanupCategory> categories = const [],
    bool includeRecent = false,
  }) {
    final native =
        jsonEncode(categories.map((c) => c.wireName).toList()).toNativeUtf8();
    try {
      return _takeJson(
        _buildManifest(native.cast<ffi.Char>(), includeRecent ? 1 : 0),
      );
    } finally {
      calloc.free(native);
    }
  }

  /// Executes a manifest produced by [buildManifest].
  ///
  /// [simulate] must stay true for anything short of a deliberate, confirmed
  /// cleanup: the UI is expected to run the simulation, show the result, and
  /// only then ask. Execution re-validates every path against the matrix, so a
  /// manifest edited between build and execute cannot smuggle a protected path
  /// through — but the caller is still responsible for having shown it.
  Map<String, dynamic> executeManifest(
    Map<String, dynamic> manifest, {
    required bool simulate,
  }) {
    final native = jsonEncode(manifest).toNativeUtf8();
    try {
      return _takeJson(_executeManifest(native.cast<ffi.Char>(),
          simulate ? 1 : 0));
    } finally {
      calloc.free(native);
    }
  }
}
