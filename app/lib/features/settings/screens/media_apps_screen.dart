/// `/settings/apps`: per-app base URL overrides and custom app URL schemes
/// (APP.md §13, ARCHITECTURE §7.10). Stored on this device.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/launcher/launcher_providers.dart';
import 'package:yams_hub/core/links/external_links.dart';
import 'package:yams_hub/core/settings/app_settings.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../widgets/settings_widgets.dart';

/// Apps with a native client that can be opened through a custom scheme.
const schemeApps = {ExternalApp.jellyfin, ExternalApp.audiobookshelf};

/// Example schemes shown as hints.
const _schemeHints = {ExternalApp.jellyfin: 'jellyfin://', ExternalApp.audiobookshelf: 'audiobookshelf://'};

/// Every configurable app, in launcher order.
List<ExternalApp> get configurableApps => [
  for (final group in LauncherGroup.values)
    for (final e in launcherApps.entries)
      if (e.value.group == group) e.key,
];

/// Validates a base URL override; null when valid (or empty = default).
String? validateBaseUrl(String input) {
  final s = input.trim();
  if (s.isEmpty) return null;
  final uri = Uri.tryParse(s.contains('://') ? s : 'http://$s');
  if (uri == null || uri.host.isEmpty || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return 'Enter an http(s) address, e.g. http://192.168.1.10:8096';
  }
  if (uri.hasQuery || uri.hasFragment) return 'Leave out ? and # parts';
  return null;
}

/// Validates a custom URL scheme; null when valid (or empty = none).
String? validateScheme(String input) {
  final s = input.trim();
  if (s.isEmpty) return null;
  final name = s.split(':').first;
  if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*$').hasMatch(name)) return 'Enter a scheme such as jellyfin://';
  if (name == 'http' || name == 'https') return 'Use the address field for web links';
  return null;
}

class MediaAppsScreen extends ConsumerWidget {
  const MediaAppsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolver = ref.watch(externalLinkResolverProvider);
    final defaults = ExternalLinkResolver(serverRoot: resolver.serverRoot, config: resolver.config);

    return Scaffold(
      appBar: AppBar(title: const Text('Media apps')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const SettingsHint(
            'Links into the apps use the hub\'s host and each app\'s port, so they work on LAN and Tailscale. '
            'Override an address only if an app lives somewhere else.',
            icon: Icons.info_outline,
          ),
          for (final app in configurableApps)
            _AppTile(
              app: app,
              effective: resolver.baseFor(app),
              custom: resolver.overrides.containsKey(app),
              scheme: resolver.schemes[app],
              onTap: () => showAppLinkEditor(context, app: app, defaultBase: defaults.baseFor(app)),
            ),
          const SettingsHint(
            'The Kavita Auth Key is not set here: it is a secret of the hub (see Media > Books).',
            icon: Icons.key_outlined,
          ),
        ],
      ),
    );
  }
}

class _AppTile extends StatelessWidget {
  const _AppTile({required this.app, required this.effective, required this.custom, this.scheme, this.onTap});

  final ExternalApp app;
  final Uri? effective;
  final bool custom;
  final String? scheme;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      effective?.toString() ?? 'No address',
      if (scheme != null) 'app link $scheme',
    ].join(' · ');
    return ListTile(
      key: Key('media-app-${app.name}'),
      leading: Icon(launcherApps[app]?.icon ?? Icons.open_in_new),
      title: Text(app.displayName),
      subtitle: Text(subtitle, overflow: TextOverflow.ellipsis),
      trailing: custom || scheme != null
          ? const StatusChip(label: 'Custom', tone: StatusTone.info, dense: true)
          : const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

/// Opens the editor sheet for [app].
Future<void> showAppLinkEditor(BuildContext context, {required ExternalApp app, required Uri? defaultBase}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => AppLinkEditor(app: app, defaultBase: defaultBase),
    );

/// Base URL override, custom scheme (Jellyfin/ABS), "Test open".
class AppLinkEditor extends ConsumerStatefulWidget {
  const AppLinkEditor({super.key, required this.app, required this.defaultBase});

  final ExternalApp app;
  final Uri? defaultBase;

  @override
  ConsumerState<AppLinkEditor> createState() => _AppLinkEditorState();
}

class _AppLinkEditorState extends ConsumerState<AppLinkEditor> {
  late final TextEditingController _base;
  late final TextEditingController _scheme;
  String? _baseError;
  String? _schemeError;

  ExternalApp get _app => widget.app;
  bool get _hasScheme => schemeApps.contains(_app);

  @override
  void initState() {
    super.initState();
    final settings = ref.read(appSettingsProvider);
    _base = TextEditingController(text: settings.externalBaseUrls[_app] ?? '');
    _scheme = TextEditingController(text: settings.appSchemes[_app] ?? '');
  }

  @override
  void dispose() {
    _base.dispose();
    _scheme.dispose();
    super.dispose();
  }

  /// The resolver as it would be with the draft values.
  ExternalLinkResolver _draft() {
    final r = ref.read(externalLinkResolverProvider);
    return ExternalLinkResolver(
      serverRoot: r.serverRoot,
      config: r.config,
      overrides: {...r.overrides}..remove(_app)..addAll({if (_base.text.trim().isNotEmpty) _app: _base.text.trim()}),
      schemes: {...r.schemes}..remove(_app)..addAll({if (_scheme.text.trim().isNotEmpty) _app: _scheme.text.trim()}),
    );
  }

  bool _validate() {
    setState(() {
      _baseError = validateBaseUrl(_base.text);
      _schemeError = _hasScheme ? validateScheme(_scheme.text) : null;
    });
    return _baseError == null && _schemeError == null;
  }

  Future<void> _testWeb() async {
    if (!_validate()) return;
    final uri = _draft().resolve(ExternalLink(_app, '/'));
    final ok = uri != null && await launchExternalUri(uri);
    if (!ok && mounted) context.showSnack("Couldn't open ${uri ?? _app.displayName}");
  }

  Future<void> _testApp() async {
    if (!_validate()) return;
    final uri = _draft().customScheme(_app);
    if (uri == null) return;
    final ok = await launchExternalUri(uri);
    if (!ok && mounted) context.showSnack('No app answered $uri on this device');
  }

  void _save() {
    if (!_validate()) return;
    final controller = ref.read(appSettingsProvider.notifier);
    controller.setExternalBaseUrl(_app, _base.text);
    if (_hasScheme) controller.setAppScheme(_app, _scheme.text);
    context.showSnack('Saved ${_app.displayName}');
    Navigator.of(context).pop();
  }

  void _reset() {
    final controller = ref.read(appSettingsProvider.notifier);
    controller.setExternalBaseUrl(_app, null);
    if (_hasScheme) controller.setAppScheme(_app, null);
    context.showSnack('${_app.displayName} uses the default address');
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final defaultText = widget.defaultBase?.toString();
    final customised = ref.watch(
      appSettingsProvider.select((s) => s.externalBaseUrls.containsKey(_app) || s.appSchemes.containsKey(_app)),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(launcherApps[_app]?.icon ?? Icons.open_in_new, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Text(_app.displayName, style: theme.textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('app-base-url'),
              controller: _base,
              keyboardType: TextInputType.url,
              autocorrect: false,
              onChanged: (_) => setState(() => _baseError = null),
              decoration: InputDecoration(
                labelText: 'Address',
                hintText: defaultText ?? 'http://host:port',
                helperText: defaultText == null ? 'Leave empty for the default' : 'Leave empty for $defaultText',
                helperMaxLines: 2,
                errorText: _baseError,
              ),
            ),
            if (_hasScheme) ...[
              const SizedBox(height: 16),
              TextField(
                key: const Key('app-scheme'),
                controller: _scheme,
                keyboardType: TextInputType.url,
                autocorrect: false,
                onChanged: (_) => setState(() => _schemeError = null),
                decoration: InputDecoration(
                  labelText: 'App link scheme (optional)',
                  hintText: _schemeHints[_app],
                  helperText: '"Open app" tries this first, then the store page, then the web',
                  helperMaxLines: 2,
                  errorText: _schemeError,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                if (customised) TextButton(onPressed: _reset, child: const Text('Reset')),
                OutlinedButton.icon(
                  key: const Key('app-test-open'),
                  onPressed: _testWeb,
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('Test open'),
                ),
                if (_hasScheme && _scheme.text.trim().isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: _testApp,
                    icon: const Icon(Icons.launch, size: 18),
                    label: const Text('Test app'),
                  ),
                FilledButton(key: const Key('app-save'), onPressed: _save, child: const Text('Save')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
