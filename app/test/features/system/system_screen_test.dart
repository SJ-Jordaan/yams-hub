import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/routing/router.dart';
import 'package:yams_hub/features/system/widgets/service_health_card.dart';
import 'package:yams_hub/features/system/widgets/system_format.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/fake_api.dart';
import '../../support/pump_hub_app.dart';
import 'system_samples.dart';

/// Tall enough that the whole list is built on a phone-width screen.
const _tallPhone = Size(400, 3200);

String _location(HubTestApp app) =>
    app.container.read(routerProvider).routerDelegate.currentConfiguration.uri.toString();

void main() {
  testWidgets('shows host, storage, network, uptime and service health', (tester) async {
    final api = buildCoreFakeApi();
    serveSystem(api);
    await pumpHubApp(tester, api: api, location: '/system', size: _tallPhone);

    // Host.
    expect(find.text('System'), findsWidgets);
    expect(find.textContaining('Intel(R) N100 · 4 cores · up 2h 52m'), findsOneWidget);
    expect(find.byKey(const Key('system.cpuPercent')), findsOneWidget);
    expect(find.text('22 %'), findsOneWidget);
    expect(find.text('Load 0.60 · 0.86 · 1.02'), findsOneWidget);
    expect(find.text('C3'), findsOneWidget);
    expect(find.text('Package 68 °C'), findsOneWidget);
    expect(find.text('Cores 65 / 66 / 63 / 65 °C'), findsOneWidget);
    expect(find.text('Memory'), findsOneWidget);
    expect(find.text('Swap'), findsOneWidget);
    // Charts (explicit text styles; fl_chart renders them).
    expect(find.byKey(const Key('system.chart.cpu')), findsOneWidget);
    expect(find.byKey(const Key('system.chart.temperature')), findsOneWidget);
    expect(find.byKey(const Key('system.chart.netRx')), findsOneWidget);
    expect(find.byKey(const Key('system.chart.diskRead')), findsOneWidget);
    final history = api.requestsTo('/system/history');
    expect(
      {for (final r in history) r.uri.queryParameters['metric']},
      {'cpu', 'temperature', 'netRx', 'netTx', 'diskRead', 'diskWrite'},
    );
    expect({for (final r in history) r.uri.queryParameters['range']}, {'1h'});

    // Storage.
    expect(find.text('/volume1'), findsOneWidget);
    expect(find.textContaining('3.5 TiB / 7.2 TiB · 49 %'), findsOneWidget);
    expect(find.text('RAID0 · md1 · active · sda2 + sdb2'), findsOneWidget);
    expect(find.text(noRedundancyText), findsOneWidget);
    expect(find.textContaining('read 102 kB/s · write 5 MB/s'), findsOneWidget);

    // Network.
    expect(find.byKey(const Key('system.iface.eth0')), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(const Key('system.iface.eth0')), matching: find.text('120 kB/s')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byKey(const Key('system.iface.eth0')), matching: find.text('2.4 MB/s')),
      findsOneWidget,
    );
    expect(find.text('Idle'), findsOneWidget);

    // Uptime.
    expect(find.text('3/4 up'), findsOneWidget);
    expect(find.text('Media'), findsWidgets);
    expect(find.text('jellyfin web'), findsOneWidget);
    expect(find.text('4 ms'), findsWidgets);
    expect(find.text('99.6 %'), findsOneWidget);
    expect(find.text('89.6 %'), findsOneWidget);
    expect(find.byKey(const Key('system.incident')), findsNothing);

    // Service health.
    expect(find.text('Service health'), findsOneWidget);
    expect(find.byKey(const Key('system.health.sonarr')), findsOneWidget);
  });

  testWidgets('health rows open the related screen (shelfmark → /media/shelfmark)', (tester) async {
    final api = buildCoreFakeApi();
    serveSystem(api);
    final app = await pumpHubApp(tester, api: api, location: '/system', size: _tallPhone);
    await tester.tap(find.byKey(const Key('system.health.shelfmark')));
    await settle(tester);
    expect(_location(app), '/media/shelfmark');
  });

  test('health tap targets', () {
    expect(systemHealthRoute(ServiceId.shelfmark), '/media/shelfmark');
    expect(systemHealthRoute(ServiceId.sonarr), '/library?tab=tv');
    expect(systemHealthRoute(ServiceId.radarr), '/library?tab=movies');
    expect(systemHealthRoute(ServiceId.qbittorrent), '/activity');
    expect(systemHealthRoute(ServiceId.gluetun), '/activity');
    expect(systemHealthRoute(ServiceId.prowlarr), '/indexers');
    expect(systemHealthRoute(ServiceId.bazarr), '/subtitles');
    expect(systemHealthRoute(ServiceId.seerr), '/requests');
    expect(systemHealthRoute(ServiceId.jellyfin), '/media/jellyfin');
    expect(systemHealthRoute(ServiceId.audiobookshelf), '/media/audiobooks');
    expect(systemHealthRoute(ServiceId.kavita), '/media/books');
    expect(systemHealthRoute(ServiceId.docker), '/containers');
    expect(systemHealthRoute(ServiceId.watchtower), '/containers/updates');
    expect(systemHealthRoute(ServiceId.uptimeKuma), isNull);
    expect(systemHealthRoute(ServiceId.host), isNull);
  });

  testWidgets('the 24 h toggle reloads the charts', (tester) async {
    final api = buildCoreFakeApi();
    serveSystem(api);
    await pumpHubApp(tester, api: api, location: '/system', size: _tallPhone);
    final before = api.requestsTo('/system/history').length;
    await tester.tap(find.text('24 h'));
    await settle(tester);
    final after = api.requestsTo('/system/history').skip(before).toList();
    expect(after, isNotEmpty);
    expect({for (final r in after) r.uri.queryParameters['range']}, {'24h'});
  });

  testWidgets('missing sources show their notes', (tester) async {
    final api = buildCoreFakeApi();
    serveSystem(api, host: buildHostMetrics(temperature: false, hostNetwork: false));
    await pumpHubApp(tester, api: api, location: '/system', size: _tallPhone);
    expect(find.text(temperatureUnavailableText), findsNWidgets(2)); // host card + chart
    expect(find.text(hostNetworkUnavailableText), findsNWidgets(2)); // network card + chart
    expect(find.byKey(const Key('system.chart.netRx')), findsNothing);
    expect(api.requestsTo('/system/history').where((r) => r.uri.queryParameters['metric'] == 'temperature'), isEmpty);
  });

  testWidgets('RAID not active: red banner; incident and down monitor', (tester) async {
    final api = buildCoreFakeApi();
    serveSystem(
      api,
      host: buildHostMetrics(raidHealthy: false, tailscaleBps: 5000),
      uptime: buildUptime(incident: true, gluetunDown: true),
    );
    await pumpHubApp(tester, api: api, location: '/system', size: _tallPhone);
    expect(find.byKey(const Key('system.raidBanner.md1')), findsOneWidget);
    expect(find.textContaining('md1 is inactive'), findsOneWidget);
    expect(find.text('RAID0 · md1 · inactive · sda2 + sdb2'), findsOneWidget);
    expect(find.text('Remote use'), findsOneWidget);
    expect(find.byKey(const Key('system.incident')), findsOneWidget);
    expect(find.text('VPN switch'), findsOneWidget);
    expect(find.text('2/4 up · 1 down'), findsOneWidget);
  });

  testWidgets('first-load errors per card, with retry', (tester) async {
    final api = buildCoreFakeApi()
      ..on('GET', '/system/host', (_) => FakeResponse.error(503, ApiErrorCode.upstreamUnavailable, message: 'Hub busy'))
      ..on(
        'GET',
        '/uptime',
        (_) => FakeResponse.error(503, ApiErrorCode.serviceNotConfigured, message: 'Uptime Kuma is not configured'),
      );
    await pumpHubApp(tester, api: api, location: '/system', size: _tallPhone);
    expect(find.textContaining('Hub busy'), findsOneWidget);
    expect(find.text('Not configured on the hub'), findsOneWidget);
    expect(find.text('Storage'), findsNothing);

    serveSystem(api);
    await tester.tap(find.text('Retry').first);
    await settle(tester);
    expect(find.text('Storage'), findsOneWidget);
    expect(find.textContaining('Hub busy'), findsNothing);
  });

  testWidgets('a failed refresh keeps the data and shows the stale banner', (tester) async {
    final api = buildCoreFakeApi();
    serveSystem(api);
    await pumpHubApp(tester, api: api, location: '/system', size: _tallPhone);
    expect(find.text('22 %'), findsOneWidget);
    final before = api.requestsTo('/system/host').length;
    api.on('GET', '/system/host', (_) => const FakeResponse.fail(DioExceptionType.connectionError));
    // Pull-to-refresh (the indicator's own trigger; charts own drag gestures).
    unawaited(tester.state<RefreshIndicatorState>(find.byType(RefreshIndicator)).show());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(api.requestsTo('/system/host').length, greaterThan(before));
    expect(find.text('22 %'), findsOneWidget);
    expect(find.textContaining("Couldn't refresh"), findsOneWidget);
  });

  testWidgets('loading state shows skeletons', (tester) async {
    final api = buildCoreFakeApi();
    serveSystem(api);
    final slow = api;
    slow.on('GET', '/system/host', (_) async {
      await Future<void>.delayed(const Duration(seconds: 2));
      return FakeResponse(buildHostMetrics().toJson());
    });
    await pumpHubApp(tester, api: slow, location: '/system', size: _tallPhone);
    expect(find.text('Host'), findsOneWidget);
    expect(find.text('22 %'), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    expect(find.text('22 %'), findsOneWidget);
  });

  testWidgets('two columns on wide screens without overflow', (tester) async {
    final api = buildCoreFakeApi();
    serveSystem(api);
    await pumpHubApp(tester, api: api, location: '/system', size: const Size(1400, 2400));
    expect(tester.takeException(), isNull);
    final host = tester.getTopLeft(find.text('Host'));
    final storage = tester.getTopLeft(find.text('Storage'));
    expect(storage.dx, greaterThan(host.dx + 300));
  });
}
