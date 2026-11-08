/// Header of the Subtitles screen (APP.md §11): missing counts, SignalR
/// chips, providers and health issues from `GET /subtitles/summary`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../providers/subtitles_providers.dart';

/// Scrolls with the list it heads; the data comes from the shared summary
/// provider so every tab shows the same header without a second request.
class SubtitlesHeader extends ConsumerWidget {
  const SubtitlesHeader({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(subtitlesSummaryProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // A failed refresh keeps the last summary (APP.md §2.1).
            if (summary.hasValue && summary.hasError)
              StaleBanner(onRetry: () => ref.invalidate(subtitlesSummaryProvider)),
            Padding(
              padding: const EdgeInsets.all(12),
              child: switch (summary) {
                AsyncValue(:final value?) => SubtitlesSummaryView(summary: value),
                AsyncValue(:final error?) => ErrorView(
                  error: error,
                  compact: true,
                  onRetry: () => ref.invalidate(subtitlesSummaryProvider),
                ),
                _ => const _HeaderSkeleton(),
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// The summary contents (also used by tests).
class SubtitlesSummaryView extends StatelessWidget {
  const SubtitlesSummaryView({super.key, required this.summary});

  final SubtitlesSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final s = summary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: formatCount(s.missingEpisodes), style: theme.textTheme.titleMedium),
                    TextSpan(text: s.missingEpisodes == 1 ? ' episode' : ' episodes', style: muted),
                    TextSpan(text: '  ·  ', style: muted),
                    TextSpan(text: formatCount(s.missingMovies), style: theme.textTheme.titleMedium),
                    TextSpan(text: s.missingMovies == 1 ? ' movie missing' : ' movies missing', style: muted),
                  ],
                ),
              ),
            ),
            if (s.version != null) Text('Bazarr ${s.version}', style: muted),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [_signalrChip('Sonarr', s.signalr.sonarr), _signalrChip('Radarr', s.signalr.radarr)],
        ),
        if (s.signalr.anyDown)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Bazarr misses new imports until its next hourly sync.', style: muted),
          ),
        if (s.providers.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            s.throttledProviders == 0 ? 'Providers' : 'Providers · ${s.throttledProviders} throttled',
            style: theme.textTheme.labelLarge,
          ),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [for (final p in s.providers) _ProviderChip(provider: p)]),
          // Why a provider is throttled and when Bazarr retries it.
          for (final p in s.providers.where((p) => !p.ok))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                [p.name, if (p.status.isNotEmpty) p.status, if (p.retry != null) 'retry ${p.retry}'].join(' · '),
                style: muted,
              ),
            ),
        ],
        for (final h in s.health)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded, size: 18, color: colors.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        if (h.object.isNotEmpty)
                          TextSpan(
                            text: '${h.object}: ',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        TextSpan(text: h.issue),
                      ],
                    ),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static Widget _signalrChip(String app, SubtitleSignalrState state) {
    final live = state == SubtitleSignalrState.live;
    return StatusChip(
      label: '$app ${live ? 'live' : 'down'}',
      tone: live ? StatusTone.ok : StatusTone.warning,
      icon: live ? Icons.bolt : Icons.link_off,
      dense: true,
    );
  }
}

class _ProviderChip extends StatelessWidget {
  const _ProviderChip({required this.provider});

  final SubtitleProvider provider;

  @override
  Widget build(BuildContext context) {
    final p = provider;
    return StatusChip(
      label: p.name,
      tone: p.ok ? StatusTone.ok : StatusTone.warning,
      icon: p.ok ? Icons.check : Icons.hourglass_bottom,
      dense: true,
    );
  }
}

class _HeaderSkeleton extends StatelessWidget {
  const _HeaderSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SkeletonBox(width: 220, height: 18),
        SizedBox(height: 12),
        Row(children: [SkeletonBox(width: 90, height: 20), SizedBox(width: 6), SkeletonBox(width: 90, height: 20)]),
        SizedBox(height: 12),
        SkeletonBox(width: 260, height: 20),
      ],
    );
  }
}

/// The admin "Tasks" sheet: Bazarr's scheduled tasks with interval, next run,
/// a spinner while running and "Run now".
class SubtitleTasksSheet extends ConsumerStatefulWidget {
  const SubtitleTasksSheet({super.key, required this.onRun});

  /// Runs a task (`POST /subtitles/tasks/{id}/run`).
  final Future<void> Function(SubtitleTask task) onRun;

  static Future<void> show(BuildContext context, {required Future<void> Function(SubtitleTask task) onRun}) =>
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (_) => SubtitleTasksSheet(onRun: onRun),
      );

  @override
  ConsumerState<SubtitleTasksSheet> createState() => _SubtitleTasksSheetState();
}

class _SubtitleTasksSheetState extends ConsumerState<SubtitleTasksSheet> {
  final Set<String> _starting = {};
  final Set<String> _started = {};

  Future<void> _run(SubtitleTask task) async {
    setState(() => _starting.add(task.id));
    try {
      await widget.onRun(task);
      if (mounted) setState(() => _started.add(task.id));
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _starting.remove(task.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary = ref.watch(subtitlesSummaryProvider);
    final tasks = summary.value?.tasks;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text('Bazarr tasks', style: theme.textTheme.titleMedium),
          ),
          Flexible(
            child: switch (tasks) {
              null when summary.hasError => ErrorView(
                error: summary.error!,
                compact: true,
                onRetry: () => ref.invalidate(subtitlesSummaryProvider),
              ),
              null => const SkeletonList(count: 4),
              [] => const EmptyView(icon: Icons.schedule, title: 'No scheduled tasks'),
              final list => ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 16),
                children: [
                  for (final t in list)
                    ListTile(
                      key: ValueKey('subtitle-task-${t.id}'),
                      title: Text(t.name),
                      subtitle: Text(
                        [
                          if (t.interval.isNotEmpty) t.interval,
                          if (t.running) 'running now' else if (t.nextRun.isNotEmpty) 'next ${t.nextRun}',
                        ].join(' · '),
                      ),
                      trailing: t.running || _starting.contains(t.id)
                          ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : _started.contains(t.id)
                          ? const Tooltip(message: 'Started', child: Icon(Icons.check))
                          : TextButton(onPressed: () => _run(t), child: const Text('Run now')),
                    ),
                ],
              ),
            },
          ),
        ],
      ),
    );
  }
}
