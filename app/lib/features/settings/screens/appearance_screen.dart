/// `/settings/appearance`: theme mode, dynamic colour, accent seed, dashboard
/// cards (visibility and order), web apps shown in the launcher, list
/// density (APP.md §13). Stored on this device.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/dashboard/dashboard_cards.dart';
import 'package:yams_hub/core/launcher/launcher_providers.dart';
import 'package:yams_hub/core/platform/platform.dart';
import 'package:yams_hub/core/settings/app_settings.dart';
import 'package:yams_models/yams_models.dart';

import '../widgets/settings_widgets.dart';

/// Names of the accent seeds, in [accentSeeds] order.
const accentSeedNames = ['Violet', 'Blue', 'Teal', 'Green', 'Amber', 'Red'];

class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final controller = ref.read(appSettingsProvider.notifier);
    final dynamicActive = isAndroid && settings.dynamicColor;

    return Scaffold(
      appBar: AppBar(title: const Text('Appearance')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const SettingsSectionHeader('Theme'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SegmentedButton<ThemeMode>(
              key: const Key('appearance-theme-mode'),
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('System'), icon: Icon(Icons.brightness_auto)),
                ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode_outlined)),
                ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode_outlined)),
              ],
              selected: {settings.themeMode},
              onSelectionChanged: (s) => controller.setThemeMode(s.first),
            ),
          ),
          if (isAndroid)
            SwitchListTile(
              key: const Key('appearance-dynamic-color'),
              secondary: const Icon(Icons.wallpaper_outlined),
              title: const Text('Dynamic color'),
              subtitle: const Text('Use your wallpaper colours (Android 12 and newer)'),
              value: settings.dynamicColor,
              onChanged: controller.setDynamicColor,
            ),
          ListTile(
            title: const Text('Accent colour'),
            subtitle: Text(dynamicActive ? 'Used when dynamic color is off or unavailable' : 'Tints the whole app'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (var i = 0; i < accentSeeds.length; i++)
                  _SeedSwatch(
                    color: accentSeeds[i],
                    name: accentSeedNames[i],
                    selected: settings.seedColor == accentSeeds[i].toARGB32(),
                    dimmed: dynamicActive,
                    onTap: () => controller.setSeedColor(accentSeeds[i]),
                  ),
              ],
            ),
          ),
          const SettingsSectionHeader('List density'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SegmentedButton<ListDensity>(
              segments: const [
                ButtonSegment(value: ListDensity.comfortable, label: Text('Comfortable')),
                ButtonSegment(value: ListDensity.compact, label: Text('Compact')),
              ],
              selected: {settings.listDensity},
              onSelectionChanged: (s) => controller.setListDensity(s.first),
            ),
          ),
          const SettingsSectionHeader('Dashboard cards'),
          const SettingsHint('Untick a card to hide it from Home. Drag to change the order.'),
          const DashboardCardsEditor(),
          const SettingsSectionHeader('Web apps'),
          const SettingsHint('Apps shown in the launcher (Home, More and Web apps) on this device.'),
          const LauncherAppsChecklist(),
        ],
      ),
    );
  }
}

class _SeedSwatch extends StatelessWidget {
  const _SeedSwatch({
    required this.color,
    required this.name,
    required this.selected,
    required this.dimmed,
    required this.onTap,
  });

  final Color color;
  final String name;
  final bool selected;
  final bool dimmed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: '$name accent',
      selected: selected,
      button: true,
      child: Tooltip(
        message: name,
        child: InkResponse(
          key: Key('seed-$name'),
          onTap: onTap,
          radius: 28,
          child: Opacity(
            opacity: dimmed ? 0.6 : 1,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: selected ? scheme.onSurface : Colors.transparent, width: 3),
              ),
              child: selected ? const Icon(Icons.check, color: Colors.white) : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// Dashboard card checklist with drag-to-reorder (`hiddenCards`,
/// `cardOrder`). The System card can be hidden too: the dashboard still asks
/// for it to keep alerts live.
class DashboardCardsEditor extends ConsumerWidget {
  const DashboardCardsEditor({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final controller = ref.read(appSettingsProvider.notifier);
    final order = settings.orderedCards;
    final customised = settings.cardOrder.isNotEmpty || settings.hiddenCards.isNotEmpty;

    return Column(
      children: [
        ReorderableListView.builder(
          key: const Key('appearance-cards'),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: order.length,
          onReorderItem: (oldIndex, newIndex) {
            final next = [...order];
            next.insert(newIndex, next.removeAt(oldIndex));
            controller.setCardOrder(next);
          },
          itemBuilder: (context, i) {
            final key = order[i];
            final spec = dashboardCards[key];
            final visible = !settings.hiddenCards.contains(key);
            return ListTile(
              key: ValueKey('card-$key'),
              leading: Checkbox(
                key: Key('card-check-$key'),
                value: visible,
                onChanged: (v) => controller.setCardHidden(key, !(v ?? true)),
              ),
              title: Row(
                children: [
                  Icon(spec?.icon ?? Icons.dashboard_outlined, size: 20),
                  const SizedBox(width: 12),
                  Flexible(child: Text(spec?.title ?? key)),
                ],
              ),
              onTap: () => controller.setCardHidden(key, visible),
              trailing: ReorderableDragStartListener(
                index: i,
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.drag_handle, semanticLabel: 'Reorder'),
                ),
              ),
            );
          },
        ),
        if (customised)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton.icon(
                onPressed: () => controller.update((s) => s.copyWith(cardOrder: const [], hiddenCards: const {})),
                icon: const Icon(Icons.restart_alt),
                label: const Text('Reset cards'),
              ),
            ),
          ),
      ],
    );
  }
}

/// Launcher apps checklist writing `appSettingsProvider.hiddenLauncherApps`.
class LauncherAppsChecklist extends ConsumerWidget {
  const LauncherAppsChecklist({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hidden = ref.watch(appSettingsProvider.select((s) => s.hiddenLauncherApps));
    final controller = ref.read(appSettingsProvider.notifier);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final group in LauncherGroup.values) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(group.label, style: theme.textTheme.labelMedium),
          ),
          for (final MapEntry(key: app, value: spec) in launcherApps.entries)
            if (spec.group == group)
              CheckboxListTile(
                key: Key('launcher-app-${app.name}'),
                value: !hidden.contains(app),
                onChanged: (v) => controller.setLauncherAppHidden(app, !(v ?? true)),
                secondary: Icon(spec.icon),
                title: Text(app.displayName),
                dense: true,
              ),
        ],
        if (hidden.isNotEmpty)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton.icon(
                onPressed: () => controller.update((s) => s.copyWith(hiddenLauncherApps: const <ExternalApp>{})),
                icon: const Icon(Icons.visibility_outlined),
                label: const Text('Show all apps'),
              ),
            ),
          ),
      ],
    );
  }
}
