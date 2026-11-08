/// Host card (APP.md §12): CPU % with per-core bars, load averages, package
/// and core temperatures, memory and swap bars, uptime, CPU model, and the
/// history charts.
library;

import 'package:flutter/material.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import 'history_charts.dart';
import 'system_format.dart';

class HostCard extends StatelessWidget {
  const HostCard({super.key, required this.metrics});

  final HostMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cpu = metrics.cpu;
    final mem = metrics.memory;
    final subtitle = [
      ?metrics.hostname,
      ?cpu?.model,
      if (cpu?.cores case final n?) '$n cores',
      if (metrics.uptimeSeconds case final s?) 'up ${formatSeconds(s)}',
    ].join(' · ');

    return SectionCard(
      title: 'Host',
      icon: Icons.memory,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (subtitle.isNotEmpty)
            Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          if (cpu != null) _CpuSection(cpu: cpu, temperatureSource: metrics.sources.temperature),
          if (mem != null) ...[
            const SizedBox(height: 16),
            ProgressBar(
              key: const Key('system.memory'),
              value: mem.usedRatio,
              label: 'Memory',
              trailing: '${formatBytes(mem.usedBytes)} / ${formatBytes(mem.totalBytes)}',
              tone: toneForUsage(mem.usedRatio),
            ),
            if (mem.swapTotalBytes > 0) ...[
              const SizedBox(height: 10),
              ProgressBar(
                value: mem.swapUsedRatio,
                label: 'Swap',
                trailing: '${formatBytes(mem.swapUsedBytes)} / ${formatBytes(mem.swapTotalBytes)}',
                tone: toneForUsage(mem.swapUsedRatio),
              ),
            ],
          ],
          const SizedBox(height: 20),
          const Divider(height: 1),
          const SizedBox(height: 16),
          HostHistoryCharts(sources: metrics.sources),
        ],
      ),
    );
  }
}

class _CpuSection extends StatelessWidget {
  const _CpuSection({required this.cpu, required this.temperatureSource});

  final HostCpu cpu;
  final bool temperatureSource;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final loads = [cpu.load1, cpu.load5, cpu.load15];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              cpu.percent == null ? '–' : formatPercent(cpu.percent),
              key: const Key('system.cpuPercent'),
              style: theme.textTheme.headlineMedium?.copyWith(color: colors.forTone(toneForCpu(cpu.percent))),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('CPU', style: muted),
            ),
            const SizedBox(width: 12),
            if (loads.every((l) => l != null))
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Tooltip(
                    message: 'Load average over 1, 5 and 15 minutes',
                    child: Text(
                      'Load ${loads.map((l) => l!.toStringAsFixed(2)).join(' · ')}',
                      style: muted,
                      textAlign: TextAlign.end,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (cpu.perCorePercent.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              for (var i = 0; i < cpu.perCorePercent.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: ProgressBar(
                    value: cpu.perCorePercent[i] / 100,
                    label: 'C$i',
                    trailing: formatPercent(cpu.perCorePercent[i]),
                    height: 4,
                    tone: toneForCpu(cpu.perCorePercent[i]),
                  ),
                ),
              ],
            ],
          ),
        ],
        const SizedBox(height: 12),
        if (temperatureSource && cpu.packageTempC != null)
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatusChip(
                key: const Key('system.packageTemp'),
                icon: Icons.thermostat,
                label: 'Package ${formatCelsius(cpu.packageTempC)}',
                tone: toneForTemperature(cpu.packageTempC),
              ),
              if (cpu.coreTempsC.isNotEmpty)
                Text('Cores ${cpu.coreTempsC.map((c) => c.round()).join(' / ')} °C', style: muted),
            ],
          )
        else
          Row(
            children: [
              Icon(Icons.thermostat, size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(child: Text(temperatureUnavailableText, style: muted)),
            ],
          ),
      ],
    );
  }
}
