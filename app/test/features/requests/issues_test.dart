import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/fake_api.dart';
import '../../support/pump_hub_app.dart';
import 'requests_samples.dart';

final _comments = [
  IssueComment(
    id: 21,
    message: 'Audio out of sync from 12:30',
    author: const IssueUser(id: 2, displayName: 'Zenith Greyrat'),
    createdAt: DateTime.utc(2026, 11, 7, 19),
  ),
  IssueComment(
    id: 22,
    message: 'Looking into it',
    author: const IssueUser(id: 1, displayName: 'Paul Greyrat'),
    createdAt: DateTime.utc(2026, 11, 7, 20),
  ),
];

FakeApi _api({Role role = Role.admin, JsonMap? me}) {
  final api = buildCoreFakeApi(role: role);
  if (me != null) api.getJson('/auth/me', me);
  api.on('GET', '/issues', (r) {
    final filter = r.uri.queryParameters['filter'];
    final items = switch (filter) {
      'open' => [issue(11), issue(12, commentCount: 0, by: const IssueUser(id: 1, displayName: 'Paul Greyrat'))],
      'resolved' => [issue(13, status: IssueStatus.resolved)],
      _ => <Issue>[],
    };
    return FakeResponse(
      PagedList.of(items: items, page: 1, pageSize: 25, total: items.length).toJson((i) => i.toJson()),
    );
  });
  return api;
}

void main() {
  testWidgets('list: open by default, comment counts, S2E5, filter chips', (tester) async {
    final api = _api();
    await pumpHubApp(tester, api: api, location: '/requests/issues');
    expect(api.requestsTo('/issues').first.uri.queryParameters['filter'], 'open');
    expect(find.text('True Blood'), findsNWidgets(2));
    expect(find.text('S2E5'), findsNWidgets(2));
    expect(find.text('2'), findsOneWidget, reason: 'commentCount of #11');
    expect(find.textContaining('Zenith Greyrat ·'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, 'Resolved'));
    await settle(tester);
    expect(api.requestsTo('/issues').last.uri.queryParameters['filter'], 'resolved');
    expect(find.text('Resolved'), findsWidgets);
  });

  testWidgets('empty list', (tester) async {
    final api = buildCoreFakeApi()
      ..getJson(
        '/issues',
        PagedList<Issue>.of(items: const [], page: 1, pageSize: 25, total: 0).toJson((i) => i.toJson()),
      );
    await pumpHubApp(tester, api: api, location: '/requests/issues');
    expect(find.text('No open issues'), findsOneWidget);
  });

  testWidgets('unlinked members read the list but are told to link', (tester) async {
    final api = _api(role: Role.member, me: linkedMe(linked: false));
    await pumpHubApp(tester, api: api, role: Role.member, location: '/requests/issues');
    expect(find.text('Link your account to Seerr to comment'), findsOneWidget);
    expect(find.text('True Blood'), findsWidgets);
  });

  testWidgets('detail: thread, comment as the user, creator can resolve', (tester) async {
    final api = _api(role: Role.member, me: linkedMe())
      ..getJson('/issues/11', issue(11, comments: _comments).toJson())
      ..on('POST', '/issues/11/comments', (r) {
        final body = r.data is String ? jsonDecode(r.data as String) : r.data;
        return FakeResponse(
          issue(
            11,
            comments: [
              ..._comments,
              IssueComment(
                id: 23,
                message: (body as Map)['message'] as String,
                author: const IssueUser(id: 2, displayName: 'Zenith Greyrat'),
                createdAt: DateTime.utc(2026, 11, 8, 8),
              ),
            ],
          ).toJson(),
        );
      })
      ..postJson('/issues/11/resolve', issue(11, status: IssueStatus.resolved, comments: _comments).toJson());
    await pumpHubApp(tester, api: api, role: Role.member, location: '/requests/issues/11');

    expect(find.text('Audio out of sync from 12:30'), findsOneWidget);
    expect(find.text('Looking into it'), findsOneWidget);
    expect(find.text('Reported by Zenith Greyrat · 1 day ago'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Add a comment'), 'Still happening on S2E6');
    await tester.tap(find.byTooltip('Send'));
    await settle(tester);
    expect(api.requestsTo('/issues/11/comments', method: 'POST'), hasLength(1));
    expect(find.text('Still happening on S2E6'), findsOneWidget);

    // The member created #11, so they may resolve it.
    await tester.tap(find.widgetWithText(TextButton, 'Resolve'));
    await settle(tester);
    expect(api.requestsTo('/issues/11/resolve', method: 'POST'), hasLength(1));
    expect(find.widgetWithText(TextButton, 'Reopen'), findsOneWidget);
    expect(find.text('Issue resolved'), findsOneWidget);
  });

  testWidgets("members cannot resolve someone else's issue; a 403 is explained", (tester) async {
    final api = _api(role: Role.member, me: linkedMe())
      ..getJson('/issues/12', issue(12, by: const IssueUser(id: 1, displayName: 'Paul Greyrat')).toJson());
    await pumpHubApp(tester, api: api, role: Role.member, location: '/requests/issues/12');
    expect(find.widgetWithText(TextButton, 'Resolve'), findsNothing);

    final admin = _api()
      ..getJson('/issues/12', issue(12, by: const IssueUser(id: 3, displayName: 'Rudeus')).toJson())
      ..on(
        'POST',
        '/issues/12/resolve',
        (_) => FakeResponse.error(403, ApiErrorCode.forbidden, message: 'Only the reporter or an admin can do that.'),
      );
    await pumpHubApp(tester, api: admin, location: '/requests/issues/12');
    await tester.tap(find.widgetWithText(TextButton, 'Resolve'));
    await settle(tester);
    expect(find.text('Only the reporter or an admin can do that.'), findsOneWidget);
  });
}
