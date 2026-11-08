/// The request sheet (APP.md §4.3): season picker for series, the admin-only
/// "Advanced" options (server, quality profile, root folder) and the quota
/// line. Pops with the [CreateRequest] to send.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/servers/server_config_provider.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../providers/requests_providers.dart';
import 'request_ui.dart';

/// Opens the sheet for [title]; null when dismissed.
Future<CreateRequest?> showRequestSheet(BuildContext context, TitleDetail title) => showModalBottomSheet<CreateRequest>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => RequestSheet(title: title),
);

class RequestSheet extends ConsumerStatefulWidget {
  const RequestSheet({super.key, required this.title});

  final TitleDetail title;

  @override
  ConsumerState<RequestSheet> createState() => _RequestSheetState();
}

class _RequestSheetState extends ConsumerState<RequestSheet> {
  late final Set<int> _selected = {...widget.title.request.requestableSeasons};
  int? _serverId;
  int? _profileId;
  String? _rootFolder;

  TitleDetail get t => widget.title;

  bool get _partialAllowed =>
      ref.watch(serverConfigProvider.select((c) => c.value?.seerr.partialRequestsEnabled)) ?? true;

  List<TvSeason> get _requestable => [
    for (final s in t.seasons)
      if (s.requestable) s,
  ];

  CreateRequestAdvanced? get _advanced {
    final a = CreateRequestAdvanced(serverId: _serverId, profileId: _profileId, rootFolder: _rootFolder);
    return a.isEmpty ? null : a;
  }

  void _submit() {
    final advanced = _advanced;
    if (!t.isTv) {
      Navigator.of(context).pop(CreateRequest(mediaType: MediaType.movie, tmdbId: t.tmdbId, advanced: advanced));
      return;
    }
    final all = !_partialAllowed || _selected.length == _requestable.length && t.media == null;
    Navigator.of(context).pop(
      CreateRequest(
        mediaType: MediaType.tv,
        tmdbId: t.tmdbId,
        allSeasons: all,
        seasons: all ? null : (_selected.toList()..sort()),
        advanced: advanced,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAdmin = ref.watch(isAdminProvider);
    final quota = quotaFor(ref.watch(seerrInfoProvider), t.type);
    final line = isAdmin ? null : quotaLine(quota, t.type);
    final blocked = !isAdmin && quotaBlocks(quota);
    final partial = _partialAllowed;
    final count = partial ? _selected.length : _requestable.length;
    final canSubmit = !blocked && (!t.isTv || count > 0);
    final label = !t.isTv
        ? 'Request'
        : count == 0
        ? 'Pick seasons'
        : 'Request $count season${count == 1 ? '' : 's'}';

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: t.isTv ? 0.75 : 0.5,
      minChildSize: 0.35,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    t.isTv ? 'Request ${t.title}' : 'Request ${t.title}${t.year == null ? '' : ' (${t.year})'}',
                    style: theme.textTheme.titleLarge,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              controller: scroll,
              children: [
                if (t.isTv) ...[
                  if (!partial)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
                      child: Text('Seerr only allows requesting every missing season at once.'),
                    )
                  else if (_requestable.length > 1)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: TextButton.icon(
                          onPressed: () => setState(() {
                            final all = _requestable.map((s) => s.seasonNumber);
                            if (_selected.length == _requestable.length) {
                              _selected.clear();
                            } else {
                              _selected.addAll(all);
                            }
                          }),
                          icon: const Icon(Icons.done_all),
                          label: Text(
                            _selected.length == _requestable.length ? 'Clear selection' : 'Select all requestable',
                          ),
                        ),
                      ),
                    ),
                  for (final s in t.seasons)
                    _SeasonRow(
                      season: s,
                      selected: partial ? _selected.contains(s.seasonNumber) : s.requestable,
                      onChanged: !partial || !s.requestable
                          ? null
                          : (v) => setState(() => v ? _selected.add(s.seasonNumber) : _selected.remove(s.seasonNumber)),
                    ),
                ],
                if (isAdmin)
                  _AdvancedOptions(
                    type: t.type,
                    serverId: _serverId,
                    profileId: _profileId,
                    rootFolder: _rootFolder,
                    onChanged: (server, profile, folder) => setState(() {
                      _serverId = server;
                      _profileId = profile;
                      _rootFolder = folder;
                    }),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (line != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        line,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: blocked ? StatusColors.of(context).error : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  FilledButton.icon(
                    onPressed: canSubmit ? _submit : null,
                    icon: const Icon(Icons.add),
                    label: Text(blocked ? 'No requests left' : label),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SeasonRow extends StatelessWidget {
  const _SeasonRow({required this.season, required this.selected, required this.onChanged});

  final TvSeason season;
  final bool selected;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final s = season;
    final year = s.airDate == null || s.airDate!.length < 4 ? null : s.airDate!.substring(0, 4);
    final status = s.requestable
        ? null
        : s.requestStatus != null && s.availability == Availability.none
        ? StatusChip(
            label: requestStatusLabel(s.requestStatus!),
            tone: requestStatusTone(s.requestStatus!),
            dense: true,
          )
        : StatusChip(label: availabilityLabel(s.availability), tone: availabilityTone(s.availability), dense: true);
    return CheckboxListTile(
      value: selected || !s.requestable,
      onChanged: onChanged == null ? null : (v) => onChanged!(v ?? false),
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(s.name),
      subtitle: Text(['${s.episodeCount} episode${s.episodeCount == 1 ? '' : 's'}', ?year].join(' · ')),
      secondary: status,
    );
  }
}

/// Server, quality profile and root folder (admins, `GET /requests/options`).
class _AdvancedOptions extends ConsumerWidget {
  const _AdvancedOptions({
    required this.type,
    required this.serverId,
    required this.profileId,
    required this.rootFolder,
    required this.onChanged,
  });

  final MediaType type;
  final int? serverId;
  final int? profileId;
  final String? rootFolder;
  final void Function(int? serverId, int? profileId, String? rootFolder) onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ExpansionTile(
      leading: const Icon(Icons.tune),
      title: const Text('Advanced'),
      subtitle: Text(serverId == null && profileId == null && rootFolder == null ? 'Seerr defaults' : 'Custom options'),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        AsyncValueView(
          value: ref.watch(requestOptionsProvider),
          showStaleBanner: false,
          compactError: true,
          onRetry: () => ref.invalidate(requestOptionsProvider),
          loading: const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
          data: (context, options) {
            final servers = options.forMediaType(type);
            if (servers.isEmpty) return Text('No ${arrName(type)} server is set up in Seerr.');
            final server =
                servers.where((s) => s.serverId == serverId).firstOrNull ??
                servers.where((s) => s.isDefault).firstOrNull ??
                servers.first;
            final profile = profileId ?? server.defaultProfileId;
            final folder = rootFolder ?? server.defaultRootFolder;
            return Column(
              children: [
                if (servers.length > 1)
                  _Dropdown<int>(
                    label: 'Server',
                    value: server.serverId,
                    items: {for (final s in servers) s.serverId: s.name},
                    onChanged: (v) => onChanged(v, null, null),
                  ),
                _Dropdown<int>(
                  label: 'Quality profile',
                  value: server.profiles.any((p) => p.id == profile) ? profile : null,
                  items: {
                    for (final p in server.profiles)
                      p.id: p.id == server.defaultProfileId ? '${p.name} (default)' : p.name,
                  },
                  onChanged: (v) => onChanged(serverId, v == server.defaultProfileId ? null : v, rootFolder),
                ),
                _Dropdown<String>(
                  label: 'Root folder',
                  value: server.rootFolders.any((f) => f.path == folder) ? folder : null,
                  items: {
                    for (final f in server.rootFolders)
                      f.path: f.freeBytes == null ? f.path : '${f.path} · ${formatBytes(f.freeBytes)} free',
                  },
                  onChanged: (v) => onChanged(serverId, profileId, v == server.defaultRootFolder ? null : v),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({required this.label, required this.value, required this.items, required this.onChanged});

  final String label;
  final T? value;
  final Map<T, String> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: DropdownButtonFormField<T>(
      key: ValueKey('$label:$value:${items.length}'),
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
      items: [
        for (final e in items.entries)
          DropdownMenuItem(
            value: e.key,
            child: Text(e.value, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged,
    ),
  );
}
