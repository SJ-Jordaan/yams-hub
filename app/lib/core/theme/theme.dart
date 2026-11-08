/// Material 3 theme and the [StatusColors] extension (ARCHITECTURE §7.9).
library;

import 'package:flutter/material.dart';
import 'package:yams_models/yams_models.dart';

/// Semantic tone of a status: feature widgets pick a tone, never a colour.
enum StatusTone { ok, warning, error, info, neutral }

/// Status colours as a [ThemeExtension], so feature widgets never hard-code
/// greens and reds. Read with `StatusColors.of(context)`.
@immutable
class StatusColors extends ThemeExtension<StatusColors> {
  const StatusColors({
    required this.ok,
    required this.warning,
    required this.error,
    required this.info,
    required this.neutral,
    required this.onStatus,
  });

  static const dark = StatusColors(
    ok: Color(0xFF66BB6A),
    warning: Color(0xFFFFCA28),
    error: Color(0xFFEF5350),
    info: Color(0xFF42A5F5),
    neutral: Color(0xFF9E9E9E),
    onStatus: Color(0xFF111111),
  );

  static const light = StatusColors(
    ok: Color(0xFF2E7D32),
    warning: Color(0xFFB26A00),
    error: Color(0xFFC62828),
    info: Color(0xFF1565C0),
    neutral: Color(0xFF616161),
    onStatus: Color(0xFFFFFFFF),
  );

  final Color ok;
  final Color warning;
  final Color error;
  final Color info;
  final Color neutral;

  /// Foreground on a solid status colour.
  final Color onStatus;

  /// The extension of the ambient theme (falls back to the preset matching
  /// its brightness).
  static StatusColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<StatusColors>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  Color forTone(StatusTone tone) => switch (tone) {
    StatusTone.ok => ok,
    StatusTone.warning => warning,
    StatusTone.error => error,
    StatusTone.info => info,
    StatusTone.neutral => neutral,
  };

  @override
  StatusColors copyWith({
    Color? ok,
    Color? warning,
    Color? error,
    Color? info,
    Color? neutral,
    Color? onStatus,
  }) => StatusColors(
    ok: ok ?? this.ok,
    warning: warning ?? this.warning,
    error: error ?? this.error,
    info: info ?? this.info,
    neutral: neutral ?? this.neutral,
    onStatus: onStatus ?? this.onStatus,
  );

  @override
  StatusColors lerp(covariant StatusColors? other, double t) {
    if (other == null) return this;
    return StatusColors(
      ok: Color.lerp(ok, other.ok, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      error: Color.lerp(error, other.error, t)!,
      info: Color.lerp(info, other.info, t)!,
      neutral: Color.lerp(neutral, other.neutral, t)!,
      onStatus: Color.lerp(onStatus, other.onStatus, t)!,
    );
  }
}

/// Tone of a service health status.
StatusTone toneForHealth(ServiceHealthStatus status) => switch (status) {
  ServiceHealthStatus.up => StatusTone.ok,
  ServiceHealthStatus.degraded => StatusTone.warning,
  ServiceHealthStatus.down => StatusTone.error,
  ServiceHealthStatus.disabled || ServiceHealthStatus.unknown => StatusTone.neutral,
};

/// Tone of an alert severity.
StatusTone toneForSeverity(AlertSeverity severity) => switch (severity) {
  AlertSeverity.critical || AlertSeverity.error => StatusTone.error,
  AlertSeverity.warning => StatusTone.warning,
  AlertSeverity.info => StatusTone.info,
  AlertSeverity.unknown => StatusTone.neutral,
};

/// Tone of a job status.
StatusTone toneForJob(JobStatus status) => switch (status) {
  JobStatus.succeeded => StatusTone.ok,
  JobStatus.failed => StatusTone.error,
  JobStatus.queued || JobStatus.running => StatusTone.info,
  JobStatus.unknown => StatusTone.neutral,
};

/// Builds the app theme for [scheme]. Fonts are the platform defaults (the
/// web build loads no Google Fonts).
ThemeData buildHubTheme(ColorScheme scheme) {
  final dark = scheme.brightness == Brightness.dark;
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    extensions: [dark ? StatusColors.dark : StatusColors.light],
    visualDensity: VisualDensity.standard,
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: EdgeInsets.zero,
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
  );
}

/// The fallback scheme for [seed] when dynamic colour is off or unavailable.
ColorScheme seededScheme(Color seed, Brightness brightness) =>
    ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
