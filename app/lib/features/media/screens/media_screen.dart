/// `/media`: tabs Now playing | Stats | Apps (APP.md §8).
library;

import 'package:flutter/material.dart';

import 'apps_tab.dart';
import 'now_playing_tab.dart';
import 'stats_tab.dart';

/// The `tab` query values of `/media` (`AppPaths.media(tab: 'stats')`).
enum MediaTab {
  playing('Now playing', Icons.play_circle_outline),
  stats('Stats', Icons.insights_outlined),
  apps('Apps', Icons.apps);

  const MediaTab(this.label, this.icon);

  final String label;
  final IconData icon;

  /// Parses `?tab=`; unknown values open Now playing.
  static MediaTab parse(String? v) => switch (v) {
    'stats' => stats,
    'apps' => apps,
    _ => playing,
  };
}

class MediaScreen extends StatefulWidget {
  const MediaScreen({super.key, this.initialTab});

  /// The tab from `?tab=`; null keeps the current tab (Now playing on first
  /// build).
  final MediaTab? initialTab;

  @override
  State<MediaScreen> createState() => _MediaScreenState();
}

class _MediaScreenState extends State<MediaScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: MediaTab.values.length,
    vsync: this,
    initialIndex: (widget.initialTab ?? MediaTab.playing).index,
  );

  /// The last tab a `?tab=` asked for: returning from a detail screen
  /// re-delivers it, which must not undo the user's own tab change.
  late MediaTab? _requested = widget.initialTab;

  @override
  void didUpdateWidget(MediaScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final tab = widget.initialTab;
    if (tab != null && tab != _requested) {
      _requested = tab;
      _tabs.animateTo(tab.index);
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Media'),
        bottom: TabBar(
          controller: _tabs,
          tabs: [for (final t in MediaTab.values) Tab(text: t.label)],
        ),
      ),
      body: TabBarView(controller: _tabs, children: const [NowPlayingTab(), StatsTab(), AppsTab()]),
    );
  }
}
