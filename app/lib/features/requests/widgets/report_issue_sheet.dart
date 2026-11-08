/// "Report issue" sheet (APP.md §4.3): type, season/episode (series) and a
/// message; `POST /issues`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_exception.dart';
import 'package:yams_models/yams_models.dart';

import '../data/requests_api.dart';
import '../providers/requests_providers.dart';
import 'request_ui.dart';

/// Opens the sheet; true when an issue was created.
Future<bool> showReportIssueSheet(BuildContext context, TitleDetail title) async =>
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => ReportIssueSheet(title: title),
    ) ??
    false;

class ReportIssueSheet extends ConsumerStatefulWidget {
  const ReportIssueSheet({super.key, required this.title});

  final TitleDetail title;

  @override
  ConsumerState<ReportIssueSheet> createState() => _ReportIssueSheetState();
}

class _ReportIssueSheetState extends ConsumerState<ReportIssueSheet> {
  static const _maxLength = 2000;
  final _message = TextEditingController();
  IssueType _type = IssueType.video;
  int _season = 0;
  int _episode = 0;
  bool _sending = false;
  String? _error;

  TitleDetail get t => widget.title;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _message.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'Describe the problem.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await ref
          .read(requestsApiProvider)
          .createIssue(
            CreateIssue(
              mediaType: t.type,
              tmdbId: t.tmdbId,
              type: _type,
              message: text,
              season: t.isTv && _season > 0 ? _season : null,
              episode: t.isTv && _season > 0 && _episode > 0 ? _episode : null,
            ),
          );
      ref.read(requestsGenerationProvider.notifier).bump();
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Issue reported')));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = ApiException.from(e).message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final seasons = t.seasons.where((s) => s.availability != Availability.none).toList();
    final season = seasons.where((s) => s.seasonNumber == _season).firstOrNull;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Report a problem', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(t.title, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            SegmentedButton<IssueType>(
              segments: [
                for (final type in const [IssueType.video, IssueType.audio, IssueType.subtitles, IssueType.other])
                  ButtonSegment(value: type, label: Text(issueTypeLabel(type))),
              ],
              selected: {_type},
              showSelectedIcon: false,
              onSelectionChanged: _sending ? null : (v) => setState(() => _type = v.first),
            ),
            if (t.isTv && seasons.isNotEmpty) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: _season,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Season',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        const DropdownMenuItem(value: 0, child: Text('All seasons')),
                        for (final s in seasons) DropdownMenuItem(value: s.seasonNumber, child: Text(s.name)),
                      ],
                      onChanged: _sending
                          ? null
                          : (v) => setState(() {
                              _season = v ?? 0;
                              _episode = 0;
                            }),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      key: ValueKey('episodes:$_season'),
                      initialValue: _episode,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Episode',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        const DropdownMenuItem(value: 0, child: Text('All episodes')),
                        if (season != null)
                          for (var e = 1; e <= season.episodeCount; e++)
                            DropdownMenuItem(value: e, child: Text('Episode $e')),
                      ],
                      onChanged: _sending || season == null ? null : (v) => setState(() => _episode = v ?? 0),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _message,
              enabled: !_sending,
              minLines: 3,
              maxLines: 6,
              maxLength: _maxLength,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'What is wrong?',
                hintText: 'e.g. Audio out of sync from 12:30',
                border: const OutlineInputBorder(),
                errorText: _error,
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _sending ? null : _submit,
              icon: _sending
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              label: const Text('Report issue'),
            ),
          ],
        ),
      ),
    );
  }
}
