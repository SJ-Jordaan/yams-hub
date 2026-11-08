/// `/settings/servers`: server profiles (APP.md §13, ARCHITECTURE §7.5).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/servers/server_connection.dart';
import 'package:yams_hub/core/servers/server_profile.dart';
import 'package:yams_hub/core/servers/server_store.dart';
import 'package:yams_hub/core/widgets/widgets.dart';

import '../providers/settings_providers.dart';
import '../widgets/settings_widgets.dart';

/// Route id of the "Add server" editor.
const newServerId = 'new';

class ServersScreen extends ConsumerWidget {
  const ServersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(serverStoreProvider);
    final activeId = store.active?.id;
    final connection = ref.watch(activeServerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Servers')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push(AppPaths.settingsServer(newServerId)),
        icon: const Icon(Icons.add),
        label: const Text('Add server'),
      ),
      body: store.profiles.isEmpty
          ? const EmptyView(icon: Icons.dns_outlined, title: 'No servers', message: 'Add your YAMS Hub to get started.')
          : RadioGroup<String>(
              groupValue: activeId,
              onChanged: (id) {
                if (id == null || id == activeId) return;
                ref.read(serverStoreProvider.notifier).setActive(id);
                final name = ref.read(serverStoreProvider).byId(id)?.name ?? 'server';
                context.showSnack('Switched to $name');
              },
              child: ListView(
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  for (final p in store.profiles)
                    _ProfileTile(
                      profile: p,
                      active: p.id == activeId,
                      connection: p.id == activeId ? connection : null,
                    ),
                  const SettingsHint(
                    'The app tries the last working address first and falls back to the others (LAN, then '
                    'Tailscale). On networks it does not recognise, Tailscale goes first.',
                    icon: Icons.info_outline,
                  ),
                ],
              ),
            ),
    );
  }
}

class _ProfileTile extends ConsumerWidget {
  const _ProfileTile({required this.profile, required this.active, this.connection});

  final ServerProfile profile;
  final bool active;
  final ServerConnection? connection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = connection;
    final inUse = c != null && c.isConnected ? c.baseUrl : null;
    final urls = profile.urls.map((u) => u.toString()).join('\n');
    return ListTile(
      key: Key('server-${profile.id}'),
      leading: Radio<String>(value: profile.id),
      title: Row(
        children: [
          Flexible(child: Text(profile.name, overflow: TextOverflow.ellipsis)),
          if (inUse != null) ...[const SizedBox(width: 8), NetworkChip(inUse)],
        ],
      ),
      subtitle: Text(urls.isEmpty ? 'No addresses' : urls),
      isThreeLine: profile.urls.length > 1,
      onTap: () => context.push(AppPaths.settingsServer(profile.id)),
      trailing: PopupMenuButton<String>(
        tooltip: 'More',
        onSelected: (v) async {
          switch (v) {
            case 'edit':
              await context.push(AppPaths.settingsServer(profile.id));
            case 'delete':
              await deleteServerProfile(context, ref, profile);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Edit'))),
          PopupMenuItem(
            value: 'delete',
            child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Delete')),
          ),
        ],
      ),
    );
  }
}

/// Confirms, signs out of [profile] and removes it. True when removed.
Future<bool> deleteServerProfile(BuildContext context, WidgetRef ref, ServerProfile profile) async {
  final store = ref.read(serverStoreProvider);
  final isActive = store.active?.id == profile.id;
  final last = store.profiles.length == 1;
  final ok = await ConfirmDialog.show(
    context,
    title: 'Delete ${profile.name}?',
    message: [
      'This device signs out of ${profile.name} and forgets its addresses.',
      if (last) 'It is your only server: you will set up a server again.',
    ].join(' '),
    confirmLabel: 'Delete',
    destructive: true,
  );
  if (!ok) return false;
  // Read before awaiting: signing out of the active server navigates to the
  // login screen, which disposes the calling widget (and its ref).
  final storeNotifier = ref.read(serverStoreProvider.notifier);
  await signOutOfProfile(ref, profile, isActive: isActive);
  storeNotifier.remove(profile.id);
  return true;
}

/// Ends this device's session on [profile]: the active profile signs out
/// through the hub (`POST /auth/logout`); another profile only forgets its
/// stored tokens (it is not connected, so nothing can be sent to it).
Future<void> signOutOfProfile(WidgetRef ref, ServerProfile profile, {required bool isActive}) async {
  if (isActive) {
    final auth = ref.read(authControllerProvider.notifier);
    if (ref.read(authControllerProvider).signedIn) await auth.logout();
    return;
  }
  final instanceId = profile.instanceId;
  if (instanceId == null) return;
  final store = ref.read(profileTokenStoreProvider);
  try {
    await store.delete(instanceId);
  } catch (_) {
    // Nothing stored, or storage unavailable: nothing to forget.
  }
}
