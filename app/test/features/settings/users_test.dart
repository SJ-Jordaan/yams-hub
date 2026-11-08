import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/fake_api.dart';
import '../../support/pump_hub_app.dart';
import 'settings_fixtures.dart';

Finder fieldIn(String key) => find.descendant(of: find.byKey(Key(key)), matching: find.byType(TextField));

void main() {
  group('users list', () {
    testWidgets('shows roles, links, disabled state and Seerr chips', (tester) async {
      await pumpHubApp(tester, api: settingsFakeApi(), location: '/settings/users');

      expect(find.text('Ada (you)'), findsOneWidget);
      expect(find.text('@bob · Jellyfin: bob'), findsOneWidget);
      expect(find.text('Disabled'), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(const Key('user-$carolId-issue')), matching: find.text('No Seerr account')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: find.byKey(const Key('user-$daveId-issue')), matching: find.text('No Jellyfin link')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('user-$bobId-issue')), findsNothing);
      expect(find.byKey(const Key('user-$adaId-issue')), findsNothing);
      expect(find.textContaining('1 user has no Seerr account'), findsOneWidget);
    });

    testWidgets('without the Jellyfin users the list still shows, with a banner', (tester) async {
      final api = buildCoreFakeApi()
        ..getJson('/admin/users', itemList(sampleUsers().map((u) => u.toJson())))
        ..on('GET', '/admin/jellyfin-users', (_) => FakeResponse.error(503, ApiErrorCode.upstreamUnavailable));
      await pumpHubApp(tester, api: api, location: '/settings/users');
      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('@bob · Jellyfin: linked'), findsOneWidget);
      expect(find.textContaining('Unknown Jellyfin user'), findsNothing);
      expect(find.textContaining("Couldn't load Jellyfin users"), findsOneWidget);
      expect(find.text('No Seerr account'), findsNothing);
    });
  });

  group('user editor', () {
    testWidgets('creates a member with a Jellyfin link', (tester) async {
      final created = hubUser('u_e7e7e7e7e7e7', 'Eve', jellyfinUserId: jfEve);
      final api = settingsFakeApi()..postJson('/admin/users', created.toJson(), status: 201);
      await pumpHubApp(tester, api: api, location: '/settings/users/new');

      expect(find.text('Add user'), findsWidgets);
      await tester.enterText(find.byKey(const Key('user-username')), 'eve');
      await tester.enterText(find.byKey(const Key('user-display-name')), 'Eve');
      await tester.enterText(fieldIn('user-password'), 'correct horse battery');
      await tester.pump();

      await tapInList(tester, find.text('None'));
      await tester.tap(find.text('eve (Jellyfin admin)').last);
      await settle(tester);
      expect(find.byKey(const Key('seerr-missing')), findsOneWidget);

      await tapInList(tester, find.byKey(const Key('user-save')));
      expect(api.requestsTo('/admin/users', method: 'POST').single.data, {
        'username': 'eve',
        'displayName': 'Eve',
        'password': 'correct horse battery',
        'role': 'member',
        'jellyfinUserId': jfEve,
      });
      expect(find.text('Added Eve'), findsOneWidget);
    });

    testWidgets('rejects a bad username and a short password locally', (tester) async {
      final api = settingsFakeApi();
      await pumpHubApp(tester, api: api, location: '/settings/users/new');
      await tester.enterText(find.byKey(const Key('user-username')), 'Bad Name');
      await tester.enterText(fieldIn('user-password'), 'short');
      await tapInList(tester, find.byKey(const Key('user-save')));
      expect(find.textContaining('2–32 characters'), findsOneWidget);
      expect(find.text('At least 10 characters'), findsOneWidget);
      expect(api.requestsTo('/admin/users', method: 'POST'), isEmpty);
    });

    testWidgets('a taken username is shown on the field', (tester) async {
      final api = settingsFakeApi()
        ..on('POST', '/admin/users', (_) => FakeResponse.error(409, ApiErrorCode.alreadyExists));
      await pumpHubApp(tester, api: api, location: '/settings/users/new');
      await tester.enterText(find.byKey(const Key('user-username')), 'bob');
      await tester.enterText(fieldIn('user-password'), 'correct horse battery');
      await tapInList(tester, find.byKey(const Key('user-save')));
      expect(find.text('This username is taken'), findsOneWidget);
    });

    testWidgets('edits send only the changed fields', (tester) async {
      final bob = sampleUsers()[1];
      final saved = hubUser(bobId, 'Robert', role: Role.admin, jellyfinUserId: jfBob);
      final api = settingsFakeApi()..on('PATCH', '/admin/users/$bobId', (_) => FakeResponse(saved.toJson()));
      await pumpHubApp(tester, api: api, location: '/settings/users/$bobId');

      expect(find.text('@${bob.username}'), findsOneWidget);
      expect(find.byKey(const Key('seerr-account')), findsOneWidget);
      expect(find.text('Seerr account: Bob'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('user-display-name')), 'Robert');
      await tester.tap(find.descendant(of: find.byKey(const Key('user-role')), matching: find.text('Admin')));
      await tester.pump();
      await tapInList(tester, find.byKey(const Key('user-save')));

      expect(api.requestsTo('/admin/users/$bobId', method: 'PATCH').single.data, {
        'displayName': 'Robert',
        'role': 'admin',
      });
      expect(find.text('Saved'), findsOneWidget);
    });

    testWidgets('clearing the Jellyfin link sends an empty id', (tester) async {
      final api = settingsFakeApi()
        ..on('PATCH', '/admin/users/$bobId', (_) => FakeResponse(hubUser(bobId, 'Bob').toJson()));
      await pumpHubApp(tester, api: api, location: '/settings/users/$bobId');
      await tapInList(tester, find.text('bob'));
      await tester.tap(find.text('None').last);
      await settle(tester);
      await tapInList(tester, find.byKey(const Key('user-save')));
      expect(api.requestsTo('/admin/users/$bobId', method: 'PATCH').single.data, {'jellyfinUserId': ''});
    });

    testWidgets('Import into Seerr asks first, then shows the new Seerr account', (tester) async {
      final api = settingsFakeApi()
        ..postJson('/admin/jellyfin-users/$jfCarol/import-to-seerr', sampleJellyfinUsers(carolImported: true)[1].toJson());
      await pumpHubApp(tester, api: api, location: '/settings/users/$carolId');

      expect(find.text('No Seerr account'), findsOneWidget);
      await tapInList(tester, find.byKey(const Key('seerr-import')));
      expect(find.text('Create a Seerr account for carol with the default permissions?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Import'));
      await settle(tester);

      expect(api.requestsTo('/admin/jellyfin-users/$jfCarol/import-to-seerr', method: 'POST'), hasLength(1));
      expect(find.text('Seerr account: carol'), findsOneWidget);
      expect(find.byKey(const Key('seerr-missing')), findsNothing);
      expect(find.text('Imported carol into Seerr'), findsOneWidget);
    });

    testWidgets('delete asks first and sends confirm=true', (tester) async {
      final api = settingsFakeApi()..on('DELETE', '/admin/users/$daveId', (_) => const FakeResponse.noContent());
      await pumpHubApp(tester, api: api, location: '/settings/users/$daveId');

      await tester.tap(find.byKey(const Key('user-delete')));
      await settle(tester);
      expect(find.text('Delete Dave?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await settle(tester);

      final delete = api.requestsTo('/admin/users/$daveId', method: 'DELETE').single;
      expect(delete.uri.queryParameters, {'confirm': 'true'});
      expect(find.text('Deleted Dave'), findsOneWidget);
    });

    testWidgets('you cannot delete or disable yourself', (tester) async {
      await pumpHubApp(tester, api: settingsFakeApi(), location: '/settings/users/$adaId');
      expect(find.byKey(const Key('user-delete')), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const Key('user-disabled')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      final toggle = tester.widget<SwitchListTile>(find.byKey(const Key('user-disabled')));
      expect(toggle.onChanged, isNull);
    });

    testWidgets('usernames are folded to lowercase', (tester) async {
      final created = hubUser('u_e7e7e7e7e7e7', 'Eve');
      final api = settingsFakeApi()..postJson('/admin/users', created.toJson(), status: 201);
      await pumpHubApp(tester, api: api, location: '/settings/users/new');
      await tester.enterText(find.byKey(const Key('user-username')), ' Eve ');
      await tester.enterText(fieldIn('user-password'), 'correct horse battery');
      await tapInList(tester, find.byKey(const Key('user-save')));
      final body = api.requestsTo('/admin/users', method: 'POST').single.data as Map;
      expect(body['username'], 'eve');
      expect(body['displayName'], 'eve');
    });

    testWidgets('gateway errors for fields the form lacks still show a SnackBar', (tester) async {
      final api = settingsFakeApi()
        ..on(
          'PATCH',
          '/admin/users/$bobId',
          (_) => FakeResponse(
            const ApiError(
              code: ApiErrorCode.validationFailed,
              message: 'Role is invalid',
              status: 422,
              requestId: 'test-request-id',
              fields: [ApiFieldError(field: 'role', message: 'Unknown role')],
            ).toResponseBody(),
            status: 422,
          ),
        );
      await pumpHubApp(tester, api: api, location: '/settings/users/$bobId');
      await tester.enterText(find.byKey(const Key('user-display-name')), 'Robert');
      await tapInList(tester, find.byKey(const Key('user-save')));
      expect(find.text('Role is invalid'), findsOneWidget);
    });

    testWidgets('editing yourself: no password reset, demotion asks first', (tester) async {
      final demoted = hubUser(adaId, 'Ada');
      final api = settingsFakeApi()..on('PATCH', '/admin/users/$adaId', (_) => FakeResponse(demoted.toJson()));
      await pumpHubApp(tester, api: api, location: '/settings/users/$adaId');
      expect(find.byKey(const Key('user-password')), findsNothing);
      expect(find.byKey(const Key('user-own-password')), findsOneWidget);

      await tester.tap(find.descendant(of: find.byKey(const Key('user-role')), matching: find.text('Member')));
      await tester.pump();
      await tapInList(tester, find.byKey(const Key('user-save')));
      expect(find.text('Remove your admin role?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await settle(tester);
      expect(api.requestsTo('/admin/users/$adaId', method: 'PATCH'), isEmpty);

      await tapInList(tester, find.byKey(const Key('user-save')));
      await tester.tap(find.widgetWithText(FilledButton, 'Make me a member'));
      await settle(tester);
      expect(api.requestsTo('/admin/users/$adaId', method: 'PATCH').single.data, {'role': 'member'});
    });

    testWidgets('an unknown user id shows not found', (tester) async {
      await pumpHubApp(tester, api: settingsFakeApi(), location: '/settings/users/u_missing');
      expect(find.text('User not found'), findsOneWidget);
    });
  });
}
