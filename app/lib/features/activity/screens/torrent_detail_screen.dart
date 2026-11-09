/// Torrent detail `/activity/torrent/:hash` (APP.md §6.2), interval 2 s.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/api/api_exception.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/activity_api.dart';
import '../providers/activity_providers.dart';
import '../widgets/activity_actions.dart';
import '../widgets/activity_format.dart';
import '../widgets/share_limits_sheet.dart';

class TorrentDetailScreen extends ConsumerWidget {
  const TorrentDetailScreen({super.key, required this.hash});

  final String hash;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(torrentDetailProvider(hash));
    final name = value.value?.summary.name;
    final gone = value.hasError && ApiException.from(value.error!).code == ApiErrorCode.notFound;
    return Scaffold(
      appBar: AppBar(title: Text(name ?? 'Torrent', maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: gone
          ? EmptyView(
              icon: Icons.delete_sweep_outlined,
              title: 'Torrent no longer exists',
              message: 'decluttarr or Sonarr/Radarr may have removed it.',
              action: FilledButton.tonal(
                onPressed: () => context.canPop() ? context.pop() : context.go(AppPaths.activity(tab: 'torrents')),
                child: const Text('Back'),
              ),
            )
          : AsyncValueView<TorrentDetail>(
              value: value,
              onRetry: () => ref.invalidate(torrentDetailProvider(hash)),
              data: (context, d) => RefreshIndicator(
                onRefresh: () => ref.refresh(torrentDetailProvider(hash).future),
                child: _DetailBody(detail: d),
              ),
            ),
    );
  }
}

class _DetailBody extends ConsumerWidget {
  const _DetailBody({required this.detail});

  final TorrentDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = detail;
    final t = d.summary;
    final theme = Theme.of(context);
    final admin = ref.watch(isAdminProvider);
    final tone = torrentStateTone(t.state);
    final big = theme.textTheme.titleMedium;
    return ListView(
      key: const ValueKey('torrentDetailList'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(t.name, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  StatusChip(label: torrentStateLabel(t.state), tone: tone, icon: torrentStateIcon(t.state)),
                  if (t.forceStart) const StatusChip(label: 'Forced', tone: StatusTone.info),
                  if (t.protected) const StatusChip(label: 'Keep', icon: Icons.shield, tone: StatusTone.info),
                  // Only when no tracker works (issue #1); d.trackers shows the failing ones.
                  if (d.hasTrackerError)
                    const StatusChip(
                      key: ValueKey('torrentTrackerError'),
                      label: 'Tracker error',
                      tone: StatusTone.error,
                    ),
                ],
              ),
              const SizedBox(height: 12),
              ProgressBar(
                value: t.progress,
                tone: tone,
                height: 10,
                label: formatPercent(t.progress * 100, decimals: 1),
                trailing: t.direction == TorrentDirection.download ? 'ETA ${formatEta(t.etaSeconds)}' : null,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 20,
                runSpacing: 8,
                children: [
                  SpeedText(bps: t.dlBps, direction: SpeedDirection.down, style: big),
                  SpeedText(bps: t.upBps, direction: SpeedDirection.up, style: big),
                  Text('Ratio ${ratioText(t.ratio)}', style: big),
                ],
              ),
            ],
          ),
        ),
        if (admin) ...[const SizedBox(height: 12), _Actions(torrent: t)],
        if (d.arr.isNotEmpty) ...[const SizedBox(height: 12), _ArrCard(entries: d.arr)],
        const SizedBox(height: 12),
        SectionCard(
          title: 'General',
          child: KeyValueList(
            entries: [
              KeyValue('Size', formatBytes(t.sizeBytes)),
              KeyValue('Downloaded', formatBytes(t.downloadedBytes)),
              KeyValue('Uploaded', formatBytes(t.uploadedBytes)),
              KeyValue('Seeds', '${t.seeds} connected · ${d.seedsTotal} in swarm'),
              KeyValue('Peers', '${t.peers} connected · ${d.peersTotal} in swarm'),
              KeyValue('Added', formatDateTime(t.addedAt)),
              KeyValue('Completed', t.completedAt == null ? null : formatDateTime(t.completedAt)),
              KeyValue('Save path', d.savePath),
              KeyValue('Pieces', '${d.piecesHave} / ${d.piecesTotal} × ${formatBytes(d.pieceSizeBytes)}'),
              KeyValue('Time active', formatSeconds(d.timeActiveSeconds)),
              KeyValue('Seeding time', formatSeconds(d.seedingTimeSeconds)),
              KeyValue('Average speed', '↓ ${formatBps(d.avgDlBps)} · ↑ ${formatBps(d.avgUpBps)}'),
              KeyValue('Category', t.category ?? 'None'),
              KeyValue('Tags', t.tags.join(', ')),
              KeyValue('Private', d.isPrivate ? 'Yes' : null),
              KeyValue('Comment', d.comment),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _ShareLimitsCard(detail: d, editable: admin),
        if (d.files.isNotEmpty) ...[const SizedBox(height: 12), _FilesCard(detail: d, editable: admin)],
        if (d.trackers.isNotEmpty) ...[const SizedBox(height: 12), _TrackersCard(detail: d)],
      ],
    );
  }
}

class _Actions extends ConsumerWidget {
  const _Actions({required this.torrent});

  final TorrentSummary torrent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = torrent;
    final stopped = t.state == TorrentState.stopped;
    Widget button(IconData icon, String label, VoidCallback onPressed, {Key? key}) =>
        OutlinedButton.icon(key: key, onPressed: onPressed, icon: Icon(icon, size: 18), label: Text(label));
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (stopped)
          button(
            Icons.play_arrow,
            'Start',
            () => torrentAction(context, ref, [t.hash], TorrentAction.start, done: 'Started'),
            key: const ValueKey('torrentStart'),
          )
        else
          button(
            Icons.pause,
            'Stop',
            () => torrentAction(context, ref, [t.hash], TorrentAction.stop, done: 'Stopped'),
            key: const ValueKey('torrentStop'),
          ),
        if (!t.forceStart)
          button(
            Icons.fast_forward,
            'Force start',
            () => torrentAction(context, ref, [t.hash], TorrentAction.forceStart, done: 'Force started'),
          ),
        button(
          Icons.fact_check_outlined,
          'Recheck',
          () => torrentAction(context, ref, [t.hash], TorrentAction.recheck, done: 'Recheck started'),
        ),
        button(
          Icons.campaign_outlined,
          'Reannounce',
          () => torrentAction(context, ref, [t.hash], TorrentAction.reannounce, done: 'Reannounced'),
        ),
        button(
          t.protected ? Icons.shield : Icons.shield_outlined,
          t.protected ? 'Unprotect' : 'Protect',
          () => toggleProtect(context, ref, t),
        ),
        button(Icons.label_outline, 'Category', () => chooseCategory(context, ref, [t.hash], current: t.category)),
        OutlinedButton.icon(
          key: const ValueKey('torrentDelete'),
          style: OutlinedButton.styleFrom(foregroundColor: StatusColors.of(context).error),
          onPressed: () async {
            final router = GoRouter.of(context);
            if (await deleteTorrents(context, ref, [t])) {
              if (router.canPop()) router.pop();
            }
          },
          icon: const Icon(Icons.delete_outline, size: 18),
          label: const Text('Delete'),
        ),
      ],
    );
  }
}

class _ArrCard extends StatelessWidget {
  const _ArrCard({required this.entries});

  final List<QueueArrEntry> entries;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Tracked by ${entries.map((e) => arrLabel(e.service)).toSet().join(' and ')}',
      icon: Icons.link,
      child: Column(
        children: [
          for (final e in entries)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(e.mediaTitle ?? 'Unknown'),
              subtitle: Text(
                [?e.episodesLabel, '${e.trackedState.name} · ${e.queueIds.length} queue records'].join(' · '),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: switch ((e.seriesId, e.movieId)) {
                (final id?, _) => () => context.go(AppPaths.seriesDetail(id)),
                (_, final id?) => () => context.go(AppPaths.movieDetail(id)),
                _ => null,
              },
            ),
        ],
      ),
    );
  }
}

class _ShareLimitsCard extends StatelessWidget {
  const _ShareLimitsCard({required this.detail, required this.editable});

  final TorrentDetail detail;
  final bool editable;

  @override
  Widget build(BuildContext context) {
    final s = detail.shareLimits;
    String limit(num v, String Function(num) f) => v < 0 ? 'None' : f(v);
    return SectionCard(
      title: 'Share limits',
      trailing: editable
          ? TextButton(
              key: const ValueKey('editShareLimits'),
              onPressed: () => showShareLimitsSheet(context, detail),
              child: const Text('Edit'),
            )
          : null,
      child: KeyValueList(
        entries: [
          KeyValue('Mode', switch (s.mode) {
            ShareLimitsMode.global => 'Use global limits',
            ShareLimitsMode.unlimited => 'Unlimited',
            ShareLimitsMode.custom => 'Custom',
            ShareLimitsMode.unknown => 'Unknown',
          }),
          KeyValue('Ratio limit', limit(s.effectiveRatio, (v) => v.toStringAsFixed(2))),
          KeyValue(
            'Seeding limit',
            limit(s.effectiveSeedingMinutes, (v) => formatDuration(Duration(minutes: v.toInt()))),
          ),
          if (s.inactiveMinutes != null)
            KeyValue('Inactive limit', formatDuration(Duration(minutes: s.inactiveMinutes!))),
          KeyValue('When reached', shareActionLabel(s.action)),
        ],
      ),
    );
  }
}

class _FilesCard extends ConsumerWidget {
  const _FilesCard({required this.detail, required this.editable});

  final TorrentDetail detail;
  final bool editable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final hash = detail.summary.hash;
    return SectionCard(
      title: 'Files (${detail.files.length})',
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Column(
        children: [
          for (final f in detail.files)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              title: _FilePath(name: f.name),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ProgressBar(value: f.progress, height: 4),
                    const SizedBox(height: 2),
                    Text(
                      '${formatPercent(f.progress * 100)} of ${formatBytes(f.sizeBytes)}',
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              trailing: editable
                  ? DropdownButton<TorrentFilePriority>(
                      value: f.priority == TorrentFilePriority.unknown ? TorrentFilePriority.normal : f.priority,
                      underline: const SizedBox.shrink(),
                      style: theme.textTheme.bodySmall,
                      items: [
                        for (final p in const [
                          TorrentFilePriority.skip,
                          TorrentFilePriority.normal,
                          TorrentFilePriority.high,
                          TorrentFilePriority.max,
                        ])
                          DropdownMenuItem(value: p, child: Text(filePriorityLabel(p))),
                      ],
                      onChanged: (p) {
                        if (p == null || p == f.priority) return;
                        runActivityAction(
                          context,
                          ref,
                          () => ref.read(activityApiProvider).setFilePriority(hash, [f.index], p),
                          done: 'Priority set to ${filePriorityLabel(p)}',
                          hash: hash,
                        );
                      },
                    )
                  : Text(filePriorityLabel(f.priority), style: theme.textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}

/// A relative path with its folders de-emphasised.
class _FilePath extends StatelessWidget {
  const _FilePath({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final i = name.lastIndexOf('/');
    if (i < 0) return Text(name, maxLines: 2, overflow: TextOverflow.ellipsis);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: name.substring(0, i + 1),
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
          TextSpan(text: name.substring(i + 1)),
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _TrackersCard extends StatelessWidget {
  const _TrackersCard({required this.detail});

  final TorrentDetail detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trackers = detail.trackers;
    final failing = detail.failingTrackers;
    return SectionCard(
      title: 'Trackers',
      // Some failing while others work is not an error: a quiet count only.
      trailing: failing == 0
          ? null
          : Text(
              '$failing of ${trackers.length} failing',
              key: const ValueKey('trackersFailing'),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Column(
        children: [
          for (final t in trackers)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              title: Text(t.url),
              subtitle: Text(
                [
                  if (t.seeds != null) '${t.seeds} seeds',
                  if (t.peers != null) '${t.peers} peers',
                  ?t.message,
                ].join(' · '),
              ),
              trailing: StatusChip(label: trackerStatusLabel(t.status), tone: trackerStatusTone(t.status), dense: true),
            ),
        ],
      ),
    );
  }
}
