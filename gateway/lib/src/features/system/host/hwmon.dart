/// CPU temperatures from the `coretemp` hwmon device (API.md §13.1).
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// Package and per-core temperatures in °C.
final class CoreTemps {
  const CoreTemps({required this.packageC, required this.coresC});

  final double? packageC;

  /// Ordered by core number.
  final List<double> coresC;
}

final _tempInput = RegExp(r'^temp(\d+)_input$');
final _coreLabel = RegExp(r'^Core\s+(\d+)$');

/// Reads `coretemp` under `<sysDir>/class/hwmon`.
///
/// The entries there (`hwmon0`, `hwmon1`) are relative symlinks such as
/// `../../devices/platform/coretemp.0/hwmon/hwmon1`. Each entry is resolved
/// with `Link.resolveSymbolicLinksSync()` inside a try/catch: a dangling or
/// unreadable entry is skipped, never fatal. Devices are selected by their
/// `name` file, never by index.
final class HwmonReader {
  HwmonReader(this.sysDir);

  /// `HOST_SYS` (`/sys`).
  final String sysDir;

  /// The coretemp readings, or null when there is no such sensor.
  CoreTemps? read() {
    for (final dir in _devices()) {
      final name = _readTrimmed(p.join(dir, 'name'));
      if (name != 'coretemp') continue;
      final temps = _readCoretemp(dir);
      if (temps != null) return temps;
    }
    return null;
  }

  /// Resolved hwmon device directories, in name order.
  List<String> _devices() {
    final root = Directory(p.join(sysDir, 'class', 'hwmon'));
    final List<FileSystemEntity> entries;
    try {
      entries = root.listSync(followLinks: false);
    } on FileSystemException {
      return const [];
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    final out = <String>[];
    for (final e in entries) {
      try {
        final resolved = Link(e.path).resolveSymbolicLinksSync();
        if (FileSystemEntity.isDirectorySync(resolved)) out.add(resolved);
      } on FileSystemException {
        // Dangling link (or a race with a device going away): skip it.
      }
    }
    return out;
  }

  CoreTemps? _readCoretemp(String dir) {
    final List<FileSystemEntity> files;
    try {
      files = Directory(dir).listSync(followLinks: false);
    } on FileSystemException {
      return null;
    }
    double? package;
    final labelledCores = <int, double>{};
    final unlabelled = <int, double>{};
    for (final f in files) {
      final m = _tempInput.firstMatch(p.basename(f.path));
      if (m == null) continue;
      final index = int.parse(m[1]!);
      final milli = int.tryParse(_readTrimmed(f.path) ?? '');
      if (milli == null) continue;
      final celsius = milli / 1000;
      final label = _readTrimmed(p.join(dir, 'temp${index}_label'));
      if (label == null) {
        unlabelled[index] = celsius;
      } else if (label.startsWith('Package')) {
        package ??= celsius;
      } else if (_coreLabel.firstMatch(label) case final c?) {
        labelledCores[int.parse(c[1]!)] = celsius;
      }
    }
    // Without labels: temp1 is the package, temp2.. are the cores.
    if (package == null && labelledCores.isEmpty && unlabelled.isNotEmpty) {
      package = unlabelled.remove(1);
      labelledCores.addAll(unlabelled);
    }
    if (package == null && labelledCores.isEmpty) return null;
    final keys = labelledCores.keys.toList()..sort();
    return CoreTemps(
      packageC: package,
      coresC: [for (final k in keys) labelledCores[k]!],
    );
  }

  static String? _readTrimmed(String path) {
    try {
      return File(path).readAsStringSync().trim();
    } on FileSystemException {
      return null;
    }
  }
}
