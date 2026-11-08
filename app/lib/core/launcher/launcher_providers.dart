/// The web-apps launcher model (ARCHITECTURE §7.9, APP.md §3.5).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_models/yams_models.dart';

import '../links/external_links.dart';
import '../servers/server_config_provider.dart';
import '../settings/app_settings.dart';

/// Launcher groups, in display order.
enum LauncherGroup {
  media('Media'),
  automation('Automation'),
  downloads('Downloads'),
  system('System');

  const LauncherGroup(this.label);

  final String label;
}

/// Static presentation of each launcher app: group and Material icon (no brand
/// assets), in display order within the group.
const Map<ExternalApp, ({LauncherGroup group, IconData icon})> launcherApps = {
  ExternalApp.jellyfin: (group: LauncherGroup.media, icon: Icons.live_tv),
  ExternalApp.audiobookshelf: (group: LauncherGroup.media, icon: Icons.headphones),
  ExternalApp.kavita: (group: LauncherGroup.media, icon: Icons.menu_book),
  ExternalApp.seerr: (group: LauncherGroup.media, icon: Icons.playlist_add),
  ExternalApp.shelfmark: (group: LauncherGroup.media, icon: Icons.auto_stories),
  ExternalApp.jellystat: (group: LauncherGroup.media, icon: Icons.insights),
  ExternalApp.sonarr: (group: LauncherGroup.automation, icon: Icons.tv),
  ExternalApp.radarr: (group: LauncherGroup.automation, icon: Icons.movie),
  ExternalApp.prowlarr: (group: LauncherGroup.automation, icon: Icons.travel_explore),
  ExternalApp.bazarr: (group: LauncherGroup.automation, icon: Icons.subtitles),
  ExternalApp.qbittorrent: (group: LauncherGroup.downloads, icon: Icons.swap_vert),
  ExternalApp.uptimeKuma: (group: LauncherGroup.system, icon: Icons.monitor_heart),
  ExternalApp.portainer: (group: LauncherGroup.system, icon: Icons.inventory_2),
};

/// One launcher tile.
@immutable
class LauncherEntry {
  const LauncherEntry({
    required this.app,
    required this.group,
    required this.icon,
    this.health,
    this.url,
  });

  final ExternalApp app;
  final LauncherGroup group;
  final IconData icon;

  /// Health of the app's service; null for Portainer (no probe) or when
  /// `GET /health` failed (no dot).
  final ServiceHealth? health;

  /// The web UI URL, null when it cannot be resolved.
  final Uri? url;

  String get name => app.displayName;
  ServiceHealthStatus? get status => health?.status;
  String? get version => health?.version;
  bool get isUp => health?.status == ServiceHealthStatus.up;
}

/// Builds the launcher tiles from `GET /server` `externalApps` plus
/// `GET /health`, leaving out [hidden] apps and apps the gateway does not
/// list, ordered by group then the [launcherApps] order. Pure, for tests.
List<LauncherEntry> buildLauncherEntries({
  required ServerConfig config,
  HealthReport? health,
  Set<ExternalApp> hidden = const {},
  Uri? Function(ExternalApp app)? resolveUrl,
}) {
  final healthById = {for (final s in health?.services ?? const <ServiceHealth>[]) s.id: s};
  final entries = <LauncherEntry>[];
  for (final group in LauncherGroup.values) {
    for (final MapEntry(key: app, value: spec) in launcherApps.entries) {
      if (spec.group != group) continue;
      if (hidden.contains(app) || !config.externalApps.containsKey(app)) continue;
      final serviceId = app.serviceId;
      entries.add(
        LauncherEntry(
          app: app,
          group: group,
          icon: spec.icon,
          health: serviceId == null ? null : healthById[serviceId],
          url: resolveUrl?.call(app),
        ),
      );
    }
  }
  return entries;
}

/// "13 apps · 12 up" (More screen subtitle).
String launcherSummary(List<LauncherEntry> entries) {
  final withStatus = entries.where((e) => e.health != null);
  final up = withStatus.where((e) => e.isUp).length;
  final apps = '${entries.length} ${entries.length == 1 ? 'app' : 'apps'}';
  return withStatus.isEmpty ? apps : '$apps · $up up';
}

/// The visible launcher tiles. Fails only when `GET /server` fails; a failed
/// `GET /health` just removes the status dots.
final launcherEntriesProvider = FutureProvider.autoDispose<List<LauncherEntry>>((ref) async {
  final hidden = ref.watch(appSettingsProvider.select((s) => s.hiddenLauncherApps));
  final resolver = ref.watch(externalLinkResolverProvider);
  final config = await ref.watch(serverConfigProvider.future);
  final health = ref.watch(healthProvider).value;
  return buildLauncherEntries(
    config: config,
    health: health,
    hidden: hidden,
    resolveUrl: (app) => resolver.resolve(ExternalLink(app, '/')),
  );
});
