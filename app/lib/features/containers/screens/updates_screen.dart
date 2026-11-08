/// `/containers/updates`: Watchtower scan, update checks and updates
/// (APP.md §9.4). Manual refresh only.
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

/// The Watchtower env change that enables per-container checks.
const watchtowerEndpointsEnv = 'WATCHTOWER_HTTP_API_ENDPOINTS=metrics,check,containers,history';

/// The status of one row.
enum UpdateRowStatus {
  available('Update available', StatusTone.info),
  upToDate('Up to date', StatusTone.ok),
  pinned('Pinned tag', StatusTone.neutral),
  error('Error', StatusTone.error),
  notChecked('Not checked', StatusTone.neutral);

  const UpdateRowStatus(this.label, this.tone);

  final String label;
  final StatusTone tone;

  static UpdateRowStatus of(UpdateInfo u) {
    if (u.updateAvailable ?? false) return available;
    if (u.error != null) return error;
    if (u.pinned) return pinned;
    if (u.updateAvailable == false) return upToDate;
    return notChecked;
  }
}

class UpdatesScreen extends ConsumerWidget {
  const UpdatesScreen({super.key});

  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(updatesProvider);
    try {
      await ref.read(updatesProvider.future);
    } catch (_) {
      // Shown by the error view / stale banner.
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(updatesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Updates')),
      body: RefreshIndicator(
        onRefresh: () => _refresh(ref),
        child: AsyncValueView(
          value: value,
          onRetry: () => ref.invalidate(updatesProvider),
          data: (context, u) => _UpdatesBody(updates: u),
        ),
      ),
    );
  }
}

class _UpdatesBody extends ConsumerWidget {
  const _UpdatesBody({required this.updates});

  final UpdatesResponse updates;

  Future<void> _check(BuildContext context, WidgetRef ref) async {
    try {
      final job = await ref.read(containersApiProvider).checkUpdates();
      ref.read(containerJobsProvider.notifier).track(ContainerJobKeys.check, job.id);
    } catch (e) {
      if (context.mounted) context.showError(e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final u = updates;
    final theme = Theme.of(context);
    final isAdmin = ref.watch(isAdminProvider);
    final checking =
        u.checking || ref.watch(containerJobsProvider.select((m) => m.containsKey(ContainerJobKeys.check)));
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final available = u.updatesAvailable;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        if (u.lastScan case final scan?) ...[_ScanStrip(scan: scan), const SizedBox(height: 12)],
        if (!u.available) ...[const _EnableCheckCard(), const SizedBox(height: 12)],
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            available == 0
                                ? (u.checkedAt == null ? 'No update check yet' : 'No updates found')
                                : (available == 1 ? '1 update available' : '$available updates available'),
                            style: theme.textTheme.titleMedium,
                          ),
                          Tooltip(
                            message: u.checkedAt == null ? '' : formatDateTime(u.checkedAt),
                            child: Text(
                              u.checkedAt == null ? 'Never checked' : 'Last checked ${formatRelative(u.checkedAt)}',
                              style: muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (isAdmin && u.available)
                      FilledButton.tonalIcon(
                        onPressed: checking ? null : () => _check(context, ref),
                        icon: checking
                            ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.refresh),
                        label: const Text('Check now'),
                      ),
                  ],
                ),
                ContainerJobChip(jobKey: ContainerJobKeys.check, onDone: () => ref.invalidate(updatesProvider)),
                if (!u.updaterAvailable) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.terminal, size: 16, color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(child: Text('Run `yams update-containers` on the NAS to apply updates.', style: muted)),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (u.items.isEmpty)
          const EmptyView(
            icon: Icons.inventory_2_outlined,
            title: 'No containers',
            message: 'Docker did not list any container.',
          )
        else
          for (final item in u.items) _UpdateRow(item: item, updaterAvailable: u.updaterAvailable),
      ],
    );
  }
}

class _ScanStrip extends StatelessWidget {
  const _ScanStrip({required this.scan});

  final WatchtowerScan scan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    Widget n(String label, int v, {StatusTone? tone}) => Column(
      children: [
        Text(
          '$v',
          style: theme.textTheme.titleMedium?.copyWith(color: tone == null || v == 0 ? null : colors.forTone(tone)),
        ),
        Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
    final when = scan.at == null
        ? (scan.scansTotal == 0 ? 'No scan since Watchtower started' : 'Last scan')
        : 'Last scan ${formatRelative(scan.at)}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.radar, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Watchtower', style: theme.textTheme.titleSmall),
                const SizedBox(width: 12),
                Expanded(
                  child: Tooltip(
                    message: scan.at == null ? '' : formatDateTime(scan.at),
                    child: Text(
                      when,
                      style: theme.textTheme.labelSmall,
                      textAlign: TextAlign.end,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                n('scanned', scan.scanned),
                n('updated', scan.updated, tone: StatusTone.ok),
                n('failed', scan.failed, tone: StatusTone.error),
                n('skipped', scan.skipped, tone: StatusTone.warning),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EnableCheckCard extends StatelessWidget {
  const _EnableCheckCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    return Card(
      color: colors.info.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline, color: colors.info),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "Per-container update checks need Watchtower's check endpoint",
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Add this line to watchtower.env and remove WATCHTOWER_HTTP_API_METRICS=true, then recreate Watchtower:',
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: SelectableText(
                watchtowerEndpointsEnv,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  fontFamilyFallback: const ['Courier'],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'The daily scheduled scan and the Discord notifications keep working unchanged.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _UpdateRow extends ConsumerWidget {
  const _UpdateRow({required this.item, required this.updaterAvailable});

  final UpdateInfo item;
  final bool updaterAvailable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final u = item;
    final theme = Theme.of(context);
    final isAdmin = ref.watch(isAdminProvider);
    final status = UpdateRowStatus.of(u);
    final updating = ref.watch(containerJobsProvider.select((m) => m[ContainerJobKeys.update(u.name)]));
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final canUpdate = isAdmin && updaterAvailable && u.canUpdate && (u.updateAvailable ?? false);
    return Card(
      key: ValueKey('update-${u.name}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(u.name, style: theme.textTheme.titleSmall)),
                StatusChip(label: status.label, tone: status.tone, dense: true),
              ],
            ),
            const SizedBox(height: 4),
            Text(u.currentVersion ?? u.image, style: muted, overflow: TextOverflow.ellipsis),
            if (u.error != null) ...[
              const SizedBox(height: 4),
              Text(u.error!, style: theme.textTheme.bodySmall?.copyWith(color: StatusColors.of(context).error)),
            ],
            if (u.autoUpdate || canUpdate || updating != null) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (u.autoUpdate)
                    const StatusChip(
                      label: 'Auto-updated by Watchtower',
                      icon: Icons.autorenew,
                      tone: StatusTone.info,
                      dense: true,
                    ),
                  if (canUpdate && updating == null)
                    FilledButton.tonalIcon(
                      onPressed: () => runContainerUpdate(context, ref, u.name),
                      icon: const Icon(Icons.system_update_alt),
                      label: const Text('Update'),
                    ),
                  ContainerJobChip(
                    jobKey: ContainerJobKeys.update(u.name),
                    onDone: () => ref.invalidate(updatesProvider),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
