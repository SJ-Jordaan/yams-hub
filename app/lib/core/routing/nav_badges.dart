/// Shell badges and More-screen counts from the dashboard's raw card keys
/// (ARCHITECTURE §7.2, API.md §4). Core never imports feature DTO classes.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_models/yams_models.dart';

import '../api/core_api.dart';
import '../auth/auth_controller.dart';
import '../refresh/app_lifecycle_provider.dart';
import '../refresh/auto_refresh.dart';
import '../settings/app_settings.dart';

/// Counts read from `cards.<key>.data` (API.md §4 raw-key contract). Every
/// field is null when its card is missing, failed, or the key is absent or
/// has the wrong type (no badge).
@immutable
class NavBadges {
  const NavBadges({
    this.requestsPending,
    this.activityAttention,
    this.calendarNext7Days,
    this.containersRunning,
    this.containersTotal,
    this.indexersFailing,
    this.subtitlesMissing,
  });

  /// Reads the raw keys from the given cards; cards not in [cards] are null.
  factory NavBadges.fromCards(Map<String, Section> cards) => const NavBadges().merge(cards);

  /// The dashboard cards the poller asks for.
  static const cardKeys = [
    DashboardCardKeys.requests,
    DashboardCardKeys.activity,
    DashboardCardKeys.calendar,
    DashboardCardKeys.containers,
    DashboardCardKeys.indexers,
    DashboardCardKeys.subtitles,
  ];

  /// `cards.requests.data.counts.pending` (admins see it on Requests).
  final int? requestsPending;

  /// `cards.activity.data.counts.attention`.
  final int? activityAttention;

  /// `cards.calendar.data.countNext7Days`.
  final int? calendarNext7Days;

  /// `cards.containers.data.running` / `.total`.
  final int? containersRunning;
  final int? containersTotal;

  /// `cards.indexers.data.failing` (array length).
  final int? indexersFailing;

  /// `cards.subtitles.data.missingEpisodes`.
  final int? subtitlesMissing;

  /// A copy updated from the cards present in [cards]; other fields keep
  /// their value (a fast-cards refresh only carries `activity`).
  NavBadges merge(Map<String, Section> cards) {
    JsonMap? data(String key) {
      final section = cards[key];
      return section == null ? null : (section.isOk ? section.data : null);
    }

    bool has(String key) => cards.containsKey(key);
    final requests = data(DashboardCardKeys.requests);
    final activity = data(DashboardCardKeys.activity);
    final calendar = data(DashboardCardKeys.calendar);
    final containers = data(DashboardCardKeys.containers);
    final indexers = data(DashboardCardKeys.indexers);
    final subtitles = data(DashboardCardKeys.subtitles);

    return NavBadges(
      requestsPending: has(DashboardCardKeys.requests)
          ? _int(readMap(requests?['counts'])?['pending'])
          : requestsPending,
      activityAttention: has(DashboardCardKeys.activity)
          ? _int(readMap(activity?['counts'])?['attention'])
          : activityAttention,
      calendarNext7Days: has(DashboardCardKeys.calendar)
          ? _int(calendar?['countNext7Days'])
          : calendarNext7Days,
      containersRunning: has(DashboardCardKeys.containers)
          ? _int(containers?['running'])
          : containersRunning,
      containersTotal: has(DashboardCardKeys.containers) ? _int(containers?['total']) : containersTotal,
      indexersFailing: has(DashboardCardKeys.indexers)
          ? (indexers?['failing'] is List ? (indexers!['failing']! as List).length : null)
          : indexersFailing,
      subtitlesMissing: has(DashboardCardKeys.subtitles)
          ? _int(subtitles?['missingEpisodes'])
          : subtitlesMissing,
    );
  }

  /// Only real JSON integers count (a `"5"` string is "wrong type", no badge).
  static int? _int(Object? v) => switch (v) {
    int() when v >= 0 => v,
    double() when v >= 0 && v == v.truncateToDouble() => v.toInt(),
    _ => null,
  };

  @override
  bool operator ==(Object other) =>
      other is NavBadges &&
      other.requestsPending == requestsPending &&
      other.activityAttention == activityAttention &&
      other.calendarNext7Days == calendarNext7Days &&
      other.containersRunning == containersRunning &&
      other.containersTotal == containersTotal &&
      other.indexersFailing == indexersFailing &&
      other.subtitlesMissing == subtitlesMissing;

  @override
  int get hashCode => Object.hash(
    requestsPending,
    activityAttention,
    calendarNext7Days,
    containersRunning,
    containersTotal,
    indexersFailing,
    subtitlesMissing,
  );
}

/// Polls `GET /dashboard?cards=requests,activity,calendar,containers,indexers,subtitles`
/// every 30 s (scaled by the refresh preset, paused in the background).
/// `dashboardProvider` [seed]s it whenever it loads; a seed that carries
/// every badge card restarts the timer, so no second request is made while
/// Home shows all of those cards.
///
/// Kept alive by `ShellScaffold`, which watches it.
class NavBadgesController extends Notifier<NavBadges> {
  Timer? _timer;
  bool _polling = false;

  /// Delay of the first poll after start-up or sign-in.
  static const initialDelay = Duration(seconds: 2);

  @override
  NavBadges build() {
    ref.watch(authControllerProvider.select((s) => s.signedIn));
    ref.watch(appSettingsProvider.select((s) => s.refreshPreset));
    ref.listen<AppLifecycleState>(appLifecycleProvider, (previous, next) {
      if (next == AppLifecycleState.resumed) {
        unawaited(poll());
      } else {
        _timer?.cancel();
      }
    });
    ref.onDispose(() => _timer?.cancel());
    // A short delay lets a visible dashboard seed the badges first (its seed
    // cancels this timer), so start-up does not fetch the cards twice.
    Future.microtask(() => _schedule(initialDelay));
    return const NavBadges();
  }

  /// Applies dashboard data fetched elsewhere. The poll timer restarts only
  /// when [response] carried every badge card: a dashboard with hidden cards
  /// (or a fast refresh) leaves some badges stale, so the poll must still
  /// run on time for them.
  void seed(DashboardResponse response) {
    if (!ref.mounted) return;
    state = state.merge(response.cards);
    if (NavBadges.cardKeys.every(response.cards.containsKey) || !(_timer?.isActive ?? false)) {
      _schedule();
    }
  }

  /// Fetches the badge cards now.
  Future<void> poll() async {
    if (_polling || !ref.mounted) return;
    if (!ref.read(authControllerProvider).signedIn) return;
    _polling = true;
    try {
      final response = await ref.read(coreApiProvider).dashboard(cards: NavBadges.cardKeys);
      if (ref.mounted) state = state.merge(response.cards);
    } catch (_) {
      // Keep the previous badges; the next tick retries.
    } finally {
      _polling = false;
      if (ref.mounted) _schedule();
    }
  }

  void _schedule([Duration? delay]) {
    _timer?.cancel();
    if (!ref.mounted || ref.read(appLifecycleProvider) != AppLifecycleState.resumed) return;
    final interval = delay ?? scaledInterval(ref, RefreshIntervals.navBadges);
    if (interval == null) return;
    _timer = Timer(interval, () => unawaited(poll()));
  }
}

final navBadgesProvider = NotifierProvider<NavBadgesController, NavBadges>(NavBadgesController.new);
