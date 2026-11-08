/// Transfer settings `/activity/transfer` (admin, APP.md §6.3): normal and
/// alternative limits (KiB/s, 0 = unlimited), alt-speed and session
/// switches, the read-only schedule and global statistics.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/activity_api.dart';
import '../providers/activity_providers.dart';
import '../widgets/activity_format.dart';

class TransferSettingsScreen extends ConsumerWidget {
  const TransferSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(transferProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Speed & session')),
      body: AsyncValueView<TransferState>(
        value: value,
        onRetry: () => ref.invalidate(transferProvider),
        data: (context, t) => _TransferBody(transfer: t),
      ),
    );
  }
}

class _TransferBody extends ConsumerStatefulWidget {
  const _TransferBody({required this.transfer});

  final TransferState transfer;

  @override
  ConsumerState<_TransferBody> createState() => _TransferBodyState();
}

class _TransferBodyState extends ConsumerState<_TransferBody> {
  late final Map<String, TextEditingController> _fields = {
    'dl': TextEditingController(text: _kib(widget.transfer.limits?.dlBps)),
    'up': TextEditingController(text: _kib(widget.transfer.limits?.upBps)),
    'altDl': TextEditingController(text: _kib(widget.transfer.limits?.altDlBps)),
    'altUp': TextEditingController(text: _kib(widget.transfer.limits?.altUpBps)),
  };
  bool _saving = false;
  bool? _pendingAlt;
  bool? _pendingPaused;

  /// The user edited a limit: polled values no longer overwrite the fields.
  bool _edited = false;

  static String _kib(int? bps) => bps == null ? '' : '${bps ~/ 1024}';

  int _bps(String key) => (int.tryParse(_fields[key]!.text.trim()) ?? 0) * 1024;

  /// Every limit has a value (an empty field must never be saved as
  /// "unlimited", e.g. when the current limits could not be read).
  bool get _complete => _fields.values.every((c) => int.tryParse(c.text.trim()) != null);

  @override
  void didUpdateWidget(covariant _TransferBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    final limits = widget.transfer.limits;
    if (_edited || limits == null) return;
    for (final (key, bps) in [
      ('dl', limits.dlBps),
      ('up', limits.upBps),
      ('altDl', limits.altDlBps),
      ('altUp', limits.altUpBps),
    ]) {
      final text = _kib(bps);
      if (_fields[key]!.text != text) _fields[key]!.text = text;
    }
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() f, String done) async {
    try {
      await f();
      if (mounted) context.showSnack(done);
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) ref.invalidate(transferProvider);
    }
  }

  Future<void> _saveLimits() async {
    setState(() => _saving = true);
    await _run(
      () => ref
          .read(activityApiProvider)
          .setLimits(
            TransferLimits(dlBps: _bps('dl'), upBps: _bps('up'), altDlBps: _bps('altDl'), altUpBps: _bps('altUp')),
          ),
      'Speed limits saved',
    );
    if (mounted) {
      setState(() {
        _saving = false;
        _edited = false;
      });
    }
  }

  Widget _field(String key, String label) => TextField(
    key: ValueKey('limit_$key'),
    controller: _fields[key],
    keyboardType: TextInputType.number,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    onChanged: (_) => setState(() => _edited = true),
    decoration: InputDecoration(
      labelText: label,
      suffixText: 'KiB/s',
      helperText: '0 = unlimited',
      border: const OutlineInputBorder(),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = widget.transfer;
    final theme = Theme.of(context);
    final schedule = t.schedule;
    final alt = _pendingAlt ?? t.altSpeedEnabled;
    final paused = _pendingPaused ?? t.sessionPaused;
    return RefreshIndicator(
      onRefresh: () => ref.refresh(transferProvider.future),
      child: ListView(
        key: const ValueKey('transferSettingsList'),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
        children: [
          if (t.stale) const StaleBanner(),
          SectionCard(
            title: 'Speed limits',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (t.limits == null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text("Couldn't read the current limits.", style: theme.textTheme.bodySmall),
                  ),
                Text('Normal', style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: _field('dl', 'Download')),
                    const SizedBox(width: 12),
                    Expanded(child: _field('up', 'Upload')),
                  ],
                ),
                const SizedBox(height: 16),
                Text('Alternative', style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: _field('altDl', 'Download')),
                    const SizedBox(width: 12),
                    Expanded(child: _field('altUp', 'Upload')),
                  ],
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    key: const ValueKey('saveLimits'),
                    onPressed: _saving || !_complete ? null : _saveLimits,
                    child: _saving
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Save limits'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
            title: 'Modes',
            child: Column(
              children: [
                SwitchListTile(
                  key: const ValueKey('altSwitch'),
                  secondary: const Icon(Icons.slow_motion_video),
                  title: const Text('Alternative speed limits'),
                  subtitle: Text(
                    schedule != null && schedule.enabled
                        ? '${scheduleLabel(schedule)}. Configure the schedule in qBittorrent; it overrides manual '
                              'changes at the next boundary.'
                        : 'No schedule. Configure the schedule in qBittorrent.',
                  ),
                  value: alt,
                  onChanged: _pendingAlt != null
                      ? null
                      : (v) async {
                          setState(() => _pendingAlt = v);
                          await _run(
                            () => ref.read(activityApiProvider).setAltSpeed(v),
                            v ? 'Alternative limits on' : 'Alternative limits off',
                          );
                          if (mounted) setState(() => _pendingAlt = null);
                        },
                ),
                SwitchListTile(
                  key: const ValueKey('sessionSwitch'),
                  secondary: const Icon(Icons.pause_circle_outline),
                  title: const Text('Pause all torrents'),
                  subtitle: const Text('Pauses the whole qBittorrent session'),
                  value: paused,
                  onChanged: _pendingPaused != null
                      ? null
                      : (v) async {
                          setState(() => _pendingPaused = v);
                          await _run(
                            () => ref.read(activityApiProvider).setSessionPaused(v),
                            v ? 'Session paused' : 'Session resumed',
                          );
                          if (mounted) setState(() => _pendingPaused = null);
                        },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Statistics',
            child: KeyValueList(
              entries: [
                KeyValue.widget(
                  'Connection',
                  Align(
                    alignment: Alignment.centerLeft,
                    child: StatusChip(
                      label: connectionLabel(t.connectionStatus),
                      tone: connectionTone(t.connectionStatus),
                      dense: true,
                    ),
                  ),
                ),
                KeyValue('Effective limits', '↓ ${_limitText(t.dlLimitBps)} · ↑ ${_limitText(t.upLimitBps)}'),
                KeyValue('Global ratio', t.globalRatio.toStringAsFixed(2)),
                KeyValue('All-time download', formatBytes(t.allTimeDownloadedBytes)),
                KeyValue('All-time upload', formatBytes(t.allTimeUploadedBytes)),
                KeyValue(
                  'This session',
                  '↓ ${formatBytes(t.sessionDownloadedBytes)} · ↑ ${formatBytes(t.sessionUploadedBytes)}',
                ),
                KeyValue('Free space', formatBytes(t.freeSpaceBytes)),
                KeyValue('DHT nodes', formatCount(t.dhtNodes)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              'Updated ${formatRelative(t.updatedAt)}',
              style: theme.textTheme.labelSmall?.copyWith(color: StatusColors.of(context).neutral),
            ),
          ),
        ],
      ),
    );
  }

  static String _limitText(int bps) => bps <= 0 ? 'unlimited' : formatBps(bps);
}
