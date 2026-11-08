import 'dart:convert';

import 'package:dio/dio.dart' show RequestOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/features/containers/containers_dashboard_card.dart';
import 'package:yams_hub/features/containers/providers/containers_providers.dart';
import 'package:yams_hub/features/containers/screens/updates_screen.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/builders.dart';
import '../../support/fake_api.dart';
import '../../support/pump_hub_app.dart';
import 'containers_samples.dart';

JsonMap bodyOf(RequestOptions r) {
  final data = r.data;
  return data is String ? jsonDecode(data) as JsonMap : data as JsonMap;
}

final _vertical = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first;

Future<void> scrollTo(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 200, scrollable: _vertical);
  await settle(tester, frames: 2);
}

Future<void> pumpCard(WidgetTester tester, Section section) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildHubTheme(ColorScheme.fromSeed(seedColor: const Color(0xFF7C4DFF), brightness: Brightness.dark)),
        home: Scaffold(body: ContainersDashboardCard(section: section)),
      ),
    ),
  );
}

void main() {
  group('Updates', () {
    testWidgets('scan strip, last check, statuses and the Update flow', (tester) async {
      final api = buildCoreFakeApi()
        ..getJson('/updates', updatesResponse(scanAt: testNow.subtract(const Duration(hours: 3))).toJson())
        ..on(
          'POST',
          '/updates/sonarr',
          (_) => FakeResponse({
            'job': job(
              'j_upd00000001',
              status: JobStatus.running,
              kind: 'updates.apply',
              label: 'Ask the updater',
            ).toJson(),
          }, status: 202),
        );
      serveJob(api, job('j_upd00000001', kind: 'updates.apply', label: 'compose pull sonarr'));
      await pumpHubApp(tester, api: api, location: '/containers/updates');

      expect(find.text('Watchtower'), findsOneWidget);
      expect(find.text('21'), findsOneWidget);
      expect(find.text('scanned'), findsOneWidget);
      expect(find.textContaining('Last scan'), findsOneWidget);
      expect(find.text('1 update available'), findsOneWidget);
      expect(find.textContaining('Last checked'), findsOneWidget);
      expect(find.text('Check now'), findsOneWidget);
      expect(find.text('Update available'), findsOneWidget);
      expect(find.text('Auto-updated by Watchtower'), findsOneWidget);
      await scrollTo(tester, find.text('registry timeout'));
      expect(find.text('Pinned tag'), findsOneWidget);
      expect(find.text('Error'), findsOneWidget);
      await scrollTo(tester, find.widgetWithText(FilledButton, 'Update'));

      await tester.tap(find.widgetWithText(FilledButton, 'Update'));
      await settle(tester);
      expect(find.text('Pull the latest image and recreate sonarr? It will be offline for a moment.'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Update').last);
      await settle(tester, frames: 10);
      expect(bodyOf(api.requestsTo('/updates/sonarr', method: 'POST').single), {'confirm': true});
      // The job sheet shows steps and log lines.
      expect(find.text('Update sonarr'), findsOneWidget);
      expect(find.text('compose pull sonarr'), findsWidgets);
      expect(find.text('line two'), findsOneWidget);
    });

    testWidgets('check endpoint off: strip still shown, instructions, no Check now', (tester) async {
      final api = buildCoreFakeApi()..getJson('/updates', updatesResponse(available: false, updater: false).toJson());
      await pumpHubApp(tester, api: api, location: '/containers/updates');
      expect(find.text('Watchtower'), findsOneWidget);
      expect(find.text(watchtowerEndpointsEnv), findsOneWidget);
      expect(find.text('Check now'), findsNothing);
      expect(find.text('Never checked'), findsOneWidget);
      expect(find.text('Run `yams update-containers` on the NAS to apply updates.'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Update'), findsNothing);
    });

    testWidgets('Check now starts a check job and refreshes when done', (tester) async {
      final api = buildCoreFakeApi()
        ..getJson('/updates', updatesResponse().toJson())
        ..on(
          'POST',
          '/updates/check',
          (_) => FakeResponse({
            'job': job(
              'j_chk00000001',
              status: JobStatus.running,
              kind: 'updates.check',
              label: 'Check every container for updates',
            ).toJson(),
          }, status: 202),
        );
      serveJob(api, job('j_chk00000001', kind: 'updates.check', label: 'Check every container for updates'));
      await pumpHubApp(tester, api: api, location: '/containers/updates');
      final before = api.requestsTo('/updates').length;
      await tester.tap(find.text('Check now'));
      await settle(tester, frames: 10);
      expect(bodyOf(api.requestsTo('/updates/check', method: 'POST').single), <String, Object?>{});
      expect(find.text('Check every container for updates: done'), findsWidgets);
      expect(api.requestsTo('/updates').length, greaterThan(before));
    });

    testWidgets('a rate-limited check shows the gateway message', (tester) async {
      final api = buildCoreFakeApi()
        ..getJson('/updates', updatesResponse().toJson())
        ..on(
          'POST',
          '/updates/check',
          (_) => FakeResponse.error(
            429,
            ApiErrorCode.rateLimited,
            message: 'Containers were checked less than 5 minutes ago.',
          ),
        );
      await pumpHubApp(tester, api: api, location: '/containers/updates');
      await tester.tap(find.text('Check now'));
      await settle(tester);
      expect(find.text('Containers were checked less than 5 minutes ago.'), findsOneWidget);
    });

    testWidgets('members see the list without admin buttons', (tester) async {
      final api = buildCoreFakeApi(role: Role.member)..getJson('/updates', updatesResponse().toJson());
      await pumpHubApp(tester, api: api, role: Role.member, location: '/containers/updates');
      expect(find.text('Check now'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Update'), findsNothing);
      expect(find.text('Update available'), findsOneWidget);
    });

    test('row status', () {
      expect(
        UpdateRowStatus.of(const UpdateInfo(name: 'a', image: 'a', updateAvailable: true)),
        UpdateRowStatus.available,
      );
      expect(UpdateRowStatus.of(const UpdateInfo(name: 'a', image: 'a', pinned: true)), UpdateRowStatus.pinned);
      expect(UpdateRowStatus.of(const UpdateInfo(name: 'a', image: 'a')), UpdateRowStatus.notChecked);
      expect(
        UpdateRowStatus.of(const UpdateInfo(name: 'a', image: 'a', updateAvailable: false)),
        UpdateRowStatus.upToDate,
      );
    });
  });

  group('Maintenance', () {
    testWidgets('clean decluttarr and the last recyclarr run; Sync now confirms', (tester) async {
      final api = buildCoreFakeApi()
        ..getJson('/maintenance/decluttarr', decluttarrStatus().toJson())
        ..getJson('/maintenance/recyclarr', recyclarrStatus().toJson())
        ..on(
          'POST',
          '/maintenance/recyclarr/sync',
          (_) => FakeResponse({
            'job': job(
              'j_sync0000001',
              status: JobStatus.running,
              kind: 'maintenance.recyclarr.sync',
              label: 'Run recyclarr sync',
            ).toJson(),
          }, status: 202),
        );
      serveJob(api, job('j_sync0000001', kind: 'maintenance.recyclarr.sync', label: 'Run recyclarr sync'));
      await pumpHubApp(tester, api: api, location: '/containers/maintenance');

      expect(find.text('Decluttarr'), findsOneWidget);
      expect(find.text('Queues are clean: nothing removed in the last 24 h'), findsOneWidget);
      expect(find.textContaining('every 10 min'), findsOneWidget);
      expect(find.textContaining('144 runs'), findsOneWidget);
      await scrollTo(tester, find.text('Sync now'));
      expect(find.textContaining('Sundays 04:00'), findsOneWidget);
      expect(find.text('hd-bluray-web (Radarr)'), findsOneWidget);
      expect(find.text('web-1080p (Sonarr)'), findsOneWidget);
      expect(find.text('7 custom format(s) already existed'), findsOneWidget);

      await tester.tap(find.text('Sync now'));
      await settle(tester);
      expect(find.text('Sync Recyclarr now?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Sync now').last);
      await settle(tester, frames: 10);
      expect(bodyOf(api.requestsTo('/maintenance/recyclarr/sync', method: 'POST').single), {'confirm': true});
      expect(find.text('Run recyclarr sync: done'), findsWidgets);
    });

    testWidgets('removals and strikes are listed; a failed card does not hide the other', (tester) async {
      final api = buildCoreFakeApi()
        ..getJson('/maintenance/decluttarr', decluttarrStatus(clean: false).toJson())
        ..on(
          'GET',
          '/maintenance/recyclarr',
          (_) => FakeResponse.error(503, ApiErrorCode.upstreamUnavailable, message: 'Docker is not reachable.'),
        );
      await pumpHubApp(tester, api: api, location: '/containers/maintenance');
      expect(find.text('Some.Show.S01E01'), findsOneWidget);
      expect(find.text('remove_stalled · torrent kept'), findsOneWidget);
      expect(find.text('Other.Show.S02E02'), findsOneWidget);
      expect(find.text('remove_stalled · 2/3'), findsOneWidget);
      await scrollTo(tester, find.textContaining('Docker is not reachable.'));
      expect(find.textContaining('Docker is not reachable.'), findsOneWidget);
    });

    testWidgets('members get no Sync now', (tester) async {
      final api = buildCoreFakeApi(role: Role.member)
        ..getJson('/maintenance/decluttarr', decluttarrStatus().toJson())
        ..getJson('/maintenance/recyclarr', recyclarrStatus().toJson());
      await pumpHubApp(tester, api: api, role: Role.member, location: '/containers/maintenance');
      await scrollTo(tester, find.text('web-1080p (Sonarr)'));
      expect(find.text('Sync now'), findsNothing);
    });
  });

  group('Dashboard card', () {
    testWidgets('running/total, problem chips, top CPU, Watchtower and Decluttarr lines', (tester) async {
      await pumpCard(
        tester,
        buildSection(
          ContainersCard(
            total: 21,
            running: 20,
            unhealthy: const ['jellystat'],
            stopped: const ['portainer'],
            updatesAvailable: 2,
            lastScan: const WatchtowerScan(scanned: 21, updated: 0, failed: 0, skipped: 0, restarted: 0, scansTotal: 0),
            topCpu: const [
              ContainerCpuUsage(name: 'jellyfin', cpuPercent: 41.5),
              ContainerCpuUsage(name: 'sonarr', cpuPercent: 3.04),
            ],
            decluttarr: ContainersCardDecluttarr(lastRunAt: testNow, removed24h: 0),
          ).toJson(),
        ),
      );
      expect(find.text('20'), findsOneWidget);
      expect(find.text('/ 21 running'), findsOneWidget);
      expect(find.text('jellystat'), findsOneWidget);
      expect(find.text('portainer'), findsOneWidget);
      expect(find.text('2 updates'), findsOneWidget);
      expect(find.text('jellyfin'), findsOneWidget);
      expect(find.text('41.5 %'), findsOneWidget);
      expect(find.text('Watchtower · no scan yet · 21 scanned'), findsOneWidget);
      expect(find.textContaining('Decluttarr · last run'), findsOneWidget);
      expect(find.textContaining('nothing removed (24 h)'), findsOneWidget);
      expect(find.bySemanticsLabel('All running'), findsNothing);
    });

    testWidgets('all running: a check mark and no chips', (tester) async {
      await pumpCard(tester, buildSection(const ContainersCard(total: 21, running: 21).toJson()));
      expect(find.text('21'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.byType(ActionChip), findsNothing);
    });

    testWidgets('the dashboard shows the card from GET /dashboard', (tester) async {
      final api = buildCoreFakeApi()
        ..getJson(
          '/dashboard',
          buildDashboardJson(
            cards: {
              ...rawCards(),
              DashboardCardKeys.containers: buildSection(
                const ContainersCard(total: 21, running: 19, unhealthy: ['jellystat']).toJson(),
              ).toJson(),
            },
          ),
        );
      await pumpHubApp(tester, api: api);
      await scrollTo(tester, find.text('/ 21 running'));
      expect(find.text('/ 21 running'), findsOneWidget);
      expect(find.text('jellystat'), findsOneWidget);
    });
  });

  test('usage history keeps two minutes of samples', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final sub = container.listen(containerUsageHistoryProvider('sonarr'), (_, _) {});
    addTearDown(sub.close);
    final n = container.read(containerUsageHistoryProvider('sonarr').notifier);
    final t0 = DateTime(2026, 11, 8, 9);
    n.add(summary('sonarr', cpu: 1), now: t0);
    n.add(summary('sonarr', cpu: 2), now: t0.add(const Duration(minutes: 1)));
    n.add(summary('sonarr', cpu: 3), now: t0.add(const Duration(minutes: 2, seconds: 1)));
    expect(container.read(containerUsageHistoryProvider('sonarr')).map((s) => s.cpuPercent), [2, 3]);
    n.add(summary('sonarr', state: ContainerState.exited), now: t0.add(const Duration(minutes: 3)));
    expect(container.read(containerUsageHistoryProvider('sonarr')), hasLength(2));
  });
}
