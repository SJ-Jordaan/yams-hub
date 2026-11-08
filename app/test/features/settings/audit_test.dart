import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/fake_api.dart';
import '../../support/pump_hub_app.dart';
import 'settings_fixtures.dart';

FakeApi auditApi(List<AuditEntry> Function(Map<String, String> query) entries) => settingsFakeApi()
  ..on('GET', '/admin/audit', (r) {
    final q = r.uri.queryParameters;
    final items = entries(q);
    return FakeResponse(
      PagedList<AuditEntry>.of(
        items: items,
        page: int.parse(q['page'] ?? '1'),
        pageSize: 50,
        total: items.length,
      ).toJson((e) => e.toJson()),
    );
  });

void main() {
  final entries = [
    auditEntry(
      'a1',
      'library.tv.delete',
      target: 'series:54',
      params: {'deleteFiles': true, 'confirm': true},
    ),
    auditEntry('a2', 'containers.restart', target: 'sonarr', outcome: AuditOutcome.error, errorCode: 'policy_denied'),
  ];

  testWidgets('lists entries with outcome chips', (tester) async {
    await pumpHubApp(tester, api: auditApi((_) => entries), location: '/settings/audit');
    expect(find.text('library.tv.delete'), findsOneWidget);
    expect(find.text('ada · series:54'), findsOneWidget);
    expect(find.text('OK'), findsOneWidget);
    expect(find.text('policy_denied'), findsOneWidget);
    expect(find.text('5 min ago'), findsNWidgets(2));
  });

  testWidgets('action and outcome filters go to the gateway', (tester) async {
    final api = auditApi((q) => q['action'] == 'library.' ? [entries.first] : entries);
    await pumpHubApp(tester, api: api, location: '/settings/audit');

    final library = find.widgetWithText(FilterChip, 'library');
    await tester.ensureVisible(library);
    await tester.pumpAndSettle();
    await tester.tap(library);
    await settle(tester);
    expect(api.requestsTo('/admin/audit').last.uri.queryParameters['action'], 'library.');
    expect(find.text('containers.restart'), findsNothing);

    await tester.tap(find.widgetWithText(FilterChip, 'Failed'));
    await settle(tester);
    expect(api.requestsTo('/admin/audit').last.uri.queryParameters, containsPair('outcome', 'error'));

    await tester.tap(find.text('Clear filters'));
    await settle(tester);
    expect(api.requestsTo('/admin/audit').last.uri.queryParameters, {'page': '1', 'pageSize': '50'});
  });

  testWidgets('typed action prefixes are sent on submit', (tester) async {
    final api = auditApi((_) => entries);
    await pumpHubApp(tester, api: api, location: '/settings/audit');
    await tester.enterText(find.byKey(const Key('audit-action')), 'auth.login');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await settle(tester);
    expect(api.requestsTo('/admin/audit').last.uri.queryParameters['action'], 'auth.login');
  });

  testWidgets('tapping a row shows its params as JSON', (tester) async {
    await pumpHubApp(tester, api: auditApi((_) => entries), location: '/settings/audit');
    await tester.tap(find.text('library.tv.delete'));
    await settle(tester);
    final params = tester.widget<SelectableText>(find.byKey(const Key('audit-params')));
    expect(params.data, contains('"deleteFiles": true'));
    expect(find.text('42 ms'), findsOneWidget);
  });

  testWidgets('empty log', (tester) async {
    await pumpHubApp(tester, api: auditApi((_) => const []), location: '/settings/audit');
    expect(find.text('No audit entries yet'), findsOneWidget);
  });
}
