import 'package:test/test.dart';

import '../support/test_hub.dart';
import 'stub_routes_data.dart';

final _param = RegExp(r'<[A-Za-z_][A-Za-z0-9_]*(?:\|([^>]*))?>');

/// The first registration (in order) whose shelf_router pattern matches
/// [method] [path], built the way shelf_router builds its regular
/// expressions (`<name|regex>`, default `[^/]+`).
RouteSpec? _firstMatch(List<RouteSpec> routes, String method, String path) {
  for (final r in routes) {
    if (r.method != method) continue;
    final sb = StringBuffer('^');
    var last = 0;
    for (final m in _param.allMatches(r.path)) {
      sb
        ..write(RegExp.escape(r.path.substring(last, m.start)))
        ..write('(?:${m[1] ?? '[^/]+'})');
      last = m.end;
    }
    sb
      ..write(RegExp.escape(r.path.substring(last)))
      ..write(r'$');
    if (RegExp(sb.toString()).hasMatch(path)) return r;
  }
  return null;
}

/// Whether [registered] is the registration intended for the API.md route
/// [intended]: same number of segments, and every static segment of the
/// intended route is the same static segment in the registration. Feature
/// slices may refine parameter regexes, rename parameters or split a
/// parameter into static alternatives; a parameter registered where API.md
/// has a static segment (static-after-parameter order) fails.
bool _sameRoute(String registered, String intended) {
  final a = registered.split('/');
  final b = intended.split('/');
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final staticIntended = !b[i].contains('<');
    if (staticIntended && a[i] != b[i]) return false;
  }
  return true;
}

void main() {
  late TestHub hub;
  setUpAll(() => hub = TestHub());
  tearDownAll(() => hub.close());

  test('every API.md feature route is registered and matched first', () async {
    await hub.ready;
    final routes = hub.hub.router.routes;
    for (final route in stubRoutes) {
      final match = _firstMatch(routes, route.method, route.path);
      expect(match, isNotNull, reason: '${route.method} ${route.path}');
      expect(
        _sameRoute(match!.path, route.pattern),
        isTrue,
        reason:
            '${route.method} ${route.path} is answered by $match instead of '
            '${route.pattern}: register static segments before parameters',
      );
    }
  });

  group('every stub route reaches its intended registration', () {
    for (final route in stubRoutes) {
      test('${route.method} ${route.path}', () async {
        final r = await hub.request(
          route.method,
          '/api/v1${route.path}',
          body: route.method == 'GET' ? null : {'confirm': true},
        );
        // Once a feature replaces its stub the route answers for real; until
        // then it is a 501 that names the registration that answered.
        if (r.status != 501) return;
        expect(r.errorCode, 'not_implemented');
        final details = readMap(readMap(r.map['error'])?['details']);
        final answered = readString(details?['route']);
        expect(answered, isNotNull);
        final pattern = answered!.substring(answered.indexOf(' ') + 1);
        expect(answered, startsWith('${route.method} '));
        expect(
          _sameRoute(pattern, route.pattern),
          isTrue,
          reason: 'answered by $answered',
        );
      });
    }
  });

  test('admin-only feature routes refuse members with 403', () async {
    for (final route in stubRoutes.where((r) => r.admin)) {
      final r = await hub.request(
        route.method,
        '/api/v1${route.path}',
        as: TestAs.member,
      );
      expect(r.status, 403, reason: '${route.method} ${route.path}');
      expect(r.errorCode, 'forbidden');
    }
  });

  test('route roles and audit flags follow API.md', () async {
    await hub.ready;
    for (final route in stubRoutes) {
      final spec = _firstMatch(
        hub.hub.router.routes,
        route.method,
        route.path,
      )!;
      expect(
        spec.role,
        route.admin ? Role.admin : Role.member,
        reason: '${route.method} ${route.pattern}',
      );
      if (route.method != 'GET') {
        expect(spec.audit, isTrue, reason: 'writes are audited');
      }
    }
  });

  test('the cookie mount serves the same routes', () async {
    // Core routes (feature routes answer whatever their fakes allow).
    for (final path in ['/jobs?active=true', '/auth/me', '/admin/users']) {
      final a = await hub.get('/api/v1$path');
      final b = await hub.get('/yh/api/v1$path');
      expect(a.status, 200, reason: path);
      expect(b.status, a.status, reason: path);
      expect(b.json, a.json, reason: path);
    }
    // Feature routes are mounted there too: a route missing from the cookie
    // mount would answer the JSON 404 of the outer router.
    for (final route in stubRoutes.where((r) => r.method == 'GET').take(5)) {
      final a = await hub.get('/api/v1${route.path}');
      final b = await hub.get('/yh/api/v1${route.path}');
      expect(b.status, a.status, reason: route.path);
    }
  });

  test('every feature module is registered with a dashboard card', () async {
    expect(hub.hub.modules.map((m) => m.id), [
      'requests',
      'library',
      'activity',
      'calendar',
      'indexers',
      'subtitles',
      'containers',
      'system',
      'media',
    ]);
    final r = await hub.get('/api/v1/dashboard');
    expect(r.status, 200);
    final cards = readMap(r.map['cards'])!;
    expect(cards.keys.toSet(), DashboardCardKeys.all.toSet());
    for (final c in cards.values) {
      final section = Section.fromJson(readMap(c)!);
      expect(section.status, isNot(SectionState.unknown));
      // Stub cards report not_implemented as an error section.
      if (section.error?.code == 'not_implemented') {
        expect(section.status, SectionState.error);
      }
    }
  });

  test('unknown paths and method mismatches return the JSON 404', () async {
    for (final (method, path) in [
      ('GET', '/api/v1/nope'),
      ('DELETE', '/api/v1/calendar'),
      ('POST', '/api/v1/system/host'),
      ('GET', '/api/v1/library/tv/abc'),
      ('GET', '/api/v1/containers/..'),
      ('POST', '/api/v1/containers/.hidden/actions'),
      ('GET', '/api/v2/ping'),
      ('GET', '/yh/whatever'),
    ]) {
      final r = await hub.request(method, path);
      expect(r.status, 404, reason: '$method $path');
      expect(r.headers['content-type'], startsWith('application/json'));
      expect(r.errorCode, 'not_found', reason: '$method $path');
      expect(r.body, isNot(contains('Route not found')));
    }
  });
}
