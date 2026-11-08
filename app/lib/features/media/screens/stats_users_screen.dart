/// `/media/stats/users`: watch statistics per Jellyfin user and their
/// playback history (APP.md §8.2), every 5 min.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/media_api.dart';
import '../providers/media_providers.dart';
import '../widgets/media_common.dart';

String _norm(String? id) => (id ?? '').toLowerCase().replaceAll('-', '');

class StatsUsersScreen extends ConsumerWidget {
  const StatsUsersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(watchUsersProvider);
    final auth = ref.watch(authControllerProvider);
    final myJellyfinId = _norm(auth.user?.jellyfinUserId);
    // Members only ever see their own history (the gateway scopes it).
    bool canOpen(WatchUser u) => auth.isAdmin || (myJellyfinId.isNotEmpty && _norm(u.userId) == myJellyfinId);
    return Scaffold(
      appBar: AppBar(title: const Text('Watch stats by user')),
      body: AsyncValueView<List<WatchUser>>(
        value: value,
        onRetry: () => ref.invalidate(watchUsersProvider),
        data: (context, users) {
          if (users.isEmpty) {
            return MediaRefreshList(
              onRefresh: () => ref.refresh(watchUsersProvider.future),
              children: const [
                SizedBox(
                  height: 360,
                  child: EmptyView(
                    icon: Icons.people_outline,
                    title: 'No users yet',
                    message: 'Jellystat lists users once it has synced with Jellyfin.',
                  ),
                ),
              ],
            );
          }
          return RefreshIndicator(
            onRefresh: () => ref.refresh(watchUsersProvider.future),
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: users.length,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
              itemBuilder: (context, i) {
                final u = users[i];
                final open = canOpen(u);
                return _UserTile(user: u, onTap: open ? () => showPlaybackHistory(context, u) : null);
              },
            ),
          );
        },
      ),
    );
  }
}

class _UserTile extends StatelessWidget {
  const _UserTile({required this.user, this.onTap});

  final WatchUser user;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final u = user;
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.secondaryContainer,
        child: ClipOval(
          child: u.avatarPath == null
              ? Text(u.name.isEmpty ? '?' : u.name.characters.first.toUpperCase())
              : HubImage(u.avatarPath, width: 40, height: 40, placeholderIcon: Icons.person),
        ),
      ),
      title: Text(u.name.isEmpty ? 'Unknown user' : u.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              '${formatCount(u.totalPlays)} ${u.totalPlays == 1 ? 'play' : 'plays'}',
              formatWatchTime(u.totalWatchSeconds),
              if (u.lastSeenAt != null) 'seen ${formatRelative(u.lastSeenAt)}' else 'never watched',
            ].join(' · '),
          ),
          if (u.lastWatched != null) Text(u.lastWatched!, maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
        ],
      ),
      isThreeLine: u.lastWatched != null,
      trailing: onTap == null ? null : const Icon(Icons.chevron_right),
    );
  }
}

/// A full-height sheet with [user]'s playback history.
Future<void> showPlaybackHistory(BuildContext context, WatchUser user) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.85,
    minChildSize: 0.4,
    builder: (context, controller) => PlaybackHistoryList(user: user, controller: controller),
  ),
);

/// [user]'s plays, newest first, loading more on scroll.
class PlaybackHistoryList extends ConsumerWidget {
  const PlaybackHistoryList({super.key, required this.user, this.controller});

  final WatchUser user;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final api = ref.watch(mediaApiProvider);
    return InfiniteList.paged<PlaybackRecord>(
      controller: controller,
      fetchPage: (page) => api.history(page: page, pageSize: 25, userId: user.userId),
      header: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text('${user.name} · history', style: theme.textTheme.titleMedium),
      ),
      empty: const SizedBox(
        height: 260,
        child: EmptyView(icon: Icons.history, title: 'No plays yet', message: 'Plays appear here once they finish.'),
      ),
      itemBuilder: (context, r, _) => ListTile(
        leading: HubImage(
          r.imagePath,
          width: 72,
          height: 40,
          borderRadius: BorderRadius.circular(6),
          placeholderIcon: Icons.movie_outlined,
        ),
        title: Text(
          r.seriesName == null ? r.title : '${r.seriesName} · ${r.title}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          [
            formatWatchTime(r.durationSeconds),
            playMethodLabel(r.playMethod),
            [r.client, r.device].where((s) => s.isNotEmpty).join(' – '),
          ].where((s) => s.isNotEmpty).join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Tooltip(
          message: formatDateTime(r.at),
          child: Text(formatRelative(r.at), style: theme.textTheme.labelSmall),
        ),
      ),
    );
  }
}
