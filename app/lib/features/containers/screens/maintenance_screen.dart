/// `/containers/maintenance`: Decluttarr and Recyclarr (APP.md §9.5).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/containers_api.dart';
import '../providers/containers_providers.dart';
import '../widgets/container_actions.dart';
import '../widgets/container_visuals.dart';

class MaintenanceScreen extends ConsumerWidget {
  const MaintenanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final decluttarr = ref.watch(decluttarrProvider);
    final recyclarr = ref.watch(recyclarrProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Maintenance')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref
            ..invalidate(decluttarrProvider)
            ..invalidate(recyclarrProvider);
          await Future.wait([
            ref.read(decluttarrProvider.future).then<void>((_) {}, onError: (Object _) {}),
            ref.read(recyclarrProvider.future).then<void>((_) {}, onError: (Object _) {}),
          ]);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            SectionCard(
              title: 'Decluttarr',
              icon: Icons.cleaning_services_outlined,
              trailing: _containerChip(decluttarr.value?.container),
              child: _section(
                decluttarr,
                onRetry: () => ref.invalidate(decluttarrProvider),
                height: 160,
                data: (d) => DecluttarrPanel(status: d),
              ),
            ),
            const SizedBox(height: 12),
            SectionCard(
              title: 'Recyclarr',
              icon: Icons.tune,
              trailing: _containerChip(recyclarr.value?.container),
              child: _section(
                recyclarr,
                onRetry: () => ref.invalidate(recyclarrProvider),
                height: 200,
                data: (r) => RecyclarrPanel(status: r),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget? _containerChip(MaintenanceContainerState? c) {
    if (c == null) return null;
    final health = c.health;
    final tone = health == ContainerHealth.unhealthy ? StatusTone.error : containerStateTone(c.state);
    final label =
        health == ContainerHealth.healthy || health == ContainerHealth.unhealthy || health == ContainerHealth.starting
        ? health.name
        : containerStateLabel(c.state).toLowerCase();
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: StatusChip(label: label, tone: tone, dense: true),
    );
  }

  static Widget _section<T>(
    AsyncValue<T> v, {
    required VoidCallback onRetry,
    required double height,
    required Widget Function(T data) data,
  }) {
    if (v.hasValue) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (v.hasError)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: StaleBanner(onRetry: onRetry),
            ),
          data(v.value as T),
        ],
      );
    }
    if (v.hasError) return ErrorView(error: v.error!, compact: true, onRetry: onRetry);
    return Column(
      children: [
        SkeletonBox(height: height / 3),
        const SizedBox(height: 8),
        SkeletonBox(height: height / 3),
      ],
    );
  }
}

class DecluttarrPanel extends StatelessWidget {
  const DecluttarrPanel({super.key, required this.status});

  final DecluttarrStatus status;

  @override
  Widget build(BuildContext context) {
    final d = status;
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final h = d.last24h;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (d.testMode)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: colors.warning.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.science_outlined, color: colors.warning, size: 18),
                const SizedBox(width: 8),
                const Expanded(child: Text('Test mode is on: nothing is really removed.')),
              ],
            ),
          ),
        Text(
          [
            if (d.lastRunAt != null) 'Last run ${formatTime(d.lastRunAt)}' else 'No run in the last 24 h',
            if (d.nextRunAt != null) 'next about ${formatTime(d.nextRunAt)}',
            'every ${d.intervalMinutes} min',
          ].join(' · '),
        ),
        const SizedBox(height: 4),
        Text(
          '24 h: ${h.runs} runs · ${h.removed.length} removed · ${h.strikes.length} strikes'
          '${h.searches > 0 ? ' · ${h.searches} searched' : ''}'
          '${h.obsoleteTagged > 0 ? ' · ${h.obsoleteTagged} tagged obsolete' : ''}',
          style: muted,
        ),
        const SizedBox(height: 8),
        if (h.removed.isEmpty)
          Row(
            children: [
              Icon(Icons.check_circle_outline, color: colors.ok, size: 18),
              const SizedBox(width: 8),
              const Expanded(child: Text('Queues are clean: nothing removed in the last 24 h')),
            ],
          )
        else ...[
          Text('Removed', style: theme.textTheme.labelLarge),
          for (final r in h.removed)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.delete_sweep_outlined),
              title: Text(r.title),
              subtitle: Text('${r.job}${r.kind == DecluttarrRemovalKind.queueRemoval ? ' · torrent kept' : ''}'),
              trailing: Tooltip(
                message: formatDateTime(r.at),
                child: Text(formatTime(r.at), style: muted),
              ),
            ),
        ],
        if (h.strikes.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Strikes', style: theme.textTheme.labelLarge),
          for (final s in h.strikes)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.flag_outlined, color: s.count >= s.max ? colors.error : colors.warning),
              title: Text(s.title),
              subtitle: Text('${s.job} · ${s.count}/${s.max}'),
              trailing: Tooltip(
                message: formatDateTime(s.at),
                child: Text(formatTime(s.at), style: muted),
              ),
            ),
        ],
        _Messages(title: 'Warnings', entries: d.warnings, tone: StatusTone.warning),
        _Messages(title: 'Errors', entries: d.errors, tone: StatusTone.error),
      ],
    );
  }
}

class _Messages extends StatelessWidget {
  const _Messages({required this.title, required this.entries, required this.tone});

  final String title;
  final List<MaintenanceLogEntry> entries;
  final StatusTone tone;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final color = StatusColors.of(context).forTone(tone);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: theme.textTheme.labelLarge?.copyWith(color: color)),
          for (final e in entries.take(10))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('${formatTime(e.at)}  ${e.text}', style: theme.textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}

class RecyclarrPanel extends ConsumerWidget {
  const RecyclarrPanel({super.key, required this.status});

  final RecyclarrStatus status;

  Future<void> _sync(BuildContext context, WidgetRef ref) async {
    final ok = await ConfirmDialog.show(
      context,
      title: 'Sync Recyclarr now?',
      message:
          'Custom formats and quality profiles in Sonarr and Radarr are overwritten with the TRaSH guide settings.',
      confirmLabel: 'Sync now',
    );
    if (!ok || !context.mounted) return;
    try {
      final job = await ref.read(containersApiProvider).recyclarrSync();
      ref.read(containerJobsProvider.notifier).track(ContainerJobKeys.recyclarrSync, job.id);
    } catch (e) {
      if (context.mounted) context.showError(e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = status;
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final isAdmin = ref.watch(isAdminProvider);
    final syncing = ref.watch(containerJobsProvider.select((m) => m.containsKey(ContainerJobKeys.recyclarrSync)));
    final run = r.lastRun;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          [
            'Schedule: ${describeCron(r.schedule)}',
            if (r.nextRunAt != null) 'next ${formatRelative(r.nextRunAt)}',
          ].join(' · '),
        ),
        const SizedBox(height: 8),
        if (run == null)
          Text('No run log found yet.', style: muted)
        else ...[
          Row(
            children: [
              Icon(run.ok ? Icons.check_circle : Icons.cancel, color: run.ok ? colors.ok : colors.error, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Tooltip(
                  message: formatDateTime(run.startedAt),
                  child: Text('Last run ${formatRelative(run.startedAt)}${run.ok ? '' : ' · failed'}'),
                ),
              ),
            ],
          ),
          for (final i in run.instances)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(i.completed ? Icons.check : Icons.close, color: i.completed ? colors.ok : colors.error),
              title: Text('${i.name} (${i.type == RecyclarrInstanceType.radarr ? 'Radarr' : 'Sonarr'})'),
              subtitle: Text(
                [
                  'CF ${i.customFormatsCreated} created · ${i.customFormatsUpdated} updated · ${i.customFormatsSkipped} unchanged',
                  if (i.profilesSynced != null) '${i.profilesSynced} profiles synced',
                  if (i.qualitySizesSynced) 'sizes synced',
                ].join('\n'),
              ),
            ),
          for (final w in run.warnings.take(5))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(w, style: theme.textTheme.bodySmall?.copyWith(color: colors.warning)),
            ),
          for (final e in run.errors.take(5))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(e, style: theme.textTheme.bodySmall?.copyWith(color: colors.error)),
            ),
        ],
        if (isAdmin) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: r.canSyncNow && !syncing ? () => _sync(context, ref) : null,
                icon: const Icon(Icons.sync),
                label: const Text('Sync now'),
              ),
              const SizedBox(width: 8),
              if (!r.canSyncNow) Expanded(child: Text('Needs the updater sidecar', style: muted)),
            ],
          ),
          ContainerJobChip(jobKey: ContainerJobKeys.recyclarrSync, onDone: () => ref.invalidate(recyclarrProvider)),
        ],
      ],
    );
  }
}
