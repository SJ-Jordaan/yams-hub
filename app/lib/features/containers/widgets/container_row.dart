/// One container row of the Containers list (APP.md §9.1).
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
import 'container_actions.dart';
import 'container_visuals.dart';

enum _RowAction { restart, stop, start, update, logs, web }

class ContainerRow extends ConsumerWidget {
  const ContainerRow({super.key, required this.container, this.canUpdate = false});

  final ContainerSummary container;

  /// From `GET /updates`: the updater can update this container.
  final bool canUpdate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = container;
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final isAdmin = ref.watch(isAdminProvider);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    final meta = <Widget>[
      Text(containerUptimeText(c), style: muted),
      if (c.cpuPercent != null)
        UsageBar(label: formatPercent(c.cpuPercent, decimals: 1), fraction: cpuFraction(c.cpuPercent!), width: 36),
      if (c.memBytes != null) UsageBar(label: formatBytes(c.memBytes), fraction: (c.memPercent ?? 0) / 100, width: 36),
      if (c.imageVersion != null) Text(c.imageVersion!, style: muted, overflow: TextOverflow.ellipsis),
    ];

    return ListTile(
      key: ValueKey('container-${c.name}'),
      onTap: () => context.go(AppPaths.container(c.name)),
      contentPadding: const EdgeInsets.only(left: 16, right: 4),
      leading: Tooltip(
        message: containerStateLabel(c.state),
        child: StatusDot(tone: containerStateTone(c.state), size: 12),
      ),
      title: Row(
        children: [
          Flexible(child: Text(c.name, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 8),
          ContainerHealthChip(c.health),
          if (c.updateAvailable) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: 'Update available',
              child: Icon(Icons.circle, size: 8, color: colors.info),
            ),
          ],
          if (c.isLocked) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: 'Protected',
              child: Icon(Icons.lock_outline, size: 16, color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
          if (c.sharesNetworkWith != null) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: 'Uses the network of ${c.sharesNetworkWith}',
              child: Icon(Icons.link, size: 16, color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(spacing: 10, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: meta),
          ContainerJobChip(
            jobKey: ContainerJobKeys.action(c.name),
            onDone: () => ref.invalidate(containerListProvider),
          ),
          ContainerJobChip(
            jobKey: ContainerJobKeys.update(c.name),
            onDone: () => ref.invalidate(containerListProvider),
          ),
        ],
      ),
      trailing: _menu(context, ref, isAdmin),
    );
  }

  Widget? _menu(BuildContext context, WidgetRef ref, bool isAdmin) {
    final c = container;
    final hasWeb = c.links.isNotEmpty;
    if (!isAdmin && !hasWeb) return null;
    return PopupMenuButton<_RowAction>(
      tooltip: 'Actions for ${c.name}',
      onSelected: (a) => _run(context, ref, a),
      itemBuilder: (context) => [
        // Locked: the actions stay visible but disabled, marked "Protected".
        if (isAdmin && c.isLocked) ...[
          const PopupMenuItem(
            enabled: false,
            child: ListTile(
              enabled: false,
              leading: Icon(Icons.restart_alt),
              title: Text('Restart'),
              subtitle: Text('Protected'),
            ),
          ),
          PopupMenuItem(
            enabled: false,
            child: ListTile(
              enabled: false,
              leading: Icon(c.isRunning ? Icons.stop_circle_outlined : Icons.play_circle_outline),
              title: Text(c.isRunning ? 'Stop' : 'Start'),
              subtitle: const Text('Protected'),
            ),
          ),
        ],
        if (isAdmin && !c.isLocked) ...[
          const PopupMenuItem(
            value: _RowAction.restart,
            child: ListTile(leading: Icon(Icons.restart_alt), title: Text('Restart')),
          ),
          if (c.isRunning)
            const PopupMenuItem(
              value: _RowAction.stop,
              child: ListTile(leading: Icon(Icons.stop_circle_outlined), title: Text('Stop')),
            )
          else
            const PopupMenuItem(
              value: _RowAction.start,
              child: ListTile(leading: Icon(Icons.play_circle_outline), title: Text('Start')),
            ),
          if (canUpdate && c.updateAvailable)
            const PopupMenuItem(
              value: _RowAction.update,
              child: ListTile(leading: Icon(Icons.system_update_alt), title: Text('Update')),
            ),
        ],
        if (isAdmin)
          const PopupMenuItem(
            value: _RowAction.logs,
            child: ListTile(leading: Icon(Icons.article_outlined), title: Text('Logs')),
          ),
        if (hasWeb)
          const PopupMenuItem(
            value: _RowAction.web,
            child: ListTile(leading: Icon(Icons.open_in_new), title: Text('Open web UI')),
          ),
      ],
    );
  }

  Future<void> _run(BuildContext context, WidgetRef ref, _RowAction a) async {
    final c = container;
    switch (a) {
      case _RowAction.restart:
        await runContainerAction(context, ref, c, ContainerAction.restart);
      case _RowAction.stop:
        await runContainerAction(context, ref, c, ContainerAction.stop);
      case _RowAction.start:
        await runContainerAction(context, ref, c, ContainerAction.start);
      case _RowAction.update:
        await runContainerUpdate(context, ref, c.name);
      case _RowAction.logs:
        context.go(AppPaths.containerLogs(c.name));
      case _RowAction.web:
        final ok = await openExternal(ref, c.links.first);
        if (!ok && context.mounted) context.showSnack("Couldn't open ${c.links.first.app.displayName}");
    }
  }
}
