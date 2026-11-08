/// Shown for unknown routes (e.g. a stale deep link).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../widgets/empty_view.dart';
import 'paths.dart';

class NotFoundScreen extends StatelessWidget {
  const NotFoundScreen({super.key, this.location});

  final String? location;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Not found')),
      body: EmptyView(
        icon: Icons.explore_off_outlined,
        title: 'Page not found',
        message: location == null ? 'This link does not lead anywhere.' : '$location does not exist.',
        action: FilledButton(onPressed: () => context.go(AppPaths.home()), child: const Text('Go home')),
      ),
    );
  }
}
