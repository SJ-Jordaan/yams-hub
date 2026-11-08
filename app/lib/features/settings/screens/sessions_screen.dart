/// `/settings/sessions`: signed-in devices (`GET /auth/sessions`); admins can
/// switch to every user's sessions. Revoke with a confirmation
/// (`DELETE /auth/sessions/{id}`) (APP.md §13).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_client.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/settings_api.dart';
import '../providers/settings_providers.dart';
import '../widgets/settings_widgets.dart';

class SessionsScreen extends ConsumerStatefulWidget {
  const SessionsScreen({super.key});

  @override
  ConsumerState<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends ConsumerState<SessionsScreen> {
  bool _all = false;
  final Set<String> _revoking = {};

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(isAdminProvider);
    final all = isAdmin && _all;
    final sessions = ref.watch(sessionsProvider(all));

    return Scaffold(
      appBar: AppBar(title: const Text('Sessions')),
      body: Column(
        children: [
          if (isAdmin)
            SwitchListTile(
              key: const Key('sessions-all-users'),
              title: const Text('All users'),
              subtitle: const Text('Show every session on the hub'),
              value: _all,
              onChanged: (v) => setState(() => _all = v),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => awaitRefresh(ref.refresh(sessionsProvider(all).future)),
              child: AsyncValueView<List<SessionInfo>>(
                value: sessions,
                onRetry: () => ref.invalidate(sessionsProvider(all)),
                data: (context, list) => list.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: const [
                          EmptyView(icon: Icons.devices_outlined, title: 'No sessions', message: 'Nobody is signed in.'),
                        ],
                      )
                    : ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.only(bottom: 24),
                        itemCount: list.length,
                        separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
                        itemBuilder: (context, i) => _SessionTile(
                          session: list[i],
                          showUser: all,
                          busy: _revoking.contains(list[i].id),
                          onRevoke: () => _revoke(list[i], all),
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _revoke(SessionInfo session, bool all) async {
    if (session.current) {
      final ok = await ConfirmDialog.show(
        context,
        title: 'Sign out of this device?',
        message: 'This is the session you are using now.',
        confirmLabel: 'Sign out',
        destructive: true,
      );
      if (!ok || !mounted) return;
      await ref.read(authControllerProvider.notifier).logout();
      return;
    }
    final who = session.username == null ? '' : ' (${session.username})';
    final ok = await ConfirmDialog.show(
      context,
      title: 'Revoke ${session.deviceName}$who?',
      message: 'The device is signed out and needs the password to sign in again.',
      confirmLabel: 'Revoke',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _revoking.add(session.id));
    try {
      await ref.read(settingsApiProvider).revokeSession(session.id);
      if (!mounted) return;
      context.showSnack('Revoked ${session.deviceName}');
      ref.invalidate(sessionsProvider);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == ApiErrorCode.notFound) {
        context.showSnack('That session had already ended');
        ref.invalidate(sessionsProvider);
      } else {
        // "Result unknown": the hub may have revoked it; reload to check.
        if (e.code == ClientErrorCode.resultUnknown) ref.invalidate(sessionsProvider);
        context.showError(e);
      }
    } finally {
      if (mounted) setState(() => _revoking.remove(session.id));
    }
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session, required this.showUser, required this.busy, required this.onRevoke});

  final SessionInfo session;
  final bool showUser;
  final bool busy;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = session;
    final details = [
      if (showUser && s.username != null) s.username!,
      platformLabelOf(s.platform),
      ?s.lastIp,
    ].join(' · ');
    return ListTile(
      key: Key('session-${s.id}'),
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.secondaryContainer,
        foregroundColor: theme.colorScheme.onSecondaryContainer,
        child: Icon(platformIcon(s.platform)),
      ),
      title: Row(
        children: [
          Flexible(child: Text(s.deviceName, overflow: TextOverflow.ellipsis)),
          if (s.current) ...[
            const SizedBox(width: 8),
            const StatusChip(label: 'This device', tone: StatusTone.ok, dense: true),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(details),
          Tooltip(
            message: 'Signed in ${formatDateTime(s.createdAt)} · last seen ${formatDateTime(s.lastSeenAt)}',
            child: Text('Last seen ${formatRelative(s.lastSeenAt)} · signed in ${formatDate(s.createdAt)}'),
          ),
        ],
      ),
      isThreeLine: true,
      trailing: busy
          ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
          : IconButton(
              tooltip: s.current ? 'Sign out' : 'Revoke',
              icon: Icon(s.current ? Icons.logout : Icons.block),
              onPressed: onRevoke,
            ),
    );
  }
}
