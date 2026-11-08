/// Periodic provider refresh scaled by the refresh preset (ARCHITECTURE §7.7).
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/app_settings.dart';
import 'app_lifecycle_provider.dart';

/// Base intervals of APP.md §14 (Normal preset).
abstract final class RefreshIntervals {
  static const dashboard = Duration(seconds: 15);
  static const dashboardFast = Duration(seconds: 5);
  static const torrents = Duration(seconds: 2);
  static const queue = Duration(seconds: 3);
  static const nowPlaying = Duration(seconds: 5);
  static const hostMetrics = Duration(seconds: 5);
  static const containers = Duration(seconds: 10);
  static const thirtySeconds = Duration(seconds: 30);
  static const health = thirtySeconds;
  static const navBadges = thirtySeconds;
  static const webApps = thirtySeconds;
  static const sixtySeconds = Duration(seconds: 60);
  static const calendar = Duration(minutes: 5);
  static const stats = Duration(minutes: 5);
}

/// The effective interval for [base] under the current preset, or null when
/// the preset is Manual.
Duration? scaledInterval(Ref ref, Duration base) =>
    ref.read(appSettingsProvider).refreshPreset.scale(base);

/// Re-runs the calling provider every `base × preset` while the app is in the
/// foreground. Call it at the start of a provider's build:
///
/// ```dart
/// final fooProvider = FutureProvider.autoDispose((ref) async {
///   autoRefresh(ref, RefreshIntervals.sixtySeconds);
///   return ref.watch(fooApiProvider).load();
/// });
/// ```
///
/// The timer is cancelled when the provider rebuilds or is disposed, paused
/// while the app is not resumed (and the provider is refreshed on resume when
/// "Refresh on app resume" is on), and restarted when the preset changes.
///
/// Riverpod additionally pauses providers whose widgets are not visible (an
/// inactive tab). A refresh due while paused is remembered instead, and runs
/// [autoRefreshResumeDelay] after the provider resumes, so returning to a tab
/// plays its transition before the refetches and rebuilds start.
void autoRefresh(Ref ref, Duration base) {
  final preset = ref.watch(appSettingsProvider.select((s) => s.refreshPreset));
  final interval = preset.scale(base);
  Timer? timer;
  Timer? resumeTimer;
  var stale = false;

  void schedule() {
    timer?.cancel();
    if (interval == null) return;
    timer = Timer(interval, () {
      if (!ref.mounted) return;
      if (ref.isPaused) {
        stale = true;
      } else {
        ref.invalidateSelf();
      }
    });
  }

  ref.onResume(() {
    if (!stale) return;
    stale = false;
    resumeTimer?.cancel();
    resumeTimer = Timer(autoRefreshResumeDelay, () {
      if (ref.mounted) ref.invalidateSelf();
    });
  });

  if (ref.read(appLifecycleProvider) == AppLifecycleState.resumed) schedule();

  ref.listen<AppLifecycleState>(appLifecycleProvider, (previous, next) {
    if (next == AppLifecycleState.resumed) {
      if (previous != AppLifecycleState.resumed && ref.read(appSettingsProvider).refreshOnResume) {
        ref.invalidateSelf();
      } else {
        schedule();
      }
    } else {
      timer?.cancel();
    }
  });
  ref.onDispose(() {
    timer?.cancel();
    resumeTimer?.cancel();
  });
}

/// How long after a paused provider resumes its overdue refresh runs (the
/// tab-switch transition plays first).
const autoRefreshResumeDelay = Duration(milliseconds: 300);
