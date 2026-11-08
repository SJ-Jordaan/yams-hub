/// Home stays cheap: cards are built lazily on phones, and a refresh that
/// changes nothing rebuilds nothing (APP.md §3.3).
library;

import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/dashboard/dashboard_card_frame.dart';
import 'package:yams_hub/core/dashboard/dashboard_providers.dart';
import 'package:yams_hub/core/dashboard/dashboard_screen.dart';
import 'package:yams_hub/core/launcher/web_apps_screen.dart';
import 'package:yams_hub/core/launcher/web_apps_section.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/builders.dart';
import '../../support/fake_api.dart';
import '../../support/pump_hub_app.dart';

/// Counts builds of [DashboardScreen] and of each card's content
/// ([DashboardCardView], by card key) while installed, and remembers in which
/// frame each [DashboardCardFrame] and the [WebAppsSection] were first built.
class _BuildCounter {
  _BuildCounter() {
    debugOnRebuildDirtyWidget = (element, _) {
      final builtOnce = !_seen.add(element);
      final w = element.widget;
      final frame = SchedulerBinding.instance.currentFrameTimeStamp;
      if (w is DashboardScreen) screen++;
      if (w is DashboardCardView) cards[w.spec.key] = (cards[w.spec.key] ?? 0) + 1;
      if (w is DashboardCardFrame && !builtOnce) firstBuilt[frame] = (firstBuilt[frame] ?? 0) + 1;
      if (w is WebAppsSection && !builtOnce) webAppsFirstBuilt ??= frame;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
  }

  // Elements built before (the callback's own flag is only kept while
  // debugPrintRebuildDirtyWidgets is on).
  final Set<Element> _seen = Set.identity();

  int screen = 0;
  final Map<String, int> cards = {};

  /// Frame timestamp → card frames first built in it.
  final SplayTreeMap<Duration, int> firstBuilt = SplayTreeMap();
  Duration? webAppsFirstBuilt;

  void reset() {
    screen = 0;
    cards.clear();
  }
}

/// Lets the post-login prebuild (the cache extent growing frame by frame)
/// finish.
Future<void> _prebuild(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Every card ok, so each one has a real body.
JsonMap _fullDashboard({int tick = 0}) => buildDashboardJson(
  cards: {
    ...rawCards(),
    DashboardCardKeys.system: buildSection({'cpuPercent': 12.5 + tick}).toJson(),
    DashboardCardKeys.activity: buildSection({
      'counts': {'downloading': 2 + tick, 'seeding': 5, 'stalled': 0, 'attention': 2},
    }).toJson(),
  },
);

Future<void> _runFor(WidgetTester tester, Duration total) async {
  for (var t = Duration.zero; t < total; t += const Duration(milliseconds: 500)) {
    await tester.pump(const Duration(milliseconds: 500));
  }
}

void main() {
  testWidgets('phone: the first frame builds only the visible cards, the rest follow frame by frame', (tester) async {
    final api = buildCoreFakeApi()..getJson('/dashboard', _fullDashboard());
    final counter = _BuildCounter();
    await pumpHubApp(tester, api: api, size: const Size(412, 839));
    await _prebuild(tester);

    final total = DashboardCardKeys.all.length;
    expect(counter.firstBuilt.values.fold(0, (a, b) => a + b), total, reason: 'every card is prebuilt in the end');
    final firstFrame = counter.firstBuilt.firstKey()!;
    expect(counter.firstBuilt[firstFrame], lessThan(total), reason: 'not all in the first frame');
    expect(counter.firstBuilt.length, greaterThan(1));
    // The web apps (and their providers) come after the cards, never in the
    // first card frame.
    final webApps = counter.webAppsFirstBuilt;
    if (webApps != null) expect(webApps, greaterThan(firstFrame));

    await tester.scrollUntilVisible(find.text('Web apps'), 300);
    await settle(tester);
    expect(find.byType(LauncherTile), findsWidgets);
  });

  testWidgets('wide: every card is built behind its own repaint boundary', (tester) async {
    final api = buildCoreFakeApi()..getJson('/dashboard', _fullDashboard());
    await pumpHubApp(tester, api: api, size: const Size(1400, 2400));
    final frames = find.byType(DashboardCardFrame);
    expect(frames, findsNWidgets(DashboardCardKeys.all.length));
    for (final e in frames.evaluate()) {
      expect(find.ancestor(of: find.byWidget(e.widget), matching: find.byType(RepaintBoundary)), findsWidgets);
    }
  });

  testWidgets('60 s of unchanged polls rebuild no card and not the screen', (tester) async {
    final api = buildCoreFakeApi()..getJson('/dashboard', _fullDashboard());
    final counter = _BuildCounter();
    // Tall enough that every card is built.
    await pumpHubApp(tester, api: api, size: const Size(412, 4000));
    await _prebuild(tester);
    expect(find.byType(DashboardCardFrame), findsNWidgets(DashboardCardKeys.all.length));
    counter.reset();
    final before = api.requestsTo('/dashboard').length;

    await _runFor(tester, const Duration(seconds: 60));

    expect(api.requestsTo('/dashboard').length - before, greaterThanOrEqualTo(10), reason: 'fast and full polls ran');
    expect(counter.cards, isEmpty);
    expect(counter.screen, lessThanOrEqualTo(1));
  });

  testWidgets('unchanged cards still rebuild once when the minute of generatedAt changes', (tester) async {
    // Relative times ("last scan 5 min ago") must not freeze on unchanged data.
    var minutes = 0;
    final api = buildCoreFakeApi()
      ..on(
        'GET',
        '/dashboard',
        (_) => FakeResponse({
          ..._fullDashboard(),
          'generatedAt': instantToJson(testNow.add(Duration(minutes: minutes))),
        }),
      );
    final counter = _BuildCounter();
    await pumpHubApp(tester, api: api, size: const Size(412, 4000));
    await _prebuild(tester);
    expect(find.byType(DashboardCardFrame), findsNWidgets(DashboardCardKeys.all.length));
    counter.reset();

    minutes = 1;
    await _runFor(tester, const Duration(seconds: 60));

    expect(counter.cards.keys.toSet(), DashboardCardKeys.all.toSet());
    expect(counter.cards.values, everyElement(1), reason: 'once per minute, not once per poll');
  });

  testWidgets('changing fast-card data rebuilds only those cards', (tester) async {
    var tick = 0;
    final api = buildCoreFakeApi()..on('GET', '/dashboard', (_) => FakeResponse(_fullDashboard(tick: tick++)));
    final counter = _BuildCounter();
    await pumpHubApp(tester, api: api, size: const Size(412, 4000));
    await _prebuild(tester);
    counter.reset();

    await _runFor(tester, const Duration(seconds: 60));

    expect(counter.cards.keys.toSet(), {DashboardCardKeys.system, DashboardCardKeys.activity});
    expect(counter.cards.keys.toSet(), everyElement(isIn(fastDashboardCards)));
    expect(counter.screen, lessThanOrEqualTo(1));
  });

  group('section reuse', () {
    test('an equal section keeps its instance, a changed one is replaced', () {
      final current = DashboardResponse.fromJson(_fullDashboard());
      final partial = DashboardResponse.fromJson(_fullDashboard(tick: 1));
      final merged = mergeDashboard(current, partial);
      expect(identical(merged.card(DashboardCardKeys.requests), current.card(DashboardCardKeys.requests)), isTrue);
      expect(identical(merged.card(DashboardCardKeys.calendar), current.card(DashboardCardKeys.calendar)), isTrue);
      expect(identical(merged.card(DashboardCardKeys.system), current.card(DashboardCardKeys.system)), isFalse);
      expect(merged.card(DashboardCardKeys.system)!.data!['cpuPercent'], 13.5);
      expect(identical(merged.alerts, current.alerts), isTrue);

      final again = reuseDashboard(merged, DashboardResponse.fromJson(_fullDashboard(tick: 1)));
      for (final key in DashboardCardKeys.all) {
        expect(identical(again.card(key), merged.card(key)), isTrue, reason: key);
      }
    });

    test('status, stale, error and stale fetchedAt changes are not reused', () {
      final ok = buildSection({'a': 1});
      expect(identical(reuseSection(ok, buildSection({'a': 1})), ok), isTrue);
      expect(identical(reuseSection(ok, buildSection({'a': 2})), ok), isFalse);
      expect(identical(reuseSection(ok, buildSection({'a': 1}, stale: true)), ok), isFalse);
      final fresh = Section.ok(const {'a': 1}, fetchedAt: testNow.add(const Duration(seconds: 5)));
      expect(identical(reuseSection(ok, fresh), ok), isTrue, reason: 'fetchedAt only matters when stale');
      final stale = buildSection({'a': 1}, stale: true);
      final staleLater = Section.ok(const {'a': 1}, fetchedAt: testNow.add(const Duration(minutes: 1)), stale: true);
      expect(identical(reuseSection(stale, staleLater), stale), isFalse);
      const error = ApiError(code: ApiErrorCode.internal, message: 'Boom', status: 500);
      const other = ApiError(code: ApiErrorCode.upstreamUnavailable, message: 'Down', status: 502);
      const failed = Section.failure(error);
      expect(identical(reuseSection(failed, const Section.failure(error)), failed), isTrue);
      expect(identical(reuseSection(failed, const Section.failure(other)), failed), isFalse);
    });

    test('alerts: equal lists keep their instance', () {
      final a = [buildAlert(id: 'x'), buildAlert(id: 'y')];
      expect(identical(reuseAlerts(a, [buildAlert(id: 'x'), buildAlert(id: 'y')]), a), isTrue);
      expect(identical(reuseAlerts(a, [buildAlert(id: 'y'), buildAlert(id: 'x')]), a), isFalse);
      expect(identical(reuseAlerts(a, [buildAlert(id: 'x')]), a), isFalse);
    });
  });
}
