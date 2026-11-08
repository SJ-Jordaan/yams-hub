import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/links/external_links.dart';
import 'package:yams_models/yams_models.dart';

import '../support/builders.dart';

void main() {
  const jellyfinItem = '/web/#/details?id=4f5731b2c357273bf4002dd8d042a856&serverId=79315eab3c4c401f8391d5c26210b6d7';

  test('host of the active server + the configured port, path appended as-is', () {
    final r = ExternalLinkResolver(serverRoot: testLanUrl, config: buildServerConfig());
    expect(
      r.resolve(const ExternalLink(ExternalApp.jellyfin, jellyfinItem)).toString(),
      'http://192.168.10.183:8096$jellyfinItem',
    );
    expect(r.resolve(const ExternalLink(ExternalApp.shelfmark, '/')).toString(), 'http://192.168.10.183:8084/');
  });

  test('defaults apply before GET /server answered', () {
    final r = ExternalLinkResolver(serverRoot: testTailscaleUrl);
    expect(r.baseFor(ExternalApp.audiobookshelf).toString(), 'http://zenith.example.ts.net:13378');
  });

  test('gateway baseUrl override, then the user override, win', () {
    final config = ServerConfig(
      version: '1',
      instanceId: 'x',
      externalApps: {ExternalApp.kavita: const ExternalAppConfig(port: 5000, baseUrl: 'http://books.lan/')},
    );
    var r = ExternalLinkResolver(serverRoot: testLanUrl, config: config);
    expect(r.resolve(const ExternalLink(ExternalApp.kavita, '/library')).toString(), 'http://books.lan/library');
    r = ExternalLinkResolver(
      serverRoot: testLanUrl,
      config: config,
      overrides: {ExternalApp.kavita: 'kavita.example:8443'},
    );
    expect(r.resolve(const ExternalLink(ExternalApp.kavita, 'library')).toString(), 'http://kavita.example:8443/library');
  });

  test('no server and no override: unresolvable', () {
    expect(const ExternalLinkResolver(serverRoot: null).resolve(const ExternalLink(ExternalApp.sonarr, '/')), isNull);
  });

  test('custom schemes', () {
    const r = ExternalLinkResolver(serverRoot: null, schemes: {ExternalApp.jellyfin: 'jellyfin'});
    expect(r.customScheme(ExternalApp.jellyfin).toString(), 'jellyfin://');
    expect(r.customScheme(ExternalApp.kavita), isNull);
  });
}
