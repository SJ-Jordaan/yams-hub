import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yams_hub/core/auth/token_manager.dart';
import 'package:yams_hub/core/auth/token_store.dart';
import 'package:yams_hub/core/auth/token_store_io.dart';
import 'package:yams_models/yams_models.dart';

import '../support/builders.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BackendTokenStore', () {
    test('round-trips every field under tokens.<instanceId>', () async {
      final backend = MemoryTokenBackend();
      final store = BackendTokenStore(backend);
      final tokens = buildStoredTokens();
      await store.write(testInstanceId, tokens);

      expect(backend.values.keys, ['tokens.$testInstanceId']);
      final json = jsonDecode(backend.values['tokens.$testInstanceId']!) as Map<String, Object?>;
      expect(
        json.keys,
        unorderedEquals([
          'accessToken',
          'accessTokenExpiresAt',
          'refreshToken',
          'refreshTokenExpiresAt',
          'sessionId',
          'serverProofKey',
        ]),
      );

      final read = await store.read(testInstanceId);
      expect(read!.accessToken, tokens.accessToken);
      expect(read.refreshToken, tokens.refreshToken);
      expect(read.sessionId, testSessionId);
      expect(read.serverProofKey, testProofKey);
      expect(read.refreshTokenExpiresAt.difference(tokens.refreshTokenExpiresAt).inSeconds.abs(), lessThan(1));
    });

    test('tokens are kept per instance and deleted', () async {
      final store = BackendTokenStore(MemoryTokenBackend());
      await store.write('a', buildStoredTokens(access: 'yha_a'));
      await store.write('b', buildStoredTokens(access: 'yha_b'));
      expect((await store.read('a'))!.accessToken, 'yha_a');
      await store.delete('a');
      expect(await store.read('a'), isNull);
      expect((await store.read('b'))!.accessToken, 'yha_b');
    });

    test('a corrupt value reads as no tokens and is removed', () async {
      final backend = MemoryTokenBackend({'tokens.x': '{not json'});
      final store = BackendTokenStore(backend);
      expect(await store.read('x'), isNull);
      expect(backend.values, isEmpty);
      backend.values['tokens.y'] = '{"accessToken": "yha"}';
      expect(await store.read('y'), isNull);
    });
  });

  test('secure storage backend (flutter_secure_storage 11)', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = BackendTokenStore(SecureStorageTokenBackend());
    await store.write(testInstanceId, buildStoredTokens());
    expect((await store.read(testInstanceId))!.sessionId, testSessionId);
    await store.delete(testInstanceId);
    expect(await store.read(testInstanceId), isNull);
  });

  test('cookie transport uses the no-op store', () async {
    final store = createTokenStore(cookieTransport: true);
    expect(store, isA<NoopTokenStore>());
    await store.write('x', buildStoredTokens());
    expect(await store.read('x'), isNull);
  });

  group('TokenManager', () {
    late SharedPreferences prefs;
    late BackendTokenStore store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      store = BackendTokenStore(MemoryTokenBackend());
    });

    TokenManager manager({bool cookie = false, DateTime Function()? clock}) =>
        TokenManager(store: store, prefs: prefs, cookieTransport: cookie, clock: clock);

    test('sign in persists tokens and the user; a new run restores both', () async {
      final tm = manager();
      var notified = 0;
      tm.addListener(() => notified++);
      await tm.signIn(scope: testInstanceId, user: buildUser(), tokens: buildStoredTokens());
      expect(tm.hasSession, isTrue);
      expect(tm.accessToken, 'yha_access1');
      expect(notified, 1);

      final next = manager();
      await next.activate(testInstanceId);
      expect(next.hasSession, isTrue);
      expect(next.user!.role, Role.admin);
      expect(next.proofCredentials!.sessionId, testSessionId);
      expect(next.proofCredentials!.serverProofKey, testProofKey);
    });

    test('forgetCachedUser drops another profile\'s cached user, never the active one', () async {
      final other = manager();
      await other.signIn(scope: 'feedfacefeedface', user: buildUser(), tokens: buildStoredTokens());
      final tm = manager();
      await tm.signIn(scope: testInstanceId, user: buildUser(), tokens: buildStoredTokens());
      expect(prefs.getString('auth.user.feedfacefeedface'), isNotNull);

      await tm.forgetCachedUser('feedfacefeedface');
      expect(prefs.getString('auth.user.feedfacefeedface'), isNull);

      await tm.forgetCachedUser(testInstanceId);
      expect(prefs.getString('auth.user.$testInstanceId'), isNotNull);
      expect(tm.user, isNotNull);
    });

    test('rotation keeps the session id and proof key', () async {
      final tm = manager();
      await tm.signIn(scope: testInstanceId, user: buildUser(), tokens: buildStoredTokens());
      await tm.storeTokens(buildTokenPair(access: 'yha_2', refresh: 'yhr_s_0123456789ab.r2'));
      expect(tm.accessToken, 'yha_2');
      final stored = await store.read(testInstanceId);
      expect(stored!.refreshToken, 'yhr_s_0123456789ab.r2');
      expect(stored.sessionId, testSessionId);
      expect(stored.serverProofKey, testProofKey);
    });

    test('rotation updates accessTokenProvider (image headers)', () async {
      final tm = manager();
      await tm.signIn(scope: testInstanceId, user: buildUser(), tokens: buildStoredTokens());
      final container = ProviderContainer(overrides: [tokenManagerProvider.overrideWithValue(tm)]);
      addTearDown(container.dispose);
      final seen = <String?>[];
      container.listen(accessTokenProvider, (_, next) => seen.add(next), fireImmediately: true);
      await tm.storeTokens(buildTokenPair(access: 'yha_2', refresh: 'yhr_s_0123456789ab.r2'));
      await container.pump();
      await tm.expire();
      await container.pump();
      expect(seen, ['yha_access1', 'yha_2', null]);
    });

    test('expire clears tokens, the user cache and notifies', () async {
      final tm = manager();
      await tm.signIn(scope: testInstanceId, user: buildUser(), tokens: buildStoredTokens());
      var notified = 0;
      tm.addListener(() => notified++);
      await tm.expire();
      expect(tm.hasSession, isFalse);
      expect(tm.user, isNull);
      expect(notified, 1);
      expect(await store.read(testInstanceId), isNull);
      expect(prefs.getKeys().where((k) => k.startsWith('auth.')), isEmpty);
    });

    test('an expired refresh token is no session', () async {
      final tm = manager(clock: () => DateTime.now().add(const Duration(days: 365)));
      await tm.signIn(scope: testInstanceId, user: buildUser(), tokens: buildStoredTokens());
      expect(tm.hasSession, isFalse);
    });

    test('switching instance loads that instance\'s session only', () async {
      final tm = manager();
      await tm.signIn(scope: 'a', user: buildUser(), tokens: buildStoredTokens(access: 'yha_a'));
      await tm.activate('b');
      expect(tm.hasSession, isFalse);
      expect(tm.accessToken, isNull);
      await tm.activate('a');
      expect(tm.accessToken, 'yha_a');
    });

    test('cookie transport keeps only a signed-in marker', () async {
      final tm = manager(cookie: true);
      await tm.signIn(scope: 'ignored', user: buildUser(role: Role.member));
      expect(tm.hasSession, isTrue);
      expect(tm.accessToken, isNull);
      expect(tm.proofCredentials, isNull);

      final next = manager(cookie: true);
      await next.activate(null);
      expect(next.hasSession, isTrue);
      expect(next.user!.role, Role.member);
    });

    test('saveUser updates the cached role', () async {
      final tm = manager();
      await tm.signIn(scope: testInstanceId, user: buildUser(), tokens: buildStoredTokens());
      await tm.saveUser(buildUser(role: Role.member));
      expect(tm.user!.role, Role.member);
    });
  });
}
