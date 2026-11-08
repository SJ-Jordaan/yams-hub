/// How this build reaches its hub (ARCHITECTURE §5.3, §7.5, §7.6).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'server_profile.dart';

/// Native app, web build served by the gateway, or the dev web server.
enum HostingMode {
  /// Android / iOS (or desktop): server profiles, bearer tokens.
  native,

  /// The release web build served by the gateway itself: one implicit profile
  /// for the page origin, cookie transport on `/yh/api/v1`, no server pages.
  gatewayWeb,

  /// `flutter run -d chrome` against a LAN gateway: server profiles, bearer
  /// tokens in sessionStorage (cookie transport when the origins match).
  devWeb;

  /// Whether the user manages server profiles (onboarding, Settings > Servers).
  bool get hasServerProfiles => this != gatewayWeb;
}

/// Set `--dart-define=YAMS_HUB_DEV_WEB=true` to use server profiles in a
/// release web build that is not served by the gateway.
const bool _forceDevWeb = bool.fromEnvironment('YAMS_HUB_DEV_WEB');

/// The hosting mode of this build. Overridden in tests.
final hostingModeProvider = Provider<HostingMode>((ref) => detectHostingMode());

/// Debug web builds run on the Flutter dev server; release web builds are
/// served by the gateway.
HostingMode detectHostingMode() {
  if (!kIsWeb) return HostingMode.native;
  return kDebugMode || _forceDevWeb ? HostingMode.devWeb : HostingMode.gatewayWeb;
}

/// The single implicit profile of the gateway-served web build.
ServerProfile implicitWebProfile(Uri pageUri) {
  final origin = Uri(
    scheme: pageUri.scheme,
    host: pageUri.host,
    port: pageUri.hasPort ? pageUri.port : null,
  );
  return ServerProfile(id: 'web', name: pageUri.host, urls: [origin], lastGoodUrl: origin);
}
