import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/api/api_client.dart';
import 'package:yams_models/yams_models.dart';

import '../support/builders.dart';
import '../support/fake_api.dart';

class _Session implements AuthSession {
  _Session({this.cookieTransport = false, this.accessToken = 'yha_old', this.refreshToken = 'yhr_s.old'});

  @override
  final bool cookieTransport;
  @override
  String? accessToken;
  @override
  String? refreshToken;
  int expired = 0;
  final stored = <TokenPair>[];

  @override
  Future<void> storeTokens(TokenPair tokens) async {
    stored.add(tokens);
    accessToken = tokens.accessToken;
    refreshToken = tokens.refreshToken;
  }

  @override
  Future<void> expire() async {
    expired++;
    accessToken = null;
    refreshToken = null;
  }
}

void main() {
  const base = 'http://192.168.10.183:8090/api/v1';
  late FakeApi api;

  Dio dio(_Session session, {String baseUrl = base}) =>
      createHubDio(baseUrl: baseUrl, session: session, adapter: api, reprobe: () async => null);

  /// `/library/tv` answers 401 token_expired unless the new token is sent.
  void protectedRoute({String path = '/library/tv', String code = ApiErrorCode.tokenExpired}) {
    api.on('GET', path, (r) {
      final auth = r.headers['Authorization'];
      return auth == 'Bearer yha_new' || (auth == null && r.extra['cookieOk'] == true)
          ? const FakeResponse({'ok': true})
          : FakeResponse.error(401, code);
    });
  }

  setUp(() => api = FakeApi());

  test('adds the bearer token, but not to login and refresh', () async {
    final session = _Session(accessToken: 'yha_new');
    api
      ..getJson('/server', {'ok': true})
      ..postJson('/auth/login', {'ok': true});
    final d = dio(session);
    await d.getMap('/server');
    await d.postMap('/auth/login', body: {});
    expect(api.requests[0].headers['Authorization'], 'Bearer yha_new');
    expect(api.requests[1].headers.containsKey('Authorization'), isFalse);
  });

  test('401 token_expired: refreshes, stores the rotated pair and retries once', () async {
    final session = _Session();
    protectedRoute();
    api.on('POST', '/auth/refresh', (r) {
      expect(r.data, {'refreshToken': 'yhr_s.old'});
      return FakeResponse({'tokens': buildTokenPair(access: 'yha_new', refresh: 'yhr_s.new').toJson()});
    });
    expect(await dio(session).getMap('/library/tv'), {'ok': true});
    expect(session.stored.single.refreshToken, 'yhr_s.new');
    expect(api.requestsTo('/library/tv'), hasLength(2));
    expect(api.requestsTo('/library/tv').last.headers['Authorization'], 'Bearer yha_new');
  });

  test('401 unauthorized also triggers the refresh', () async {
    final session = _Session();
    protectedRoute(code: ApiErrorCode.unauthorized);
    api.postJson('/auth/refresh', {'tokens': buildTokenPair(access: 'yha_new').toJson()});
    expect(await dio(session).getMap('/library/tv'), {'ok': true});
  });

  test('concurrent 401s share one single-flight refresh', () async {
    final session = _Session();
    protectedRoute();
    var refreshes = 0;
    api.on('POST', '/auth/refresh', (r) async {
      refreshes++;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return FakeResponse({'tokens': buildTokenPair(access: 'yha_new').toJson()});
    });
    final d = dio(session);
    final results = await Future.wait([for (var i = 0; i < 4; i++) d.getMap('/library/tv')]);
    expect(results, everyElement({'ok': true}));
    expect(refreshes, 1);
  });

  test('the refresh Dio copies baseUrl and X-YAMS-Client, and has no Authorization', () async {
    final session = _Session();
    protectedRoute();
    api.postJson('/auth/refresh', {'tokens': buildTokenPair(access: 'yha_new').toJson()});
    await dio(session, baseUrl: 'http://zenith.example.ts.net:8090/api/v1').getMap('/library/tv');
    final refresh = api.requestsTo('/auth/refresh').single;
    expect(refresh.uri.toString(), 'http://zenith.example.ts.net:8090/api/v1/auth/refresh');
    expect(refresh.headers[hubClientHeaderName], startsWith('yams-hub/'));
    expect(refresh.headers.containsKey('Authorization'), isFalse);
  });

  test('a rejected refresh expires the session and surfaces the 401', () async {
    final session = _Session();
    protectedRoute();
    api.on('POST', '/auth/refresh', (_) => FakeResponse.error(401, ApiErrorCode.refreshInvalid));
    await expectLater(
      dio(session).getMap('/library/tv'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', ApiErrorCode.tokenExpired)),
    );
    expect(session.expired, 1);
    expect(api.requestsTo('/library/tv'), hasLength(1));
  });

  test('a refresh that fails on the network keeps the session', () async {
    final session = _Session();
    protectedRoute();
    api.on('POST', '/auth/refresh', (_) => const FakeResponse.fail(DioExceptionType.connectionError));
    await expectLater(dio(session).getMap('/library/tv'), throwsA(isA<ApiException>()));
    expect(session.expired, 0);
    expect(session.refreshToken, 'yhr_s.old');
  });

  test('no refresh token: expires immediately', () async {
    final session = _Session(refreshToken: null);
    protectedRoute();
    await expectLater(dio(session).getMap('/library/tv'), throwsA(isA<ApiException>()));
    expect(session.expired, 1);
    expect(api.requestsTo('/auth/refresh'), isEmpty);
  });

  test('other 401 codes and 403s are not refreshed', () async {
    final session = _Session();
    api.on('GET', '/admin/users', (_) => FakeResponse.error(403, ApiErrorCode.forbidden));
    await expectLater(
      dio(session).getMap('/admin/users'),
      throwsA(isA<ApiException>().having((e) => e.status, 'status', 403)),
    );
    expect(api.requestsTo('/auth/refresh'), isEmpty);
  });

  test('cookie transport: no Authorization header; empty refresh body with X-YAMS-Client', () async {
    final session = _Session(cookieTransport: true, accessToken: null, refreshToken: null);
    var calls = 0;
    api
      ..on('GET', '/library/tv', (r) {
        expect(r.headers.containsKey('Authorization'), isFalse);
        calls++;
        return calls == 1 ? FakeResponse.error(401, ApiErrorCode.tokenExpired) : const FakeResponse({'ok': true});
      })
      ..on('POST', '/auth/refresh', (r) {
        expect(r.data, isNull);
        return const FakeResponse.noContent();
      });
    final d = dio(session, baseUrl: 'http://192.168.10.183:8090/yh/api/v1');
    expect(await d.getMap('/library/tv'), {'ok': true});
    final refresh = api.requestsTo('/auth/refresh').single;
    expect(refresh.uri.path, '/yh/api/v1/auth/refresh');
    expect(refresh.headers[hubClientHeaderName], isNotNull);
  });
}
