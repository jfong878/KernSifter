// Typed views over the engine's JSON.
//
// The engine's payloads are the source of truth; these classes only give them
// names and types so widgets don't index into raw maps. Parsing is defensive:
// a missing or unexpectedly-shaped field degrades to a sane default rather
// than throwing in the middle of a build, because a newer engine adding a field
// must not crash an older shell.

import 'core_engine_ffi.dart';

/// Formats a byte count for display, matching the CLI's units.
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return unit == 0 ? '$bytes B' : '${value.toStringAsFixed(1)} ${units[unit]}';
}

/// One candidate the engine selected for cleanup.
class EligibleEntry {
  const EligibleEntry({
    required this.path,
    required this.category,
    required this.sizeBytes,
  });

  final String path;
  final CleanupCategory? category;
  final int sizeBytes;

  /// The file name only — the full path is long enough to break any row.
  String get name {
    final slash = _lastSeparator;
    return slash == -1 ? path : path.substring(slash + 1);
  }

  /// The parent directory, for the secondary line under the name.
  String get parent {
    final slash = _lastSeparator;
    return slash <= 0 ? '' : path.substring(0, slash);
  }

  /// Index of the final path separator, accepting either platform's style.
  ///
  /// The substring is taken from [path] itself rather than from a normalized
  /// copy: a Windows path shown to a Windows user must keep its backslashes.
  /// Only the *position* of the separator matters, not its character.
  int get _lastSeparator {
    final backslash = path.lastIndexOf(r'\');
    final forward = path.lastIndexOf('/');
    return backslash > forward ? backslash : forward;
  }

  factory EligibleEntry.fromJson(Map<String, dynamic> json) {
    return EligibleEntry(
      path: json['path'] as String? ?? '',
      category: _categoryFromWire(json['category'] as String?),
      sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
    );
  }
}

/// One candidate the engine declined, with the reason.
class SkippedEntry {
  const SkippedEntry({
    required this.path,
    required this.category,
    required this.sizeBytes,
    required this.reason,
    required this.message,
    required this.permanent,
  });

  final String path;
  final CleanupCategory? category;
  final int sizeBytes;
  final String reason;

  /// The engine's human-readable explanation, e.g. "only 2 day(s) old — the
  /// floor is 7". Shown verbatim: the engine phrased it, so the UI does not
  /// have to and cannot drift from it.
  final String message;

  /// Whether the decline is permanent, as opposed to an age floor the
  /// candidate may simply be too young for. Permanent declines are the ones a
  /// user should stop being surprised by.
  final bool permanent;

  factory SkippedEntry.fromJson(Map<String, dynamic> json) {
    return SkippedEntry(
      path: json['path'] as String? ?? '',
      category: _categoryFromWire(json['category'] as String?),
      sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
      reason: _reasonTag(json['reason']),
      message: _skipMessageFromWire(json['reason']),
      permanent: _reasonIsPermanent(json['reason']),
    );
  }
}

/// Extracts the variant name from a `SkipReason`.
///
/// Serde serializes this externally tagged, so a unit variant arrives as the
/// bare string `"BlockedByMatrix"` while a variant carrying data arrives as
/// `{"TooRecent": {"age_days": 2, "min_age_days": 7}}`. Both must be read.
String _reasonTag(dynamic reason) {
  if (reason is String) return reason;
  if (reason is Map && reason.length == 1) {
    return reason.keys.first.toString();
  }
  if (reason == null) return 'Unknown';
  return reason.toString();
}

/// A readable explanation for a serialized reason.
///
/// The engine's own `SkipReason::message()` is authoritative, but the per-entry
/// `skipped` list only carries the enum tag — only the aggregated summary
/// includes the phrasing. Rather than reimplement the wording here (which would
/// drift from the engine), the tag is shown and the engine's phrasing is used
/// wherever the engine supplied it.
String _skipMessageFromWire(dynamic reason) {
  final tag = _reasonTag(reason);
  if (tag == 'TooRecent' && reason is Map) {
    final detail = reason['TooRecent'];
    if (detail is Map) {
      final age = detail['age_days'];
      final floor = detail['min_age_days'];
      if (age is num && floor is num) {
        return 'only ${age.toInt()} day(s) old — the floor is ${floor.toInt()}';
      }
    }
  }
  return tag;
}

/// Whether the decline is permanent.
///
/// Mirrors `SkipReason::is_permanent` on the Rust side: only the age-related
/// reasons are temporary, and only those may clear on a later scan.
bool _reasonIsPermanent(dynamic reason) {
  final tag = _reasonTag(reason);
  return tag != 'TooRecent' && tag != 'AgeUnknown';
}

/// A reason bucket in the "why is this still here?" panel.
class SkipReasonSummary {
  const SkipReasonSummary({
    required this.reason,
    required this.message,
    required this.bytes,
    required this.permanent,
  });

  final String reason;
  final String message;
  final int bytes;
  final bool permanent;

  factory SkipReasonSummary.fromJson(Map<String, dynamic> json) {
    return SkipReasonSummary(
      reason: json['reason'] as String? ?? 'Unknown',
      message: json['message'] as String? ?? 'no reason given',
      bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      permanent: json['permanent'] as bool? ?? true,
    );
  }
}

/// The executor's verdict on a scan: what may be cleaned, what was not.
class CleanupPlan {
  const CleanupPlan({
    required this.platform,
    required this.eligible,
    required this.skipped,
    required this.skipSummaries,
    required this.needsElevation,
  });

  final CorePlatform platform;
  final List<EligibleEntry> eligible;
  final List<SkippedEntry> skipped;
  final List<SkipReasonSummary> skipSummaries;
  final bool needsElevation;

  int get eligibleCount => eligible.length;
  int get eligibleBytes =>
      eligible.fold(0, (sum, e) => sum + e.sizeBytes);
  int get skippedCount => skipped.length;

  /// The largest eligible entries, biggest first — the answer to "what am I
  /// actually getting back".
  List<EligibleEntry> get largestEligible {
    final sorted = List<EligibleEntry>.of(eligible)
      ..sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
    return sorted;
  }

  factory CleanupPlan.fromJson(Map<String, dynamic> json) {
    List<T> parseList<T>(String key, T Function(Map<String, dynamic>) build) {
      final raw = json[key];
      if (raw is! List) return const [];
      return raw
          .whereType<Map<String, dynamic>>()
          .map(build)
          .toList(growable: false);
    }

    return CleanupPlan(
      platform: _platformFromWire(json['platform']),
      eligible: parseList('eligible', EligibleEntry.fromJson),
      skipped: parseList('skipped', SkippedEntry.fromJson),
      skipSummaries:
          parseList('skipped_bytes_by_reason', SkipReasonSummary.fromJson),
      needsElevation: json['needs_elevation'] as bool? ?? false,
    );
  }
}

/// A frozen dry-run manifest, ready for the engine to execute.
class DryRunManifest {
  const DryRunManifest({
    required this.raw,
    required this.id,
    required this.entryCount,
    required this.totalBytes,
    required this.cleanableBytes,
    required this.blockedCount,
  });

  /// The exact JSON handed back to the engine at execution time. It is kept
  /// verbatim rather than rebuilt from the fields above, because the engine
  /// re-verifies this document and a re-serialized copy could differ.
  final Map<String, dynamic> raw;

  final int id;
  final int entryCount;
  final int totalBytes;
  final int cleanableBytes;
  final int blockedCount;

  factory DryRunManifest.fromJson(Map<String, dynamic> json) {
    return DryRunManifest(
      raw: json,
      id: (json['id'] as num?)?.toInt() ?? 0,
      entryCount: (json['entries'] as List?)?.length ?? 0,
      totalBytes: (json['total_bytes'] as num?)?.toInt() ?? 0,
      cleanableBytes: (json['cleanable_bytes'] as num?)?.toInt() ?? 0,
      blockedCount: (json['blocked_count'] as num?)?.toInt() ?? 0,
    );
  }
}

/// What the engine did (or would have done) for one path.
class ExecutionOutcome {
  const ExecutionOutcome({
    required this.path,
    required this.status,
    required this.detail,
  });

  final String path;
  final String status;
  final String? detail;

  bool get isProblem =>
      status == 'Blocked' || status == 'Failed' || status == 'Missing';

  factory ExecutionOutcome.fromJson(Map<String, dynamic> json) {
    return ExecutionOutcome(
      path: json['path'] as String? ?? '',
      status: json['status'] as String? ?? 'Unknown',
      detail: json['detail'] as String?,
    );
  }
}

/// The result of a simulated or real execution.
class ExecutionReport {
  const ExecutionReport({
    required this.simulated,
    required this.trashedBytes,
    required this.simulatedBytes,
    required this.outcomes,
  });

  final bool simulated;
  final int trashedBytes;
  final int simulatedBytes;
  final List<ExecutionOutcome> outcomes;

  /// The bytes actually affected, whether simulated or real. The engine splits
  /// these because a simulation must never be able to report a real number.
  int get affectedBytes => simulated ? simulatedBytes : trashedBytes;

  /// Outcomes the user should look at: blocked, failed or vanished.
  List<ExecutionOutcome> get problems =>
      outcomes.where((o) => o.isProblem).toList(growable: false);

  factory ExecutionReport.fromJson(Map<String, dynamic> json) {
    final raw = json['outcomes'];
    return ExecutionReport(
      simulated: json['simulated'] as bool? ?? true,
      trashedBytes: (json['trashed_bytes'] as num?)?.toInt() ?? 0,
      simulatedBytes: (json['simulated_bytes'] as num?)?.toInt() ?? 0,
      outcomes: raw is List
          ? raw
              .whereType<Map<String, dynamic>>()
              .map(ExecutionOutcome.fromJson)
              .toList(growable: false)
          : const [],
    );
  }
}

CleanupCategory? _categoryFromWire(String? wire) {
  if (wire == null) return null;
  for (final c in CleanupCategory.values) {
    if (c.wireName == wire) return c;
  }
  return null;
}

/// Reads the platform from either serialized form.
///
/// `CleanupPlan::platform` is a `PlatformId` enum, so serde sends the variant
/// *name* ("Windows"); `ks_platform_id` separately reports the numeric ABI id.
/// Both are accepted so the shell works whichever one it is handed.
CorePlatform _platformFromWire(dynamic wire) {
  if (wire is num) return CorePlatform.fromId(wire.toInt());
  if (wire is String) {
    final byLabel = wire.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    for (final p in CorePlatform.values) {
      if (p.label.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '') == byLabel) {
        return p;
      }
    }
  }
  return CorePlatform.linux;
}
