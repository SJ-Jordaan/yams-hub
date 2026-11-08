/// Per-device app settings (ARCHITECTURE §7.9, APP.md §13), stored in
/// SharedPreferences as one JSON document.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yams_models/yams_models.dart';

import '../platform/platform.dart';

/// The app's SharedPreferences instance. Loaded in `main()` before `runApp`
/// and injected with an override, so every reader is synchronous.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw StateError('sharedPreferencesProvider must be overridden in main()'),
);

/// Refresh presets (APP.md §14): every base interval is multiplied by
/// [multiplier]; [manual] disables timers.
enum RefreshPreset {
  fast('Fast', 0.5),
  normal('Normal', 1),
  batterySaver('Battery saver', 3),
  manual('Manual', null);

  const RefreshPreset(this.label, this.multiplier);

  final String label;

  /// `null` for [manual] (no timers).
  final double? multiplier;

  /// [base] scaled by this preset, never below 1 s; `null` when timers are off.
  Duration? scale(Duration base) {
    final m = multiplier;
    if (m == null) return null;
    final ms = (base.inMilliseconds * m).round();
    return Duration(milliseconds: ms < 1000 ? 1000 : ms);
  }
}

/// List density (Settings > Appearance).
enum ListDensity { comfortable, compact }

/// The six accent seeds offered in Settings > Appearance; the first is the
/// default (`#7C4DFF`, ARCHITECTURE §7.9).
const List<Color> accentSeeds = [
  Color(0xFF7C4DFF),
  Color(0xFF2962FF),
  Color(0xFF00897B),
  Color(0xFF43A047),
  Color(0xFFFF8F00),
  Color(0xFFE53935),
];

/// Immutable settings snapshot. Hand-written `copyWith` (no codegen).
@immutable
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.dark,
    this.dynamicColorOverride,
    this.seedColor = 0xFF7C4DFF,
    this.refreshPreset = RefreshPreset.normal,
    this.refreshOnResume = true,
    this.hiddenCards = const {},
    this.cardOrder = const [],
    this.hiddenLauncherApps = const {},
    this.dismissedAlerts = const {},
    this.listDensity = ListDensity.comfortable,
    this.externalBaseUrls = const {},
    this.appSchemes = const {},
  });

  factory AppSettings.fromJson(Map<String, Object?> j) => AppSettings(
    themeMode: readOptionalEnum(j['themeMode'], ThemeMode.values) ?? ThemeMode.dark,
    dynamicColorOverride: readBool(j['dynamicColor']),
    seedColor: readInt(j['seedColor']) ?? 0xFF7C4DFF,
    refreshPreset:
        readOptionalEnum(j['refreshPreset'], RefreshPreset.values) ?? RefreshPreset.normal,
    refreshOnResume: readBool(j['refreshOnResume']) ?? true,
    hiddenCards: readStringList(j['hiddenCards']).toSet(),
    cardOrder: readStringList(j['cardOrder']),
    hiddenLauncherApps: {
      for (final name in readStringList(j['hiddenLauncherApps']))
        if (ExternalApp.fromJson(name) case final app when app != ExternalApp.unknown) app,
    },
    dismissedAlerts: readStringList(j['dismissedAlerts']).toSet(),
    listDensity:
        readOptionalEnum(j['listDensity'], ListDensity.values) ?? ListDensity.comfortable,
    externalBaseUrls: _readAppMap(j['externalBaseUrls']),
    appSchemes: _readAppMap(j['appSchemes']),
  );

  /// System / dark / light. Dark by default.
  final ThemeMode themeMode;

  /// The user's explicit "Dynamic color" choice; `null` = platform default.
  final bool? dynamicColorOverride;

  /// Accent seed (ARGB) used when dynamic colour is off or unavailable.
  final int seedColor;
  final RefreshPreset refreshPreset;

  /// Refresh the visible screen when the app returns to the foreground.
  final bool refreshOnResume;

  /// Dashboard card keys hidden from Home (also left out of `?cards=`).
  final Set<String> hiddenCards;

  /// Custom dashboard card order (keys); empty = default order.
  final List<String> cardOrder;

  /// Launcher apps hidden on this device.
  final Set<ExternalApp> hiddenLauncherApps;

  /// Ids of dismissed dashboard alerts.
  final Set<String> dismissedAlerts;
  final ListDensity listDensity;

  /// Settings > Media apps base URL overrides (`http://host:port`).
  final Map<ExternalApp, String> externalBaseUrls;

  /// Settings > Media apps custom URL schemes (`jellyfin://`).
  final Map<ExternalApp, String> appSchemes;

  /// Dynamic colour: on by default on Android (12+ supplies a scheme), off
  /// elsewhere.
  bool get dynamicColor => dynamicColorOverride ?? isAndroid;

  Color get seed => Color(seedColor);

  /// Dashboard card keys in display order, hidden ones included.
  List<String> get orderedCards {
    final known = DashboardCardKeys.all;
    return [
      for (final k in cardOrder)
        if (known.contains(k)) k,
      for (final k in known)
        if (!cardOrder.contains(k)) k,
    ];
  }

  /// Visible dashboard card keys in display order.
  List<String> get visibleCards => [
    for (final k in orderedCards)
      if (!hiddenCards.contains(k)) k,
  ];

  AppSettings copyWith({
    ThemeMode? themeMode,
    bool? dynamicColor,
    int? seedColor,
    RefreshPreset? refreshPreset,
    bool? refreshOnResume,
    Set<String>? hiddenCards,
    List<String>? cardOrder,
    Set<ExternalApp>? hiddenLauncherApps,
    Set<String>? dismissedAlerts,
    ListDensity? listDensity,
    Map<ExternalApp, String>? externalBaseUrls,
    Map<ExternalApp, String>? appSchemes,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    dynamicColorOverride: dynamicColor ?? dynamicColorOverride,
    seedColor: seedColor ?? this.seedColor,
    refreshPreset: refreshPreset ?? this.refreshPreset,
    refreshOnResume: refreshOnResume ?? this.refreshOnResume,
    hiddenCards: hiddenCards ?? this.hiddenCards,
    cardOrder: cardOrder ?? this.cardOrder,
    hiddenLauncherApps: hiddenLauncherApps ?? this.hiddenLauncherApps,
    dismissedAlerts: dismissedAlerts ?? this.dismissedAlerts,
    listDensity: listDensity ?? this.listDensity,
    externalBaseUrls: externalBaseUrls ?? this.externalBaseUrls,
    appSchemes: appSchemes ?? this.appSchemes,
  );

  Map<String, Object?> toJson() => compactJson({
    'themeMode': themeMode.name,
    'dynamicColor': dynamicColorOverride,
    'seedColor': seedColor,
    'refreshPreset': refreshPreset.name,
    'refreshOnResume': refreshOnResume,
    'hiddenCards': hiddenCards.toList()..sort(),
    'cardOrder': cardOrder,
    'hiddenLauncherApps': [for (final a in hiddenLauncherApps) a.name]..sort(),
    'dismissedAlerts': dismissedAlerts.toList()..sort(),
    'listDensity': listDensity.name,
    'externalBaseUrls': {for (final e in externalBaseUrls.entries) e.key.name: e.value},
    'appSchemes': {for (final e in appSchemes.entries) e.key.name: e.value},
  });

  static Map<ExternalApp, String> _readAppMap(Object? v) => {
    for (final e in (readMap(v) ?? const <String, Object?>{}).entries)
      if (ExternalApp.fromJson(e.key) case final app when app != ExternalApp.unknown)
        if (readString(e.value) case final s? when s.trim().isNotEmpty) app: s.trim(),
  };
}

/// Reads and writes [AppSettings]. Every change is persisted immediately.
class AppSettingsController extends Notifier<AppSettings> {
  static const storageKey = 'app_settings.v1';

  /// Alert ids are capped so the stored list cannot grow without bound.
  static const maxDismissedAlerts = 200;

  @override
  AppSettings build() {
    final raw = ref.watch(sharedPreferencesProvider).getString(storageKey);
    if (raw == null) return const AppSettings();
    try {
      final decoded = readMap(jsonDecode(raw));
      return decoded == null ? const AppSettings() : AppSettings.fromJson(decoded);
    } on FormatException {
      return const AppSettings();
    }
  }

  /// Applies [change] and persists the result.
  void update(AppSettings Function(AppSettings current) change) {
    final next = change(state);
    state = next;
    ref.read(sharedPreferencesProvider).setString(storageKey, jsonEncode(next.toJson()));
  }

  void setThemeMode(ThemeMode mode) => update((s) => s.copyWith(themeMode: mode));

  void setDynamicColor(bool enabled) => update((s) => s.copyWith(dynamicColor: enabled));

  void setSeedColor(Color color) => update((s) => s.copyWith(seedColor: color.toARGB32()));

  void setRefreshPreset(RefreshPreset preset) =>
      update((s) => s.copyWith(refreshPreset: preset));

  void setRefreshOnResume(bool enabled) => update((s) => s.copyWith(refreshOnResume: enabled));

  void setListDensity(ListDensity density) => update((s) => s.copyWith(listDensity: density));

  void setCardHidden(String key, bool hidden) => update(
    (s) => s.copyWith(
      hiddenCards: hidden ? {...s.hiddenCards, key} : ({...s.hiddenCards}..remove(key)),
    ),
  );

  void setCardOrder(List<String> keys) => update((s) => s.copyWith(cardOrder: List.of(keys)));

  void setLauncherAppHidden(ExternalApp app, bool hidden) => update(
    (s) => s.copyWith(
      hiddenLauncherApps: hidden
          ? {...s.hiddenLauncherApps, app}
          : ({...s.hiddenLauncherApps}..remove(app)),
    ),
  );

  void dismissAlert(String id) => update((s) {
    final ids = [...s.dismissedAlerts.where((e) => e != id), id];
    final kept = ids.length > maxDismissedAlerts
        ? ids.sublist(ids.length - maxDismissedAlerts)
        : ids;
    return s.copyWith(dismissedAlerts: kept.toSet());
  });

  void clearDismissedAlerts() => update((s) => s.copyWith(dismissedAlerts: const {}));

  /// Sets (or with null/blank, clears) the base URL override for [app].
  void setExternalBaseUrl(ExternalApp app, String? url) => update((s) {
    final next = {...s.externalBaseUrls};
    if (url == null || url.trim().isEmpty) {
      next.remove(app);
    } else {
      next[app] = url.trim();
    }
    return s.copyWith(externalBaseUrls: next);
  });

  /// Sets (or with null/blank, clears) the custom URL scheme for [app].
  void setAppScheme(ExternalApp app, String? scheme) => update((s) {
    final next = {...s.appSchemes};
    if (scheme == null || scheme.trim().isEmpty) {
      next.remove(app);
    } else {
      next[app] = scheme.trim();
    }
    return s.copyWith(appSchemes: next);
  });
}

/// The current [AppSettings].
final appSettingsProvider = NotifierProvider<AppSettingsController, AppSettings>(
  AppSettingsController.new,
);
