/// Links into the services' own web UIs and apps (ARCHITECTURE §7.10).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:yams_models/yams_models.dart';

import '../platform/platform.dart';
import '../servers/server_config_provider.dart';
import '../servers/server_connection.dart';
import '../settings/app_settings.dart';

/// Ports of the policy defaults (ARCHITECTURE §5.2.1), used until `GET /server`
/// has answered.
const Map<ExternalApp, int> defaultExternalAppPorts = {
  ExternalApp.jellyfin: 8096,
  ExternalApp.audiobookshelf: 13378,
  ExternalApp.kavita: 5000,
  ExternalApp.seerr: 5055,
  ExternalApp.shelfmark: 8084,
  ExternalApp.sonarr: 8989,
  ExternalApp.radarr: 7878,
  ExternalApp.prowlarr: 9696,
  ExternalApp.bazarr: 6767,
  ExternalApp.qbittorrent: 8081,
  ExternalApp.uptimeKuma: 3001,
  ExternalApp.jellystat: 3002,
  ExternalApp.portainer: 9000,
};

/// Native apps that exist for a service, with their store pages. Shelfmark and
/// the admin UIs have none: `openApp` goes straight to the web UI.
const Map<ExternalApp, ({String android, String ios})> nativeAppStores = {
  ExternalApp.jellyfin: (
    android: 'https://play.google.com/store/apps/details?id=org.jellyfin.mobile',
    ios: 'https://apps.apple.com/search?term=Jellyfin',
  ),
  ExternalApp.audiobookshelf: (
    android: 'https://play.google.com/store/apps/details?id=com.audiobookshelf.app',
    ios: 'https://apps.apple.com/search?term=Audiobookshelf',
  ),
};

/// Resolves [ExternalLink]s to absolute URLs.
///
/// Base URL precedence: the user's override (Settings > Media apps), the
/// gateway's `externalApps.<app>.baseUrl`, then
/// `<scheme>://<active server host>:<port>`, so links follow the host the app
/// is using (LAN or Tailscale).
@immutable
class ExternalLinkResolver {
  const ExternalLinkResolver({
    required this.serverRoot,
    this.config,
    this.overrides = const {},
    this.schemes = const {},
  });

  /// The active hub root URL (scheme and host are reused).
  final Uri? serverRoot;
  final ServerConfig? config;
  final Map<ExternalApp, String> overrides;
  final Map<ExternalApp, String> schemes;

  /// The base URL of [app]'s web UI, or null when it cannot be derived.
  Uri? baseFor(ExternalApp app) {
    final override = overrides[app];
    if (override != null && override.isNotEmpty) return Uri.tryParse(_withScheme(override));
    final configured = config?.externalApps[app];
    final absolute = configured?.baseUrl;
    if (absolute != null && absolute.isNotEmpty) return Uri.tryParse(_withScheme(absolute));
    final root = serverRoot;
    final port = configured?.port ?? defaultExternalAppPorts[app];
    if (root == null || port == null || root.host.isEmpty) return null;
    return Uri(scheme: root.scheme, host: root.host, port: port);
  }

  /// [link.path] appended to the base of [link.app] (the path may carry a
  /// query and a `#` fragment route such as Jellyfin's `/web/#/details?id=`).
  Uri? resolve(ExternalLink link) {
    final base = baseFor(link.app);
    if (base == null) return null;
    var root = base.toString();
    while (root.endsWith('/')) {
      root = root.substring(0, root.length - 1);
    }
    final path = link.path.isEmpty ? '/' : (link.path.startsWith('/') ? link.path : '/${link.path}');
    return Uri.tryParse('$root$path');
  }

  /// The user's custom URL scheme for [app] (`jellyfin://`), if any.
  Uri? customScheme(ExternalApp app) {
    final s = schemes[app];
    if (s == null || s.isEmpty) return null;
    return Uri.tryParse(s.contains(':') ? s : '$s://');
  }

  static String _withScheme(String url) => url.contains('://') ? url : 'http://$url';
}

final externalLinkResolverProvider = Provider<ExternalLinkResolver>((ref) {
  final settings = ref.watch(appSettingsProvider);
  return ExternalLinkResolver(
    serverRoot: ref.watch(activeServerProvider.select((s) => s.baseUrl ?? s.profile?.urls.firstOrNull)),
    config: ref.watch(serverConfigProvider).value,
    overrides: settings.externalBaseUrls,
    schemes: settings.appSchemes,
  );
});

/// Opens [uri] outside the app (a new browser tab on web).
Future<bool> launchExternalUri(Uri uri) async {
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication, webOnlyWindowName: '_blank');
  } catch (_) {
    return false;
  }
}

/// Opens [link] in the service's web UI. False when it cannot be resolved or
/// launched.
Future<bool> openExternal(WidgetRef ref, ExternalLink link) async {
  final uri = ref.read(externalLinkResolverProvider).resolve(link);
  return uri != null && await launchExternalUri(uri);
}

/// Opens [app]: the user's custom URL scheme first, then the store page of the
/// native app (Android/iOS, Jellyfin and Audiobookshelf only), then the web UI.
Future<bool> openApp(WidgetRef ref, ExternalApp app) async {
  final resolver = ref.read(externalLinkResolverProvider);
  final scheme = resolver.customScheme(app);
  if (scheme != null && await launchExternalUri(scheme)) return true;
  final store = nativeAppStores[app];
  if (store != null && isMobile) {
    final url = Uri.parse(isAndroid ? store.android : store.ios);
    if (await launchExternalUri(url)) return true;
  }
  return openExternal(ref, ExternalLink(app, '/'));
}
