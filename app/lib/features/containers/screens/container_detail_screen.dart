/// `/containers/:name`: container detail (APP.md §9.2).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/links/external_links.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../providers/containers_providers.dart';
import '../widgets/container_actions.dart';
import '../widgets/container_visuals.dart';
import 'containers_screen.dart' show containersError;

class ContainerDetailScreen extends ConsumerWidget {
  const ContainerDetailScreen({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(containerDetailProvider(name));
    // Feed the client-side 2-minute CPU/memory history.
    ref.listen(containerDetailProvider(name), (_, next) {
      final d = next.value;
      if (d != null && !next.isLoading) ref.read(containerUsageHistoryProvider(name).notifier).add(d.summary);
    });
    final isAdmin = ref.watch(isAdminProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(name),
        actions: [
          if (isAdmin)
            IconButton(
              tooltip: 'Logs',
              icon: const Icon(Icons.article_outlined),
              onPressed: () => context.go(AppPaths.containerLogs(name)),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(containerDetailProvider(name));
          try {
            await ref.read(containerDetailProvider(name).future);
          } catch (_) {
            // Shown by the error view / stale banner.
          }
        },
        child: !value.hasValue && value.hasError
            ? ErrorView(
                error: containersError(value.error!),
                onRetry: () => ref.invalidate(containerDetailProvider(name)),
              )
            : AsyncValueView(
                value: value,
                onRetry: () => ref.invalidate(containerDetailProvider(name)),
                loading: const _DetailSkeleton(),
                data: (context, d) => _DetailBody(detail: d, isAdmin: isAdmin),
              ),
      ),
    );
  }
}

class _DetailSkeleton extends StatelessWidget {
  const _DetailSkeleton();

  @override
  Widget build(BuildContext context) => ListView(
    physics: const NeverScrollableScrollPhysics(),
    padding: const EdgeInsets.all(16),
    children: const [
      SkeletonBox(height: 120, radius: 12),
      SizedBox(height: 12),
      SkeletonBox(height: 90, radius: 12),
      SizedBox(height: 12),
      SkeletonBox(height: 220, radius: 12),
    ],
  );
}

class _DetailBody extends ConsumerWidget {
  const _DetailBody({required this.detail, required this.isAdmin});

  final ContainerDetail detail;
  final bool isAdmin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = detail;
    final s = d.summary;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _Header(summary: s),
        const SizedBox(height: 12),
        if (isAdmin) ...[_Actions(detail: d), const SizedBox(height: 12)],
        if (s.isRunning) ...[_LiveUsage(summary: s, pids: d.pids), const SizedBox(height: 12)],
        if (_dependencyHint(d) case final hint?) ...[
          Card(
            child: ListTile(leading: const Icon(Icons.account_tree_outlined), title: Text(hint)),
          ),
          const SizedBox(height: 12),
        ],
        SectionCard(
          title: 'Details',
          icon: Icons.info_outline,
          child: _Facts(detail: d),
        ),
        if (d.healthLog.isNotEmpty) ...[
          const SizedBox(height: 12),
          SectionCard(
            title: 'Health checks',
            icon: Icons.monitor_heart_outlined,
            child: _HealthLog(entries: d.healthLog),
          ),
        ],
        const SizedBox(height: 12),
        SectionCard(
          title: 'Recent events',
          icon: Icons.timeline,
          child: d.events.isEmpty
              ? Text(
                  'No events since the hub started.',
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                )
              : _Events(events: d.events),
        ),
      ],
    );
  }

  static String? _dependencyHint(ContainerDetail d) {
    final parts = <String>[];
    if (d.name == 'gluetun') {
      parts.add('Restarting gluetun also restarts qbittorrent.');
    } else if (d.dependents.isNotEmpty) {
      parts.add('${d.dependents.join(', ')} depend${d.dependents.length == 1 ? 's' : ''} on ${d.name}.');
    }
    if (d.dependsOn.isNotEmpty) parts.add('${d.name} depends on ${d.dependsOn.join(', ')}.');
    if (d.summary.sharesNetworkWith case final owner?) {
      if (!d.dependsOn.contains(owner)) parts.add('Uses the network of $owner.');
    }
    return parts.isEmpty ? null : parts.join(' ');
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.summary});

  final ContainerSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = summary;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                StatusDot(tone: containerStateTone(s.state), size: 12),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(s.name, style: theme.textTheme.titleLarge, overflow: TextOverflow.ellipsis),
                ),
                if (s.isLocked)
                  const StatusChip(label: 'Protected', icon: Icons.lock_outline, dense: true)
                else if (s.protection == ContainerProtection.confirm)
                  const StatusChip(label: 'Asks first', icon: Icons.verified_user_outlined, dense: true),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(s.image, style: muted),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                StatusChip(label: containerStateLabel(s.state), tone: containerStateTone(s.state), dense: true),
                ContainerHealthChip(s.health),
                if (s.imageVersion != null) StatusChip(label: s.imageVersion!, dense: true),
                if (s.pinned) const StatusChip(label: 'Pinned tag', dense: true),
                if (s.autoUpdate) const StatusChip(label: 'Auto-updated', tone: StatusTone.info, dense: true),
                if (s.updateAvailable) const StatusChip(label: 'Update available', tone: StatusTone.info, dense: true),
                Text(containerUptimeText(s), style: muted),
              ],
            ),
            if (s.links.isNotEmpty) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => openExternal(ref, s.links.first),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: Text('Open ${s.links.first.app.displayName}'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Actions extends ConsumerWidget {
  const _Actions({required this.detail});

  final ContainerDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = detail.summary;
    final name = s.name;
    final updates = ref.watch(updatesProvider).value;
    final canUpdate =
        (updates?.updaterAvailable ?? false) &&
        (updates?.items.any((u) => u.name == name && u.canUpdate && (u.updateAvailable ?? false)) ?? false);
    final running = ref.watch(containerJobsProvider.select((m) => m.containsKey(ContainerJobKeys.action(name))));
    final theme = Theme.of(context);

    void refresh() => ref.invalidate(containerDetailProvider(name));

    final buttons = <Widget>[
      FilledButton.tonalIcon(
        onPressed: s.isLocked || running ? null : () => runContainerAction(context, ref, s, ContainerAction.restart),
        icon: const Icon(Icons.restart_alt),
        label: const Text('Restart'),
      ),
      if (s.isRunning)
        OutlinedButton.icon(
          onPressed: s.isLocked || running ? null : () => runContainerAction(context, ref, s, ContainerAction.stop),
          icon: const Icon(Icons.stop_circle_outlined),
          label: const Text('Stop'),
        )
      else
        OutlinedButton.icon(
          onPressed: s.isLocked || running ? null : () => runContainerAction(context, ref, s, ContainerAction.start),
          icon: const Icon(Icons.play_circle_outline),
          label: const Text('Start'),
        ),
      if (canUpdate && !s.isLocked)
        OutlinedButton.icon(
          onPressed: () => runContainerUpdate(context, ref, name),
          icon: const Icon(Icons.system_update_alt),
          label: const Text('Update'),
        ),
      OutlinedButton.icon(
        onPressed: () => context.go(AppPaths.containerLogs(name)),
        icon: const Icon(Icons.article_outlined),
        label: const Text('Logs'),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(spacing: 8, runSpacing: 8, children: buttons),
        if (s.isLocked)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Protected: the hub never stops, restarts or updates $name.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ContainerJobChip(jobKey: ContainerJobKeys.action(name), onDone: refresh),
        ContainerJobChip(jobKey: ContainerJobKeys.update(name), onDone: refresh),
      ],
    );
  }
}

class _LiveUsage extends ConsumerWidget {
  const _LiveUsage({required this.summary, this.pids});

  final ContainerSummary summary;
  final int? pids;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = summary;
    final theme = Theme.of(context);
    final history = ref.watch(containerUsageHistoryProvider(s.name));
    final cpu = [for (final h in history) ?h.cpuPercent];
    if (s.cpuPercent == null && s.memBytes == null) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.speed),
          title: const Text('Collecting usage…'),
          subtitle: Text('CPU and memory appear after the next samples.', style: theme.textTheme.bodySmall),
        ),
      );
    }
    Widget stat(String label, String value) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        Text(value, style: theme.textTheme.titleMedium),
      ],
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 24,
              runSpacing: 12,
              children: [
                stat('CPU', formatPercent(s.cpuPercent, decimals: 1)),
                stat('Memory', '${formatBytes(s.memBytes)} · ${formatPercent(s.memPercent, decimals: 1)}'),
                if (s.sharesNetworkWith != null)
                  stat('Network', 'via ${s.sharesNetworkWith}')
                else if (s.netRxBps != null)
                  stat('Network', '↓ ${formatBps(s.netRxBps)}  ↑ ${formatBps(s.netTxBps)}'),
                if (pids != null) stat('Processes', '$pids'),
              ],
            ),
            if (cpu.length >= 2) ...[
              const SizedBox(height: 12),
              Text('CPU, last 2 min', style: theme.textTheme.labelSmall),
              const SizedBox(height: 4),
              Sparkline(values: cpu, minY: 0, height: 48),
            ],
          ],
        ),
      ),
    );
  }
}

class _Facts extends StatelessWidget {
  const _Facts({required this.detail});

  final ContainerDetail detail;

  @override
  Widget build(BuildContext context) {
    final d = detail;
    final s = d.summary;
    return KeyValueList(
      entries: [
        KeyValue('Restart count', '${d.restartCount}'),
        if (s.startedAt != null) KeyValue('Started', '${formatDateTime(s.startedAt)} (${formatRelative(s.startedAt)})'),
        if (d.finishedAt != null)
          KeyValue('Finished', '${formatDateTime(d.finishedAt)} (${formatRelative(d.finishedAt)})'),
        if (d.exitCode != null) KeyValue('Exit code', '${d.exitCode}'),
        KeyValue('OOM killed', d.oomKilled ? 'Yes' : 'No'),
        if (d.error != null) KeyValue('Error', d.error),
        KeyValue('Restart policy', d.restartPolicy),
        KeyValue('Network', d.networkMode),
        if (s.ports.isNotEmpty)
          KeyValue('Ports', s.ports.map((p) => '${p.public} → ${p.private}/${p.protocol}').join('\n')),
        if (d.mounts.isNotEmpty)
          KeyValue('Mounts', d.mounts.map((m) => '${m.destination} (${m.readOnly ? 'ro' : 'rw'})').join('\n')),
        KeyValue('Image id', shortImageId(d.imageId)),
        KeyValue('Created', formatDateTime(d.createdAt)),
      ],
    );
  }
}

class _HealthLog extends StatelessWidget {
  const _HealthLog({required this.entries});

  final List<ContainerHealthLogEntry> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', fontFamilyFallback: const ['Courier']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final h in entries.reversed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Tooltip(message: formatDateTime(h.start), child: Text(formatTime(h.start))),
                    const SizedBox(width: 12),
                    StatusChip(
                      label: 'exit ${h.exitCode}',
                      tone: h.exitCode == 0 ? StatusTone.ok : StatusTone.error,
                      dense: true,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${h.end.difference(h.start).inMilliseconds} ms',
                      style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
                if (h.output != null) ...[
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: SelectableText(h.output!, style: mono),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _Events extends StatelessWidget {
  const _Events({required this.events});

  final List<ContainerEvent> events;

  static (IconData, StatusTone, String) _look(ContainerEvent e) => switch (e.action) {
    ContainerEventAction.start => (Icons.play_arrow, StatusTone.ok, 'Started'),
    ContainerEventAction.restart => (Icons.restart_alt, StatusTone.info, 'Restarted'),
    ContainerEventAction.stop => (Icons.stop, StatusTone.neutral, 'Stopped'),
    ContainerEventAction.die => (
      Icons.power_settings_new,
      (e.exitCode ?? 0) == 0 ? StatusTone.neutral : StatusTone.error,
      e.exitCode == null ? 'Exited' : 'Exited (${e.exitCode})',
    ),
    ContainerEventAction.kill => (Icons.dangerous_outlined, StatusTone.warning, 'Killed'),
    ContainerEventAction.oom => (Icons.memory, StatusTone.error, 'Out of memory'),
    ContainerEventAction.health => (
      Icons.monitor_heart_outlined,
      e.health == 'healthy' ? StatusTone.ok : (e.health == 'unhealthy' ? StatusTone.error : StatusTone.warning),
      'Health: ${e.health ?? 'changed'}',
    ),
    ContainerEventAction.create => (Icons.add_box_outlined, StatusTone.info, 'Created'),
    ContainerEventAction.destroy => (Icons.delete_outline, StatusTone.neutral, 'Removed'),
    ContainerEventAction.unknown => (Icons.circle_outlined, StatusTone.neutral, 'Event'),
  };

  @override
  Widget build(BuildContext context) {
    final colors = StatusColors.of(context);
    final theme = Theme.of(context);
    return Column(
      children: [
        for (final e in events)
          () {
            final (icon, tone, label) = _look(e);
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(icon, color: colors.forTone(tone)),
              title: Text(label),
              trailing: Tooltip(
                message: formatDateTime(e.at),
                child: Text(formatRelative(e.at), style: theme.textTheme.labelSmall),
              ),
            );
          }(),
      ],
    );
  }
}
