/// Labels and tones shared by the system widgets.
library;

import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_models/yams_models.dart';

/// rx+tx on `tailscale0` above which the screen says "Remote use" (the
/// gateway uses the same threshold for the dashboard's Tailscale dot).
const tailscaleRemoteUseBps = 2048;

/// Missing-source texts (APP.md §12).
const temperatureUnavailableText = 'CPU temperature unavailable (no coretemp sensor under /sys/class/hwmon)';
const hostNetworkUnavailableText = 'Host network unavailable (mount /proc/1/net/dev into the hub)';

/// Persistent RAID0 note (APP.md §12).
const noRedundancyText = 'No redundancy: one disk failure loses all data. Keep backups.';

/// `48 °C`.
String formatCelsius(double? c) => c == null ? '–' : '${c.round()} °C';

/// Temperature tone: amber from 80 °C, red from 95 °C (the N100 throttles at
/// 105 °C).
StatusTone toneForTemperature(double? c) {
  if (c == null) return StatusTone.neutral;
  if (c >= 95) return StatusTone.error;
  if (c >= 80) return StatusTone.warning;
  return StatusTone.ok;
}

/// Fill tone of a usage bar: amber from 80 %, red from 95 %.
StatusTone toneForUsage(double ratio) {
  if (ratio >= 0.95) return StatusTone.error;
  if (ratio >= 0.8) return StatusTone.warning;
  return StatusTone.ok;
}

/// CPU tone: amber from 80 %.
StatusTone toneForCpu(double? percent) => percent != null && percent >= 80 ? StatusTone.warning : StatusTone.ok;

/// `RAID0`.
String raidLevelLabel(String level) => level == 'unknown' ? 'RAID' : level.toUpperCase();

/// `RAID0 · active`.
String raidChipLabel(String level, String state) => '${raidLevelLabel(level)} · $state';

StatusTone toneForUptime(UptimeStatus s) => switch (s) {
  UptimeStatus.up => StatusTone.ok,
  UptimeStatus.down => StatusTone.error,
  UptimeStatus.pending => StatusTone.warning,
  UptimeStatus.maintenance => StatusTone.info,
  UptimeStatus.unknown => StatusTone.neutral,
};

String uptimeStatusLabel(UptimeStatus s) => switch (s) {
  UptimeStatus.up => 'Up',
  UptimeStatus.down => 'Down',
  UptimeStatus.pending => 'Pending',
  UptimeStatus.maintenance => 'Maintenance',
  UptimeStatus.unknown => 'No data',
};

/// `99.6 %` from a 0..1 ratio (two decimals below 99.95 % would be noise;
/// one decimal reads well on a phone).
String formatUptimeRatio(double? ratio) {
  if (ratio == null) return '–';
  final pct = ratio * 100;
  if (pct >= 99.95) return '100 %';
  return '${pct.toStringAsFixed(1)} %';
}
