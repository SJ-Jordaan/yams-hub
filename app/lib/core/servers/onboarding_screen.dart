/// `/onboarding`: first server setup (APP.md §3.1).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_models/yams_models.dart';

import '../api/api_exception.dart';
import '../app_info.dart';
import '../platform/platform.dart';
import '../routing/paths.dart';
import '../theme/theme.dart';
import 'network_kind.dart';
import 'server_connection.dart';
import 'server_profile.dart';
import 'server_resolver.dart';
import 'server_store.dart';

/// Example hub address shown as a hint.
const lanUrlHint = 'http://<server-ip>:8090';

/// Example Tailscale address shown as a hint.
const tailscaleUrlHint = 'http://<server>.<tailnet>.ts.net:8090';

/// Profile name used when none is entered.
const defaultServerName = 'YAMS';

/// The address prefilled for a new server. On web it is the page's own
/// origin (the gateway serves the web app); on Android and iOS it is empty.
String defaultServerUrl({bool? web, Uri? base}) {
  if (!(web ?? isWeb)) return '';
  final b = base ?? Uri.base;
  if ((b.scheme != 'http' && b.scheme != 'https') || b.host.isEmpty) return '';
  return Uri(scheme: b.scheme, host: b.host, port: b.hasPort ? b.port : null).toString();
}

/// Result of testing one URL.
@immutable
class UrlProbe {
  const UrlProbe.ok(ServerPing this.ping, this.latency) : error = null;

  const UrlProbe.failed(String this.error) : ping = null, latency = null;

  final ServerPing? ping;
  final Duration? latency;
  final String? error;

  bool get ok => ping != null;
}

/// Pings [url] and checks it is a compatible YAMS Hub.
Future<UrlProbe> probeServerUrl(ServerPingClient client, Uri url) async {
  final watch = Stopwatch()..start();
  try {
    final ping = await client.ping(url, timeout: const Duration(seconds: 4));
    watch.stop();
    if (ping.name != 'yams-hub') return const UrlProbe.failed('Not a YAMS Hub.');
    final incompatible = incompatibilityReason(apiVersion: ping.apiVersion, minAppVersion: ping.minAppVersion);
    if (incompatible != null) return UrlProbe.failed(incompatible);
    return UrlProbe.ok(ping, watch.elapsed);
  } on ApiException catch (e) {
    return UrlProbe.failed(e.message);
  }
}

/// Checks the probes of the entered URLs (APP.md §3.1): at least one answers,
/// and all answering URLs belong to the same hub. Returns the error, or null.
String? validateProbes(Map<Uri, UrlProbe> probes) {
  final answering = probes.values.where((p) => p.ok).toList();
  if (answering.isEmpty) {
    final reasons = {for (final p in probes.values) ?p.error};
    return reasons.length == 1 ? reasons.first : 'No URL answered as a YAMS Hub.';
  }
  final ids = {for (final p in answering) p.ping!.instanceId};
  if (ids.length > 1) return 'The URLs belong to different hubs.';
  return null;
}

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _name = TextEditingController(text: defaultServerName);
  final _lan = TextEditingController(text: defaultServerUrl());
  final _tailscale = TextEditingController();
  Map<Uri, UrlProbe> _probes = {};
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final existing = ref.read(serverStoreProvider).active;
    if (existing != null) {
      _name.text = existing.name;
      final lan = existing.urls.where((u) => !isTailscaleHost(u.host)).firstOrNull;
      final ts = existing.urls.where((u) => isTailscaleHost(u.host)).firstOrNull;
      _lan.text = lan?.toString() ?? '';
      _tailscale.text = ts?.toString() ?? '';
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _lan.dispose();
    _tailscale.dispose();
    super.dispose();
  }

  List<Uri> get _urls => [
    for (final c in [_lan, _tailscale]) ?parseServerUrl(c.text),
  ];

  Future<Map<Uri, UrlProbe>> _testAll() async {
    final client = ref.read(serverPingClientProvider);
    final urls = _urls;
    final results = await Future.wait(urls.map((u) => probeServerUrl(client, u)));
    return {for (var i = 0; i < urls.length; i++) urls[i]: results[i]};
  }

  Future<void> _test() async {
    if (_urls.isEmpty) {
      setState(() => _error = 'Enter at least one URL.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final probes = await _testAll();
    if (!mounted) return;
    setState(() {
      _probes = probes;
      _busy = false;
      _error = validateProbes(probes);
    });
  }

  Future<void> _continue() async {
    final urls = _urls;
    if (urls.isEmpty) {
      setState(() => _error = 'Enter at least one URL.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final probes = await _testAll();
    if (!mounted) return;
    final error = validateProbes(probes);
    if (error != null) {
      setState(() {
        _probes = probes;
        _busy = false;
        _error = error;
      });
      return;
    }
    final winner = probes.entries.firstWhere((e) => e.value.ok);
    final instanceId = winner.value.ping!.instanceId;
    final store = ref.read(serverStoreProvider.notifier);
    final existing = ref.read(serverStoreProvider).profiles.where((p) => p.instanceId == instanceId).firstOrNull;
    final name = _name.text.trim().isEmpty ? defaultServerName : _name.text.trim();
    store.upsert(
      ServerProfile(
        id: existing?.id ?? ServerStore.newId(),
        name: name,
        urls: urls,
        lastGoodUrl: winner.key,
        instanceId: instanceId,
      ),
      activate: true,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    context.go(AppPaths.login());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Connect to your hub')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Enter the addresses of your YAMS Hub. The app tries the last working one first and falls back '
                    'automatically.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 20),
                  TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
                  const SizedBox(height: 16),
                  _UrlField(
                    controller: _lan,
                    label: 'LAN URL',
                    hint: lanUrlHint,
                    probe: _probeFor(_lan),
                    onChanged: () => setState(() {}),
                  ),
                  const SizedBox(height: 16),
                  _UrlField(
                    controller: _tailscale,
                    label: 'Tailscale URL (optional)',
                    hint: tailscaleUrlHint,
                    probe: _probeFor(_tailscale),
                    onChanged: () => setState(() {}),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'On untrusted Wi-Fi the app uses the Tailscale URL.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      key: const Key('onboarding-error'),
                      style: theme.textTheme.bodyMedium?.copyWith(color: StatusColors.of(context).error),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      OutlinedButton(onPressed: _busy ? null : _test, child: const Text('Test')),
                      const Spacer(),
                      FilledButton(
                        onPressed: _busy ? null : _continue,
                        child: _busy
                            ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Text('Continue'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  UrlProbe? _probeFor(TextEditingController c) {
    final url = parseServerUrl(c.text);
    return url == null ? null : _probes[url];
  }
}

class _UrlField extends StatelessWidget {
  const _UrlField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.probe,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final UrlProbe? probe;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = StatusColors.of(context);
    final theme = Theme.of(context);
    final text = controller.text.trim();
    final url = parseServerUrl(text);
    final invalid = text.isNotEmpty && url == null;
    final warn = url != null && needsPlainHttpWarning(url);
    final p = probe;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          autocorrect: false,
          onChanged: (_) => onChanged(),
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            errorText: invalid ? 'Not a valid http(s) URL' : null,
            suffixIcon: p == null
                ? null
                : Icon(p.ok ? Icons.check_circle : Icons.error_outline, color: p.ok ? colors.ok : colors.error),
          ),
        ),
        if (p != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 12),
            child: Text(
              p.ok ? 'OK · ${p.ping!.name} ${p.ping!.version} · ${p.latency!.inMilliseconds} ms' : p.error!,
              style: theme.textTheme.bodySmall?.copyWith(color: p.ok ? colors.ok : colors.error),
            ),
          ),
        if (warn)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
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
            ),
          ),
      ],
    );
  }
}
