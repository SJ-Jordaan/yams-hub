/// `/indexers` (APP.md §10.1): Prowlarr indexers with health, 30-day stats,
/// enable switches, multi-select bulk actions and tests.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/api/api_exception.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/indexers_api.dart';
import '../providers/indexers_providers.dart';
import '../widgets/indexer_widgets.dart';

class IndexersScreen extends ConsumerStatefulWidget {
  const IndexersScreen({super.key});

  @override
  ConsumerState<IndexersScreen> createState() => _IndexersScreenState();
}

class _IndexersScreenState extends ConsumerState<IndexersScreen> {
  /// Long-press multi-select (admins).
  final Set<int> _selected = {};

  /// Indexers whose switch is waiting for the gateway.
  final Set<int> _busy = {};

  /// The running "Test all" job.
  String? _testAllJob;

  /// Running "Test selected" jobs (job id → indexer id) and the results of
  /// the batch collected so far.
  final Map<String, int> _testJobs = {};
  final List<IndexerTestResult> _batchResults = [];

  /// Still starting the jobs of a "Test selected" batch.
  bool _launching = false;

  bool get _selecting => _selected.isNotEmpty;

  Map<int, String> get _names => {
    for (final i
        in ref.read(indexerListProvider).value?.items ?? const <Indexer>[])
      i.id: i.name,
  };

  void _toggleSelection(int id) => setState(() {
    if (!_selected.remove(id)) _selected.add(id);
  });

  Future<void> _setEnabled(Set<int> ids, bool enabled) async {
    setState(() => _busy.addAll(ids));
    try {
      await ref.read(indexerListProvider.notifier).setEnabled(ids, enabled);
      if (mounted && ids.length > 1) {
        context.showSnack(
          '${enabled ? 'Enabled' : 'Disabled'} ${ids.length} indexers',
        );
      }
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _busy.removeAll(ids));
    }
  }

  Future<void> _setPriority(Set<int> ids) async {
    final items =
        ref.read(indexerListProvider).value?.items ?? const <Indexer>[];
    final current = items
        .where((i) => ids.contains(i.id))
        .map((i) => i.priority)
        .toSet();
    final priority = await showPriorityDialog(
      context,
      initial: current.length == 1 ? current.single : null,
      count: ids.length,
    );
    if (priority == null || !mounted) return;
    try {
      await ref.read(indexerListProvider.notifier).setPriority(ids, priority);
      if (mounted) context.showSnack('Priority set to $priority');
    } catch (e) {
      if (mounted) context.showError(e);
    }
  }

  Future<void> _testAll() async {
    try {
      final job = await ref.read(indexersApiProvider).testAll();
      if (mounted) setState(() => _testAllJob = job.id);
    } catch (e) {
      if (mounted) context.showError(e);
    }
  }

  void _onTestAllDone(Job job) {
    setState(() => _testAllJob = null);
    ref.invalidate(indexerListProvider);
    if (job.status == JobStatus.failed) {
      context.showSnack(
        'Test all failed: ${job.error?.message ?? 'unknown error'}',
      );
      return;
    }
    showTestResultsSheet(
      context,
      results: IndexerTestResult.listFromJobResult(job.result),
      names: _names,
      title: 'Test all',
    );
  }

  Future<void> _testSelected(Set<int> ids) async {
    setState(() {
      _selected.clear();
      _batchResults.clear();
      _launching = true;
    });
    final api = ref.read(indexersApiProvider);
    for (final id in ids) {
      try {
        final job = await api.test(id);
        if (!mounted) return;
        setState(() => _testJobs[job.id] = id);
      } catch (e) {
        if (!mounted) return;
        _batchResults.add(
          IndexerTestResult(
            id: id,
            valid: false,
            failures: [ApiException.from(e).message],
          ),
        );
      }
    }
    setState(() => _launching = false);
    if (_testJobs.isEmpty) _finishBatch();
  }

  void _onTestDone(Job job) {
    final id = _testJobs.remove(job.id);
    if (id == null) return;
    _batchResults.add(
      _parseResult(job) ??
          IndexerTestResult(
            id: id,
            valid: false,
            failures: [job.error?.message ?? 'Test failed'],
          ),
    );
    setState(() {});
    if (_testJobs.isEmpty && !_launching) _finishBatch();
  }

  static IndexerTestResult? _parseResult(Job job) {
    final result = job.result;
    if (job.status != JobStatus.succeeded || result == null) return null;
    try {
      return IndexerTestResult.fromJson(result);
    } on FormatException {
      return null;
    }
  }

  void _finishBatch() {
    ref.invalidate(indexerListProvider);
    final results = List.of(_batchResults);
    _batchResults.clear();
    if (results.isEmpty) return;
    final names = _names;
    if (results.length == 1) {
      final r = results.single;
      final name = names[r.id] ?? 'Indexer #${r.id}';
      context.showSnack(
        r.valid ? '$name passed' : '$name failed: ${r.failures.join('; ')}',
      );
      return;
    }
    showTestResultsSheet(
      context,
      results: results,
      names: names,
      title: 'Test selected',
    );
  }

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(indexerListProvider);
    final isAdmin = ref.watch(isAdminProvider);
    final testing = _testAllJob != null || _testJobs.isNotEmpty;
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(_selected.clear);
      },
      child: Scaffold(
        appBar: _selecting ? _selectionBar() : _normalBar(isAdmin, testing),
        body: RefreshIndicator(
          onRefresh: () => ref.refresh(indexerListProvider.future),
          child: AsyncValueView<IndexerList>(
            value: value,
            onRetry: () => ref.invalidate(indexerListProvider),
            data: (context, list) => _list(context, list, isAdmin),
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _normalBar(bool isAdmin, bool testing) => AppBar(
    title: const Text('Indexers'),
    actions: [
      if (isAdmin)
        IconButton(
          tooltip: 'Test all',
          icon: const Icon(Icons.fact_check_outlined),
          onPressed: testing ? null : _testAll,
        ),
      if (isAdmin)
        IconButton(
          tooltip: 'Search',
          icon: const Icon(Icons.search),
          onPressed: () => context.go(AppPaths.indexersSearch()),
        ),
      IconButton(
        tooltip: 'History',
        icon: const Icon(Icons.history),
        onPressed: () => context.go(AppPaths.indexersHistory()),
      ),
    ],
  );

  PreferredSizeWidget _selectionBar() {
    final ids = Set.of(_selected);
    return AppBar(
      leading: IconButton(
        tooltip: 'Clear selection',
        icon: const Icon(Icons.close),
        onPressed: () => setState(_selected.clear),
      ),
      title: Text('${ids.length} selected'),
      actions: [
        IconButton(
          tooltip: 'Enable',
          icon: const Icon(Icons.toggle_on_outlined),
          onPressed: () {
            setState(_selected.clear);
            _setEnabled(ids, true);
          },
        ),
        IconButton(
          tooltip: 'Disable',
          icon: const Icon(Icons.toggle_off_outlined),
          onPressed: () {
            setState(_selected.clear);
            _setEnabled(ids, false);
          },
        ),
        IconButton(
          tooltip: 'Set priority',
          icon: const Icon(Icons.low_priority),
          onPressed: () {
            setState(_selected.clear);
            _setPriority(ids);
          },
        ),
        IconButton(
          tooltip: 'Test selected',
          icon: const Icon(Icons.network_check),
          onPressed: _testJobs.isEmpty && !_launching
              ? () => _testSelected(ids)
              : null,
        ),
      ],
    );
  }

  Widget _list(BuildContext context, IndexerList list, bool isAdmin) {
    final header = <Widget>[
      IndexerHealthBanner(health: list.health),
      if (_testAllJob != null || _testJobs.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (_testAllJob case final id?)
                JobChip(
                  id,
                  key: ValueKey(id),
                  showSnackBar: false,
                  onDone: _onTestAllDone,
                ),
              for (final id in _testJobs.keys)
                JobChip(
                  id,
                  key: ValueKey(id),
                  showSnackBar: false,
                  onDone: _onTestDone,
                ),
            ],
          ),
        ),
    ];
    if (list.items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          ...header,
          const EmptyView(
            icon: Icons.travel_explore,
            title: 'No indexers configured in Prowlarr',
            message: 'Add indexers in the Prowlarr web UI; they appear here automatically.',
          ),
        ],
      );
    }
    final enabled = list.items.where((i) => i.enabled).length;
    final failing = list.items.where((i) => i.isFailing).length;
    final theme = Theme.of(context);
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: list.items.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ...header,
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  '$enabled of ${list.items.length} enabled'
                  '${failing == 0 ? '' : ' · $failing failing'} · stats for the last 30 days',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          );
        }
        final indexer = list.items[index - 1];
        return _IndexerTile(
          indexer: indexer,
          admin: isAdmin,
          selecting: _selecting,
          selected: _selected.contains(indexer.id),
          busy: _busy.contains(indexer.id),
          onTap: () => _selecting
              ? _toggleSelection(indexer.id)
              : context.go(AppPaths.indexer(indexer.id)),
          onLongPress: isAdmin ? () => _toggleSelection(indexer.id) : null,
          onEnabled: (v) => _setEnabled({indexer.id}, v),
        );
      },
    );
  }
}

class _IndexerTile extends StatelessWidget {
  const _IndexerTile({
    required this.indexer,
    required this.admin,
    required this.selecting,
    required this.selected,
    required this.busy,
    required this.onTap,
    required this.onLongPress,
    required this.onEnabled,
  });

  final Indexer indexer;
  final bool admin;
  final bool selecting;
  final bool selected;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final ValueChanged<bool> onEnabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return ListTile(
      selected: selected,
      onTap: onTap,
      onLongPress: onLongPress,
      leading: selecting
          ? Checkbox(value: selected, onChanged: (_) => onTap())
          : null,
      title: Row(
        children: [
          Flexible(child: Text(indexer.name, overflow: TextOverflow.ellipsis)),
          if (indexer.usesFlareSolverr) ...[
            const SizedBox(width: 6),
            const FlareSolverrIcon(),
          ],
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                IndexerStatusChip(indexer: indexer),
                IndexerLabel(protocolLabel(indexer.protocol)),
                IndexerLabel(privacyLabel(indexer.privacy)),
                IndexerLabel(
                  'Priority ${indexer.priority}',
                  icon: Icons.low_priority,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(statsLine(indexer.stats), style: muted),
          ],
        ),
      ),
      isThreeLine: true,
      trailing: admin && !selecting
          ? Semantics(
              label:
                  '${indexer.enabled ? 'Disable' : 'Enable'} ${indexer.name}',
              child: Switch(
                value: indexer.enabled,
                onChanged: busy ? null : onEnabled,
              ),
            )
          : null,
    );
  }
}
