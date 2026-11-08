import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/api/api_client.dart';
import 'package:yams_models/yams_models.dart';

import '../support/fake_api.dart';

class _NoSession implements AuthSession {
  @override
  bool get cookieTransport => false;
  @override
  String? get accessToken => 'yha_token';
  @override
  String? get refreshToken => 'yhr_s.x';
  @override
  Future<void> storeTokens(TokenPair tokens) async {}
  @override
  Future<void> expire() async {}
}

void main() {
  const lan = 'http://192.168.10.183:8090/api/v1';
  const tailscale = 'http://zenith.example.ts.net:8090/api/v1';

  late FakeApi api;
  late int reprobes;
  String? reprobeResult;

  Dio dio() => createHubDio(
    baseUrl: lan,
    session: _NoSession(),
    adapter: api,
    reprobe: () async {
      reprobes++;
      return reprobeResult;
    },
  );

  /// The first request to [path] fails with [type]; later ones succeed.
  void failFirst(String method, String path, DioExceptionType type) {
    var calls = 0;
    api.on(method, path, (r) {
      calls++;
      return calls == 1 ? FakeResponse.fail(type) : const FakeResponse({'ok': true});
    });
  }

  setUp(() {
    api = FakeApi();
    reprobes = 0;
    reprobeResult = tailscale;
  });

  test('GET after a connection error is retried once against the re-probed URL', () async {
    failFirst('GET', '/library/tv', DioExceptionType.connectionError);
    final res = await dio().getMap('/library/tv');
    expect(res, {'ok': true});
    expect(reprobes, 1);
    expect(api.requests, hasLength(2));
    expect(api.requests.first.uri.host, '192.168.10.183');
    expect(api.requests.last.uri.host, 'zenith.example.ts.net');
    expect(api.requests.last.headers['Authorization'], 'Bearer yha_token');
  });

  test('GET after a receive timeout is retried', () async {
    failFirst('GET', '/health', DioExceptionType.receiveTimeout);
    expect(await dio().getMap('/health'), {'ok': true});
    expect(api.requests, hasLength(2));
  });

  test('HEAD after a send timeout is retried', () async {
    failFirst('HEAD', '/ping', DioExceptionType.sendTimeout);
    final res = await dio().head<Object?>('/ping');
    expect(res.statusCode, 200);
    expect(api.requests, hasLength(2));
  });

  for (final type in [DioExceptionType.connectionError, DioExceptionType.connectionTimeout]) {
    test('POST is retried after $type (the request never left the device)', () async {
      failFirst('POST', '/containers/sonarr/actions', type);
      expect(await dio().postMap('/containers/sonarr/actions', body: {'action': 'restart'}), {'ok': true});
      expect(api.requests, hasLength(2));
    });
  }

  for (final (method, type) in [
    ('POST', DioExceptionType.receiveTimeout),
    ('DELETE', DioExceptionType.receiveTimeout),
    ('PATCH', DioExceptionType.sendTimeout),
    ('PUT', DioExceptionType.sendTimeout),
  ]) {
    test('$method after $type is never retried: result unknown', () async {
      failFirst(method, '/library/tv/54', type);
      final d = dio();
      Future<JsonMap> send() => switch (method) {
        'POST' => d.postMap('/library/tv/54'),
        'DELETE' => d.deleteMap('/library/tv/54', query: {'confirm': true}),
        'PATCH' => d.patchMap('/library/tv/54', body: {'monitored': true}),
        _ => d.putMap('/library/tv/54', body: {}),
      };
      await expectLater(
        send(),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', ClientErrorCode.resultUnknown)),
      );
      expect(api.requests, hasLength(1));
    });
  }

  test('nothing reachable: the GET fails with a network error after one probe', () async {
    reprobeResult = null;
    api.on('GET', '/dashboard', (_) => const FakeResponse.fail(DioExceptionType.connectionError));
    await expectLater(
      dio().getMap('/dashboard'),
      throwsA(isA<ApiException>().having((e) => e.isNetwork, 'isNetwork', isTrue)),
    );
    expect(reprobes, 1);
    expect(api.requests, hasLength(1));
  });

  test('a failed retry is not retried again', () async {
    api.on('GET', '/dashboard', (_) => const FakeResponse.fail(DioExceptionType.connectionError));
    await expectLater(dio().getMap('/dashboard'), throwsA(isA<ApiException>()));
    expect(api.requests, hasLength(2));
    expect(reprobes, 1);
  });

  test('HTTP errors are not failover cases', () async {
    api.on('GET', '/library/tv', (_) => FakeResponse.error(503, ApiErrorCode.upstreamUnavailable, message: 'Sonarr is not reachable.'));
    await expectLater(
      dio().getMap('/library/tv'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', ApiErrorCode.upstreamUnavailable)
            .having((e) => e.status, 'status', 503)
            .having((e) => e.message, 'message', 'Sonarr is not reachable.')
            .having((e) => e.requestId, 'requestId', 'test-request-id'),
      ),
    );
    expect(reprobes, 0);
    expect(api.requests, hasLength(1));
  });

  test('without a resolved server nothing leaves the device', () async {
    final d = createHubDio(baseUrl: null, session: _NoSession(), adapter: api, reprobe: () async => null);
    await expectLater(
      d.getMap('/dashboard'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', ClientErrorCode.noServer)),
    );
    expect(api.requests, isEmpty);
  });

  test('a request made while the server is still resolving waits for it', () async {
    api.getJson('/dashboard', {'ok': true});
    final resolved = Completer<String?>();
    final d = createHubDio(
      baseUrl: null,
      session: _NoSession(),
      adapter: api,
      reprobe: () async => null,
      awaitServer: () => resolved.future,
    );
    final pending = d.getMap('/dashboard');
    await Future<void>.delayed(Duration.zero);
    expect(api.requests, isEmpty, reason: 'nothing is sent before a URL passed resolution');
    resolved.complete(lan);
    expect(await pending, {'ok': true});
    expect(api.requests.single.uri.toString(), '$lan/dashboard');
    expect(api.requests.single.headers['Authorization'], 'Bearer yha_token');
  });

  test('resolution without a usable URL still fails with no_server', () async {
    final d = createHubDio(
      baseUrl: null,
      session: _NoSession(),
      adapter: api,
      reprobe: () async => null,
      awaitServer: () async => null,
    );
    await expectLater(
      d.getMap('/dashboard'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', ClientErrorCode.noServer)),
    );
    expect(api.requests, isEmpty);
  });

  test('every request carries X-YAMS-Client', () async {
    api.getJson('/server', {'ok': true});
    await dio().getMap('/server');
    expect(api.requests.single.headers[hubClientHeaderName], startsWith('yams-hub/'));
  });
}
