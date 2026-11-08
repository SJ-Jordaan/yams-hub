/// Media > Now playing (APP.md §8.1), refreshed every 5 s.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../providers/media_providers.dart';
import '../widgets/media_common.dart';
import '../widgets/session_card.dart';

class NowPlayingTab extends ConsumerWidget {
  const NowPlayingTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(nowPlayingProvider);
    Future<void> refresh() => ref.refresh(nowPlayingProvider.future);
    return AsyncValueView<NowPlaying>(
      value: value,
      onRetry: () => ref.invalidate(nowPlayingProvider),
      loading: const SkeletonList(count: 3, leadingSize: 72),
      data: (context, np) {
        if (np.sessions.isEmpty) return _NothingPlaying(onRefresh: refresh);
        final playing = np.sessions.length;
        return RefreshIndicator(
          onRefresh: refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 32),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                child: Text(
                  [
                    '$playing ${playing == 1 ? 'stream' : 'streams'}',
                    if (np.transcoding > 0) '${np.transcoding} transcoding',
                    if (np.hwAccel != null) 'HW: ${np.hwAccel!.toUpperCase()}',
                  ].join(' · '),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              for (final s in np.sessions) SessionCard(key: ValueKey(s.id), session: s, serverHwAccel: np.hwAccel),
            ],
          ),
        );
      },
    );
  }
}

/// Empty state with Jellyfin's continue-watching row below.
class _NothingPlaying extends ConsumerWidget {
  const _NothingPlaying({required this.onRefresh});

  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final continueWatching = ref.watch(jellyfinOverviewProvider).value?.continueWatching ?? const <MediaItem>[];
    return MediaRefreshList(
      onRefresh: () async {
        ref.invalidate(jellyfinOverviewProvider);
        await onRefresh();
      },
      children: [
        const SizedBox(
          height: 260,
          child: EmptyView(
            icon: Icons.tv_off_outlined,
            title: 'Nothing is playing right now',
            message: 'Streams from every Jellyfin app show up here.',
          ),
        ),
        if (continueWatching.isNotEmpty)
          MediaSection(
            title: 'Continue watching',
            padding: EdgeInsets.zero,
            child: MediaPosterRow(children: [for (final i in continueWatching) MediaItemPoster(item: i)]),
          ),
      ],
    );
  }
}
