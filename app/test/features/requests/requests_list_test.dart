import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/features/requests/data/requests_api.dart';
import 'package:yams_hub/features/requests/providers/requests_providers.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/fake_api.dart';
import '../../support/pump_hub_app.dart';
import 'requests_samples.dart';

FakeApi _api({Role role = Role.admin}) {
  final api = buildCoreFakeApi(role: role)..getJson('/requests/counts', counts.toJson());
  api.on('GET', '/requests', (r) {
    final q = r.uri.queryParameters;
    final items = switch ((q['filter'], q['mine'])) {
      ('pending', _) => [request(201), request(202, title: 'The Matrix', type: MediaType.movie, tmdbId: 603)],
      ('failed', _) => [request(189, title: 'Fringe', status: RequestStatus.failed, availability: Availability.none)],
      (_, 'true') => [
        request(
          196,
          title: 'The Legend of Korra',
          status: RequestStatus.completed,
          availability: Availability.available,
          admin: role == Role.admin,
          libraryId: 163,
        ),
      ],
      _ => <RequestSummary>[],
    };
    return FakeResponse(requestPage(items));
  });
  return api;
}

void main() {
  testWidgets('admin: tabs with counts, pending rows with approve / decline', (tester) async {
    final api = _api()..postJson('/requests/201/approve', request(201, status: RequestStatus.approved).toJson());
    await pumpHubApp(tester, api: api, location: '/requests/list?tab=pending');

    expect(find.text('Pending (2)'), findsOneWidget);
    expect(find.text('Failed (1)'), findsOneWidget);
    expect(find.text('True Blood (2008)'), findsOneWidget);
    expect(find.text('S4 S5'), findsOneWidget);
    expect(find.textContaining('Zenith Greyrat · '), findsWidgets);
    expect(api.requestsTo('/requests').first.uri.queryParameters['filter'], 'pending');

    await tester.tap(find.byTooltip('Approve').first);
    await settle(tester);
    expect(api.requestsTo('/requests/201/approve', method: 'POST'), hasLength(1));
    expect(find.text('Approved · sent to Sonarr'), findsOneWidget);
  });

  testWidgets('decline asks first; cancelling sends nothing', (tester) async {
    final api = _api()..postJson('/requests/202/decline', request(202, status: RequestStatus.declined).toJson());
    await pumpHubApp(tester, api: api, location: '/requests/list?tab=pending');
    await tester.tap(find.byTooltip('Decline').last);
    await settle(tester);
    expect(find.text('Decline request?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(api.requestsTo('/requests/202/decline'), isEmpty);

    await tester.tap(find.byTooltip('Decline').last);
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Decline'));
    await settle(tester);
    expect(api.requestsTo('/requests/202/decline', method: 'POST'), hasLength(1));
  });

  testWidgets('swipe right approves on phones', (tester) async {
    final api = _api()..postJson('/requests/201/approve', request(201, status: RequestStatus.approved).toJson());
    await pumpHubApp(tester, api: api, location: '/requests/list?tab=pending');
    await tester.drag(find.text('True Blood (2008)'), const Offset(500, 0));
    await settle(tester);
    expect(api.requestsTo('/requests/201/approve', method: 'POST'), hasLength(1));
  });

  testWidgets('failed tab offers Retry', (tester) async {
    final api = _api()
      ..postJson('/requests/189/retry', request(189, title: 'Fringe', status: RequestStatus.approved).toJson());
    await pumpHubApp(tester, api: api, location: '/requests/list?tab=failed');
    expect(find.text('Fringe (2008)'), findsOneWidget);
    expect(find.text('Failed'), findsWidgets);
    await tester.tap(find.byTooltip('Retry'));
    await settle(tester);
    expect(api.requestsTo('/requests/189/retry', method: 'POST'), hasLength(1));
    expect(find.text('Retrying · sent to Sonarr'), findsOneWidget);
  });

  testWidgets('delete asks first and sends confirm=true', (tester) async {
    final api = _api()..on('DELETE', '/requests/201', (_) => const FakeResponse.noContent());
    await pumpHubApp(tester, api: api, location: '/requests/list?tab=pending');
    await tester.tap(find.byTooltip('More').first);
    await settle(tester);
    await tester.tap(find.text('Delete'));
    await settle(tester);
    expect(find.text('Nothing is removed from the library.'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await settle(tester);
    final call = api.requestsTo('/requests/201', method: 'DELETE').single;
    expect(call.uri.queryParameters['confirm'], 'true');
    expect(find.text('Request deleted'), findsOneWidget);
  });

  testWidgets('members only see "My requests", without admin actions', (tester) async {
    final api = _api(role: Role.member);
    await pumpHubApp(tester, api: api, role: Role.member, location: '/requests/list?tab=pending');
    expect(find.text('My requests'), findsOneWidget);
    expect(find.byType(TabBar), findsNothing);
    expect(find.text('The Legend of Korra (2008)'), findsOneWidget);
    expect(find.byTooltip('Approve'), findsNothing);
    expect(api.requestsTo('/requests').single.uri.queryParameters['mine'], 'true');
  });

  testWidgets('empty Mine tab links to Discover', (tester) async {
    final api = buildCoreFakeApi(role: Role.member)
      ..getJson('/requests', requestPage(const []))
      ..getJson('/requests/counts', counts.toJson());
    await pumpHubApp(tester, api: api, role: Role.member, location: '/requests/list');
    expect(find.text("You haven't requested anything yet"), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Discover'), findsOneWidget);
  });

  testWidgets('loads more pages as the list scrolls', (tester) async {
    final api = buildCoreFakeApi()..getJson('/requests/counts', counts.toJson());
    api.on('GET', '/requests', (r) {
      final p = int.parse(r.uri.queryParameters['page']!);
      return FakeResponse(
        PagedList.of(
          items: [for (var i = 0; i < 25; i++) request(p * 100 + i, title: 'Title ${p * 100 + i}')],
          page: p,
          pageSize: 25,
          total: 40,
        ).toJson((r) => r.toJson()),
      );
    });
    await pumpHubApp(tester, api: api, location: '/requests/list?tab=all');
    await tester.drag(find.byType(ListView).last, const Offset(0, -5000));
    await settle(tester);
    expect(api.requestsTo('/requests').map((r) => r.uri.queryParameters['page']), containsAll(['1', '2']));
  });

  testWidgets('detail: seasons, Open in Library, admin actions', (tester) async {
    final api = _api()
      ..getJson(
        '/requests/196',
        request(
          196,
          title: 'The Legend of Korra',
          status: RequestStatus.approved,
          availability: Availability.partial,
          libraryId: 163,
          seasons: const [
            RequestSeason(seasonNumber: 1, status: RequestStatus.completed),
            RequestSeason(seasonNumber: 2, status: RequestStatus.approved),
          ],
        ).toJson(),
      );
    await pumpHubApp(tester, api: api, location: '/requests/list/196');
    expect(find.text('The Legend of Korra'), findsWidgets);
    expect(find.text('S1 · Completed'), findsOneWidget);
    expect(find.text('S2 · Approved'), findsOneWidget);
    expect(find.text('Partially available'), findsWidgets);
    expect(find.text('Delete'), findsOneWidget);
    await tester.tap(find.text('Open in Library'));
    await settle(tester);
    final router = GoRouter.of(tester.element(find.byType(Scaffold).last));
    expect(router.routerDelegate.currentConfiguration.uri.path, '/library/tv/163');
  });

  testWidgets('the counts provider maps tabs to filters', (tester) async {
    expect(RequestsTab.visible(isAdmin: false), [RequestsTab.mine]);
    expect(RequestsTab.visible(isAdmin: true), RequestsTab.values);
    expect(RequestsTab.pending.filter, RequestsFilter.pending);
    expect(RequestsTab.mine.mineOnly, isTrue);
    expect(RequestsTab.fromName('failed'), RequestsTab.failed);
    expect(RequestsTab.fromName('bogus'), isNull);
  });
}
