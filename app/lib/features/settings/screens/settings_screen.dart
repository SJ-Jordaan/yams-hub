/// `/settings`: the grouped settings list (APP.md §13).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/api/api_client.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/servers/hosting.dart';
import 'package:yams_hub/core/servers/server_connection.dart';
import 'package:yams_hub/core/settings/app_settings.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';

import '../widgets/settings_widgets.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showServers = ref.watch(hostingModeProvider).hasServerProfiles;
    final auth = ref.watch(authControllerProvider);
    final isAdmin = ref.watch(isAdminProvider);
    final preset = ref.watch(appSettingsProvider.select((s) => s.refreshPreset));
    final user = auth.user;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (showServers) ...[
            const SettingsSectionHeader('Server'),
            const _ServerTile(),
          ],
          const SettingsSectionHeader('Account'),
          ListTile(
            key: const Key('settings-account'),
            leading: InitialAvatar(user?.displayName ?? '?'),
            title: Text(user == null ? 'Signed in' : 'Signed in as ${user.displayName}'),
            subtitle: user == null ? null : Text('@${user.username}'),
            trailing: user == null ? null : RoleChip(user.role),
            onTap: () => context.push(AppPaths.settingsAccount()),
          ),
          ListTile(
            leading: const Icon(Icons.devices_outlined),
            title: const Text('Sessions'),
            subtitle: const Text('Devices signed in to the hub'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppPaths.settingsSessions()),
          ),
          const SignOutTile(),
          if (isAdmin) ...[
            const SettingsSectionHeader('Administration'),
            ListTile(
              leading: const Icon(Icons.group_outlined),
              title: const Text('Users'),
              subtitle: const Text('Hub accounts, Jellyfin and Seerr links'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push(AppPaths.settingsUsers()),
            ),
            ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: const Text('Audit log'),
              subtitle: const Text('Who changed what'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push(AppPaths.settingsAudit()),
            ),
          ],
          const SettingsSectionHeader('This device'),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Appearance'),
            subtitle: const Text('Theme, colours, dashboard cards, web apps'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppPaths.settingsAppearance()),
          ),
          ListTile(
            leading: const Icon(Icons.update),
            title: const Text('Refresh'),
            subtitle: Text(preset.label),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppPaths.settingsRefresh()),
          ),
          ListTile(
            leading: const Icon(Icons.open_in_new),
            title: const Text('Media apps'),
            subtitle: const Text('Addresses and app links'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppPaths.settingsApps()),
          ),
          const SettingsSectionHeader('About'),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About YAMS Hub'),
            subtitle: const Text('Versions, health, addresses, licenses'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppPaths.settingsAbout()),
          ),
          const SettingsHint('Settings other than the server and your account are stored on this device only.'),
        ],
      ),
    );
  }
}

/// Active profile name, URL in use and the LAN/Tailscale chip.
class _ServerTile extends ConsumerWidget {
  const _ServerTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(activeServerProvider);
    final profile = connection.profile;
    final url = connection.baseUrl;
    final subtitle = switch (connection.status) {
      ConnectionStatus.connected when url != null => url.toString(),
      ConnectionStatus.resolving => 'Connecting…',
      ConnectionStatus.unreachable => 'Not reachable (tried ${profile?.urls.length ?? 0} addresses)',
      _ => 'No server configured',
    };
    return ListTile(
      key: const Key('settings-server'),
      leading: const Icon(Icons.dns_outlined),
      title: Text(profile?.name ?? 'Server'),
      subtitle: Text(subtitle),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (url != null && connection.isConnected) NetworkChip(url),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: () => context.push(AppPaths.settingsServers()),
    );
  }
}

/// "Sign out" (`POST /auth/logout`) with a confirmation; the router then
/// shows the login screen.
class SignOutTile extends ConsumerStatefulWidget {
  const SignOutTile({super.key});

  @override
  ConsumerState<SignOutTile> createState() => _SignOutTileState();
}

class _SignOutTileState extends ConsumerState<SignOutTile> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final error = StatusColors.of(context).error;
    return ListTile(
      key: const Key('settings-sign-out'),
      leading: _busy
          ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(Icons.logout, color: error),
      title: Text('Sign out', style: TextStyle(color: error)),
      enabled: !_busy,
      onTap: _signOut,
    );
  }

  Future<void> _signOut() async {
    final name = ref.read(activeServerProvider).profile?.name;
    final ok = await ConfirmDialog.show(
      context,
      title: 'Sign out?',
      message: name == null ? 'You will need your password to sign in again.' : 'Sign out of $name on this device?',
      confirmLabel: 'Sign out',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(authControllerProvider.notifier).logout();
    } on ApiException catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
