/// `/more` (phones): the destinations that are not in the bottom bar, with
/// live counts (APP.md §3.4).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../launcher/launcher_providers.dart';
import 'destinations.dart';
import 'nav_badges.dart';
import 'paths.dart';

/// The More subtitles derived from the badge counts (null = no subtitle).
@visibleForTesting
Map<int, String?> moreSubtitles(NavBadges b) => {
  Branches.calendar: switch (b.calendarNext7Days) {
    null => null,
    1 => '1 episode this week',
    final n => '$n episodes this week',
  },
  Branches.containers: b.containersRunning == null ? null : '${b.containersRunning} running',
  Branches.indexers: switch (b.indexersFailing) {
    null => null,
    0 => 'All working',
    final n => '$n failing',
  },
  Branches.subtitles: b.subtitlesMissing == null ? null : '${b.subtitlesMissing} missing',
};

class MoreScreen extends ConsumerWidget {
  const MoreScreen({super.key});

  static const _entries = [
    Branches.calendar,
    Branches.media,
    Branches.containers,
    Branches.indexers,
    Branches.subtitles,
    Branches.system,
    Branches.settings,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subtitles = moreSubtitles(ref.watch(navBadgesProvider));
    final launcher = ref.watch(launcherEntriesProvider).value;
    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.apps),
            title: const Text('Web apps'),
            subtitle: launcher == null ? null : Text(launcherSummary(launcher)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go(AppPaths.webApps()),
          ),
          const Divider(),
          for (final b in _entries)
            ListTile(
              leading: Icon(hubDestinations[b].icon),
              title: Text(hubDestinations[b].label),
              subtitle: subtitles[b] == null ? null : Text(subtitles[b]!),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.go(hubDestinations[b].path),
            ),
        ],
      ),
    );
  }
}
