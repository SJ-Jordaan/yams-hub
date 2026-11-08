/// The Activity header (APP.md §6.1): speeds, the alt-speed turtle toggle
/// with its schedule caption, the connection dot and the VPN chip.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_exception.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/activity_api.dart';
import '../providers/activity_providers.dart';
import 'activity_format.dart';
import 'vpn_sheet.dart';

class TransferBar extends ConsumerStatefulWidget {
  const TransferBar({super.key});

  @override
  ConsumerState<TransferBar> createState() => _TransferBarState();
}

class _TransferBarState extends ConsumerState<TransferBar> {
  bool? _pendingAlt;

  Future<void> _setAlt(bool enabled) async {
    setState(() => _pendingAlt = enabled);
    try {
      await ref.read(activityApiProvider).setAltSpeed(enabled);
      if (mounted) context.showSnack(enabled ? 'Alternative speed limits on' : 'Alternative speed limits off');
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) {
        setState(() => _pendingAlt = null);
        ref.invalidate(transferProvider);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final admin = ref.watch(isAdminProvider);
    final value = ref.watch(transferProvider);
    final t = value.value;
    final colors = StatusColors.of(context);
    final style = theme.textTheme.titleMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);

    Widget content;
    if (t == null) {
      content = value.hasError
          ? Row(
              children: [
                Icon(Icons.cloud_off, size: 18, color: colors.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    ApiException.from(value.error!).message,
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            )
          : const Row(children: [SkeletonBox(width: 90), SizedBox(width: 16), SkeletonBox(width: 90)]);
    } else {
      final alt = _pendingAlt ?? t.altSpeedEnabled;
      final schedule = t.schedule;
      final showAlt = admin || alt;
      final caption = schedule != null && schedule.enabled ? scheduleLabel(schedule) : null;
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Tooltip(
                message: connectionLabel(t.connectionStatus),
                child: StatusDot(tone: connectionTone(t.connectionStatus)),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SpeedText(bps: t.dlBps, direction: SpeedDirection.down, style: style),
                      const SizedBox(width: 14),
                      SpeedText(bps: t.upBps, direction: SpeedDirection.up, style: style),
                      if (t.sessionPaused) ...[
                        const SizedBox(width: 8),
                        const StatusChip(label: 'Paused', tone: StatusTone.warning, dense: true),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const VpnChip(),
            ],
          ),
          if (showAlt)
            Row(
              children: [
                SizedBox(
                  height: 28,
                  child: IconButton(
                    key: const ValueKey('altSpeedToggle'),
                    tooltip: alt ? 'Alternative speed limits on' : 'Alternative speed limits off',
                    padding: EdgeInsets.zero,
                    iconSize: 20,
                    visualDensity: VisualDensity.compact,
                    isSelected: alt,
                    color: alt ? colors.info : null,
                    icon: const Icon(Icons.slow_motion_video),
                    onPressed: !admin || _pendingAlt != null ? null : () => _setAlt(!alt),
                  ),
                ),
                Expanded(
                  child: Tooltip(
                    message: 'The schedule overrides manual changes at the next boundary',
                    triggerMode: TooltipTriggerMode.tap,
                    child: Text(
                      [alt ? 'Alt speed on' : 'Alt speed off', ?caption].join(' · '),
                      style: theme.textTheme.labelSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
        ],
      );
    }
    return Padding(padding: const EdgeInsets.fromLTRB(16, 4, 8, 4), child: content);
  }
}

/// The VPN state chip; tap opens the VPN sheet.
class VpnChip extends ConsumerWidget {
  const VpnChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(vpnProvider);
    final v = value.value;
    final tone = v == null ? (value.hasError ? StatusTone.error : StatusTone.neutral) : vpnTone(v.status);
    final label = v == null
        ? 'VPN'
        : v.status == VpnConnectionState.down
        ? 'VPN down'
        : (v.country ?? 'VPN');
    return ActionChip(
      key: const ValueKey('vpnChip'),
      avatar: StatusDot(tone: tone),
      label: Text(label),
      visualDensity: VisualDensity.compact,
      onPressed: () => showVpnSheet(context),
    );
  }
}
