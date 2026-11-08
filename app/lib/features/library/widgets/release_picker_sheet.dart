/// "Choose release": interactive search through Sonarr/Radarr (APP.md §5.2,
/// API.md §7.8).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_exception.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/library_api.dart';

/// How the release list is ordered (rejected releases always last).
enum ReleaseSort {
  score('Score'),
  size('Size'),
  age('Age'),
  seeders('Seeders');

  const ReleaseSort(this.label);
  final String label;
}

/// Sorts [items]: the *arr order (approved first) for [ReleaseSort.score],
/// else by the field; rejected releases go last in every order.
List<ReleaseChoice> sortReleases(List<ReleaseChoice> items, ReleaseSort sort) {
  int field(ReleaseChoice a, ReleaseChoice b) => switch (sort) {
    ReleaseSort.score => 0,
    ReleaseSort.size => b.sizeBytes.compareTo(a.sizeBytes),
    ReleaseSort.age => (a.ageHours ?? 1 << 30).compareTo(b.ageHours ?? 1 << 30),
    ReleaseSort.seeders => (b.seeders ?? -1).compareTo(a.seeders ?? -1),
  };
  final indexed = [for (var i = 0; i < items.length; i++) (i, items[i])];
  indexed.sort((x, y) {
    final r = (x.$2.rejected ? 1 : 0).compareTo(y.$2.rejected ? 1 : 0);
    if (r != 0) return r;
    final f = field(x.$2, y.$2);
    return f != 0 ? f : x.$1.compareTo(y.$1);
  });
  return [for (final e in indexed) e.$2];
}

/// "3 h", "2 d", "5 mo".
String releaseAge(int? hours) {
  if (hours == null) return '–';
  if (hours < 48) return '$hours h';
  final days = hours ~/ 24;
  if (days < 60) return '$days d';
  return '${days ~/ 30} mo';
}

/// The release picker as a modal bottom sheet.
class ReleasePickerSheet extends ConsumerStatefulWidget {
  const ReleasePickerSheet({super.key, required this.title, required this.service, required this.search});

  /// "S03E01 · The Lightspeed Hero", "Season 3", the movie title.
  final String title;
  final ArrService service;

  /// Runs the (long) search; called again by "Search again".
  final Future<ReleaseChoiceList> Function(LibraryApi api) search;

  /// Opens the sheet. Returns true when a release was grabbed.
  static Future<bool> show(
    BuildContext context, {
    required String title,
    required ArrService service,
    required Future<ReleaseChoiceList> Function(LibraryApi api) search,
  }) async {
    final grabbed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => ReleasePickerSheet(title: title, service: service, search: search),
    );
    return grabbed ?? false;
  }

  @override
  ConsumerState<ReleasePickerSheet> createState() => _ReleasePickerSheetState();
}

class _ReleasePickerSheetState extends ConsumerState<ReleasePickerSheet> {
  Future<ReleaseChoiceList>? _future;
  Timer? _ticker;
  int _elapsed = 0;
  ReleaseSort _sort = ReleaseSort.score;
  String? _grabbing;
  String? _expanded;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _start() {
    // "Search again" lives on a SnackBar that can outlive the sheet.
    if (!mounted) return;
    _ticker?.cancel();
    _elapsed = 0;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed++);
    });
    final future = widget.search(ref.read(libraryApiProvider));
    future.whenComplete(() => _ticker?.cancel()).ignore();
    setState(() {
      _future = future;
    });
  }

  Future<void> _grab(ReleaseChoice r) async {
    if (r.rejected || r.temporarilyRejected) {
      final ok = await ConfirmDialog.show(
        context,
        title: 'Grab anyway?',
        message: '${widget.service.serviceId.displayName} would not grab this release automatically:',
        confirmLabel: 'Grab anyway',
        destructive: true,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [for (final reason in r.rejections) Text('• $reason')],
        ),
      );
      if (!ok || !mounted) return;
    }
    setState(() => _grabbing = r.releaseId);
    try {
      await ref.read(libraryApiProvider).grab(r.releaseId);
      if (!mounted) return;
      context.showSnack('Sent to qBittorrent via ${widget.service.serviceId.displayName}');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _grabbing = null);
      final error = ApiException.from(e);
      if (error.code == ApiErrorCode.notFound) {
        context.showSnack(
          'Results expired, search again',
          action: SnackBarAction(label: 'Search again', onPressed: _start),
        );
      } else {
        context.showError(e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, controller) => FutureBuilder<ReleaseChoiceList>(
        future: _future,
        builder: (context, snap) {
          final header = Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Choose release', style: theme.textTheme.titleMedium),
                      Text(
                        widget.title,
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (snap.hasData)
                  PopupMenuButton<ReleaseSort>(
                    tooltip: 'Sort',
                    icon: const Icon(Icons.sort),
                    initialValue: _sort,
                    onSelected: (s) => setState(() => _sort = s),
                    itemBuilder: (_) => [
                      for (final s in ReleaseSort.values) PopupMenuItem(value: s, child: Text('Sort by ${s.label}')),
                    ],
                  ),
              ],
            ),
          );
          if (snap.connectionState != ConnectionState.done) {
            return ListView(
              controller: controller,
              children: [
                header,
                const SizedBox(height: 48),
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 16),
                Center(child: Text('Searching indexers… ${_elapsed}s', style: theme.textTheme.titleSmall)),
                const SizedBox(height: 4),
                Center(
                  child: Text(
                    'Up to 2 min: every indexer is asked live',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            );
          }
          if (snap.hasError) {
            return ListView(
              controller: controller,
              children: [
                header,
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: ErrorView(error: snap.error!, onRetry: _start),
                ),
              ],
            );
          }
          final list = snap.data!;
          final items = sortReleases(list.items, _sort);
          if (items.isEmpty) {
            return ListView(
              controller: controller,
              children: [
                header,
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: EmptyView(
                    icon: Icons.search_off,
                    title: 'No releases found',
                    message: 'The indexers returned nothing for this search.',
                    action: OutlinedButton(onPressed: _start, child: const Text('Search again')),
                  ),
                ),
              ],
            );
          }
          final approved = items.where((r) => r.approved).length;
          return ListView.separated(
            controller: controller,
            itemCount: items.length + 1,
            separatorBuilder: (_, i) => i == 0 ? const SizedBox.shrink() : const Divider(height: 1),
            itemBuilder: (context, i) {
              if (i == 0) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    header,
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        '${items.length} releases · $approved approved · ${(list.tookMs / 1000).toStringAsFixed(1)} s',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                );
              }
              final r = items[i - 1];
              return ReleaseChoiceTile(
                release: r,
                expanded: _expanded == r.releaseId,
                grabbing: _grabbing == r.releaseId,
                enabled: _grabbing == null,
                onTap: () => setState(() => _expanded = _expanded == r.releaseId ? null : r.releaseId),
                onGrab: () => _grab(r),
              );
            },
          );
        },
      ),
    );
  }
}

/// One release: greyed with its reasons when rejected.
class ReleaseChoiceTile extends StatelessWidget {
  const ReleaseChoiceTile({
    super.key,
    required this.release,
    required this.onTap,
    required this.onGrab,
    this.expanded = false,
    this.grabbing = false,
    this.enabled = true,
  });

  final ReleaseChoice release;
  final VoidCallback onTap;
  final VoidCallback onGrab;
  final bool expanded;
  final bool grabbing;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final r = release;
    final dimmed = r.rejected;
    final scoreTone = r.customFormatScore > 0
        ? StatusTone.ok
        : (r.customFormatScore < 0 ? StatusTone.error : StatusTone.neutral);
    final meta = [
      formatBytes(r.sizeBytes),
      releaseAge(r.ageHours),
      if (r.protocol == LibraryReleaseProtocol.torrent) '${r.seeders ?? '?'}↑ ${r.leechers ?? '?'}↓',
      if (r.protocol == LibraryReleaseProtocol.usenet) 'Usenet',
      r.indexer,
    ].join(' · ');
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  r.title,
                  style: theme.textTheme.bodyMedium,
                  maxLines: expanded ? 4 : 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (r.rejected)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(Icons.block, size: 18, color: colors.error),
                )
              else if (r.temporarilyRejected)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(Icons.schedule, size: 18, color: colors.warning),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              StatusChip(label: r.quality.name, tone: StatusTone.info, dense: true),
              StatusChip(label: 'Score ${r.customFormatScore}', tone: scoreTone, dense: true),
              if (r.fullSeason) const StatusChip(label: 'Season pack', dense: true),
              for (final l in r.episodeLabels.take(3)) StatusChip(label: l, dense: true),
              for (final l in r.languages) StatusChip(label: l, dense: true),
            ],
          ),
          const SizedBox(height: 4),
          Text(meta, style: theme.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (r.rejections.isNotEmpty && !expanded)
            Text(
              r.rejections.first,
              style: theme.textTheme.bodySmall?.copyWith(color: r.rejected ? colors.error : colors.warning),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          if (expanded) ...[
            for (final reason in r.rejections)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '• $reason',
                  style: theme.textTheme.bodySmall?.copyWith(color: r.rejected ? colors.error : colors.warning),
                ),
              ),
            if (r.customFormats.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Formats: ${r.customFormats.join(', ')}', style: theme.textTheme.bodySmall),
              ),
            if (r.releaseGroup != null) Text('Group: ${r.releaseGroup}', style: theme.textTheme.bodySmall),
            if (r.publishDate != null)
              Text('Published ${formatDateTime(r.publishDate)}', style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: enabled ? onGrab : null,
                icon: grabbing
                    ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.download),
                label: Text(r.rejected ? 'Grab anyway' : 'Grab'),
              ),
            ),
          ],
        ],
      ),
    );
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Opacity(opacity: dimmed && !expanded ? 0.55 : 1, child: content),
    );
  }
}
