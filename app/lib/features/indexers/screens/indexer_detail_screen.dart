/// `/indexers/:id` (APP.md §10.2): fields, stats, failure timeline,
/// categories, and the admin enable switch, priority and test.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/links/external_links.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/indexers_api.dart';
import '../providers/indexers_providers.dart';
import '../widgets/indexer_widgets.dart';

class IndexerDetailScreen extends ConsumerStatefulWidget {
  const IndexerDetailScreen({super.key, required this.id});

  final int id;

  @override
  ConsumerState<IndexerDetailScreen> createState() =>
      _IndexerDetailScreenState();
}

class _IndexerDetailScreenState extends ConsumerState<IndexerDetailScreen> {
  String? _testJob;
  bool _startingTest = false;

  /// The value shown by the switch while the change is in flight.
  bool? _pendingEnabled;
  bool _savingPriority = false;

  Future<void> _refresh() async {
    ref.invalidate(indexerListProvider);
    ref.invalidate(indexerDetailProvider(widget.id));
    await ref.read(indexerDetailProvider(widget.id).future);
  }

  Future<void> _update(IndexerBulkUpdate update) async {
    await ref.read(indexersApiProvider).bulkUpdate(update);
    ref.invalidate(indexerListProvider);
    ref.invalidate(indexerDetailProvider(widget.id));
    await ref.read(indexerDetailProvider(widget.id).future);
  }

  Future<void> _setEnabled(bool enabled) async {
    setState(() => _pendingEnabled = enabled);
    try {
      await _update(IndexerBulkUpdate(ids: [widget.id], enabled: enabled));
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _pendingEnabled = null);
    }
  }

  Future<void> _setPriority(Indexer indexer) async {
    final priority = await showPriorityDialog(
      context,
      initial: indexer.priority,
    );
    if (priority == null || priority == indexer.priority || !mounted) return;
    setState(() => _savingPriority = true);
    try {
      await _update(IndexerBulkUpdate(ids: [widget.id], priority: priority));
      if (mounted) context.showSnack('Priority set to $priority');
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _savingPriority = false);
    }
  }

  Future<void> _test() async {
    setState(() => _startingTest = true);
    try {
      final job = await ref.read(indexersApiProvider).test(widget.id);
      if (mounted) setState(() => _testJob = job.id);
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _startingTest = false);
    }
  }

  void _onTestDone(Job job, String name) {
    setState(() => _testJob = null);
    ref.invalidate(indexerDetailProvider(widget.id));
    ref.invalidate(indexerListProvider);
    IndexerTestResult? result;
    if (job.status == JobStatus.succeeded && job.result != null) {
      try {
        result = IndexerTestResult.fromJson(job.result!);
      } on FormatException {
        result = null;
      }
    }
    if (result == null) {
      context.showSnack(
        'Test failed: ${job.error?.message ?? 'unknown error'}',
      );
      return;
    }
    if (result.valid) {
      context.showSnack('$name passed the test');
    } else {
      showTestResultsSheet(
        context,
        results: [result],
        names: {widget.id: name},
        title: 'Test $name',
      );
    }
  }

  /// The test job could not be followed (expired, hub unreachable): bring
  /// the Test button back.
  void _onTestLost() {
    setState(() => _testJob = null);
    ref.invalidate(indexerDetailProvider(widget.id));
    context.showSnack('Lost track of the test. Refresh to check the result.');
  }

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(indexerDetailProvider(widget.id));
    final isAdmin = ref.watch(isAdminProvider);
    return Scaffold(
      appBar: AppBar(title: Text(value.value?.name ?? 'Indexer')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: AsyncValueView<Indexer>(
          value: value,
          onRetry: () => ref.invalidate(indexerDetailProvider(widget.id)),
          data: (context, indexer) => _body(context, indexer, isAdmin),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, Indexer indexer, bool isAdmin) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final stats = indexer.stats;
    final hasFailures =
        indexer.failingSince != null ||
        indexer.lastFailure != null ||
        indexer.disabledTill != null;
    final baseUrl = indexer.baseUrl;
    final baseUri = baseUrl == null ? null : Uri.tryParse(baseUrl);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IndexerStatusChip(indexer: indexer, dense: false),
              IndexerLabel(protocolLabel(indexer.protocol)),
              IndexerLabel(privacyLabel(indexer.privacy)),
              if (indexer.usesFlareSolverr)
                const IndexerLabel('FlareSolverr', icon: Icons.shield_outlined),
            ],
          ),
        ),
        if (indexer.description case final d?)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
            child: Text(
              d,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (isAdmin)
          SectionCard(
            title: 'Settings',
            icon: Icons.tune,
            padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Enabled'),
                  subtitle: const Text(
                    'Sonarr and Radarr search enabled indexers',
                  ),
                  value: _pendingEnabled ?? indexer.enabled,
                  onChanged: _pendingEnabled == null ? _setEnabled : null,
                ),
                ListTile(
                  title: const Text('Priority'),
                  subtitle: const Text('1–50, lower is preferred'),
                  trailing: _savingPriority
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          '${indexer.priority}',
                          style: theme.textTheme.titleMedium,
                        ),
                  onTap: _savingPriority ? null : () => _setPriority(indexer),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Row(
                    children: [
                      if (_testJob case final job?)
                        Flexible(
                          child: JobChip(
                            job,
                            key: ValueKey(job),
                            showSnackBar: false,
                            onDone: (j) => _onTestDone(j, indexer.name),
                            onLost: (_) => _onTestLost(),
                          ),
                        )
                      else
                        FilledButton.tonalIcon(
                          onPressed: _startingTest ? null : _test,
                          icon: _startingTest
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.network_check),
                          label: const Text('Test'),
                        ),
                    ],
                  ),
                ),
                if (_testJob != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      indexer.usesFlareSolverr
                          ? 'FlareSolverr can take up to 2 minutes.'
                          : 'Testing… this can take up to 2 minutes.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        if (hasFailures)
          SectionCard(
            title: 'Failures',
            icon: Icons.error_outline,
            child: KeyValueList(
              entries: [
                if (indexer.failingSince case final t?)
                  KeyValue('Failing since', formatDateTime(t)),
                if (indexer.lastFailure case final t?)
                  KeyValue('Last failure', formatDateTime(t)),
                if (indexer.disabledTill case final t?)
                  KeyValue.widget(
                    indexer.isFailing ? 'Next retry' : 'Back-off ended',
                    Text(
                      '${formatDateTime(t)} (${formatRelative(t)})',
                      style: indexer.isFailing
                          ? TextStyle(color: colors.error)
                          : null,
                    ),
                  ),
              ],
            ),
          ),
        SectionCard(
          title: 'Last 30 days',
          icon: Icons.query_stats,
          child: stats == null
              ? Text(
                  'No activity in the last 30 days',
                  style: theme.textTheme.bodyMedium,
                )
              : KeyValueList(
                  entries: [
                    KeyValue('Searches', formatCount(stats.queries)),
                    KeyValue('RSS queries', formatCount(stats.rssQueries)),
                    KeyValue('Grabs', formatCount(stats.grabs)),
                    KeyValue(
                      'Failed',
                      '${formatCount(stats.failedQueries)} searches · ${formatCount(stats.failedRssQueries)} RSS · '
                          '${formatCount(stats.failedGrabs)} grabs',
                    ),
                    if (stats.authQueries > 0)
                      KeyValue('Auth queries', formatCount(stats.authQueries)),
                    KeyValue(
                      'Avg response',
                      '${formatCount(stats.avgResponseMs)} ms',
                    ),
                  ],
                ),
        ),
        SectionCard(
          title: 'Details',
          icon: Icons.info_outline,
          child: KeyValueList(
            entries: [
              if (baseUrl != null)
                KeyValue.widget(
                  'Base URL',
                  InkWell(
                    onTap: baseUri == null
                        ? null
                        : () async {
                            final ok = await launchExternalUri(baseUri);
                            if (!ok && context.mounted) {
                              context.showSnack("Couldn't open $baseUrl");
                            }
                          },
                    child: Text(
                      baseUrl,
                      style: TextStyle(
                        color: theme.colorScheme.primary,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ),
              KeyValue('Priority', '${indexer.priority}'),
              KeyValue('Implementation', indexer.implementation),
              KeyValue('Language', indexer.language),
              KeyValue(
                'RSS',
                indexer.supportsRss ? 'Supported' : 'Not supported',
              ),
              KeyValue(
                'Search',
                indexer.supportsSearch ? 'Supported' : 'Not supported',
              ),
              if (indexer.tags.isNotEmpty)
                KeyValue('Tags', indexer.tags.map((t) => t.label).join(', ')),
              if (indexer.added case final t?) KeyValue('Added', formatDate(t)),
            ],
          ),
        ),
        if (indexer.categories case final cats? when cats.isNotEmpty)
          SectionCard(
            title: 'Categories',
            icon: Icons.category_outlined,
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [for (final c in cats) IndexerLabel(c)],
            ),
          ),
      ],
    );
  }
}
