import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yams_hub/core/api/api_client.dart';
import 'package:yams_hub/core/auth/token_manager.dart';
import 'package:yams_hub/core/auth/token_store.dart';
import 'package:yams_hub/core/servers/hosting.dart';
import 'package:yams_hub/core/servers/server_connection.dart';
import 'package:yams_hub/core/servers/server_resolver.dart';
import 'package:yams_hub/core/servers/server_store.dart';
import 'package:yams_hub/core/settings/app_settings.dart';

import '../support/builders.dart';
import '../support/fake_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeApi api;
  late ProviderContainer container;

  /// [lanProofKey] / [tailscaleProofKey] are the keys the LAN / Tailscale
  /// hosts sign with (an impostor's differs; null: no proof at all).
  Future<void> start({
    String lanProofKey = testProofKey,
    bool tailscaleUp = false,
    String? tailscaleProofKey = testProofKey,
    bool signedIn = true,
  }) async {
    api = FakeApi()
      ..on('GET', '/ping', (r) {
        if (r.uri.host.endsWith('ts.net')) {
          return tailscaleUp
              ? FakeResponse(buildPing(nonce: r.uri.queryParameters['nonce'], proofKey: tailscaleProofKey).toJson())
              : const FakeResponse.fail(DioExceptionType.connectionError);
        }
        return FakeResponse(buildPing(nonce: r.uri.queryParameters['nonce'], proofKey: lanProofKey).toJson());
      })
      ..getJson('/server', buildServerConfig().toJson());
    final profile = buildProfile();
    SharedPreferences.setMockInitialValues({
      ServerStore.storageKey: jsonEncode(ServerStoreState(profiles: [profile], activeId: profile.id).toJson()),
    });
    final prefs = await SharedPreferences.getInstance();
    final tokens = TokenManager(store: BackendTokenStore(MemoryTokenBackend()), prefs: prefs, cookieTransport: false);
    if (signedIn) await tokens.signIn(scope: testInstanceId, user: buildUser(), tokens: buildStoredTokens());
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        tokenManagerProvider.overrideWithValue(tokens),
        hostingModeProvider.overrideWithValue(HostingMode.native),
        httpClientAdapterProvider.overrideWithValue(api),
        serverPingClientProvider.overrideWithValue(DioServerPingClient(adapter: api)),
      ],
    );
    addTearDown(container.dispose);
    ActiveServerController.resetHomeVerified();
  }

  Future<ServerConnection> resolved() async {
    container.read(activeServerProvider);
    await container.read(activeServerProvider.notifier).resolve();
    return container.read(activeServerProvider);
  }

  test('the LAN URL that passes the proof becomes the API base', () async {
    await start();
    final c = await resolved();
    expect(c.status, ConnectionStatus.connected);
    expect(c.apiBase, 'http://192.168.10.183:8090/api/v1');
    expect(c.proofVerified, isTrue);
    expect(container.read(serverStoreProvider).active!.lastGoodUrl, testLanUrl);
    expect(container.read(dioProvider).options.baseUrl, 'http://192.168.10.183:8090/api/v1');
    final ping = api.requestsTo('/ping').firstWhere((r) => r.uri.host == '192.168.10.183');
    expect(ping.uri.queryParameters['sid'], testSessionId);
    expect(ping.headers.containsKey('Authorization'), isFalse, reason: 'the ping never carries a token');
  });

  test('an impostor on the LAN URL is never sent a token; Tailscale is used instead', () async {
    await start(lanProofKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', tailscaleUp: true);
    final c = await resolved();
    expect(c.baseUrl, testTailscaleUrl);
    expect(c.proofVerified, isTrue);
    await container.read(dioProvider).getMap('/server');
    final sent = api.requestsTo('/server').single;
    expect(sent.uri.host, 'zenith.example.ts.net');
    expect(sent.headers['Authorization'], 'Bearer yha_access1');
  });

  test('a *.ts.net impostor without the proof is never sent a token', () async {
    // Tailscale off, the local DNS answers the MagicDNS name: the public
    // ping fields match, the proof does not.
    await start(
      lanProofKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      tailscaleUp: true,
      tailscaleProofKey: null,
    );
    final c = await resolved();
    expect(c.status, ConnectionStatus.unreachable);
    expect(c.baseUrl, isNull);
    final ping = api.requestsTo('/ping').firstWhere((r) => r.uri.host == 'zenith.example.ts.net');
    expect(ping.uri.queryParameters['sid'], testSessionId);
    await expectLater(container.read(dioProvider).getMap('/server'), throwsA(isA<ApiException>()));
    expect(api.requestsTo('/server'), isEmpty);
  });

  test('nothing acceptable: unreachable, and requests do not leave the device', () async {
    await start(lanProofKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA');
    final c = await resolved();
    expect(c.status, ConnectionStatus.unreachable);
    expect(c.baseUrl, isNull);
    await expectLater(
      container.read(dioProvider).getMap('/server'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', ClientErrorCode.noServer)),
    );
    expect(api.requestsTo('/server'), isEmpty);
  });

  test('signed out: no proof is required', () async {
    await start(lanProofKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', signedIn: false);
    final c = await resolved();
    expect(c.baseUrl, testLanUrl);
    expect(c.proofVerified, isFalse);
  });

  test('failover re-probes and returns the API base to retry against', () async {
    await start();
    await resolved();
    expect(await container.read(activeServerProvider.notifier).failover(), 'http://192.168.10.183:8090/api/v1');
  });
}
