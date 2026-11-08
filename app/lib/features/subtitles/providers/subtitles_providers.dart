/// Riverpod state of the Subtitles screen (APP.md §11).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/refresh/app_lifecycle_provider.dart';
import 'package:yams_hub/core/refresh/auto_refresh.dart';
import 'package:yams_models/yams_models.dart';

import '../data/subtitles_api.dart';

/// `GET /subtitles/summary`, refreshed every 60 s (APP.md §11).
final subtitlesSummaryProvider = FutureProvider.autoDispose<SubtitlesSummary>((ref) async {
  autoRefresh(ref, RefreshIntervals.sixtySeconds);
  return ref.watch(subtitlesApiProvider).summary();
});

/// How often Bazarr's job queue is polled while a search runs (APP.md §11).
const subtitleJobPollInterval = Duration(seconds: 3);

/// Searches give up waiting for the queue to drain after this long.
const subtitleSearchTimeout = Duration(minutes: 10);

/// Searches started from this screen and Bazarr's active jobs.
@immutable
class SubtitleSearchState {
  const SubtitleSearchState({this.searching = const {}, this.jobs = const [], this.completed = 0});

  /// Keys of the chips/rows whose search is queued or running
  /// ([SubtitleSearchController.languageKey], [SubtitleSearchController.itemKey]).
  final Set<String> searching;

  /// Bazarr's running and pending jobs at the last poll.
  final List<SubtitleJob> jobs;

  /// Incremented each time the searches finish (Bazarr's queue drained).
  final int completed;

  bool get active => searching.isNotEmpty;

  bool isSearching(String key) => searching.contains(key);

  SubtitleSearchState copyWith({Set<String>? searching, List<SubtitleJob>? jobs, int? completed}) =>
      SubtitleSearchState(
        searching: searching ?? this.searching,
        jobs: jobs ?? this.jobs,
        completed: completed ?? this.completed,
      );
}

/// Starts subtitle searches and, while any runs, polls `GET /subtitles/jobs`
/// every 3 s until Bazarr's queue has no running or pending job.
///
/// Bazarr answers searches with `204` and no job id, so a search counts as
/// done when the queue drains (or after [subtitleSearchTimeout]). Polls are
/// skipped while the app is in the background.
class SubtitleSearchController extends Notifier<SubtitleSearchState> {
  Timer? _timer;
  bool _polling = false;
  int _failures = 0;
  DateTime? _startedAt;

  /// Key of the chip for [language] of [item].
  static String languageKey(WantedSubtitle item, SubtitleLanguage language) =>
      '${item.key}|${language.code}|${language.forced ? 'f' : ''}${language.hi ? 'h' : ''}';

  /// Key of the "Search all for this series/movie" action of [item].
  static String itemKey(WantedSubtitle item) => switch (item.type) {
    SubtitleMediaType.episode => 'series:${item.seriesId}',
    _ => item.key,
  };

  @override
  SubtitleSearchState build() {
    ref.onDispose(() {
      _timer?.cancel();
      _timer = null;
    });
    return const SubtitleSearchState();
  }

  SubtitlesApi get _api => ref.read(subtitlesApiProvider);

  /// Searches the missing [language] of [item]. Throws the API error (the
  /// chip is then released).
  Future<void> searchLanguage(WantedSubtitle item, SubtitleLanguage language) =>
      _start(languageKey(item, language), () => _api.search(SubtitleSearchRequest.forWanted(item, language)));

  /// Searches every missing language of the series (episodes) or movie of
  /// [item].
  Future<void> searchItem(WantedSubtitle item) {
    final id = item.type == SubtitleMediaType.movie ? item.movieId : item.seriesId;
    if (id == null) return Future.value();
    return _start(itemKey(item), () => _api.searchItem(SubtitleSearchItemType.of(item), id));
  }

  Future<void> _start(String key, Future<void> Function() send) async {
    if (state.isSearching(key)) return;
    state = state.copyWith(searching: {...state.searching, key});
    try {
      await send();
    } catch (_) {
      if (ref.mounted) state = state.copyWith(searching: {...state.searching}..remove(key));
      rethrow;
    }
    if (!ref.mounted) return;
    _startedAt = DateTime.now();
    _failures = 0;
    _timer ??= Timer.periodic(subtitleJobPollInterval, (_) => unawaited(_poll()));
  }

  Future<void> _poll() async {
    // Paused while the app is in the background (APP.md §2.1).
    if (_polling || !ref.mounted || !ref.read(appInForegroundProvider)) return;
    _polling = true;
    try {
      final results = await Future.wait([_api.jobs(status: 'running'), _api.jobs(status: 'pending')]);
      if (!ref.mounted) return;
      _failures = 0;
      final jobs = [...results[0], ...results[1]];
      final timedOut = _startedAt != null && DateTime.now().difference(_startedAt!) > subtitleSearchTimeout;
      if (jobs.isEmpty || timedOut) {
        _finish();
      } else {
        state = state.copyWith(jobs: jobs);
      }
    } catch (_) {
      // Keep polling through a blip; stop after repeated failures.
      if (ref.mounted && ++_failures >= 5) _finish();
    } finally {
      _polling = false;
    }
  }

  void _finish() {
    _timer?.cancel();
    _timer = null;
    _startedAt = null;
    state = SubtitleSearchState(completed: state.completed + 1);
  }
}

final subtitleSearchProvider = NotifierProvider.autoDispose<SubtitleSearchController, SubtitleSearchState>(
  SubtitleSearchController.new,
);
