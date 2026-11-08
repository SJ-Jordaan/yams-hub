/// VPN details sheet (APP.md §6.1): public IP, location, forwarded port vs
/// listen port, gluetun health and "Restart VPN" (admin, a containers job).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/activity_api.dart';
import '../providers/activity_providers.dart';
import 'activity_format.dart';

Future<void> showVpnSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  useSafeArea: true,
  isScrollControlled: true,
  builder: (_) => const VpnSheet(),
);

class VpnSheet extends ConsumerStatefulWidget {
  const VpnSheet({super.key});

  @override
  ConsumerState<VpnSheet> createState() => _VpnSheetState();
}

class _VpnSheetState extends ConsumerState<VpnSheet> {
  String? _jobId;
  bool _starting = false;

  Future<void> _restart() async {
    final ok = await ConfirmDialog.show(
      context,
      title: 'Restart VPN?',
      message:
          'Gluetun restarts and qBittorrent loses network until it is back; '
          'the hub restarts qBittorrent afterwards.',
      confirmLabel: 'Restart',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _starting = true);
    try {
      final job = await ref.read(activityApiProvider).restartGluetun();
      if (mounted) setState(() => _jobId = job.id);
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final admin = ref.watch(isAdminProvider);
    final value = ref.watch(vpnProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: AsyncValueView<VpnStatus>(
        value: value,
        showStaleBanner: false,
        compactError: true,
        onRetry: () => ref.invalidate(vpnProvider),
        loading: const SkeletonList(count: 4, padding: EdgeInsets.zero),
        data: (context, v) {
          final location = [?v.city, ?v.region, ?v.country].join(', ');
          final colors = StatusColors.of(context);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.vpn_lock, color: colors.forTone(vpnTone(v.status))),
                  const SizedBox(width: 12),
                  Expanded(child: Text('VPN', style: theme.textTheme.titleLarge)),
                  StatusChip(label: _stateLabel(v.status), tone: vpnTone(v.status)),
                ],
              ),
              const SizedBox(height: 16),
              KeyValueList(
                entries: [
                  KeyValue('Public IP', v.publicIp ?? 'None (reconnecting?)'),
                  KeyValue('Location', location),
                  KeyValue('Provider', v.organization),
                  KeyValue('Forwarded port', v.forwardedPort?.toString() ?? 'None yet'),
                  KeyValue('qBittorrent port', v.listenPort?.toString() ?? '–'),
                  KeyValue.widget(
                    'Port in sync',
                    Align(
                      alignment: Alignment.centerLeft,
                      child: StatusChip(
                        label: v.portInSync ? 'Yes' : 'No',
                        tone: v.portInSync ? StatusTone.ok : StatusTone.warning,
                        dense: true,
                      ),
                    ),
                  ),
                  KeyValue('qBittorrent', v.qbitConnection),
                  KeyValue('Gluetun health', v.gluetunHealth.name),
                  KeyValue('Checked', formatRelative(v.checkedAt)),
                ],
              ),
              if (admin) ...[
                const SizedBox(height: 16),
                if (_jobId case final id?)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: JobChip(
                      id,
                      onDone: (_) {
                        if (!mounted) return;
                        ref
                          ..invalidate(vpnProvider)
                          ..invalidate(transferProvider);
                      },
                      onLost: (_) {
                        if (!mounted) return;
                        setState(() => _jobId = null);
                        ref.invalidate(vpnProvider);
                      },
                    ),
                  )
                else
                  OutlinedButton.icon(
                    key: const ValueKey('restartVpn'),
                    onPressed: _starting ? null : _restart,
                    icon: _starting
                        ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.restart_alt),
                    label: const Text('Restart VPN'),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

  static String _stateLabel(VpnConnectionState s) => switch (s) {
    VpnConnectionState.connected => 'Connected',
    VpnConnectionState.degraded => 'Degraded',
    VpnConnectionState.down => 'Down',
    VpnConnectionState.unknown => 'Unknown',
  };
}
