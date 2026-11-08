/// The root widget: theme (with dynamic colour), router and incoming links.
library;

import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/app_info.dart';
import 'core/intents/incoming_links.dart';
import 'core/routing/router.dart';
import 'core/settings/app_settings.dart';
import 'core/theme/theme_controller.dart';
import 'core/widgets/snack.dart';

class YamsHubApp extends ConsumerStatefulWidget {
  const YamsHubApp({super.key, this.incomingLinks});

  /// Overridable for tests; defaults to the platform channel.
  final IncomingLinks? incomingLinks;

  @override
  ConsumerState<YamsHubApp> createState() => _YamsHubAppState();
}

class _YamsHubAppState extends ConsumerState<YamsHubApp> {
  late final IncomingLinks _links = widget.incomingLinks ?? IncomingLinks();

  @override
  void initState() {
    super.initState();
    unawaited(_links.start((route) => ref.read(routerProvider).go(route)));
  }

  @override
  void dispose() {
    _links.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);
    final router = ref.watch(routerProvider);
    final messengerKey = ref.watch(scaffoldMessengerKeyProvider);
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        final themes = HubThemes.resolve(settings, lightDynamic: lightDynamic, darkDynamic: darkDynamic);
        return MaterialApp.router(
          title: appTitle,
          debugShowCheckedModeBanner: false,
          theme: themes.light,
          darkTheme: themes.dark,
          themeMode: themes.mode,
          routerConfig: router,
          scaffoldMessengerKey: messengerKey,
        );
      },
    );
  }
}
