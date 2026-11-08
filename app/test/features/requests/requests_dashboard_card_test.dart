import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/auth/token_manager.dart';
import 'package:yams_hub/core/servers/server_connection.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/features/requests/requests_dashboard_card.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/builders.dart';
import '../../support/pump_hub_app.dart';
import 'requests_samples.dart';

Future<void> _pumpCard(WidgetTester tester, Section section, {bool admin = true}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        activeServerProvider.overrideWith(
          () => ActiveServerController(
            fixed: ServerConnection(
              status: ConnectionStatus.connected,
              profile: buildProfile(),
              baseUrl: testLanUrl,
              ping: buildPing(),
            ),
          ),
        ),
        accessTokenProvider.overrideWithValue('yha_access1'),
        isAdminProvider.overrideWithValue(admin),
      ],
      child: MaterialApp(
        theme: buildHubTheme(ColorScheme.fromSeed(seedColor: const Color(0xFF7C4DFF), brightness: Brightness.dark)),
        home: Scaffold(
          body: SingleChildScrollView(child: RequestsDashboardCard(section: section)),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('admin: counters and the requests waiting for approval', (tester) async {
    await _pumpCard(
      tester,
      buildSection(
        RequestsCard(
          counts: counts,
          pending: [
            request(201),
            request(202, title: 'The Matrix', type: MediaType.movie, tmdbId: 603),
          ],
          recent: [request(197, title: 'Gachiakuta')],
          openIssues: 2,
        ).toJson(),
      ),
    );
    // APP.md §3.3: pending · processing · available (+ failed, issues).
    for (final label in ['Pending', 'Processing', 'Available', 'Failed', 'Issues']) {
      expect(find.text(label), findsWidgets, reason: label);
    }
    expect(find.text('Waiting for approval'), findsOneWidget);
    expect(find.text('True Blood (2008)'), findsOneWidget);
    expect(find.text('The Matrix (2008)'), findsOneWidget);
    expect(find.text('Gachiakuta (2008)'), findsNothing);
    // Admins approve / decline inline; nothing else is offered on the card.
    expect(find.byTooltip('Approve'), findsNWidgets(2));
    expect(find.byTooltip('Decline'), findsNWidgets(2));
    expect(find.byTooltip('More'), findsNothing);
  });

  testWidgets('admin: up to 5 pending rows', (tester) async {
    await _pumpCard(
      tester,
      buildSection(
        RequestsCard(
          counts: const RequestCounts(total: 7, pending: 7),
          pending: [for (var i = 0; i < 5; i++) request(300 + i, title: 'Pending $i')],
        ).toJson(),
      ),
    );
    for (var i = 0; i < 5; i++) {
      expect(find.text('Pending $i (2008)'), findsOneWidget);
    }
    expect(find.text('All 7 pending requests'), findsOneWidget);
  });

  testWidgets('member: own latest requests, no pending counter', (tester) async {
    await _pumpCard(
      tester,
      buildSection(
        RequestsCard(
          counts: counts,
          recent: [
            request(
              196,
              title: 'The Legend of Korra',
              status: RequestStatus.completed,
              availability: Availability.available,
            ),
          ],
        ).toJson(),
      ),
      admin: false,
    );
    expect(find.text('Your latest requests'), findsOneWidget);
    expect(find.text('The Legend of Korra (2008)'), findsOneWidget);
    // The counter and the row's status chip.
    expect(find.text('Available'), findsNWidgets(2));
    expect(find.text('Failed'), findsNothing);
    expect(find.byTooltip('Approve'), findsNothing);
  });

  testWidgets('partial data (raw counts only) still renders', (tester) async {
    await _pumpCard(
      tester,
      buildSection({
        'counts': {'pending': 3, 'processing': 1},
      }),
    );
    expect(find.text('3'), findsOneWidget);
    expect(find.text('No requests waiting'), findsOneWidget);
  });

  testWidgets('the dashboard shows the card with its title', (tester) async {
    await pumpHubApp(tester, location: '/home');
    expect(find.text('Requests'), findsWidgets);
  });

  testWidgets('approving from the card posts and refreshes the card', (tester) async {
    final card = buildSection(RequestsCard(counts: counts, pending: [request(201)]).toJson()).toJson();
    final api = buildCoreFakeApi()
      ..getJson('/dashboard', buildDashboardJson(cards: {...rawCards(), DashboardCardKeys.requests: card}))
      ..postJson('/requests/201/approve', request(201, status: RequestStatus.approved).toJson());
    await pumpHubApp(tester, api: api, location: '/home');
    final approve = find.byTooltip('Approve');
    await tester.ensureVisible(approve);
    await settle(tester);
    final before = api.requestsTo('/dashboard').length;
    await tester.tap(approve);
    await settle(tester);
    expect(api.requestsTo('/requests/201/approve', method: 'POST'), hasLength(1));
    expect(find.text('Approved · sent to Sonarr'), findsOneWidget);
    final reloads = api.requestsTo('/dashboard').skip(before);
    expect(reloads.map((r) => r.uri.queryParameters['cards']), contains(DashboardCardKeys.requests));
  });
}
