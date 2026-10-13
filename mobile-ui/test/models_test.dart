// Tests for the shell.
//
// These do not load the native library: a Flutter test runs on the host, where
// the .so/.dll may not be built, and a test that needs a device build to be
// meaningful is a test nobody runs. What is tested here is the part that can
// silently go wrong on the Dart side — parsing the engine's JSON, and the
// invariants the UI relies on before it will let the user confirm a cleanup.
//
// The engine's own behaviour is covered by the Rust test suite
// (`cargo test -p core-engine`), including the FFI boundary itself.

import 'package:flutter_test/flutter_test.dart';
import 'package:kernsifter/core_engine_ffi.dart';
import 'package:kernsifter/models.dart';

void main() {
  group('formatBytes', () {
    test('renders each unit the way the CLI does', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes(3 * 1024 * 1024 * 1024), '3.0 GB');
    });

    test('never renders a negative or nonsensical size', () {
      expect(formatBytes(-1), '0 B');
    });
  });

  group('CleanupCategory', () {
    test('wire names are unique', () {
      final names = CleanupCategory.values.map((c) => c.wireName).toSet();
      expect(names.length, CleanupCategory.values.length);
    });

    test('every category has a human label', () {
      for (final c in CleanupCategory.values) {
        expect(c.label, isNotEmpty, reason: c.name);
      }
    });
  });

  group('CleanupPlan.fromJson', () {
    test('parses eligible, skipped and reason summaries', () {
      final plan = CleanupPlan.fromJson({
        'platform': 3,
        'needs_elevation': false,
        'eligible': [
          {'path': r'C:\a\b.tmp', 'category': 'Temp', 'size_bytes': 100},
          {'path': r'C:\c\d.log', 'category': 'Logs', 'size_bytes': 250},
        ],
        'skipped': [
          {
            'path': r'C:\e\f.dat',
            'category': 'Cache',
            'size_bytes': 50,
            'reason': 'TooRecent',
          },
        ],
        'skipped_bytes_by_reason': [
          {
            'reason': 'TooRecent',
            'message': 'only 2 day(s) old — the floor is 7',
            'permanent': false,
            'bytes': 50,
          },
        ],
      });

      expect(plan.platform, CorePlatform.android);
      expect(plan.eligibleCount, 2);
      expect(plan.eligibleBytes, 350);
      expect(plan.skippedCount, 1);
      expect(plan.needsElevation, isFalse);

      // Sorted biggest-first: the UI's "largest first" list depends on this.
      expect(plan.largestEligible.first.sizeBytes, 250);
      expect(plan.largestEligible.first.category, CleanupCategory.logs);
    });

    test('an empty plan is valid and reports zero, not null', () {
      final plan = CleanupPlan.fromJson({
        'platform': 0,
        'eligible': <dynamic>[],
        'skipped': <dynamic>[],
        'skipped_bytes_by_reason': <dynamic>[],
      });
      expect(plan.eligibleCount, 0);
      expect(plan.eligibleBytes, 0);
      expect(plan.skippedCount, 0);
    });

    test('tolerates a payload missing optional fields', () {
      // A newer engine may omit a field; the shell must degrade, not crash
      // mid-build.
      final plan = CleanupPlan.fromJson({'platform': 0});
      expect(plan.eligible, isEmpty);
      expect(plan.skipped, isEmpty);
      expect(plan.needsElevation, isFalse);
    });

    test('ignores malformed entries rather than throwing', () {
      final plan = CleanupPlan.fromJson({
        'platform': 0,
        'eligible': [
          'not an object',
          {'path': r'C:\ok.tmp', 'category': 'Temp', 'size_bytes': 10},
        ],
      });
      expect(plan.eligibleCount, 1);
      expect(plan.eligible.first.sizeBytes, 10);
    });

    test('accepts the platform as a name, which is how serde sends it', () {
      // `CleanupPlan::platform` is a PlatformId enum, so the real payload
      // carries "Windows", not 0. A model that only handled the integer would
      // throw on every live plan.
      final plan = CleanupPlan.fromJson({
        'platform': 'Windows',
        'eligible': <dynamic>[],
        'skipped': <dynamic>[],
      });
      expect(plan.platform, CorePlatform.windows);

      expect(CleanupPlan.fromJson({'platform': 'Hardened Android'}).platform,
          CorePlatform.hardenedAndroid);
    });

    test('accepts the platform as an integer too', () {
      expect(CleanupPlan.fromJson({'platform': 3}).platform,
          CorePlatform.android);
    });

    test('reads an externally tagged skip reason with data', () {
      // Serde sends `TooRecent { age_days, min_age_days }` as an object, not a
      // string, so the parser must handle both shapes.
      final plan = CleanupPlan.fromJson({
        'platform': 'Windows',
        'eligible': <dynamic>[],
        'skipped': [
          {
            'path': r'C:\x',
            'category': 'Temp',
            'size_bytes': 5,
            'reason': {
              'TooRecent': {'age_days': 2, 'min_age_days': 7}
            },
          },
        ],
      });
      final skipped = plan.skipped.single;
      expect(skipped.reason, 'TooRecent');
      expect(skipped.message, contains('2 day(s) old'));
      expect(skipped.message, contains('floor is 7'));
      // An age floor is not a permanent refusal — it may clear on a later scan.
      expect(skipped.permanent, isFalse);
    });

    test('reads a unit skip reason as a bare string', () {
      final plan = CleanupPlan.fromJson({
        'platform': 'Windows',
        'eligible': <dynamic>[],
        'skipped': [
          {
            'path': r'C:\x',
            'category': 'Temp',
            'size_bytes': 5,
            'reason': 'BlockedByMatrix',
          },
        ],
      });
      final skipped = plan.skipped.single;
      expect(skipped.reason, 'BlockedByMatrix');
      expect(skipped.permanent, isTrue);
    });

    test('an unknown category name degrades to null, not a crash', () {
      final entry = EligibleEntry.fromJson({
        'path': r'C:\x',
        'category': 'SomeFutureCategory',
        'size_bytes': 1,
      });
      expect(entry.category, isNull);
    });
  });

  group('EligibleEntry path handling', () {
    test('splits a Windows path into name and parent', () {
      final entry = EligibleEntry.fromJson({
        'path': r'C:\Users\me\AppData\Local\Temp\thing.tmp',
        'size_bytes': 1,
      });
      expect(entry.name, 'thing.tmp');
      expect(entry.parent, r'C:\Users\me\AppData\Local\Temp');
    });

    test('splits a POSIX path into name and parent', () {
      final entry = EligibleEntry.fromJson({
        'path': '/var/tmp/thing.sock',
        'size_bytes': 1,
      });
      expect(entry.name, 'thing.sock');
      expect(entry.parent, '/var/tmp');
    });

    test('handles a bare filename with no directory', () {
      final entry =
          EligibleEntry.fromJson({'path': 'loose.tmp', 'size_bytes': 1});
      expect(entry.name, 'loose.tmp');
      expect(entry.parent, '');
    });
  });

  group('DryRunManifest', () {
    test('keeps the raw JSON it was given, for round-tripping', () {
      // The engine re-verifies this exact document at execution time, so the
      // shell must pass back what it received rather than re-serializing a
      // subset of the fields it parsed.
      final raw = <String, dynamic>{
        'version': 1,
        'id': 7,
        'entries': [
          {'path': '/a', 'size_bytes': 1}
        ],
        'total_bytes': 1,
        'cleanable_bytes': 1,
        'blocked_count': 0,
      };
      final manifest = DryRunManifest.fromJson(raw);
      expect(manifest.id, 7);
      expect(manifest.entryCount, 1);
      expect(manifest.cleanableBytes, 1);
      expect(manifest.blockedCount, 0);
      expect(identical(manifest.raw, raw), isTrue,
          reason: 'the raw payload must be the same object handed in');
    });
  });

  group('ExecutionReport', () {
    test('a simulation reports simulated bytes, never trashed bytes', () {
      final report = ExecutionReport.fromJson({
        'simulated': true,
        'trashed_bytes': 0,
        'simulated_bytes': 900,
        'outcomes': [
          {'path': '/a', 'status': 'Simulated'},
        ],
      });
      expect(report.affectedBytes, 900);
      expect(report.problems, isEmpty);
    });

    test('surfaces blocked, failed and missing as problems', () {
      final report = ExecutionReport.fromJson({
        'simulated': true,
        'simulated_bytes': 10,
        'outcomes': [
          {'path': '/a', 'status': 'Simulated'},
          {'path': '/b', 'status': 'Blocked', 'detail': 'matrix'},
          {'path': '/c', 'status': 'Failed', 'detail': 'io'},
          {'path': '/d', 'status': 'Missing'},
          {'path': '/e', 'status': 'Trashed'},
        ],
      });
      expect(report.problems.length, 3);
      expect(report.problems.map((p) => p.status), containsAll(['Blocked', 'Failed', 'Missing']));
    });
  });

  group('CorePlatform', () {
    test('maps ABI integers back to platforms', () {
      expect(CorePlatform.fromId(0), CorePlatform.windows);
      expect(CorePlatform.fromId(3), CorePlatform.android);
      expect(CorePlatform.fromId(4), CorePlatform.hardenedAndroid);
    });

    test('an unknown integer falls back instead of throwing', () {
      // A newer engine could add a platform; the shell should still render.
      expect(CorePlatform.fromId(99), CorePlatform.linux);
    });

    test('ids are unique', () {
      final ids = CorePlatform.values.map((p) => p.id).toSet();
      expect(ids.length, CorePlatform.values.length);
    });
  });
}
