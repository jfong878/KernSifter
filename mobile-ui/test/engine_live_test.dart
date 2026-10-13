// A live test of the Dart <-> Rust boundary.
//
// This one DOES load the native library and call across it, which the rest of
// the suite deliberately avoids. It is the only test that can catch a mismatch
// between the `dart:ffi` signatures here and the `extern "C"` definitions in
// `core-engine/src/ffi.rs` — a class of bug that type-checks perfectly on both
// sides and still segfaults at runtime.
//
// It is skipped unless a built library is pointed at by KS_ENGINE_LIB, because
// the library is cross-compiled per target and a host test run has no
// guarantee one exists. Everything here is read-only or simulated: the
// destructive path is never taken.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kernsifter/core_engine_ffi.dart';
import 'package:kernsifter/models.dart';

/// Overrides library discovery so the test can load a build for any target.
String? get _libraryPath => Platform.environment['KS_ENGINE_LIB'];

void main() {
  final libPath = _libraryPath;

  group('live engine binding', () {
    late CoreEngine engine;

    setUpAll(() {
      // Reuse the same lookup strategy as the app, but allow an override.
      if (libPath == null) return;
      engine = CoreEngine.openAt(libPath);
    });

    test('reports a version and a matching ABI', () {
      if (libPath == null) {
        markTestSkipped('set KS_ENGINE_LIB to a built core_engine library');
        return;
      }
      expect(engine.version, isNotEmpty);
      expect(
        engine.abiVersion ~/ 10000,
        CoreEngine.kExpectedAbiMajor,
        reason: 'the Dart bindings and the library disagree about the ABI',
      );
    });

    test('identifies its platform', () {
      if (libPath == null) {
        markTestSkipped('set KS_ENGINE_LIB to a built core_engine library');
        return;
      }
      expect(engine.platformName, isNotEmpty);
      expect(CorePlatform.values.map((p) => p.id), contains(engine.platform.id));
    });

    test('audits a path and returns a verdict', () {
      if (libPath == null) {
        markTestSkipped('set KS_ENGINE_LIB to a built core_engine library');
        return;
      }
      final verdict = engine.auditPath(Platform.pathSeparator == r'\'
          ? r'C:\Windows\Temp\ks-probe.tmp'
          : '/tmp/ks-probe.tmp');
      expect(verdict['allowed'], isA<bool>());
      expect(verdict['reason'], anyOf(isNull, isA<String>()));
    });

    test('a null-result call reports the engine error rather than crashing',
        () {
      if (libPath == null) {
        markTestSkipped('set KS_ENGINE_LIB to a built core_engine library');
        return;
      }
      // A manifest that is not a manifest must be refused, not executed.
      expect(
        () => engine.executeManifest({'version': 999}, simulate: true),
        throwsA(isA<CoreEngineException>()),
      );
    });

    test('the error slot recovers after a failure', () {
      if (libPath == null) {
        markTestSkipped('set KS_ENGINE_LIB to a built core_engine library');
        return;
      }
      try {
        engine.executeManifest({'version': 999}, simulate: true);
      } on CoreEngineException {
        // expected
      }
      // A thread-local error slot that never resets would leave the UI
      // permanently showing a stale failure.
      final verdict = engine.auditPath('/tmp/ks-probe.tmp');
      expect(verdict['allowed'], isA<bool>());
      expect(engine.lastError, 'ok');
    });

    test('the ABI is checked before any call is trusted', () {
      if (libPath == null) {
        markTestSkipped('set KS_ENGINE_LIB to a built core_engine library');
        return;
      }
      // Constructing the engine already validated the major version, so a
      // mismatch would have thrown in setUpAll rather than producing garbage
      // JSON. Reaching here means the check passed.
      expect(engine.abiVersion, greaterThan(0));
    });

    test('a real plan parses into the model the UI renders', () {
      if (libPath == null) {
        markTestSkipped('set KS_ENGINE_LIB to a built core_engine library');
        return;
      }
      // Read-only: `plan` never modifies anything.
      final plan = CleanupPlan.fromJson(engine.plan());
      expect(plan.eligibleCount, greaterThanOrEqualTo(0));
      expect(plan.skippedCount, greaterThanOrEqualTo(0));
      for (final entry in plan.eligible) {
        expect(entry.path, isNotEmpty);
      }
    });
  }, skip: libPath == null ? 'set KS_ENGINE_LIB to run the live binding test' : null);
}
