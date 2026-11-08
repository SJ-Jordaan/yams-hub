/// `/media/shelfmark`: book and audiobook downloads (APP.md §8.3), every
/// 30 s. Searching and requesting books inside the hub is v1.1.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../providers/media_providers.dart';
import '../widgets/media_common.dart';

const _shelfmarkWeb = ExternalLink(ExternalApp.shelfmark, '/');

class ShelfmarkScreen extends ConsumerWidget {
  const ShelfmarkScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(shelfmarkProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Shelfmark')),
      body: AsyncValueView<ShelfmarkStatus>(
        value: value,
        onRetry: () => ref.invalidate(shelfmarkProvider),
        loading: const SkeletonList(count: 4),
        errorActions: [_OpenButton(compact: true)],
        data: (context, s) => _Body(status: s, onRefresh: () => ref.refresh(shelfmarkProvider.future)),
      ),
    );
  }
}

class _OpenButton extends ConsumerWidget {
  const _OpenButton({this.compact = false, this.link = _shelfmarkWeb});

  final bool compact;
  final ExternalLink link;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void open() => openLink(context, ref, link, name: 'Shelfmark');
    if (compact) {
      return OutlinedButton.icon(
        onPressed: open,
        icon: const Icon(Icons.open_in_new),
        label: const Text('Open Shelfmark'),
      );
    }
    return FilledButton.icon(
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
      onPressed: open,
      icon: const Icon(Icons.auto_stories),
      label: const Text('Open Shelfmark to find books'),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.status, required this.onRefresh});

  final ShelfmarkStatus status;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = status;
    final (stateLabel, stateTone) = switch (s.status) {
      ShelfmarkServiceState.ok => ('Healthy', StatusTone.ok),
      ShelfmarkServiceState.degraded => ('Degraded', StatusTone.warning),
      ShelfmarkServiceState.down => ('Down', StatusTone.error),
      ShelfmarkServiceState.unknown => ('Unknown', StatusTone.neutral),
    };
    final (coordLabel, coordTone) = switch (s.coordinator) {
      ShelfmarkCoordinator.running => ('Downloads running', StatusTone.ok),
      ShelfmarkCoordinator.stopped => ('Downloads stopped', StatusTone.error),
      ShelfmarkCoordinator.unknown => ('Coordinator unknown', StatusTone.neutral),
    };
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return MediaRefreshList(
      onRefresh: onRefresh,
      children: [
        if (s.coordinator == ShelfmarkCoordinator.stopped) ...[
          const SizedBox(height: 16),
          const MediaNoticeCard(
            icon: Icons.warning_amber_rounded,
            tone: StatusTone.error,
            title: 'The download coordinator is stopped',
            message: 'Book and audiobook downloads are paused until Shelfmark restarts it (or the container restarts).',
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatusChip(label: stateLabel, tone: stateTone),
              StatusChip(label: coordLabel, tone: coordTone),
              if (s.generatedAt != null) Text('Updated ${formatRelative(s.generatedAt)}', style: muted),
            ],
          ),
        ),
        if (s.isEmpty)
          const SizedBox(
            height: 220,
            child: EmptyView(
              icon: Icons.auto_stories_outlined,
              title: 'No book downloads yet',
              message: 'Find books and audiobooks in Shelfmark; their progress shows up here.',
            ),
          )
        else ...[
          MediaSection(
            title: 'Queue',
            child: MediaStatGrid(
              minTileWidth: 100,
              children: [
                MediaStatTile(label: 'Downloading', value: formatCount(s.queue.active), icon: Icons.downloading),
                MediaStatTile(label: 'Queued', value: formatCount(s.queue.queued), icon: Icons.schedule),
                MediaStatTile(
                  label: 'Awaiting pickup',
                  value: formatCount(s.queue.awaitingPickup),
                  icon: Icons.inventory_2_outlined,
                ),
              ],
            ),
          ),
          MediaSection(
            title: 'Requests',
            child: MediaStatGrid(
              minTileWidth: 100,
              children: [
                MediaStatTile(label: 'Pending', value: formatCount(s.requests.pending)),
                MediaStatTile(label: 'Delivered', value: formatCount(s.requests.delivered), tone: StatusTone.ok),
                MediaStatTile(
                  label: 'Failed',
                  value: formatCount(s.requests.failed),
                  tone: s.requests.failed > 0 ? StatusTone.error : null,
                ),
                MediaStatTile(label: 'Cancelled', value: formatCount(s.requests.cancelled)),
                MediaStatTile(label: 'Rejected', value: formatCount(s.requests.rejected)),
              ],
            ),
          ),
          MediaSection(
            title: 'Added',
            child: _AddedTable(added: s.added),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                Icon(
                  s.failed7d > 0 ? Icons.error_outline : Icons.check_circle_outline,
                  size: 18,
                  color: StatusColors.of(context).forTone(s.failed7d > 0 ? StatusTone.error : StatusTone.ok),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    s.failed7d == 0
                        ? 'No failed downloads in the last 7 days'
                        : '${s.failed7d} failed ${s.failed7d == 1 ? 'download' : 'downloads'} in the last 7 days',
                  ),
                ),
              ],
            ),
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: _OpenButton(link: s.web),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Downloads land in Audiobookshelf and Kavita once imported. Searching and requesting books from the hub '
            'is coming in a later version.',
            style: muted,
          ),
        ),
      ],
    );
  }
}

class _AddedTable extends StatelessWidget {
  const _AddedTable({required this.added});

  final ShelfmarkAdded added;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final head = theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    TableRow row(String label, int d7, int d30, {bool bold = false}) {
      final style = bold ? theme.textTheme.titleSmall : theme.textTheme.bodyMedium;
      return TableRow(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(label, style: style),
          ),
          Text(formatCount(d7), style: style, textAlign: TextAlign.end),
          Text(formatCount(d30), style: style, textAlign: TextAlign.end),
        ],
      );
    }

    return Table(
      columnWidths: const {0: FlexColumnWidth(2), 1: FlexColumnWidth(), 2: FlexColumnWidth()},
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(
          children: [
            Text('', style: head),
            Text('7 days', style: head, textAlign: TextAlign.end),
            Text('30 days', style: head, textAlign: TextAlign.end),
          ],
        ),
        row('Ebooks', added.ebook7d, added.ebook30d),
        row('Audiobooks', added.audiobook7d, added.audiobook30d),
        row('Total', added.total7d, added.total30d, bold: true),
      ],
    );
  }
}
