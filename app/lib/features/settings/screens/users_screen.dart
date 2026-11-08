/// `/settings/users` (admin): hub users with role, Jellyfin link, disabled
/// state and the "No Seerr account" chip (APP.md §13).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../providers/settings_providers.dart';
import '../widgets/settings_widgets.dart';

/// Route id of the "Add user" editor.
const newUserId = 'new';

class UsersScreen extends ConsumerWidget {
  const UsersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final users = ref.watch(usersProvider);
    // The chips need the Jellyfin users; when they fail the list still shows.
    final jellyfin = ref.watch(jellyfinUsersProvider);
    final meId = ref.watch(authControllerProvider.select((s) => s.user?.id));

    return Scaffold(
      appBar: AppBar(title: const Text('Users')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push(AppPaths.settingsUser(newUserId)),
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Add user'),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(jellyfinUsersProvider);
          await awaitRefresh(ref.refresh(usersProvider.future));
        },
        child: AsyncValueView<List<User>>(
          value: users,
          onRetry: () => ref.invalidate(usersProvider),
          data: (context, list) {
            final options = jellyfin.value;
            final needsImport = [
              for (final u in list)
                if (seerrLinkIssue(u, options) == SeerrLinkIssue.noSeerrAccount) u,
            ];
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 96),
              children: [
                if (jellyfin.hasError && !jellyfin.hasValue)
                  StaleBanner(
                    message: "Couldn't load Jellyfin users · Seerr links unknown",
                    onRetry: () => ref.invalidate(jellyfinUsersProvider),
                  ),
                if (needsImport.isNotEmpty)
                  SettingsHint(
                    '${needsImport.length == 1 ? '1 user has' : '${needsImport.length} users have'} no Seerr '
                    'account and cannot request until imported. Open the user and tap "Import into Seerr".',
                    icon: Icons.info_outline,
                  ),
                if (list.isEmpty)
                  const EmptyView(icon: Icons.group_outlined, title: 'No users', message: 'Add the first account.')
                else
                  for (final u in list)
                    UserTile(
                      user: u,
                      jellyfin: jellyfinOptionFor(u.jellyfinUserId, options),
                      jellyfinLoaded: options != null,
                      issue: seerrLinkIssue(u, options),
                      isMe: u.id == meId,
                      onTap: () => context.push(AppPaths.settingsUser(u.id)),
                    ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// One user row: name, username, Jellyfin user, role and status chips.
class UserTile extends StatelessWidget {
  const UserTile({
    super.key,
    required this.user,
    this.jellyfin,
    this.jellyfinLoaded = true,
    this.issue,
    this.isMe = false,
    this.onTap,
  });

  final User user;
  final JellyfinUserOption? jellyfin;

  /// Whether the Jellyfin users are known; until then a link is shown
  /// without a name (rather than as an unknown user).
  final bool jellyfinLoaded;
  final SeerrLinkIssue? issue;
  final bool isMe;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final link = user.jellyfinUserId;
    final linked = link == null || link.isEmpty
        ? null
        : (jellyfin?.name ?? (jellyfinLoaded ? 'Unknown Jellyfin user' : 'linked'));
    final subtitle = [
      '@${user.username}',
      if (linked != null) 'Jellyfin: $linked',
    ].join(' · ');
    return ListTile(
      key: Key('user-${user.id}'),
      onTap: onTap,
      leading: Opacity(opacity: user.disabled ? 0.5 : 1, child: InitialAvatar(user.displayName)),
      title: Text(
        isMe ? '${user.displayName} (you)' : user.displayName,
        style: user.disabled ? TextStyle(color: theme.colorScheme.onSurfaceVariant) : null,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(subtitle, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              RoleChip(user.role),
              if (user.disabled) const StatusChip(label: 'Disabled', tone: StatusTone.neutral, dense: true),
              if (issue != null)
                StatusChip(
                  key: Key('user-${user.id}-issue'),
                  label: issue!.label,
                  tone: StatusTone.warning,
                  dense: true,
                ),
            ],
          ),
        ],
      ),
      isThreeLine: true,
      trailing: const Icon(Icons.chevron_right),
    );
  }
}
