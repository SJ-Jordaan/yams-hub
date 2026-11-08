/// Media providers (ARCHITECTURE §7.2), refreshed per APP.md §8 / §14.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/refresh/auto_refresh.dart';
import 'package:yams_hub/core/settings/app_settings.dart';
import 'package:yams_models/yams_models.dart';

import '../data/media_api.dart';

/// `GET /media/now-playing`, every 5 s.
final nowPlayingProvider = FutureProvider.autoDispose<NowPlaying>((ref) {
  autoRefresh(ref, RefreshIntervals.nowPlaying);
  return ref.watch(mediaApiProvider).nowPlaying();
});

/// `GET /media/jellyfin`, every 60 s.
final jellyfinOverviewProvider = FutureProvider.autoDispose<JellyfinOverview>((ref) {
  autoRefresh(ref, RefreshIntervals.sixtySeconds);
  return ref.watch(mediaApiProvider).jellyfin();
});

/// The selected Stats period (7 / 30 / 90 / 365 days).
final statsDaysProvider = NotifierProvider<StatsDaysController, int>(StatsDaysController.new);

class StatsDaysController extends Notifier<int> {
  @override
  int build() => 30;

  void select(int days) {
    if (WatchStats.periods.contains(days)) state = days;
  }
}

/// `GET /media/stats?days=`, every 5 min.
final watchStatsProvider = FutureProvider.autoDispose.family<WatchStats, int>((ref, days) {
  autoRefresh(ref, RefreshIntervals.stats);
  return ref.watch(mediaApiProvider).stats(days);
});

/// `GET /media/stats/users`, every 5 min.
final watchUsersProvider = FutureProvider.autoDispose<List<WatchUser>>((ref) {
  autoRefresh(ref, RefreshIntervals.stats);
  return ref.watch(mediaApiProvider).statsUsers();
});

/// `GET /media/audiobooks`, every 60 s.
final audiobooksProvider = FutureProvider.autoDispose<AudiobooksOverview>((ref) {
  autoRefresh(ref, RefreshIntervals.sixtySeconds);
  return ref.watch(mediaApiProvider).audiobooks();
});

/// `GET /media/books`, every 60 s.
final booksProvider = FutureProvider.autoDispose<BooksOverview>((ref) {
  autoRefresh(ref, RefreshIntervals.sixtySeconds);
  return ref.watch(mediaApiProvider).books();
});

/// `GET /media/shelfmark`, every 30 s.
final shelfmarkProvider = FutureProvider.autoDispose<ShelfmarkStatus>((ref) {
  autoRefresh(ref, RefreshIntervals.thirtySeconds);
  return ref.watch(mediaApiProvider).shelfmark();
});

/// `GET /media/apps`, every 60 s.
final mediaAppsProvider = FutureProvider.autoDispose<List<MediaApp>>((ref) {
  autoRefresh(ref, RefreshIntervals.sixtySeconds);
  return ref.watch(mediaApiProvider).apps();
});

/// The per-device "authors and narrators look swapped" hint on the
/// Audiobookshelf screen (dismissible, APP.md §8.3).
final absNamingHintDismissedProvider = NotifierProvider<AbsNamingHintController, bool>(AbsNamingHintController.new);

class AbsNamingHintController extends Notifier<bool> {
  static const storageKey = 'media.absNamingHintDismissed';

  @override
  bool build() => ref.watch(sharedPreferencesProvider).getBool(storageKey) ?? false;

  Future<void> dismiss() async {
    state = true;
    await ref.read(sharedPreferencesProvider).setBool(storageKey, true);
  }
}

/// Session actions [admin]: they refresh now playing on completion. Errors
/// propagate as `ApiException` (the caller shows the SnackBar).
final sessionActionsProvider = Provider<SessionActions>((ref) => SessionActions(ref));

class SessionActions {
  SessionActions(this._ref);

  final Ref _ref;

  Future<void> playback(String sessionId, MediaPlaybackCommand command) async {
    try {
      await _ref.read(mediaApiProvider).playback(sessionId, command);
    } finally {
      _ref.invalidate(nowPlayingProvider);
    }
  }

  Future<void> message(String sessionId, MediaSessionMessage message) =>
      _ref.read(mediaApiProvider).message(sessionId, message);
}
