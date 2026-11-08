/// `/login` (APP.md §3.2).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_models/yams_models.dart';

import '../api/api_exception.dart';
import '../app_info.dart';
import '../routing/paths.dart';
import '../servers/hosting.dart';
import '../servers/server_connection.dart';
import '../theme/theme.dart';
import 'auth_controller.dart';
import 'device_name.dart';

/// The inline message for a failed sign-in.
String loginErrorMessage(Object error) {
  final e = ApiException.from(error);
  if (e.code == ApiErrorCode.invalidCredentials) return 'Wrong username or password';
  if (e.code == ApiErrorCode.rateLimited) {
    final seconds = e.retryAfterSeconds;
    if (seconds == null || seconds <= 0) return 'Too many attempts. Try again later.';
    final minutes = (seconds / 60).ceil();
    return seconds < 60
        ? 'Too many attempts. Try again in $seconds s'
        : 'Too many attempts. Try again in $minutes min';
  }
  if (e.isNetwork) return "Can't reach the hub";
  if (e.code == ApiErrorCode.forbidden) return e.message.isEmpty ? 'Account disabled' : e.message;
  return e.message;
}

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, this.from});

  /// Where to go after signing in (handled by the router's redirect).
  final String? from;

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;
  bool _networkError = false;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
      _networkError = false;
    });
    try {
      final deviceName = await ref.read(deviceNameProvider.future);
      await ref
          .read(authControllerProvider.notifier)
          .login(username: _username.text, password: _password.text, deviceName: deviceName);
      // The router redirects away from /login once signed in.
    } catch (e) {
      if (!mounted) return;
      final api = ApiException.from(e);
      setState(() {
        _error = loginErrorMessage(e);
        _networkError = api.isNetwork;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connection = ref.watch(activeServerProvider);
    final profilesEditable = ref.watch(hostingModeProvider).hasServerProfiles;
    final profile = connection.profile;
    final url = connection.baseUrl ?? profile?.lastGoodUrl ?? profile?.urls.firstOrNull;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(Icons.hub_outlined, size: 56, color: theme.colorScheme.primary),
                      const SizedBox(height: 12),
                      Text(appTitle, textAlign: TextAlign.center, style: theme.textTheme.headlineMedium),
                      const SizedBox(height: 24),
                      if (profile != null)
                        _ServerLine(
                          name: profile.name,
                          url: url,
                          status: connection.status,
                          onChange: profilesEditable ? () => context.go(AppPaths.onboarding()) : null,
                          onRetry: () => ref.read(activeServerProvider.notifier).resolve(),
                        ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _username,
                        decoration: const InputDecoration(labelText: 'Username', prefixIcon: Icon(Icons.person_outline)),
                        autofillHints: const [AutofillHints.username],
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.next,
                        validator: (v) => (v ?? '').trim().isEmpty ? 'Enter your username' : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _password,
                        obscureText: _obscure,
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            tooltip: _obscure ? 'Show password' : 'Hide password',
                            icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                        ),
                        autofillHints: const [AutofillHints.password],
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _submit(),
                        validator: (v) => (v ?? '').isEmpty ? 'Enter your password' : null,
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          key: const Key('login-error'),
                          style: theme.textTheme.bodyMedium?.copyWith(color: StatusColors.of(context).error),
                        ),
                        if (_networkError && profilesEditable)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: () => context.go(AppPaths.onboarding()),
                              child: const Text('Choose another server'),
                            ),
                          ),
                      ],
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: _busy ? null : _submit,
                        child: _busy
                            ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Text('Sign in'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ServerLine extends StatelessWidget {
  const _ServerLine({
    required this.name,
    required this.url,
    required this.status,
    required this.onChange,
    required this.onRetry,
  });

  final String name;
  final Uri? url;
  final ConnectionStatus status;
  final VoidCallback? onChange;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final (IconData icon, Color color, String text) = switch (status) {
      ConnectionStatus.connected => (Icons.check_circle_outline, colors.ok, url?.toString() ?? ''),
      ConnectionStatus.resolving => (Icons.sync, colors.neutral, 'Connecting…'),
      ConnectionStatus.unreachable => (Icons.wifi_off, colors.error, "Can't reach the hub"),
      ConnectionStatus.noProfile => (Icons.help_outline, colors.neutral, 'No server'),
    };
    return Card(
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(name),
        subtitle: Text(text, style: theme.textTheme.bodySmall),
        trailing: Wrap(
          children: [
            if (status == ConnectionStatus.unreachable)
              IconButton(tooltip: 'Retry', icon: const Icon(Icons.refresh), onPressed: onRetry),
            if (onChange != null) TextButton(onPressed: onChange, child: const Text('Change server')),
          ],
        ),
      ),
    );
  }
}
