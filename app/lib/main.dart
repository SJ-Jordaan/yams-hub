import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/api/retry.dart';
import 'core/auth/token_manager.dart';
import 'core/auth/token_store.dart';
import 'core/servers/hosting.dart';
import 'core/servers/server_connection.dart';
import 'core/servers/server_store.dart';
import 'core/settings/app_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Clean URLs on web (the gateway serves index.html for unknown paths), so
  // alert routes work as deep links. No-op on mobile.
  usePathUrlStrategy();
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString('lib/core/theme/fonts/LICENSE.txt');
    yield LicenseEntryWithLineBreaks(['Roboto'], text);
  });

  final prefs = await SharedPreferences.getInstance();
  final mode = detectHostingMode();
  final active = mode == HostingMode.gatewayWeb ? null : ServerStore.readFrom(prefs).active;
  final cookie = usesCookieTransport(mode, active);

  // Load the session before the first frame so the router knows whether the
  // user is signed in (and as which role) without a splash screen.
  final tokens = TokenManager(store: createTokenStore(cookieTransport: cookie), prefs: prefs, cookieTransport: cookie);
  await tokens.activate(active?.instanceId);

  runApp(
    ProviderScope(
      retry: hubRetry,
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        tokenManagerProvider.overrideWithValue(tokens),
      ],
      child: const YamsHubApp(),
    ),
  );
}
