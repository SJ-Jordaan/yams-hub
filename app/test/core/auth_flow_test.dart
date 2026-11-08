import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/auth/login_screen.dart';
import 'package:yams_hub/core/routing/router.dart';
import 'package:yams_hub/core/servers/server_store.dart';
import 'package:yams_models/yams_models.dart';

import '../support/builders.dart';
import '../support/fake_api.dart';
import '../support/pump_hub_app.dart';

String location(HubTestApp app) =>
    app.container.read(routerProvider).routerDelegate.currentConfiguration.uri.toString();

void main() {
  testWidgets('signed out: deep links go to /login?from= and back after sign-in', (tester) async {
    final api = buildCoreFakeApi()..postJson('/auth/login', buildLoginResponse().toJson());
    final app = await pumpHubApp(tester, api: api, signedIn: false, location: '/containers/sonarr');
    expect(location(app), '/login?from=%2Fcontainers%2Fsonarr');
    expect(find.text('Zenith'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, 'Username'), 'ada');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'correct horse');
    await tester.tap(find.text('Sign in'));
    await settle(tester);

    final login = api.requestsTo('/auth/login').single;
    final body = login.data as Map<String, Object?>;
    expect(body['username'], 'ada');
    expect(body['transport'], 'token');
    expect(body['deviceName'], 'Test device');
    expect(location(app), '/containers/sonarr');
    expect(app.tokens.hasSession, isTrue);
    expect(app.tokens.tokens!.serverProofKey, testProofKey);
    expect(app.tokens.tokens!.sessionId, testSessionId);
    expect(app.container.read(isAdminProvider), isTrue);
  });

  testWidgets('a bearer login without a server proof key is refused', (tester) async {
    final r = buildLoginResponse();
    final json = r.toJson()..remove('serverProofKey');
    final api = buildCoreFakeApi()..postJson('/auth/login', json);
    final app = await pumpHubApp(tester, api: api, signedIn: false, location: '/login');
    await tester.enterText(find.widgetWithText(TextFormField, 'Username'), 'ada');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'correct horse');
    await tester.tap(find.text('Sign in'));
    await settle(tester);
    expect(app.tokens.hasSession, isFalse, reason: 'no key: no URL could ever be proven');
    expect(location(app), '/login');
  });

  testWidgets('wrong password shows the inline error', (tester) async {
    final api = buildCoreFakeApi()
      ..on('POST', '/auth/login', (_) => FakeResponse.error(401, ApiErrorCode.invalidCredentials));
    await pumpHubApp(tester, api: api, signedIn: false, location: '/login');
    await tester.enterText(find.widgetWithText(TextFormField, 'Username'), 'ada');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'nope');
    await tester.tap(find.text('Sign in'));
    await settle(tester);
    expect(find.text('Wrong username or password'), findsOneWidget);
  });

  test('login error messages', () {
    expect(
      loginErrorMessage(const ApiError(code: ApiErrorCode.rateLimited, message: '', status: 429, retryAfterSeconds: 600)),
      'Too many attempts. Try again in 10 min',
    );
    expect(
      loginErrorMessage(const ApiError(code: ApiErrorCode.rateLimited, message: '', status: 429, retryAfterSeconds: 2)),
      'Too many attempts. Try again in 2 s',
    );
  });

  testWidgets('an expired session (refresh rejected) returns to login', (tester) async {
    final api = buildCoreFakeApi()
      ..on('GET', '/dashboard', (_) => FakeResponse.error(401, ApiErrorCode.tokenExpired))
      ..on('POST', '/auth/refresh', (_) => FakeResponse.error(401, ApiErrorCode.refreshInvalid));
    final app = await pumpHubApp(tester, api: api);
    await settle(tester);
    expect(app.tokens.hasSession, isFalse);
    expect(location(app), startsWith('/login'));
  });

  testWidgets('sign out clears the session and goes to login', (tester) async {
    final api = buildCoreFakeApi()..on('POST', '/auth/logout', (_) => const FakeResponse.noContent());
    final app = await pumpHubApp(tester, api: api);
    unawaited(app.container.read(authControllerProvider.notifier).logout());
    await settle(tester);
    expect(api.requestsTo('/auth/logout'), hasLength(1));
    expect(api.requestsTo('/auth/logout').single.headers['Authorization'], 'Bearer yha_access1');
    expect(app.tokens.hasSession, isFalse);
    expect(location(app), startsWith('/login'));
  });

  testWidgets('no server profile: onboarding validates and saves the profile', (tester) async {
    final api = buildCoreFakeApi();
    final app = await pumpHubApp(
      tester,
      api: api,
      signedIn: false,
      location: '/home',
      prefsValues: {ServerStore.storageKey: '{"profiles": []}'},
    );
    expect(location(app), '/onboarding');
    // Default LAN URL is prefilled; add a Tailscale URL that is down.
    await tester.enterText(find.widgetWithText(TextField, 'Tailscale URL (optional)'), 'http://zenith.example.ts.net:8090');
    await tester.tap(find.text('Test'));
    await settle(tester);
    expect(find.textContaining('yams-hub 1.0.0'), findsWidgets);

    await tester.tap(find.text('Continue'));
    await settle(tester);
    final store = app.container.read(serverStoreProvider);
    expect(store.active!.instanceId, testInstanceId);
    expect(store.active!.urls.map((u) => u.toString()), ['http://192.168.10.183:8090', 'http://zenith.example.ts.net:8090']);
    expect(location(app), '/login');
  });

  testWidgets('onboarding rejects URLs that belong to different hubs', (tester) async {
    final api = FakeApi()
      ..on('GET', '/ping', (r) => FakeResponse(buildPing(instanceId: r.uri.host.endsWith('ts.net') ? 'other' : testInstanceId).toJson()));
    await pumpHubApp(
      tester,
      api: api,
      signedIn: false,
      prefsValues: {ServerStore.storageKey: '{"profiles": []}'},
    );
    await tester.enterText(find.widgetWithText(TextField, 'Tailscale URL (optional)'), 'http://zenith.example.ts.net:8090');
    await tester.tap(find.text('Continue'));
    await settle(tester);
    expect(find.text('The URLs belong to different hubs.'), findsOneWidget);
  });

  testWidgets('onboarding warns about plain HTTP to the internet', (tester) async {
    await pumpHubApp(tester, signedIn: false, prefsValues: {ServerStore.storageKey: '{"profiles": []}'});
    await tester.enterText(find.widgetWithText(TextField, 'LAN URL'), 'http://hub.example.com:8090');
    await tester.pump();
    expect(find.textContaining('Passwords and tokens would travel unencrypted'), findsOneWidget);
  });
}
