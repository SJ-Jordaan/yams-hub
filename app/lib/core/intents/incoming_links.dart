/// Links delivered to the app by the OS (ARCHITECTURE §7.11): a `magnet:` URI
/// opens `/activity/add?url=<uri>`. Members are redirected with "Admins only"
/// by that route's guard.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../routing/paths.dart';

/// The app route for an incoming link, or null when the app does not handle it.
String? routeForIncomingLink(String link) {
  final uri = Uri.tryParse(link.trim());
  if (uri == null) return null;
  if (uri.scheme.toLowerCase() == 'magnet') return AppPaths.activityAdd(url: link.trim());
  return null;
}

/// Reads the launch link and later links from the `dev.zenith.yams_hub/links`
/// channel (MainActivity.kt / AppDelegate.swift). go_router's own platform deep
/// linking is disabled, so this is the only receiver.
class IncomingLinks {
  IncomingLinks({MethodChannel? channel}) : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'dev.zenith.yams_hub/links';

  final MethodChannel _channel;

  /// Starts listening and calls [onRoute] with the route of every handled
  /// link (the launch link first). No-op on web.
  Future<void> start(void Function(String route) onRoute) async {
    if (kIsWeb) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onLink' && call.arguments is String) {
        final route = routeForIncomingLink(call.arguments as String);
        if (route != null) onRoute(route);
      }
      return null;
    });
    try {
      final initial = await _channel.invokeMethod<String>('getInitialLink');
      if (initial != null) {
        final route = routeForIncomingLink(initial);
        if (route != null) onRoute(route);
      }
    } on MissingPluginException {
      // Platform without the channel (desktop, tests).
    } on PlatformException {
      // Ignore: no launch link.
    }
  }

  void stop() {
    if (!kIsWeb) _channel.setMethodCallHandler(null);
  }
}
