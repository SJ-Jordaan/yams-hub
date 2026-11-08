/// `/settings/users/:id` (admin): add (id `new`) or edit a hub user, link a
/// Jellyfin user and import it into Seerr (APP.md §13, API.md §2.3).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/api/api_client.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../providers/settings_providers.dart';
import '../widgets/settings_widgets.dart';
import 'users_screen.dart' show newUserId;

/// Hub usernames (ARCHITECTURE §4; the gateway validates too).
final _usernamePattern = RegExp(r'^[a-z0-9._-]{2,32}$');

/// Request fields the form shows errors on.
const _formFields = {'username', 'displayName', 'password', 'jellyfinUserId'};

class UserEditorScreen extends ConsumerWidget {
  const UserEditorScreen({super.key, required this.userId});

  /// The user to edit, or [newUserId].
  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (userId == newUserId) return const _UserForm(user: null);
    final users = ref.watch(usersProvider);
    return users.when(
      skipLoadingOnRefresh: true,
      skipLoadingOnReload: true,
      loading: () => Scaffold(appBar: AppBar(title: const Text('User')), body: const SkeletonList(count: 5)),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('User')),
        body: ErrorView(error: e, onRetry: () => ref.invalidate(usersProvider)),
      ),
      data: (list) {
        final user = list.where((u) => u.id == userId).firstOrNull;
        if (user == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('User')),
            body: EmptyView(
              icon: Icons.person_off_outlined,
              title: 'User not found',
              message: 'It may have been deleted.',
              action: FilledButton.tonal(
                onPressed: () => context.go(AppPaths.settingsUsers()),
                child: const Text('All users'),
              ),
            ),
          );
        }
        return _UserForm(key: ValueKey(user.id), user: user);
      },
    );
  }
}

class _UserForm extends ConsumerStatefulWidget {
  const _UserForm({super.key, required this.user});

  final User? user;

  @override
  ConsumerState<_UserForm> createState() => _UserFormState();
}

class _UserFormState extends ConsumerState<_UserForm> {
  late final TextEditingController _username = TextEditingController(text: widget.user?.username ?? '');
  late final TextEditingController _displayName = TextEditingController(text: widget.user?.displayName ?? '');
  final _password = TextEditingController();
  late Role _role = widget.user?.role ?? Role.member;
  late String? _jellyfinId = widget.user?.jellyfinUserId;
  late bool _disabled = widget.user?.disabled ?? false;
  bool _saving = false;
  bool _deleting = false;
  bool _importing = false;
  Map<String, String> _fieldErrors = const {};

  bool get _isNew => widget.user == null;

  /// Hub usernames are lowercase (ARCHITECTURE §4); typed capitals are folded.
  String get _normalizedUsername => _username.text.trim().toLowerCase();

  bool get _isMe => widget.user != null && widget.user!.id == ref.read(authControllerProvider).user?.id;

  @override
  void dispose() {
    _username.dispose();
    _displayName.dispose();
    _password.dispose();
    super.dispose();
  }

  bool _validate() {
    final errors = <String, String>{};
    if (_isNew && !_usernamePattern.hasMatch(_normalizedUsername)) {
      errors['username'] = '2–32 characters: lowercase letters, digits, . _ -';
    }
    if (!_isNew && _displayName.text.trim().isEmpty) errors['displayName'] = 'Enter a display name';
    final pw = _password.text;
    if (_isNew && pw.length < minPasswordLength) {
      errors['password'] = 'At least $minPasswordLength characters';
    } else if (!_isNew && pw.isNotEmpty && pw.length < minPasswordLength) {
      errors['password'] = 'At least $minPasswordLength characters';
    }
    setState(() => _fieldErrors = errors);
    return errors.isEmpty;
  }

  /// Only the fields that changed; an empty Jellyfin id clears the link.
  UpdateUserRequest _changes(User user) {
    final displayName = _displayName.text.trim();
    final oldLink = user.jellyfinUserId == null ? null : normalizeJellyfinId(user.jellyfinUserId!);
    final newLink = _jellyfinId == null ? null : normalizeJellyfinId(_jellyfinId!);
    return UpdateUserRequest(
      displayName: displayName != user.displayName ? displayName : null,
      role: _role != user.role ? _role : null,
      jellyfinUserId: oldLink == newLink ? null : (_jellyfinId ?? ''),
      disabled: _disabled != user.disabled ? _disabled : null,
      password: _password.text.isEmpty ? null : _password.text,
    );
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    if (!_validate()) return;
    final controller = ref.read(usersProvider.notifier);
    final user = widget.user;
    setState(() => _saving = true);
    try {
      if (user == null) {
        final username = _normalizedUsername;
        final displayName = _displayName.text.trim();
        final created = await controller.create(
          CreateUserRequest(
            username: username,
            displayName: displayName.isEmpty ? username : displayName,
            password: _password.text,
            role: _role,
            jellyfinUserId: _jellyfinId,
          ),
        );
        if (!mounted) return;
        context.showSnack('Added ${created.displayName}');
      } else {
        final changes = _changes(user);
        if (changes.isEmpty) {
          _close();
          return;
        }
        if (_isMe && changes.role != null && !changes.role!.isAdmin) {
          final ok = await ConfirmDialog.show(
            context,
            title: 'Remove your admin role?',
            message: 'You will lose access to Users, Audit log and every admin action right away.',
            confirmLabel: 'Make me a member',
            destructive: true,
          );
          if (!ok || !mounted) return;
        }
        final saved = await controller.save(user.id, changes);
        if (!mounted) return;
        // Editing yourself: keep the cached role and name in sync.
        if (saved.id == ref.read(authControllerProvider).user?.id) ref.invalidate(meProvider);
        context.showSnack(changes.password != null ? 'Saved. ${saved.displayName} was signed out everywhere.' : 'Saved');
      }
      _close();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == ApiErrorCode.alreadyExists) {
        setState(() => _fieldErrors = {'username': 'This username is taken'});
        return;
      }
      if (e.code == ClientErrorCode.resultUnknown) ref.invalidate(usersProvider);
      final shown = {for (final f in e.fields) if (_formFields.contains(f.field)) f.field: f.message};
      if (shown.isNotEmpty) setState(() => _fieldErrors = shown);
      // Errors that no field of the form can show (or none at all) go to a SnackBar.
      if (shown.length != e.fields.length || e.fields.isEmpty) context.showError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final user = widget.user;
    if (user == null) return;
    final ok = await ConfirmDialog.show(
      context,
      title: 'Delete ${user.displayName}?',
      message: 'The account is removed and every device it is signed in on is signed out. This cannot be undone.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _deleting = true);
    try {
      await ref.read(usersProvider.notifier).delete(user.id);
      if (!mounted) return;
      context.showSnack('Deleted ${user.displayName}');
      _close();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == ClientErrorCode.resultUnknown) ref.invalidate(usersProvider);
      context.showError(e);
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Future<void> _import(JellyfinUserOption option) async {
    final ok = await ConfirmDialog.show(
      context,
      title: 'Import into Seerr?',
      message: 'Create a Seerr account for ${option.name} with the default permissions?',
      confirmLabel: 'Import',
    );
    if (!ok || !mounted) return;
    setState(() => _importing = true);
    try {
      final updated = await ref.read(jellyfinUsersProvider.notifier).importToSeerr(option.jellyfinUserId);
      if (!mounted) return;
      context.showSnack(
        updated.seerrUserId == null
            ? 'Seerr did not create an account for ${option.name}'
            : 'Imported ${option.name} into Seerr',
      );
    } on ApiException catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _close() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppPaths.settingsUsers());
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.user;
    final meId = ref.watch(authControllerProvider.select((s) => s.user?.id));
    final isMe = user != null && user.id == meId;
    final busy = _saving || _deleting;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'Add user' : user!.displayName),
        actions: [
          if (!_isNew && !isMe)
            IconButton(
              key: const Key('user-delete'),
              tooltip: 'Delete user',
              icon: _deleting
                  ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.delete_outline),
              onPressed: busy ? null : _delete,
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            if (_isNew)
              TextField(
                key: const Key('user-username'),
                controller: _username,
                autocorrect: false,
                enableSuggestions: false,
                enabled: !busy,
                decoration: InputDecoration(
                  labelText: 'Username',
                  helperText: 'Used to sign in; cannot be changed later',
                  errorText: _fieldErrors['username'],
                ),
              )
            else
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: InitialAvatar(user!.displayName),
                title: Text('@${user.username}'),
                subtitle: Text('Created ${formatDate(user.createdAt)} · updated ${formatRelative(user.updatedAt)}'),
              ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('user-display-name'),
              controller: _displayName,
              enabled: !busy,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: 'Display name',
                helperText: _isNew ? 'Defaults to the username' : null,
                errorText: _fieldErrors['displayName'],
              ),
            ),
            const SizedBox(height: 20),
            Text('Role', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            SegmentedButton<Role>(
              key: const Key('user-role'),
              segments: const [
                ButtonSegment(value: Role.member, label: Text('Member'), icon: Icon(Icons.person_outline)),
                ButtonSegment(value: Role.admin, label: Text('Admin'), icon: Icon(Icons.admin_panel_settings_outlined)),
              ],
              selected: {if (_role == Role.unknown) Role.member else _role},
              onSelectionChanged: busy ? null : (s) => setState(() => _role = s.first),
            ),
            SettingsHint(
              _role.isAdmin
                  ? 'Admins can change the library, downloads, containers and users.'
                  : 'Members browse, request and watch; they cannot change anything on the server.',
            ),
            const SizedBox(height: 12),
            if (isMe)
              // A reset here would revoke this device's session too; the
              // account page asks for the current password instead.
              ListTile(
                key: const Key('user-own-password'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.password),
                title: const Text('Change your password'),
                subtitle: const Text('In Account, with your current password'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(AppPaths.settingsAccount()),
              )
            else ...[
              PasswordField(
                key: const Key('user-password'),
                controller: _password,
                label: _isNew ? 'Password' : 'New password (optional)',
                errorText: _fieldErrors['password'],
                enabled: !busy,
                autofillHints: const [AutofillHints.newPassword],
                onChanged: (_) => setState(() {}),
              ),
              if (_isNew || _password.text.isNotEmpty) PasswordStrengthHint(password: _password.text),
              if (!_isNew) const SettingsHint('Setting a new password signs the user out on every device.'),
            ],
            const SizedBox(height: 20),
            Text('Jellyfin user', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            _JellyfinLink(
              userId: user?.id,
              selected: _jellyfinId,
              enabled: !busy,
              importing: _importing,
              error: _fieldErrors['jellyfinUserId'],
              onChanged: (id) => setState(() => _jellyfinId = id),
              onImport: _import,
            ),
            if (!_isNew) ...[
              const SizedBox(height: 12),
              SwitchListTile(
                key: const Key('user-disabled'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Disabled'),
                subtitle: const Text('A disabled user cannot sign in; their devices are signed out.'),
                value: _disabled,
                onChanged: busy || isMe ? null : (v) => setState(() => _disabled = v),
              ),
            ],
            const SizedBox(height: 24),
            Align(
              alignment: Alignment.centerRight,
              child: BusyButton(
                key: const Key('user-save'),
                label: _isNew ? 'Add user' : 'Save',
                busy: _saving,
                onPressed: busy ? null : _save,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The Jellyfin user dropdown (`GET /admin/jellyfin-users`) plus the Seerr
/// account of the selected user, or "No Seerr account" with "Import into
/// Seerr".
class _JellyfinLink extends ConsumerWidget {
  const _JellyfinLink({
    required this.userId,
    required this.selected,
    required this.enabled,
    required this.importing,
    required this.onChanged,
    required this.onImport,
    this.error,
  });

  /// The hub user being edited (null when creating).
  final String? userId;
  final String? selected;
  final bool enabled;
  final bool importing;
  final String? error;
  final ValueChanged<String?> onChanged;
  final ValueChanged<JellyfinUserOption> onImport;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jellyfin = ref.watch(jellyfinUsersProvider);
    final hubUsers = {for (final u in ref.watch(usersProvider).value ?? const <User>[]) u.id: u.displayName};
    final options = jellyfin.value;

    if (options == null) {
      if (jellyfin.hasError) {
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.error_outline),
          title: const Text("Couldn't load Jellyfin users"),
          subtitle: Text(ApiException.from(jellyfin.error!).message),
          trailing: TextButton(onPressed: () => ref.invalidate(jellyfinUsersProvider), child: const Text('Retry')),
        );
      }
      return const InputDecorator(
        decoration: InputDecoration(labelText: 'Jellyfin user'),
        child: Row(
          children: [
            SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 12),
            Flexible(child: Text('Loading Jellyfin users…', overflow: TextOverflow.ellipsis)),
          ],
        ),
      );
    }

    final current = jellyfinOptionFor(selected, options);
    // The dropdown value must be one of its items.
    final value = selected == null ? null : (current?.jellyfinUserId ?? selected);
    final items = <DropdownMenuItem<String?>>[
      const DropdownMenuItem<String?>(value: null, child: Text('None')),
      if (selected != null && current == null)
        DropdownMenuItem<String?>(value: selected, child: Text('Unknown Jellyfin user ($selected)')),
      for (final o in options)
        () {
          final takenBy = o.linkedHubUserId != null && o.linkedHubUserId != userId ? o.linkedHubUserId : null;
          final suffix = [
            if (o.isAdministrator) 'Jellyfin admin',
            if (takenBy != null) 'linked to ${hubUsers[takenBy] ?? 'another user'}',
          ].join(' · ');
          return DropdownMenuItem<String?>(
            value: o.jellyfinUserId,
            enabled: takenBy == null,
            child: Text(suffix.isEmpty ? o.name : '${o.name} ($suffix)', overflow: TextOverflow.ellipsis),
          );
        }(),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String?>(
          key: ValueKey('jellyfin-${options.length}-$value'),
          initialValue: value,
          isExpanded: true,
          items: items,
          onChanged: enabled ? onChanged : null,
          decoration: InputDecoration(
            labelText: 'Jellyfin user',
            helperText: 'Their Seerr account is used for requests',
            errorText: error,
          ),
        ),
        if (current != null) ...[
          const SizedBox(height: 8),
          _SeerrStatus(option: current, importing: importing, onImport: enabled ? () => onImport(current) : null),
        ],
      ],
    );
  }
}

class _SeerrStatus extends StatelessWidget {
  const _SeerrStatus({required this.option, required this.importing, required this.onImport});

  final JellyfinUserOption option;
  final bool importing;
  final VoidCallback? onImport;

  @override
  Widget build(BuildContext context) {
    final colors = StatusColors.of(context);
    if (option.seerrUserId != null) {
      return ListTile(
        key: const Key('seerr-account'),
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.check_circle_outline, color: colors.ok),
        title: Text('Seerr account: ${option.seerrDisplayName ?? 'user ${option.seerrUserId}'}'),
        subtitle: const Text('Can request movies and series'),
      );
    }
    return Column(
      key: const Key('seerr-missing'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.warning_amber_rounded, color: colors.warning),
          title: const Text('No Seerr account'),
          subtitle: const Text('Cannot request until imported into Seerr'),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: importing
              ? const Padding(
                  padding: EdgeInsets.all(8),
                  child: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : FilledButton.tonalIcon(
                  key: const Key('seerr-import'),
                  onPressed: onImport,
                  icon: const Icon(Icons.person_add_alt),
                  label: const Text('Import into Seerr'),
                ),
        ),
      ],
    );
  }
}
