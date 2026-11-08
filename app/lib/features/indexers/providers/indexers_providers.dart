/// Riverpod state of the indexers feature (APP.md §10).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/refresh/auto_refresh.dart';
import 'package:yams_models/yams_models.dart';

import '../data/indexers_api.dart';

/// `GET /indexers`, every 60 s, with optimistic enable/priority edits.
class IndexerListController extends AsyncNotifier<IndexerList> {
  @override
  Future<IndexerList> build() async {
    autoRefresh(ref, RefreshIntervals.sixtySeconds);
    return ref.watch(indexersApiProvider).list();
  }

  /// Enables or disables [ids] (optimistic; rolled back and rethrown on
  /// failure).
  Future<void> setEnabled(Set<int> ids, bool enabled) => _update(
    IndexerBulkUpdate(ids: ids.toList()..sort(), enabled: enabled),
    (i) => i.withEnabled(enabled),
    ids,
  );

  /// Sets the priority (1–50) of [ids].
  Future<void> setPriority(Set<int> ids, int priority) => _update(
    IndexerBulkUpdate(ids: ids.toList()..sort(), priority: priority),
    (i) => i.withPriority(priority),
    ids,
  );

  Future<void> _update(
    IndexerBulkUpdate update,
    Indexer Function(Indexer) patch,
    Set<int> ids,
  ) async {
    final previous = state.value;
    if (previous != null) {
      state = AsyncData(
        previous.withItems([
          for (final i in previous.items) ids.contains(i.id) ? patch(i) : i,
        ]),
      );
    }
    try {
      final fresh = await ref.read(indexersApiProvider).bulkUpdate(update);
      if (ref.mounted) state = AsyncData(fresh);
    } catch (_) {
      if (ref.mounted && previous != null) state = AsyncData(previous);
      rethrow;
    }
    // The detail screens show the same indexers.
    for (final id in ids) {
      ref.invalidate(indexerDetailProvider(id));
    }
  }
}

final indexerListProvider =
    AsyncNotifierProvider.autoDispose<IndexerListController, IndexerList>(
      IndexerListController.new,
    );

/// `GET /indexers/{id}`, every 60 s.
final indexerDetailProvider = FutureProvider.autoDispose.family<Indexer, int>((
  ref,
  id,
) async {
  autoRefresh(ref, RefreshIntervals.sixtySeconds);
  return ref.watch(indexersApiProvider).detail(id);
});

/// `GET /indexers/categories` (the gateway caches it for 24 h).
final indexerCategoriesProvider =
    FutureProvider.autoDispose<List<IndexerCategory>>((ref) {
      return ref.watch(indexersApiProvider).categories();
    });

/// Categories that belong to Sonarr/Radarr/Lidarr: a manual grab there would
/// show up as an unknown download in the *arr queue.
const arrManagedCategories = {'tv-sonarr', 'radarr', 'lidarr'};

/// qBittorrent categories offered by the grab sheet: `manual` first, then the
/// non-*arr categories. Falls back to `manual` alone when the list cannot be
/// loaded.
final grabCategoriesProvider = FutureProvider.autoDispose<List<String>>((
  ref,
) async {
  const manual = ReleaseGrabRequest.defaultCategory;
  try {
    final all = await ref.watch(indexersApiProvider).qbitCategories();
    final names = {for (final c in all) c.name}
      ..removeAll(arrManagedCategories);
    return [manual, ...(names..remove(manual)).toList()..sort()];
  } catch (_) {
    return const [manual];
  }
});

/// The state of the manual search screen.
class ReleaseSearchState {
  const ReleaseSearchState({
    this.query,
    this.running = false,
    this.startedAt,
    this.result,
    this.error,
  });

  /// The last submitted search.
  final ReleaseSearchQuery? query;
  final bool running;
  final DateTime? startedAt;
  final ReleaseList? result;
  final Object? error;
}

/// Runs explicit (never as-you-type) manual searches, one at a time.
class ReleaseSearchController extends Notifier<ReleaseSearchState> {
  int _generation = 0;

  @override
  ReleaseSearchState build() => const ReleaseSearchState();

  Future<void> search(ReleaseSearchQuery query) async {
    if (state.running) return;
    final generation = ++_generation;
    state = ReleaseSearchState(
      query: query,
      running: true,
      startedAt: DateTime.now(),
    );
    try {
      final result = await ref.read(indexersApiProvider).search(query);
      if (!ref.mounted || generation != _generation) return;
      state = ReleaseSearchState(query: query, result: result);
    } catch (e) {
      if (!ref.mounted || generation != _generation) return;
      state = ReleaseSearchState(query: query, error: e);
    }
  }

  /// Forgets the results (new form).
  void clear() {
    _generation++;
    state = const ReleaseSearchState();
  }
}

final releaseSearchProvider =
    NotifierProvider.autoDispose<ReleaseSearchController, ReleaseSearchState>(
      ReleaseSearchController.new,
    );
