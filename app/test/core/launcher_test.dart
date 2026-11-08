import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/launcher/launcher_providers.dart';
import 'package:yams_hub/core/links/external_links.dart';
import 'package:yams_models/yams_models.dart';

import '../support/builders.dart';

void main() {
  test('one tile per configured app, grouped Media, Automation, Downloads, System', () {
    final entries = buildLauncherEntries(config: buildServerConfig(), health: buildHealth());
    expect(entries.map((e) => e.app), [
      ExternalApp.jellyfin,
      ExternalApp.audiobookshelf,
      ExternalApp.kavita,
      ExternalApp.seerr,
      ExternalApp.shelfmark,
      ExternalApp.jellystat,
      ExternalApp.sonarr,
      ExternalApp.radarr,
      ExternalApp.prowlarr,
      ExternalApp.bazarr,
      ExternalApp.qbittorrent,
      ExternalApp.uptimeKuma,
      ExternalApp.portainer,
    ]);
    expect(entries.map((e) => e.group).toSet(), LauncherGroup.values.toSet());
  });

  test('hidden apps and apps the gateway does not list are left out', () {
    final entries = buildLauncherEntries(
      config: buildServerConfig(apps: [ExternalApp.jellyfin, ExternalApp.sonarr, ExternalApp.portainer]),
      hidden: {ExternalApp.sonarr},
    );
    expect(entries.map((e) => e.app), [ExternalApp.jellyfin, ExternalApp.portainer]);
  });

  test('status and version come from the service of the same name; Portainer has no dot', () {
    final entries = buildLauncherEntries(config: buildServerConfig(), health: buildHealth(down: {ServiceId.kavita}));
    LauncherEntry of(ExternalApp a) => entries.firstWhere((e) => e.app == a);
    expect(of(ExternalApp.jellyfin).status, ServiceHealthStatus.up);
    expect(of(ExternalApp.jellyfin).version, '1.2.3');
    expect(of(ExternalApp.kavita).status, ServiceHealthStatus.down);
    expect(of(ExternalApp.uptimeKuma).status, ServiceHealthStatus.up);
    expect(of(ExternalApp.portainer).health, isNull);
  });

  test('without health there are no dots, but every tile stays', () {
    final entries = buildLauncherEntries(config: buildServerConfig());
    expect(entries, hasLength(13));
    expect(entries.every((e) => e.status == null), isTrue);
    expect(launcherSummary(entries), '13 apps');
  });

  test('summary counts apps and the ones up', () {
    final entries = buildLauncherEntries(config: buildServerConfig(), health: buildHealth(down: {ServiceId.kavita}));
    expect(launcherSummary(entries), '13 apps · 11 up');
  });

  test('tiles open the app on the host the app is using', () {
    final resolver = ExternalLinkResolver(serverRoot: testTailscaleUrl, config: buildServerConfig());
    final entries = buildLauncherEntries(
      config: buildServerConfig(),
      resolveUrl: (app) => resolver.resolve(ExternalLink(app, '/')),
    );
    expect(entries.first.url.toString(), 'http://zenith.example.ts.net:8096/');
    expect(entries.firstWhere((e) => e.app == ExternalApp.shelfmark).url.toString(), 'http://zenith.example.ts.net:8084/');
  });
}
