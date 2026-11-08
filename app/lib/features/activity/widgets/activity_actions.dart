/// Admin actions shared by the queue, torrent list and torrent detail:
/// torrent actions, the delete flow with the `managed_by_arr` fallback, and
/// the *arr queue removal dialog (APP.md §2.4).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_exception.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/activity_api.dart';
import '../providers/activity_providers.dart';
import 'activity_format.dart';

/// Runs [action], then refreshes the activity lists and shows [done] (or
/// the error). Returns whether it succeeded.
Future<bool> runActivityAction(
  BuildContext context,
  WidgetRef ref,
  Future<void> Function() action, {
  String? done,
  String? hash,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await action();
    if (done != null) messenger?.showSnackBar(SnackBar(content: Text(done)));
    return true;
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(ApiException.from(e).message)));
    return false;
  } finally {
    if (context.mounted) invalidateActivity(ref, hash: hash);
  }
}

/// A simple torrent action (stop, start, recheck, ...).
Future<bool> torrentAction(
  BuildContext context,
  WidgetRef ref,
  List<String> hashes,
  TorrentAction action, {
  String? category,
  List<String>? tags,
  String? done,
}) => runActivityAction(
  context,
  ref,
  () => ref
      .read(activityApiProvider)
      .torrentAction(TorrentActionRequest(hashes: hashes, action: action, category: category, tags: tags)),
  done: done,
  hash: hashes.length == 1 ? hashes.single : null,
);

/// Adds or removes the `Keep` tag (decluttarr never removes kept torrents).
Future<bool> toggleProtect(BuildContext context, WidgetRef ref, TorrentSummary t) => torrentAction(
  context,
  ref,
  [t.hash],
  t.protected ? TorrentAction.removeTags : TorrentAction.addTags,
  tags: const ['Keep'],
  done: t.protected ? 'Protection removed' : 'Protected from cleanup',
);

/// Picks a category (from `GET /transfer/categories`) and applies it.
Future<void> chooseCategory(BuildContext context, WidgetRef ref, List<String> hashes, {String? current}) async {
  final CategoryList list;
  try {
    list = await ref.read(torrentCategoriesProvider.future);
  } catch (e) {
    if (context.mounted) context.showError(e);
    return;
  }
  if (!context.mounted) return;
  final choice = await ActionSheet.show<String>(
    context,
    title: 'Set category',
    items: [
      const ActionSheetItem(value: '', label: 'No category', icon: Icons.label_off_outlined),
      for (final c in list.categories)
        ActionSheetItem(
          value: c.name,
          label: c.name,
          icon: c.name == current ? Icons.check : Icons.label_outline,
          subtitle: c.readOnly ? 'Used by ${_ownerOf(c.name)}' : null,
        ),
    ],
  );
  if (choice == null || !context.mounted) return;
  await torrentAction(
    context,
    ref,
    hashes,
    TorrentAction.setCategory,
    category: choice,
    done: choice.isEmpty ? 'Category cleared' : 'Category set to $choice',
  );
}

String _ownerOf(String category) => switch (category) {
  'tv-sonarr' => 'Sonarr',
  'radarr' => 'Radarr',
  'lidarr' => 'Lidarr',
  _ => 'Books',
};

/// Picks a tag and adds/removes it.
Future<void> chooseTag(BuildContext context, WidgetRef ref, List<String> hashes, {required bool add}) async {
  final CategoryList list;
  try {
    list = await ref.read(torrentCategoriesProvider.future);
  } catch (e) {
    if (context.mounted) context.showError(e);
    return;
  }
  if (!context.mounted) return;
  final tag = await ActionSheet.show<String>(
    context,
    title: add ? 'Add tag' : 'Remove tag',
    items: [for (final t in list.tags) ActionSheetItem(value: t, label: t, icon: Icons.sell_outlined)],
  );
  if (tag == null || !context.mounted) return;
  await torrentAction(
    context,
    ref,
    hashes,
    add ? TorrentAction.addTags : TorrentAction.removeTags,
    tags: [tag],
    done: add ? 'Tag $tag added' : 'Tag $tag removed',
  );
}

/// What to do with *arr queue records being removed.
class QueueRemoveOptions {
  const QueueRemoveOptions({required this.removeFromClient, required this.blocklist, required this.searchAgain});

  final bool removeFromClient;
  final bool blocklist;
  final bool searchAgain;
}

/// "Remove from queue" dialog: Remove from qBittorrent (on), Blocklist
/// release (off), Search again (only with blocklist).
Future<QueueRemoveOptions?> showQueueRemoveDialog(
  BuildContext context, {
  required String title,
  required ArrService service,
  String confirmLabel = 'Remove',
}) => showDialog<QueueRemoveOptions>(
  context: context,
  builder: (_) => _QueueRemoveDialog(title: title, service: service, confirmLabel: confirmLabel),
);

class _QueueRemoveDialog extends StatefulWidget {
  const _QueueRemoveDialog({required this.title, required this.service, required this.confirmLabel});

  final String title;
  final ArrService service;
  final String confirmLabel;

  @override
  State<_QueueRemoveDialog> createState() => _QueueRemoveDialogState();
}

class _QueueRemoveDialogState extends State<_QueueRemoveDialog> {
  bool _client = true;
  bool _blocklist = false;
  bool _search = false;

  @override
  Widget build(BuildContext context) {
    final danger = StatusColors.of(context).error;
    final arr = arrLabel(widget.service);
    return AlertDialog(
      title: Text('Remove from $arr queue?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Remove from qBittorrent'),
              subtitle: const Text('Deletes the torrent and its downloaded data'),
              value: _client,
              onChanged: (v) => setState(() => _client = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Blocklist release'),
              subtitle: Text('$arr will not grab this release again'),
              value: _blocklist,
              onChanged: (v) => setState(() {
                _blocklist = v;
                if (!v) _search = false;
              }),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Search again'),
              subtitle: Text('$arr looks for another release'),
              value: _search,
              onChanged: _blocklist ? (v) => setState(() => _search = v) : null,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: danger, foregroundColor: Colors.white),
          onPressed: () =>
              Navigator.of(context)
                  .pop(QueueRemoveOptions(removeFromClient: _client, blocklist: _blocklist, searchAgain: _search)),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// Removes *arr queue records after the dialog.
Future<bool> removeFromQueue(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  required QueueArrEntry entry,
}) => removeTargetsFromQueue(
  context,
  ref,
  title: title,
  service: entry.service,
  targets: [QueueRemoveTarget(service: entry.service, queueIds: entry.queueIds)],
);

Future<bool> removeTargetsFromQueue(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  required ArrService service,
  required List<QueueRemoveTarget> targets,
}) async {
  final options = await showQueueRemoveDialog(context, title: title, service: service);
  if (options == null || !context.mounted) return false;
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final result = await ref
        .read(activityApiProvider)
        .removeFromQueue(
          QueueRemoveRequest(
            items: targets,
            removeFromClient: options.removeFromClient,
            blocklist: options.blocklist,
            searchAgain: options.searchAgain,
            confirm: true,
          ),
        );
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          result.removed == 0 && result.alreadyGone > 0 ? 'Already removed' : 'Removed from ${arrLabel(service)}',
        ),
      ),
    );
    return true;
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(ApiException.from(e).message)));
    return false;
  } finally {
    if (context.mounted) invalidateActivity(ref);
  }
}

/// Delete torrents: keep/delete files, then (on `managed_by_arr`) offer the
/// *arr removal instead or deleting anyway.
Future<bool> deleteTorrents(BuildContext context, WidgetRef ref, List<TorrentSummary> torrents) async {
  if (torrents.isEmpty) return false;
  var deleteFiles = false;
  final name = torrents.length == 1 ? torrents.single.name : '${torrents.length} torrents';
  final confirmed = await ConfirmDialog.show(
    context,
    title: torrents.length == 1 ? 'Delete torrent?' : 'Delete ${torrents.length} torrents?',
    message: name,
    destructive: true,
    confirmLabel: 'Delete',
    content: StatefulBuilder(
      builder: (context, setState) => RadioGroup<bool>(
        groupValue: deleteFiles,
        onChanged: (v) => setState(() => deleteFiles = v ?? false),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioListTile<bool>(contentPadding: EdgeInsets.zero, value: false, title: Text('Keep files')),
            RadioListTile<bool>(
              contentPadding: EdgeInsets.zero,
              value: true,
              title: Text('Delete files (permanent)'),
              subtitle: Text('There is no recycle bin'),
            ),
          ],
        ),
      ),
    ),
  );
  if (!confirmed || !context.mounted) return false;
  final api = ref.read(activityApiProvider);
  final hashes = [for (final t in torrents) t.hash];
  Future<void> send({bool force = false}) => api.torrentAction(
    TorrentActionRequest(
      hashes: hashes,
      action: TorrentAction.delete,
      deleteFiles: deleteFiles,
      force: force ? true : null,
      confirm: true,
    ),
  );
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await send();
    messenger?.showSnackBar(SnackBar(content: Text(torrents.length == 1 ? 'Torrent deleted' : 'Torrents deleted')));
    return true;
  } on ApiException catch (e) {
    if (e.code != ApiErrorCode.managedByArr || !context.mounted) {
      messenger?.showSnackBar(SnackBar(content: Text(e.message)));
      return false;
    }
    final managed = TorrentManagedByArr.listFromDetails(e.details);
    final services = {for (final m in managed) m.service};
    final arr = services.length == 1 ? arrLabel(services.single) : 'Sonarr/Radarr';
    final choice = await ActionSheet.show<String>(
      context,
      title: '$arr still tracks this download',
      items: [
        ActionSheetItem(
          value: 'arr',
          label: 'Remove via $arr instead',
          subtitle: 'Recommended: $arr will not re-grab it or report it missing',
          icon: Icons.playlist_remove,
        ),
        const ActionSheetItem(
          value: 'force',
          label: 'Delete in qBittorrent anyway',
          icon: Icons.delete_forever_outlined,
          destructive: true,
        ),
      ],
    );
    if (!context.mounted || choice == null) return false;
    if (choice == 'force') {
      return runActivityAction(context, ref, () => send(force: true), done: 'Torrent deleted');
    }
    return removeTargetsFromQueue(
      context,
      ref,
      title: name,
      service: services.length == 1 ? services.single : ArrService.sonarr,
      targets: [for (final m in managed) QueueRemoveTarget(service: m.service, queueIds: m.queueIds)],
    );
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(ApiException.from(e).message)));
    return false;
  } finally {
    if (context.mounted) invalidateActivity(ref);
  }
}
