import 'package:test/test.dart';
import 'package:yams_models/yams_models.dart';

import 'round_trip.dart';

final _userJson = <String, Object?>{
  'id': 'u_1a2b3c4d5e6f',
  'username': 'zandolor',
  'displayName': 'Zandolor',
  'role': 'admin',
  'jellyfinUserId': '4c0628aacef24bdfacd40f946ea33ee7',
  'disabled': false,
  'createdAt': '2026-11-01T10:00:00Z',
  'updatedAt': '2026-11-08T09:00:00Z',
};

final _sessionJson = <String, Object?>{
  'id': 's_0a1b2c3d4e5f',
  'userId': 'u_1a2b3c4d5e6f',
  'deviceName': 'Pixel 9',
  'platform': 'android',
  'createdAt': '2026-11-01T10:00:00Z',
  'lastSeenAt': '2026-11-08T08:59:00Z',
  'lastIp': '100.64.0.7',
  'expiresAt': '2026-12-01T10:00:00Z',
  'current': true,
};

final _tokensJson = <String, Object?>{
  'accessToken': 'yha_abc',
  'accessTokenExpiresAt': '2026-11-08T10:00:00Z',
  'refreshToken': 'yhr_s_0a1b2c3d4e5f.xyz',
  'refreshTokenExpiresAt': '2026-12-08T09:00:00Z',
};

void main() {
  group('Role', () {
    test('parses known and unknown values', () {
      expect(Role.fromJson('admin'), Role.admin);
      expect(Role.fromJson('member'), Role.member);
      expect(Role.fromJson('owner'), Role.unknown);
      expect(Role.fromJson(null), Role.unknown);
    });
    test('satisfies', () {
      expect(Role.admin.satisfies(Role.admin), isTrue);
      expect(Role.admin.satisfies(Role.member), isTrue);
      expect(Role.member.satisfies(Role.member), isTrue);
      expect(Role.member.satisfies(Role.admin), isFalse);
      expect(Role.unknown.satisfies(Role.member), isFalse);
      expect(Role.admin.satisfies(Role.unknown), isFalse);
    });
  });

  test('ClientPlatform and AuthTransport parse unknown values', () {
    expect(ClientPlatform.fromJson('ios'), ClientPlatform.ios);
    expect(ClientPlatform.fromJson('windows'), ClientPlatform.unknown);
    expect(AuthTransport.fromJson('cookie'), AuthTransport.cookie);
    expect(AuthTransport.fromJson('carrier-pigeon'), AuthTransport.unknown);
  });

  test('LoginRequest round trips; transport defaults to token', () {
    expectRoundTrip(
      {
        'username': 'zandolor',
        'password': 'correct horse battery',
        'deviceName': 'Pixel 9',
        'platform': 'android',
        'transport': 'cookie',
      },
      LoginRequest.fromJson,
      (r) => r.toJson(),
    );
    final r = LoginRequest.fromJson({
      'username': 'a',
      'password': 's3cret-hunter2',
      'deviceName': 'c',
      'platform': 'beos',
    });
    expect(r.transport, AuthTransport.token);
    expect(r.platform, ClientPlatform.unknown);
    expect(r.toString(), isNot(contains('s3cret-hunter2')));
    final bogus = LoginRequest.fromJson({
      'username': 'a',
      'password': 'b',
      'deviceName': 'c',
      'platform': 'web',
      'transport': 'cookies',
    });
    expect(bogus.transport, AuthTransport.unknown);
  });

  test('TokenPair round trips', () {
    final t = expectRoundTrip(
      _tokensJson,
      TokenPair.fromJson,
      (t) => t.toJson(),
    );
    expect(t.accessTokenExpiresAt, DateTime.utc(2026, 11, 8, 10));
    expect(t.toString(), isNot(contains('yha_')));
  });

  test('LoginResponse round trips for bearer and cookie transports', () {
    final bearer = expectRoundTrip(
      {
        'user': _userJson,
        'session': _sessionJson,
        'tokens': _tokensJson,
        'serverProofKey': 'q2Vh3x9bW1r0b2Ffc2VydmVyX3Byb29mX2tleQ',
      },
      LoginResponse.fromJson,
      (r) => r.toJson(),
    );
    expect(bearer.tokens?.accessToken, 'yha_abc');
    expect(bearer.serverProofKey, isNotNull);

    final cookie = expectRoundTrip(
      {'user': _userJson, 'session': _sessionJson},
      LoginResponse.fromJson,
      (r) => r.toJson(),
    );
    expect(cookie.tokens, isNull);
    expect(cookie.serverProofKey, isNull);
  });

  test('RefreshRequest and RefreshResponse round trip', () {
    expectRoundTrip(
      {'refreshToken': 'yhr_s_1.abc'},
      RefreshRequest.fromJson,
      (r) => r.toJson(),
    );
    expect(const RefreshRequest().toJson(), isEmpty);
    expectRoundTrip(
      {'tokens': _tokensJson},
      RefreshResponse.fromJson,
      (r) => r.toJson(),
    );
  });

  test('ChangePasswordRequest round trips', () {
    final r = expectRoundTrip(
      {'currentPassword': 'old password!', 'newPassword': 'new password!!'},
      ChangePasswordRequest.fromJson,
      (r) => r.toJson(),
    );
    expect(r.toString(), isNot(contains('password!')));
  });

  group('User', () {
    test('round trips', () {
      final u = expectRoundTrip(_userJson, User.fromJson, (u) => u.toJson());
      expect(u.isAdmin, isTrue);
    });
    test('round trips without optional fields; unknown role parses', () {
      final json = {..._userJson, 'role': 'superuser'}
        ..remove('jellyfinUserId');
      final u = User.fromJson(json);
      expect(u.role, Role.unknown);
      expect(u.jellyfinUserId, isNull);
      expect(u.toJson().containsKey('jellyfinUserId'), isFalse);
    });
    test('requires id and timestamps', () {
      expect(
        () => User.fromJson({..._userJson}..remove('createdAt')),
        throwsFormatException,
      );
      expect(
        () => User.fromJson({..._userJson}..remove('id')),
        throwsFormatException,
      );
    });
  });

  group('SessionInfo', () {
    test('round trips (with admin username)', () {
      expectRoundTrip(_sessionJson, SessionInfo.fromJson, (s) => s.toJson());
      expectRoundTrip(
        {..._sessionJson, 'current': false, 'username': 'alice'}
          ..remove('lastIp'),
        SessionInfo.fromJson,
        (s) => s.toJson(),
      );
    });
    test('unknown platform parses', () {
      final s = SessionInfo.fromJson({..._sessionJson, 'platform': 'tv'});
      expect(s.platform, ClientPlatform.unknown);
    });
  });

  group('MeResponse', () {
    test('round trips with a linked Seerr account and quotas', () {
      final me = expectRoundTrip(
        {
          'user': _userJson,
          'session': _sessionJson,
          'seerr': {
            'linked': true,
            'seerrUserId': 3,
            'displayName': 'Zandolor',
            'canAutoApprove': false,
            'quota': {
              'movie': {
                'limit': 10,
                'days': 7,
                'used': 2,
                'remaining': 8,
                'restricted': false,
              },
              'tv': {'used': 1, 'restricted': false},
            },
          },
        },
        MeResponse.fromJson,
        (m) => m.toJson(),
      );
      expect(me.seerr.quota?.movie.isUnlimited, isFalse);
      expect(me.seerr.quota?.tv.isUnlimited, isTrue);
      expect(me.seerr.quota?.tv.remaining, isNull);
    });

    test('round trips unlinked; missing seerr part means unlinked', () {
      expectRoundTrip(
        {
          'user': _userJson,
          'session': _sessionJson,
          'seerr': {'linked': false, 'canAutoApprove': false},
        },
        MeResponse.fromJson,
        (m) => m.toJson(),
      );
      final me = MeResponse.fromJson({
        'user': _userJson,
        'session': _sessionJson,
      });
      expect(me.seerr.linked, isFalse);
      expect(me.seerr.quota, isNull);
    });
  });

  test('CreateUserRequest round trips', () {
    final r = expectRoundTrip(
      {
        'username': 'alice',
        'displayName': 'Alice',
        'password': 'longenoughpw',
        'role': 'member',
        'jellyfinUserId': '0123456789abcdef0123456789abcdef',
      },
      CreateUserRequest.fromJson,
      (r) => r.toJson(),
    );
    expect(r.role, Role.member);
    expect(r.toString(), isNot(contains('longenoughpw')));
  });

  group('UpdateUserRequest', () {
    test('round trips full and partial bodies', () {
      expectRoundTrip(
        {
          'displayName': 'Alice B',
          'role': 'admin',
          'jellyfinUserId': '',
          'disabled': true,
          'password': 'anotherlongpw',
        },
        UpdateUserRequest.fromJson,
        (r) => r.toJson(),
      );
      final partial = expectRoundTrip(
        {'disabled': false},
        UpdateUserRequest.fromJson,
        (r) => r.toJson(),
      );
      expect(partial.role, isNull);
      expect(partial.isEmpty, isFalse);
      expect(const UpdateUserRequest().isEmpty, isTrue);
    });
    test('an unknown role parses to unknown, a missing one to null', () {
      expect(UpdateUserRequest.fromJson({'role': 'root'}).role, Role.unknown);
      expect(UpdateUserRequest.fromJson({}).role, isNull);
      expect(
        const UpdateUserRequest(password: 'secretsecret').toString(),
        isNot(contains('secretsecret')),
      );
    });
  });

  test('JellyfinUserOption round trips', () {
    expectRoundTrip(
      {
        'jellyfinUserId': '4c0628aacef24bdfacd40f946ea33ee7',
        'name': 'zandolor',
        'isAdministrator': true,
        'seerrUserId': 1,
        'seerrDisplayName': 'Zandolor',
        'linkedHubUserId': 'u_1a2b3c4d5e6f',
        'avatarPath': '/api/v1/img/jellyfin-user/4c0628aacef24bdfacd40f946ea33ee7?tag=abc',
      },
      JellyfinUserOption.fromJson,
      (o) => o.toJson(),
    );
    expectRoundTrip(
      {
        'jellyfinUserId': '0123456789abcdef0123456789abcdef',
        'name': 'guest',
        'isAdministrator': false,
      },
      JellyfinUserOption.fromJson,
      (o) => o.toJson(),
    );
  });

  group('AuditEntry', () {
    test('round trips', () {
      expectRoundTrip(
        {
          'id': 'a_01',
          'at': '2026-11-08T09:00:00.123Z',
          'userId': 'u_1a2b3c4d5e6f',
          'username': 'zandolor',
          'sessionId': 's_0a1b2c3d4e5f',
          'ip': '192.168.10.20',
          'action': 'library.series_delete',
          'target': 'sonarr:54',
          'params': {'deleteFiles': false},
          'outcome': 'error',
          'errorCode': 'upstream_timeout',
          'durationMs': 5012,
        },
        AuditEntry.fromJson,
        (e) => e.toJson(),
      );
    });
    test('unknown outcome parses to unknown', () {
      final e = AuditEntry.fromJson({
        'id': 'a',
        'at': '2026-11-08T09:00:00Z',
        'action': 'auth.login',
        'outcome': 'maybe',
        'durationMs': 3,
      });
      expect(e.outcome, AuditOutcome.unknown);
    });
  });
}
