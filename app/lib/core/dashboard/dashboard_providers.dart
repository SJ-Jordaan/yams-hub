/// `GET /dashboard` for Home (APP.md §3.3): every visible card every 15 s,
/// the fast cards (activity, system, media) every 5 s.
library;

import 'dart:async';

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

/// Merges a partial response (some cards only) into [current]: its cards
/// replace the old ones, and its alerts replace the alerts of those cards'
/// features.
DashboardResponse mergeDashboard(DashboardResponse current, DashboardResponse partial) {
  final refreshed = partial.cards.keys.toSet();
  return DashboardResponse(
    generatedAt: partial.generatedAt,
    alerts: [
      for (final a in current.alerts)
        if (!refreshed.contains(a.feature)) a,
      ...partial.alerts,
    ],
    cards: {...current.cards, ...partial.cards},
  );
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
    if (ref.mounted) {
      ref.read(navBadgesProvider.notifier).seed(response);
      _scheduleFast(visible);
    }
    return response;
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
