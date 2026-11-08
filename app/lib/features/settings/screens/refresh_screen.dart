/// `/settings/refresh`: refresh preset with the resulting intervals, and
/// "Refresh on app resume" (APP.md §13, §14).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/refresh/auto_refresh.dart';
import 'package:yams_hub/core/settings/app_settings.dart';

import '../widgets/settings_widgets.dart';

/// One row of the interval table: a screen and its base interval (null =
/// manual, pull to refresh only).
typedef RefreshRow = ({String label, Duration? base});

/// APP.md §14, base values (Normal preset).
const List<RefreshRow> refreshTable = [
  (label: 'Dashboard', base: RefreshIntervals.dashboard),
  (label: 'Dashboard live cards (downloads, system, now playing)', base: RefreshIntervals.dashboardFast),
  (label: 'Torrents, torrent detail, transfer bar', base: RefreshIntervals.torrents),
  (label: 'Download queue', base: RefreshIntervals.queue),
  (label: 'Now playing', base: RefreshIntervals.nowPlaying),
  (label: 'Host metrics', base: RefreshIntervals.hostMetrics),
  (label: 'Containers', base: RefreshIntervals.containers),
  (label: 'Requests, health, uptime, VPN, web apps, badges', base: RefreshIntervals.thirtySeconds),
  (label: 'Library, indexers, subtitles, books, media apps', base: RefreshIntervals.sixtySeconds),
  (label: 'Calendar, stats', base: RefreshIntervals.calendar),
  (label: 'Discover, search, history, updates, logs', base: null),
];

/// `1 s`, `2.5 s`, `45 s`, `1 min 30 s`, `15 min`.
String formatInterval(Duration d) {
  final ms = d.inMilliseconds;
  if (ms < 60000) {
    final s = ms / 1000;
    final text = s == s.roundToDouble() ? s.toStringAsFixed(0) : s.toStringAsFixed(1);
    return '$text s';
  }
  final minutes = d.inMinutes;
  final seconds = d.inSeconds % 60;
  return seconds == 0 ? '$minutes min' : '$minutes min $seconds s';
}

/// What a row refreshes at under [preset].
String intervalLabel(RefreshPreset preset, Duration? base) {
  if (base == null) return 'Pull to refresh';
  final scaled = preset.scale(base);
  return scaled == null ? 'Pull to refresh' : 'Every ${formatInterval(scaled)}';
}

String presetDescription(RefreshPreset preset) => switch (preset) {
  RefreshPreset.fast => 'Twice as often. Uses more battery and data.',
  RefreshPreset.normal => 'Recommended.',
  RefreshPreset.batterySaver => 'Three times less often.',
  RefreshPreset.manual => 'Nothing refreshes by itself; pull down to refresh.',
};

class RefreshScreen extends ConsumerWidget {
  const RefreshScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final controller = ref.read(appSettingsProvider.notifier);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Refresh')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const SettingsSectionHeader('Refresh rate'),
          RadioGroup<RefreshPreset>(
            groupValue: settings.refreshPreset,
            onChanged: (p) {
              if (p != null) controller.setRefreshPreset(p);
            },
            child: Column(
              children: [
                for (final p in RefreshPreset.values)
                  RadioListTile<RefreshPreset>(
                    key: Key('preset-${p.name}'),
                    value: p,
                    title: Text(p.label),
                    subtitle: Text(presetDescription(p)),
                  ),
              ],
            ),
          ),
          SwitchListTile(
            key: const Key('refresh-on-resume'),
            title: const Text('Refresh on app resume'),
            subtitle: const Text('Reload the screen you are on when you come back to the app'),
            value: settings.refreshOnResume,
            onChanged: controller.setRefreshOnResume,
          ),
          SettingsSectionHeader('Intervals (${settings.refreshPreset.label})'),
          const SettingsHint('Timers pause while the app is in the background or the screen is not visible.'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Table(
              key: const Key('refresh-table'),
              columnWidths: const {0: FlexColumnWidth(), 1: IntrinsicColumnWidth()},
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              border: TableBorder(horizontalInside: BorderSide(color: theme.dividerColor.withValues(alpha: 0.4))),
              children: [
                for (final row in refreshTable)
                  TableRow(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Text(row.label, style: theme.textTheme.bodyMedium),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(left: 16),
                        child: Text(
                          intervalLabel(settings.refreshPreset, row.base),
                          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.primary),
                          textAlign: TextAlign.end,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
