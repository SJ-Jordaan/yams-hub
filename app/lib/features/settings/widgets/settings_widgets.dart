/// Small widgets shared by the settings screens.
library;

import 'package:flutter/material.dart';
import 'package:yams_hub/core/servers/network_kind.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

/// The caption above a group of settings tiles.
class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(title, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
    );
  }
}

/// A short explanatory text below a group of tiles.
class SettingsHint extends StatelessWidget {
  const SettingsHint(this.text, {super.key, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
          ],
          Expanded(child: Text(text, style: style)),
        ],
      ),
    );
  }
}

/// "Admin" / "Member" chip.
class RoleChip extends StatelessWidget {
  const RoleChip(this.role, {super.key, this.dense = true});

  final Role role;
  final bool dense;

  @override
  Widget build(BuildContext context) => StatusChip(
    label: switch (role) {
      Role.admin => 'Admin',
      Role.member => 'Member',
      Role.unknown => 'Unknown role',
    },
    tone: role.isAdmin ? StatusTone.info : StatusTone.neutral,
    dense: dense,
  );
}

/// "LAN" / "Tailscale" / "Internet" chip for a hub URL.
class NetworkChip extends StatelessWidget {
  const NetworkChip(this.url, {super.key});

  final Uri url;

  @override
  Widget build(BuildContext context) {
    final kind = networkKindOf(url);
    return StatusChip(
      label: kind.label,
      dense: true,
      tone: switch (kind) {
        NetworkKind.lan => StatusTone.ok,
        NetworkKind.tailscale => StatusTone.info,
        NetworkKind.internet => StatusTone.warning,
      },
    );
  }
}

/// A round avatar with the first letter of [name].
class InitialAvatar extends StatelessWidget {
  const InitialAvatar(this.name, {super.key, this.radius = 20});

  final String name;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final trimmed = name.trim();
    return CircleAvatar(
      radius: radius,
      backgroundColor: scheme.primaryContainer,
      foregroundColor: scheme.onPrimaryContainer,
      child: Text(trimmed.isEmpty ? '?' : trimmed.characters.first.toUpperCase()),
    );
  }
}

/// The plain-HTTP warning of ARCHITECTURE §7.5, shown under a URL whose host
/// is on the internet.
class PlainHttpWarning extends StatelessWidget {
  const PlainHttpWarning({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = StatusColors.of(context);
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.warning_amber_rounded, size: 18, color: colors.warning),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'This address is on the internet. Passwords and tokens would travel unencrypted.',
            style: theme.textTheme.bodySmall?.copyWith(color: colors.warning),
          ),
        ),
      ],
    );
  }
}

/// Minimum length of hub passwords (API.md §2.2).
const minPasswordLength = 10;

/// A rough password strength, for the hint under password fields.
enum PasswordStrength {
  tooShort('Too short', StatusTone.error, 0.15),
  weak('Weak', StatusTone.error, 0.35),
  fair('Fair', StatusTone.warning, 0.65),
  strong('Strong', StatusTone.ok, 1);

  const PasswordStrength(this.label, this.tone, this.fraction);

  final String label;
  final StatusTone tone;
  final double fraction;

  /// Length and character variety; long passphrases count as strong.
  static PasswordStrength of(String password) {
    if (password.length < minPasswordLength) return tooShort;
    var classes = 0;
    if (RegExp('[a-z]').hasMatch(password)) classes++;
    if (RegExp('[A-Z]').hasMatch(password)) classes++;
    if (RegExp('[0-9]').hasMatch(password)) classes++;
    if (RegExp('[^A-Za-z0-9]').hasMatch(password)) classes++;
    final unique = password.split('').toSet().length;
    if (unique < 5) return weak;
    if (password.length >= 16 || (password.length >= 12 && classes >= 3)) return strong;
    return classes >= 2 ? fair : weak;
  }
}

/// A thin bar plus label under a new-password field.
class PasswordStrengthHint extends StatelessWidget {
  const PasswordStrengthHint({super.key, required this.password});

  final String password;

  @override
  Widget build(BuildContext context) {
    if (password.isEmpty) {
      return const SettingsHint('At least $minPasswordLength characters. A long passphrase is best.');
    }
    final strength = PasswordStrength.of(password);
    final color = StatusColors.of(context).forTone(strength.tone);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
      child: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: strength.fraction,
                minHeight: 4,
                color: color,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            strength == PasswordStrength.tooShort
                ? 'Too short (${password.length}/$minPasswordLength)'
                : strength.label,
            key: const Key('password-strength'),
            style: theme.textTheme.labelMedium?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

/// A password field with a show/hide toggle.
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.controller,
    required this.label,
    this.errorText,
    this.onChanged,
    this.textInputAction,
    this.onSubmitted,
    this.autofillHints,
    this.enabled = true,
  });

  final TextEditingController controller;
  final String label;
  final String? errorText;
  final ValueChanged<String>? onChanged;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final Iterable<String>? autofillHints;
  final bool enabled;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      obscureText: _obscure,
      enabled: widget.enabled,
      autocorrect: false,
      enableSuggestions: false,
      autofillHints: widget.autofillHints,
      textInputAction: widget.textInputAction,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      decoration: InputDecoration(
        labelText: widget.label,
        errorText: widget.errorText,
        suffixIcon: IconButton(
          tooltip: _obscure ? 'Show password' : 'Hide password',
          icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
          onPressed: () => setState(() => _obscure = !_obscure),
        ),
      ),
    );
  }
}

/// A filled button that shows a spinner while [busy].
class BusyButton extends StatelessWidget {
  const BusyButton({super.key, required this.label, required this.onPressed, this.busy = false, this.icon});

  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final child = busy
        ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
        : Text(label);
    if (icon != null && !busy) {
      return FilledButton.icon(onPressed: onPressed, icon: Icon(icon), label: child);
    }
    return FilledButton(onPressed: busy ? null : onPressed, child: child);
  }
}

/// Icon for the platform a session was created from.
IconData platformIcon(ClientPlatform platform) => switch (platform) {
  ClientPlatform.android => Icons.android,
  ClientPlatform.ios => Icons.phone_iphone,
  ClientPlatform.web => Icons.language,
  ClientPlatform.other || ClientPlatform.unknown => Icons.devices_other,
};

/// Label of a session platform.
String platformLabelOf(ClientPlatform platform) => switch (platform) {
  ClientPlatform.android => 'Android',
  ClientPlatform.ios => 'iOS',
  ClientPlatform.web => 'Web',
  ClientPlatform.other => 'Other',
  ClientPlatform.unknown => 'Unknown',
};

/// Awaits a provider refresh for a [RefreshIndicator]; failures are shown by
/// the screen itself (stale banner or error view), not thrown here.
Future<void> awaitRefresh(Future<Object?> refresh) async {
  try {
    await refresh;
  } catch (_) {
    // Rendered by the screen's AsyncValueView.
  }
}

/// A few skeleton rows for a section inside a scrolling list (where the
/// scrolling `SkeletonList` cannot be nested).
class SkeletonRows extends StatelessWidget {
  const SkeletonRows({super.key, this.count = 3});

  final int count;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Column(
      children: [
        for (var i = 0; i < count; i++)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                SkeletonBox(width: 24, height: 24, radius: 12),
                SizedBox(width: 16),
                Expanded(child: SkeletonBox(height: 14)),
              ],
            ),
          ),
      ],
    ),
  );
}
