import 'dart:convert';

import 'package:dio/dio.dart' show RequestOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/routing/router.dart';
import 'package:yams_hub/features/containers/screens/containers_screen.dart';
import 'package:yams_hub/features/containers/widgets/container_visuals.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/fake_api.dart';
import '../../support/pump_hub_app.dart';
import 'containers_samples.dart';

String location(HubTestApp app) =>
    app.container.read(routerProvider).routerDelegate.currentConfiguration.uri.toString();

FakeApi containersApi({Role role = Role.admin}) => buildCoreFakeApi(role: role)
  ..getJson('/containers', containerList().toJson())
  ..getJson('/updates', updatesResponse().toJson());

JsonMap bodyOf(RequestOptions r) {
  final data = r.data;
  return data is String ? jsonDecode(data) as JsonMap : data as JsonMap;
}

/// The vertical list of the current screen.
final _vertical = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first;

Future<void> scrollTo(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 200, scrollable: _vertical);
  await settle(tester, frames: 2);
}

Future<void> tapVisible(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await settle(tester, frames: 2);
  await tester.tap(f);
  await settle(tester);
}

void main() {
  group('Containers list', () {
    testWidgets('summary, grouped rows, health chips and markers', (tester) async {
      final api = containersApi();
      await pumpHubApp(tester, api: api, location: '/containers');

      expect(find.text('6 / 7 running', findRichText: true), findsOneWidget);
      expect(find.text('Docker 29.4.3 · 114 images'), findsOneWidget);
      expect(find.text('Updates (1)'), findsOneWidget);
      expect(find.text('Maintenance'), findsOneWidget);
      for (final g in ['Media', 'Automation', 'Downloads']) {
        expect(find.text(g), findsOneWidget);
      }
      expect(find.text('jellystat'), findsOneWidget);
      expect(find.text('unhealthy'), findsOneWidget);
      expect(find.text('healthy'), findsOneWidget);
      expect(find.byTooltip('Update available'), findsOneWidget);
      await scrollTo(tester, find.byTooltip('Uses the network of gluetun'));
      expect(find.byTooltip('Uses the network of gluetun'), findsOneWidget);
      await scrollTo(tester, find.text('yams-hub'));
      expect(find.byTooltip('Protected'), findsOneWidget);
      expect(api.requestsTo('/containers'), isNotEmpty);
    });

    testWidgets('filter chips and search narrow the list', (tester) async {
      await pumpHubApp(tester, api: containersApi(), location: '/containers');
      await tapVisible(tester, find.widgetWithText(FilterChip, 'Unhealthy'));
      expect(find.text('jellystat'), findsOneWidget);
      expect(find.text('sonarr'), findsNothing);

      await tapVisible(tester, find.widgetWithText(FilterChip, 'Stopped'));
      expect(find.text('portainer'), findsOneWidget);
      expect(find.text('jellystat'), findsNothing);

      await tapVisible(tester, find.widgetWithText(FilterChip, 'All'));
      await tester.enterText(find.byType(TextField), 'qbit');
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);
      expect(find.text('qbittorrent'), findsOneWidget);
      expect(find.text('sonarr'), findsNothing);
    });

    testWidgets('group headers collapse', (tester) async {
      await pumpHubApp(tester, api: containersApi(), location: '/containers');
      expect(find.text('jellyfin'), findsOneWidget);
      await tester.tap(find.text('Media'));
      await settle(tester);
      expect(find.text('jellyfin'), findsNothing);
      await tester.tap(find.text('Media'));
      await settle(tester);
      expect(find.text('jellyfin'), findsOneWidget);
    });

    testWidgets('restart from the row menu starts a job and reports it', (tester) async {
      final api = containersApi();
      final j = job('j_restart00001');
      api.on(
        'POST',
        '/containers/sonarr/actions',
        (_) => FakeResponse({'job': job('j_restart00001', status: JobStatus.running).toJson()}, status: 202),
      );
      serveJob(api, j);
      await pumpHubApp(tester, api: api, location: '/containers');

      await tapVisible(tester, find.byTooltip('Actions for sonarr'));
      expect(find.text('Update'), findsOneWidget); // canUpdate + update available
      await tester.tap(find.text('Restart'));
      await settle(tester);
      // sonarr is not in the confirm list: no dialog.
      expect(find.byType(AlertDialog), findsNothing);
      final post = api.requestsTo('/containers/sonarr/actions', method: 'POST').single;
      expect(bodyOf(post), {'action': 'restart'});
      await settle(tester, frames: 10);
      expect(find.text('Restart sonarr: done'), findsWidgets);
    });

    testWidgets('stop asks first and sends confirm=true; gluetun warns about qBittorrent', (tester) async {
      final api = containersApi();
      api.on(
        'POST',
        '/containers/gluetun/actions',
        (_) =>
            FakeResponse({'job': job('j_stop0000001', label: 'Stop gluetun', target: 'gluetun').toJson()}, status: 202),
      );
      serveJob(api, job('j_stop0000001', label: 'Stop gluetun', target: 'gluetun'));
      await pumpHubApp(tester, api: api, location: '/containers');

      await tapVisible(tester, find.byTooltip('Actions for gluetun'));
      await tester.tap(find.text('Stop'));
      await settle(tester);
      expect(find.text('Stop gluetun?'), findsOneWidget);
      expect(find.text('qBittorrent will lose network until gluetun is back.'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await settle(tester);
      expect(api.requestsTo('/containers/gluetun/actions'), isEmpty);

      await tapVisible(tester, find.byTooltip('Actions for gluetun'));
      await tester.tap(find.text('Stop'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Stop'));
      await settle(tester);
      expect(bodyOf(api.requestsTo('/containers/gluetun/actions').single), {'action': 'stop', 'confirm': true});
    });

    testWidgets('locked containers show actions disabled as Protected', (tester) async {
      final api = containersApi();
      await pumpHubApp(tester, api: api, location: '/containers');
      await scrollTo(tester, find.byTooltip('Actions for yams-hub'));
      await tapVisible(tester, find.byTooltip('Actions for yams-hub'));
      expect(find.text('Protected'), findsNWidgets(2));
      expect(find.text('Restart'), findsOneWidget);
      expect(find.text('Logs'), findsOneWidget);
      await tester.tap(find.text('Restart'), warnIfMissed: false);
      await settle(tester);
      expect(api.requestsTo('/containers/yams-hub/actions'), isEmpty);
    });

    testWidgets('members get no admin actions', (tester) async {
      await pumpHubApp(
        tester,
        api: containersApi(role: Role.member),
        role: Role.member,
        location: '/containers',
      );
      expect(find.byTooltip('Actions for portainer'), findsNothing);
      // Web UI links stay available.
      await tapVisible(tester, find.byTooltip('Actions for sonarr'));
      expect(find.text('Open web UI'), findsOneWidget);
      expect(find.text('Restart'), findsNothing);
    });

    testWidgets('a failed first load says the Docker proxy is unreachable', (tester) async {
      final api = buildCoreFakeApi()
        ..on(
          'GET',
          '/containers',
          (_) => FakeResponse.error(503, ApiErrorCode.upstreamUnavailable, message: 'Docker is not reachable.'),
        )
        ..getJson('/updates', updatesResponse().toJson());
      await pumpHubApp(tester, api: api, location: '/containers');
      expect(find.text('Docker proxy unreachable'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('tapping a row opens the detail screen', (tester) async {
      final api = containersApi()..getJson('/containers/sonarr', detail('sonarr').toJson());
      final app = await pumpHubApp(tester, api: api, location: '/containers');
      await tester.tap(find.text('sonarr'));
      await settle(tester);
      expect(location(app), '/containers/sonarr');
    });
  });

  group('Container detail', () {
    testWidgets('header, usage, facts, health log output and events (admin)', (tester) async {
      final api = containersApi()..getJson('/containers/sonarr', detail('sonarr').toJson());
      await pumpHubApp(tester, api: api, location: '/containers/sonarr');
      expect(find.text('lscr.io/linuxserver/sonarr:latest'), findsOneWidget);
      expect(find.text('Running'), findsOneWidget);
      expect(find.text('3.0 %'), findsOneWidget);
      expect(find.text('Restart'), findsOneWidget);
      expect(find.text('Update'), findsOneWidget);
      await scrollTo(tester, find.text('unless-stopped'));
      expect(find.text('ae55f56fa15c'), findsOneWidget);
      expect(find.text('/config (rw)\n/etc/localtime (ro)'), findsOneWidget);
      await scrollTo(tester, find.text('checked http://sonarr:8989/api?apikey=*** ok'));
      expect(find.text('exit 1'), findsOneWidget);
      await scrollTo(tester, find.text('Exited (137)'));
      expect(find.text('Started'), findsWidgets);
    });

    testWidgets('gluetun shows the qbittorrent dependency hint', (tester) async {
      final api = containersApi()
        ..getJson(
          '/containers/gluetun',
          detail(
            'gluetun',
            s: summary(
              'gluetun',
              group: 'downloads',
              health: ContainerHealth.healthy,
              protection: ContainerProtection.confirm,
            ),
          ).toJson(),
        );
      await pumpHubApp(tester, api: api, location: '/containers/gluetun');
      expect(find.text('Restarting gluetun also restarts qbittorrent.'), findsOneWidget);
      expect(find.text('Asks first'), findsOneWidget);
    });

    testWidgets('restart of a confirm-list container asks first', (tester) async {
      final api = containersApi()
        ..getJson(
          '/containers/jellyfin',
          detail(
            'jellyfin',
            s: summary('jellyfin', group: 'media', protection: ContainerProtection.confirm),
          ).toJson(),
        )
        ..on(
          'POST',
          '/containers/jellyfin/actions',
          (_) => FakeResponse({'job': job('j_jf000000001', target: 'jellyfin').toJson()}, status: 202),
        );
      serveJob(api, job('j_jf000000001', target: 'jellyfin', label: 'Restart jellyfin'));
      await pumpHubApp(tester, api: api, location: '/containers/jellyfin');
      await tester.tap(find.widgetWithText(FilledButton, 'Restart'));
      await settle(tester);
      expect(find.text('Restart jellyfin?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Restart').last);
      await settle(tester);
      expect(bodyOf(api.requestsTo('/containers/jellyfin/actions').single), {'action': 'restart', 'confirm': true});
    });

    testWidgets('a job the hub no longer knows releases the buttons', (tester) async {
      final api = containersApi()
        ..getJson('/containers/sonarr', detail('sonarr').toJson())
        ..on(
          'POST',
          '/containers/sonarr/actions',
          (_) => FakeResponse({'job': job('j_lost00000001', status: JobStatus.running).toJson()}, status: 202),
        )
        ..on(
          'GET',
          '/jobs/j_lost00000001',
          (_) => FakeResponse.error(404, ApiErrorCode.notFound, message: 'No such job.'),
        );
      await pumpHubApp(tester, api: api, location: '/containers/sonarr');
      final restart = find.widgetWithText(FilledButton, 'Restart');
      await tester.tap(restart);
      await settle(tester, frames: 10);
      expect(find.text('Lost track of the job. Refresh to check the result.'), findsOneWidget);
      expect(tester.widget<FilledButton>(restart).onPressed, isNotNull);
    });

    testWidgets('locked: buttons disabled with the Protected note', (tester) async {
      final api = containersApi()
        ..getJson(
          '/containers/yams-hub',
          detail(
            'yams-hub',
            s: summary('yams-hub', group: 'system', protection: ContainerProtection.locked),
          ).toJson(),
        );
      await pumpHubApp(tester, api: api, location: '/containers/yams-hub');
      expect(find.text('Protected: the hub never stops, restarts or updates yams-hub.'), findsOneWidget);
      final restart = tester.widget<ButtonStyleButton>(
        find.ancestor(of: find.text('Restart'), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)),
      );
      expect(restart.onPressed, isNull);
    });

    testWidgets('members see no output, no actions and no logs button', (tester) async {
      final member = detail('sonarr');
      final json = member.toJson();
      json['healthLog'] = [for (final h in member.healthLog) (h.toJson()..remove('output'))];
      final api = containersApi(role: Role.member)..getJson('/containers/sonarr', json);
      await pumpHubApp(tester, api: api, role: Role.member, location: '/containers/sonarr');
      expect(find.text('Restart'), findsNothing);
      expect(find.byTooltip('Logs'), findsNothing);
      await scrollTo(tester, find.text('exit 1'));
      expect(find.textContaining('apikey'), findsNothing);
    });

    testWidgets('unknown container → not found', (tester) async {
      final api = containersApi()
        ..on(
          'GET',
          '/containers/nope',
          (_) => FakeResponse.error(404, ApiErrorCode.notFound, message: 'No such container.'),
        );
      await pumpHubApp(tester, api: api, location: '/containers/nope');
      expect(find.text('No such container.'), findsOneWidget);
    });
  });

  group('Logs', () {
    LogResponse logs() => LogResponse(
      lines: [
        LogLine(
          at: DateTime.utc(2026, 11, 8, 8, 17, 23),
          stream: ContainerLogStream.stderr,
          text: 'INFO    | Termination signal received',
        ),
        LogLine(
          at: DateTime.utc(2026, 11, 8, 8, 17, 24),
          stream: ContainerLogStream.stdout,
          text: 'Application Started!',
        ),
      ],
      truncated: true,
    );

    testWidgets('lines, tail selector, filter and follow', (tester) async {
      final api = containersApi()..getJson('/containers/decluttarr/logs', logs().toJson());
      await pumpHubApp(tester, api: api, location: '/containers/decluttarr/logs');
      expect(find.textContaining('Termination signal received'), findsOneWidget);
      expect(find.textContaining('Application Started!'), findsOneWidget);
      expect(find.text('Older lines are not shown (tail 200).'), findsOneWidget);
      expect(api.requestsTo('/containers/decluttarr/logs').single.uri.queryParameters, {
        'tail': '200',
        'stream': 'all',
      });

      await tester.tap(find.text('500'));
      await settle(tester);
      expect(api.requestsTo('/containers/decluttarr/logs').last.uri.queryParameters['tail'], '500');

      await tester.tap(find.text('stderr'));
      await settle(tester);
      expect(api.requestsTo('/containers/decluttarr/logs').last.uri.queryParameters['stream'], 'stderr');

      await tester.enterText(find.byType(TextField), 'started');
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);
      expect(find.textContaining('Termination'), findsNothing);
      expect(find.textContaining('Application Started!'), findsOneWidget);

      await tester.tap(find.byTooltip('Follow'));
      await settle(tester);
      final follow = api.requestsTo('/containers/decluttarr/logs').last.uri.queryParameters;
      expect(follow['since'], '2026-11-08T08:17:24Z');
      expect(find.byTooltip('Stop following'), findsOneWidget);
      await tester.tap(find.byTooltip('Stop following'));
      await settle(tester);
    });

    testWidgets('logs disabled on the proxy → empty view with the hint', (tester) async {
      final api = containersApi()
        ..on(
          'GET',
          '/containers/sonarr/logs',
          (_) => FakeResponse.error(
            503,
            ApiErrorCode.serviceNotConfigured,
            message: 'Logs need ALLOW_LOGS=1 on socket-proxy-hub.',
          ),
        );
      await pumpHubApp(tester, api: api, location: '/containers/sonarr/logs');
      expect(find.text('Logs need ALLOW_LOGS=1 on socket-proxy-hub.'), findsOneWidget);
    });

    testWidgets('members are redirected to the detail screen', (tester) async {
      final api = containersApi(role: Role.member)..getJson('/containers/sonarr', detail('sonarr').toJson());
      final app = await pumpHubApp(tester, api: api, role: Role.member, location: '/containers/sonarr/logs');
      expect(location(app), '/containers/sonarr');
      expect(api.requestsTo('/containers/sonarr/logs'), isEmpty);
    });
  });

  test('filterContainers and describeCron', () {
    final items = containerList().items;
    expect(filterContainers(items, ContainerFilter.updates, '').map((c) => c.name), ['sonarr']);
    expect(filterContainers(items, ContainerFilter.running, 'JELLY').map((c) => c.name), ['jellyfin', 'jellystat']);
    expect(describeCron('0 4 * * 0'), 'Sundays 04:00');
    expect(describeCron('30 3 * * *'), 'Daily 03:30');
    expect(describeCron('*/5 * * * *'), '*/5 * * * *');
  });
}
