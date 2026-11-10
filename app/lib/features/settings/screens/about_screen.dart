/// `/settings/about`: app and gateway versions, API version, instance id,
/// service health summary, public URLs, the Tailscale note and licenses
/// (APP.md §13).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/app_info.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/servers/server_config_provider.dart';
import 'package:yams_hub/core/servers/server_connection.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../providers/settings_providers.dart';
import '../widgets/settings_widgets.dart';

/// Untrusted-network advice (ARCHITECTURE §7.5).
const tailscaleNote = 'On untrusted Wi-Fi, use the Tailscale URL';

class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(serverConfigProvider);
    final health = ref.watch(healthProvider);
    final app = ref.watch(appVersionProvider).value;
    final ping = ref.watch(activeServerProvider.select((s) => s.ping));
    final appVersion = app == null ? hubAppVersion : (app.build == null ? app.version : '${app.version} (${app.build})');

    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(serverConfigProvider);
          await Future.wait([
            awaitRefresh(ref.read(serverConfigProvider.future)),
            awaitRefresh(ref.refresh(healthProvider.future)),
          ]);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            const SettingsSectionHeader('Versions'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: KeyValueList(
                labelWidth: 120,
                entries: [
                  KeyValue('App', appVersion),
                  KeyValue.widget('Gateway', _configValue(config, (c) => c.version, fallback: ping?.version)),
                  KeyValue('API', 'v${ping?.apiVersion ?? supportedApiVersion}'),
                  KeyValue.widget(
                    'Instance',
                    _configValue(config, (c) => c.instanceId, fallback: ping?.instanceId, copyable: true),
                  ),
                ],
              ),
            ),
            const SettingsSectionHeader('Services'),
            _HealthSummary(health: health, onRetry: () => ref.invalidate(healthProvider)),
            const SettingsSectionHeader('Addresses'),
            ...config.when(
              skipLoadingOnRefresh: true,
              skipLoadingOnReload: true,
              loading: () => const [Padding(padding: EdgeInsets.all(16), child: SkeletonBox(height: 40))],
              error: (e, _) => [ErrorView(error: e, compact: true, onRetry: () => ref.invalidate(serverConfigProvider))],
              data: (c) => [
                if (c.publicUrls.isEmpty) const ListTile(title: Text('No public addresses configured')),
                for (final u in c.publicUrls) _UrlTile(url: u),
              ],
            ),
            const SettingsHint(tailscaleNote, icon: Icons.vpn_lock_outlined),
            const SettingsSectionHeader('Legal'),
            ListTile(
              key: const Key('about-licenses'),
              leading: const Icon(Icons.article_outlined),
              title: const Text('Open-source licenses'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showLicensePage(
                context: context,
                applicationName: appTitle,
                applicationVersion: appVersion,
                applicationLegalese: 'A companion for the YAMS media stack.',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _configValue(
    AsyncValue<ServerConfig> config,
    String Function(ServerConfig c) read, {
    String? fallback,
    bool copyable = false,
  }) {
    final value = config.value == null ? fallback : read(config.value!);
    if (value == null) {
      return config.hasError ? const Text('–') : const SkeletonBox(width: 120, height: 14);
    }
    return copyable ? _CopyableText(value) : SelectableText(value);
  }
}

class _CopyableText extends StatelessWidget {
  const _CopyableText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Flexible(child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace'))),
      IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: 'Copy',
        icon: const Icon(Icons.copy, size: 18),
        onPressed: () => _copy(context, text),
      ),
    ],
  );
}

Future<void> _copy(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) context.showSnack('Copied');
}

class _UrlTile extends StatelessWidget {
  const _UrlTile({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(url);
    return ListTile(
      key: Key('about-url-$url'),
      leading: const Icon(Icons.link),
      title: SelectableText(url),
      subtitle: uri == null || uri.host.isEmpty ? null : Align(alignment: Alignment.centerLeft, child: NetworkChip(uri)),
      trailing: IconButton(tooltip: 'Copy $url', icon: const Icon(Icons.copy), onPressed: () => _copy(context, url)),
    );
  }
}

/// Overall status plus one row per service (`GET /health`).
class _HealthSummary extends StatelessWidget {
  const _HealthSummary({required this.health, required this.onRetry});

  final AsyncValue<HealthReport> health;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final report = health.value;
    if (report == null) {
      if (health.hasError) return ErrorView(error: health.error!, compact: true, onRetry: onRetry);
      return const SkeletonRows();
    }
    final theme = Theme.of(context);
    final configured = report.services.where((s) => s.status != ServiceHealthStatus.disabled).toList();
    final up = configured.where((s) => s.status == ServiceHealthStatus.up).length;
    final problems = report.services
        .where((s) => s.status == ServiceHealthStatus.down || s.status == ServiceHealthStatus.degraded)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (health.hasError) StaleBanner(onRetry: onRetry),
        ListTile(
          key: const Key('about-health-overall'),
          leading: StatusDot(tone: toneForHealth(report.overall), size: 14),
          title: Text('$up of ${configured.length} services up'),
          subtitle: Text('Checked ${formatRelative(report.checkedAt)}'),
          trailing: StatusChip.health(report.overall),
          onTap: () => context.go(AppPaths.system()),
        ),
        for (final s in problems)
          ListTile(
            dense: true,
            leading: StatusDot(tone: toneForHealth(s.status)),
            title: Text(s.name),
            subtitle: s.message == null ? null : Text(s.message!, maxLines: 4, overflow: TextOverflow.ellipsis),
            trailing: StatusChip.health(s.status, dense: true),
          ),
        ExpansionTile(
          key: const Key('about-health-all'),
          title: Text('All services', style: theme.textTheme.bodyMedium),
          children: [
            for (final s in report.services)
              ListTile(
                dense: true,
                leading: StatusDot(tone: toneForHealth(s.status)),
                title: Text(s.name),
                subtitle: Text(
                  [
                    if (s.version != null) s.version!,
                    if (s.latencyMs != null) '${s.latencyMs} ms',
                  ].join(' · ').ifEmptyDash,
                ),
                trailing: StatusChip.health(s.status, dense: true),
              ),
          ],
        ),
      ],
    );
  }
}

extension on String {
  String get ifEmptyDash => isEmpty ? '–' : this;
}
