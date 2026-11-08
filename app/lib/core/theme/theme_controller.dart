/// Resolves the light/dark themes from settings and the platform's dynamic
/// colour schemes (supplied by `DynamicColorBuilder` in `app.dart`).
library;

import 'package:flutter/material.dart';

import '../settings/app_settings.dart';
import 'theme.dart';

/// The settings the themes depend on (a record, compared by value).
typedef HubThemeSettings = ({ThemeMode themeMode, bool dynamicColor, int seedColor, ListDensity listDensity});

/// The theme fields of [s].
HubThemeSettings themeSettingsOf(AppSettings s) =>
    (themeMode: s.themeMode, dynamicColor: s.dynamicColor, seedColor: s.seedColor, listDensity: s.listDensity);

/// The two themes plus the mode `MaterialApp` should use.
@immutable
class HubThemes {
  const HubThemes({required this.light, required this.dark, required this.mode});

  /// Picks the dynamic schemes when the user enabled dynamic colour and the
  /// platform supplied them (Android 12+), otherwise the seeded schemes.
  factory HubThemes.resolve(AppSettings settings, {ColorScheme? lightDynamic, ColorScheme? darkDynamic}) =>
      HubThemes.from(themeSettingsOf(settings), lightDynamic: lightDynamic, darkDynamic: darkDynamic);

  /// [HubThemes.resolve] from the theme fields alone.
  factory HubThemes.from(HubThemeSettings settings, {ColorScheme? lightDynamic, ColorScheme? darkDynamic}) {
    final useDynamic = settings.dynamicColor && lightDynamic != null && darkDynamic != null;
    final seed = Color(settings.seedColor);
    final light = useDynamic ? lightDynamic.completed() : seededScheme(seed, Brightness.light);
    final dark = useDynamic ? darkDynamic.completed() : seededScheme(seed, Brightness.dark);
    final compact = settings.listDensity == ListDensity.compact;
    return HubThemes(
      light: buildHubTheme(light, compactLists: compact),
      dark: buildHubTheme(dark, compactLists: compact),
      mode: settings.themeMode,
    );
  }

  final ThemeData light;
  final ThemeData dark;
  final ThemeMode mode;
}

extension on ColorScheme {
  /// Dynamic schemes from the platform can be sparse; re-deriving from their
  /// primary keeps every M3 role (surface containers, ...) populated.
  ColorScheme completed() => ColorScheme.fromSeed(seedColor: primary, brightness: brightness);
}
