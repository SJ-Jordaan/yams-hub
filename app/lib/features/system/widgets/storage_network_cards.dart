/// Storage card (volume bar, RAID panel, disk I/O) and Network card (host
/// interfaces, Tailscale remote use) of the System screen (APP.md §12).
library;

import 'package:flutter/material.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import 'rate_text.dart';
import 'system_format.dart';

class StorageCard extends StatelessWidget {
  const StorageCard({super.key, required this.metrics});

  final HostMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final io = metrics.diskIo;
    return SectionCard(
      title: 'Storage',
      icon: Icons.storage,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final md in metrics.raid)
            if (!md.healthy) ...[
              _Banner(
                key: Key('system.raidBanner.${md.device}'),
                tone: StatusTone.error,
                icon: Icons.error,
                text:
                    '${md.device} is ${md.state == 'active' ? 'degraded' : md.state}. '
                    '${md.redundant ? 'Replace the failed disk soon.' : 'The volume may be unavailable; check the disks in UGOS.'}',
              ),
              const SizedBox(height: 12),
            ],
          if (metrics.storage.isEmpty)
            Text('Volume usage unavailable (statvfs of the data mount failed)', style: muted)
          else
            for (final s in metrics.storage) ...[
              ProgressBar(
                key: Key('system.volume.${s.mount}'),
                value: s.usedPercent / 100,
                label: s.mount,
                trailing:
                    '${formatBytes(s.usedBytes)} / ${formatBytes(s.totalBytes)} · ${formatPercent(s.usedPercent)}',
                tone: toneForUsage(s.usedPercent / 100),
                height: 8,
              ),
              const SizedBox(height: 4),
              Text('${formatBytes(s.freeBytes)} free', style: muted),
              const SizedBox(height: 12),
            ],
          for (final md in metrics.raid) ...[_RaidPanel(raid: md), const SizedBox(height: 8)],
          if (metrics.raid.isEmpty) Text('No md RAID arrays found', style: muted),
          if (io != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.speed, size: 16, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Disk  read ${formatBps(io.readBps)} · write ${formatBps(io.writeBps)}', style: muted),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _RaidPanel extends StatelessWidget {
  const _RaidPanel({required this.raid});

  final HostRaid raid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final tone = raid.healthy ? StatusTone.ok : StatusTone.error;
    final line = [
      raidLevelLabel(raid.level),
      raid.device,
      raid.state,
      if (raid.members.isNotEmpty) raid.members.join(' + '),
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(raid.healthy ? Icons.check_circle : Icons.error, size: 18, color: colors.forTone(tone)),
            const SizedBox(width: 8),
            Expanded(child: Text(line, style: theme.textTheme.bodyMedium)),
          ],
        ),
        if (!raid.redundant) ...[
          const SizedBox(height: 8),
          const _Banner(
            key: Key('system.noRedundancy'),
            tone: StatusTone.warning,
            icon: Icons.info_outline,
            text: noRedundancyText,
          ),
        ],
      ],
    );
  }
}

class NetworkCard extends StatelessWidget {
  const NetworkCard({super.key, required this.metrics});

  final HostMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return SectionCard(
      title: 'Network',
      icon: Icons.lan_outlined,
      child: !metrics.sources.hostNetwork || metrics.network.isEmpty
          ? Row(
              children: [
                Icon(Icons.info_outline, size: 16, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(child: Text(hostNetworkUnavailableText, style: muted)),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < metrics.network.length; i++) ...[
                  if (i > 0) const Divider(height: 20),
                  _InterfaceRow(net: metrics.network[i]),
                ],
              ],
            ),
    );
  }
}

class _InterfaceRow extends StatelessWidget {
  const _InterfaceRow({required this.net});

  final HostNetwork net;

  bool get _tailscale => net.interfaceName.startsWith('tailscale');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final remote = _tailscale && net.rxBps + net.txBps >= tailscaleRemoteUseBps;
    return Row(
      key: Key('system.iface.${net.interfaceName}'),
      children: [
        Icon(_tailscale ? Icons.vpn_lock : Icons.settings_ethernet, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(child: Text(net.interfaceName, style: theme.textTheme.titleSmall)),
                  if (_tailscale) ...[
                    const SizedBox(width: 8),
                    StatusChip(
                      label: remote ? 'Remote use' : 'Idle',
                      tone: remote ? StatusTone.info : StatusTone.neutral,
                      dense: true,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text('Received ${formatBytes(net.rxTotalBytes)} · sent ${formatBytes(net.txTotalBytes)}', style: muted),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            RateText(rxBps: net.rxBps, style: theme.textTheme.bodyMedium),
            RateText(txBps: net.txBps, style: theme.textTheme.bodyMedium),
          ],
        ),
      ],
    );
  }
}

/// A tinted note box (persistent RAID0 note, red "not active" banner).
class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.tone, required this.icon, required this.text});

  final StatusTone tone;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final color = StatusColors.of(context).forTone(tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
