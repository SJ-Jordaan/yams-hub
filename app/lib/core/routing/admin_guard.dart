/// Redirect for admin-only routes (ARCHITECTURE §7.3): members are sent to
/// the parent route with a SnackBar "Admins only".
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_controller.dart';
import '../widgets/snack.dart';

/// `GoRoute(redirect: adminOnly(AppPaths.library()), ...)`.
GoRouterRedirect adminOnly(String parent) => adminOnlyTo((_) => parent);

/// Like [adminOnly] with a parent computed from the route state, e.g.
/// `adminOnlyTo((s) => AppPaths.container(s.pathParameters['name']!))`.
GoRouterRedirect adminOnlyTo(String Function(GoRouterState state) parent) {
  return (context, state) {
    final container = ProviderScope.containerOf(context, listen: false);
    final auth = container.read(authControllerProvider);
    // Signed-out users are handled by the global redirect (to /login).
    if (!auth.signedIn || auth.isAdmin) return null;
    showHubSnackBar(container.read(scaffoldMessengerKeyProvider), 'Admins only');
    return parent(state);
  };
}
