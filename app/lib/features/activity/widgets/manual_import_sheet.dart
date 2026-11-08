/// Manual-import sheet (APP.md §6.1, API.md §8.3.1): the candidate files
/// Sonarr/Radarr found in a download, with their matches and rejections, an
/// import mode and "Import N files".
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_exception.dart';
import 'package:yams_hub/core/links/external_links.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/activity_api.dart';
import '../providers/activity_providers.dart';
import 'activity_format.dart';

/// Opens the sheet for [entry] (its first queue id addresses the download).
Future<void> showManualImportSheet(BuildContext context, {required QueueArrEntry entry, required String title}) {
  final queueId = entry.queueIds.firstOrNull;
  if (queueId == null) return Future.value();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 1,
      builder: (context, controller) =>
          ManualImportSheet(entry: entry, queueId: queueId, title: title, scrollController: controller),
    ),
  );
}

class ManualImportSheet extends ConsumerStatefulWidget {
  const ManualImportSheet({
    super.key,
    required this.entry,
    required this.queueId,
    required this.title,
    this.scrollController,
  });

  final QueueArrEntry entry;
  final int queueId;
  final String title;
  final ScrollController? scrollController;

  @override
  ConsumerState<ManualImportSheet> createState() => _ManualImportSheetState();
}

class _ManualImportSheetState extends ConsumerState<ManualImportSheet> {
  /// Selected file ids (null until the candidates load).
  Set<String>? _selected;

  /// Edited episode matches by file id.
  final Map<String, List<ManualImportFileEpisode>> _episodes = {};
  QueueImportMode _mode = QueueImportMode.auto;
  bool _sending = false;
  CommandRef? _command;

  ArrService get _service => widget.entry.service;

  (ArrService, int) get _key => (_service, widget.queueId);

  bool _importable(ManualImportFile f) {
    if (_service == ArrService.radarr) return f.movieId != null;
    final eps = _episodes[f.fileId] ?? f.episodes;
    return f.seriesId != null && eps.isNotEmpty;
  }

  Future<void> _editMatch(ManualImportFile f) async {
    final seriesId = f.seriesId;
    if (seriesId == null) {
      context.showSnack('Sonarr could not match a series; use Open in Sonarr.');
      return;
    }
    final current = {for (final e in _episodes[f.fileId] ?? f.episodes) e.id};
    final picked = await showDialog<List<ManualImportFileEpisode>>(
      context: context,
      builder: (_) => _EpisodePicker(seriesId: seriesId, selected: current, fileName: f.relativePath),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _episodes[f.fileId] = picked;
      if (picked.isNotEmpty) _selected?.add(f.fileId);
    });
  }

  Future<void> _import(List<ManualImportFile> files) async {
    final chosen = [
      for (final f in files)
        if (_selected!.contains(f.fileId) && _importable(f)) f,
    ];
    if (chosen.isEmpty) return;
    if (_mode == QueueImportMode.move) {
      final ok = await ConfirmDialog.show(
        context,
        title: 'Move files?',
        message: 'Files are moved out of the download folder; the torrent stops seeding them.',
        confirmLabel: 'Move',
        destructive: true,
      );
      if (!ok || !mounted) return;
    }
    setState(() => _sending = true);
    try {
      final command = await ref
          .read(activityApiProvider)
          .manualImport(
            QueueImportRequest(
              service: _service,
              queueId: widget.queueId,
              importMode: _mode,
              files: [
                for (final f in chosen)
                  QueueImportFileSelection(
                    fileId: f.fileId,
                    seriesId: _episodes.containsKey(f.fileId) ? f.seriesId : null,
                    episodeIds: _episodes[f.fileId]?.map((e) => e.id).toList(),
                  ),
              ],
            ),
          );
      if (mounted) setState(() => _command = command);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == ApiErrorCode.notFound) ref.invalidate(importCandidatesProvider(_key));
      context.showSnack(e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _commandDone(CommandRef c) {
    final ok = c.status == CommandStatus.completed && c.result != CommandResult.unsuccessful;
    final arr = arrLabel(_service);
    final messenger = ScaffoldMessenger.maybeOf(context);
    invalidateActivity(ref);
    Navigator.of(context).maybePop();
    final String text;
    if (ok) {
      text = 'Import finished';
    } else if (c.status.isActive || c.status == CommandStatus.unknown) {
      text = '$arr is still importing; check its queue in a moment';
    } else {
      text = 'Import ${c.status.name}${c.message == null ? '' : ': ${c.message}'}';
    }
    messenger?.showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = ref.watch(importCandidatesProvider(_key));
    final arr = arrLabel(_service);
    final link = widget.entry.links.firstOrNull;

    Widget body;
    if (value.hasValue) {
      final files = value.value!.items;
      _selected ??= {
        for (final f in files)
          if (f.importable) f.fileId,
      };
      if (files.isEmpty) {
        body = EmptyView(
          icon: Icons.folder_off_outlined,
          title: '$arr found no files to import',
          message: 'The download may still be moving, or the files are not video files.',
          action: link == null
              ? null
              : OutlinedButton.icon(
                  onPressed: () => openExternal(ref, link),
                  icon: const Icon(Icons.open_in_new),
                  label: Text('Open in $arr'),
                ),
        );
      } else {
        body = ListView.separated(
          controller: widget.scrollController,
          padding: const EdgeInsets.only(bottom: 16),
          itemCount: files.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) => _CandidateRow(
            file: files[i],
            service: _service,
            episodes: _episodes[files[i].fileId],
            selected: _selected!.contains(files[i].fileId),
            importable: _importable(files[i]),
            onSelected: (v) => setState(() => v ? _selected!.add(files[i].fileId) : _selected!.remove(files[i].fileId)),
            onEdit: _service == ArrService.sonarr ? () => _editMatch(files[i]) : null,
          ),
        );
      }
    } else if (value.hasError) {
      final e = ApiException.from(value.error!);
      body = e.code == ApiErrorCode.notFound
          ? const EmptyView(
              icon: Icons.task_alt,
              title: 'Already resolved',
              message: 'This download is no longer in the queue.',
            )
          : ErrorView(error: e, onRetry: () => ref.invalidate(importCandidatesProvider(_key)));
    } else {
      body = const SkeletonList(count: 4);
    }

    final files = value.value?.items ?? const <ManualImportFile>[];
    final count = _selected == null ? 0 : files.where((f) => _selected!.contains(f.fileId) && _importable(f)).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Manual import', style: theme.textTheme.titleLarge),
              Text(
                '$arr · ${widget.title}',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        Expanded(child: body),
        if (files.isNotEmpty)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: _command != null
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: CommandChip(command: _command!, label: 'Importing $count files', onDone: _commandDone),
                    )
                  : Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SegmentedButton<QueueImportMode>(
                          segments: const [
                            ButtonSegment(value: QueueImportMode.auto, label: Text('Auto')),
                            ButtonSegment(value: QueueImportMode.move, label: Text('Move')),
                            ButtonSegment(value: QueueImportMode.copy, label: Text('Copy')),
                          ],
                          selected: {_mode},
                          onSelectionChanged: (s) => setState(() => _mode = s.first),
                        ),
                        FilledButton.icon(
                          key: const ValueKey('importButton'),
                          onPressed: count == 0 || _sending ? null : () => _import(files),
                          icon: _sending
                              ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.move_to_inbox),
                          label: Text('Import $count ${count == 1 ? 'file' : 'files'}'),
                        ),
                      ],
                    ),
            ),
          ),
      ],
    );
  }
}

class _CandidateRow extends StatelessWidget {
  const _CandidateRow({
    required this.file,
    required this.service,
    required this.selected,
    required this.importable,
    required this.onSelected,
    this.episodes,
    this.onEdit,
  });

  final ManualImportFile file;
  final ArrService service;
  final List<ManualImportFileEpisode>? episodes;
  final bool selected;
  final bool importable;
  final ValueChanged<bool> onSelected;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final eps = episodes ?? file.episodes;
    final match = service == ArrService.radarr
        ? (file.movieTitle ?? 'No movie matched')
        : eps.isEmpty
        ? 'No episode matched'
        : eps.map((e) => e.title == null ? e.label : '${e.label} · ${e.title}').join(', ');
    return CheckboxListTile(
      value: selected && importable,
      onChanged: importable ? (v) => onSelected(v ?? false) : null,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(file.relativePath, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              StatusChip(label: formatBytes(file.sizeBytes), dense: true),
              StatusChip(label: file.quality.name, tone: StatusTone.info, dense: true),
              for (final l in file.languages) StatusChip(label: l, dense: true),
              if (file.releaseGroup != null) StatusChip(label: file.releaseGroup!, dense: true),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  match,
                  style: theme.textTheme.bodySmall?.copyWith(color: importable ? null : colors.warning),
                ),
              ),
              if (onEdit != null) TextButton(onPressed: onEdit, child: const Text('Edit match')),
            ],
          ),
          for (final r in file.rejections)
            Text(r.reason, style: theme.textTheme.bodySmall?.copyWith(color: colors.error)),
        ],
      ),
    );
  }
}

class _EpisodePicker extends ConsumerStatefulWidget {
  const _EpisodePicker({required this.seriesId, required this.selected, required this.fileName});

  final int seriesId;
  final Set<int> selected;
  final String fileName;

  @override
  ConsumerState<_EpisodePicker> createState() => _EpisodePickerState();
}

class _EpisodePickerState extends ConsumerState<_EpisodePicker> {
  late final Set<int> _selected = {...widget.selected};

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(seriesEpisodesProvider(widget.seriesId));
    final episodes = value.value ?? const <ActivitySeriesEpisode>[];
    return AlertDialog(
      title: const Text('Match episodes'),
      content: SizedBox(
        width: 420,
        height: 420,
        child: value.hasValue
            ? ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(widget.fileName, style: Theme.of(context).textTheme.bodySmall),
                  ),
                  for (final e in episodes)
                    CheckboxListTile(
                      dense: true,
                      value: _selected.contains(e.id),
                      onChanged: (v) => setState(() => v ?? false ? _selected.add(e.id) : _selected.remove(e.id)),
                      title: Text(e.label),
                      subtitle: e.title == null ? null : Text(e.title!, maxLines: 1, overflow: TextOverflow.ellipsis),
                      secondary: e.hasFile ? const Icon(Icons.check_circle_outline, size: 18) : null,
                    ),
                ],
              )
            : value.hasError
            ? ErrorView(
                error: value.error!,
                compact: true,
                onRetry: () => ref.invalidate(seriesEpisodesProvider(widget.seriesId)),
              )
            : const SkeletonList(count: 6, padding: EdgeInsets.zero),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop([
            for (final e in episodes)
              if (_selected.contains(e.id)) ManualImportFileEpisode(id: e.id, label: e.label, title: e.title),
          ]),
          child: const Text('Use'),
        ),
      ],
    );
  }
}

/// How long the chip polls before it gives up (API.md §7.4: at most 2 min).
const commandMaxWait = Duration(minutes: 2);

/// Polls a Sonarr/Radarr command (`GET /library/commands/...` every 2 s)
/// and reports its end once. After [commandMaxWait], or when the poll
/// fails, it reports the last known state (possibly still active).
class CommandChip extends ConsumerStatefulWidget {
  const CommandChip({super.key, required this.command, required this.label, this.onDone});

  final CommandRef command;
  final String label;
  final ValueChanged<CommandRef>? onDone;

  @override
  ConsumerState<CommandChip> createState() => _CommandChipState();
}

class _CommandChipState extends ConsumerState<CommandChip> {
  bool _reported = false;
  Timer? _deadline;

  (ServiceId, int) get _key => (widget.command.service, widget.command.id);

  @override
  void initState() {
    super.initState();
    _deadline = Timer(commandMaxWait, () {
      if (mounted) _report(ref.read(commandProvider(_key)).value ?? widget.command, force: true);
    });
  }

  @override
  void dispose() {
    _deadline?.cancel();
    super.dispose();
  }

  void _report(CommandRef c, {bool force = false}) {
    if (_reported || (c.status.isActive && !force)) return;
    _reported = true;
    _deadline?.cancel();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onDone?.call(c);
    });
  }

  @override
  Widget build(BuildContext context) {
    // A command that finished before the first poll needs no polling.
    if (!widget.command.status.isActive && widget.command.status != CommandStatus.unknown) {
      _report(widget.command);
    }
    ref.listen<AsyncValue<CommandRef>>(commandProvider(_key), (previous, next) {
      if (next.value case final c? when !next.hasError) {
        _report(c);
      } else if (next.hasError && !next.isLoading) {
        _report(previous?.value ?? widget.command, force: true);
      }
    });
    final c = ref.watch(commandProvider(_key)).value ?? widget.command;
    final colors = StatusColors.of(context);
    final Widget avatar = switch (c.status) {
      CommandStatus.completed => Icon(Icons.check_circle, size: 18, color: colors.ok),
      CommandStatus.failed ||
      CommandStatus.aborted ||
      CommandStatus.cancelled ||
      CommandStatus.orphaned => Icon(Icons.error, size: 18, color: colors.error),
      _ => const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
    };
    return Chip(
      avatar: avatar,
      label: Text(c.status.isActive ? '${widget.label}…' : '${widget.label}: ${c.status.name}'),
    );
  }
}
