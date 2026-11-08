/// Add torrent (APP.md §6.4): magnet/URL lines, `.torrent` files on web,
/// category, tags and "Start stopped" → `POST /torrents/add`.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_exception.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_models/yams_models.dart';

import '../data/activity_api.dart';
import '../platform/torrent_file_picker.dart';
import '../providers/activity_providers.dart';

/// Categories Sonarr/Radarr own: offered with a warning.
const _arrCategories = {'tv-sonarr', 'radarr'};

/// Maximum `.torrent` files and size (API.md §8.4).
const _maxFiles = 5;
const _maxFileBytes = 5 * 1024 * 1024;

final _magnet = RegExp(r'^magnet:\?.*xt=urn:bt(ih|mh):', caseSensitive: false);

/// Whether [line] is a magnet link or an http(s) URL.
bool isTorrentLinkLine(String line) {
  final t = line.trim();
  if (_magnet.hasMatch(t)) return true;
  final u = Uri.tryParse(t);
  return u != null && (u.scheme == 'http' || u.scheme == 'https') && u.host.isNotEmpty && !t.contains(' ');
}

/// Opens the add-torrent form in a bottom sheet.
Future<bool?> showAddTorrentSheet(BuildContext context, {String? initialUrl}) => showModalBottomSheet<bool>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SingleChildScrollView(
      child: AddTorrentForm(initialUrl: initialUrl, onAdded: () => Navigator.of(context).pop(true)),
    ),
  ),
);

class AddTorrentForm extends ConsumerStatefulWidget {
  const AddTorrentForm({super.key, this.initialUrl, this.onAdded});

  final String? initialUrl;

  /// Called after qBittorrent accepted the torrents.
  final VoidCallback? onAdded;

  @override
  ConsumerState<AddTorrentForm> createState() => _AddTorrentFormState();
}

class _AddTorrentFormState extends ConsumerState<AddTorrentForm> {
  late final _urls = TextEditingController(text: widget.initialUrl ?? '');
  final List<PickedTorrentFile> _files = [];
  String _category = 'manual';
  final Set<String> _tags = {};
  bool _stopped = false;
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _urls.dispose();
    super.dispose();
  }

  List<String> get _lines => [
    for (final l in _urls.text.split('\n'))
      if (l.trim().isNotEmpty) l.trim(),
  ];

  String? _validate() {
    final lines = _lines;
    if (lines.isEmpty && _files.isEmpty) {
      return 'Paste a magnet link or URL${canPickTorrentFiles ? ', or choose a .torrent file' : ''}.';
    }
    final bad = lines.where((l) => !isTorrentLinkLine(l)).toList();
    if (bad.isNotEmpty) return 'Not a magnet link or http(s) URL: ${bad.first}';
    if (lines.length > 20) return 'At most 20 links at once.';
    return null;
  }

  Future<void> _pick() async {
    final picked = await pickTorrentFiles();
    if (!mounted || picked.isEmpty) return;
    final tooBig = picked.where((f) => f.bytes.length > _maxFileBytes).map((f) => f.name).toList();
    setState(() {
      for (final f in picked) {
        if (f.bytes.length <= _maxFileBytes && _files.length < _maxFiles) _files.add(f);
      }
      _error = tooBig.isEmpty ? null : '${tooBig.join(', ')} is larger than 5 MB.';
    });
  }

  Future<void> _submit() async {
    final error = _validate();
    setState(() => _error = error);
    if (error != null) return;
    setState(() => _sending = true);
    try {
      await ref
          .read(activityApiProvider)
          .addTorrents(
            TorrentAddRequest(
              urls: _lines,
              torrentFilesBase64: [for (final f in _files) base64.encode(f.bytes)],
              category: _category,
              tags: _tags.toList(),
              stopped: _stopped ? true : null,
            ),
          );
      if (!mounted) return;
      ref
        ..invalidate(torrentsProvider)
        ..invalidate(torrentCategoriesProvider);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Added to qBittorrent')));
      widget.onAdded?.call();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(
        () => _error = e.code == ApiErrorCode.validationFailed && e.service == ServiceId.qbittorrent
            ? 'qBittorrent rejected this torrent'
            : e.message,
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final cats = ref.watch(torrentCategoriesProvider);
    final list = cats.value;
    final offered = <String>{
      'manual',
      for (final c in list?.categories ?? const <TorrentCategory>[])
        if (!c.readOnly || _arrCategories.contains(c.name)) c.name,
    }.toList()..sort();
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Add torrent', style: theme.textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('torrentUrls'),
            controller: _urls,
            minLines: 2,
            maxLines: 6,
            keyboardType: TextInputType.multiline,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Magnet links or URLs',
              helperText: 'One per line. qBittorrent fetches URLs itself, through the VPN.',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          if (canPickTorrentFiles) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: _files.length >= _maxFiles ? null : _pick,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Choose .torrent files'),
                ),
                for (final f in _files)
                  InputChip(label: Text(f.name), onDeleted: () => setState(() => _files.remove(f))),
              ],
            ),
          ],
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            key: const ValueKey('torrentCategory'),
            initialValue: offered.contains(_category) ? _category : 'manual',
            decoration: const InputDecoration(labelText: 'Category', border: OutlineInputBorder()),
            items: [for (final c in offered) DropdownMenuItem(value: c, child: Text(c))],
            onChanged: (c) => setState(() => _category = c ?? 'manual'),
          ),
          if (_arrCategories.contains(_category)) ...[
            const SizedBox(height: 8),
            Text(
              'Sonarr/Radarr did not grab this, so they will not import it. Use Library > Choose release instead.',
              style: theme.textTheme.bodySmall?.copyWith(color: colors.warning),
            ),
          ],
          if (list != null && list.tags.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Tags', style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                for (final t in list.tags)
                  FilterChip(
                    label: Text(t),
                    selected: _tags.contains(t),
                    onSelected: (v) => setState(() => v ? _tags.add(t) : _tags.remove(t)),
                  ),
              ],
            ),
          ],
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Start stopped'),
            value: _stopped,
            onChanged: (v) => setState(() => _stopped = v),
          ),
          if (_error != null) ...[
            Text(_error!, style: theme.textTheme.bodyMedium?.copyWith(color: colors.error)),
            const SizedBox(height: 8),
          ],
          FilledButton.icon(
            key: const ValueKey('addTorrentButton'),
            onPressed: _sending ? null : _submit,
            icon: _sending
                ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.add),
            label: const Text('Add'),
          ),
        ],
      ),
    );
  }
}
