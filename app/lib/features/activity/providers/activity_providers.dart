/// Riverpod providers of the Activity screens (APP.md §6, §14 intervals).
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/refresh/auto_refresh.dart';
import 'package:yams_models/yams_models.dart';

import '../data/activity_api.dart';

/// `GET /transfer` every 2 s while visible (the header transfer bar).
final transferProvider = FutureProvider.autoDispose<TransferState>((ref) async {
  autoRefresh(ref, RefreshIntervals.torrents);
  return ref.watch(activityApiProvider).transfer();
});

/// `GET /vpn` every 30 s.
final vpnProvider = FutureProvider.autoDispose<VpnStatus>((ref) async {
  autoRefresh(ref, RefreshIntervals.thirtySeconds);
  return ref.watch(activityApiProvider).vpn();
});

/// `GET /activity/queue?filter=` every 3 s.
final queueProvider = FutureProvider.autoDispose.family<QueueResponse, String>((ref, filter) async {
  autoRefresh(ref, RefreshIntervals.queue);
  return ref.watch(activityApiProvider).queue(filter: filter);
});

/// `GET /torrents` every 2 s.
final torrentsProvider = FutureProvider.autoDispose.family<TorrentList, TorrentQuery>((ref, query) async {
  autoRefresh(ref, RefreshIntervals.torrents);
  return ref.watch(activityApiProvider).torrents(query);
});

/// `GET /torrents/{hash}` every 2 s.
final torrentDetailProvider = FutureProvider.autoDispose.family<TorrentDetail, String>((ref, hash) async {
  autoRefresh(ref, RefreshIntervals.torrents);
  return ref.watch(activityApiProvider).torrent(hash);
});

/// `GET /transfer/categories` (no timer; the gateway caches 60 s).
final torrentCategoriesProvider = FutureProvider.autoDispose<CategoryList>(
  (ref) => ref.watch(activityApiProvider).categories(),
);

/// Manual-import candidates of one queue record (no cache, no timer).
final importCandidatesProvider = FutureProvider.autoDispose.family<ManualImportCandidates, (ArrService, int)>(
  (ref, key) => ref.watch(activityApiProvider).importCandidates(key.$1, key.$2),
);

/// Episodes of a series for the "Edit match" picker.
final seriesEpisodesProvider = FutureProvider.autoDispose.family<List<ActivitySeriesEpisode>, int>(
  (ref, seriesId) => ref.watch(activityApiProvider).seriesEpisodes(seriesId),
);

/// Poll interval of `GET /library/commands/{service}/{id}` (APP.md §2.3).
const commandPollInterval = Duration(seconds: 2);

/// Polls a Sonarr/Radarr command every 2 s until it is no longer active.
final commandProvider = FutureProvider.autoDispose.family<CommandRef, (ServiceId, int)>((ref, key) async {
  final command = await ref.watch(activityApiProvider).command(key.$1, key.$2);
  if (command.status.isActive) {
    final timer = Timer(commandPollInterval, () {
      if (ref.mounted) ref.invalidateSelf();
    });
    ref.onDispose(timer.cancel);
  }
  return command;
});

/// Invalidates every list the activity writes can change.
void invalidateActivity(WidgetRef ref, {String? hash}) {
  ref
    ..invalidate(queueProvider)
    ..invalidate(torrentsProvider)
    ..invalidate(transferProvider);
  if (hash != null) ref.invalidate(torrentDetailProvider(hash));
}
