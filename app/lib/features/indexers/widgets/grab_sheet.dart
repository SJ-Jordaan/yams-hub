/// The release sheet of the manual search: details, "Grab to qBittorrent"
/// with a category and "Open info page" (APP.md §10.4).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_exception.dart';
import 'package:yams_hub/core/links/external_links.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/indexers_api.dart';
import '../providers/indexers_providers.dart';
import 'indexer_widgets.dart';

/// "14 h", "3 d", or the publish date.
String formatReleaseAge(Release r) {
  final h = r.ageHours;
  if (h == null) {
    return r.publishDate == null ? '–' : formatRelative(r.publishDate);
  }
  if (h < 1) return '<1 h';
  if (h < 48) return '$h h';
  return '${h ~/ 24} d';
}

/// Shows the sheet; resolves true when the release was sent to qBittorrent.
Future<bool> showGrabSheet(BuildContext context, Release release) async {
  final sent = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => GrabSheet(release: release),
  );
  return sent ?? false;
}

class GrabSheet extends ConsumerStatefulWidget {
  const GrabSheet({super.key, required this.release});

  final Release release;

  @override
  ConsumerState<GrabSheet> createState() => _GrabSheetState();
}

class _GrabSheetState extends ConsumerState<GrabSheet> {
  String _category = ReleaseGrabRequest.defaultCategory;
  bool _sending = false;
  Object? _error;

  Future<void> _grab() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await ref
          .read(indexersApiProvider)
          .grab(
            ReleaseGrabRequest(
              releaseId: widget.release.releaseId,
              category: _category,
            ),
          );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).pop(true);
      messenger?.showSnackBar(
        SnackBar(content: Text('Sent to qBittorrent ($_category)')),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = e;
        });
      }
    }
  }

  String _errorText(Object error) {
    final e = ApiException.from(error);
    if (e.status == 404) return 'This result expired. Search again to grab it.';
    return e.message;
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.release;
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final categories =
        ref.watch(grabCategoriesProvider).value ??
        const [ReleaseGrabRequest.defaultCategory];
    final infoUri = r.infoUrl == null ? null : Uri.tryParse(r.infoUrl!);
    final usenet = r.protocol == 'usenet';
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectableText(r.title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          KeyValueList(
            dense: true,
            labelWidth: 96,
            entries: [
              KeyValue('Indexer', r.indexer),
              KeyValue('Size', formatBytes(r.sizeBytes)),
              KeyValue.widget(
                'Age',
                Tooltip(
                  message: formatDateTime(r.publishDate),
                  child: Text(formatReleaseAge(r)),
                ),
              ),
              if (r.seeders != null || r.leechers != null)
                KeyValue(
                  'Peers',
                  '${r.seeders ?? '–'} seeders · ${r.leechers ?? '–'} leechers',
                ),
              if (r.grabs case final g?) KeyValue('Grabs', formatCount(g)),
              KeyValue('Source', r.hasMagnet ? 'Magnet link' : '.torrent file'),
            ],
          ),
          if (r.categories.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [for (final c in r.categories) IndexerLabel(c)],
            ),
          ],
          const SizedBox(height: 20),
          DropdownButtonFormField<String>(
            key: ValueKey(categories.join('|')),
            initialValue: categories.contains(_category)
                ? _category
                : categories.first,
            decoration: const InputDecoration(
              labelText: 'qBittorrent category',
              helperText: '"manual" is created on the first grab',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final c in categories)
                DropdownMenuItem(value: c, child: Text(c)),
            ],
            onChanged: _sending
                ? null
                : (v) => setState(
                    () => _category = v ?? ReleaseGrabRequest.defaultCategory,
                  ),
          ),
          const SizedBox(height: 16),
          if (_error case final e?)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Icon(Icons.error_outline, color: colors.error, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _errorText(e),
                      style: TextStyle(color: colors.error),
                    ),
                  ),
                ],
              ),
            ),
          FilledButton.icon(
            onPressed: _sending || usenet ? null : _grab,
            icon: _sending
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download),
            label: Text(
              usenet
                  ? 'Usenet releases cannot be grabbed'
                  : 'Grab to qBittorrent',
            ),
          ),
          if (infoUri != null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () async {
                final ok = await launchExternalUri(infoUri);
                if (!ok && context.mounted) {
                  context.showSnack("Couldn't open the info page");
                }
              },
              icon: const Icon(Icons.open_in_new),
              label: const Text('Open info page'),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            'Manual grabs are not tracked by Sonarr or Radarr.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
