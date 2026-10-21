// KernSifter — mobile shell.
//
// A thin Flutter UI over the core-engine Rust safety core. The screens below
// contain no cleanup policy at all: they show what the engine decided, ask the
// user to confirm, and hand the result back to the engine to act on.
//
// The one rule the UI does enforce is the flow itself: scan → plan → dry-run
// manifest → simulate → confirm → execute. Nothing reaches [CoreEngine
// .executeManifest] with `simulate: false` unless the user has seen the
// simulated result for that exact manifest.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'auth.dart';
import 'core_engine_ffi.dart';
import 'models.dart';
import 'token_store.dart';

/// Where the sync Worker lives. Supplied at build time, never guessed:
///
///   flutter run --dart-define=KERNSIFTER_SYNC_ORIGIN=https://kernsifter-sync.<sub>.workers.dev
///
/// Empty by default, so an unconfigured build says so instead of failing in a
/// way that looks like a bug in the app.
const String _syncOrigin = String.fromEnvironment('KERNSIFTER_SYNC_ORIGIN');

void main() {
  runApp(const KernSifterApp());
}

/// Owns the engine handle and the current view state.
///
/// A plain [ChangeNotifier] rather than a state-management package: the app
/// has one screen's worth of state, and a dependency-free shell is one less
/// thing to keep in step with the Rust core.
class KernSifterController extends ChangeNotifier {
  KernSifterController(this.engine);

  final CoreEngine engine;

  CleanupPlan? _plan;
  DryRunManifest? _manifest;
  ExecutionReport? _report;
  bool _busy = false;
  String? _error;
  final Set<CleanupCategory> _selected = <CleanupCategory>{};
  bool _includeRecent = false;

  CleanupPlan? get plan => _plan;
  DryRunManifest? get manifest => _manifest;
  ExecutionReport? get report => _report;
  bool get busy => _busy;
  String? get error => _error;
  Set<CleanupCategory> get selected => Set.unmodifiable(_selected);
  bool get includeRecent => _includeRecent;

  /// True once a simulation for the *current* manifest has been shown. Only
  /// then may the user execute for real.
  bool get hasSimulated => _report != null && _report!.simulated;

  void toggleCategory(CleanupCategory c) {
    if (_selected.contains(c)) {
      _selected.remove(c);
    } else {
      _selected.add(c);
    }
    notifyListeners();
  }

  void setIncludeRecent(bool value) {
    _includeRecent = value;
    notifyListeners();
  }

  /// Runs a scan and asks the engine for its plan.
  ///
  /// Runs on an isolate-free background task: the walk touches every sanctioned
  /// root and would otherwise block the UI thread for seconds.
  Future<void> scan() async {
    _busy = true;
    _error = null;
    _plan = null;
    _manifest = null;
    _report = null;
    notifyListeners();

    try {
      final json = await compute(_planOnBackground, _PlanRequest(
        categories: _selected.toList(),
        includeRecent: _includeRecent,
        libraryPath: null,
      ));
      _plan = CleanupPlan.fromJson(json);
    } catch (e) {
      _error = 'Scan failed: $e';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Freezes the current plan into a dry-run manifest.
  Future<void> prepareManifest() async {
    _busy = true;
    _error = null;
    _report = null;
    notifyListeners();

    try {
      final json = await compute(_manifestOnBackground, _PlanRequest(
        categories: _selected.toList(),
        includeRecent: _includeRecent,
        libraryPath: null,
      ));
      _manifest = DryRunManifest.fromJson(json);
    } catch (e) {
      _error = 'Could not build the dry-run manifest: $e';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Runs the dry run. Nothing is modified; the point is to show the user
  /// exactly what the engine would do.
  Future<void> simulate() async {
    final manifest = _manifest;
    if (manifest == null) return;

    _busy = true;
    _error = null;
    notifyListeners();

    try {
      final report = await compute(
        _executeOnBackground,
        _ExecuteRequest(
          manifest: manifest.raw,
          simulate: true,
        ),
      );
      _report = ExecutionReport.fromJson(report);
    } catch (e) {
      _error = 'Simulation failed: $e';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Executes for real. Refuses unless a simulation of this manifest was shown.
  Future<void> execute() async {
    final manifest = _manifest;
    if (manifest == null) return;
    if (!hasSimulated) {
      _error = 'Run the dry run first — the engine requires a reviewed result.';
      notifyListeners();
      return;
    }

    _busy = true;
    _error = null;
    notifyListeners();

    try {
      final report = await compute(
        _executeOnBackground,
        _ExecuteRequest(
          manifest: manifest.raw,
          simulate: false,
        ),
      );
      _report = ExecutionReport.fromJson(report);
      // The manifest has been consumed; keeping it would invite a second run of
      // the same frozen set, which is no longer what is on disk.
      _manifest = null;
    } catch (e) {
      _error = 'Execution refused: $e';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}

/// Arguments for the background plan call.
///
/// [libraryPath] is unused for the in-process engine but keeps the payload
/// shape stable for a future out-of-process engine.
class _PlanRequest {
  const _PlanRequest({
    required this.categories,
    required this.includeRecent,
    required this.libraryPath,
  });

  final List<CleanupCategory> categories;
  final bool includeRecent;
  final String? libraryPath;
}

class _ExecuteRequest {
  const _ExecuteRequest({required this.manifest, required this.simulate});

  final Map<String, dynamic> manifest;
  final bool simulate;
}

/// Top-level entry points used by [compute]. Each reopens the library, because
/// a `DynamicLibrary` handle does not survive the hop to another isolate.
Map<String, dynamic> _planOnBackground(_PlanRequest request) {
  final engine = CoreEngine.open();
  return engine.plan(
    categories: request.categories,
    includeRecent: request.includeRecent,
  );
}

Map<String, dynamic> _manifestOnBackground(_PlanRequest request) {
  final engine = CoreEngine.open();
  return engine.buildManifest(
    categories: request.categories,
    includeRecent: request.includeRecent,
  );
}

Map<String, dynamic> _executeOnBackground(_ExecuteRequest request) {
  final engine = CoreEngine.open();
  return engine.executeManifest(request.manifest, simulate: request.simulate);
}

class KernSifterApp extends StatelessWidget {
  const KernSifterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KernSifter',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D32)),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E7D32),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  KernSifterController? _controller;

  /// Null unless a sync origin was supplied at build time.
  DeviceAuthClient? _sync;

  /// Non-null while the device is waiting for the human to approve it in a
  /// browser. Rendered inline rather than in a dialog, so cancelling cannot
  /// race with the poll loop over the navigation stack.
  DeviceAuthorization? _syncAuthorization;

  String _syncStatus = 'Sync: not connected';
  bool _syncBusy = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _sync = _syncOrigin.isEmpty
        ? null
        : DeviceAuthClient(
            origin: Uri.parse(_syncOrigin),
            store: SecureTokenStore(),
            clientName: 'KernSifter mobile',
          );
    // Opening the library can fail (missing .so, ABI mismatch). That is a build
    // problem, so it is reported as a full-screen error rather than a snackbar
    // on a UI that could never work.
    try {
      _controller = KernSifterController(CoreEngine.open());
    } catch (e) {
      _loadError = '$e';
    }
  }

  @override
  void dispose() {
    _sync?.close();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loadError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('KernSifter')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48),
                const SizedBox(height: 16),
                const Text(
                  'The core engine could not be loaded.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  _loadError!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      );
    }

    final controller = _controller!;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('KernSifter'),
            actions: [
              IconButton(
                tooltip: _sync == null ? 'Sync is not configured' : _syncStatus,
                icon: Icon(
                  _sync == null
                      ? Icons.cloud_off_outlined
                      : (_syncAuthorization != null
                          ? Icons.cloud_sync_outlined
                          : Icons.cloud_queue_outlined),
                ),
                onPressed: _syncBusy ? null : _toggleSync,
              ),
              IconButton(
                tooltip: 'About the engine',
                icon: const Icon(Icons.info_outline),
                onPressed: () => _showEngineInfo(context, controller),
              ),
            ],
          ),
          body: Column(
            children: [
              if (_syncAuthorization != null) _syncBanner(_syncAuthorization!),
              Expanded(
                child: controller.error != null
                    ? _ErrorBanner(
                        message: controller.error!,
                        onDismiss: controller.clearError,
                      )
                    : _body(context, controller),
              ),
            ],
          ),
          bottomNavigationBar: controller.busy
              ? const LinearProgressIndicator()
              : null,
        );
      },
    );
  }

  /// The approval step, inline: the user reads the code, opens a browser, and
  /// this disappears either when the poll succeeds or when they cancel.
  Widget _syncBanner(DeviceAuthorization authorization) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Approve this device', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Enter this code in your browser to finish connecting:',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            SelectableText(
              authorization.userCode,
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 4),
            SelectableText(
              authorization.verificationUriComplete.toString(),
              style: theme.textTheme.bodySmall,
            ),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: authorization.verificationUriComplete.toString()),
                    );
                    _snack('Link copied. Paste it into your browser.');
                  },
                  icon: const Icon(Icons.copy_all_outlined),
                  label: const Text('Copy link'),
                ),
                TextButton(
                  onPressed: () => setState(() => _syncAuthorization = null),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Connect when there is no token, disconnect when there is.
  Future<void> _toggleSync() async {
    final sync = _sync;
    if (sync == null) {
      _snack('Sync is not configured. Build with '
          '--dart-define=KERNSIFTER_SYNC_ORIGIN=<worker origin>.');
      return;
    }
    if (_syncBusy) return;
    if (await sync.currentToken() != null) {
      await _disconnectFromSync(sync);
    } else {
      await _connectToSync(sync);
    }
  }

  Future<void> _connectToSync(DeviceAuthClient sync) async {
    setState(() => _syncBusy = true);
    try {
      final authorization = await sync.start();
      if (!mounted) return;
      setState(() => _syncAuthorization = authorization);
      // isCancelled is consulted between polls, so Cancel stops the loop and
      // the token is never minted.
      final token = await sync.poll(
        authorization,
        isCancelled: () => _syncAuthorization == null,
      );
      await sync.store.write(token);
      if (!mounted) return;
      setState(() {
        _syncAuthorization = null;
        _syncStatus = 'Sync connected';
      });
      _snack('Connected. This device can now sync your KernSifter data.');
    } on DeviceAuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _syncAuthorization = null;
        _syncStatus = 'Sync failed: ${error.reason.name}';
      });
      _snack(error.message);
    } finally {
      if (mounted) setState(() => _syncBusy = false);
    }
  }

  Future<void> _disconnectFromSync(DeviceAuthClient sync) async {
    setState(() => _syncBusy = true);
    try {
      // Revokes at the server as well as clearing the keystore: deleting the
      // local copy alone would leave a live credential.
      await sync.disconnect();
      if (!mounted) return;
      setState(() => _syncStatus = 'Sync: not connected');
      _snack("Disconnected. This device's token was revoked at the server.");
    } on DeviceAuthException catch (error) {
      _snack(error.message);
    } finally {
      if (mounted) setState(() => _syncBusy = false);
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _body(BuildContext context, KernSifterController controller) {
    final plan = controller.plan;
    if (plan == null) return _ScanView(controller: controller);

    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(tabs: [
            Tab(text: 'Cleanup'),
            Tab(text: 'Declined'),
          ]),
          Expanded(
            child: TabBarView(
              children: [
                _CleanupView(controller: controller, plan: plan),
                _DeclinedView(controller: controller, plan: plan),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showEngineInfo(
      BuildContext context, KernSifterController controller) {
    showAboutDialog(
      context: context,
      applicationName: 'KernSifter',
      applicationVersion: controller.engine.version,
      applicationLegalese:
          'All cleanup decisions are made by the core-engine Rust safety core.\n'
          'ABI ${controller.engine.abiVersion} on ${controller.engine.platformName}.',
    );
  }
}

class _ScanView extends StatelessWidget {
  const _ScanView({required this.controller});

  final KernSifterController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Space scan', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          'KernSifter asks the engine which candidates are safe to clean, and '
          'why it declined the rest. Nothing is removed until you review a '
          'dry run and confirm it.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 24),
        Text('Categories', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Leave everything unticked for a smart clean of routine categories.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final category in CleanupCategory.values)
              FilterChip(
                label: Text(category.label),
                selected: controller.selected.contains(category),
                onSelected: (_) => controller.toggleCategory(category),
              ),
          ],
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Include recent files'),
          subtitle: const Text(
            'Ignores the per-category age floors. Categories that are '
            'manual-only or protected stay excluded either way.',
          ),
          value: controller.includeRecent,
          onChanged: controller.setIncludeRecent,
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: controller.busy ? null : controller.scan,
          icon: const Icon(Icons.search),
          label: const Text('Scan'),
        ),
      ],
    );
  }
}

class _CleanupView extends StatelessWidget {
  const _CleanupView({required this.controller, required this.plan});

  final KernSifterController controller;
  final CleanupPlan plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (plan.eligibleCount == 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Nothing is eligible right now.\n\n'
            'The engine declined every candidate — the Declined tab says why.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      );
    }

    final largest = plan.largestEligible.take(50).toList(growable: false);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Reclaimable', style: theme.textTheme.labelLarge),
                Text(
                  formatBytes(plan.eligibleBytes),
                  style: theme.textTheme.headlineMedium,
                ),
                Text(
                  '${plan.eligibleCount} candidate'
                  '${plan.eligibleCount == 1 ? '' : 's'}',
                  style: theme.textTheme.bodySmall,
                ),
                if (plan.needsElevation) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.shield_outlined, size: 16),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Some paths need a privileged process to clean.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('Largest first', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final entry in largest)
          ListTile(
            dense: true,
            title: Text(entry.name, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              entry.parent,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            trailing: Text(formatBytes(entry.sizeBytes)),
          ),
        if (plan.eligibleCount > largest.length)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '… and ${plan.eligibleCount - largest.length} more',
              style: theme.textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 24),
        _ManifestFlow(controller: controller, plan: plan),
      ],
    );
  }
}

/// The dry-run gate: manifest → simulate → confirm → execute.
///
/// Each step is a separate, explicit action. The execute button is only enabled
/// after a simulation of the same manifest has been shown, which is the UI half
/// of the engine's own "nothing runs unverified" rule.
class _ManifestFlow extends StatelessWidget {
  const _ManifestFlow({required this.controller, required this.plan});

  final KernSifterController controller;
  final CleanupPlan plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final manifest = controller.manifest;
    final report = controller.report;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Before anything moves', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'KernSifter writes a dry-run manifest first. Review it, simulate '
              'it, then confirm. Files go to the OS trash, so they stay '
              'recoverable.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            if (manifest == null)
              OutlinedButton.icon(
                onPressed:
                    controller.busy ? null : controller.prepareManifest,
                icon: const Icon(Icons.description_outlined),
                label: const Text('Build dry-run manifest'),
              )
            else ...[
              _SummaryRow(
                'Manifest',
                '#${manifest.id} · ${manifest.entryCount} entries',
              ),
              _SummaryRow(
                'Would reclaim',
                formatBytes(manifest.cleanableBytes),
              ),
              if (manifest.blockedCount > 0)
                _SummaryRow(
                  'Blocked at scan',
                  '${manifest.blockedCount}',
                ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: controller.busy || controller.hasSimulated
                    ? null
                    : controller.simulate,
                icon: const Icon(Icons.play_arrow),
                label: Text(
                  controller.hasSimulated
                      ? 'Dry run complete'
                      : 'Run dry run',
                ),
              ),
              if (report != null && report.simulated) ...[
                const SizedBox(height: 12),
                Card(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Dry run — nothing was changed',
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        _SummaryRow(
                          'Would move',
                          formatBytes(report.simulatedBytes),
                        ),
                        _SummaryRow(
                          'Would skip',
                          '${report.problems.length}',
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.error,
                    foregroundColor: theme.colorScheme.onError,
                  ),
                  onPressed: controller.busy ? null : () => _confirm(context),
                  icon: const Icon(Icons.delete_outline),
                  label: Text(
                    'Move ${formatBytes(report.simulatedBytes)} to trash',
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _confirm(BuildContext context) async {
    final report = controller.report;
    if (report == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Move these files?'),
        content: Text(
          '${formatBytes(report.simulatedBytes)} across '
          '${plan.eligibleCount} candidates will be moved to the OS trash.\n\n'
          'This is recoverable from the trash, but KernSifter will not be able '
          'to undo it for you.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Move to trash'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await controller.execute();
    }
  }
}

class _DeclinedView extends StatelessWidget {
  const _DeclinedView({required this.controller, required this.plan});

  final KernSifterController controller;
  final CleanupPlan plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (plan.skippedCount == 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Nothing was declined — every candidate found was eligible.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      );
    }

    final maxBytes = plan.skipSummaries.isEmpty
        ? 1
        : plan.skipSummaries
            .map((s) => s.bytes)
            .reduce((a, b) => a > b ? a : b);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Why this is still here', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          'The engine declined ${plan.skippedCount} candidate'
          '${plan.skippedCount == 1 ? '' : 's'}. Nothing is hidden: every one '
          'carries a reason.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        for (final summary in plan.skipSummaries) ...[
          Text(summary.message, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: maxBytes == 0 ? 0 : summary.bytes / maxBytes,
                    minHeight: 8,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(formatBytes(summary.bytes)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            summary.permanent
                ? 'Always declined'
                : 'Age-dependent — may change on a later scan',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
        ],
      ],
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: theme.textTheme.bodyMedium),
          Text(value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning_amber_rounded,
                size: 40, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: onDismiss,
              child: const Text('Dismiss'),
            ),
          ],
        ),
      ),
    );
  }
}
