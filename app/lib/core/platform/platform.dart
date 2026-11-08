/// Platform checks for every app file (ARCHITECTURE §7.1).
///
/// Built on `kIsWeb` and `defaultTargetPlatform` only, so the web build
/// compiles: feature code must use these instead of `dart:io`'s `Platform`.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:yams_models/yams_models.dart';

/// Running in a browser.
bool get isWeb => kIsWeb;

/// Native Android app.
bool get isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Native iOS app.
bool get isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// Native desktop build (not a supported target, but `flutter run` works).
bool get isDesktop =>
    !kIsWeb &&
    switch (defaultTargetPlatform) {
      TargetPlatform.linux || TargetPlatform.macOS || TargetPlatform.windows => true,
      _ => false,
    };

/// Native mobile app (Android or iOS).
bool get isMobile => isAndroid || isIOS;

/// The platform reported to the gateway on login (`LoginRequest.platform`).
ClientPlatform get clientPlatform {
  if (isWeb) return ClientPlatform.web;
  if (isAndroid) return ClientPlatform.android;
  if (isIOS) return ClientPlatform.ios;
  return ClientPlatform.other;
}

/// Short platform label used in the `X-YAMS-Client` header.
String get platformLabel {
  if (kIsWeb) return 'web';
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => 'android',
    TargetPlatform.iOS => 'ios',
    TargetPlatform.linux => 'linux',
    TargetPlatform.macOS => 'macos',
    TargetPlatform.windows => 'windows',
    TargetPlatform.fuchsia => 'fuchsia',
  };
}

/// Whether [context] is laid out at a phone width (< 600 dp).
bool isCompactWidth(BuildContext context) => MediaQuery.sizeOf(context).width < 600;
