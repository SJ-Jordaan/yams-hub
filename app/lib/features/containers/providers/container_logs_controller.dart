/// State of the log viewer (APP.md §9.3): manual refresh plus a "Follow"
/// mode that polls every 3 s with `since=<last line>`.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/refresh/app_lifecycle_provider.dart';
import 'package:yams_models/yams_models.dart';

import '../data/containers_api.dart';

/// Tail sizes offered by the viewer.
const containerLogTails = [200, 500, 2000];

/// Follow poll interval (not scaled by the refresh preset).
const containerLogFollowInterval = Duration(seconds: 3);

/// Most lines kept while following.
const containerLogMaxLines = 5000;

@immutable
class ContainerLogsState {
  const ContainerLogsState({
    this.lines = const [],
    this.loading = true,
    this.error,
    this.tail = 200,
    this.stream = 'all',
    this.follow = false,
    this.truncated = false,
  });

  final List<LogLine> lines;
  final bool loading;
  final Object? error;
  final int tail;

  /// `all`, `stdout` or `stderr`.
  final String stream;
  final bool follow;
  final bool truncated;

  ContainerLogsState copyWith({
    List<LogLine>? lines,
    bool? loading,
    Object? error,
    bool clearError = false,
    int? tail,
    String? stream,
    bool? follow,
    bool? truncated,
  }) => ContainerLogsState(
    lines: lines ?? this.lines,
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
    tail: tail ?? this.tail,
    stream: stream ?? this.stream,
    follow: follow ?? this.follow,
    truncated: truncated ?? this.truncated,
  );
}

class ContainerLogsController extends Notifier<ContainerLogsState> {
  ContainerLogsController(this.name);

  final String name;
  Timer? _timer;
  bool _polling = false;
  int _generation = 0;

  @override
  ContainerLogsState build() {
    ref.onDispose(() => _timer?.cancel());
    Future.microtask(reload);
    return const ContainerLogsState();
  }

  ContainersApi get _api => ref.read(containersApiProvider);

  /// Loads the last `tail` lines again.
  Future<void> reload() async {
    final gen = ++_generation;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final r = await _api.logs(name, tail: state.tail, stream: state.stream);
      if (!ref.mounted || gen != _generation) return;
      state = state.copyWith(lines: r.lines, truncated: r.truncated, loading: false, clearError: true);
    } catch (e) {
      if (!ref.mounted || gen != _generation) return;
      state = state.copyWith(loading: false, error: e);
    }
  }

  void setTail(int tail) {
    if (tail == state.tail) return;
    state = state.copyWith(tail: tail);
    unawaited(reload());
  }

  void setStream(String stream) {
    if (stream == state.stream) return;
    state = state.copyWith(stream: stream);
    unawaited(reload());
  }

  void setFollow(bool follow) {
    state = state.copyWith(follow: follow);
    _timer?.cancel();
    _timer = null;
    if (follow) {
      _timer = Timer.periodic(containerLogFollowInterval, (_) => unawaited(poll()));
      unawaited(poll());
    }
  }

  /// Fetches lines newer than the last one (Follow).
  Future<void> poll() async {
    if (_polling || state.loading) return;
    if (ref.read(appLifecycleProvider) != AppLifecycleState.resumed) return;
    DateTime? since;
    for (final l in state.lines.reversed) {
      if (l.at != null) {
        since = l.at;
        break;
      }
    }
    if (since == null) return reload();
    _polling = true;
    final gen = _generation;
    try {
      final r = await _api.logs(name, tail: containerLogTails.last, since: since, stream: state.stream);
      if (!ref.mounted || gen != _generation || r.lines.isEmpty) return;
      final merged = [...state.lines, ...r.lines];
      final overflow = merged.length - containerLogMaxLines;
      state = state.copyWith(
        lines: overflow > 0 ? merged.sublist(overflow) : merged,
        truncated: state.truncated || overflow > 0,
        clearError: true,
      );
    } catch (e) {
      if (ref.mounted && gen == _generation) state = state.copyWith(error: e);
    } finally {
      _polling = false;
    }
  }
}

final containerLogsProvider = NotifierProvider.autoDispose.family<ContainerLogsController, ContainerLogsState, String>(
  ContainerLogsController.new,
);
