/// `/settings/account`: who is signed in, change password
/// (`POST /auth/password`), sign out (APP.md §13).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_client.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/settings_api.dart';
import '../widgets/settings_widgets.dart';
import 'settings_screen.dart' show SignOutTile;

class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).user;
    final me = ref.watch(meProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: RefreshIndicator(
        onRefresh: () => awaitRefresh(ref.refresh(meProvider.future)),
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            ListTile(
              contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              leading: InitialAvatar(user?.displayName ?? '?', radius: 24),
              title: Text(user?.displayName ?? 'Signed in', style: theme.textTheme.titleMedium),
              subtitle: user == null ? null : Text('@${user.username}'),
              trailing: user == null ? null : RoleChip(user.role, dense: false),
            ),
            _SeerrLinkTile(me: me),
            const SettingsSectionHeader('Change password'),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: ChangePasswordForm()),
            const SettingsSectionHeader('Session'),
            const SignOutTile(),
          ],
        ),
      ),
    );
  }
}

class _SeerrLinkTile extends StatelessWidget {
  const _SeerrLinkTile({required this.me});

  final AsyncValue<MeResponse> me;

  @override
  Widget build(BuildContext context) {
    final seerr = me.value?.seerr;
    if (seerr == null) return const SizedBox.shrink();
    final quota = seerr.quota;
    String quotaText(String label, QuotaInfo q) =>
        q.limit == null ? '$label: unlimited' : '$label: ${q.remaining ?? 0} of ${q.limit} left (${q.days ?? 7} days)';
    return ListTile(
      leading: const Icon(Icons.playlist_add),
      title: Text(seerr.linked ? 'Requests as ${seerr.displayName ?? 'Seerr user ${seerr.seerrUserId}'}' : 'No Seerr account'),
      subtitle: Text(
        seerr.linked
            ? [
                if (seerr.canAutoApprove) 'Requests are approved automatically',
                if (quota != null) ...[quotaText('Movies', quota.movie), quotaText('Series', quota.tv)],
              ].join(' · ').ifEmpty('Linked to Seerr')
            : 'Ask an admin to link your Jellyfin user and import it into Seerr.',
      ),
    );
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

/// Current, new and confirm fields with a strength hint. On success the
/// gateway revokes the user's other sessions.
class ChangePasswordForm extends ConsumerStatefulWidget {
  const ChangePasswordForm({super.key});

  @override
  ConsumerState<ChangePasswordForm> createState() => _ChangePasswordFormState();
}

class _ChangePasswordFormState extends ConsumerState<ChangePasswordForm> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _currentError;
  String? _nextError;
  String? _confirmError;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  bool _validate() {
    setState(() {
      _currentError = _current.text.isEmpty ? 'Enter your current password' : null;
      _nextError = _next.text.length < minPasswordLength ? 'At least $minPasswordLength characters' : null;
      if (_nextError == null && _next.text == _current.text) _nextError = 'Choose a different password';
      _confirmError = _confirm.text != _next.text ? "Passwords don't match" : null;
    });
    return _currentError == null && _nextError == null && _confirmError == null;
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!_validate()) return;
    setState(() => _busy = true);
    try {
      await ref.read(settingsApiProvider).changePassword(currentPassword: _current.text, newPassword: _next.text);
      if (!mounted) return;
      _current.clear();
      _next.clear();
      _confirm.clear();
      context.showSnack('Password changed. Your other devices were signed out.');
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == ApiErrorCode.invalidCredentials) {
        setState(() => _currentError = 'Current password is wrong');
      } else {
        final current = e.messageFor('currentPassword');
        final next = e.messageFor('newPassword');
        if (current != null || next != null) {
          setState(() {
            _currentError = current;
            _nextError = next;
          });
        } else {
          context.showError(e);
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PasswordField(
            key: const Key('password-current'),
            controller: _current,
            label: 'Current password',
            errorText: _currentError,
            enabled: !_busy,
            autofillHints: const [AutofillHints.password],
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),
          PasswordField(
            key: const Key('password-new'),
            controller: _next,
            label: 'New password',
            errorText: _nextError,
            enabled: !_busy,
            autofillHints: const [AutofillHints.newPassword],
            textInputAction: TextInputAction.next,
            onChanged: (_) => setState(() {}),
          ),
          PasswordStrengthHint(password: _next.text),
          const SizedBox(height: 12),
          PasswordField(
            key: const Key('password-confirm'),
            controller: _confirm,
            label: 'Confirm new password',
            errorText: _confirmError,
            enabled: !_busy,
            autofillHints: const [AutofillHints.newPassword],
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 8),
          const SettingsHint('Changing your password signs out your other devices.'),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: BusyButton(label: 'Change password', busy: _busy, onPressed: _submit),
          ),
        ],
      ),
    );
  }
}
