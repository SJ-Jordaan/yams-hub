/// Parsers for the procfs files the host sampler reads
/// (integrations/system.md §4). Every parser is pure and lenient: lines it
/// does not understand are skipped, and missing values yield null.
library;

/// Jiffies of one `cpu` line of `/proc/stat`.
final class CpuTimes {
  const CpuTimes({required this.busy, required this.total});

  /// user + nice + system + irq + softirq + steal.
  final int busy;

  /// busy + idle + iowait.
  final int total;

  /// Busy share 0..100 between [previous] and this sample; null when the
  /// counters did not advance (or went backwards).
  double? percentSince(CpuTimes previous) {
    final dTotal = total - previous.total;
    final dBusy = busy - previous.busy;
    if (dTotal <= 0 || dBusy < 0) return null;
    return (dBusy / dTotal * 100).clamp(0, 100).toDouble();
  }
}

/// `/proc/stat`: the aggregate `cpu` line and the per-core `cpuN` lines.
final class ProcStat {
  const ProcStat({required this.total, required this.cores});

  final CpuTimes total;

  /// Indexed by core number.
  final List<CpuTimes> cores;

  static ProcStat? parse(String text) {
    CpuTimes? total;
    final cores = <int, CpuTimes>{};
    for (final line in text.split('\n')) {
      if (!line.startsWith('cpu')) continue;
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 5) continue;
      final values = [for (final p in parts.skip(1)) int.tryParse(p) ?? 0];
      int at(int i) => i < values.length ? values[i] : 0;
      // user nice system idle iowait irq softirq steal guest guest_nice
      final busy = at(0) + at(1) + at(2) + at(5) + at(6) + at(7);
      final times = CpuTimes(busy: busy, total: busy + at(3) + at(4));
      final name = parts.first;
      if (name == 'cpu') {
        total = times;
      } else if (int.tryParse(name.substring(3)) case final n?) {
        cores[n] = times;
      }
    }
    if (total == null) return null;
    final ordered = cores.keys.toList()..sort();
    return ProcStat(total: total, cores: [for (final k in ordered) cores[k]!]);
  }
}

/// `/proc/meminfo` values in bytes.
final class MemInfo {
  const MemInfo({
    required this.totalBytes,
    required this.availableBytes,
    required this.swapTotalBytes,
    required this.swapFreeBytes,
  });

  final int totalBytes;
  final int availableBytes;
  final int swapTotalBytes;
  final int swapFreeBytes;

  int get usedBytes => (totalBytes - availableBytes).clamp(0, totalBytes);
  int get swapUsedBytes =>
      (swapTotalBytes - swapFreeBytes).clamp(0, swapTotalBytes);

  static MemInfo? parse(String text) {
    final kb = <String, int>{};
    for (final line in text.split('\n')) {
      final i = line.indexOf(':');
      if (i <= 0) continue;
      final value = line.substring(i + 1).trim().split(RegExp(r'\s+')).first;
      final n = int.tryParse(value);
      if (n != null) kb[line.substring(0, i).trim()] = n;
    }
    final total = kb['MemTotal'];
    if (total == null) return null;
    // Kernels before 3.14 have no MemAvailable; approximate it.
    final available =
        kb['MemAvailable'] ??
        (kb['MemFree'] ?? 0) + (kb['Buffers'] ?? 0) + (kb['Cached'] ?? 0);
    return MemInfo(
      totalBytes: total * 1024,
      availableBytes: available * 1024,
      swapTotalBytes: (kb['SwapTotal'] ?? 0) * 1024,
      swapFreeBytes: (kb['SwapFree'] ?? 0) * 1024,
    );
  }
}

/// `/proc/loadavg` → `[load1, load5, load15]`.
List<double>? parseLoadAvg(String text) {
  final parts = text.trim().split(RegExp(r'\s+'));
  if (parts.length < 3) return null;
  final values = [for (final p in parts.take(3)) double.tryParse(p)];
  if (values.any((v) => v == null)) return null;
  return [for (final v in values) v!];
}

/// `/proc/uptime` → whole seconds.
int? parseUptime(String text) {
  final first = text.trim().split(RegExp(r'\s+')).first;
  return double.tryParse(first)?.floor();
}

/// The first `model name` of `/proc/cpuinfo`.
String? parseCpuModel(String text) {
  for (final line in text.split('\n')) {
    final i = line.indexOf(':');
    if (i <= 0) continue;
    if (line.substring(0, i).trim() == 'model name') {
      final v = line.substring(i + 1).trim();
      if (v.isNotEmpty) return v;
    }
  }
  return null;
}

/// One md array of `/proc/mdstat`.
final class MdArray {
  const MdArray({
    required this.device,
    required this.state,
    required this.level,
    required this.members,
    required this.failedMembers,
    required this.missingMirrors,
  });

  final String device;

  /// `active`, `inactive`, ...
  final String state;

  /// `raid0`, `raid1`, `linear`, ... (`unknown` for inactive arrays).
  final String level;
  final List<String> members;

  /// Members flagged `(F)`.
  final List<String> failedMembers;

  /// `_` slots in the `[UU_]` status map.
  final int missingMirrors;

  static const _redundantLevels = {
    'raid1',
    'raid4',
    'raid5',
    'raid6',
    'raid10',
  };

  bool get redundant => _redundantLevels.contains(level);

  bool get healthy =>
      state == 'active' && failedMembers.isEmpty && missingMirrors == 0;
}

final _mdHeader = RegExp(r'^(md\w*)\s*:\s*(.*)$');
final _mdMember = RegExp(r'^([A-Za-z0-9_.-]+)\[\d+\]((?:\([A-Z]\))*)$');
final _mdStatusMap = RegExp(r'\[([U_]+)\]');
final _mdLevel = RegExp(r'^(raid\d+|linear|multipath|faulty)$');

/// Parses `/proc/mdstat`; `[]` when there is no md array.
List<MdArray> parseMdstat(String text) {
  final arrays = <MdArray>[];
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final m = _mdHeader.firstMatch(lines[i].trim());
    if (m == null) continue;
    final tokens = m[2]!.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
    String? state;
    var level = 'unknown';
    final members = <String>[];
    final failed = <String>[];
    for (final t in tokens) {
      if (state == null) {
        state = t;
        continue;
      }
      if (t.startsWith('(')) continue; // (auto-read-only), (read-only)
      if (_mdLevel.hasMatch(t)) {
        level = t;
        continue;
      }
      final member = _mdMember.firstMatch(t);
      if (member != null) {
        members.add(member[1]!);
        if (member[2]!.contains('(F)')) failed.add(member[1]!);
      }
    }
    // The detail lines follow until the next blank or md line.
    var missing = 0;
    for (var j = i + 1; j < lines.length; j++) {
      final line = lines[j];
      if (line.trim().isEmpty || _mdHeader.hasMatch(line.trim())) break;
      final map = _mdStatusMap.firstMatch(line);
      if (map != null) missing += '_'.allMatches(map[1]!).length;
    }
    arrays.add(
      MdArray(
        device: m[1]!,
        state: state ?? 'unknown',
        level: level,
        members: members,
        failedMembers: failed,
        missingMirrors: missing,
      ),
    );
  }
  return arrays;
}

/// Sector counters of one `/proc/diskstats` device, in bytes.
final class DiskCounters {
  const DiskCounters({required this.readBytes, required this.writtenBytes});

  final int readBytes;
  final int writtenBytes;
}

/// The counters of [device] (`dm-0`) in `/proc/diskstats`; sectors are
/// always 512 bytes there.
DiskCounters? parseDiskstats(String text, String device) {
  for (final line in text.split('\n')) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 10 || parts[2] != device) continue;
    final read = int.tryParse(parts[5]);
    final written = int.tryParse(parts[9]);
    if (read == null || written == null) return null;
    return DiskCounters(readBytes: read * 512, writtenBytes: written * 512);
  }
  return null;
}

/// Byte counters of one interface of `/proc/net/dev`.
final class NetCounters {
  const NetCounters({
    required this.interfaceName,
    required this.rxBytes,
    required this.txBytes,
  });

  final String interfaceName;
  final int rxBytes;
  final int txBytes;
}

/// Parses `/proc/net/dev` (`iface: rx_bytes ... (8 columns) tx_bytes ...`).
List<NetCounters> parseNetDev(String text) {
  final out = <NetCounters>[];
  for (final line in text.split('\n')) {
    final i = line.indexOf(':');
    if (i <= 0) continue;
    final name = line.substring(0, i).trim();
    if (name.isEmpty || name.contains(' ') || name.contains('|')) continue;
    final cols = line.substring(i + 1).trim().split(RegExp(r'\s+'));
    if (cols.length < 9) continue;
    final rx = int.tryParse(cols[0]);
    final tx = int.tryParse(cols[8]);
    if (rx == null || tx == null) continue;
    out.add(NetCounters(interfaceName: name, rxBytes: rx, txBytes: tx));
  }
  return out;
}

/// Interfaces that are host NICs or tunnels rather than Docker plumbing or
/// loopback (`eth0`, `tailscale0`, `wlan0`; not `lo`, `docker0`, `br-…`,
/// `veth…`).
bool isHostInterface(String name) =>
    name != 'lo' &&
    !name.startsWith('veth') &&
    !name.startsWith('docker') &&
    !name.startsWith('br-') &&
    !name.startsWith('virbr');
