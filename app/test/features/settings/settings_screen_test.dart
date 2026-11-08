import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yams_hub/core/auth/token_manager.dart';
import 'package:yams_hub/core/auth/token_store.dart';
import 'package:yams_hub/core/routing/router.dart';
import 'package:yams_hub/core/servers/hosting.dart';
import 'package:yams_hub/core/servers/server_connection.dart';
import 'package:yams_hub/core/settings/app_settings.dart';
import 'package:yams_hub/features/settings/screens/settings_screen.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/builders.dart';
import '../../support/fake_api.dart';
import '../../support/pump_hub_app.dart';
import 'settings_fixtures.dart';

String location(HubTestApp app) =>
    app.container.read(routerProvider).routerDelegate.currentConfiguration.uri.toString();

void main() {
  testWidgets('admin sees server, account, administration and device groups', (tester) async {
    await pumpHubApp(tester, location: '/settings');

    expect(find.text('Zenith'), findsOneWidget);
    expect(find.text(testLanUrl.toString()), findsOneWidget);
    expect(find.text('LAN'), findsOneWidget);
    expect(find.text('Signed in as Ada'), findsOneWidget);
    expect(find.text('Admin'), findsOneWidget);
    expect(find.text('Users'), findsOneWidget);
    expect(find.text('Audit log'), findsOneWidget);
    await scrollToCenter(tester, find.text('About YAMS Hub'));
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Normal'), findsOneWidget, reason: 'refresh preset subtitle');
  });

  testWidgets('members do not see the administration tiles', (tester) async {
    await pumpHubApp(tester, role: Role.member, location: '/settings');
    expect(find.text('Member'), findsOneWidget);
    expect(find.text('Users'), findsNothing);
    expect(find.text('Audit log'), findsNothing);
  });

  testWidgets('members are redirected away from admin routes', (tester) async {
    final app = await pumpHubApp(tester, role: Role.member, location: '/settings/users');
    expect(location(app), '/settings');
    expect(find.text('Admins only'), findsOneWidget);
  });

  testWidgets('sign out asks first, then logs out and shows the login screen', (tester) async {
    final api = buildCoreFakeApi()..on('POST', '/auth/logout', (_) => const FakeResponse.noContent());
    final app = await pumpHubApp(tester, api: api, location: '/settings');

    await tester.tap(find.byKey(const Key('settings-sign-out')));
    await settle(tester);
    expect(find.text('Sign out of Zenith on this device?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await settle(tester);
    expect(api.requestsTo('/auth/logout'), isEmpty);

    await tester.tap(find.byKey(const Key('settings-sign-out')));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
    await settle(tester);
    expect(api.requestsTo('/auth/logout', method: 'POST'), hasLength(1));
    expect(app.tokens.hasSession, isFalse);
    expect(location(app), startsWith('/login'));
  });

  testWidgets('the gateway-served web build hides the server section', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final tokens = TokenManager(store: const NoopTokenStore(), prefs: prefs, cookieTransport: true);
    await tokens.signIn(scope: 'web', user: buildUser());
    final profile = buildProfile(id: 'web');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          tokenManagerProvider.overrideWithValue(tokens),
          hostingModeProvider.overrideWithValue(HostingMode.gatewayWeb),
          activeServerProvider.overrideWith(
            () => ActiveServerController(
              fixed: ServerConnection(
                status: ConnectionStatus.connected,
                profile: profile,
                baseUrl: testLanUrl,
                transport: ApiTransport.cookie,
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('settings-server')), findsNothing);
    expect(find.text('Signed in as Ada'), findsOneWidget);
  });
}
