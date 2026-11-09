/// `/settings/servers/:id`: edit (or, with id `new`, add) a server profile:
/// name, ordered URL list with per-URL test and latency, sign out, delete
/// (APP.md §13, ARCHITECTURE §7.5).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/servers/network_kind.dart';
import 'package:yams_hub/core/servers/onboarding_screen.dart'
    show UrlProbe, defaultServerName, defaultServerUrl, lanUrlHint, probeServerUrl, tailscaleUrlHint;
import 'package:yams_hub/core/servers/server_connection.dart';
import 'package:yams_hub/core/servers/server_profile.dart';
import 'package:yams_hub/core/servers/server_store.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';

import '../widgets/settings_widgets.dart';
import 'servers_screen.dart';

/// Checks the probes of a profile's URLs before saving. Returns a blocking
/// error, or null when the profile may be saved; [unreachable] is true when
/// no URL answered (the caller may still save an existing profile).
({String? error, bool unreachable, String? instanceId}) checkProfileProbes({
  required Map<Uri, UrlProbe> probes,
  required ServerProfile? existing,
  required List<ServerProfile> others,
}) {
  final answering = [for (final p in probes.values) if (p.ok) p.ping!];
  if (answering.isEmpty) return (error: null, unreachable: true, instanceId: null);
  final ids = {for (final p in answering) p.instanceId};
  if (ids.length > 1) return (error: 'The addresses belong to different hubs.', unreachable: false, instanceId: null);
  final id = ids.single;
  final known = existing?.instanceId;
  if (known != null && known != id) {
    return (
      error: 'These addresses belong to a different hub than ${existing!.name}. Add it as a new server instead.',
      unreachable: false,
      instanceId: id,
    );
  }
  for (final o in others) {
    if (o.instanceId == id) {
      return (error: 'This hub is already set up as ${o.name}.', unreachable: false, instanceId: id);
    }
  }
  return (error: null, unreachable: false, instanceId: id);
}

class ServerEditorScreen extends ConsumerStatefulWidget {
  const ServerEditorScreen({super.key, required this.profileId});

  /// The profile to edit, or [newServerId].
  final String profileId;

  @override
  ConsumerState<ServerEditorScreen> createState() => _ServerEditorScreenState();
}

class _UrlRow {
  _UrlRow(this.id, String text) : controller = TextEditingController(text: text);

  final int id;
  final TextEditingController controller;
  UrlProbe? probe;
  bool testing = false;

  Uri? get url => parseServerUrl(controller.text);
  bool get invalid => controller.text.trim().isNotEmpty && url == null;
}

class _ServerEditorScreenState extends ConsumerState<ServerEditorScreen> {
  final _name = TextEditingController();
  final List<_UrlRow> _rows = [];
  int _nextRowId = 0;
  ServerProfile? _existing;
  bool _activate = true;
  bool _saving = false;
  String? _error;

  bool get _isNew => _existing == null;

  @override
  void initState() {
    super.initState();
    _existing = widget.profileId == newServerId ? null : ref.read(serverStoreProvider).byId(widget.profileId);
    final p = _existing;
    _name.text = p?.name ?? defaultServerName;
    for (final u in p?.urls ?? const <Uri>[]) {
      _rows.add(_UrlRow(_nextRowId++, u.toString()));
    }
    if (_rows.isEmpty) _rows.add(_UrlRow(_nextRowId++, p == null ? defaultServerUrl() : ''));
  }

  @override
  void dispose() {
    _name.dispose();
    for (final r in _rows) {
      r.controller.dispose();
    }
    super.dispose();
  }

  void _addRow() => setState(() => _rows.add(_UrlRow(_nextRowId++, '')));

  void _removeRow(_UrlRow row) {
    setState(() => _rows.remove(row));
    // Disposed after the row's field has left the tree.
    WidgetsBinding.instance.addPostFrameCallback((_) => row.controller.dispose());
  }

  Future<void> _test(_UrlRow row) async {
    final url = row.url;
    if (url == null) return;
    setState(() => row.testing = true);
    final probe = await probeServerUrl(ref.read(serverPingClientProvider), url);
    if (!mounted) return;
    setState(() {
      row.testing = false;
      row.probe = probe;
    });
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    if (_rows.any((r) => r.invalid)) {
      setState(() => _error = 'Fix the invalid address first.');
      return;
    }
    final urls = <Uri>[];
    for (final r in _rows) {
      final u = r.url;
      if (u != null && !urls.contains(u)) urls.add(u);
    }
    if (urls.isEmpty) {
      setState(() => _error = 'Enter at least one URL.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });

    final client = ref.read(serverPingClientProvider);
    final results = await Future.wait(urls.map((u) => probeServerUrl(client, u)));
    if (!mounted) return;
    final probes = {for (var i = 0; i < urls.length; i++) urls[i]: results[i]};
    for (final r in _rows) {
      final u = r.url;
      if (u != null) r.probe = probes[u];
    }
    final store = ref.read(serverStoreProvider);
    final check = checkProfileProbes(
      probes: probes,
      existing: _existing,
      others: [for (final p in store.profiles) if (p.id != _existing?.id) p],
    );
    if (check.error != null) {
      setState(() {
        _saving = false;
        _error = check.error;
      });
      return;
    }
    if (check.unreachable) {
      final reasons = {for (final p in probes.values) ?p.error};
      final reason = reasons.length == 1 ? reasons.first : 'No address answered as a YAMS Hub.';
      if (_isNew) {
        setState(() {
          _saving = false;
          _error = reason;
        });
        return;
      }
      final saveAnyway = await ConfirmDialog.show(
        context,
        title: 'Save anyway?',
        message: '$reason The hub may be offline right now; the app keeps trying the addresses.',
        confirmLabel: 'Save',
      );
      if (!mounted) return;
      if (!saveAnyway) {
        setState(() => _saving = false);
        return;
      }
    }

    final existing = _existing;
    final winner = probes.entries.where((e) => e.value.ok).firstOrNull?.key;
    final lastGood = existing?.lastGoodUrl != null && urls.contains(existing!.lastGoodUrl) ? existing.lastGoodUrl : winner;
    final name = _name.text.trim().isEmpty ? defaultServerName : _name.text.trim();
    final profile = ServerProfile(
      id: existing?.id ?? ServerStore.newId(),
      name: name,
      urls: urls,
      lastGoodUrl: lastGood,
      instanceId: existing?.instanceId ?? check.instanceId,
    );
    ref.read(serverStoreProvider.notifier).upsert(profile, activate: _isNew && _activate);
    setState(() => _saving = false);
    context.showSnack(_isNew ? 'Added $name' : 'Saved $name');
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppPaths.settingsServers());
    }
  }

  Future<void> _signOut() async {
    final p = _existing;
    if (p == null) return;
    final isActive = ref.read(serverStoreProvider).active?.id == p.id;
    final ok = await ConfirmDialog.show(
      context,
      title: 'Sign out of ${p.name}?',
      message: isActive
          ? 'You will need your password to sign in again.'
          : 'This device forgets its session on ${p.name}. To end it on the hub too, revoke it in Sessions.',
      confirmLabel: 'Sign out',
    );
    if (!ok || !mounted) return;
    await signOutOfProfile(ref, p, isActive: isActive);
    if (mounted && !isActive) context.showSnack('Signed out of ${p.name}');
  }

  Future<void> _delete() async {
    final p = _existing;
    if (p == null) return;
    final removed = await deleteServerProfile(context, ref, p);
    if (!removed || !mounted) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppPaths.settingsServers());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.profileId != newServerId && _existing == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Server')),
        body: EmptyView(
          icon: Icons.dns_outlined,
          title: 'Server not found',
          message: 'It may have been deleted.',
          action: FilledButton.tonal(
            onPressed: () => context.go(AppPaths.settingsServers()),
            child: const Text('All servers'),
          ),
        ),
      );
    }
    final theme = Theme.of(context);
    final existing = _existing;
    final isActive = existing != null && ref.watch(serverStoreProvider).active?.id == existing.id;
    final signedInHere = isActive && ref.watch(authControllerProvider).signedIn;
    final canSignOut = existing != null && (signedInHere || (!isActive && existing.instanceId != null));

    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'Add server' : 'Edit server'),
        actions: [
          if (!_isNew)
            IconButton(tooltip: 'Delete server', icon: const Icon(Icons.delete_outline), onPressed: _saving ? null : _delete),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 20),
            Text('Addresses', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Tried in this order (the last working one goes first). Drag to reorder.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: _rows.length,
              onReorderItem: (oldIndex, newIndex) => setState(() {
                _rows.insert(newIndex, _rows.removeAt(oldIndex));
              }),
              itemBuilder: (context, i) {
                final row = _rows[i];
                return _UrlRowEditor(
                  key: ValueKey(row.id),
                  index: i,
                  row: row,
                  canRemove: _rows.length > 1,
                  onChanged: () => setState(() => row.probe = null),
                  onTest: () => _test(row),
                  onRemove: () => _removeRow(row),
                );
              },
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(onPressed: _addRow, icon: const Icon(Icons.add), label: const Text('Add address')),
            ),
            if (_isNew)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _activate,
                onChanged: (v) => setState(() => _activate = v ?? true),
                title: const Text('Switch to this server'),
                controlAffinity: ListTileControlAffinity.leading,
              ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                key: const Key('server-editor-error'),
                style: theme.textTheme.bodyMedium?.copyWith(color: StatusColors.of(context).error),
              ),
            ],
            const SizedBox(height: 16),
            BusyButton(label: _isNew ? 'Add server' : 'Save', busy: _saving, onPressed: _save),
            if (canSignOut) ...[
              const SizedBox(height: 24),
              const Divider(),
              ListTile(
                key: const Key('server-sign-out'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.logout),
                title: const Text('Sign out of this server'),
                subtitle: Text(isActive ? 'Ends this device\'s session on the hub' : 'Forgets this device\'s session'),
                onTap: _signOut,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _UrlRowEditor extends StatelessWidget {
  const _UrlRowEditor({
    super.key,
    required this.index,
    required this.row,
    required this.canRemove,
    required this.onChanged,
    required this.onTest,
    required this.onRemove,
  });

  final int index;
  final _UrlRow row;
  final bool canRemove;
  final VoidCallback onChanged;
  final VoidCallback onTest;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = StatusColors.of(context);
    final theme = Theme.of(context);
    final url = row.url;
    final probe = row.probe;
    final kind = url == null ? null : networkKindOf(url);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ReorderableDragStartListener(
            index: index,
            child: const Padding(
              padding: EdgeInsets.only(top: 14, right: 4),
              child: Icon(Icons.drag_indicator, semanticLabel: 'Reorder'),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: Key('server-url-$index'),
                  controller: row.controller,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  onChanged: (_) => onChanged(),
                  decoration: InputDecoration(
                    labelText: kind == null ? 'Address ${index + 1}' : '${kind.label} address',
                    hintText: index == 0 ? lanUrlHint : tailscaleUrlHint,
                    errorText: row.invalid ? 'Not a valid http(s) URL' : null,
                    suffixIcon: probe == null
                        ? null
                        : Icon(
                            probe.ok ? Icons.check_circle : Icons.error_outline,
                            color: probe.ok ? colors.ok : colors.error,
                          ),
                  ),
                ),
                if (probe != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, left: 12),
                    child: Text(
                      probe.ok
                          ? 'OK · ${probe.ping!.name} ${probe.ping!.version} · ${probe.latency!.inMilliseconds} ms'
                          : probe.error!,
                      style: theme.textTheme.bodySmall?.copyWith(color: probe.ok ? colors.ok : colors.error),
                    ),
                  ),
                if (url != null && needsPlainHttpWarning(url))
                  const Padding(padding: EdgeInsets.only(top: 6), child: PlainHttpWarning()),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: row.testing
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : TextButton(onPressed: url == null ? null : onTest, child: const Text('Test')),
          ),
          if (canRemove)
            IconButton(
              padding: const EdgeInsets.only(top: 4),
              tooltip: 'Remove address',
              icon: const Icon(Icons.close),
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }
}
