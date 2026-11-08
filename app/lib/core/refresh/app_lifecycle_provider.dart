/// The app lifecycle state as a provider (ARCHITECTURE §7.7).
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Tracks [AppLifecycleState] through an [AppLifecycleListener]. Timers in
/// `autoRefresh`, the badge poller and the server resolver pause while the
/// state is not [AppLifecycleState.resumed].
class AppLifecycleController extends Notifier<AppLifecycleState> {
  @override
  AppLifecycleState build() {
    final listener = AppLifecycleListener(onStateChange: (s) => state = s);
    ref.onDispose(listener.dispose);
    return WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
  }
}

final appLifecycleProvider = NotifierProvider<AppLifecycleController, AppLifecycleState>(
  AppLifecycleController.new,
);

/// Whether the app is in the foreground.
final appInForegroundProvider = Provider<bool>(
  (ref) => ref.watch(appLifecycleProvider) == AppLifecycleState.resumed,
);
