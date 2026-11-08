/// The compact "Web apps" grid at the bottom of the dashboard (APP.md §3.3).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../routing/paths.dart';
import '../widgets/section_card.dart';
import 'launcher_providers.dart';
import 'web_apps_screen.dart';

/// Hidden when every app is hidden or `/server` failed (the dashboard has its
/// own error handling); members see it too.
class WebAppsSection extends ConsumerWidget {
  const WebAppsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(launcherEntriesProvider.select((s) => s.value));
    if (entries == null || entries.isEmpty) return const SizedBox.shrink();
    return SectionCard(
      title: 'Web apps',
      icon: Icons.apps,
      trailing: TextButton(onPressed: () => context.go(AppPaths.webApps()), child: const Text('All apps')),
      child: GridView.extent(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        maxCrossAxisExtent: 104,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1,
        children: [for (final e in entries) LauncherTile(entry: e, compact: true)],
      ),
    );
  }
}
