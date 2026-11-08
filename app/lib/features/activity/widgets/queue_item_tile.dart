/// One row of the unified queue (APP.md §6.1 `QueueItemTile`).
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

import '../data/activity_api.dart';
import 'activity_actions.dart';
import 'activity_format.dart';
import 'manual_import_sheet.dart';

class QueueItemTile extends ConsumerWidget {
  const QueueItemTile({super.key, required this.item});

  final QueueItem item;

  void _open(BuildContext context) {
    final t = item.torrent;
    if (t != null) {
      context.push(AppPaths.torrent(t.hash));
    } else {
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (_) => QueueArrSheet(item: item),
      );
    }
  }

  Future<void> _actions(BuildContext context, WidgetRef ref) async {
    final t = item.torrent;
    final entry = item.arr.firstOrNull;
    final importEntry = item.importEntry;
    final choice = await ActionSheet.show<String>(
      context,
      title: item.title,
      items: [
        if (importEntry != null) const ActionSheetItem(value: 'import', label: 'Import…', icon: Icons.move_to_inbox),
        if (t != null && t.state == TorrentState.stopped)
          const ActionSheetItem(value: 'start', label: 'Start', icon: Icons.play_arrow),
        if (t != null && t.state != TorrentState.stopped)
          const ActionSheetItem(value: 'stop', label: 'Stop', icon: Icons.pause),
        if (entry != null && item.state == QueueItemState.delayed)
          const ActionSheetItem(value: 'grab', label: 'Grab now', icon: Icons.download),
        if (t != null)
          ActionSheetItem(
            value: 'protect',
            label: t.protected ? 'Unprotect' : 'Protect',
            subtitle: t.protected ? 'Allow decluttarr to clean it up' : 'Tag "Keep": decluttarr never removes it',
            icon: t.protected ? Icons.shield : Icons.shield_outlined,
          ),
        if (_libraryRoute(entry) != null)
          const ActionSheetItem(value: 'library', label: 'Open in Library', icon: Icons.video_library_outlined),
        if (entry != null && entry.links.isNotEmpty)
          ActionSheetItem(value: 'arr', label: 'Open in ${arrLabel(entry.service)}', icon: Icons.open_in_new),
        if (entry != null)
          const ActionSheetItem(value: 'remove', label: 'Remove…', icon: Icons.playlist_remove, destructive: true),
        if (entry == null && t != null)
          const ActionSheetItem(value: 'delete', label: 'Delete…', icon: Icons.delete_outline, destructive: true),
      ],
    );
    if (choice == null || !context.mounted) return;
    switch (choice) {
      case 'import':
        await showManualImportSheet(context, entry: importEntry!, title: item.title);
      case 'start' || 'stop':
        await torrentAction(
          context,
          ref,
          [t!.hash],
          choice == 'start' ? TorrentAction.start : TorrentAction.stop,
          done: choice == 'start' ? 'Started' : 'Stopped',
        );
      case 'grab':
        await runActivityAction(
          context,
          ref,
          () => ref.read(activityApiProvider).grab(entry!.service, entry.queueIds),
          done: 'Grab started',
        );
      case 'protect':
        await toggleProtect(context, ref, t!);
      case 'library':
        context.go(_libraryRoute(entry)!);
      case 'arr':
        await openExternal(ref, entry!.links.first);
      case 'remove':
        await removeFromQueue(context, ref, title: item.title, entry: entry!);
      case 'delete':
        await deleteTorrents(context, ref, [t!]);
    }
  }

  static String? _libraryRoute(QueueArrEntry? e) {
    if (e == null) return null;
    if (e.seriesId case final id?) return AppPaths.seriesDetail(id);
    if (e.movieId case final id?) return AppPaths.movieDetail(id);
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final admin = ref.watch(isAdminProvider);
    final attention = item.attention;
    final borderColor = attention == null ? null : colors.forTone(attentionTone(attention));
    final entry = item.arr.firstOrNull;
    final importEntry = item.importEntry;
    final message = item.arr.expand((a) => a.messages).firstOrNull;
    final poster = item.arr.map((a) => a.posterPath).nonNulls.firstOrNull;
    final left = item.sizeLeftBytes > 0 ? '${formatBytes(item.sizeLeftBytes)} left' : formatBytes(item.sizeBytes);
    final progressLabel = [
      formatPercent(item.progress * 100),
      left,
      if (item.etaSeconds != null && item.progress < 1) 'ETA ${formatEta(item.etaSeconds)}',
    ].join(' · ');

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(context),
        onLongPress: admin ? () => _actions(context, ref) : null,
        child: Container(
          decoration: borderColor == null
              ? null
              : BoxDecoration(
                  border: Border(left: BorderSide(color: borderColor, width: 4)),
                ),
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (poster != null)
                HubImage(poster, width: 40, height: 60, borderRadius: BorderRadius.circular(6))
              else
                SizedBox(
                  width: 40,
                  height: 48,
                  child: Icon(
                    item.torrent == null ? Icons.cloud_download_outlined : Icons.insert_drive_file_outlined,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.title, style: theme.textTheme.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                    if (item.subtitle != null)
                      Text(
                        item.subtitle!,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        StatusChip(label: queueStateLabel(item.state), tone: queueStateTone(item.state), dense: true),
                        if (item.dlBps > 0)
                          SpeedText(bps: item.dlBps, direction: SpeedDirection.down, style: theme.textTheme.bodySmall),
                        if (item.upBps > 0)
                          SpeedText(bps: item.upBps, direction: SpeedDirection.up, style: theme.textTheme.bodySmall),
                        if (item.torrent?.protected ?? false)
                          Icon(Icons.shield, size: 16, color: colors.info, semanticLabel: 'Protected'),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ProgressBar(value: item.progress, tone: queueStateTone(item.state)),
                    const SizedBox(height: 4),
                    Text(progressLabel, style: theme.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (attention != null && message != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        '${attentionLabel(attention)}: $message',
                        style: theme.textTheme.bodySmall?.copyWith(color: borderColor),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (admin && importEntry != null) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          FilledButton.tonalIcon(
                            onPressed: () => showManualImportSheet(context, entry: importEntry, title: item.title),
                            icon: const Icon(Icons.move_to_inbox, size: 18),
                            label: const Text('Import…'),
                          ),
                          if (importEntry.links.isNotEmpty)
                            TextButton.icon(
                              onPressed: () => openExternal(ref, importEntry.links.first),
                              icon: const Icon(Icons.open_in_new, size: 18),
                              label: Text('Open in ${arrLabel(importEntry.service)}'),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (admin && (entry != null || item.torrent != null))
                IconButton(
                  tooltip: 'Actions',
                  icon: const Icon(Icons.more_vert),
                  onPressed: () => _actions(context, ref),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Details of a queue item without a torrent (or its *arr side).
class QueueArrSheet extends ConsumerWidget {
  const QueueArrSheet({super.key, required this.item});

  final QueueItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final admin = ref.watch(isAdminProvider);
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      children: [
        Text(item.title, style: theme.textTheme.titleLarge),
        if (item.subtitle != null) Text(item.subtitle!, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 12),
        for (final e in item.arr) ...[
          KeyValueList(
            entries: [
              KeyValue('Status', '${e.status.name} · ${e.trackedState.name}'),
              KeyValue('Episodes', e.episodesLabel),
              KeyValue('Queue ids', e.queueIds.join(', ')),
              KeyValue('Upgrade', e.isUpgrade ? 'Yes' : null),
            ],
          ),
          for (final m in e.messages)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(m, style: theme.textTheme.bodySmall),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (QueueItemTile._libraryRoute(e) case final route?)
                OutlinedButton.icon(
                  onPressed: () {
                    final router = GoRouter.of(context);
                    Navigator.of(context).pop();
                    router.go(route);
                  },
                  icon: const Icon(Icons.video_library_outlined),
                  label: Text(e.mediaTitle ?? 'Open in Library'),
                ),
              if (admin && e.canManualImport)
                FilledButton.tonalIcon(
                  onPressed: () => showManualImportSheet(context, entry: e, title: item.title),
                  icon: const Icon(Icons.move_to_inbox),
                  label: const Text('Import…'),
                ),
              if (admin)
                TextButton.icon(
                  onPressed: () async {
                    final ok = await removeFromQueue(context, ref, title: item.title, entry: e);
                    if (ok && context.mounted) Navigator.of(context).pop();
                  },
                  icon: const Icon(Icons.playlist_remove),
                  label: const Text('Remove…'),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
