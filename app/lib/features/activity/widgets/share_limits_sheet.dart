/// Share-limits editor (APP.md §6.2): Use global / Unlimited / Custom. The
/// "Remove" actions go through the gateway's 428 → ConfirmDialog with its
/// `details.impact` → `confirm=true` flow (APP.md §2.4).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_exception.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/activity_api.dart';
import '../providers/activity_providers.dart';
import 'activity_format.dart';

Future<void> showShareLimitsSheet(BuildContext context, TorrentDetail detail) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SingleChildScrollView(child: ShareLimitsForm(detail: detail)),
  ),
);

class ShareLimitsForm extends ConsumerStatefulWidget {
  const ShareLimitsForm({super.key, required this.detail});

  final TorrentDetail detail;

  @override
  ConsumerState<ShareLimitsForm> createState() => _ShareLimitsFormState();
}

class _ShareLimitsFormState extends ConsumerState<ShareLimitsForm> {
  late ShareLimitsMode _mode = widget.detail.shareLimits.mode == ShareLimitsMode.unknown
      ? ShareLimitsMode.global
      : widget.detail.shareLimits.mode;
  late ShareLimitsAction _action = widget.detail.shareLimits.action == ShareLimitsAction.unknown
      ? ShareLimitsAction.byDefault
      : widget.detail.shareLimits.action;
  late final _ratio = TextEditingController(text: widget.detail.shareLimits.ratio?.toString() ?? '');
  late final _seeding = TextEditingController(text: widget.detail.shareLimits.seedingMinutes?.toString() ?? '');
  late final _inactive = TextEditingController(text: widget.detail.shareLimits.inactiveMinutes?.toString() ?? '');
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _ratio.dispose();
    _seeding.dispose();
    _inactive.dispose();
    super.dispose();
  }

  ShareLimitsUpdate? _build({bool confirm = false}) {
    double? ratio;
    int? seeding;
    int? inactive;
    if (_mode == ShareLimitsMode.custom) {
      ratio = _ratio.text.trim().isEmpty ? null : double.tryParse(_ratio.text.trim().replaceAll(',', '.'));
      seeding = _seeding.text.trim().isEmpty ? null : int.tryParse(_seeding.text.trim());
      inactive = _inactive.text.trim().isEmpty ? null : int.tryParse(_inactive.text.trim());
      final invalid =
          (_ratio.text.trim().isNotEmpty && (ratio == null || ratio < 0)) ||
          (_seeding.text.trim().isNotEmpty && (seeding == null || seeding < 0)) ||
          (_inactive.text.trim().isNotEmpty && (inactive == null || inactive < 0));
      if (invalid) {
        setState(() => _error = 'Enter positive numbers.');
        return null;
      }
      if (ratio == null && seeding == null && inactive == null) {
        setState(() => _error = 'Set a ratio, a seeding time or an inactive time.');
        return null;
      }
    }
    return ShareLimitsUpdate(
      mode: _mode,
      ratio: ratio,
      seedingMinutes: seeding,
      inactiveMinutes: inactive,
      action: _action,
      confirm: confirm ? true : null,
    );
  }

  Future<void> _save() async {
    final update = _build();
    if (update == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final api = ref.read(activityApiProvider);
    final hash = widget.detail.summary.hash;
    try {
      try {
        await api.setShareLimits(hash, update);
      } on ApiException catch (e) {
        if (e.code != ApiErrorCode.confirmationRequired || !mounted) rethrow;
        final impact = readString(e.details?['impact']) ?? 'qBittorrent will remove this torrent automatically.';
        final ok = await ConfirmDialog.show(
          context,
          title: _action == ShareLimitsAction.removeWithContent
              ? 'Delete files automatically?'
              : 'Remove automatically?',
          message: impact,
          confirmLabel: 'Save',
          destructive: true,
        );
        if (!ok || !mounted) return;
        await api.setShareLimits(hash, _build(confirm: true)!);
      }
      if (!mounted) return;
      ref.invalidate(torrentDetailProvider(hash));
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Share limits saved')));
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = ApiException.from(e).message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final custom = _mode == ShareLimitsMode.custom;
    final numeric = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))];
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Share limits', style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          SegmentedButton<ShareLimitsMode>(
            segments: const [
              ButtonSegment(value: ShareLimitsMode.global, label: Text('Use global')),
              ButtonSegment(value: ShareLimitsMode.unlimited, label: Text('Unlimited')),
              ButtonSegment(value: ShareLimitsMode.custom, label: Text('Custom')),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() {
              _mode = s.first;
              _error = null;
            }),
          ),
          if (custom) ...[
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('shareRatio'),
              controller: _ratio,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: numeric,
              decoration: const InputDecoration(labelText: 'Ratio', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _seeding,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Seeding time (minutes)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _inactive,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Inactive time (minutes)', border: OutlineInputBorder()),
            ),
          ],
          const SizedBox(height: 16),
          DropdownButtonFormField<ShareLimitsAction>(
            key: const ValueKey('shareAction'),
            initialValue: _action,
            decoration: const InputDecoration(labelText: 'When the limit is reached', border: OutlineInputBorder()),
            items: [
              for (final a in ShareLimitsAction.values)
                if (a != ShareLimitsAction.unknown) DropdownMenuItem(value: a, child: Text(shareActionLabel(a))),
            ],
            onChanged: (a) => setState(() => _action = a ?? ShareLimitsAction.byDefault),
          ),
          if (_action.removes) ...[
            const SizedBox(height: 8),
            Text(
              _action == ShareLimitsAction.removeWithContent
                  ? 'qBittorrent will delete the torrent and its files when the limit is reached.'
                  : 'qBittorrent will remove the torrent (keeping files) when the limit is reached.',
              style: theme.textTheme.bodySmall?.copyWith(color: StatusColors.of(context).warning),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: theme.textTheme.bodyMedium?.copyWith(color: StatusColors.of(context).error)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            key: const ValueKey('saveShareLimits'),
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save'),
          ),
        ],
      ),
    );
  }
}
