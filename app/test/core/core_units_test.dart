import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/api/api_exception.dart';
import 'package:yams_hub/core/api/retry.dart';
import 'package:yams_hub/core/app_info.dart';
import 'package:yams_hub/core/dashboard/alerts_panel.dart';
import 'package:yams_hub/core/dashboard/dashboard_providers.dart';
import 'package:yams_hub/core/dashboard/dashboard_screen.dart';
import 'package:yams_hub/core/intents/incoming_links.dart';
import 'package:yams_hub/core/routing/router.dart';
import 'package:yams_hub/core/routing/shell_scaffold.dart';
import 'package:yams_hub/core/servers/network_kind.dart';
import 'package:yams_hub/core/servers/server_connection.dart';
import 'package:yams_hub/core/servers/server_profile.dart';
import 'package:yams_hub/core/settings/app_settings.dart';
import 'package:yams_hub/core/widgets/formatters.dart';
import 'package:yams_hub/core/widgets/hub_image.dart';
import 'package:yams_models/yams_models.dart';

import '../support/builders.dart';

void main() {
  group('global redirect', () {
    const noProfile = RedirectState(hasProfile: false, signedIn: false, profilesEditable: true);
    const signedOut = RedirectState(hasProfile: true, signedIn: false, profilesEditable: true);
    const signedIn = RedirectState(hasProfile: true, signedIn: true, profilesEditable: true);
    const webSignedOut = RedirectState(hasProfile: true, signedIn: false, profilesEditable: false);

    String? go(RedirectState s, String location) => globalRedirect(s, Uri.parse(location));

    test('no server → onboarding', () {
      expect(go(noProfile, '/home'), '/onboarding');
      expect(go(noProfile, '/login'), '/onboarding');
      expect(go(noProfile, '/onboarding'), isNull);
    });

    test('signed out → /login?from=<path with query>', () {
      expect(go(signedOut, '/requests/list?tab=pending'), '/login?from=%2Frequests%2Flist%3Ftab%3Dpending');
      expect(go(signedOut, '/login'), isNull);
      expect(go(signedOut, '/onboarding'), isNull, reason: '"Change server" stays reachable');
      expect(go(signedOut, '/'), '/login');
    });

    test('gateway-served web: no onboarding', () {
      expect(go(webSignedOut, '/onboarding'), '/login?from=%2Fonboarding');
    });

    test('signed in: login/onboarding go to from or /home; other routes pass', () {
      expect(go(signedIn, '/login?from=%2Flibrary%2Ftv%2F54'), '/library/tv/54');
      expect(go(signedIn, '/login'), '/home');
      expect(go(signedIn, '/login?from=https://evil.example'), '/home');
      expect(go(signedIn, '/login?from=//evil.example'), '/home');
      expect(go(signedIn, '/onboarding'), '/home');
      expect(go(signedIn, '/containers/sonarr'), isNull);
    });
  });

  group('network kind and plain-HTTP warning', () {
    test('classification', () {
      expect(networkKindOf(Uri.parse('http://192.168.10.183:8090')), NetworkKind.lan);
      expect(networkKindOf(Uri.parse('http://10.0.0.2')), NetworkKind.lan);
      expect(networkKindOf(Uri.parse('http://172.20.1.1')), NetworkKind.lan);
      expect(networkKindOf(Uri.parse('http://169.254.3.4')), NetworkKind.lan);
      expect(networkKindOf(Uri.parse('http://localhost:5173')), NetworkKind.lan);
      expect(networkKindOf(Uri.parse('http://[fe80::1]:80')), NetworkKind.lan);
      expect(networkKindOf(Uri.parse('http://100.64.0.1')), NetworkKind.tailscale);
      expect(networkKindOf(Uri.parse('http://100.127.255.254')), NetworkKind.tailscale);
      expect(networkKindOf(Uri.parse('http://zenith.tail1234.ts.net:8090')), NetworkKind.tailscale);
      expect(networkKindOf(Uri.parse('http://100.128.0.1')), NetworkKind.internet);
      expect(networkKindOf(Uri.parse('http://172.32.0.1')), NetworkKind.internet);
      expect(networkKindOf(Uri.parse('http://hub.example.com')), NetworkKind.internet);
    });

    test('warning only for plain http to the internet', () {
      expect(needsPlainHttpWarning(Uri.parse('http://hub.example.com:8090')), isTrue);
      expect(needsPlainHttpWarning(Uri.parse('https://hub.example.com')), isFalse);
      expect(needsPlainHttpWarning(Uri.parse('http://192.168.10.183:8090')), isFalse);
      expect(needsPlainHttpWarning(Uri.parse('http://zenith.x.ts.net:8090')), isFalse);
    });

    test('server URL parsing', () {
      expect(parseServerUrl('192.168.10.183:8090').toString(), 'http://192.168.10.183:8090');
      expect(parseServerUrl(' https://hub.lan/path?x=1 ').toString(), 'https://hub.lan');
      expect(parseServerUrl('ftp://x'), isNull);
      expect(parseServerUrl(''), isNull);
    });
  });

  group('ApiException', () {
    RequestOptions req() => RequestOptions(path: '/x');

    test('maps the gateway error body', () {
      final e = ApiException.from(
        DioException(
          requestOptions: req(),
          response: Response(
            requestOptions: req(),
            statusCode: 429,
            data: const ApiError(
              code: ApiErrorCode.rateLimited,
              message: 'Too many',
              status: 429,
              retryAfterSeconds: 120,
            ).toResponseBody(),
          ),
          type: DioExceptionType.badResponse,
        ),
      );
      expect(e.code, ApiErrorCode.rateLimited);
      expect(e.retryAfterSeconds, 120);
    });

    test('non-JSON error bodies map by status; transport errors to network/timeout', () {
      final e = ApiException.from(
        DioException(
          requestOptions: req(),
          response: Response(requestOptions: req(), statusCode: 502, data: '<html>bad gateway</html>'),
          type: DioExceptionType.badResponse,
        ),
      );
      expect(e.code, ApiErrorCode.upstreamError);
      expect(
        ApiException.from(DioException(requestOptions: req(), type: DioExceptionType.connectionError)).code,
        ClientErrorCode.network,
      );
      expect(
        ApiException.from(DioException(requestOptions: req(), type: DioExceptionType.receiveTimeout)).code,
        ClientErrorCode.timeout,
      );
      expect(ApiException.tryFrom(StateError('bug')), isNull);
    });

    test('retry policy: no retry below 500, network at most twice', () {
      const notFound = ApiException(status: 404, code: ApiErrorCode.notFound, message: '');
      expect(hubRetry(0, notFound), isNull);
      expect(hubRetry(0, const ApiException.network()), const Duration(seconds: 1));
      expect(hubRetry(1, const ApiException.network()), const Duration(seconds: 3));
      expect(hubRetry(2, const ApiException.network()), isNull);
      expect(hubRetry(0, const ApiException.resultUnknown()), isNull);
      expect(hubRetry(0, const FormatException('x')), isNull);
    });
  });

  test('version compatibility', () {
    expect(compareVersions('1.0.0', '1.0.0'), 0);
    expect(compareVersions('1.2.0', '1.10.0'), lessThan(0));
    expect(compareVersions('2.0', '1.9.9'), greaterThan(0));
    expect(incompatibilityReason(apiVersion: 1, minAppVersion: '1.0.0'), isNull);
    expect(incompatibilityReason(apiVersion: 2, minAppVersion: '1.0.0'), contains('newer app'));
    expect(incompatibilityReason(apiVersion: 0, minAppVersion: '1.0.0'), contains('older app'));
    expect(incompatibilityReason(apiVersion: 1, minAppVersion: '9.0.0'), contains('9.0.0'));
  });

  test('incoming magnet links open /activity/add', () {
    const magnet = 'magnet:?xt=urn:btih:abc&dn=Show';
    final route = routeForIncomingLink(magnet)!;
    expect(Uri.parse(route).path, '/activity/add');
    expect(Uri.parse(route).queryParameters['url'], magnet);
    expect(routeForIncomingLink('https://example.com'), isNull);
  });

  group('formatters', () {
    test('bytes (binary) and speeds (decimal)', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1536), '1.5 KiB');
      expect(formatBytes(1496206957), '1.4 GiB');
      expect(formatBytes(1024 * 1024 * 1024 * 250), '250 GiB');
      expect(formatBps(12300000), '12.3 MB/s');
      expect(formatBps(950), '950 B/s');
      expect(formatBps(0), '0 B/s');
      expect(formatBps(null), '–');
    });

    test('durations and ETAs', () {
      expect(formatDuration(const Duration(seconds: 42)), '42s');
      expect(formatDuration(const Duration(minutes: 5, seconds: 3)), '5m 03s');
      expect(formatDuration(const Duration(hours: 1, minutes: 23)), '1h 23m');
      expect(formatDuration(const Duration(days: 2, hours: 4)), '2d 4h');
      expect(formatEta(8640000), '∞');
      expect(formatEta(null), '∞');
      expect(formatEta(90), '1m 30s');
    });

    test('relative times', () {
      final now = DateTime.utc(2026, 11, 8, 12);
      expect(formatRelative(now.subtract(const Duration(seconds: 10)), now: now), 'just now');
      expect(formatRelative(now.subtract(const Duration(minutes: 5)), now: now), '5 min ago');
      expect(formatRelative(now.subtract(const Duration(hours: 3)), now: now), '3 h ago');
      expect(formatRelative(now.subtract(const Duration(days: 2)), now: now), '2 days ago');
      expect(formatRelative(now.add(const Duration(minutes: 10)), now: now), 'in 10 min');
    });

    test('calendar dates are not time-zone converted', () {
      expect(formatCalendarDate('2026-11-08'), 'Nov 8, 2026');
      expect(formatCalendarDate('soon'), 'soon');
    });
  });

  group('dashboard', () {
    test('a fast refresh replaces its cards and their alerts only', () {
      final current = DashboardResponse.fromJson(
        buildDashboardJson(
          alerts: [
            buildAlert(id: 'vpn.down', feature: 'activity'),
            buildAlert(id: 'raid.degraded', feature: 'system', severity: AlertSeverity.critical),
            buildAlert(id: 'seerr.pending', feature: 'requests', severity: AlertSeverity.info),
          ],
        ),
      );
      final partial = DashboardResponse(
        generatedAt: testNow.add(const Duration(seconds: 5)),
        alerts: [buildAlert(id: 'vpn.port', feature: 'activity', severity: AlertSeverity.warning)],
        cards: {
          DashboardCardKeys.activity: buildSection({
            'counts': {'attention': 0},
          }),
          DashboardCardKeys.system: buildSection({'cpuPercent': 50.0}),
        },
      );
      final merged = mergeDashboard(current, partial);
      expect(merged.alerts.map((a) => a.id), unorderedEquals(['seerr.pending', 'vpn.port']));
      expect(merged.card(DashboardCardKeys.system)!.data!['cpuPercent'], 50.0);
      expect(merged.card(DashboardCardKeys.requests), isNotNull);
      expect(merged.generatedAt, partial.generatedAt);
    });

    test('alerts sort by severity and drop dismissed ones', () {
      final alerts = [
        buildAlert(id: 'a', severity: AlertSeverity.info, dismissible: true),
        buildAlert(id: 'b', severity: AlertSeverity.critical),
        buildAlert(id: 'c', severity: AlertSeverity.warning, dismissible: true),
        buildAlert(id: 'd', severity: AlertSeverity.warning),
      ];
      expect(visibleAlerts(alerts, {'c'}).map((a) => a.id), ['b', 'd', 'a']);
      expect(visibleAlerts(alerts, {'d'}).length, 4, reason: 'non-dismissible alerts cannot be hidden');
    });

    test('masonry columns and shell layout by width', () {
      expect(dashboardColumnsFor(400), 1);
      expect(dashboardColumnsFor(800), 2);
      expect(dashboardColumnsFor(1300), 3);
      expect(ShellLayout.forWidth(599), ShellLayout.compact);
      expect(ShellLayout.forWidth(600), ShellLayout.medium);
      expect(ShellLayout.forWidth(1199), ShellLayout.medium);
      expect(ShellLayout.forWidth(1200), ShellLayout.expanded);
    });
  });

  group('settings', () {
    test('round trip and defaults', () {
      const defaults = AppSettings();
      expect(defaults.themeMode, ThemeMode.dark);
      expect(defaults.refreshPreset, RefreshPreset.normal);
      expect(defaults.visibleCards, DashboardCardKeys.all);
      final s = defaults.copyWith(
        hiddenCards: {DashboardCardKeys.media},
        hiddenLauncherApps: {ExternalApp.portainer},
        cardOrder: [DashboardCardKeys.requests],
        appSchemes: {ExternalApp.jellyfin: 'jellyfin://'},
        refreshPreset: RefreshPreset.batterySaver,
      );
      final back = AppSettings.fromJson(s.toJson());
      expect(back.hiddenLauncherApps, {ExternalApp.portainer});
      expect(back.visibleCards.first, DashboardCardKeys.requests);
      expect(back.visibleCards, isNot(contains(DashboardCardKeys.media)));
      expect(back.appSchemes[ExternalApp.jellyfin], 'jellyfin://');
      expect(back.refreshPreset, RefreshPreset.batterySaver);
    });

    test('preset scaling', () {
      const base = Duration(seconds: 2);
      expect(RefreshPreset.fast.scale(base), const Duration(seconds: 1));
      expect(RefreshPreset.fast.scale(const Duration(seconds: 1)), const Duration(seconds: 1), reason: 'min 1 s');
      expect(RefreshPreset.batterySaver.scale(base), const Duration(seconds: 6));
      expect(RefreshPreset.manual.scale(base), isNull);
    });
  });

  test('image paths: active base + path; /yh prefix on cookie transport', () {
    final bearer = ServerConnection(status: ConnectionStatus.connected, baseUrl: testLanUrl);
    final cookie = ServerConnection(
      status: ConnectionStatus.connected,
      baseUrl: testLanUrl,
      transport: ApiTransport.cookie,
    );
    const path = '/api/v1/img/arr/sonarr/54/poster?size=250&v=63905';
    expect(hubImageUrl(path, bearer), 'http://192.168.10.183:8090$path');
    expect(hubImageUrl(path, cookie), 'http://192.168.10.183:8090/yh$path');
    expect(hubImageUrl(path, const ServerConnection(status: ConnectionStatus.resolving)), isNull);
    expect(hubImageUrl(null, bearer), isNull);
    // Never an absolute URL: the bearer token would travel to that host.
    expect(hubImageUrl('https://evil.example/x.jpg', bearer), isNull);
    expect(hubImageUrl('//evil.example/x.jpg', bearer), isNull);
  });
}
