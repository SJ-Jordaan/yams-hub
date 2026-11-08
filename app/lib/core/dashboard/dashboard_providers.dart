/// `GET /dashboard` for Home (APP.md §3.3): every visible card every 15 s,
/// the fast cards (activity, system, media) every 5 s.
library;

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_models/yams_models.dart';

import '../api/core_api.dart';
import '../refresh/app_lifecycle_provider.dart';
import '../refresh/auto_refresh.dart';
import '../routing/nav_badges.dart';
import '../settings/app_settings.dart';

/// Cards refreshed on the fast interval.
const fastDashboardCards = [DashboardCardKeys.activity, DashboardCardKeys.system, DashboardCardKeys.media];

/// [old] when [next] carries the same content, else [next]: unchanged
/// sections keep their identity across refreshes, so the cards that select
/// them do not rebuild. `fetchedAt` only counts while the data is stale (the
/// stale badge shows it).
Section reuseSection(Section? old, Section next) {
  if (old == null || identical(old, next)) return next;
  final same =
      old.status == next.status &&
      old.stale == next.stale &&
      old.error?.code == next.error?.code &&
      old.error?.message == next.error?.message &&
      (!next.stale || old.fetchedAt == next.fetchedAt) &&
      const DeepCollectionEquality().equals(old.data, next.data);
  return same ? old : next;
}

/// [old] when [next] holds the same alerts in the same order, else [next].
List<Alert> reuseAlerts(List<Alert> old, List<Alert> next) {
  if (identical(old, next)) return next;
  if (old.length != next.length) return next;
  const eq = DeepCollectionEquality();
  for (var i = 0; i < old.length; i++) {
    if (!identical(old[i], next[i]) && !eq.equals(old[i].toJson(), next[i].toJson())) return next;
  }
  return old;
}

/// [next] with every unchanged section and the alerts (when unchanged) taken
/// from [previous].
DashboardResponse reuseDashboard(DashboardResponse? previous, DashboardResponse next) {
  if (previous == null) return next;
  return DashboardResponse(
    generatedAt: next.generatedAt,
    alerts: reuseAlerts(previous.alerts, next.alerts),
    cards: {for (final e in next.cards.entries) e.key: reuseSection(previous.cards[e.key], e.value)},
  );
}

/// Merges a partial response (some cards only) into [current]: its cards
/// replace the old ones, and its alerts replace the alerts of those cards'
/// features. Unchanged sections and alerts keep their identity.
DashboardResponse mergeDashboard(DashboardResponse current, DashboardResponse partial) {
  final refreshed = partial.cards.keys.toSet();
  return DashboardResponse(
    generatedAt: partial.generatedAt,
    alerts: reuseAlerts(current.alerts, [
      for (final a in current.alerts)
        if (!refreshed.contains(a.feature)) a,
      ...partial.alerts,
    ]),
    cards: {
      ...current.cards,
      for (final e in partial.cards.entries) e.key: reuseSection(current.cards[e.key], e.value),
    },
  );
}

/// Re-fetches the whole dashboard (pull to refresh, retry buttons); errors are
/// shown by the screen.
Future<void> refreshDashboard(WidgetRef ref) async {
  ref.invalidate(dashboardProvider);
  try {
    await ref.read(dashboardProvider.future);
  } catch (_) {
    // Shown by the screen.
  }
}

class DashboardController extends AsyncNotifier<DashboardResponse> {
  Timer? _fastTimer;
  bool _fastInFlight = false;

  @override
  Future<DashboardResponse> build() async {
    autoRefresh(ref, RefreshIntervals.dashboard);
    // Joined so the comparison is by value.
    final visible = ref
        .watch(appSettingsProvider.select((s) => s.visibleCards.join(',')))
        .split(',')
        .where((k) => k.isNotEmpty)
        .toList();
    final api = ref.watch(coreApiProvider);
    ref.onDispose(() => _fastTimer?.cancel());

    // Every card hidden: still ask for the system card so the alerts and the
    // header stay live (an empty `cards=` would mean "all" or "none").
    final cards = visible.isEmpty ? const [DashboardCardKeys.system] : visible;
    final all = cards.length == DashboardCardKeys.all.length;
    final response = await api.dashboard(cards: all ? null : cards);
    if (!ref.mounted) return response;
    ref.read(navBadgesProvider.notifier).seed(response);
    _scheduleFast(visible);
    // Against the value shown while reloading: unchanged cards keep their
    // sections and do not rebuild.
    return reuseDashboard(state.value, response);
  }

  void _scheduleFast(List<String> visible) {
    _fastTimer?.cancel();
    final interval = scaledInterval(ref, RefreshIntervals.dashboardFast);
    final cards = fastDashboardCards.where(visible.contains).toList();
    if (interval == null || cards.isEmpty) return;
    _fastTimer = Timer(interval, () async {
      await refreshFast(cards);
      if (ref.mounted) _scheduleFast(visible);
    });
  }

  /// Refreshes only [cards] and merges them into the current state. Skipped
  /// while Home is not visible or the app is in the background.
  Future<void> refreshFast([List<String> cards = fastDashboardCards]) async {
    final current = state.value;
    if (current == null || _fastInFlight || !ref.mounted || ref.isPaused) return;
    if (ref.read(appLifecycleProvider) != AppLifecycleState.resumed) return;
    _fastInFlight = true;
    try {
      final partial = await ref.read(coreApiProvider).dashboard(cards: cards);
      final latest = state.value;
      if (!ref.mounted || latest == null) return;
      state = AsyncData(mergeDashboard(latest, partial));
      ref.read(navBadgesProvider.notifier).seed(partial);
    } catch (_) {
      // The full refresh reports errors; fast refreshes stay silent.
    } finally {
      _fastInFlight = false;
    }
  }
}

final dashboardProvider = AsyncNotifierProvider.autoDispose<DashboardController, DashboardResponse>(
  DashboardController.new,
);
