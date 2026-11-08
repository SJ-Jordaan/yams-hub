/// Riverpod providers of the library feature (APP.md §5).
library;

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/refresh/auto_refresh.dart';
import 'package:yams_hub/core/settings/app_settings.dart';
import 'package:yams_hub/core/widgets/snack.dart';
import 'package:yams_models/yams_models.dart';

import '../data/library_api.dart';

// ---------------------------------------------------------------------------
// Lists and header
// ---------------------------------------------------------------------------

/// Whether [a] and [b] hold the same items in the same order, compared by
/// their JSON.
bool sameLibraryList<T>(List<T> a, List<T> b, JsonMap Function(T) toJson) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  const eq = DeepCollectionEquality();
  for (var i = 0; i < a.length; i++) {
    if (!identical(a[i], b[i]) && !eq.equals(toJson(a[i]), toJson(b[i]))) return false;
  }
  return true;
}

/// A whole library list refreshed every 60 s. A refresh that changes nothing
/// keeps the previous list instance, so the grids and the derived (filtered,
/// sorted) lists do not rebuild.
class LibraryListController<T> extends AsyncNotifier<List<T>> {
  LibraryListController(this._load, this._toJson);

  final Future<List<T>> Function(LibraryApi api) _load;
  final JsonMap Function(T) _toJson;

  @override
  Future<List<T>> build() async {
    autoRefresh(ref, RefreshIntervals.sixtySeconds);
    final next = await _load(ref.watch(libraryApiProvider));
    if (!ref.mounted) return next;
    final previous = state.value;
    return previous != null && sameLibraryList(previous, next, _toJson) ? previous : next;
  }
}

/// Every series (the list is complete, so filters run locally). 60 s.
final seriesListProvider = AsyncNotifierProvider.autoDispose<LibraryListController<SeriesSummary>, List<SeriesSummary>>(
  () => LibraryListController((api) => api.series(), (s) => s.toJson()),
);

/// Every movie. 60 s.
final moviesListProvider = AsyncNotifierProvider.autoDispose<LibraryListController<MovieSummary>, List<MovieSummary>>(
  () => LibraryListController((api) => api.movies(), (m) => m.toJson()),
);

/// The header strip (`GET /library/summary`). 30 s.
final librarySummaryProvider = FutureProvider.autoDispose<LibrarySummary>((ref) {
  autoRefresh(ref, RefreshIntervals.thirtySeconds);
  return ref.watch(libraryApiProvider).summary();
});

/// Quality profiles, root folders and add defaults (cached 10 min upstream).
final libraryProfilesProvider = FutureProvider.autoDispose<LibraryProfiles>(
  (ref) => ref.watch(libraryApiProvider).profiles(),
);

/// The first entries of an item's history for the detail screens.
final libraryHistoryPreviewProvider = FutureProvider.autoDispose.family<List<ArrHistoryItem>, (ArrService, int)>((
  ref,
  key,
) async {
  final page = await ref.watch(libraryApiProvider).history(key.$1, key.$2, pageSize: 5);
  return page.items;
});

// ---------------------------------------------------------------------------
// Grid / list toggle (remembered)
// ---------------------------------------------------------------------------

enum LibraryViewMode { grid, list }

const _viewModeKey = 'library.viewMode';

class LibraryViewModeController extends Notifier<LibraryViewMode> {
  @override
  LibraryViewMode build() {
    try {
      final stored = ref.watch(sharedPreferencesProvider).getString(_viewModeKey);
      return stored == LibraryViewMode.list.name ? LibraryViewMode.list : LibraryViewMode.grid;
    } catch (_) {
      return LibraryViewMode.grid;
    }
  }

  void set(LibraryViewMode mode) {
    state = mode;
    try {
      ref.read(sharedPreferencesProvider).setString(_viewModeKey, mode.name);
    } catch (_) {
      // Not persisted; the in-memory choice still applies.
    }
  }

  void toggle() => set(state == LibraryViewMode.grid ? LibraryViewMode.list : LibraryViewMode.grid);
}

final libraryViewModeProvider = NotifierProvider<LibraryViewModeController, LibraryViewMode>(
  LibraryViewModeController.new,
);

// ---------------------------------------------------------------------------
// Series detail with mutations
// ---------------------------------------------------------------------------

/// `GET /library/tv/{id}` (30 s) plus the monitor toggles, applied
/// optimistically and rolled back on failure.
class SeriesDetailController extends AsyncNotifier<SeriesDetail> {
  SeriesDetailController(this.id);

  final int id;

  LibraryApi get _api => ref.read(libraryApiProvider);

  @override
  Future<SeriesDetail> build() {
    autoRefresh(ref, RefreshIntervals.thirtySeconds);
    return ref.watch(libraryApiProvider).seriesDetail(id);
  }

  Future<void> _optimistic(SeriesDetail Function(SeriesDetail d) change, Future<void> Function() send) async {
    final before = state.value;
    if (before == null) return;
    state = AsyncData(change(before));
    try {
      await send();
      ref.invalidate(seriesListProvider);
    } catch (_) {
      if (ref.mounted) state = AsyncData(before);
      rethrow;
    }
  }

  /// Series-level monitored flag.
  Future<void> setMonitored(bool monitored) =>
      _optimistic((d) => d.copyWith(series: d.series.copyWithMonitored(monitored)), () async {
        final saved = await _api.editSeries(id, monitored: monitored);
        final current = state.value;
        if (ref.mounted && current != null) state = AsyncData(current.copyWith(series: saved));
      });

  /// A season's flag; its episodes follow (Sonarr's season bookmark).
  Future<void> setSeasonMonitored(int seasonNumber, bool monitored) => _optimistic(
    (d) => d.copyWith(
      seasons: [for (final s in d.seasons) s.seasonNumber == seasonNumber ? s.copyWithMonitored(monitored) : s],
      episodes: [for (final e in d.episodes) e.seasonNumber == seasonNumber ? e.copyWithMonitored(monitored) : e],
    ),
    () => _api.setSeasonMonitored(id, seasonNumber, monitored),
  );

  /// Monitors or unmonitors [episodeIds].
  Future<void> setEpisodesMonitored(Set<int> episodeIds, bool monitored) => _optimistic(
    (d) => d.copyWith(
      episodes: [for (final e in d.episodes) episodeIds.contains(e.id) ? e.copyWithMonitored(monitored) : e],
    ),
    () => _api.setEpisodesMonitored(episodeIds.toList(), monitored),
  );

  /// Saves the edit sheet and refreshes the page.
  Future<void> edit({
    bool? monitored,
    int? qualityProfileId,
    LibrarySeriesType? seriesType,
    LibraryMonitorNewItems? monitorNewItems,
  }) async {
    final saved = await _api.editSeries(
      id,
      monitored: monitored,
      qualityProfileId: qualityProfileId,
      seriesType: seriesType,
      monitorNewItems: monitorNewItems,
    );
    final current = state.value;
    if (ref.mounted && current != null) state = AsyncData(current.copyWith(series: saved));
    ref.invalidate(seriesListProvider);
    ref.invalidateSelf();
  }
}

final seriesDetailProvider = AsyncNotifierProvider.autoDispose.family<SeriesDetailController, SeriesDetail, int>(
  SeriesDetailController.new,
);

// ---------------------------------------------------------------------------
// Movie detail with mutations
// ---------------------------------------------------------------------------

class MovieDetailController extends AsyncNotifier<MovieDetail> {
  MovieDetailController(this.id);

  final int id;

  LibraryApi get _api => ref.read(libraryApiProvider);

  @override
  Future<MovieDetail> build() {
    autoRefresh(ref, RefreshIntervals.thirtySeconds);
    return ref.watch(libraryApiProvider).movieDetail(id);
  }

  Future<void> setMonitored(bool monitored) async {
    final before = state.value;
    if (before == null) return;
    state = AsyncData(before.copyWithMovie(before.movie.copyWithMonitored(monitored)));
    try {
      final saved = await _api.editMovie(id, monitored: monitored);
      if (ref.mounted) state = AsyncData((state.value ?? before).copyWithMovie(saved));
      ref.invalidate(moviesListProvider);
    } catch (_) {
      if (ref.mounted) state = AsyncData(before);
      rethrow;
    }
  }

  Future<void> edit({bool? monitored, int? qualityProfileId, LibraryMinimumAvailability? minimumAvailability}) async {
    final saved = await _api.editMovie(
      id,
      monitored: monitored,
      qualityProfileId: qualityProfileId,
      minimumAvailability: minimumAvailability,
    );
    final current = state.value;
    if (ref.mounted && current != null) state = AsyncData(current.copyWithMovie(saved));
    ref.invalidate(moviesListProvider);
  }
}

final movieDetailProvider = AsyncNotifierProvider.autoDispose.family<MovieDetailController, MovieDetail, int>(
  MovieDetailController.new,
);

// ---------------------------------------------------------------------------
// Commands (search / refresh) with result SnackBars
// ---------------------------------------------------------------------------

/// A Sonarr/Radarr command the app is waiting for.
class LibraryTrackedCommand {
  const LibraryTrackedCommand({required this.ref, required this.label, this.kind, this.itemId});

  final CommandRef ref;

  /// "Search season 3", "Refresh", ...
  final String label;

  /// The series/movie the command is about (its detail refreshes when done).
  final LibraryKind? kind;
  final int? itemId;

  bool isFor(LibraryKind k, int id) => kind == k && itemId == id;

  LibraryTrackedCommand copyWith(CommandRef ref) =>
      LibraryTrackedCommand(ref: ref, label: label, kind: kind, itemId: itemId);
}

/// Poll interval and limit for `GET /library/commands/...` (API.md §7).
const libraryCommandPoll = Duration(seconds: 2);
const libraryCommandMaxWait = Duration(minutes: 2);

/// Polls started commands every 2 s until they finish (max 2 min), then
/// shows a result SnackBar and refreshes the affected screens. Kept alive so
/// leaving the screen does not lose the result.
class LibraryCommandsController extends Notifier<List<LibraryTrackedCommand>> {
  final _timers = <String, Timer>{};
  final _started = <String, DateTime>{};

  static String _key(CommandRef r) => '${r.service.name}:${r.id}';

  @override
  List<LibraryTrackedCommand> build() {
    ref.onDispose(() {
      for (final t in _timers.values) {
        t.cancel();
      }
      _timers.clear();
    });
    return const [];
  }

  /// Starts tracking [command] (no-op if already tracked).
  void track(CommandRef command, {required String label, LibraryKind? kind, int? itemId}) {
    final key = _key(command);
    if (state.any((c) => _key(c.ref) == key)) return;
    final tracked = LibraryTrackedCommand(ref: command, label: label, kind: kind, itemId: itemId);
    if (!command.status.isActive && command.status != CommandStatus.unknown) {
      _finish(tracked);
      return;
    }
    state = [...state, tracked];
    _started[key] = DateTime.now();
    _schedule(key);
  }

  void _schedule(String key) {
    _timers[key]?.cancel();
    _timers[key] = Timer(libraryCommandPoll, () => _poll(key));
  }

  Future<void> _poll(String key) async {
    final index = state.indexWhere((c) => _key(c.ref) == key);
    if (index < 0) return;
    final tracked = state[index];
    try {
      final latest = await ref.read(libraryApiProvider).command(tracked.ref.service, tracked.ref.id);
      final updated = tracked.copyWith(latest);
      if (!latest.status.isActive) {
        _finish(updated);
        return;
      }
      state = [for (final c in state) _key(c.ref) == key ? updated : c];
    } catch (_) {
      // Transient errors: keep polling until the deadline.
    }
    final started = _started[key] ?? DateTime.now();
    if (DateTime.now().difference(started) >= libraryCommandMaxWait) {
      _drop(key);
      _snack('${tracked.label}: still running in ${tracked.ref.service.displayName}');
      return;
    }
    _schedule(key);
  }

  void _drop(String key) {
    _timers.remove(key)?.cancel();
    _started.remove(key);
    state = [
      for (final c in state)
        if (_key(c.ref) != key) c,
    ];
  }

  void _finish(LibraryTrackedCommand c) {
    _drop(_key(c.ref));
    final r = c.ref;
    final ok = r.status == CommandStatus.completed && r.result != CommandResult.unsuccessful;
    final message = r.message;
    _snack(ok ? '${c.label}: done' : '${c.label}: ${message != null && message.isNotEmpty ? message : r.status.name}');
    switch (c.kind) {
      case LibraryKind.tv:
        if (c.itemId case final id?) ref.invalidate(seriesDetailProvider(id));
        ref.invalidate(seriesListProvider);
      case LibraryKind.movies:
        if (c.itemId case final id?) ref.invalidate(movieDetailProvider(id));
        ref.invalidate(moviesListProvider);
      case null:
        break;
    }
    ref.invalidate(librarySummaryProvider);
  }

  void _snack(String message) => showHubSnackBar(ref.read(scaffoldMessengerKeyProvider), message);
}

final libraryCommandsProvider = NotifierProvider<LibraryCommandsController, List<LibraryTrackedCommand>>(
  LibraryCommandsController.new,
);
