/// App-wide SnackBars that work from anywhere (route guards, providers).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_exception.dart';

/// The key of the app's root [ScaffoldMessenger] (`MaterialApp.scaffoldMessengerKey`).
final scaffoldMessengerKeyProvider = Provider<GlobalKey<ScaffoldMessengerState>>(
  (ref) => GlobalKey<ScaffoldMessengerState>(debugLabel: 'rootScaffoldMessenger'),
);

/// Shows [message] in the root messenger (after the current frame, so it is
/// safe to call from a redirect or a build).
void showHubSnackBar(GlobalKey<ScaffoldMessengerState> key, String message, {SnackBarAction? action}) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final messenger = key.currentState;
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action));
  });
}

/// SnackBar helpers for widgets.
extension HubSnackBars on BuildContext {
  /// Shows [message] in the nearest messenger.
  void showSnack(String message, {SnackBarAction? action}) {
    final messenger = ScaffoldMessenger.maybeOf(this);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action));
  }

  /// Shows the user-facing message of [error] (any API error).
  void showError(Object error) => showSnack(ApiException.from(error).message);
}
