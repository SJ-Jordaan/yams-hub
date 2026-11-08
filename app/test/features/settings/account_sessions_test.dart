import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/fake_api.dart';
import '../../support/pump_hub_app.dart';
import 'settings_fixtures.dart';

Future<void> fillPasswords(WidgetTester tester, {required String current, required String next, String? confirm}) async {
  await tester.enterText(find.descendant(of: find.byKey(const Key('password-current')), matching: find.byType(TextField)), current);
  await tester.enterText(find.descendant(of: find.byKey(const Key('password-new')), matching: find.byType(TextField)), next);
  await tester.enterText(
    find.descendant(of: find.byKey(const Key('password-confirm')), matching: find.byType(TextField)),
    confirm ?? next,
  );
  await tester.pump();
}

Future<void> submitPassword(WidgetTester tester) async {
  final button = find.widgetWithText(FilledButton, 'Change password');
  await tester.ensureVisible(button);
  await tester.tap(button);
  await settle(tester);
}

void main() {
  group('account', () {
    testWidgets('changes the password and clears the form', (tester) async {
      final api = buildCoreFakeApi()..on('POST', '/auth/password', (_) => const FakeResponse.noContent());
      await pumpHubApp(tester, api: api, location: '/settings/account');

      expect(find.text('Ada'), findsOneWidget);
      expect(find.text('@ada'), findsOneWidget);
      await fillPasswords(tester, current: 'old secret 1', next: 'correct horse battery');
      expect(find.text('Strong'), findsOneWidget);
      await submitPassword(tester);

      expect(api.requestsTo('/auth/password', method: 'POST').single.data, {
        'currentPassword': 'old secret 1',
        'newPassword': 'correct horse battery',
      });
      expect(find.text('Password changed. Your other devices were signed out.'), findsOneWidget);
      expect(find.text('Strong'), findsNothing, reason: 'fields cleared');
    });

    testWidgets('validates locally before sending', (tester) async {
      final api = buildCoreFakeApi();
      await pumpHubApp(tester, api: api, location: '/settings/account');

      await fillPasswords(tester, current: 'old secret 1', next: 'short', confirm: 'other');
      expect(find.text('Too short (5/10)'), findsOneWidget);
      await submitPassword(tester);
      expect(find.text('At least 10 characters'), findsOneWidget);
      expect(find.text("Passwords don't match"), findsOneWidget);
      expect(api.requestsTo('/auth/password'), isEmpty);
    });

    testWidgets('a wrong current password is shown on its field', (tester) async {
      final api = buildCoreFakeApi()
        ..on('POST', '/auth/password', (_) => FakeResponse.error(401, ApiErrorCode.invalidCredentials));
      await pumpHubApp(tester, api: api, location: '/settings/account');
      await fillPasswords(tester, current: 'nope nope 1', next: 'correct horse battery');
      await submitPassword(tester);
      expect(find.text('Current password is wrong'), findsOneWidget);
    });
  });

  group('sessions', () {
    FakeApi sessionsApi({Role role = Role.admin}) => buildCoreFakeApi(role: role)
      ..on('GET', '/auth/sessions', (r) {
        final all = r.uri.queryParameters['all'] == 'true';
        return FakeResponse(
          itemList([
            sampleSession('s_old', device: 'Old tablet', platform: ClientPlatform.other, ago: const Duration(days: 2)),
            sampleSession('s_me', device: 'Pixel 8', current: true, ago: const Duration(minutes: 1)),
            sampleSession('s_web', device: 'Firefox', platform: ClientPlatform.web, ago: const Duration(hours: 1)),
            if (all)
              sampleSession('s_bob', device: 'Bob phone', username: 'bob', userId: bobId, ago: const Duration(hours: 2)),
          ].map((s) => s.toJson())),
        );
      })
      ..on('DELETE', '/auth/sessions/s_web', (_) => const FakeResponse.noContent());

    testWidgets('lists own sessions, current first, with the This device chip', (tester) async {
      await pumpHubApp(tester, api: sessionsApi(), location: '/settings/sessions');
      expect(find.text('This device'), findsOneWidget);
      final me = tester.getTopLeft(find.byKey(const Key('session-s_me'))).dy;
      final web = tester.getTopLeft(find.byKey(const Key('session-s_web'))).dy;
      final old = tester.getTopLeft(find.byKey(const Key('session-s_old'))).dy;
      expect(me < web && web < old, isTrue);
      expect(find.textContaining('192.168.10.50'), findsNWidgets(3));
    });

    testWidgets('admins can show every user\'s sessions', (tester) async {
      final api = sessionsApi();
      await pumpHubApp(tester, api: api, location: '/settings/sessions');
      expect(find.text('Bob phone'), findsNothing);
      await tester.tap(find.byKey(const Key('sessions-all-users')));
      await settle(tester);
      expect(api.requestsTo('/auth/sessions').last.uri.queryParameters, {'all': 'true'});
      expect(find.text('Bob phone'), findsOneWidget);
      expect(find.textContaining('bob · Android'), findsOneWidget);
    });

    testWidgets('members have no All users switch', (tester) async {
      await pumpHubApp(tester, api: sessionsApi(role: Role.member), role: Role.member, location: '/settings/sessions');
      expect(find.byKey(const Key('sessions-all-users')), findsNothing);
      expect(find.text('Pixel 8'), findsOneWidget);
    });

    testWidgets('revoking asks first and sends DELETE', (tester) async {
      final api = sessionsApi();
      await pumpHubApp(tester, api: api, location: '/settings/sessions');
      final revoke = find.descendant(of: find.byKey(const Key('session-s_web')), matching: find.byTooltip('Revoke'));
      await tester.tap(revoke);
      await settle(tester);
      expect(find.text('Revoke Firefox?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Revoke'));
      await settle(tester);
      expect(api.requestsTo('/auth/sessions/s_web', method: 'DELETE'), hasLength(1));
      expect(find.text('Revoked Firefox'), findsOneWidget);
      expect(api.requestsTo('/auth/sessions', method: 'GET').length, greaterThanOrEqualTo(2), reason: 'reloaded');
    });

    testWidgets('a failed first load shows the error with retry', (tester) async {
      final api = buildCoreFakeApi()
        ..on('GET', '/auth/sessions', (_) => FakeResponse.error(503, ApiErrorCode.upstreamUnavailable, message: 'Down'));
      await pumpHubApp(tester, api: api, location: '/settings/sessions');
      expect(find.text('Retry'), findsOneWidget);
    });
  });
}
