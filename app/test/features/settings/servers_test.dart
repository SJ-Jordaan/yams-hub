import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/auth/token_store.dart';
import 'package:yams_hub/core/routing/router.dart';
import 'package:yams_hub/core/servers/server_store.dart';
import 'package:yams_hub/features/settings/providers/settings_providers.dart';

import '../../support/builders.dart';
import '../../support/fake_api.dart';
import '../../support/pump_hub_app.dart';
import 'settings_fixtures.dart';

String location(HubTestApp app) =>
    app.container.read(routerProvider).routerDelegate.currentConfiguration.uri.toString();

/// Pings answer per host: Zenith on the test URLs, another hub on 10.0.0.5,
/// nothing elsewhere.
FakeApi serversApi() => buildCoreFakeApi()
  ..on('GET', '/ping', (r) {
    final host = r.uri.host;
    if (host == '10.0.0.5') return FakeResponse(buildPing(instanceId: 'feedfacefeedface').toJson());
    if (host == testLanUrl.host || host == testTailscaleUrl.host) {
      return FakeResponse(buildPing(nonce: r.uri.queryParameters['nonce']).toJson());
    }
    return FakeResponse.error(503, 'upstream_unavailable', message: "Can't reach the hub.");
  })
  ..on('POST', '/auth/logout', (_) => const FakeResponse.noContent());

void main() {
  testWidgets('lists profiles with the active one selected', (tester) async {
    await pumpHubApp(tester, api: serversApi(), location: '/settings/servers');
    expect(find.text('Zenith'), findsOneWidget);
    expect(find.text('$testLanUrl\n$testTailscaleUrl'), findsOneWidget);
    expect(find.text('LAN'), findsOneWidget);
    final radio = tester.widget<Radio<String>>(find.byType(Radio<String>));
    expect(radio.value, 'p_test');
  });

  testWidgets('editing tests each URL and saves the new order', (tester) async {
    final app = await pumpHubApp(tester, api: serversApi(), location: '/settings/servers/p_test');

    await tester.tap(find.widgetWithText(TextButton, 'Test').first);
    await settle(tester);
    expect(find.textContaining('OK · yams-hub 1.0.0'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Home NAS');
    // Move the Tailscale URL first.
    final handle = find.byIcon(Icons.drag_indicator).last;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await settle(tester);
    final saved = app.container.read(serverStoreProvider).byId('p_test')!;
    expect(saved.name, 'Home NAS');
    expect(saved.urls, [testTailscaleUrl, testLanUrl]);
    expect(saved.instanceId, testInstanceId);
    expect(location(app), '/settings/servers');
  });

  testWidgets('shows the plain-HTTP warning for internet hosts', (tester) async {
    await pumpHubApp(tester, api: serversApi(), location: '/settings/servers/p_test');
    expect(find.textContaining('Passwords and tokens would travel unencrypted'), findsNothing);
    await tester.enterText(find.byKey(const Key('server-url-0')), 'http://hub.example.com:8090');
    await tester.pump();
    expect(find.textContaining('Passwords and tokens would travel unencrypted'), findsOneWidget);
  });

  testWidgets('URLs of another hub cannot be saved into this profile', (tester) async {
    final app = await pumpHubApp(tester, api: serversApi(), location: '/settings/servers/p_test');
    await tester.enterText(find.byKey(const Key('server-url-0')), 'http://10.0.0.5:8090');
    await tester.tap(find.byTooltip('Remove address').last);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await settle(tester);
    expect(find.byKey(const Key('server-editor-error')), findsOneWidget);
    expect(find.textContaining('different hub than Zenith'), findsOneWidget);
    expect(app.container.read(serverStoreProvider).byId('p_test')!.urls, [testLanUrl, testTailscaleUrl]);
  });

  testWidgets('adds a second hub without switching to it', (tester) async {
    final app = await pumpHubApp(tester, api: serversApi(), location: '/settings/servers/new');
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Office');
    await tester.enterText(find.byKey(const Key('server-url-0')), 'http://10.0.0.5:8090');
    await tester.tap(find.text('Switch to this server'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Add server'));
    await settle(tester);

    final store = app.container.read(serverStoreProvider);
    expect(store.profiles, hasLength(2));
    final office = store.profiles.firstWhere((p) => p.name == 'Office');
    expect(office.instanceId, 'feedfacefeedface');
    expect(office.lastGoodUrl, Uri.parse('http://10.0.0.5:8090'));
    expect(store.active!.id, 'p_test');
  });

  testWidgets('a new server must answer', (tester) async {
    final app = await pumpHubApp(tester, api: serversApi(), location: '/settings/servers/new');
    await tester.enterText(find.byKey(const Key('server-url-0')), 'http://10.9.9.9:8090');
    await tester.tap(find.widgetWithText(FilledButton, 'Add server'));
    await settle(tester);
    expect(find.byKey(const Key('server-editor-error')), findsOneWidget);
    expect(app.container.read(serverStoreProvider).profiles, hasLength(1));
  });

  testWidgets('switching the active server', (tester) async {
    final other = buildProfile(id: 'p_office', name: 'Office', urls: [Uri.parse('http://10.0.0.5:8090')], instanceId: 'feedfacefeedface');
    final app = await pumpHubApp(tester, api: serversApi(), location: '/settings/servers');
    app.container.read(serverStoreProvider.notifier).upsert(other);
    await settle(tester);
    await tester.tap(find.byType(Radio<String>).last);
    await settle(tester);
    expect(app.container.read(serverStoreProvider).active!.id, 'p_office');
  });

  testWidgets('deleting another profile asks first and forgets its session', (tester) async {
    final store = MemoryTokenBackend();
    final other = buildProfile(id: 'p_office', name: 'Office', urls: [Uri.parse('http://10.0.0.5:8090')], instanceId: 'feedfacefeedface');
    final tokens = BackendTokenStore(store);
    await tokens.write('feedfacefeedface', buildStoredTokens());
    final app = await pumpHubApp(
      tester,
      api: serversApi(),
      location: '/settings/servers',
      overrides: [profileTokenStoreProvider.overrideWithValue(tokens)],
    );
    app.container.read(serverStoreProvider.notifier).upsert(other);
    await settle(tester);

    await tester.tap(find.descendant(of: find.byKey(const Key('server-p_office')), matching: find.byTooltip('More')));
    await settle(tester);
    await tester.tap(find.text('Delete'));
    await settle(tester);
    expect(find.text('Delete Office?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await settle(tester);

    expect(app.container.read(serverStoreProvider).profiles.map((p) => p.id), ['p_test']);
    expect(await tokens.read('feedfacefeedface'), isNull);
    expect(app.tokens.hasSession, isTrue, reason: 'still signed in to the active server');
  });

  testWidgets('sign out of the active server from its editor', (tester) async {
    final api = serversApi();
    final app = await pumpHubApp(tester, api: api, location: '/settings/servers/p_test');
    await tapInList(tester, find.byKey(const Key('server-sign-out')));
    await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
    await settle(tester);
    expect(api.requestsTo('/auth/logout', method: 'POST'), hasLength(1));
    expect(app.tokens.hasSession, isFalse);
  });

  testWidgets('deleting the only, active server signs out and returns to onboarding', (tester) async {
    final api = serversApi();
    final app = await pumpHubApp(tester, api: api, location: '/settings/servers/p_test');
    await tester.tap(find.byTooltip('Delete server'));
    await settle(tester);
    expect(find.textContaining('It is your only server'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await settle(tester);

    expect(api.requestsTo('/auth/logout', method: 'POST'), hasLength(1));
    expect(app.container.read(serverStoreProvider).profiles, isEmpty);
    expect(app.tokens.hasSession, isFalse);
    expect(location(app), startsWith('/onboarding'));
  });
}
