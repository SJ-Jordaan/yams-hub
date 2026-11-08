/// Builds the whole app against a [FakeApi] with a fake server profile and a
/// signed-in user (ARCHITECTURE §7.12).
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yams_hub/app.dart';
import 'package:yams_hub/core/api/api_client.dart';
import 'package:yams_hub/core/auth/device_name.dart';
import 'package:yams_hub/core/auth/token_manager.dart';
import 'package:yams_hub/core/auth/token_store.dart';
import 'package:yams_hub/core/routing/router.dart';
import 'package:yams_hub/core/servers/hosting.dart';
import 'package:yams_hub/core/servers/server_connection.dart';
import 'package:yams_hub/core/servers/server_profile.dart';
import 'package:yams_hub/core/servers/server_resolver.dart';
import 'package:yams_hub/core/servers/server_store.dart';
import 'package:yams_hub/core/settings/app_settings.dart';
import 'package:yams_models/yams_models.dart';

import 'builders.dart';
import 'fake_api.dart';

/// Phone and wide test surfaces.
const phoneSize = Size(400, 860);
const tabletSize = Size(900, 1000);
const desktopSize = Size(1400, 1000);

/// Handles of a pumped app.
class HubTestApp {
  HubTestApp({required this.api, required this.container, required this.tokens, required this.prefs});

  final FakeApi api;
  final ProviderContainer container;
  final TokenManager tokens;
  final SharedPreferences prefs;
}

/// A [FakeApi] answering the core endpoints the shell needs on start:
/// `/dashboard`, `/server`, `/health`, `/auth/me` and `/ping` (with proof).
FakeApi buildCoreFakeApi({Role role = Role.admin, List<Alert> alerts = const []}) {
  final api = FakeApi()
    ..getJson('/dashboard', buildDashboardJson(alerts: alerts))
    ..getJson('/server', buildServerConfig().toJson())
    ..getJson('/health', buildHealth().toJson())
    ..getJson(
      '/auth/me',
      MeResponse(user: buildUser(role: role), session: buildSession(), seerr: const MeSeerrInfo.unlinked()).toJson(),
    )
    ..on('GET', '/ping', (r) {
      final nonce = r.uri.queryParameters['nonce'];
      return FakeResponse(buildPing(nonce: nonce).toJson());
    });
  return api;
}

/// Pumps [YamsHubApp] at [location].
///
/// The active server is pinned to the LAN URL (no resolution runs) unless
/// [connection] says otherwise; [signedIn] controls the stored session.
Future<HubTestApp> pumpHubApp(
  WidgetTester tester, {
  FakeApi? api,
  Role role = Role.admin,
  bool signedIn = true,
  String location = '/home',
  Size size = phoneSize,
  ServerProfile? profile,
  ServerConnection? connection,
  Map<String, Object> prefsValues = const {},
  List<Override> overrides = const [],
}) async {
  final fake = api ?? buildCoreFakeApi(role: role);
  final p = profile ?? buildProfile();

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues({
    ServerStore.storageKey: jsonEncode(ServerStoreState(profiles: [p], activeId: p.id).toJson()),
    ...prefsValues,
  });
  final prefs = await SharedPreferences.getInstance();
  final tokens = TokenManager(store: BackendTokenStore(MemoryTokenBackend()), prefs: prefs, cookieTransport: false);
  if (signedIn) {
    await tokens.signIn(scope: p.instanceId!, user: buildUser(role: role), tokens: buildStoredTokens());
  } else {
    await tokens.activate(p.instanceId);
  }

  final pinned =
      connection ??
      ServerConnection(status: ConnectionStatus.connected, profile: p, baseUrl: testLanUrl, ping: buildPing());

  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        tokenManagerProvider.overrideWithValue(tokens),
        hostingModeProvider.overrideWithValue(HostingMode.native),
        httpClientAdapterProvider.overrideWithValue(fake),
        serverPingClientProvider.overrideWithValue(DioServerPingClient(adapter: fake)),
        activeServerProvider.overrideWith(() => ActiveServerController(fixed: pinned)),
        initialLocationProvider.overrideWithValue(location),
        deviceNameProvider.overrideWith((ref) async => 'Test device'),
        ...overrides,
      ],
      child: const YamsHubApp(),
    ),
  );
  await settle(tester);
  final container = ProviderScope.containerOf(tester.element(find.byType(YamsHubApp)));
  return HubTestApp(api: fake, container: container, tokens: tokens, prefs: prefs);
}

/// Pumps frames until async work (fake HTTP, microtasks) has landed, without
/// waiting for indefinite animations or the refresh timers.
Future<void> settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}
