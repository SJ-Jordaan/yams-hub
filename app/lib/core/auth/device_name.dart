/// Default device name for new sessions (APP.md §3.2): "Pixel 8", "iPhone",
/// "Chrome on Linux".
library;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/platform.dart';

/// The platform model from `device_info_plus`, trimmed to 64 characters (the
/// gateway's limit). Falls back to a generic name when the plugin fails.
final deviceNameProvider = FutureProvider<String>((ref) async {
  try {
    // A plugin that never answers must not block sign-in.
    return clampDeviceName(await _lookup(DeviceInfoPlugin()).timeout(const Duration(seconds: 3)));
  } catch (_) {
    return fallbackDeviceName();
  }
});

Future<String> _lookup(DeviceInfoPlugin plugin) async {
  if (kIsWeb) {
    final info = await plugin.webBrowserInfo;
    return webDeviceName(info.browserName, info.platform);
  }
  if (isAndroid) {
    final info = await plugin.androidInfo;
    final model = info.model.trim();
    return model.isEmpty ? 'Android' : model;
  }
  if (isIOS) {
    final info = await plugin.iosInfo;
    final model = info.model.trim();
    return model.isEmpty ? 'iPhone' : model;
  }
  return fallbackDeviceName();
}

/// "Chrome on Linux".
@visibleForTesting
String webDeviceName(BrowserName browser, String? platform) {
  final name = switch (browser) {
    BrowserName.chrome => 'Chrome',
    BrowserName.firefox => 'Firefox',
    BrowserName.safari => 'Safari',
    BrowserName.edge => 'Edge',
    BrowserName.opera => 'Opera',
    BrowserName.msie => 'Internet Explorer',
    BrowserName.samsungInternet => 'Samsung Internet',
    BrowserName.unknown => 'Browser',
  };
  final os = _webOs(platform);
  return os == null ? name : '$name on $os';
}

String? _webOs(String? platform) {
  final p = (platform ?? '').toLowerCase();
  if (p.isEmpty) return null;
  if (p.contains('linux') && !p.contains('android')) return 'Linux';
  if (p.contains('android')) return 'Android';
  if (p.contains('mac')) return 'macOS';
  if (p.contains('win')) return 'Windows';
  if (p.contains('iphone') || p.contains('ipad') || p.contains('ios')) return 'iOS';
  return platform;
}

String fallbackDeviceName() {
  if (kIsWeb) return 'Browser';
  if (isAndroid) return 'Android';
  if (isIOS) return 'iPhone';
  return 'Desktop';
}

String clampDeviceName(String name) {
  final n = name.trim();
  if (n.isEmpty) return fallbackDeviceName();
  return n.length > 64 ? n.substring(0, 64) : n;
}
