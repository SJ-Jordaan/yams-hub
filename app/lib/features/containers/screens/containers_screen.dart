/// `/containers`: the grouped container list (APP.md §9.1).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/api/api_exception.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../providers/containers_providers.dart';
import '../widgets/container_row.dart';
import '../widgets/container_visuals.dart';

/// List filter chips.
enum ContainerFilter {
  all('All'),
  running('Running'),
  stopped('Stopped'),
  unhealthy('Unhealthy'),
  updates('Updates');

  const ContainerFilter(this.label);

  final String label;

  bool matches(ContainerSummary c) => switch (this) {
    all => true,
    running => c.isRunning,
    stopped => !c.isRunning,
    unhealthy => c.health == ContainerHealth.unhealthy,
    updates => c.updateAvailable,
  };
}

/// Filters [items] by [filter] and the search text [q].
List<ContainerSummary> filterContainers(List<ContainerSummary> items, ContainerFilter filter, String q) {
  final needle = q.trim().toLowerCase();
  return [
    for (final c in items)
      if (filter.matches(c) &&
          (needle.isEmpty ||
              c.name.toLowerCase().contains(needle) ||
              c.service.toLowerCase().contains(needle) ||
              c.image.toLowerCase().contains(needle)))
        c,
  ];
}

class ContainersScreen extends ConsumerStatefulWidget {
  const ContainersScreen({super.key});

  @override
  ConsumerState<ContainersScreen> createState() => _ContainersScreenState();
}

class _ContainersScreenState extends ConsumerState<ContainersScreen> {
  ContainerFilter _filter = ContainerFilter.all;
  String _query = '';
  final Set<String> _collapsed = {};

  Future<void> _refresh() async {
    ref.invalidate(containerListProvider);
    ref.invalidate(updatesProvider);
    try {
      await ref.read(containerListProvider.future);
    } catch (_) {
      // The error state (or stale banner) shows it.
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(containerListProvider);
    // canUpdate comes from GET /updates (manual; loaded once per visit).
    final updates = ref.watch(updatesProvider).value;
    final canUpdate = {
      for (final u in updates?.items ?? const <UpdateInfo>[])
        if (u.canUpdate && (updates?.updaterAvailable ?? false)) u.name,
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Containers')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: !value.hasValue && value.hasError
            ? ErrorView(error: containersError(value.error!), onRetry: () => ref.invalidate(containerListProvider))
            : AsyncValueView(
                value: value,
                onRetry: () => ref.invalidate(containerListProvider),
                data: (context, list) => _body(context, list, canUpdate),
                loading: const SkeletonList(count: 10, leadingSize: 12),
              ),
      ),
    );
  }

  Widget _body(BuildContext context, ContainerList list, Set<String> canUpdate) {
    final visible = filterContainers(list.items, _filter, _query);
    final groups = <String, List<ContainerSummary>>{};
    for (final c in visible) {
      final g = containerGroupOrder.contains(c.group) ? c.group : 'other';
      (groups[g] ??= []).add(c);
    }
    final children = <Widget>[
      _SummaryHeader(list: list),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: SearchField(
          hint: 'Search containers',
          initialValue: _query,
          onChanged: (q) => setState(() => _query = q),
        ),
      ),
      FilterChipsBar<ContainerFilter>(
        options: ContainerFilter.values,
        selected: {_filter},
        labelOf: (f) => f.label,
        onSelected: (f) => setState(() => _filter = f ?? ContainerFilter.all),
      ),
      const SizedBox(height: 4),
      if (visible.isEmpty)
        const Padding(
          padding: EdgeInsets.all(32),
          child: EmptyView(
            icon: Icons.filter_alt_off_outlined,
            title: 'No containers match',
            message: 'Try another filter.',
          ),
        ),
      for (final g in containerGroupOrder)
        if (groups[g] case final items?) ...[
          _GroupHeader(
            label: containerGroupLabel(g),
            count: items.length,
            running: items.where((c) => c.isRunning).length,
            collapsed: _collapsed.contains(g),
            onTap: () => setState(() => _collapsed.contains(g) ? _collapsed.remove(g) : _collapsed.add(g)),
          ),
          if (!_collapsed.contains(g))
            for (final c in items) ContainerRow(container: c, canUpdate: canUpdate.contains(c.name)),
        ],
      const SizedBox(height: 24),
    ];
    return ListView(physics: const AlwaysScrollableScrollPhysics(), children: children);
  }
}

class _SummaryHeader extends StatelessWidget {
  const _SummaryHeader({required this.list});

  final ContainerList list;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = list.items.where((c) => c.isRunning).length;
    final updates = list.items.where((c) => c.updateAvailable).length;
    final engine = list.engine.version.isEmpty ? null : 'Docker ${list.engine.version}';
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '$running', style: theme.textTheme.headlineSmall),
                  TextSpan(text: ' / ${list.items.length} running', style: theme.textTheme.titleMedium),
                ],
              ),
            ),
            if (engine != null) ...[
              const SizedBox(height: 2),
              Text(
                [engine, if (list.engine.images > 0) '${list.engine.images} images'].join(' · '),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () => context.go(AppPaths.containersUpdates()),
                  icon: const Icon(Icons.system_update_alt),
                  label: Text(updates > 0 ? 'Updates ($updates)' : 'Updates'),
                ),
                OutlinedButton.icon(
                  onPressed: () => context.go(AppPaths.containersMaintenance()),
                  icon: const Icon(Icons.cleaning_services_outlined),
                  label: const Text('Maintenance'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.label,
    required this.count,
    required this.running,
    required this.collapsed,
    required this.onTap,
  });

  final String label;
  final int count;
  final int running;
  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 4),
        child: Row(
          children: [
            Text(label, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
            const SizedBox(width: 8),
            Text(
              running == count ? '$count' : '$running/$count running',
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const Spacer(),
            Icon(
              collapsed ? Icons.expand_more : Icons.expand_less,
              size: 20,
              semanticLabel: collapsed ? 'Expand' : 'Collapse',
            ),
          ],
        ),
      ),
    );
  }
}

/// Docker proxy failures read better as "Docker proxy unreachable".
Object containersError(Object error) {
  final e = ApiException.from(error);
  if (e.code == ApiErrorCode.upstreamUnavailable || e.code == ApiErrorCode.upstreamTimeout) {
    return ApiException(status: e.status, code: e.code, message: 'Docker proxy unreachable', requestId: e.requestId);
  }
  return e;
}
