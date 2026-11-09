import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/api/api_client.dart';
import 'package:yams_hub/core/servers/onboarding_screen.dart' show UrlProbe, defaultServerUrl;
import 'package:yams_hub/core/settings/app_settings.dart';
import 'package:yams_hub/features/settings/data/settings_api.dart';
import 'package:yams_hub/features/settings/providers/settings_providers.dart';
import 'package:yams_hub/features/settings/screens/media_apps_screen.dart';
import 'package:yams_hub/features/settings/screens/refresh_screen.dart';
import 'package:yams_hub/features/settings/screens/server_editor_screen.dart';
import 'package:yams_hub/features/settings/widgets/settings_widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/builders.dart';
import '../../support/fake_api.dart';
import 'settings_fixtures.dart';

SettingsApi apiOver(FakeApi fake) {
  final dio = Dio(BaseOptions(baseUrl: 'http://192.168.10.183:8090/api/v1'))..httpClientAdapter = fake;
  return SettingsApi(dio);
}

void main() {
  group('SettingsApi', () {
    test('change password posts both fields', () async {
      final fake = FakeApi()..on('POST', '/auth/password', (_) => const FakeResponse.noContent());
      await apiOver(fake).changePassword(currentPassword: 'old password', newPassword: 'new password 1');
      expect(fake.requestsTo('/auth/password').single.data, {
        'currentPassword': 'old password',
        'newPassword': 'new password 1',
      });
    });

    test('sessions: own by default, every user with all=true', () async {
      final fake = FakeApi()
        ..getJson('/auth/sessions', itemList([sampleSession('s_1', current: true).toJson()]));
      final api = apiOver(fake);
      expect((await api.sessions()).single.id, 's_1');
      await api.sessions(all: true);
      expect(fake.requests[0].uri.queryParameters, isEmpty);
      expect(fake.requests[1].uri.queryParameters, {'all': 'true'});
    });

    test('user mutations hit the admin routes; delete sends confirm=true', () async {
      final created = hubUser('u_new', 'Erin');
      final fake = FakeApi()
        ..postJson('/admin/users', created.toJson(), status: 201)
        ..on('PATCH', '/admin/users/u_new', (_) => FakeResponse(created.toJson()))
        ..on('DELETE', '/admin/users/u_new', (_) => const FakeResponse.noContent());
      final api = apiOver(fake);
      final user = await api.createUser(
        const CreateUserRequest(username: 'erin', displayName: 'Erin', password: 'long enough!', role: Role.member),
      );
      expect(user.id, 'u_new');
      await api.updateUser('u_new', const UpdateUserRequest(jellyfinUserId: ''));
      expect(fake.requestsTo('/admin/users/u_new', method: 'PATCH').single.data, {'jellyfinUserId': ''});
      await api.deleteUser('u_new');
      expect(fake.requestsTo('/admin/users/u_new', method: 'DELETE').single.uri.queryParameters, {'confirm': 'true'});
    });

    test('import into Seerr returns the re-read option', () async {
      final fake = FakeApi()
        ..postJson(
          '/admin/jellyfin-users/$jfCarol/import-to-seerr',
          sampleJellyfinUsers(carolImported: true)[1].toJson(),
        );
      final option = await apiOver(fake).importToSeerr(jfCarol);
      expect(option.seerrUserId, 7);
    });

    test('audit sends page, page size and only the set filters', () async {
      final fake = FakeApi()
        ..getJson(
          '/admin/audit',
          PagedList<AuditEntry>.of(
            items: [auditEntry('a1', 'library.tv.delete')],
            page: 2,
            pageSize: 50,
            total: 51,
          ).toJson((e) => e.toJson()),
        );
      final page = await apiOver(fake).audit(
        page: 2,
        filter: const AuditFilter(userId: adaId, actionPrefix: ' library. ', outcome: AuditOutcome.error),
      );
      expect(page.items.single.action, 'library.tv.delete');
      expect(fake.requests.single.uri.queryParameters, {
        'page': '2',
        'pageSize': '50',
        'userId': adaId,
        'action': 'library.',
        'outcome': 'error',
      });
      await apiOver(fake).audit(page: 1);
      expect(fake.requests.last.uri.queryParameters, {'page': '1', 'pageSize': '50'});
    });

    test('gateway errors surface as ApiException with the code', () async {
      final fake = FakeApi()
        ..on('POST', '/auth/password', (_) => FakeResponse.error(401, ApiErrorCode.invalidCredentials));
      await expectLater(
        apiOver(fake).changePassword(currentPassword: 'x', newPassword: 'yyyyyyyyyy'),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', ApiErrorCode.invalidCredentials)),
      );
    });
  });

  group('users and Seerr links', () {
    final options = sampleJellyfinUsers();

    test('members without a Jellyfin user or without a Seerr account are flagged', () {
      final users = {for (final u in sampleUsers()) u.id: u};
      expect(seerrLinkIssue(users[adaId]!, options), isNull, reason: 'admins act as Seerr user 1');
      expect(seerrLinkIssue(users[bobId]!, options), isNull);
      expect(seerrLinkIssue(users[carolId]!, options), SeerrLinkIssue.noSeerrAccount);
      expect(seerrLinkIssue(users[daveId]!, options), SeerrLinkIssue.noJellyfinLink);
      expect(seerrLinkIssue(users[carolId]!, null), isNull, reason: 'unknown without the Jellyfin list');
      expect(seerrLinkIssue(users[carolId]!, sampleJellyfinUsers(carolImported: true)), isNull);
    });

    test('Jellyfin ids match without dashes and case', () {
      const dashed = '0B0B0B0B-0B0B-0B0B-0B0B-0B0B0B0B0B0B';
      expect(jellyfinOptionFor(dashed, options)?.name, 'bob');
      expect(jellyfinOptionFor(null, options), isNull);
    });

    test('users sort admins first, then by name', () {
      final sorted = sortUsers([hubUser('1', 'zed'), hubUser('2', 'Amy'), hubUser('3', 'Max', role: Role.admin)]);
      expect(sorted.map((u) => u.displayName), ['Max', 'Amy', 'zed']);
    });

    test('sessions sort the current one first, then by last activity', () {
      final sorted = sortSessions([
        sampleSession('old', ago: const Duration(days: 2)),
        sampleSession('new', ago: const Duration(minutes: 1)),
        sampleSession('me', current: true, ago: const Duration(hours: 5)),
      ]);
      expect(sorted.map((s) => s.id), ['me', 'new', 'old']);
    });
  });

  group('server profiles', () {
    test('the default address is the page origin on web and empty elsewhere', () {
      expect(defaultServerUrl(web: false, base: Uri.parse('http://10.0.0.2:8090/home')), '');
      expect(defaultServerUrl(web: true, base: Uri.parse('http://10.0.0.2:8090/home?x=1#y')), 'http://10.0.0.2:8090');
      expect(defaultServerUrl(web: true, base: Uri.parse('https://hub.example.com/')), 'https://hub.example.com');
      expect(defaultServerUrl(web: true, base: Uri.parse('file:///index.html')), '');
      expect(defaultServerUrl(), '', reason: 'tests run on the VM, not the web');
    });

    UrlProbe ok(String instanceId) =>
        UrlProbe.ok(buildPing(instanceId: instanceId), const Duration(milliseconds: 12));
    const failed = UrlProbe.failed("Can't reach the hub.");

    test('no answer is reported as unreachable, not as an error', () {
      final r = checkProfileProbes(probes: {testLanUrl: failed}, existing: buildProfile(), others: const []);
      expect(r.error, isNull);
      expect(r.unreachable, isTrue);
    });

    test('URLs of different hubs are rejected', () {
      final r = checkProfileProbes(
        probes: {testLanUrl: ok('a'), testTailscaleUrl: ok('b')},
        existing: null,
        others: const [],
      );
      expect(r.error, 'The addresses belong to different hubs.');
    });

    test('an edited profile must stay on its hub', () {
      final r = checkProfileProbes(probes: {testLanUrl: ok('other')}, existing: buildProfile(), others: const []);
      expect(r.error, contains('different hub than Zenith'));
    });

    test('a new profile for a hub that is already set up is rejected', () {
      final r = checkProfileProbes(
        probes: {testLanUrl: ok(testInstanceId)},
        existing: null,
        others: [buildProfile(name: 'Home')],
      );
      expect(r.error, 'This hub is already set up as Home.');
    });

    test('a valid new profile learns the instance id', () {
      final r = checkProfileProbes(probes: {testLanUrl: ok('fresh'), testTailscaleUrl: failed}, existing: null, others: const []);
      expect(r.error, isNull);
      expect(r.unreachable, isFalse);
      expect(r.instanceId, 'fresh');
    });
  });

  group('refresh table', () {
    test('intervals follow the preset', () {
      const dashboard = Duration(seconds: 15);
      expect(intervalLabel(RefreshPreset.normal, dashboard), 'Every 15 s');
      expect(intervalLabel(RefreshPreset.fast, dashboard), 'Every 7.5 s');
      expect(intervalLabel(RefreshPreset.batterySaver, dashboard), 'Every 45 s');
      expect(intervalLabel(RefreshPreset.manual, dashboard), 'Pull to refresh');
      expect(intervalLabel(RefreshPreset.fast, const Duration(seconds: 2)), 'Every 1 s');
      expect(intervalLabel(RefreshPreset.batterySaver, const Duration(seconds: 30)), 'Every 1 min 30 s');
      expect(intervalLabel(RefreshPreset.batterySaver, const Duration(minutes: 5)), 'Every 15 min');
      expect(intervalLabel(RefreshPreset.fast, null), 'Pull to refresh');
    });

    test('the table covers APP.md §14', () {
      expect(refreshTable, hasLength(11));
      expect(refreshTable.where((r) => r.base == null), hasLength(1));
    });
  });

  group('validation', () {
    test('password strength', () {
      expect(PasswordStrength.of('short'), PasswordStrength.tooShort);
      expect(PasswordStrength.of('aaaaaaaaaaaa'), PasswordStrength.weak);
      expect(PasswordStrength.of('abcdefghij'), PasswordStrength.weak);
      expect(PasswordStrength.of('abcdefgh12'), PasswordStrength.fair);
      expect(PasswordStrength.of('Abcdefgh12!x'), PasswordStrength.strong);
      expect(PasswordStrength.of('correct horse battery staple'), PasswordStrength.strong);
    });

    test('base URL overrides', () {
      expect(validateBaseUrl(''), isNull);
      expect(validateBaseUrl('http://192.168.10.183:8096'), isNull);
      expect(validateBaseUrl('jellyfin.example.ts.net:8096'), isNull);
      expect(validateBaseUrl('https://media.example.com/jellyfin'), isNull);
      expect(validateBaseUrl('ftp://nas'), isNotNull);
      expect(validateBaseUrl('http://nas:8096/?x=1'), isNotNull);
    });

    test('custom schemes', () {
      expect(validateScheme(''), isNull);
      expect(validateScheme('jellyfin://'), isNull);
      expect(validateScheme('swiftfin'), isNull);
      expect(validateScheme('https://'), isNotNull);
      expect(validateScheme('1bad://'), isNotNull);
    });

    test('every launcher app is configurable, in launcher order', () {
      expect(configurableApps, hasLength(13));
      expect(configurableApps.first, ExternalApp.jellyfin);
      expect(configurableApps.last, ExternalApp.portainer);
    });
  });
}
