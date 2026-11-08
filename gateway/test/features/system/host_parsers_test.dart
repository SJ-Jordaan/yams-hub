import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yams_hub_gateway/src/features/system/host/hwmon.dart';
import 'package:yams_hub_gateway/src/features/system/host/metric_history.dart';
import 'package:yams_hub_gateway/src/features/system/host/proc_parsers.dart';
import 'package:yams_hub_gateway/src/features/system/host/statvfs.dart';

import '../../support/test_hub.dart';
import 'host_fixture.dart';

void main() {
  final s = hostSnapshot();
  String text(String key) => s[key]! as String;

  group('/proc/stat', () {
    test('busy share between the two snapshot samples', () {
      final t0 = ProcStat.parse(text('proc_stat_t0'))!;
      final t1 = ProcStat.parse(text('proc_stat_t1'))!;
      expect(t0.cores, hasLength(4));
      // busy: user 51 + nice 0 + system 39 + irq 0 + softirq 6 + steal 0 = 96;
      // total = 96 + idle 318 + iowait 20 = 434.
      expect(t1.total.percentSince(t0.total), closeTo(96 / 434 * 100, 1e-9));
      for (var i = 0; i < 4; i++) {
        final pct = t1.cores[i].percentSince(t0.cores[i])!;
        expect(pct, inInclusiveRange(0, 100));
      }
    });

    test('no delta or counters going backwards yield null', () {
      final t0 = ProcStat.parse(text('proc_stat_t0'))!;
      final t1 = ProcStat.parse(text('proc_stat_t1'))!;
      expect(t0.total.percentSince(t0.total), isNull);
      expect(t0.total.percentSince(t1.total), isNull);
    });

    test('garbage has no cpu line', () {
      expect(ProcStat.parse('intr 1 2 3\n'), isNull);
      expect(ProcStat.parse(''), isNull);
    });
  });

  test('/proc/meminfo: used = MemTotal - MemAvailable, in bytes', () {
    final m = MemInfo.parse(text('proc_meminfo'))!;
    expect(m.totalBytes, 7870168 * 1024);
    expect(m.availableBytes, 2866816 * 1024);
    expect(m.usedBytes, (7870168 - 2866816) * 1024);
    expect(m.swapTotalBytes, 6029292 * 1024);
    expect(m.swapUsedBytes, (6029292 - 5271900) * 1024);
    expect(MemInfo.parse('MemFree: 1 kB\n'), isNull);
  });

  test('loadavg, uptime and cpuinfo', () {
    expect(parseLoadAvg(text('proc_loadavg')), [0.60, 0.86, 1.02]);
    expect(parseLoadAvg('0.5'), isNull);
    expect(parseUptime(text('proc_uptime')), 10322);
    expect(parseCpuModel(text('proc_cpuinfo_model')), 'Intel(R) N100');
    expect(parseCpuModel('processor : 0\n'), isNull);
  });

  group('/proc/mdstat', () {
    test('Zenith: RAID0 over two disks, active, no redundancy', () {
      final arrays = parseMdstat(text('proc_mdstat'));
      expect(arrays, hasLength(1));
      final md = arrays.single;
      expect(md.device, 'md1');
      expect(md.state, 'active');
      expect(md.level, 'raid0');
      expect(md.members, ['sda2', 'sdb2']);
      expect(md.redundant, isFalse);
      expect(md.healthy, isTrue);
    });

    test('a degraded mirror, a failed member and an inactive array', () {
      const mdstat = '''
Personalities : [raid1] [raid0]
md0 : active raid1 sdb1[1](F) sda1[0]
      976630464 blocks super 1.2 [2/1] [U_]
      bitmap: 2/8 pages [8KB], 65536KB chunk

md2 : active (auto-read-only) raid1 sdc1[0] sdd1[1]
      976630464 blocks super 1.2 [2/2] [UU]

md3 : inactive sde1[0](S)
      976630464 blocks super 1.2

unused devices: <none>
''';
      final arrays = parseMdstat(mdstat);
      expect([for (final a in arrays) a.device], ['md0', 'md2', 'md3']);
      expect(arrays[0].failedMembers, ['sdb1']);
      expect(arrays[0].missingMirrors, 1);
      expect(arrays[0].healthy, isFalse);
      expect(arrays[0].redundant, isTrue);
      expect(arrays[1].healthy, isTrue);
      expect(arrays[1].members, ['sdc1', 'sdd1']);
      expect(arrays[2].state, 'inactive');
      expect(arrays[2].level, 'unknown');
      expect(arrays[2].healthy, isFalse);
    });

    test('no arrays', () {
      expect(
        parseMdstat('Personalities : \nunused devices: <none>\n'),
        isEmpty,
      );
    });
  });

  test('/proc/diskstats dm-0 sectors are 512 bytes (synthetic sample)', () {
    final c = parseDiskstats(
      systemData('proc_diskstats_t0.synthetic.txt'),
      'dm-0',
    )!;
    expect(c.readBytes, 240512390 * 512);
    expect(c.writtenBytes, 156200704 * 512);
    expect(
      parseDiskstats(systemData('proc_diskstats_t0.synthetic.txt'), 'dm-9'),
      isNull,
    );
  });

  group('net/dev', () {
    test('host counters: eth0 and tailscale0 are host interfaces', () {
      final all = parseNetDev(text('host_proc_1_net_dev'));
      final names = [for (final c in all) c.interfaceName];
      expect(
        names,
        containsAll(['lo', 'eth0', 'tailscale0', 'docker0', 'br-c2d51ddeb5f4']),
      );
      final eth0 = all.firstWhere((c) => c.interfaceName == 'eth0');
      expect(eth0.rxBytes, 2333451724);
      expect(eth0.txBytes, 7631403758);
      final ts = all.firstWhere((c) => c.interfaceName == 'tailscale0');
      expect((ts.rxBytes, ts.txBytes), (86, 15805));
      expect(
        [
          for (final n in names)
            if (isHostInterface(n)) n,
        ],
        ['eth0', 'tailscale0'],
      );
    });

    test('a counter glued to the colon still parses', () {
      final c = parseNetDev('eth0:123 1 0 0 0 0 0 0 456 2 0 0 0 0 0 0\n')
          .single;
      expect((c.rxBytes, c.txBytes), (123, 456));
    });
  });

  group('hwmon', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('yh-hwmon-'));
    tearDown(() => tmp.delete(recursive: true));

    test('follows relative symlinks, selects coretemp by name, skips the dangling entry', () {
      final sys = p.join(tmp.path, 'sys');
      writeHwmonTree(sys);
      expect(
        Link(p.join(sys, 'class', 'hwmon', 'hwmon1')).targetSync(),
        startsWith('../../devices/'),
      );
      final temps = HwmonReader(sys).read()!;
      expect(temps.packageC, 68.0);
      expect(temps.coresC, [65.0, 66.0, 63.0, 65.0]);
    });

    test('no coretemp → null; missing class dir → null', () {
      final sys = p.join(tmp.path, 'sys');
      writeHwmonTree(sys, coretemp: false);
      expect(HwmonReader(sys).read(), isNull);
      expect(HwmonReader(p.join(tmp.path, 'nothing')).read(), isNull);
    });

    test('unlabelled sensors: temp1 is the package, temp2.. the cores', () {
      final dev = Directory(
        p.join(
          tmp.path,
          'sys',
          'devices',
          'platform',
          'coretemp.0',
          'hwmon',
          'hwmon3',
        ),
      )..createSync(recursive: true);
      File(p.join(dev.path, 'name')).writeAsStringSync('coretemp\n');
      File(p.join(dev.path, 'temp1_input')).writeAsStringSync('50000\n');
      File(p.join(dev.path, 'temp2_input')).writeAsStringSync('47500\n');
      File(p.join(dev.path, 'temp3_input')).writeAsStringSync('48000\n');
      Directory(p.join(tmp.path, 'sys', 'class', 'hwmon'))
          .createSync(recursive: true);
      Link(p.join(tmp.path, 'sys', 'class', 'hwmon', 'hwmon3'))
          .createSync('../../devices/platform/coretemp.0/hwmon/hwmon3');
      final temps = HwmonReader(p.join(tmp.path, 'sys')).read()!;
      expect(temps.packageC, 50.0);
      expect(temps.coresC, [47.5, 48.0]);
    });
  });

  group('statvfs (ffi)', () {
    test('df-style numbers', () {
      expect(zenithVolume.totalBytes, 7904532574208);
      expect(zenithVolume.usedBytes, 3765233148 * 1024);
      expect(zenithVolume.usedPercent, closeTo(48.78, 0.01));
    });

    test('reads a real file system on Linux', () {
      final usage = statvfsUsage(Directory.systemTemp.path);
      if (!Platform.isLinux) {
        expect(usage, isNull);
        return;
      }
      expect(usage, isNotNull);
      expect(usage!.totalBytes, greaterThan(0));
      expect(usage.availableBytes, lessThanOrEqualTo(usage.totalBytes));
      expect(usage.freeBytes, greaterThanOrEqualTo(usage.availableBytes));
      expect(usage.usedPercent, inInclusiveRange(0, 100));
    }, testOn: 'linux');

    test('a missing path is null', () {
      expect(statvfsUsage('/definitely/not/here/yams'), isNull);
    });
  });

  group('MetricHistory', () {
    final t0 = DateTime.utc(2026, 11, 8, 9);

    test('ring buffer keeps the newest items', () {
      final r = RingBuffer<int>(3);
      for (var i = 1; i <= 5; i++) {
        r.add(i);
      }
      expect(r.toList(), [3, 4, 5]);
      expect(r.last(2), [4, 5]);
      expect(r.newest, 5);
    });

    test('1 h of 5 s samples and 24 h of minute averages', () {
      final h = MetricHistory();
      // 2 h of samples: CPU = minute index.
      for (var i = 0; i < 2 * 720; i++) {
        final t = t0.add(Duration(seconds: 5 * i));
        h.add(t, {
          HostMetricKind.cpu: (i ~/ 12).toDouble(),
          if (i.isEven) HostMetricKind.netRx: 10,
        });
      }
      final now = t0.add(const Duration(seconds: 5 * (2 * 720 - 1)));
      final hour = h.series(HostMetricKind.cpu, HostHistoryRange.hour, now);
      expect(hour, hasLength(720));
      expect(hour.last.t, now);
      expect(hour.first.t, now.subtract(const Duration(seconds: 5 * 719)));
      final day = h.series(HostMetricKind.cpu, HostHistoryRange.day, now);
      expect(day, hasLength(120)); // 119 closed minutes + the running one
      expect(day.first.t, t0);
      expect(day[3].v, 3);
      expect(day.last.v, 119);
      // A metric present in only some samples averages over those.
      expect(
        h.series(HostMetricKind.netRx, HostHistoryRange.day, now).first.v,
        10,
      );
      expect(h.recent(HostMetricKind.cpu, 60), hasLength(60));
      expect(
        h.series(HostMetricKind.temperature, HostHistoryRange.hour, now),
        isEmpty,
      );
    });

    test('24 h keeps at most 1440 minutes', () {
      final h = MetricHistory();
      for (var i = 0; i < 1500; i++) {
        h.add(t0.add(Duration(minutes: i)), {
          HostMetricKind.memory: i.toDouble(),
        });
      }
      final now = t0.add(const Duration(minutes: 1499));
      final day = h.series(HostMetricKind.memory, HostHistoryRange.day, now);
      expect(day.length, lessThanOrEqualTo(1441));
      expect(
        day.first.t.isBefore(now.subtract(const Duration(hours: 24))),
        isFalse,
      );
    });
  });
}
